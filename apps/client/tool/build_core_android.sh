#!/usr/bin/env bash
# Собирает ядро Xray для Android (libXray.aar) и кладёт в проект вместе с геобазами.
# Нужны: git, Go, python3, JDK 17, Android SDK с NDK (переменные ANDROID_HOME и ANDROID_NDK_HOME).
# Результат в git не хранится: android/app/libs/libXray.aar и android/app/src/main/assets/geo/*.dat
set -euo pipefail

# Версия ядра закреплена коммитом: тег можно переставить, коммит нельзя.
LIBXRAY_TAG="v26.11.9"
LIBXRAY_COMMIT="5a0f7d8d1c28b34afb5727b04b26a10f6dbac7e3"
ANDROID_API=24

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/core/libxray"

: "${ANDROID_HOME:?Укажите ANDROID_HOME (путь к Android SDK)}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
[ -d "${ANDROID_NDK_HOME:-}" ] || { echo "Не найден Android NDK: установите его через sdkmanager"; exit 1; }
export ANDROID_NDK_HOME

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
(cd "$WORK" && LIBXRAY_ANDROID_API="$ANDROID_API" python3 build/main.py android)

mkdir -p "$ROOT/android/app/libs" "$ROOT/android/app/src/main/assets/geo"
cp "$WORK/libXray.aar" "$ROOT/android/app/libs/libXray.aar"
cp "$WORK/dat/geoip.dat" "$WORK/dat/geosite.dat" "$ROOT/android/app/src/main/assets/geo/"
echo "Готово: ядро $LIBXRAY_TAG и геобазы скопированы в проект."
