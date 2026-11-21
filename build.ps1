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
$buildDir = Join-Path $projectRoot 'build\gpu-smi'
$rtlDir = Join-Path $projectRoot 'rtl'
$constraintFiles = @(
    (Join-Path $projectRoot 'constraints\gpu_base.cst'),
    (Join-Path $projectRoot 'constraints\gpu_hdmi.cst'),
    (Join-Path $projectRoot 'constraints\gpu_link_hdmi_smi.cst')
)
$sourceNames = @(
    'top_tangnano20k.v', 'clocks.v', 'smi_gpu.v', 'async_fifo.v',
    'byte_fifo.v', 'bram_sdp.v', 'gpu_exec.v', 'scanout.v',
    'video_timing.v', 'sdram_ctrl.v', 'dvi_tx.v', 'tmds_encoder.v'
)
$sources = @($sourceNames | ForEach-Object { Join-Path $rtlDir $_ })

if ($Clean -and (Test-Path -LiteralPath $buildDir)) {
    $resolvedBuild = [IO.Path]::GetFullPath($buildDir)
    $resolvedRoot = [IO.Path]::GetFullPath($projectRoot) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedBuild.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove build directory outside project: $resolvedBuild"
    }
    Remove-Item -LiteralPath $resolvedBuild -Recurse -Force
}

foreach ($source in $sources) {
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing GPU RTL source: $source" }
}
foreach ($constraintFile in $constraintFiles) {
    if (-not (Test-Path -LiteralPath $constraintFile)) { throw "Missing GPU constraint file: $constraintFile" }
}
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$tempDir = Join-Path $buildDir 'tmp'
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
$env:TEMP = $tempDir
$env:TMP = $tempDir
$env:TMPDIR = $tempDir

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
$python = Resolve-Tool 'python'
$loader = if ($Program) { Resolve-Tool 'openFPGALoader' } else { $null }

foreach ($toolPath in @($yosys, $nextpnr, $gowinPack)) {
    Write-Host "Tool: $toolPath"
}

$json = Join-Path $buildDir 'top.json'
$pnrJson = Join-Path $buildDir 'top_pnr.json'
$yosysLog = Join-Path $buildDir 'synth.log'
$pnrLog = Join-Path $buildDir 'pnr.log'
$pnrReport = Join-Path $buildDir 'top_report.json'
$fs = Join-Path $buildDir 'top.fs'
$cst = Join-Path $buildDir 'tangnano20k_gpu_smi.cst'
$constraintText = ($constraintFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`r`n"
Set-Content -LiteralPath $cst -Value $constraintText -NoNewline -Encoding ascii
$srcArgs = ($sources | ForEach-Object { 'read_verilog -sv -DLINK_SMI "' + $_.Replace('\', '/') + '"' }) -join '; '
$yosysScript = "$srcArgs; synth_gowin -top top_tangnano20k; simplemap t:`$buf; opt_clean; write_json `"$($json.Replace('\', '/'))`""

Invoke-Tool $yosys @('-Q', '-q', '-l', $yosysLog, '-p', $yosysScript)
Invoke-Tool $python @((Join-Path $projectRoot 'tools\fix_bram_oce.py'), $json)
Invoke-Tool $nextpnr @(
    '--json', $json,
    '--write', $pnrJson,
    '--report', $pnrReport,
    '-l', $pnrLog,
    '--device', 'GW2AR-LV18QN88C8/I7',
    '--vopt', 'family=GW2A-18C',
    '--vopt', "cst=$cst",
    '--seed', '1'
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
