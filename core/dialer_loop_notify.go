package core

import (
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/component/proxydialer"
)

var lastLoopNotification atomic.Int64

func init() {
	proxydialer.DefaultLoopNotify = func(name string) {
		if !hostWantsEvents() {
			return
		}
		now := time.Now().UnixNano()
		last := lastLoopNotification.Load()
		if last != 0 && now-last < int64(3*time.Second) {
			return
		}
		if lastLoopNotification.CompareAndSwap(last, now) {
			sendMessage(DialerLoopMessage, name)
		}
	}
}
