#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$ROOT_DIR/DockMinimize/DockMinimize.xcodeproj"
SCHEME="DockMinimize"
CONFIGURATION="${CONFIGURATION:-Release}"
SIGN_IDENTITY="${DM_SIGN_IDENTITY:-DockMinimize Local Code Signing}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.DerivedData}"
APP_DEST="${APP_DEST:-/Applications/DockMinimize.app}"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  build

APP_SRC="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/DockMinimize.app"

if [[ ! -d "$APP_SRC" ]]; then
  echo "Build output not found: $APP_SRC"
  exit 1
fi

if [[ -d "$APP_DEST" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  mv "$APP_DEST" "${APP_DEST}.bak-$TS"
fi

cp -R "$APP_SRC" "$APP_DEST"

pkill -x DockMinimize || true
open -a "$APP_DEST" || true

/usr/bin/codesign -dv --verbose=4 "$APP_DEST" 2>&1 | rg "Authority=|Signature=|TeamIdentifier=|CDHash=" -N
