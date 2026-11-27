package core

import (
    "testing"
    "context"
    "io"
    "net/http/httptest"
    stdhttp "net/http"
    "strings"
    "time"
    "sync/atomic"
    "github.com/metacubex/http"
    "github.com/metacubex/mihomo/adapter"
    "github.com/metacubex/mihomo/adapter/outbound"
    "github.com/metacubex/mihomo/constant"
)

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
    for _, service := range []string{"cloudflare", "cachefly", "custom"} {
        if actual, err := speedServiceForRoute(false, service); err != nil || actual != service {
            t.Fatalf("VPN rejected %s", service)
        }
    }
}

func TestSpeedSamplesCountActualBodiesAndRejectErrors(t *testing.T) {
    var received atomic.Int64
    server := httptest.NewServer(stdhttp.HandlerFunc(func(w stdhttp.ResponseWriter,r *stdhttp.Request) {
        switch r.URL.Path {
        case "/html":
            w.Header().Set("Content-Type","text/html")
            _,_ = io.WriteString(w,strings.Repeat("<html>error</html>",10000))
        case "/short":
            _,_ = io.WriteString(w,"short")
        case "/upload":
            n,_:=io.Copy(io.Discard,r.Body)
            received.Add(n)
            w.WriteHeader(200)
        default:
            w.Header().Set("Content-Type","application/octet-stream")
            _,_ = io.WriteString(w,strings.Repeat("x",131072))
        }
    }))
    defer server.Close()
    client:= &http.Client{}
    ctx,cancel:=context.WithTimeout(context.Background(),5*time.Second)
    defer cancel()
    down:=runSpeedSample(ctx,client,"custom",server.URL,200000,nil,false,false)
    if down.err!="" || down.bytes!=131072 { t.Fatalf("download sample: %+v",down) }
    for _,path:= range []string{"/html","/short"} {
        if got:=runSpeedSample(ctx,client,"custom",server.URL+path,200000,nil,false,false); got.err=="" || got.bytes!=0 {
            t.Fatalf("invalid body accepted: %+v",got)
        }
    }
    payload:=make([]byte,131072)
    upload:=runSpeedSample(ctx,client,"custom",server.URL+"/upload",int64(len(payload)),payload,true,false)
    if upload.err!="" || upload.bytes!=int64(len(payload)) || received.Load()!=upload.bytes {
        t.Fatalf("upload sample: %+v, server got %d",upload,received.Load())
    }
}
func TestSpeedOptionsAndEndpointCaps(t *testing.T) {
    opts:=normalizedSpeedOptions(&ProxySpeedRequest{Streams:99,Seconds:999,MaxMB:999})
    if opts.streams!=8 || opts.seconds!=25 || opts.maxBytes!=500000000 { t.Fatalf("invalid caps: %+v",opts) }
    url,size:=speedDownloadEndpoint("cloudflare","",100000000)
    if size!=99999999 || !strings.HasSuffix(url,"bytes=99999999") { t.Fatal(url,size) }
    url,size=speedDownloadEndpoint("cachefly","",50000000)
    if size!=50000000 || !strings.HasSuffix(url,"100mb.test") { t.Fatal(url,size) }
}
type speedTestVPNAdapter struct { constant.ProxyAdapter }
func (a speedTestVPNAdapter) Type() constant.AdapterType { return constant.Vless }
func TestSpeedGroupResolvesSelectedLeafAndRejectsMixed(t *testing.T) {
    direct:=adapter.NewProxy(outbound.NewDirectWithOption(outbound.DirectOption{Name:"DIRECT"}))
    vpn:=adapter.NewProxy(speedTestVPNAdapter{outbound.NewDirectWithOption(outbound.DirectOption{Name:"VPN"})})
    selector:=selectorOver(t,"Selector",direct,vpn)
    leaf,isDirect,err:=resolveSpeedRoute(selector)
    if err!=nil || !isDirect || leaf.Name()!="DIRECT" { t.Fatal(leaf,isDirect,err) }
    mixed:=balanceOver(t,"Mixed",direct,vpn)
    if _,_,err:=resolveSpeedRoute(mixed);err==nil || err.Error()!="mixed-direct-group" { t.Fatal(err) }
    balance:=balanceOver(t,"VPNs",vpn)
    route,isDirect,err:=resolveSpeedRoute(balance)
    if err!=nil || isDirect || route.Name()!="VPNs" { t.Fatal(route,isDirect,err) }
}


func TestSpeedPhaseRetriesTransientWaveWithinBudget(t *testing.T) {
    var calls atomic.Int64
    server := httptest.NewServer(stdhttp.HandlerFunc(func(w stdhttp.ResponseWriter, r *stdhttp.Request) {
        if calls.Add(1) == 1 {
            w.WriteHeader(503)
            return
        }
        w.Header().Set("Content-Type", "application/octet-stream")
        _, _ = io.WriteString(w, strings.Repeat("x", 256000))
    }))
    defer server.Close()
    rate, n, err := measureSpeedPhase(&http.Client{}, "custom", server.URL, false, false,
        speedOptions{streams: 1, seconds: 5, maxBytes: 512000})
    if rate == nil || n != 256000 || err != "" || calls.Load() != 2 {
        t.Fatalf("retry: rate=%v bytes=%d error=%q calls=%d", rate, n, err, calls.Load())
    }
}

func TestSpeedPhaseRejectsPartiallyFailedWave(t *testing.T) {
    var calls atomic.Int64
    server := httptest.NewServer(stdhttp.HandlerFunc(func(w stdhttp.ResponseWriter, r *stdhttp.Request) {
        if calls.Add(1) == 1 {
            w.WriteHeader(503)
            return
        }
        w.Header().Set("Content-Type", "application/octet-stream")
        _, _ = io.WriteString(w, strings.Repeat("x", 256000))
    }))
    defer server.Close()
    rate, n, err := measureSpeedPhase(&http.Client{}, "custom", server.URL, false, false,
        speedOptions{streams: 2, seconds: 5, maxBytes: 1024000})
    if rate != nil || n != 0 || err != "http" || calls.Load() != 2 {
        t.Fatalf("partial wave: rate=%v bytes=%d error=%q calls=%d", rate, n, err, calls.Load())
    }
}

func TestSpeedPhaseRetryCannotExceedTrafficBudget(t *testing.T) {
    var calls atomic.Int64
    server := httptest.NewServer(stdhttp.HandlerFunc(func(w stdhttp.ResponseWriter, r *stdhttp.Request) {
        calls.Add(1)
        w.WriteHeader(503)
    }))
    defer server.Close()
    rate, n, err := measureSpeedPhase(&http.Client{}, "custom", server.URL, false, false,
        speedOptions{streams: 1, seconds: 5, maxBytes: 256000})
    if rate != nil || n != 0 || err != "http" || calls.Load() != 1 {
        t.Fatalf("budget: rate=%v bytes=%d error=%q calls=%d", rate, n, err, calls.Load())
    }
}
