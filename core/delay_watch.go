package core

import (
	"context"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/constant"
)

const delayEventCapacity = 256

type delayRecordKey struct {
	name, url string
}

type nativeDelayEvent struct {
	proxy constant.Proxy
	url string
	record constant.DelayHistory
	timedOut bool
}

type seenDelay struct {
	proxy constant.Proxy
	at time.Time
	value int32
	native bool
}

// A single session owns its seen records. A new profile or host reactivation
// starts a fresh session, recovering the latest histories once. In steady state
// the native hook wakes the worker, not a timer over every configured node.
type delayWatch struct {
	seen map[delayRecordKey]seenDelay
	events chan nativeDelayEvent
	reconcile chan struct{}
	cancel context.CancelFunc
}

var delayWatcher struct {
	sync.Mutex
	session *delayWatch
}

func init() {
	adapter.UrlTestHook = func(proxy *adapter.Proxy, url string, record constant.DelayHistory, timedOut bool) {
		if !hostWantsEvents() || isProxyGroupType(proxy.Type()) {
			return
		}
		delayWatcher.Lock()
		session := delayWatcher.session
		delayWatcher.Unlock()
		if session != nil {
			session.enqueue(nativeDelayEvent{proxy: proxy, url: url, record: record, timedOut: timedOut})
		}
	}
}

func (w *delayWatch) enqueue(event nativeDelayEvent) {
	select {
	case w.events <- event:
	default:
		// The hook must not block a health check or grow an unbounded queue.
		// Recover the current histories after a burst, coalescing overflow.
		select {
		case w.reconcile <- struct{}{}:
		default:
		}
	}
}

func startDelayWatch() {
	delayWatcher.Lock()
	defer delayWatcher.Unlock()
	if previous := delayWatcher.session; previous != nil {
		previous.cancel()
		delayWatcher.session = nil
	}
	if !hostActive.Load() {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	w := &delayWatch{
		seen: make(map[delayRecordKey]seenDelay),
		events: make(chan nativeDelayEvent, delayEventCapacity),
		reconcile: make(chan struct{}, 1),
		cancel: cancel,
	}
	delayWatcher.session = w
	go w.run(ctx)
}

func stopDelayWatch() {
	delayWatcher.Lock()
	defer delayWatcher.Unlock()
	if previous := delayWatcher.session; previous != nil {
		previous.cancel()
		delayWatcher.session = nil
	}
}

// A lazy check skips its tick on an idle tunnel; a touch lets the first run.
func touchProviders() {
	for _, provider := range providersSnapshot() {
		provider.Touch()
	}
}

func (w *delayWatch) run(ctx context.Context) {
	w.recoverHistories(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-w.reconcile:
			w.recoverHistories(ctx)
		case event := <-w.events:
			// Applying a profile and checking identity must not interleave.
			configMu.Lock()
			if ctx.Err() == nil && hostWantsEvents() {
				if result := w.accept(event, lookupProxy(event.proxy.Name()), true); result != nil {
					sendMessage(DelayMessage, result)
				}
			}
			configMu.Unlock()
		}
	}
}

func (w *delayWatch) recoverHistories(ctx context.Context) {
	configMu.Lock()
	defer configMu.Unlock()
	if ctx.Err() != nil || !hostWantsEvents() {
		return
	}
	live := make(map[delayRecordKey]seenDelay)
	for name, proxy := range allProxies() {
		if isProxyGroupType(proxy.Type()) {
			continue
		}
		for url, state := range proxy.ExtraDelayHistories() {
			if len(state.History) == 0 {
				continue
			}
			record := state.History[len(state.History)-1]
			// Histories do not contain a timeout bit. Do not fabricate one;
			// a subsequent native event can refine an equally timed record.
			if result := w.accept(nativeDelayEvent{proxy: proxy, url: url, record: record}, proxy, false); result != nil {
				sendMessage(DelayMessage, result)
			}
			key := delayRecordKey{name: name, url: url}
			live[key] = w.seen[key]
		}
	}
	w.seen = live
}

func (w *delayWatch) accept(event nativeDelayEvent, current constant.Proxy, native bool) *Delay {
	if current == nil || current != event.proxy || isProxyGroupType(current.Type()) {
		return nil
	}
	key := delayRecordKey{name: current.Name(), url: event.url}
	value := delayValue(event.record.Delay, event.timedOut)
	if w.seen == nil {
		w.seen = make(map[delayRecordKey]seenDelay)
	}
	if old, ok := w.seen[key]; ok && old.proxy == current {
		if event.record.Time.Before(old.at) {
			return nil
		}
		if event.record.Time.Equal(old.at) && (!native || old.native || old.value == value) {
			// Remember native provenance even when it adds no visible change.
			if native && event.record.Time.Equal(old.at) && old.value == value {
				old.native = true
				w.seen[key] = old
			}
			return nil
		}
	}
	w.seen[key] = seenDelay{proxy: current, at: event.record.Time, value: value, native: native}
	return &Delay{Name: current.Name(), Url: event.url, Value: value}
}
