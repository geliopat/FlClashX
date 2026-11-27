//go:build !android

package main

import (
	"encoding/json"
	"io"
	"runtime"

	"github.com/metacubex/mihomo/constant"
)

// Release metadata is injected only by the standalone core release build.
// Ordinary bundled builds remain usable but are not independent releases.
var (
	releaseVersion = ""
	engineRevision = ""
	hostRevision = ""
)

// IPCRevision describes the desktop method/event contract. A breaking change
// must increment it and be coordinated with the client's supported revisions.
const IPCRevision = 1

type coreInfo struct {
	Product string `json:"product"`
	Version string `json:"version"`
	MihomoVersion string `json:"mihomoVersion"`
	EngineRevision string `json:"engineRevision"`
	HostRevision string `json:"hostRevision"`
	IPCRevision int `json:"ipcRevision"`
	OS string `json:"os"`
	Arch string `json:"arch"`
}

func writeCoreInfo(w io.Writer) error {
	return json.NewEncoder(w).Encode(coreInfo{
		Product: "FlClashZ-core",
		Version: releaseVersion,
		MihomoVersion: constant.Version,
		EngineRevision: engineRevision,
		HostRevision: hostRevision,
		IPCRevision: IPCRevision,
		OS: runtime.GOOS,
		Arch: runtime.GOARCH,
	})
}
