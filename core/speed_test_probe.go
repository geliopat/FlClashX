package core

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"net"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
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
	Streams int `json:"streams"`
	Seconds int `json:"seconds"`
	MaxMB int `json:"max-mb"`
	Direction string `json:"direction"`
	UploadURL string `json:"upload-url"`
}

type ProxySpeedResult struct {
	Download *float64 `json:"download"`
	Upload *float64 `json:"upload"`
	DownloadError string `json:"download-error,omitempty"`
	UploadError string `json:"upload-error,omitempty"`
	DownloadBytes int64 `json:"download-bytes,omitempty"`
	UploadBytes int64 `json:"upload-bytes,omitempty"`
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
	proxy, direct, err := resolveSpeedRoute(lookupProxy(params.ProxyName))
	if err != nil { return failed(err.Error()) }
	dialer := &probeDialer{proxy: proxy}
	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil {
		return failed("failed")
	}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			// Recheck a dynamic group's current members before each connection.
			// No fallback to the system network or a DIRECT member is allowed.
			_, nowDirect, routeErr := resolveSpeedRoute(proxy)
			if routeErr != nil || nowDirect != direct { return nil, fmt.Errorf("speed route changed") }
			conn, err := dialer.dial(ctx, network, address)
			if err != nil { return nil, err }
			if !direct {
				if routed, ok := conn.(constant.Conn); ok {
					for _, name := range routed.Chains() {
						if p := lookupProxy(name); p != nil && p.Type() == constant.Direct {
							_ = conn.Close()
							return nil, fmt.Errorf("DIRECT exit refused")
						}
					}
				}
			}
			return conn, nil
		},
		TLSClientConfig: tlsConfig,
		TLSHandshakeTimeout: 10 * time.Second,
		DisableCompression: true,
		MaxIdleConns: 8,
		MaxIdleConnsPerHost: 8,
		DisableKeepAlives: true,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	service, err := speedServiceForRoute(direct, params.Service)
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
	case "cachefly":
		down = "https://cachefly.cachefly.net/100mb.test"
		up = ""
	case "custom":
	default:
		return failed("unsupported")
	}
	if service != "yandex" && (isYandexSpeedHost(down) || isYandexSpeedHost(up)) {
		return failed("unsupported")
	}
	options := normalizedSpeedOptions(params)
	result := &ProxySpeedResult{}
	if options.direction != "upload" {
		if !validSpeedURL(down) { result.DownloadError = "invalid-url" } else {
			result.Download, result.DownloadBytes, result.DownloadError = measureSpeedPhase(client, service, down, false, false, options)
		}
	}
	if options.direction != "download" {
		if service == "cachefly" { result.UploadError = "unsupported" } else if !validSpeedURL(up) {
			result.UploadError = "invalid-url"
		} else {
			result.Upload, result.UploadBytes, result.UploadError = measureSpeedPhase(client, service, up, true, multipart, options)
		}
	}
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
	return u.Scheme == "https" && isYandexSpeedHost(raw)
}

func isYandexSpeedHost(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil { return false }
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	return host == "yandex.ru" || host == "yandex.net" ||
		strings.HasSuffix(host, ".yandex.ru") || strings.HasSuffix(host, ".yandex.net")
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

// Do not allow a stale client preference or an IPC caller to run Internetometer
// through a VPN node. A named non-DIRECT route has no direct fallback.
func speedServiceForRoute(direct bool, requested string) (string, error) {
    if direct { return "yandex", nil }
    switch requested {
    case "cloudflare", "cachefly", "custom":
        return requested, nil
    default:
        return "", fmt.Errorf("unsupported VPN speed service")
    }
}


// A selector is pinned to its current leaf without changing selection. A
// load balancer is tested as the actual group, not as its fastest member.
// A mixed group cannot guarantee that a VPN endpoint stays off DIRECT.
func resolveSpeedRoute(root constant.Proxy) (constant.Proxy, bool, error) {
	active := map[constant.Proxy]bool{}
	var walk func(constant.Proxy) (constant.Proxy, bool, error)
	walk = func(p constant.Proxy) (constant.Proxy, bool, error) {
		if p == nil || active[p] { return nil, false, fmt.Errorf("unsupported") }
		active[p] = true
		defer delete(active,p)
		if group, ok := adapterAs[*outboundgroup.LoadBalance](p); ok {
			var first constant.Proxy
			var direct bool
			for _, member := range group.Proxies() {
				leaf, isDirect, err := walk(member)
				if err != nil { return nil, false, err }
				if first == nil { first, direct = leaf, isDirect } else if direct != isDirect {
					return nil, false, fmt.Errorf("mixed-direct-group")
				}
			}
			if first == nil { return nil, false, fmt.Errorf("unsupported") }
			if direct { return first, true, nil }
			return p, false, nil
		}
		if isProxyGroupType(p.Type()) {
			return walk(p.Unwrap(nil, false))
		}
		if p.Type() == constant.Direct {
			if p.Name() != "DIRECT" { return nil, false, fmt.Errorf("unsupported") }
			return p, true, nil
		}
		switch strings.ToUpper(p.Name()) {
		case "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE":
			return nil, false, fmt.Errorf("unsupported")
		}
		switch p.Type().String() {
		case "Reject", "RejectDrop", "Pass", "Compatible":
			return nil, false, fmt.Errorf("unsupported")
		}
		return p, false, nil
	}
	return walk(root)
}
