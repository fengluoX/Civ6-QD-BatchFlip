#Requires -Version 5.0
<#
.SYNOPSIS
  Build a clean Steam Workshop upload folder + zip for GitHub Release / manual install.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\pack-workshop.ps1
#>
$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$ModinfoPath = Join-Path $Root "Civ6-QD-BatchFlip.modinfo"
if (-not (Test-Path -LiteralPath $ModinfoPath)) {
  throw "Missing modinfo: $ModinfoPath"
}

[xml]$modinfo = Get-Content -LiteralPath $ModinfoPath -Encoding UTF8
$version = $modinfo.Mod.version
if ([string]::IsNullOrWhiteSpace($version)) {
  throw "Cannot read version from modinfo"
}

$ModFolderName = "Civ6-QD-BatchFlip"
$DistRoot = Join-Path $Root "dist"
$WorkshopRoot = Join-Path $DistRoot "workshop"
$OutDir = Join-Path $WorkshopRoot $ModFolderName
$ZipPath = Join-Path $DistRoot ("{0}-v{1}.zip" -f $ModFolderName, $version)

$IncludeRelPaths = @(
  "Civ6-QD-BatchFlip.modinfo",
  "ui\qd_dealpopup_bf.lua",
  "ui\bf_popuptab_batch.xml",
  "ui\bf_popuptab_batch.lua",
  "ui\BatchFlipConfig.lua",
  "ui\BatchFlipDealUtil.lua",
  "ui\BatchFlipDealSession.lua",
  "ui\BatchFlipStrategic.lua",
  "ui\BatchFlipRunner.lua",
  "ui\BatchFlipFavor.lua",
  "text\bf_text.xml",
  "text\bf_translations_text.xml"
)

Write-Host "Packing $ModFolderName v$version"
Write-Host "  root: $Root"

if (Test-Path -LiteralPath $DistRoot) {
  Remove-Item -LiteralPath $DistRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

foreach ($rel in $IncludeRelPaths) {
  $src = Join-Path $Root $rel
  if (-not (Test-Path -LiteralPath $src)) {
    throw "Missing required file: $rel"
  }
  $dst = Join-Path $OutDir $rel
  $dstParent = Split-Path -Parent $dst
  if (-not (Test-Path -LiteralPath $dstParent)) {
    New-Item -ItemType Directory -Force -Path $dstParent | Out-Null
  }
  Copy-Item -LiteralPath $src -Destination $dst -Force
}

if (Test-Path -LiteralPath $ZipPath) {
  Remove-Item -LiteralPath $ZipPath -Force
}

# Zip the mod folder itself so extract → Mods\Civ6-QD-BatchFlip\*.modinfo
Push-Location $WorkshopRoot
try {
  Compress-Archive -Path $ModFolderName -DestinationPath $ZipPath -Force
}
finally {
  Pop-Location
}

$fileCount = (Get-ChildItem -LiteralPath $OutDir -Recurse -File).Count
$zipSize = (Get-Item -LiteralPath $ZipPath).Length

Write-Host ""
Write-Host "OK"
Write-Host "  Workshop folder : $OutDir  ($fileCount files)"
Write-Host "  Zip             : $ZipPath  ($zipSize bytes)"
Write-Host ""
Write-Host "Steam Uploader: select"
Write-Host "  $OutDir\Civ6-QD-BatchFlip.modinfo"
Write-Host "Manual / GitHub : upload the zip as a release asset"
