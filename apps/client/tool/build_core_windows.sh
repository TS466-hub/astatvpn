#!/usr/bin/env bash
# Собирает службу AstatVPN для Windows (astat-helper.exe с ядром Xray внутри) под amd64 и arm64
# и кладёт рядом всё, что ей нужно: wintun.dll, geoip.dat, geosite.dat.
# Нужны: Go, curl, unzip. Windows не нужен: сборка без cgo идёт с любой системы.
# Результат в git не хранится: build/core/windows/<amd64|arm64>/
# После этого `flutter build windows` сам положит эти файлы рядом с astatvpn.exe (см. windows/CMakeLists.txt).
set -euo pipefail

# Драйвер сетевого адаптера. Архив и его сумма — с https://www.wintun.net/ (там же опубликован SHA2-256).
WINTUN_VERSION="0.14.1"
WINTUN_URL="https://www.wintun.net/builds/wintun-${WINTUN_VERSION}.zip"
WINTUN_SHA256="07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51"

# Геобазы — те же, что берёт сборка ядра для Android (download_geo в libXray).
GEOSITE_URL="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
GEOIP_URL="https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/core"
OUT="$ROOT/build/core/windows"
CACHE="$ROOT/build/core/cache"
ARCHS="${ARCHS:-amd64 arm64}"

command -v go >/dev/null || { echo "Не найден Go"; exit 1; }
mkdir -p "$CACHE"

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() { # адрес, файл
  curl -fL --retry 3 --connect-timeout 20 --max-time 600 -o "$2.part" "$1"
  mv "$2.part" "$2"
}

# --- wintun.dll ---------------------------------------------------------------------------------------
zip="$CACHE/wintun-${WINTUN_VERSION}.zip"
if [ ! -f "$zip" ] || [ "$(sha256 "$zip")" != "$WINTUN_SHA256" ]; then
  fetch "$WINTUN_URL" "$zip"
fi
actual="$(sha256 "$zip")"
if [ "$actual" != "$WINTUN_SHA256" ]; then
  rm -f "$zip"
  echo "Сумма wintun-${WINTUN_VERSION}.zip ($actual) не совпадает с опубликованной ($WINTUN_SHA256). Сборка остановлена."
  exit 1
fi
rm -rf "$CACHE/wintun"
unzip -q -o "$zip" 'wintun/bin/*' 'wintun/LICENSE.txt' -d "$CACHE"

# --- геобазы ------------------------------------------------------------------------------------------
# Если ядро для Android уже собиралось, берём те же файлы: на всех платформах будут одинаковые списки.
geo=""
for dir in "$ROOT/build/core/libxray/dat" "$ROOT/android/app/src/main/assets/geo"; do
  if [ -s "$dir/geoip.dat" ] && [ -s "$dir/geosite.dat" ]; then geo="$dir"; break; fi
done
if [ -z "$geo" ]; then
  geo="$CACHE/geo"
  mkdir -p "$geo"
  [ -s "$geo/geosite.dat" ] || fetch "$GEOSITE_URL" "$geo/geosite.dat"
  [ -s "$geo/geoip.dat" ] || fetch "$GEOIP_URL" "$geo/geoip.dat"
fi
echo "Геобазы: $geo"

# --- служба -------------------------------------------------------------------------------------------
(cd "$SRC" && go mod verify >/dev/null)
for arch in $ARCHS; do
  case "$arch" in amd64|arm64) ;; *) echo "Неизвестная архитектура: $arch"; exit 1 ;; esac
  dest="$OUT/$arch"
  mkdir -p "$dest"
  echo "Сборка astat-helper.exe для windows/$arch"
  (cd "$SRC" && GOOS=windows GOARCH="$arch" CGO_ENABLED=0 GOFLAGS=-mod=readonly \
    go build -trimpath -ldflags "-s -w" -o "$dest/astat-helper.exe" ./cmd/astat-helper)
  cp "$CACHE/wintun/bin/$arch/wintun.dll" "$dest/wintun.dll"
  cp "$CACHE/wintun/LICENSE.txt" "$dest/wintun-LICENSE.txt"
  cp "$geo/geoip.dat" "$geo/geosite.dat" "$dest/"
done

echo "Готово:"
ls -l "$OUT"/*/
