package core

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/constant"
)

func urlTest(t *testing.T, proxy constant.Proxy, url string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), defaultDelayTestTimeout)
	defer cancel()
	_, _ = proxy.URLTest(ctx, url, anyDelayTestStatus)
}

// mihomo measures whole milliseconds and reads a zero as a failed check, so
// the server must take at least one.
func noContentAfterAMillisecond(w http.ResponseWriter, _ *http.Request) {
	time.Sleep(2 * time.Millisecond)
	w.WriteHeader(http.StatusNoContent)
}

func TestNativeDelayHookReportsCommittedHistory(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(noContentAfterAMillisecond))
	defer server.Close()
	proxy := namedProxy("node")
	previous := adapter.UrlTestHook
	t.Cleanup(func() { adapter.UrlTestHook = previous })
	var events []nativeDelayEvent
	adapter.UrlTestHook = func(p *adapter.Proxy, url string, record constant.DelayHistory, timedOut bool) {
		events = append(events, nativeDelayEvent{proxy: p, url: url, record: record, timedOut: timedOut})
	}
	urlTest(t, proxy, server.URL)
	if len(events) != 1 || events[0].proxy != proxy || events[0].record.Delay == 0 {
		t.Fatalf("unexpected native events: %+v", events)
	}
	history := proxy.ExtraDelayHistories()[server.URL].History
	if len(history) == 0 || !history[len(history)-1].Time.Equal(events[0].record.Time) {
		t.Fatal("event published before URL history was committed")
	}
}

func TestNativeDelayRejectsOldSameNameProxyAndOldRecords(t *testing.T) {
	old := namedProxy("same")
	current := namedProxy("same")
	w := &delayWatch{}
	now := time.Now()
	record := constant.DelayHistory{Time: now, Delay: 10}
	if got := w.accept(nativeDelayEvent{proxy: old, url: "u", record: record}, current, true); got != nil {
		t.Fatalf("event from replaced proxy accepted: %+v", got)
	}
	event := nativeDelayEvent{proxy: current, url: "u", record: record}
	if got := w.accept(event, current, true); got == nil || got.Value != 10 {
		t.Fatalf("current event: %+v", got)
	}
	if got := w.accept(event, current, true); got != nil {
		t.Fatal("duplicate event accepted")
	}
	event.record.Time = now.Add(-time.Second)
	if got := w.accept(event, current, true); got != nil {
		t.Fatal("out-of-order event accepted")
	}
}

func TestNativeDelayCanRefineRecoveredFailure(t *testing.T) {
	proxy := namedProxy("node")
	w := &delayWatch{}
	event := nativeDelayEvent{proxy: proxy, url: "u", record: constant.DelayHistory{Time: time.Now()}}
	if got := w.accept(event, proxy, false); got == nil || got.Value != delayFailed {
		t.Fatalf("history without timeout metadata: %+v", got)
	}
	event.timedOut = true
	if got := w.accept(event, proxy, true); got == nil || got.Value != delayTimedOut {
		t.Fatalf("native timeout: %+v", got)
	}
}

func TestNativeDelayOverflowRequestsOneReconciliation(t *testing.T) {
	w := &delayWatch{events: make(chan nativeDelayEvent, 1), reconcile: make(chan struct{}, 1)}
	for range 100 {
		w.enqueue(nativeDelayEvent{})
	}
	if len(w.events) != 1 || len(w.reconcile) != 1 {
		t.Fatal("native delay queue did not remain bounded")
	}
}
