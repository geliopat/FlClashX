package core

import (
	"encoding/json"
	"testing"

	"github.com/metacubex/mihomo/adapter"
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
