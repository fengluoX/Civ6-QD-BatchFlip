#!/usr/bin/env bash
# Build a clean Steam Workshop upload folder + zip for GitHub Release / manual install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODINFO="$ROOT/Civ6-QD-BatchFlip.modinfo"
MOD_FOLDER_NAME="Civ6-QD-BatchFlip"

if [[ ! -f "$MODINFO" ]]; then
  echo "Missing modinfo: $MODINFO" >&2
  exit 1
fi

VERSION="$(sed -n 's/.*version="\([0-9][0-9]*\)".*/\1/p' "$MODINFO" | head -n1)"
if [[ -z "${VERSION}" ]]; then
  echo "Cannot read version from modinfo" >&2
  exit 1
fi

DIST="$ROOT/dist"
WORKSHOP="$DIST/workshop"
OUT="$WORKSHOP/$MOD_FOLDER_NAME"
ZIP="$DIST/${MOD_FOLDER_NAME}-v${VERSION}.zip"

INCLUDE=(
  "Civ6-QD-BatchFlip.modinfo"
  "ui/qd_dealpopup_bf.lua"
  "ui/bf_popuptab_batch.xml"
  "ui/bf_popuptab_batch.lua"
  "ui/BatchFlipConfig.lua"
  "ui/BatchFlipDealUtil.lua"
  "ui/BatchFlipDealSession.lua"
  "ui/BatchFlipStrategic.lua"
  "ui/BatchFlipRunner.lua"
  "ui/BatchFlipFavor.lua"
  "text/bf_text.xml"
  "text/bf_translations_text.xml"
)

echo "Packing ${MOD_FOLDER_NAME} v${VERSION}"
echo "  root: $ROOT"

rm -rf "$DIST"
mkdir -p "$OUT"

for rel in "${INCLUDE[@]}"; do
  src="$ROOT/$rel"
  if [[ ! -f "$src" ]]; then
    echo "Missing required file: $rel" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$OUT/$rel")"
  cp -f "$src" "$OUT/$rel"
done

# zip from workshop/ so archive root is Civ6-QD-BatchFlip/
(
  cd "$WORKSHOP"
  if command -v zip >/dev/null 2>&1; then
    zip -r -q "$ZIP" "$MOD_FOLDER_NAME"
  else
    powershell.exe -NoProfile -Command \
      "Compress-Archive -Path '$MOD_FOLDER_NAME' -DestinationPath '$(echo "$ZIP" | sed 's|/|\\|g')' -Force"
  fi
)

FILE_COUNT="$(find "$OUT" -type f | wc -l | tr -d ' ')"
ZIP_SIZE="$(wc -c < "$ZIP" | tr -d ' ')"

echo
echo "OK"
echo "  Workshop folder : $OUT  ($FILE_COUNT files)"
echo "  Zip             : $ZIP  ($ZIP_SIZE bytes)"
echo
echo "Steam Uploader: select"
echo "  $OUT/Civ6-QD-BatchFlip.modinfo"
echo "Manual / GitHub : upload the zip as a release asset"
