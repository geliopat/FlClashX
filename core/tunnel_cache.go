package core

import (
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

func allProxies() map[string]constant.Proxy {
	return tunnel.AllProxies()
}

func invalidateAllProxies() {
	tunnel.InvalidateAllProxies()
}

func providersSnapshot() map[string]cp.ProxyProvider {
	return tunnel.ProvidersSnapshot()
}

func ruleProvidersSnapshot() map[string]cp.RuleProvider {
	return tunnel.RuleProvidersSnapshot()
}
