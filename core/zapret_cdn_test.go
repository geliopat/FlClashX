package core

import (
	"context"
	"testing"
)

func TestZapretCDNURLs(t *testing.T) {
	html := "https:\\/\\/rr1---sn-test.googlevideo.com\\/videoplayback?x=1\\u0026y=2 https://rr1---sn-test.googlevideo.com/videoplayback?x=3 https://evil.googlevideo.com/videoplayback?x=4"
	urls := cdnURLs(html)
	if len(urls) != 1 || len(urls[0].urls) != 2 || urls[0].urls[0] != "https://rr1---sn-test.googlevideo.com/videoplayback?x=1&y=2" || urls[0].urls[1] != "https://rr1---sn-test.googlevideo.com/videoplayback?x=3" {
		t.Fatalf("unexpected stream URLs: %v", urls)
	}
}

func TestZapretCDNRedirect(t *testing.T) {
	base := "https://rr1---sn-test.googlevideo.com/videoplayback?x=1"
	if got, ok := cdnRedirect(base, "https://rr2---sn-test.googlevideo.com/videoplayback?x=2"); !ok || got != "https://rr2---sn-test.googlevideo.com/videoplayback?x=2" {
		t.Fatalf("valid redirect rejected: %s", got)
	}
	for _, target := range []string{"http://rr2---sn-test.googlevideo.com/videoplayback", "https://example.com/videoplayback", "https://rr2---sn-test.googlevideo.com/other", "https://rr2---sn-test.googlevideo.com:8443/videoplayback"} {
		if _, ok := cdnRedirect(base, target); ok {
			t.Fatalf("unsafe redirect accepted: %s", target)
		}
	}
}

func TestZapretCDNAlternativeAfterForbidden(t *testing.T) {
	urls := []string{"first", "second", "third"}
	var calls []string
	got := measureCDNCandidates(context.Background(), urls, func(_ context.Context, raw string) ZapretCdnSample {
		calls = append(calls, raw)
		if raw == "first" {
			return ZapretCdnSample{Verdict: "unknown", Reason: "stream_http", HTTP: 403}
		}
		return ZapretCdnSample{Verdict: "measured", HTTP: 206, Bytes: zapretCdnMin}
	})
	if len(calls) != 2 || got.Verdict != "measured" {
		t.Fatalf("alternative was not measured: calls=%v result=%+v", calls, got)
	}
}

func TestZapretCDNAllForbiddenStayUnknown(t *testing.T) {
	calls := 0
	got := measureCDNCandidates(context.Background(), []string{"first", "second"}, func(_ context.Context, _ string) ZapretCdnSample {
		calls++
		return ZapretCdnSample{Verdict: "unknown", Reason: "stream_http", HTTP: 403}
	})
	if calls != 2 || got.Verdict != "unknown" || got.HTTP != 403 {
		t.Fatalf("rejections became a measurement: calls=%d result=%+v", calls, got)
	}
}

func TestZapretCDNCandidateLimit(t *testing.T) {
	base := "https://rr1---sn-test.googlevideo.com/videoplayback?x="
	groups := cdnURLs(base + "1 " + base + "1 " + base + "2 " + base + "3 " + base + "4")
	if len(groups) != 1 || len(groups[0].urls) != zapretCdnMaxURLs {
		t.Fatalf("candidate limit or deduplication failed: %v", groups)
	}
}
