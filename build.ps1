[CmdletBinding()]
param(
    [switch]$Program,
    [switch]$Flash,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Flash -and -not $Program) {
    throw '-Flash requires -Program. Use .\build.ps1 -Program -Flash to write onboard flash.'
}

$projectRoot = $PSScriptRoot
$buildDir = Join-Path $projectRoot 'build'
$rtlDir = Join-Path $projectRoot 'rtl'
$cst = Join-Path $projectRoot 'constraints\tangnano20k.cst'
$sources = @(Get-ChildItem -LiteralPath $rtlDir -File | Where-Object { $_.Extension -in '.v', '.sv' } | Sort-Object FullName)

if ($Clean -and (Test-Path -LiteralPath $buildDir)) {
    $resolvedBuild = [IO.Path]::GetFullPath($buildDir)
    $resolvedRoot = [IO.Path]::GetFullPath($projectRoot) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedBuild.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove build directory outside project: $resolvedBuild"
    }
    Remove-Item -LiteralPath $resolvedBuild -Recurse -Force
}

if ($sources.Count -eq 0) { throw "No Verilog/SystemVerilog source files found under $rtlDir" }
if (-not (Test-Path -LiteralPath $cst)) { throw "Missing constraints file: $cst" }
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

# Add an extracted OSS CAD Suite directory without changing the user's persistent PATH.
if ($env:OSS_CAD_SUITE) {
    $suitePath = [IO.Path]::GetFullPath($env:OSS_CAD_SUITE)
    if (Test-Path -LiteralPath (Join-Path $suitePath 'bin')) { $suitePath = Join-Path $suitePath 'bin' }
    if (-not (Test-Path -LiteralPath $suitePath)) { throw "OSS_CAD_SUITE path does not exist: $suitePath" }
    $env:Path = "$suitePath;$env:Path"
}

function Resolve-Tool([string]$Name) {
    $tool = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $tool) {
        throw "Required tool '$Name' was not found on PATH. Start the OSS CAD Suite shell with 'oss' and run this script from its [OSS CAD Suite] prompt. Install openFPGALoader separately if it is not bundled."
    }
    return $tool.Source
}

function Invoke-Tool([string]$Name, [string[]]$Arguments) {
    Write-Host "`n>>> $Name $($Arguments -join ' ')" -ForegroundColor Cyan
    & $Name @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}

$yosys = Resolve-Tool 'yosys'
$nextpnr = Resolve-Tool 'nextpnr-himbaechel'
$gowinPack = Resolve-Tool 'gowin_pack'
$loader = if ($Program) { Resolve-Tool 'openFPGALoader' } else { $null }

foreach ($toolPath in @($yosys, $nextpnr, $gowinPack)) {
    Write-Host "Tool: $toolPath"
}

$json = Join-Path $buildDir 'top.json'
$pnrJson = Join-Path $buildDir 'top_pnr.json'
$fs = Join-Path $buildDir 'top.fs'
$srcArgs = ($sources | ForEach-Object { 'read_verilog -sv "' + $_.FullName.Replace('\', '/') + '"' }) -join '; '
$yosysScript = "$srcArgs; synth_gowin -top top -json `"$($json.Replace('\', '/'))`""

Invoke-Tool $yosys @('-p', $yosysScript)
Invoke-Tool $nextpnr @(
    '--json', $json,
    '--write', $pnrJson,
    '--device', 'GW2AR-LV18QN88C8/I7',
    '--vopt', 'family=GW2A-18C',
    '--vopt', "cst=$cst"
)
Invoke-Tool $gowinPack @('-d', 'GW2A-18C', '-o', $fs, $pnrJson)

if (-not (Test-Path -LiteralPath $fs) -or (Get-Item -LiteralPath $fs).Length -eq 0) {
    throw "Bitstream was not generated: $fs"
}
Write-Host "`nBuild complete: $fs ($((Get-Item -LiteralPath $fs).Length) bytes)" -ForegroundColor Green

if ($Program) {
    if ($Flash) {
        Invoke-Tool $loader @('-b', 'tangnano20k', '-f', '--verify', $fs)
    } else {
        Invoke-Tool $loader @('-b', 'tangnano20k', $fs)
    }
}
