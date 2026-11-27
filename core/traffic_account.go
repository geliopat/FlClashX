package core

import (
	"net"
	"sync"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/proxydialer"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// Keep early inbound ownership separate from native Mihomo statistics. A
// handshake or dial can still be pending when the app stops its listeners.
type accountingTunnel struct {
	constant.Tunnel
}

var trafficTunnel constant.Tunnel = accountingTunnel{tunnel.Tunnel}

// The TUN listener asserts provider.Tunnel without checking and the by-name
// dialer asserts proxydialer.Tunnel, so the wrapper must keep offering what
// embedding constant.Tunnel alone hides.
var (
	_ provider.Tunnel    = accountingTunnel{}
	_ proxydialer.Tunnel = accountingTunnel{}
)

// A connection still resolving or dialing out has no tracker yet, so
// stopping closes these from the client's side too.
var openInbound sync.Map

func (t accountingTunnel) HandleTCPConn(conn net.Conn, metadata *constant.Metadata) {
	accounted := &ownedInboundConn{Conn: conn}
	openInbound.Store(accounted, struct{}{})
	defer openInbound.Delete(accounted)
	// One still in its SOCKS or HTTP handshake when the listeners stopped
	// arrives after the sweep; registered first, it is either swept or sees
	// the stop here. TUN connections die with the device, and Android starts
	// the device before the listeners; probes run whether or not they do.
	if !isRunning.Load() && metadata.Type != constant.TUN && metadata.Type != constant.INNER {
		_ = accounted.Close()
		return
	}
	t.Tunnel.HandleTCPConn(accounted, metadata)
}

func closeOpenInbound() {
	openInbound.Range(func(conn, _ any) bool {
		_ = conn.(*ownedInboundConn).Close()
		return true
	})
}

func (t accountingTunnel) Proxies() map[string]constant.Proxy {
	return tunnel.Proxies()
}

func (t accountingTunnel) Providers() map[string]provider.ProxyProvider {
	return tunnel.ProvidersSnapshot()
}

func (t accountingTunnel) RuleProviders() map[string]provider.RuleProvider {
	return tunnel.RuleProvidersSnapshot()
}

func (t accountingTunnel) RuleUpdateCallback() *utils.Callback[provider.RuleProvider] {
	return tunnel.Tunnel.RuleUpdateCallback()
}

func findTracker(matches func(*statistic.TrackerInfo) bool) statistic.Tracker {
	var found statistic.Tracker
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		if matches(tracker.Info()) {
			found = tracker
			return false
		}
		return true
	})
	return found
}

func onTrackerFound(tracker statistic.Tracker) {
	notifyProbeRoute(tracker)
	if hostWantsEvents() {
		sendMessage(RequestMessage, tracker.Info())
		watchRequestTraffic(tracker)
	}
}

type ownedInboundConn struct {
	net.Conn
}

// Register before the tunnel is used; the core publishes after tracker
// registration. No packet inspection or per-byte lookup is needed.
func init() {
	statistic.DefaultRequestNotify = onTrackerFound
}
