//go:build ignore

// Standalone signer; run only in the release job, never in the build job.
package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type identity struct {
	Product string `json:"product"`
	Version string `json:"version"`
	MihomoVersion string `json:"mihomoVersion"`
	EngineRevision string `json:"engineRevision"`
	HostRevision string `json:"hostRevision"`
	IPCRevision int `json:"ipcRevision"`
	OS string `json:"os"`
	Arch string `json:"arch"`
}

type manifest struct {
	identity
	Schema int `json:"schema"`
	Name string `json:"name"`
	Size int64 `json:"size"`
	SHA256 string `json:"sha256"`
	URL string `json:"url"`
	Signature string `json:"signature"`
}

var versionPattern = regexp.MustCompile(`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-z\.[1-9][0-9]*$`)
var revisionPattern = regexp.MustCompile(`^[0-9a-f]{40}$`)

func fail(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func main() {
	dir := flag.String("dir", "", "directory containing the binary and core-info.json")
	version := flag.String("version", "", "independent core version")
	engine := flag.String("engine", "", "Mihomo commit")
	host := flag.String("host", "", "host adapter commit")
	flag.Parse()
	if *dir == "" || !versionPattern.MatchString(*version) ||
		!revisionPattern.MatchString(*engine) || !revisionPattern.MatchString(*host) {
		fail(fmt.Errorf("invalid release inputs"))
	}
	data, err := os.ReadFile(filepath.Join(*dir, "core-info.json"))
	fail(err)
	var id identity
	fail(json.Unmarshal(data, &id))
	if id.Product != "FlClashZ-core" || id.Version != *version ||
		id.MihomoVersion != strings.Split(*version, "-")[0] ||
		id.EngineRevision != *engine || id.HostRevision != *host ||
		id.IPCRevision != 1 || id.OS != "windows" || id.Arch != "amd64" {
		fail(fmt.Errorf("unexpected artifact identity"))
	}

	const name = "FlClashCore.exe"
	file, err := os.Open(filepath.Join(*dir, name))
	fail(err)
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, file)
	fail(err)
	if size <= 0 || size > 256*1024*1024 {
		fail(fmt.Errorf("invalid executable size"))
	}
	m := manifest{
		identity: id, Schema: 1, Name: name, Size: size,
		SHA256: hex.EncodeToString(hash.Sum(nil)),
		URL: "https://github.com/geliopat/Clash.Meta/releases/download/flclashz-core-" + *version + "/" + name,
	}

	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(os.Getenv("CORE_SIGNING_KEY")))
	if err != nil || len(seed) != ed25519.SeedSize {
		fail(fmt.Errorf("UPDATE_SIGNING_KEY must be a base64 Ed25519 seed"))
	}
	public, err := base64.StdEncoding.DecodeString(strings.TrimSpace(os.Getenv("CORE_PUBLIC_KEY")))
	if err != nil || len(public) != ed25519.PublicKeySize {
		fail(fmt.Errorf("FLCLASHZ_UPDATE_PUBLIC_KEY is missing or invalid"))
	}
	key := ed25519.NewKeyFromSeed(seed)
	if !key.Public().(ed25519.PublicKey).Equal(ed25519.PublicKey(public)) {
		fail(fmt.Errorf("signing seed does not match pinned public key"))
	}
	// Canonical ASCII/UTF-8 lines with a final newline. The URL is intentionally
	// not signed: trusted manifests may be mirrored, but bytes cannot change.
	message := fmt.Sprintf("flclashz-core-manifest-v1\n%d\n%s\n%s\n%s\n%s\n%s\n%d\n%s\n%s\n%s\n%d\n%s\n",
		m.Schema, m.Product, m.Version, m.MihomoVersion, m.EngineRevision,
		m.HostRevision, m.IPCRevision, m.OS, m.Arch, m.Name, m.Size, m.SHA256)
	m.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(key, []byte(message)))
	out, err := json.MarshalIndent(m, "", "  ")
	fail(err)
	fail(os.WriteFile(filepath.Join(*dir, "core-manifest.json"), append(out, '\n'), 0644))
}
