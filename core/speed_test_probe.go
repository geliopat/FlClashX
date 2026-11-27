package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/constant"
)

const (
	speedDownloadBytes = 16 * 1024 * 1024
	speedUploadBytes = 8 * 1024 * 1024
	speedPhaseTimeout = 25 * time.Second
	yandexProbeAPI = "https://yandex.ru/internet/api/v0/get-probes"
)

type ProxySpeedRequest struct {
	ProxyName string `json:"proxy-name"`
	Service string `json:"service"`
	DownloadURL string `json:"download-url"`
	UploadURL string `json:"upload-url"`
}

type ProxySpeedResult struct {
	Download *float64 `json:"download"`
	Upload *float64 `json:"upload"`
	DownloadError string `json:"download-error,omitempty"`
	UploadError string `json:"upload-error,omitempty"`
}

// One measurement at a time across the core, including independent UI calls.
var speedTestLock sync.Mutex

func handleSpeedTest(params *ProxySpeedRequest) *ProxySpeedResult {
	failed := func(err string) *ProxySpeedResult {
		return &ProxySpeedResult{DownloadError: err, UploadError: err}
	}
	if !speedTestLock.TryLock() {
		return failed("busy")
	}
	defer speedTestLock.Unlock()
	proxy := lookupProxy(params.ProxyName)
	if proxy == nil || isProxyGroupType(proxy.Type()) {
		return failed("unsupported")
	}
	switch strings.ToUpper(params.ProxyName) {
	case "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE":
		return failed("unsupported")
	}
	if proxy.Type() == constant.Direct && params.ProxyName != "DIRECT" {
		return failed("unsupported")
	}
	dialer := &probeDialer{proxy: proxy}
	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil {
		return failed("failed")
	}
	transport := &http.Transport{
		DialContext: dialer.dial,
		TLSClientConfig: tlsConfig,
		TLSHandshakeTimeout: 10 * time.Second,
		DisableCompression: true,
		MaxIdleConns: 2,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	service, err := speedServiceForRoute(params.ProxyName == "DIRECT", params.Service)
	if err != nil { return failed("unsupported") }
	down, up := params.DownloadURL, params.UploadURL
	multipart := false
	switch service {
	case "cloudflare":
		down = fmt.Sprintf("https://speed.cloudflare.com/__down?bytes=%d", speedDownloadBytes)
		up = "https://speed.cloudflare.com/__up"
	case "yandex":
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		down, up, err = yandexSpeedURLs(ctx, client)
		cancel()
		if err != nil {
			return failed("discovery")
		}
		multipart = true
	case "custom":
	default:
		return failed("unsupported")
	}
	if service != "yandex" && (validYandexSpeedURL(down) || validYandexSpeedURL(up)) {
		return failed("unsupported")
	}
	if !validSpeedURL(down) || !validSpeedURL(up) {
		return failed("invalid-url")
	}
	result := &ProxySpeedResult{}
	result.Download, result.DownloadError = measureSpeed(client, down, false, false)
	result.Upload, result.UploadError = measureSpeed(client, up, true, multipart)
	return result
}

func validSpeedURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "https" || u.Scheme == "http") &&
		u.Hostname() != "" && u.User == nil && u.Fragment == ""
}

func validYandexSpeedURL(raw string) bool {
	if !validSpeedURL(raw) {
		return false
	}
	u, _ := url.Parse(raw)
	host := strings.ToLower(u.Hostname())
	return u.Scheme == "https" && (host == "yandex.ru" || host == "yandex.net" ||
		strings.HasSuffix(host, ".yandex.ru") || strings.HasSuffix(host, ".yandex.net"))
}

type yandexSpeedProbe struct {
	URL string `json:"url"`
	Size int64 `json:"size"`
}

