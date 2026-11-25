package core

import (
	"context"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
)

// Adapted from zapret2-gui engine/youtube_probe.rs. Use the original signed
// videoplayback URLs, sequential samples, six nodes and a bounded wall time.
const (
	zapretCdnBytes = 3 * 1024 * 1024
	zapretCdnMin   = 64 * 1024
)

var zapretCdnMutex sync.Mutex
var zapretCdnHost = regexp.MustCompile("^rr[0-9]+---sn-[a-z0-9-]+\\.googlevideo\\.com$")
var zapretStreamURL = regexp.MustCompile("https://rr[0-9]+---sn-[a-z0-9-]+\\.googlevideo\\.com/videoplayback[^\"'<>[:space:]]*")

type ZapretCdnSample struct {
	Host    string  `json:"host"`
	Bytes   int     `json:"bytes"`
	Mbps    float64 `json:"mbps"`
	Verdict string  `json:"verdict"`
}

func cdnURLs(html string) []string {
	html = strings.ReplaceAll(strings.ReplaceAll(html, "\\/", "/"), "\\u0026", "&")
	seen := map[string]bool{}
	var urls []string
	for _, raw := range zapretStreamURL.FindAllString(html, -1) {
		if len(raw) > 4096 {
			continue
		}
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" ||
			u.Path != "/videoplayback" || !zapretCdnHost.MatchString(u.Hostname()) ||
			seen[u.Hostname()] {
			continue
		}
		seen[u.Hostname()] = true
		urls = append(urls, raw)
		if len(urls) == 6 {
			break
		}
	}
	return urls
}

func zapretDirect(result *ProbeResult) bool {
	if result == nil || len(result.Chains) == 0 {
		return false
	}
	for _, chain := range result.Chains {
		if chain != "DIRECT" {
			return false
		}
	}
	return true
}

func handleZapretCdnCheck() []ZapretCdnSample {
	if !zapretCdnMutex.TryLock() {
		return []ZapretCdnSample{}
	}
	defer zapretCdnMutex.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	var urls []string
	for _, id := range []string{"aqz-KE-bpKQ", "dQw4w9WgXcQ", "LXb3EKWsInQ"} {
		if ctx.Err() != nil {
			break
		}
		page := runProbe(ctx, probeRequest{
			url:        "https://www.youtube.com/watch?v=" + id,
			proxyName:  "DIRECT",
			timeout:    12 * time.Second,
			maxBody:    4 * 1024 * 1024,
			noRedirect: true,
			headers: map[string]string{"User-Agent": browserUserAgent, "Accept-Language": "ru-RU,ru;q=0.9,en;q=0.8"},
		})
		if zapretDirect(page) && page.StatusCode == 200 {
			urls = cdnURLs(page.Body)
			if len(urls) != 0 {
				break
			}
		}
	}
	samples := make([]ZapretCdnSample, 0, len(urls))
	for _, raw := range urls {
		if ctx.Err() != nil {
			break
		}
		u, _ := url.Parse(raw)
		host := u.Hostname()
		sample := ZapretCdnSample{Host: host, Verdict: "unknown"}
		// Do not mistake a deliberate local loopback mapping for throttling.
		if node, ok := resolver.DefaultHosts.Search(host, false); ok {
			ip, _ := node.RandIP()
			if ip.IsLoopback() || ip.IsUnspecified() {
				samples = append(samples, sample)
				continue
			}
		}
		result := runProbe(ctx, probeRequest{
			url:        raw,
			proxyName:  "DIRECT",
			timeout:    25 * time.Second,
			maxBody:    zapretCdnBytes,
			noRedirect: true,
			headers: map[string]string{"User-Agent": browserUserAgent, "Range": fmt.Sprintf("bytes=0-%d", zapretCdnBytes-1), "Accept-Encoding": "identity"},
		})
		if zapretDirect(result) && (result.StatusCode == 200 || result.StatusCode == 206) {
			contentType := strings.ToLower(result.header.Get("Content-Type"))
			if strings.HasPrefix(contentType, "video/") || strings.HasPrefix(contentType, "audio/") || strings.HasPrefix(contentType, "application/octet-stream") {
				sample.Bytes = len(result.Body)
				if sample.Bytes >= zapretCdnMin && result.sampleMicros > 0 {
					sample.Mbps = float64(sample.Bytes) * 8 / float64(result.sampleMicros)
					sample.Verdict = "measured"
				}
			}
		}
		samples = append(samples, sample)
	}
	return samples
}
