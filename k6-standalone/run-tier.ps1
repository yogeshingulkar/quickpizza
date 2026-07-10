# Run k6 tests by tier. Usage: .\run-tier.ps1 -Tier basic
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("basic", "auth", "websockets", "browser", "grpc", "extensions", "ci")]
    [string]$Tier,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$K6Args
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Load .env
$EnvFile = Join-Path $ScriptDir ".env"
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([^#=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim())
        }
    }
}

$K6Root = if ($env:K6_ROOT) { $env:K6_ROOT } else { Join-Path $ScriptDir "..\k6" }
$BaseUrl = if ($env:BASE_URL) { $env:BASE_URL } else { "http://localhost:3333" }
$K6Path = if ($env:K6_PATH) { $env:K6_PATH } else { "k6" }
$TiersDir = Join-Path $ScriptDir "tiers"

$env:K6_BROWSER_HEADLESS = if ($env:K6_BROWSER_HEADLESS) { $env:K6_BROWSER_HEADLESS } else { "true" }

function Resolve-TierFile([string]$Name) {
    $path = Join-Path $TiersDir "$Name.txt"
    if (-not (Test-Path $path)) { throw "Unknown tier: $Name" }
    return $path
}

function Collect-Tests([string]$File) {
    $tests = @()
    Get-Content $File | ForEach-Object {
        $line = ($_ -split '#')[0].Trim()
        if (-not $line) { return }
        if ($line -like '@include *') {
            $subTier = $line.Substring(9).Trim()
            $tests += Collect-Tests (Resolve-TierFile $subTier)
        } else {
            $tests += $line
        }
    }
    return $tests
}

function Run-Test([string]$Rel) {
    $test = Join-Path $K6Root $Rel
    if (-not (Test-Path $test)) { throw "Missing test file: $test" }
    Write-Host "==> k6 run $Rel"
    & $K6Path run --no-thresholds -e "BASE_URL=$BaseUrl" @K6Args $test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$Tests = Collect-Tests (Resolve-TierFile $Tier)

if ($Tier -eq "ci") {
    foreach ($rel in $Tests) { Run-Test $rel }
    $RepoRoot = Split-Path $ScriptDir -Parent
    Write-Host "==> Building xk6 binary with quickpizzaext"
    if (-not (Get-Command xk6 -ErrorAction SilentlyContinue)) {
        go install go.k6.io/xk6/cmd/xk6@latest
    }
    $Xk6Out = Join-Path $K6Root "extensions\k6.exe"
    if (-not (Test-Path (Join-Path $K6Root "extensions\k6.exe"))) {
        $Xk6Out = Join-Path $K6Root "extensions\k6"
    }
    xk6 build `
        --output $Xk6Out `
        --with "github.com/grafana/quickpizza/extensions/quickpizzaext=$(Join-Path $K6Root 'extensions\quickpizzaext')" `
        --replace "github.com/grafana/quickpizza=$RepoRoot"
    Write-Host "==> k6 run extensions/01.quickpizzaext.js"
    $ExtBin = Join-Path $K6Root "extensions\k6.exe"
    if (-not (Test-Path $ExtBin)) { $ExtBin = Join-Path $K6Root "extensions\k6" }
    & $ExtBin run --no-thresholds -e "BASE_URL=$BaseUrl" (Join-Path $K6Root "extensions\01.quickpizzaext.js")
    exit $LASTEXITCODE
}

if ($Tier -eq "extensions") {
    Write-Host "Note: extensions tier may need custom xk6 binaries. See README.md." -ForegroundColor Yellow
}

foreach ($rel in $Tests) { Run-Test $rel }
Write-Host "Tier '$Tier' completed ($($Tests.Count) tests)."
