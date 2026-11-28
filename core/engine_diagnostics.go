package core

import (
	"sync"

	"github.com/metacubex/mihomo/component/proxydialer"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// These are process-local, opt-in diagnostics. The engine owns the bounded
// rings; the adapter never holds live trackers or introduces another history.
type engineDiagnosticsSettings struct {
	ClosedFlowCapacity int  `json:"closedFlowCapacity"`
	ChainDiagnostics   bool `json:"chainDiagnostics"`
}

type engineDiagnosticsSnapshot struct {
	Settings engineDiagnosticsSettings          `json:"settings"`
	Closed   []statistic.ClosedFlow              `json:"closed"`
	Chains   []proxydialer.ChainDialObservation  `json:"chains"`
}

var engineDiagnostics struct {
	sync.Mutex
	settings engineDiagnosticsSettings
}

func handleCoreCapabilities() []string {
	return []string{"closed-flow-history-v1", "chain-diagnostics-v1", "dns-stages-v1"}
}

func handleSetEngineDiagnostics(settings engineDiagnosticsSettings) (engineDiagnosticsSettings, error) {
	engineDiagnostics.Lock()
	defer engineDiagnostics.Unlock()
	old := engineDiagnostics.settings
	if settings.ClosedFlowCapacity != old.ClosedFlowCapacity {
		if err := statistic.DefaultManager.SetClosedFlowHistoryCapacity(settings.ClosedFlowCapacity); err != nil {
			return old, err
		}
	}
	if settings.ChainDiagnostics != old.ChainDiagnostics {
		proxydialer.EnableChainDiagnostics(settings.ChainDiagnostics)
	}
	engineDiagnostics.settings = settings
	return settings, nil
}

func handleGetEngineDiagnostics() engineDiagnosticsSnapshot {
	engineDiagnostics.Lock()
	defer engineDiagnostics.Unlock()
	return engineDiagnosticsSnapshot{
		Settings: engineDiagnostics.settings,
		Closed: statistic.DefaultManager.ClosedFlowHistory(),
		Chains: proxydialer.ChainDiagnosticsSnapshot(),
	}
}

func resetEngineDiagnostics() {
	_, _ = handleSetEngineDiagnostics(engineDiagnosticsSettings{})
}
