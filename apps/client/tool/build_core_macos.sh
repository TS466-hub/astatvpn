#!/usr/bin/env bash
# Собирает службу AstatVPN для macOS (astat-helper с ядром Xray внутри, сразу под Apple Silicon и Intel)
# и кладёт рядом геобазы. Аккаунт разработчика Apple не нужен.
# Нужны: macOS, Go, curl.
# Результат в git не хранится: build/core/macos/. Сборка приложения сама кладёт эти файлы в Contents/Resources.
set -euo pipefail

# Геобазы — те же, что берёт сборка ядра для Android (download_geo в libXray).
GEOSITE_URL="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
GEOIP_URL="https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/core"
OUT="$ROOT/build/core/macos"
CACHE="$ROOT/build/core/cache"

command -v go >/dev/null || { echo "Не найден Go"; exit 1; }
mkdir -p "$OUT" "$CACHE"

for arch in arm64 amd64; do
  echo "Сборка службы под $arch"
  (cd "$SRC" && CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath -ldflags "-s -w" -o "$CACHE/astat-helper-darwin-$arch" ./cmd/astat-helper)
done
lipo -create -output "$OUT/astat-helper" "$CACHE/astat-helper-darwin-arm64" "$CACHE/astat-helper-darwin-amd64"
chmod 755 "$OUT/astat-helper"
# объединённый файл теряет подпись, а macOS на Apple Silicon не запускает неподписанные программы
codesign --force --sign - "$OUT/astat-helper"

fetch() { # адрес, файл
  if [ ! -s "$2" ]; then
    curl -fsSL --retry 3 -o "$2.part" "$1"
    mv "$2.part" "$2"
  fi
}
# если геобазы уже собраны для другой системы, берём их: во всех сборках они должны быть одинаковыми
geo=""
for dir in "$ROOT/android/app/src/main/assets/geo" "$ROOT/apple/geo"; do
  if [ -s "$dir/geoip.dat" ] && [ -s "$dir/geosite.dat" ]; then geo="$dir"; break; fi
done
if [ -z "$geo" ]; then
  geo="$CACHE/geo"
  mkdir -p "$geo"
  fetch "$GEOIP_URL" "$geo/geoip.dat"
  fetch "$GEOSITE_URL" "$geo/geosite.dat"
fi
cp "$geo/geoip.dat" "$geo/geosite.dat" "$OUT/"

"$OUT/astat-helper" version
echo "Готово: служба и геобазы лежат в $OUT"
