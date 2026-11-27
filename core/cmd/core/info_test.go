//go:build !android

package main

import (
	"bytes"
	"encoding/json"
	"runtime"
	"testing"
)

func TestCoreInfoContract(t *testing.T) {
	var buf bytes.Buffer
	if err := writeCoreInfo(&buf); err != nil {
		t.Fatal(err)
	}
	var got coreInfo
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Product != "FlClashZ-core" || got.IPCRevision != IPCRevision ||
		got.OS != runtime.GOOS || got.Arch != runtime.GOARCH ||
		got.Version != releaseVersion || got.EngineRevision != engineRevision ||
		got.HostRevision != hostRevision {
		t.Fatalf("unexpected core info: %+v", got)
	}
}
