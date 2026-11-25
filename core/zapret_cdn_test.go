package core

import "testing"

func TestZapretCDNURLs(t *testing.T) {
	html := "https:\\/\\/rr1---sn-test.googlevideo.com\\/videoplayback?x=1\\u0026y=2 https://rr1---sn-test.googlevideo.com/videoplayback?x=3 https://evil.googlevideo.com/videoplayback?x=4"
	urls := cdnURLs(html)
	if len(urls) != 1 || urls[0] != "https://rr1---sn-test.googlevideo.com/videoplayback?x=1&y=2" {
		t.Fatalf("unexpected stream URLs: %v", urls)
	}
}
