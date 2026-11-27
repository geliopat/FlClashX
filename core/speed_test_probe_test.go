package core

import "testing"

func TestChooseYandexSpeedURLs(t *testing.T) {
	down, up, err := chooseYandexSpeedURLs(
		[]yandexSpeedProbe{
			{URL: "https://other.invalid/50mb", Size: 999999999},
			{URL: "https://a.yandex.net/1mb", Size: 1024*1024},
			{URL: "https://a.yandex.net/50mb", Size: 50*1024*1024},
		},
		[]yandexSpeedProbe{{URL: "https://a.yandex.net/upload"}},
	)
	if err != nil || down != "https://a.yandex.net/50mb" || up != "https://a.yandex.net/upload" {
		t.Fatalf("unexpected choice: %q %q %v", down, up, err)
	}
}

func TestSpeedURLValidation(t *testing.T) {
	for _, raw := range []string{"file:///tmp/x", "https://user:pass@example.com/", "https://", "https://example.com/#x"} {
		if validSpeedURL(raw) { t.Errorf("accepted %q", raw) }
	}
	if !validSpeedURL("https://example.com/__up") { t.Fatal("valid URL rejected") }
}


func TestSpeedServiceNeverUsesYandexThroughVPN(t *testing.T) {
    if service, err := speedServiceForRoute(true, "custom"); err != nil || service != "yandex" {
        t.Fatal("DIRECT did not select Internetometer")
    }
    if _, err := speedServiceForRoute(false, "yandex"); err == nil {
        t.Fatal("VPN accepted Internetometer")
    }
    for _, service := range []string{"cloudflare", "custom"} {
        if actual, err := speedServiceForRoute(false, service); err != nil || actual != service {
            t.Fatalf("VPN rejected %s", service)
        }
    }
}
