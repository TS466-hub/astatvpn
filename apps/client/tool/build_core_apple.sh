#!/usr/bin/env bash
# Собирает ядро Xray для iOS и macOS (LibXray.xcframework) и кладёт в проект вместе с геобазами.
# Нужны: macOS с Xcode, git, Go, python3.
# Результат в git не хранится: apple/LibXray.xcframework и apple/geo/*.dat
set -euo pipefail

# Версия ядра закреплена коммитом: тег можно переставить, коммит нельзя. Та же, что в build_core_android.sh.
LIBXRAY_TAG="v26.11.9"
LIBXRAY_COMMIT="5a0f7d8d1c28b34afb5727b04b26a10f6dbac7e3"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/core/libxray"

if [ ! -d "$WORK/.git" ]; then
  rm -rf "$WORK"
  mkdir -p "$(dirname "$WORK")"
  git clone --depth 1 --branch "$LIBXRAY_TAG" https://github.com/XTLS/libXray.git "$WORK"
fi
actual="$(git -C "$WORK" rev-parse HEAD)"
if [ "$actual" != "$LIBXRAY_COMMIT" ]; then
  echo "Коммит libXray ($actual) не совпадает с закреплённым ($LIBXRAY_COMMIT). Сборка остановлена."
  exit 1
fi

# Наша правка замера задержки: число считается по готовому соединению, а не по первому запросу,
# который включает установку соединения. Применяется один раз.
PATCH="$ROOT/tool/patches/libxray-ping.patch"
if git -C "$WORK" apply --check "$PATCH" 2>/dev/null; then
  git -C "$WORK" apply "$PATCH"
elif ! git -C "$WORK" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "Правка $PATCH не подходит к этой версии libXray. Сборка остановлена."
  exit 1
fi

export PATH="$(go env GOPATH)/bin:$PATH"
(cd "$WORK" && python3 build/main.py apple gomobile)

mkdir -p "$ROOT/apple/geo"
rm -rf "$ROOT/apple/LibXray.xcframework"
cp -R "$WORK/LibXray.xcframework" "$ROOT/apple/LibXray.xcframework"
cp "$WORK/dat/geoip.dat" "$WORK/dat/geosite.dat" "$ROOT/apple/geo/"
echo "Готово: ядро $LIBXRAY_TAG для iOS и macOS и геобазы скопированы в проект."
