#!/usr/bin/env bash
# Полная настройка нового сервера под VPN-ноду: подкачка 2 ГБ, BBR, файрвол, remnanode, подключение к панели.
#
#   bash setup-node.sh --name Germany --country DE
#
# API-токен панели спрашивается скрыто и не попадает в историю команд.
set -Eeuo pipefail

BASE_URL="${SETUP_BASE_URL:-https://app.autohitech.shop}"
PANEL="${SETUP_PANEL:-https://panel.autohitech.shop}"
NAME=""; COUNTRY=""; SWAP_GB=2
ok()  { printf ' ✓ %s\n' "$*"; }
die() { printf ' ✗ Ошибка: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --country) COUNTRY="${2:-}"; shift 2 ;;
    --panel) PANEL="${2:-}"; shift 2 ;;
    *) die "Неизвестный параметр: $1. Пример: bash setup-node.sh --name Germany --country DE" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Запустите от root"
[[ "$NAME" =~ ^[A-Za-z0-9_-]{3,30}$ ]] || die "--name: от 3 до 30 латинских букв или цифр, например Germany"
[[ "$COUNTRY" =~ ^[A-Za-z]{2}$ ]] || die "--country: код страны из 2 букв, например DE"

if [ "${SETUP_SYSTEM_ONLY:-0}" != 1 ]; then
  printf 'Вставьте API-токен панели (символы не отображаются) и нажмите Enter: '
  read -rs TOKEN </dev/tty
  echo
  [ -n "$TOKEN" ] || die "Токен пустой"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq openssl ca-certificates ufw >/dev/null

# Подкачка: заменяем файл, только если он отличается по размеру
want=$((SWAP_GB * 1024 * 1024 * 1024))
if [ "$(stat -c %s /swapfile 2>/dev/null || echo 0)" != "$want" ]; then
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  fallocate -l "${SWAP_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024)) status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
fi
swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile
grep -qE '^/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
ok "Подкачка ${SWAP_GB} ГБ"

cat > /etc/sysctl.d/99-astat-node.conf <<'CONF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
CONF
modprobe tcp_bbr 2>/dev/null || true
echo tcp_bbr > /etc/modules-load.d/bbr.conf
sysctl --system >/dev/null
[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ] || die "BBR не включился: ядро его не поддерживает"
ok "BBR включён"

# Файрвол: сначала открываем текущий порт SSH, чтобы не потерять доступ к серверу
panel_host="${PANEL#*://}"; panel_host="${panel_host%%[:/]*}"
panel_ip="$(getent ahostsv4 "$panel_host" | awk '{print $1; exit}')"
[ -n "$panel_ip" ] || die "Не удалось определить IP панели $panel_host"
ssh_port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
ufw allow "${ssh_port:-22}/tcp" >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow from "$panel_ip" to any port 2222 proto tcp >/dev/null
ufw --force enable >/dev/null
ok "Файрвол: открыты SSH (${ssh_port:-22}), 443 и 2222 только для панели ($panel_ip)"

if [ "${SETUP_SYSTEM_ONLY:-0}" = 1 ]; then ok "Системная часть готова"; exit 0; fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$BASE_URL/install-node.sh" -o "$tmp" || die "Не удалось скачать install-node.sh с $BASE_URL"
bash "$tmp" --panel "$PANEL" --token "$TOKEN" --name "$NAME" --country "$COUNTRY" --profile ASTAT --yes
unset TOKEN

sleep 15
docker ps --format '{{.Names}} {{.Status}}' | grep -q '^remnanode Up' || die "remnanode не запущен: docker logs remnanode"
ss -ltn | grep -q ':2222 ' || die "Нода не слушает порт 2222: docker logs remnanode"
ok "Нода «$NAME» запущена. Проверьте в панели (Nodes), что она онлайн, и обновите подписку в приложении."
