#!/usr/bin/env bash
# Build a clean Steam Workshop upload folder + steam meta assets + zip.
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
STEAM_META="$DIST/steam"
ZIP="$DIST/${MOD_FOLDER_NAME}-v${VERSION}.zip"

# Game-loadable files only (must match .modinfo <Files>)
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

# Uploader / Workshop page helpers (not loaded by the game)
STEAM_META_FILES=(
  "workshop/preview-512.jpg"
  "workshop/preview.jpg"
  "workshop/STEAM_DESCRIPTION.txt"
)

echo "Packing ${MOD_FOLDER_NAME} v${VERSION}"
echo "  root: $ROOT"

rm -rf "$DIST"
mkdir -p "$OUT" "$STEAM_META"

for rel in "${INCLUDE[@]}"; do
  src="$ROOT/$rel"
  if [[ ! -f "$src" ]]; then
    echo "Missing required file: $rel" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$OUT/$rel")"
  cp -f "$src" "$OUT/$rel"
done

PREVIEW=""
for rel in "${STEAM_META_FILES[@]}"; do
  src="$ROOT/$rel"
  leaf="$(basename "$rel")"
  if [[ ! -f "$src" ]]; then
    if [[ "$leaf" == "STEAM_DESCRIPTION.txt" ]]; then
      echo "Missing required file: $rel" >&2
      exit 1
    fi
    echo "Skip missing optional file: $rel" >&2
    continue
  fi
  cp -f "$src" "$STEAM_META/$leaf"
  if [[ "$leaf" == "preview-512.jpg" ]]; then
    PREVIEW="$STEAM_META/$leaf"
  elif [[ "$leaf" == "preview.jpg" && -z "$PREVIEW" ]]; then
    PREVIEW="$STEAM_META/$leaf"
  fi
done

if [[ -z "$PREVIEW" ]]; then
  echo "Missing workshop preview image (expected workshop/preview-512.jpg or workshop/preview.jpg)" >&2
  exit 1
fi

UPLOAD_GUIDE="$STEAM_META/UPLOAD.txt"
cat > "$UPLOAD_GUIDE" <<EOF
QD 批量倒卖 v${VERSION} — Steam Workshop 上传指引
==============================================

1) Steam Workshop Uploader
   - 选择模组清单:
     $OUT/Civ6-QD-BatchFlip.modinfo
   - Select Image... 选择预览图:
     $PREVIEW
   - 建议标签: UI, Gameplay, Gathering Storm
   - 可见性可先 Friends Only

2) 上传完成后，到工坊物品页编辑简介，粘贴:
   $STEAM_META/STEAM_DESCRIPTION.txt

3) 依赖请挂上 Quick Deals:
   https://steamcommunity.com/sharedfiles/filedetails/?id=2460661464

手动安装 / GitHub Release 用 zip:
  $ZIP
EOF

# zip from workshop/ so archive root is Civ6-QD-BatchFlip/
(
  cd "$WORKSHOP"
  if command -v zip >/dev/null 2>&1; then
    zip -r -q "$ZIP" "$MOD_FOLDER_NAME"
  else
    win_zip="$(printf '%s' "$ZIP" | sed 's|/|\\|g')"
    powershell.exe -NoProfile -Command \
      "Compress-Archive -Path '$MOD_FOLDER_NAME' -DestinationPath '$win_zip' -Force"
  fi
)

FILE_COUNT="$(find "$OUT" -type f | wc -l | tr -d ' ')"
META_COUNT="$(find "$STEAM_META" -type f | wc -l | tr -d ' ')"
ZIP_SIZE="$(wc -c < "$ZIP" | tr -d ' ')"

echo
echo "OK"
echo "  Mod folder      : $OUT  ($FILE_COUNT files)"
echo "  Steam meta      : $STEAM_META  ($META_COUNT files)"
echo "  Zip             : $ZIP  ($ZIP_SIZE bytes)"
echo
echo "Steam Uploader .modinfo :"
echo "  $OUT/Civ6-QD-BatchFlip.modinfo"
echo "Steam Uploader preview  :"
echo "  $PREVIEW"
echo "Workshop description    :"
echo "  $STEAM_META/STEAM_DESCRIPTION.txt"
echo "Guide                   :"
echo "  $UPLOAD_GUIDE"
