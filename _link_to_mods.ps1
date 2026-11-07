$gameMods = "C:\Users\17854\Documents\My Games\Sid Meier's Civilization VI\Mods"
$dest = "C:\Users\17854\Documents\My Games\Sid Meier's Civilization VI\Mods\Civ6-QD-BatchFlip"
$target = "E:\Civ6-QD-BatchFlip"

New-Item -ItemType Directory -Force -Path $gameMods | Out-Null

if (Test-Path -LiteralPath $dest) {
  Write-Host "Already present: $dest"
} else {
  cmd /c "mklink /J `"$dest`" `"$target`""
  Write-Host "Linked: $dest -> $target"
}

Get-ChildItem -LiteralPath $gameMods | Select-Object Name
Get-Item -LiteralPath $dest | Format-List FullName, LinkType, Target
