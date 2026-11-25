package core

import "testing"

func TestZapretCDNURLs(t *testing.T) {
	html := "https:\\/\\/rr1---sn-test.googlevideo.com\\/videoplayback?x=1\\u0026y=2 https://rr1---sn-test.googlevideo.com/videoplayback?x=3 https://evil.googlevideo.com/videoplayback?x=4"
	urls := cdnURLs(html)
	if len(urls) != 1 || urls[0] != "https://rr1---sn-test.googlevideo.com/videoplayback?x=1&y=2" {
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
