param(
    [ValidateSet("current", "ccs")]
    [string]$Mode = "current",
    [string]$CodexConfigPath = (Join-Path $HOME ".codex\config.toml"),
    [string]$CodexStateDbPath = (Join-Path $HOME ".codex\state_5.sqlite"),
    [string]$CcSwitchDbPath = (Join-Path $HOME ".cc-switch\cc-switch.db")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-PathExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
}

function Invoke-SqlJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Database,
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $raw = & sqlite3 -json $Database $Sql
    if ($LASTEXITCODE -ne 0) {
        throw "sqlite3 query failed."
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
        return $parsed
    }

    return @($parsed)
}

function Invoke-Sql {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Database,
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $Sql | & sqlite3 $Database | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "sqlite3 update failed."
    }
}

function Escape-SqlLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value -replace "'", "''"
}

function Get-CurrentProviderId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $content = Get-Content -LiteralPath $ConfigPath -Raw
    $match = [regex]::Match($content, '(?m)^model_provider\s*=\s*"([^"]+)"\s*$')
    if (-not $match.Success) {
        throw "model_provider not found in $ConfigPath"
    }

    return $match.Groups[1].Value
}

function Normalize-ConfigTextToProvider {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigText,
        [Parameter(Mandatory = $true)]
        [string]$ProviderId
    )

    $normalized = $ConfigText -replace "`r", ""
    $normalized = [regex]::Replace(
        $normalized,
        '(?m)^model_provider\s*=\s*".*?"\s*$',
        ('model_provider = "{0}"' -f $ProviderId)
    )
    $normalized = [regex]::Replace(
        $normalized,
        '(?m)^\[model_providers\.[^\]]+\]\s*$',
        ('[model_providers.{0}]' -f $ProviderId)
    )

    return $normalized
}

Assert-PathExists -Path $CodexConfigPath -Label "Codex config"
Assert-PathExists -Path $CodexStateDbPath -Label "Codex state database"

$updatedCcSwitchProviders = New-Object System.Collections.Generic.List[string]
$targetProvider = $null

if ($Mode -eq "current") {
    $targetProvider = Get-CurrentProviderId -ConfigPath $CodexConfigPath
}

if ($Mode -eq "ccs") {
    Assert-PathExists -Path $CcSwitchDbPath -Label "CC Switch database"
    $targetProvider = "codex"

    $providerRows = Invoke-SqlJson -Database $CcSwitchDbPath -Sql "SELECT id, name, settings_config FROM providers WHERE app_type = 'codex';"
    foreach ($row in $providerRows) {
        $settings = $row.settings_config | ConvertFrom-Json
        if (-not $settings.PSObject.Properties.Name.Contains("config")) {
            continue
        }

        $newConfig = Normalize-ConfigTextToProvider -ConfigText $settings.config -ProviderId $targetProvider
        if ($newConfig -eq $settings.config) {
            continue
        }

        $settings.config = $newConfig
        $newSettingsJson = $settings | ConvertTo-Json -Compress -Depth 10
        $escapedSettings = Escape-SqlLiteral -Value $newSettingsJson
        $escapedId = Escape-SqlLiteral -Value ([string]$row.id)
        Invoke-Sql -Database $CcSwitchDbPath -Sql "UPDATE providers SET settings_config = '$escapedSettings' WHERE id = '$escapedId';"
        $updatedCcSwitchProviders.Add([string]$row.name)
    }

    $liveConfig = Get-Content -LiteralPath $CodexConfigPath -Raw
    $normalizedLiveConfig = Normalize-ConfigTextToProvider -ConfigText $liveConfig -ProviderId $targetProvider
    if ($normalizedLiveConfig -ne $liveConfig) {
        Set-Content -LiteralPath $CodexConfigPath -Value $normalizedLiveConfig -NoNewline
    }
}

$beforeCounts = Invoke-SqlJson -Database $CodexStateDbPath -Sql "SELECT model_provider, COUNT(*) AS count FROM threads GROUP BY model_provider ORDER BY count DESC;"
$rowsToMigrate = Invoke-SqlJson -Database $CodexStateDbPath -Sql "SELECT COUNT(*) AS count FROM threads WHERE model_provider <> '$targetProvider';"
$rowsToMigrateCount = if ($rowsToMigrate.Count -gt 0) { [int]$rowsToMigrate[0].count } else { 0 }

if ($rowsToMigrateCount -gt 0) {
    Invoke-Sql -Database $CodexStateDbPath -Sql "BEGIN IMMEDIATE; UPDATE threads SET model_provider = '$targetProvider' WHERE model_provider <> '$targetProvider'; COMMIT;"
}

$afterCounts = Invoke-SqlJson -Database $CodexStateDbPath -Sql "SELECT model_provider, COUNT(*) AS count FROM threads GROUP BY model_provider ORDER BY count DESC;"

[ordered]@{
    mode = $Mode
    target_provider = $targetProvider
    updated_ccswitch_provider_count = $updatedCcSwitchProviders.Count
    updated_ccswitch_providers = @($updatedCcSwitchProviders)
    migrated_thread_rows = $rowsToMigrateCount
    before_state_counts = $beforeCounts
    after_state_counts = $afterCounts
} | ConvertTo-Json -Depth 10