func yandexSpeedURLs(ctx context.Context, client *http.Client) (string, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s?t=%d", yandexProbeAPI, time.Now().UnixMilli()), nil)
	if err != nil {
		return "", "", err
	}
	speedHeaders(req)
	response, err := client.Do(req)
	if err != nil {
		return "", "", err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return "", "", fmt.Errorf("Yandex API HTTP %d", response.StatusCode)
	}
	var config struct {
		Download struct { Probes []yandexSpeedProbe `json:"probes"` } `json:"download"`
		Upload struct { Probes []yandexSpeedProbe `json:"probes"` } `json:"upload"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1024*1024)).Decode(&config); err != nil {
		return "", "", err
	}
	return chooseYandexSpeedURLs(config.Download.Probes, config.Upload.Probes)
}

func chooseYandexSpeedURLs(download, upload []yandexSpeedProbe) (string, string, error) {
	bestDown, bestUp := "", ""
	var bestSize int64
	for _, d := range download {
		if !validYandexSpeedURL(d.URL) {
			continue
		}
		du, _ := url.Parse(d.URL)
		size := d.Size
		if strings.Contains(d.URL, "50mb") {
			size = max(size, 50*1024*1024)
		}
		for _, u := range upload {
			if !validYandexSpeedURL(u.URL) {
				continue
			}
			uu, _ := url.Parse(u.URL)
			if du.Hostname() == uu.Hostname() && (bestDown == "" || size > bestSize) {
				bestDown, bestUp, bestSize = d.URL, u.URL, size
			}
		}
	}
	if bestDown == "" || bestUp == "" {
		return "", "", fmt.Errorf("no matching Yandex download/upload probes")
	}
	return bestDown, bestUp, nil
}

func speedHeaders(req *http.Request) {
	req.Header.Set("User-Agent", browserUserAgent)
	req.Header.Set("Cache-Control", "no-cache")
	req.Header.Set("Accept-Encoding", "identity")
	if validYandexSpeedURL(req.URL.String()) {
		req.Header.Set("Referer", "https://yandex.ru/internet/")
		req.Header.Set("Origin", "https://yandex.ru")
	}
}

// This is a bounded single-connection sample, not the service's multi-stream
// browser score. No partial upload is reported as successful.
func measureSpeed(client *http.Client, endpoint string, upload, multipart bool) (*float64, string) {
	ctx, cancel := context.WithTimeout(context.Background(), speedPhaseTimeout)
	defer cancel()
	var body io.Reader
	var payload []byte
	method := http.MethodGet
	contentType := "application/octet-stream"
	if upload {
		method = http.MethodPost
		payload = make([]byte, speedUploadBytes)
		if _, err := rand.Read(payload); err != nil {
			return nil, "failed"
		}
		if multipart {
			const boundary = "FlClashZSpeedSample"
			prefix := "--"+boundary+"\r\nContent-Disposition: form-data; name=\"data\"; filename=\"blob\"\r\nContent-Type: application/octet-stream\r\n\r\n"
			suffix := "\r\n--"+boundary+"--\r\n"
			body = io.MultiReader(strings.NewReader(prefix), bytes.NewReader(payload), strings.NewReader(suffix))
			contentType = "multipart/form-data; boundary="+boundary
			req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
			if err != nil { return nil, "failed" }
			req.ContentLength = int64(len(prefix)+len(payload)+len(suffix))
			req.Header.Set("Content-Type", contentType)
			return transferSpeed(client, req, int64(len(payload)), true)
		}
		body = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return nil, "failed"
	}
	if upload {
		req.Header.Set("Content-Type", contentType)
	}
	return transferSpeed(client, req, int64(len(payload)), upload)
}

func transferSpeed(client *http.Client, req *http.Request, payloadBytes int64, upload bool) (*float64, string) {
	speedHeaders(req)
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return nil, probeErrorKind(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, "http"
	}
	var count int64
	if upload {
		_, err = io.Copy(io.Discard, io.LimitReader(resp.Body, 64*1024))
		count = payloadBytes
	} else {
		// A download URL must return data, not a successful HTML landing page.
		if strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")), "text/html") {
			return nil, "invalid-body"
		}
		count, err = io.Copy(io.Discard, io.LimitReader(resp.Body, speedDownloadBytes))
	}
	if err != nil {
		return nil, probeErrorKind(err)
	}
	if count < 64*1024 {
		return nil, "invalid-body"
	}
	elapsed := time.Since(start).Seconds()
	if elapsed <= 0 {
		return nil, "failed"
	}
	value := float64(count)*8/elapsed/1e6
	return &value, ""
}


// Do not allow a stale client preference or an IPC caller to run Internetometer
// through a VPN node. A named non-DIRECT route has no direct fallback.
func speedServiceForRoute(direct bool, requested string) (string, error) {
    if direct { return "yandex", nil }
    switch requested {
    case "cloudflare", "custom":
        return requested, nil
    default:
        return "", fmt.Errorf("unsupported VPN speed service")
    }
}
