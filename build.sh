#!/bin/bash
# Сборка Notch Island в .app
#   ./build.sh            — собрать в build/NotchIsland.app
#   ./build.sh --install  — собрать, положить в /Applications и запустить
set -euo pipefail
cd "$(dirname "$0")"

APP="NotchIsland.app"
OUT="build/$APP"

echo "→ Компилирую…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/NotchIsland"

echo "→ Собираю ${APP}…"
rm -rf "${OUT}"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "${BIN}" "$OUT/Contents/MacOS/NotchIsland"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$OUT/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "${OUT}"

echo "✓ Готово: ${OUT}"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x NotchIsland 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$APP"
  cp -R "${OUT}" /Applications/
  touch "/Applications/$APP"   # чтобы Finder обновил иконку
  open "/Applications/$APP"
  echo "✓ Установлено в /Applications и запущено"
fi
