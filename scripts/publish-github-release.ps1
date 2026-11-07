#Requires -Version 5.0
<#
.SYNOPSIS
  Pack workshop zip (if needed) and create/update a GitHub Release for the current modinfo version.

.NOTES
  Requires GitHub CLI (`gh`) authenticated for fengluoX/Civ6-QD-BatchFlip.
  Does not git-commit; attach the built zip to tag v{version}.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\publish-github-release.ps1
#>
$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
  $candidates = @(
    "${env:ProgramFiles}\GitHub CLI\gh.exe",
    "${env:LOCALAPPDATA}\Programs\GitHub CLI\gh.exe"
  )
  foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) {
      $gh = @{ Source = $c }
      break
    }
  }
}
if (-not $gh) {
  throw @"
GitHub CLI (gh) not found.
Install: https://cli.github.com/
Then: gh auth login
"@
}
$GhExe = if ($gh.Source) { $gh.Source } else { $gh.Path }

[xml]$modinfo = Get-Content -LiteralPath (Join-Path $Root "Civ6-QD-BatchFlip.modinfo") -Encoding UTF8
$version = $modinfo.Mod.version
$tag = "v$version"
$zipName = "Civ6-QD-BatchFlip-v$version.zip"
$zipPath = Join-Path $Root "dist\$zipName"

& (Join-Path $PSScriptRoot "pack-workshop.ps1")
if (-not (Test-Path -LiteralPath $zipPath)) {
  throw "Pack failed: missing $zipPath"
}

$notes = @"
## QD 批量倒卖 $tag

Steam / 手动安装包（解压到 ``Documents\My Games\Sid Meier's Civilization VI\Mods\``）。

### 依赖
- [Quick Deals](https://steamcommunity.com/sharedfiles/filedetails/?id=2460661464)

### 安装
1. 下载 ``$zipName`` 并解压到 Mods 目录
2. 启用本模组 + Quick Deals
3. 完整重启文明 6

详见仓库 README。
"@

Write-Host "Creating / updating GitHub release $tag ..."

$existing = & $GhExe release view $tag --repo fengluoX/Civ6-QD-BatchFlip 2>$null
if ($LASTEXITCODE -eq 0) {
  Write-Host "Release $tag already exists; uploading asset (clobber)..."
  & $GhExe release upload $tag $zipPath --repo fengluoX/Civ6-QD-BatchFlip --clobber
} else {
  & $GhExe release create $tag $zipPath `
    --repo fengluoX/Civ6-QD-BatchFlip `
    --title "QD 批量倒卖 $tag" `
    --notes $notes
}

if ($LASTEXITCODE -ne 0) {
  throw "gh release failed (exit $LASTEXITCODE)"
}

$url = & $GhExe release view $tag --repo fengluoX/Civ6-QD-BatchFlip --json url -q .url
Write-Host "Done: $url"
