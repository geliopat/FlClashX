package core

import (
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/dns"
)

const (
	initiatorRule   = resolver.InitiatorRule
	initiatorProxy  = resolver.InitiatorProxy
	initiatorDirect = resolver.InitiatorDirect
	initiatorApp    = resolver.InitiatorApp
)

type dnsQueryRecord = dns.QueryRecord

// Install once, before requests begin. Do not wrap the package resolvers:
// that hides the concrete Resolvers type from native ClearAll and loses the
// actual upstream, question type, cache hit and caller identity.
func init() {
	dns.DefaultQueryNotify = func(record dns.QueryRecord) {
		if hostWantsEvents() {
			sendMessage(DnsMessage, newDnsQuery(record))
		}
	}
}
