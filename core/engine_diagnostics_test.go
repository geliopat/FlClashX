package core

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
)

func TestNativeDiagnosticsSettingsAndCapabilityContract(t *testing.T) {
	resetEngineDiagnostics()
	t.Cleanup(resetEngineDiagnostics)
	wanted := engineDiagnosticsSettings{ClosedFlowCapacity:8,ChainDiagnostics:true}
	actual,err:=handleSetEngineDiagnostics(wanted)
	if err!=nil || actual!=wanted {t.Fatalf("settings: %+v %v",actual,err)}
	if _,err:=handleSetEngineDiagnostics(engineDiagnosticsSettings{ClosedFlowCapacity:1025});err==nil {
		t.Fatal("accepted oversized history")
	}
	snapshot:=handleGetEngineDiagnostics()
	if snapshot.Settings!=wanted || snapshot.Closed==nil || snapshot.Chains==nil {
		t.Fatalf("unexpected snapshot: %+v",snapshot)
	}
	var response MethodResponse
	if err:=json.Unmarshal(handleMethodCall(&MethodCall{ID:"test",Method:getCoreCapabilitiesMethod}),&response);err!=nil || response.Error!=nil {
		t.Fatalf("capability RPC: %+v %v",response,err)
	}
	resetEngineDiagnostics()
	if handleGetEngineDiagnostics().Settings!=(engineDiagnosticsSettings{}) {t.Fatal("diagnostics did not stop")}
}

func TestChainHealthOwnerSourceIntegration(t *testing.T) {
	if !chainHealthAvailable() {t.Skip("published engine does not expose the additive source API")}
	proxy,err:=adapter.ParseProxy(map[string]any{
		"name":"owner", "type":"vless", "server":"backend.example", "port":443,
		"uuid":"01234567-89ab-cdef-0123-456789abcdef", "dialer-proxy":"front",
	},adapter.WithProviderName("provider"))
	if err!=nil {t.Fatal(err)}
	defer proxy.Close()
	owner,dialer,factory,ok:=describeChainHealthOwner(proxy)
	if !ok || owner.Name!="owner" || owner.Group!="front" || owner.Provider!="provider" || owner.Identity=="" || dialer==nil || factory==nil {
		t.Fatalf("live source not identified: %+v",owner)
	}
}

func TestChainHealthReportsIgnoreReplacedJobs(t *testing.T) {
	const name = "refactor-test-chain"
	old := &chainHealthJob{}
	active := &chainHealthJob{}
	chainHealthJobs.Lock()
	previous := chainHealthJobs.jobs[name]
	chainHealthJobs.jobs[name] = active
	chainHealthJobs.Unlock()
	t.Cleanup(func() {
		chainHealthJobs.Lock()
		defer chainHealthJobs.Unlock()
		if previous == nil {
			delete(chainHealthJobs.jobs, name)
		} else {
			chainHealthJobs.jobs[name] = previous
		}
	})

	reportChainHealth(name, old, []outboundgroup.ChainProbeResult{{Member: "old"}}, errors.New("old"))
	finishChainHealth(name, old)
	results := []outboundgroup.ChainProbeResult{{Member: "current", Healthy: true}}
	reportChainHealth(name, active, results, nil)
	results[0].Member = "mutated"
	chainHealthJobs.Lock()
	defer chainHealthJobs.Unlock()
	if chainHealthJobs.jobs[name] != active || len(active.status.Results) != 1 ||
		active.status.Results[0].Member != "current" || active.status.Error != "" ||
		len(old.status.Results) != 0 {
		t.Fatal("stale job or caller-owned results altered the active snapshot")
	}
}

type testRetiringChainGroup struct {
	nativeChainHealthGroup
	enabled bool
}

func (g *testRetiringChainGroup) SetChainHealthEnabled(enabled bool) {
	g.enabled = enabled
}

func TestChainHealthRetainsCancelledSchedulerSlot(t *testing.T) {
	const name = "retiring-test-chain"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	group := &testRetiringChainGroup{enabled: true}
	job := &chainHealthJob{group: group, cancel: cancel}
	chainHealthJobs.Lock()
	chainHealthJobs.jobs[name] = job
	stopChainHealthLocked(name)
	retiring := chainHealthJobs.retiring[name]
	active := chainHealthJobs.jobs[name]
	chainHealthJobs.Unlock()
	t.Cleanup(func() {
		chainHealthJobs.Lock()
		defer chainHealthJobs.Unlock()
		delete(chainHealthJobs.jobs, name)
		delete(chainHealthJobs.retiring, name)
	})
	if active != nil || retiring != job || ctx.Err() == nil || group.enabled {
		t.Fatal("cancelled job released native scheduler ownership before exit")
	}
	finishChainHealth(name, &chainHealthJob{})
	chainHealthJobs.Lock()
	retiring = chainHealthJobs.retiring[name]
	chainHealthJobs.Unlock()
	if retiring != job {
		t.Fatal("stale completion released another worker's slot")
	}
	finishChainHealth(name, job)
	chainHealthJobs.Lock()
	retiring = chainHealthJobs.retiring[name]
	chainHealthJobs.Unlock()
	if retiring != nil {
		t.Fatal("completed worker retained scheduler ownership")
	}
}
