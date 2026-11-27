package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"strings"
	"sync"
	"bufio"
	"time"

	"github.com/metacubex/http"
)

type speedOptions struct {
	streams, seconds int
	maxBytes int64
	direction string
}

func normalizedSpeedOptions(p *ProxySpeedRequest) speedOptions {
	streams, seconds, mb := p.Streams, p.Seconds, p.MaxMB
	if streams == 0 { streams = 4 }
	if seconds == 0 { seconds = 8 }
	if mb == 0 { mb = 100 }
	direction := p.Direction
	if direction != "download" && direction != "upload" { direction = "both" }
	return speedOptions{min(8,max(1,streams)), min(25,max(2,seconds)), int64(min(500,max(10,mb)))*1000000, direction}
}

type speedSample struct {
	bytes int64
	first, last time.Time
	err string
	retryable bool
}

type timedSpeedReader struct {
	reader io.Reader
	sample *speedSample
	mu *sync.Mutex
}

func (r timedSpeedReader) Read(p []byte) (int,error) {
	n, err := r.reader.Read(p)
	if n > 0 {
		r.mu.Lock()
		defer r.mu.Unlock()
		now := time.Now()
		if r.sample.first.IsZero() { r.sample.first = now }
		r.sample.last = now
		r.sample.bytes += int64(n)
	}
	return n,err
}

// Sizes are requested, never assumed to equal transferred bytes. CacheFly
// supports public test objects; 50 MB is a capped sample of the 100 MB file.
func speedDownloadEndpoint(service, endpoint string, size int64) (string,int64) {
	switch service {
	case "cloudflare":
		return fmt.Sprintf("https://speed.cloudflare.com/__down?bytes=%d", min(size,int64(99999999))), min(size,int64(99999999))
	case "cachefly":
		switch {
		case size <= 1048576: return "https://cachefly.cachefly.net/1mb.test", min(size,int64(1048576))
		case size <= 10485760: return "https://cachefly.cachefly.net/10mb.test", min(size,int64(10485760))
		default: return "https://cachefly.cachefly.net/100mb.test", min(size,int64(104857600))
		}
	default:
		return endpoint,size
	}
}

func measureSpeedPhase(client *http.Client, service, endpoint string, upload, multipart bool, options speedOptions) (*float64,int64,string) {
	ctx,cancel := context.WithTimeout(context.Background(),time.Duration(options.seconds)*time.Second)
	defer cancel()
	remaining := options.maxBytes
	var measured int64
	var elapsed time.Duration
	size := int64(256000)
	failure := "timeout"
	retried := false
	// A wave has independent connections. Increase the chunk size only after
	// successful waves. Retry a wholly failed transient wave at most once,
	// inside the original deadline and traffic budget.
	for remaining >= 65536 && ctx.Err() == nil {
		streams := min(options.streams,int(remaining/65536))
		chunk := min(size,remaining/int64(streams))
		if upload { chunk = min(chunk,int64(16000000)) }
		var payload []byte
		if upload {
			payload = make([]byte,int(chunk))
			if _,err := rand.Read(payload); err != nil { return nil,measured,"failed" }
		}
		wave := make(chan speedSample,streams)
		for i := 0; i < streams; i++ {
			go func() {
				url,limit := endpoint,chunk
				if !upload { url,limit = speedDownloadEndpoint(service,endpoint,chunk) }
				wave <- runSpeedSample(ctx,client,service,url,limit,payload,upload,multipart)
			}()
		}
		// Reserve even unsuccessful/partial transfers against the traffic cap.
		remaining -= int64(streams)*chunk
		var first,last time.Time
		var total int64
		failed := false
		allFailuresRetryable := true
		for i:=0; i<streams; i++ {
			s := <-wave
			if s.err != "" {
				failed = true
				allFailuresRetryable = allFailuresRetryable && s.retryable
				failure = s.err
				continue
			}
			if first.IsZero() || s.first.Before(first) { first=s.first }
			if s.last.After(last) { last=s.last }
			total += s.bytes
		}
		if failed {
			// A mixed wave is not a valid aggregate throughput sample. Never
			// report the surviving streams as the whole requested group.
			if total == 0 && allFailuresRetryable && !retried && ctx.Err() == nil && remaining >= 65536 {
				retried = true
				continue
			}
			if ctx.Err() != nil && measured >= 65536 && elapsed > 0 {
				break // the time budget ended after at least one complete wave
			}
			return nil, measured, failure
		}
		if total > 0 && last.After(first) {
			measured += total
			elapsed += last.Sub(first)
		} else if total > 0 {
			// Very small local transfers may fit inside one clock tick.
			// The body is valid, but the interval cannot support a rate.
			// Increase the next chunk instead of inventing a duration.
			failure = "insufficient-duration"
		}
		if elapsed >= time.Duration(options.seconds)*time.Second { break }
		// Ramp based on completed body duration, not TCP/TLS setup latency.
		switch {
		case size < 1000000: size=1000000
		case size < 10000000: size=10000000
		case size < 50000000: size=50000000
		default: size=99999999
		}
	}
	if measured < 65536 || elapsed <= 0 { return nil,measured,failure }
	rate:=float64(measured)*8/elapsed.Seconds()/1e6
	return &rate,measured,""
}

