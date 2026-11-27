package core

import (
    "errors"
    "os"
    "path/filepath"
    "testing"
)

func TestGeoSourceReceiptAndSafeProfileSwitch(t *testing.T) {
    path := filepath.Join(t.TempDir(), "GeoSite.dat")
    old, next := []byte("old source"), []byte("new source")
    if err := os.WriteFile(path, old, 0600); err != nil { t.Fatal(err) }
    if err := writeGeoReceipt(path, "https://a.example/data", old); err != nil { t.Fatal(err) }
    fetches := 0
    fetch := func(url string) ([]byte, error) {
        fetches++
        if url != "https://b.example/data" { t.Fatalf("unexpected source %s", url) }
        return next, nil
    }
    validate := func([]byte) error { return nil }
    if err := prepareGeoSource(path, "https://b.example/data", true, fetch, validate); !errors.Is(err, errGeoRestart) { t.Fatalf("want restart, got %v", err) }
    if !geoSourceMatches(path, "https://a.example/data") || geoSourceMatches(path, "https://b.example/data") { t.Fatal("active resource changed") }
    if err := prepareGeoSource(path, "https://b.example/data", false, fetch, validate); err != nil { t.Fatal(err) }
    if fetches != 1 || !geoSourceMatches(path, "https://b.example/data") { t.Fatal("staged resource not reused") }
    if err := os.WriteFile(path, []byte("tampered"), 0600); err != nil { t.Fatal(err) }
    if geoSourceMatches(path, "https://b.example/data") { t.Fatal("tampering accepted") }
}

func TestGeoSourceFailureLeavesOldBytesUntouched(t *testing.T) {
    path := filepath.Join(t.TempDir(), "GeoIP.dat")
    if err := os.WriteFile(path, []byte("original"), 0600); err != nil { t.Fatal(err) }
    fetch := func(string) ([]byte, error) { return nil, errors.New("offline") }
    if err := prepareGeoSource(path, "https://b.example/data", true, fetch, func([]byte) error { return nil }); !errors.Is(err, errGeoSource) { t.Fatalf("want source error, got %v", err) }
    data, err := os.ReadFile(path)
    if err != nil || string(data) != "original" { t.Fatal("original file changed") }
    if geoSourceMatches(path, "https://b.example/data") { t.Fatal("unverified source accepted") }
}

func TestGeoSourceLegacyIdenticalBytesDoNotRequireRestart(t *testing.T) {
    path := filepath.Join(t.TempDir(), "GeoIP.dat")
    data := []byte("same")
    if err := os.WriteFile(path, data, 0600); err != nil { t.Fatal(err) }
    if err := prepareGeoSource(path, "https://a.example/data", true, func(string) ([]byte, error) { return data, nil }, func([]byte) error { return nil }); err != nil { t.Fatal(err) }
    if !geoSourceMatches(path, "https://a.example/data") { t.Fatal("receipt missing") }
}
