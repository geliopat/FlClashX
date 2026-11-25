$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Root = Split-Path -Parent $PSScriptRoot
$AssetDir = Join-Path $Root "windows\zapret"
$TempRoot = Join-Path $env:TEMP ("flclashx-zapret-" + [Guid]::NewGuid().ToString("N"))
$Zapret2Zip = Join-Path $TempRoot "zapret2.zip"
$FlowsealZip = Join-Path $TempRoot "flowseal.zip"
$Zapret2Extract = Join-Path $TempRoot "zapret2"
$FlowsealExtract = Join-Path $TempRoot "flowseal"
$Zapret2Version = "v1.0.8"
$Zapret2Url = "https://github.com/bol-van/zapret2/releases/download/$Zapret2Version/zapret2-$Zapret2Version.zip"
$Zapret2Sha256 = "f2b84934a72536ec0ab4fdf71881a7d596ba67aef3f241dc8c9bc6260e534dd2"
$FlowsealVersion = "1.10.4"
$FlowsealUrl = "https://github.com/Flowseal/zapret-discord-youtube/releases/download/$FlowsealVersion/zapret-discord-youtube-$FlowsealVersion.zip"
$FlowsealSha256 = "291af673bd0238506f9548e0e94ca0abf244000f4c9a06960544fb01c5f97b34"
$ZapretSourceCommit = "8dd17fcbcca405a50f497a6e2346ca263901d775"
# Shared Lua libraries carry upstream fixes on top of this GUI base.
$LuaLibraryVersion = "v1.0.8"
$ZapretSourceBase = "https://raw.githubusercontent.com/geliopat/zapret2-gui/$ZapretSourceCommit"

function Get-PinnedArchive {
    param([string]$Url, [string]$Path, [string]$ExpectedSha256, [string]$Label)
    Write-Host "Downloading $Label..."
    Invoke-WebRequest -Uri $Url -OutFile $Path
    $Actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "SHA256 mismatch for $Label. Expected $ExpectedSha256, got $Actual."
    }
    Write-Host "Verified SHA256: $Label"
}

