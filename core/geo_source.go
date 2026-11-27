package core

import (
    "bytes"
    "crypto/sha256"
    "encoding/hex"
    "encoding/json"
    "errors"
    "fmt"
    "io"
    "os"
    "runtime"
    "sync"

    "github.com/metacubex/mihomo/component/geodata"
    "github.com/metacubex/mihomo/config"
    "github.com/oschwald/maxminddb-golang"
)

// Serialize downloads with configuration parsing on Windows. A resource
// updater must not install a file from the previous profile during a switch.
var geoSourceMu sync.Mutex
var errGeoSource = errors.New("geo resource source verification failed")
var errGeoRestart = errors.New("geo resource source changed; restart Mihomo to apply the selected profile")

type geoReceipt struct {
    Source string `json:"source-sha256"`
    Content string `json:"content-sha256"`
}

func geoDigest(data []byte) string {
    sum := sha256.Sum256(data)
    return hex.EncodeToString(sum[:])
}

func geoReceiptPath(path string) string { return path + ".source.json" }
func geoNextPath(path string) string { return path + ".source-next" }

func geoFileDigest(path string) (string, error) {
    file, err := os.Open(path)
    if err != nil { return "", err }
    defer file.Close()
    hash := sha256.New()
    if _, err := io.Copy(hash, file); err != nil { return "", err }
    return hex.EncodeToString(hash.Sum(nil)), nil
}

func geoSourceMatches(path, url string) bool {
    if url == "" { return false }
    data, err := os.ReadFile(geoReceiptPath(path))
    if err != nil { return false }
    var receipt geoReceipt
    if json.Unmarshal(data, &receipt) != nil || receipt.Source != geoDigest([]byte(url)) {
        return false
    }
    digest, err := geoFileDigest(path)
    return err == nil && digest == receipt.Content
}

// Store hashes, never URL credentials. Failure to write the receipt cannot
// make an unverified cache appear valid on the next attempt.
func writeGeoReceipt(path, url string, data []byte) error {
    receipt, err := json.Marshal(geoReceipt{Source: geoDigest([]byte(url)), Content: geoDigest(data)})
    if err != nil { return err }
    target := geoReceiptPath(path)
    temp, err := writeSyncedTemp(target, receipt)
    if err != nil { return err }
    defer os.Remove(temp)
    return os.Rename(temp, target)
}

func promoteVerifiedGeoFile(from, to, url string) error {
    if !geoSourceMatches(from, url) { return fmt.Errorf("staged source no longer verified") }
    if err := os.Rename(from, to); err != nil { return err }
    // If the second rename fails, the new file is deliberately unverified.
    return os.Rename(geoReceiptPath(from), geoReceiptPath(to))
}

func validateGeoSource(name string, data []byte) error {
    if len(data) == 0 { return fmt.Errorf("empty resource") }
    switch name {
    case "MMDB", "ASN":
        reader, err := maxminddb.FromBytes(data)
        if err != nil { return err }
        return reader.Close()
    case "GEOIP", "GEOSITE":
        loader, err := geodata.GetGeoDataLoader("standard")
        if err != nil { return err }
        if name == "GEOIP" {
            _, err = loader.LoadIPByBytes(data, "cn")
        } else {
            _, err = loader.LoadSiteByBytes(data, "cn")
        }
        return err
    default:
        return fmt.Errorf("unknown resource")
    }
}

// A new source is staged separately while a configuration is active.
// Never replace live rule data or mapped databases just to validate a
// different profile. A fresh process promotes only the requested source.
func prepareGeoSource(path, url string, active bool, fetch func(string) ([]byte, error), validate func([]byte) error) error {
    if geoSourceMatches(path, url) { return nil }
    next := geoNextPath(path)
    if !geoSourceMatches(next, url) {
        data, err := fetch(url)
        if err != nil { return fmt.Errorf("%w: download failed", errGeoSource) }
        if err := validate(data); err != nil { return fmt.Errorf("%w: invalid data", errGeoSource) }
        // A legacy file may actually already contain the requested data.
        if existing, err := os.ReadFile(path); err == nil && bytes.Equal(existing, data) {
            if err := writeGeoReceipt(path, url, data); err != nil { return fmt.Errorf("%w: receipt write failed", errGeoSource) }
            return nil
        }
        temp, err := writeSyncedTemp(next, data)
        if err != nil { return fmt.Errorf("%w: staging failed", errGeoSource) }
        defer os.Remove(temp)
        if err := os.Rename(temp, next); err != nil { return fmt.Errorf("%w: staging failed", errGeoSource) }
        if err := writeGeoReceipt(next, url, data); err != nil { return fmt.Errorf("%w: staged receipt failed", errGeoSource) }
    }
    if active { return errGeoRestart }
    if err := promoteVerifiedGeoFile(next, path, url); err != nil {
        return fmt.Errorf("%w: cannot promote verified resource", errGeoSource)
    }
    return nil
}

// The effective raw config contains the resolved URLs, not the UI's
// remembered settings. Unused, missing built-in resources remain lazy;
// existing resources and non-default URLs require verified provenance.
func prepareGeoSources(raw *config.RawConfig) error {
    if runtime.GOOS != "windows" || !isInit.Load() { return nil }
    defaults := config.DefaultRawConfig().GeoXUrl
    urls := raw.GeoXUrl
    entries := []struct{name, url, fallback string}{
        {"MMDB", urls.Mmdb, defaults.Mmdb},
        {"ASN", urls.ASN, defaults.ASN},
        {"GEOIP", urls.GeoIp, defaults.GeoIp},
        {"GEOSITE", urls.GeoSite, defaults.GeoSite},
    }
    restart := false
    for _, entry := range entries {
        resource := geoResources[entry.name]
        path := resource.path()
        if entry.url == "" { continue }
        if entry.url == entry.fallback && !fileExists(path) && !fileExists(geoNextPath(path)) {
            continue
        }
        err := prepareGeoSource(path, entry.url, currentConfig != nil,
            func(url string) ([]byte, error) { return downloadBytes(url, geoDownloadTimeout, skipCertVerify.Load()) },
            func(data []byte) error { return validateGeoSource(entry.name, data) })
        if errors.Is(err, errGeoRestart) { restart = true; continue }
        if err != nil { return fmt.Errorf("%s: %w", entry.name, err) }
    }
    if restart { return errGeoRestart }
    return nil
}
