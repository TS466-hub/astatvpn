#!/usr/bin/env bash
# Упаковывает собранное приложение для macOS в образ диска (DMG) для раздачи с сайта.
# Сначала: tool/build_core_macos.sh && flutter build macos --release
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/macos/Build/Products/Release/AstatVPN.app"
OUT="$ROOT/build/installer"
[ -d "$APP" ] || { echo "Нет $APP: сначала соберите приложение"; exit 1; }
[ -x "$APP/Contents/Resources/astat-helper" ] || { echo "В приложении нет службы: выполните tool/build_core_macos.sh и соберите заново"; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Программы"
mkdir -p "$OUT"
rm -f "$OUT/AstatVPN.dmg"
hdiutil create -volname "AstatVPN" -srcfolder "$STAGE" -ov -format UDZO "$OUT/AstatVPN.dmg" >/dev/null
echo "Готово: $OUT/AstatVPN.dmg"
