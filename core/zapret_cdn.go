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
	Reason  string  `json:"reason,omitempty"`
	HTTP    int     `json:"httpStatus,omitempty"`
}

// Keep several original playback URLs per node; the first format can
// be rejected even when a different format is available.
const (
	zapretCdnMaxHosts = 6
	zapretCdnMaxURLs  = 3
)

type cdnCandidates struct {
	host string
	urls []string
}

func appendCDNURL(groups []cdnCandidates, raw string) []cdnCandidates {
	if len(raw) > 4096 {
		return groups
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" ||
		u.Path != "/videoplayback" || !zapretCdnHost.MatchString(u.Hostname()) {
		return groups
	}
	for i := range groups {
		if groups[i].host != u.Hostname() {
			continue
		}
		for _, existing := range groups[i].urls {
			if existing == raw {
				return groups
			}
		}
		if len(groups[i].urls) < zapretCdnMaxURLs {
			groups[i].urls = append(groups[i].urls, raw)
		}
		return groups
	}
	if len(groups) < zapretCdnMaxHosts {
		groups = append(groups, cdnCandidates{host: u.Hostname(), urls: []string{raw}})
	}
	return groups
}

func cdnURLs(html string) []cdnCandidates {
	html = strings.ReplaceAll(strings.ReplaceAll(html, "\\/", "/"), "\\u0026", "&")
	var groups []cdnCandidates
	for _, raw := range zapretStreamURL.FindAllString(html, -1) {
		// An escaped closing quote can leave a trailing JSON backslash.
		groups = appendCDNURL(groups, strings.TrimSuffix(raw, "\\"))
	}
	return groups
}

// Rejection is not a speed sample. Retry only with another original URL,
// never by modifying the signed query or the DNS destination.
func measureCDNCandidates(ctx context.Context, urls []string, measure func(context.Context, string) ZapretCdnSample) ZapretCdnSample {
	sample := ZapretCdnSample{Verdict: "unknown", Reason: "budget_exhausted"}
	for _, raw := range urls {
		if ctx.Err() != nil {
			break
		}
		sample = measure(ctx, raw)
		if sample.Reason != "stream_http" || (sample.HTTP != 403 && sample.HTTP != 401 && sample.HTTP != 410) {
			return sample
		}
	}
	return sample
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

// Never expose signed playback URLs or raw network errors to the UI.
func cdnProbeReason(result *ProbeResult) string {
	if result == nil {
		return "probe_busy_or_timeout"
	}
	if result.Error != "" {
		if result.Error == probeErrorTimeout {
			return "timeout"
		}
		return "network_error"
	}
	if !zapretDirect(result) {
		return "direct_unconfirmed"
	}
	return ""
}

func cdnRedirect(current, location string) (string, bool) {
	base, err := url.Parse(current)
	if err != nil || location == "" {
		return "", false
	}
	target, err := base.Parse(location)
	if err != nil || target.Scheme != "https" || target.User != nil ||
		target.Port() != "" || target.Path != "/videoplayback" ||
		!zapretCdnHost.MatchString(target.Hostname()) || len(target.String()) > 4096 {
		return "", false
	}
	return target.String(), true
}

func cdnMappedLocally(host string) bool {
	if node, ok := resolver.DefaultHosts.Search(host, false); ok {
		ip, _ := node.RandIP()
		return ip.IsLoopback() || ip.IsUnspecified()
	}
	return false
}

func handleZapretCdnCheck() []ZapretCdnSample {
	if !zapretCdnMutex.TryLock() {
		return []ZapretCdnSample{{Verdict: "diagnostic", Reason: "check_busy"}}
	}
	defer zapretCdnMutex.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	var groups []cdnCandidates
	samples := []ZapretCdnSample{}
	for _, id := range []string{"aqz-KE-bpKQ", "dQw4w9WgXcQ", "LXb3EKWsInQ"} {
		if ctx.Err() != nil {
			break
		}
		page := runProbe(ctx, probeRequest{
			url:        "https://www.youtube.com/watch?v=" + id,
			proxyName:  "DIRECT",
			timeout:    12 * time.Second,
			maxBody:    8 * 1024 * 1024,
			noRedirect: true,
			headers:    map[string]string{"User-Agent": browserUserAgent, "Accept-Language": "ru-RU,ru;q=0.9,en;q=0.8"},
		})
		diagnostic := ZapretCdnSample{Host: "www.youtube.com", Verdict: "diagnostic", Reason: cdnProbeReason(page)}
		if page != nil {
			diagnostic.HTTP = page.StatusCode
		}
		if diagnostic.Reason == "" {
			switch {
			case page.StatusCode != 200:
				diagnostic.Reason = "watch_http"
			default:
				found := cdnURLs(page.Body)
				if len(found) == 0 {
					diagnostic.Reason = "no_stream_urls"
				} else {
					diagnostic.Reason = "stream_urls_found"
				}
				for _, group := range found {
					for _, raw := range group.urls {
						groups = appendCDNURL(groups, raw)
					}
				}
			}
		}
		samples = append(samples, diagnostic)
	}
	for _, group := range groups {
		if ctx.Err() != nil {
			samples = append(samples, ZapretCdnSample{Verdict: "diagnostic", Reason: "budget_exhausted"})
			break
		}
		samples = append(samples, measureCDNCandidates(ctx, group.urls, measureZapretCDN))
	}
	return samples
}

func measureZapretCDN(ctx context.Context, raw string) ZapretCdnSample {
	ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	for hop := 0; hop <= 3; hop++ {
		u, _ := url.Parse(raw)
		host := u.Hostname()
		sample := ZapretCdnSample{Host: host, Verdict: "unknown"}
		if cdnMappedLocally(host) {
			sample.Reason = "local_hosts_mapping"
			return sample
		}
		result := runProbe(ctx, probeRequest{
			url:        raw,
			proxyName:  "DIRECT",
			timeout:    25 * time.Second,
			maxBody:    zapretCdnBytes,
			noRedirect: true,
			headers:    map[string]string{"User-Agent": browserUserAgent, "Range": fmt.Sprintf("bytes=0-%d", zapretCdnBytes-1), "Accept-Encoding": "identity"},
		})
		sample.Reason = cdnProbeReason(result)
		if result != nil {
			sample.HTTP = result.StatusCode
		}
		if sample.Reason != "" {
			return sample
		}
		if result.StatusCode >= 300 && result.StatusCode < 400 {
			next, ok := cdnRedirect(raw, result.header.Get("Location"))
			if !ok || hop == 3 {
				sample.Reason = "redirect_rejected"
				return sample
			}
			raw = next
			continue
		}
		if result.StatusCode != 200 && result.StatusCode != 206 {
			sample.Reason = "stream_http"
			return sample
		}
		contentType := strings.ToLower(result.header.Get("Content-Type"))
		if !strings.HasPrefix(contentType, "video/") &&
			!strings.HasPrefix(contentType, "audio/") &&
			!strings.HasPrefix(contentType, "application/octet-stream") {
			sample.Reason = "not_media"
			return sample
		}
		sample.Bytes = len(result.Body)
		if sample.Bytes < zapretCdnMin || result.sampleMicros <= 0 {
			sample.Reason = "insufficient_sample"
			return sample
		}
		sample.Mbps = float64(sample.Bytes) * 8 / float64(result.sampleMicros)
		sample.Verdict = "measured"
		return sample
	}
	return ZapretCdnSample{Verdict: "unknown", Reason: "redirect_rejected"}
}
