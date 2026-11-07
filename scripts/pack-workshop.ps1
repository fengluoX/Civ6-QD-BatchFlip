#Requires -Version 5.0
<#
.SYNOPSIS
  Build a clean Steam Workshop upload folder + steam meta assets + zip.

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
$SteamMetaDir = Join-Path $DistRoot "steam"
$ZipPath = Join-Path $DistRoot ("{0}-v{1}.zip" -f $ModFolderName, $version)

# Game-loadable files only (must match .modinfo <Files>)
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

# Uploader / Workshop page helpers (not loaded by the game)
$SteamMetaRelPaths = @(
  "workshop\preview-512.jpg",
  "workshop\preview.jpg",
  "workshop\STEAM_DESCRIPTION.txt"
)

function Copy-RelFile {
  param(
    [Parameter(Mandatory = $true)][string]$Rel,
    [Parameter(Mandatory = $true)][string]$DestRoot,
    [switch]$Required
  )
  $src = Join-Path $Root $Rel
  if (-not (Test-Path -LiteralPath $src)) {
    if ($Required) { throw "Missing required file: $Rel" }
    Write-Warning "Skip missing optional file: $Rel"
    return $null
  }
  $leaf = Split-Path -Leaf $Rel
  $dst = Join-Path $DestRoot $leaf
  if (-not (Test-Path -LiteralPath $DestRoot)) {
    New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null
  }
  Copy-Item -LiteralPath $src -Destination $dst -Force
  return $dst
}

Write-Host "Packing $ModFolderName v$version"
Write-Host "  root: $Root"

if (Test-Path -LiteralPath $DistRoot) {
  Remove-Item -LiteralPath $DistRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $SteamMetaDir | Out-Null

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

$previewPath = $null
foreach ($rel in $SteamMetaRelPaths) {
  $required = $rel -like "*STEAM_DESCRIPTION*"
  $copied = Copy-RelFile -Rel $rel -DestRoot $SteamMetaDir -Required:$required
  if ($rel -like "*preview-512*" -and $copied) { $previewPath = $copied }
  elseif ($rel -like "*preview.jpg" -and -not $previewPath -and $copied) { $previewPath = $copied }
}
if (-not $previewPath) {
  throw "Missing workshop preview image (expected workshop\preview-512.jpg or workshop\preview.jpg)"
}

$uploadGuide = @"
QD 批量倒卖 v$version — Steam Workshop 上传指引
==============================================

1) Steam Workshop Uploader
   - 选择模组清单:
     $OutDir\Civ6-QD-BatchFlip.modinfo
   - Select Image... 选择预览图:
     $previewPath
   - 建议标签: UI, Gameplay, Gathering Storm
   - 可见性可先 Friends Only

2) 上传完成后，到工坊物品页编辑简介，粘贴:
   $SteamMetaDir\STEAM_DESCRIPTION.txt

3) 依赖请挂上 Quick Deals:
   https://steamcommunity.com/sharedfiles/filedetails/?id=2460661464

手动安装 / GitHub Release 用 zip:
  $ZipPath
"@
$uploadGuidePath = Join-Path $SteamMetaDir "UPLOAD.txt"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($uploadGuidePath, $uploadGuide, $utf8NoBom)

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
$metaCount = (Get-ChildItem -LiteralPath $SteamMetaDir -Recurse -File).Count
$zipSize = (Get-Item -LiteralPath $ZipPath).Length

Write-Host ""
Write-Host "OK"
Write-Host "  Mod folder      : $OutDir  ($fileCount files)"
Write-Host "  Steam meta      : $SteamMetaDir  ($metaCount files)"
Write-Host "  Zip             : $ZipPath  ($zipSize bytes)"
Write-Host ""
Write-Host "Steam Uploader .modinfo :"
Write-Host "  $OutDir\Civ6-QD-BatchFlip.modinfo"
Write-Host "Steam Uploader preview  :"
Write-Host "  $previewPath"
Write-Host "Workshop description    :"
Write-Host "  $SteamMetaDir\STEAM_DESCRIPTION.txt"
Write-Host "Guide                   :"
Write-Host "  $uploadGuidePath"