try {
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $AssetDir -Force | Out-Null
    Get-ChildItem -Path $AssetDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

    Get-PinnedArchive -Url $Zapret2Url -Path $Zapret2Zip -ExpectedSha256 $Zapret2Sha256 -Label "bol-van/zapret2 $Zapret2Version"
    Expand-Archive -Path $Zapret2Zip -DestinationPath $Zapret2Extract -Force
    $Zapret2Bin = Get-ChildItem -Path $Zapret2Extract -Recurse -Directory | Where-Object { $_.Name -ieq "windows-x86_64" } | Select-Object -First 1
    if (-not $Zapret2Bin) { throw "The zapret2 archive has no windows-x86_64 binary directory." }
    Get-ChildItem -Path $Zapret2Bin.FullName -File | ForEach-Object { Copy-Item -Path $_.FullName -Destination $AssetDir -Force }

    Get-PinnedArchive -Url $FlowsealUrl -Path $FlowsealZip -ExpectedSha256 $FlowsealSha256 -Label "Flowseal/zapret-discord-youtube $FlowsealVersion"
    Expand-Archive -Path $FlowsealZip -DestinationPath $FlowsealExtract -Force
    $FlowsealEngine = Get-ChildItem -Path $FlowsealExtract -Recurse -File -Filter "winws.exe" | Select-Object -First 1
    if (-not $FlowsealEngine) { throw "The Flowseal archive has no winws.exe." }
    Copy-Item -Path $FlowsealEngine.FullName -Destination (Join-Path $AssetDir "winws.exe") -Force

    $ListsDir = Join-Path $AssetDir "lists"
    New-Item -ItemType Directory -Path $ListsDir -Force | Out-Null
    $FlowsealLists = Get-ChildItem -Path $FlowsealExtract -Recurse -Directory -Filter "lists" | Select-Object -First 1
    if ($FlowsealLists) {
        Get-ChildItem -Path $FlowsealLists.FullName -File | ForEach-Object { Copy-Item -Path $_.FullName -Destination $ListsDir -Force }
    }

    $StrategySource = Join-Path $Root "services\helper\strategies"
    $StrategyDir = Join-Path $AssetDir "strategies"
    New-Item -ItemType Directory -Path $StrategyDir -Force | Out-Null

    # Keep the original zapret2-gui directory structure in the installed bundle.
    # The root copies are retained because the flagship and imported profiles
    # load the shared Lua libraries from the engine working directory.
    $LuaFiles = @("zapret-lib.lua","zapret-antidpi.lua","zapret-auto.lua","zapret-discord-light.lua","zapret-extsplit.lua","zapret-firstbyte.lua","zapret-ipfrag.lua","zapret-obfs.lua","zapret-pcap.lua","zapret-sites-light.lua","zapret-syndata.lua","zapret-tests.lua","zapret-tspu-max.lua","zapret-yt4k.lua")
    foreach ($Name in $LuaFiles) {
        $SourcePath = Join-Path $StrategySource $Name
        if (-not (Test-Path $SourcePath -PathType Leaf)) { throw "Bundled Lua strategy is missing: $SourcePath" }
        Copy-Item -Path $SourcePath -Destination (Join-Path $AssetDir $Name) -Force
        Copy-Item -Path $SourcePath -Destination (Join-Path $StrategyDir $Name) -Force
        if ((Get-Item (Join-Path $StrategyDir $Name)).Length -eq 0) { throw "Bundled Lua strategy is empty: $Name" }
    }

    $ImportedSource = Join-Path $StrategySource "imported"
    if (-not (Test-Path (Join-Path $ImportedSource "kinlay0") -PathType Container)) {
        throw "The pinned kinlay0 strategy folder is missing."
    }
    Copy-Item -Path $ImportedSource -Destination $StrategyDir -Recurse -Force
    $ImportedBatFiles = @(Get-ChildItem -Path (Join-Path $StrategyDir "imported\kinlay0") -File -Filter "*.bat")
    if ($ImportedBatFiles.Count -ne 26) {
        throw "Expected 26 pinned kinlay0 BAT strategies, found $($ImportedBatFiles.Count)."
    }
    foreach ($RequiredStrategy in @("zapret-antidpi.lua","zapret-discord-light.lua","zapret-extsplit.lua","zapret-firstbyte.lua","zapret-ipfrag.lua","zapret-sites-light.lua","zapret-syndata.lua","zapret-tspu-max.lua","zapret-yt4k.lua")) {
        if (-not (Test-Path (Join-Path $StrategyDir $RequiredStrategy) -PathType Leaf)) {
            throw "Required built-in Lua strategy is missing: $RequiredStrategy"
        }
    }
    foreach ($RequiredSource in @("translate.py","README.md","LICENSE")) {
        if (-not (Test-Path (Join-Path (Join-Path $StrategyDir "imported\kinlay0") $RequiredSource) -PathType Leaf)) {
            throw "Required kinlay0 source file is missing: $RequiredSource"
        }
    }

    $BlobFiles = @("ACTIVE_DISCORD_UDP.bin","ACTIVE_GAME_UDP.bin","quic_initial_4pda_to.bin","quic_initial_5ka_ru.bin","quic_initial_lemana_pro.bin","quic_initial_rutube_ru.bin","quic_initial_steam_chat_com.bin","quic_initial_steamcommunity_com.bin","quic_initial_steamstatic_com.bin","quic_initial_tencent_com.bin","quic_initial_www_google_com.bin","stun.bin","stun2.bin","tls_clienthello_4pda_to.bin","tls_clienthello_5ka_ru.bin","tls_clienthello_awswaf_com.bin","tls_clienthello_max_ru.bin","tls_clienthello_retext_ai.bin","tls_clienthello_sochi_park.bin","tls_clienthello_steam_chat_com.bin","tls_clienthello_steamstatic_com.bin","tls_clienthello_teamspeak_com.bin","tls_clienthello_www_google_com.bin","tls_clienthello_www_sferum_ru.bin")
    foreach ($Name in $BlobFiles) {
        $Path = Join-Path $AssetDir $Name
        Invoke-WebRequest -Uri "$ZapretSourceBase/bin/$Name" -OutFile $Path
        if ((Get-Item $Path).Length -eq 0) { throw "Downloaded payload is empty: $Name" }
    }

    $ListFiles = @("ipset-all.txt","ipset-exclude.txt","ipset-exclude-user.txt","list-exclude.txt","list-exclude-user.txt","list-general.txt","list-general-user.txt","list-google.txt")
    foreach ($Name in $ListFiles) {
        $Path = Join-Path $ListsDir $Name
        try {
            Invoke-WebRequest -Uri "$ZapretSourceBase/lists/$Name" -OutFile $Path
        } catch {
            if ($Name.EndsWith("-user.txt")) { [System.IO.File]::WriteAllText($Path, "") } else { throw }
        }
    }

    $Required = @("winws2.exe","winws.exe","WinDivert.dll","WinDivert64.sys","cygwin1.dll","zapret-lib.lua","zapret-antidpi.lua","ACTIVE_DISCORD_UDP.bin","quic_initial_www_google_com.bin","tls_clienthello_www_google_com.bin","tls_clienthello_max_ru.bin","stun2.bin")
    foreach ($Name in $Required) {
        $Path = Join-Path $AssetDir $Name
        if (-not (Test-Path $Path -PathType Leaf) -or (Get-Item $Path).Length -eq 0) { throw "Required Zapret asset is missing or empty: $Name" }
    }
    # Record successfully staged components. User-editable lists are excluded.
    $LuaHashes = [ordered]@{}
    foreach ($Name in $LuaFiles) {
        foreach ($Relative in @($Name, "strategies/$Name")) {
            $LuaHashes[$Relative] = (Get-FileHash -LiteralPath (Join-Path $AssetDir $Relative) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    foreach ($File in (Get-ChildItem -LiteralPath (Join-Path $StrategyDir "imported") -Recurse -File -Filter "*.bat" | Sort-Object FullName)) {
        $Relative = $File.FullName.Substring($AssetDir.Length + 1).Replace('\', '/')
        $LuaHashes[$Relative] = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    foreach ($Name in $BlobFiles) {
        $LuaHashes[$Name] = (Get-FileHash -LiteralPath (Join-Path $AssetDir $Name) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    # The client must not install a strategy pack whose compiled catalog differs.
    $CatalogParts = @("services/helper/src/service/zapret.rs", "services/helper/src/service/zapret/imported_strategies.rs") | ForEach-Object {
        $Hash = (git -C $Root rev-parse "HEAD:$_")
        if ($LASTEXITCODE -ne 0 -or $Hash -notmatch '^[a-f0-9]{40}$') { throw "Cannot identify strategy catalog: $_" }
        $Hash
    }
    $EngineHashes = [ordered]@{}
    foreach ($Name in @("winws2.exe", "WinDivert.dll", "WinDivert64.sys", "cygwin1.dll")) {
        $EngineHashes[$Name] = (Get-FileHash -LiteralPath (Join-Path $AssetDir $Name) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $Manifest = [ordered]@{
        schema = 1
        catalogAbi = ($CatalogParts -join ':')
        components = [ordered]@{
            Zapret2 = [ordered]@{
                version = $Zapret2Version
                archiveSha256 = $Zapret2Sha256
                files = $EngineHashes
            }
            Flowseal = [ordered]@{
                version = $FlowsealVersion
                archiveSha256 = $FlowsealSha256
                files = [ordered]@{ "winws.exe" = (Get-FileHash -LiteralPath (Join-Path $AssetDir "winws.exe") -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
            "Lua/BAT source" = [ordered]@{
                version = $ZapretSourceCommit
                luaLibraryVersion = $LuaLibraryVersion
                files = $LuaHashes
            }
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $AssetDir "versions.json"), ($Manifest | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Zapret component versions manifest created"
    Write-Host "Zapret2 and Flowseal Windows assets staged in $AssetDir"
} finally {
    if (Test-Path $TempRoot) { Remove-Item -Path $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
