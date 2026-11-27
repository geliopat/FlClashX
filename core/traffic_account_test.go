package core

import (
	"io"
	"net"
	"testing"

	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/component/proxydialer"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// The TUN listener asserts provider.Tunnel unchecked; the wrapper must offer it.
func TestTrafficTunnelOffersEveryInterfaceMihomoAsserts(t *testing.T) {
	if _, ok := trafficTunnel.(provider.Tunnel); !ok {
		t.Fatal("trafficTunnel does not satisfy provider.Tunnel; TUN start panics")
	}
	if _, ok := trafficTunnel.(proxydialer.Tunnel); !ok {
		t.Fatal("trafficTunnel does not satisfy proxydialer.Tunnel")
	}
	rp := trafficTunnel.(provider.Tunnel)
	if rp.RuleUpdateCallback() != tunnel.Tunnel.RuleUpdateCallback() {
		t.Fatal("rule update callback must be mihomo's own, not a fresh one")
	}
}

func registerTracker(t *testing.T, metadata *constant.Metadata) statistic.Tracker {
	t.Helper()
	local, remote := net.Pipe()
	go func() { _, _ = io.Copy(io.Discard, remote) }()
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "DIRECT"})
	tracker := statistic.NewTCPTracker(
		outbound.NewConn(local, direct),
		statistic.DefaultManager,
		metadata,
		nil,
		0,
		0,
		true,
	)
	t.Cleanup(func() {
		_ = tracker.Close()
		_ = remote.Close()
	})
	return tracker
}

func TestNativeTrackerPublishesBeforeFirstPayload(t *testing.T) {
	metadata := &constant.Metadata{}
	probe := &routedConn{}
	pendingProbeRoutes.Store(metadata, probe)
	t.Cleanup(func() { pendingProbeRoutes.Delete(metadata) })
	tracker := registerTracker(t, metadata)
	if statistic.DefaultManager.Get(tracker.ID()) == nil {
		t.Fatal("tracker must be registered before callback")
	}
	probe.mu.Lock()
	defer probe.mu.Unlock()
	if probe.route == nil || len(probe.route.chains) == 0 {
		t.Fatal("native connection callback did not settle probe route")
	}
}

func TestNativeTrafficTotalsDoNotDependOnPolling(t *testing.T) {
	handleResetTraffic()
	t.Cleanup(handleResetTraffic)
	statistic.DefaultManager.PushUploaded(false, 31)
	statistic.DefaultManager.PushUploaded(true, 7)
	statistic.DefaultManager.PushDownloaded(false, 42)
	want := Traffic{Up: 31, Down: 42}
	if got := handleGetTotalTraffic(true); got != want {
		t.Fatalf("proxy totals: %+v, want %+v", got, want)
	}
	if got := handleGetTotalTraffic(false); got != (Traffic{Up: 38, Down: 42}) {
		t.Fatalf("all totals: %+v", got)
	}
}