func runSpeedSample(ctx context.Context, client *http.Client, service, endpoint string, limit int64, payload []byte, upload,multipart bool) speedSample {
	s := speedSample{}
	var mu sync.Mutex
	fail := func(reason string) speedSample { return speedSample{err:reason} }
	method := http.MethodGet
	var body io.Reader
	var bodyLength int64
	contentType := "application/octet-stream"
	if upload {
		method=http.MethodPost
		body=timedSpeedReader{bytes.NewReader(payload),&s,&mu}
		bodyLength=int64(len(payload))
		if multipart {
			const boundary="FlClashZSpeedSample"
			prefix:="--"+boundary+"\r\nContent-Disposition: form-data; name=\"data\"; filename=\"blob\"\r\nContent-Type: application/octet-stream\r\n\r\n"
			suffix:="\r\n--"+boundary+"--\r\n"
			body=io.MultiReader(strings.NewReader(prefix),body,strings.NewReader(suffix))
			bodyLength+=int64(len(prefix)+len(suffix))
			contentType="multipart/form-data; boundary="+boundary
		}
	}
	req,err:=http.NewRequestWithContext(ctx,method,endpoint,body)
	if err!=nil { return fail("invalid-url") }
	speedHeaders(req)
	if upload { req.ContentLength=bodyLength; req.Header.Set("Content-Type",contentType) }
	if !upload && service=="cachefly" { req.Header.Set("Range",fmt.Sprintf("bytes=0-%d",limit-1)) }
	resp,err:=client.Do(req)
	if err!=nil { return speedSample{err: probeErrorKind(err), retryable: ctx.Err() == nil} }
	defer resp.Body.Close()
	if resp.StatusCode<200 || resp.StatusCode>=300 {
		return speedSample{err: "http", retryable: resp.StatusCode == 502 || resp.StatusCode == 503 || resp.StatusCode == 504}
	}
	if strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")),"text/html") { return fail("invalid-body") }
	if upload {
		// Only a complete, acknowledged body is counted. The receipt excludes
		// the multipart envelope and does not claim wire-level byte counts.
		if _,err:=io.Copy(io.Discard,io.LimitReader(resp.Body,65536));err!=nil { return fail(probeErrorKind(err)) }
		mu.Lock()
		defer mu.Unlock()
		if s.bytes!=int64(len(payload)) { return fail("incomplete-upload") }
		// Include the final acknowledgement to avoid measuring only a
		// fast local transport buffer rather than accepted payload.
		s.last = time.Now()
		return s
	}
	reader := bufio.NewReaderSize(resp.Body, 1024)
	// Start the measurement before reading any payload, including the
	// small peek used to detect disguised HTML error pages.
	s.first = time.Now()
	prefix, _ := reader.Peek(512)
	head := strings.ToLower(strings.TrimSpace(string(prefix)))
	if strings.HasPrefix(head, "<html") || strings.HasPrefix(head, "<!doctype html") {
		return fail("invalid-body")
	}
	buffer:=make([]byte,64*1024)
	n,err:=io.CopyBuffer(io.Discard,timedSpeedReader{io.LimitReader(reader,limit),&s,&mu},buffer)
	if err!=nil { return fail(probeErrorKind(err)) }
	if n<65536 || (service=="cloudflare" && n!=limit) ||
		(resp.ContentLength>=0 && n<min(resp.ContentLength,limit)) { return fail("invalid-body") }
	// Payload integrity is independent of clock granularity.
	return s
}
