#!/bin/sh
# hermes-status.sh — 一加8T pmOS 系统状态采集 + Telegram 推送
# 对标 MI10-Hermes 状态卡片。设备侧运行(busybox ash 兼容)。
# 配置: /etc/hermes-status.conf (TG_TOKEN, TG_CHAT_ID, PROXY)
# 用法: hermes-status.sh        # 采集并推送
#       hermes-status.sh --dry  # 只打印不推送

CONF="${HERMES_CONF:-/etc/hermes-status.conf}"
[ -f "$CONF" ] && . "$CONF"

DRY=0
[ "$1" = "--dry" ] && DRY=1

# ---- 采集 ----
HOST=$(hostname)
UP=$(uptime | sed 's/.*up //; s/,  *[0-9]* user.*//; s/,  *load.*//')
LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
# 内存
MEM_T=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
MEM_A=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
MEM_U=$((MEM_T - MEM_A))
MEM_P=$((MEM_U * 100 / MEM_T))
# swap
SW_T=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
SW_F=$(awk '/SwapFree/{print int($2/1024)}' /proc/meminfo)
SW_U=$((SW_T - SW_F))
SW_P=0; [ "$SW_T" -gt 0 ] && SW_P=$((SW_U * 100 / SW_T))
# 磁盘(docker数据盘 + 根)
DISK_ROOT=$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')
DISK_DOCK=$(df -h /var/lib/docker 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')
# docker
DK_RUN=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
DK_NAMES=$(docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
# 温度
TEMP=""
for z in /sys/class/thermal/thermal_zone*/temp; do
  [ -f "$z" ] || continue
  t=$(cat "$z" 2>/dev/null)
  [ "$t" -gt 1000 ] 2>/dev/null && t=$((t/1000))
  [ "$t" -gt "${TEMP:-0}" ] 2>/dev/null && TEMP=$t
done

# ---- 服务端口探活 ----
probe() { # name port
  code=$(wget -q -O /dev/null -T 4 -S "http://127.0.0.1:$2/" 2>&1 | grep -oE "HTTP/[0-9.]+ [0-9]+" | tail -1 | grep -oE "[0-9]+$")
  [ -z "$code" ] && code="--"
  echo "$1 ($2) HTTP $code"
}
SVC_HA=$(probe homeassistant 8123)
SVC_NTFY=$(probe ntfy 8080)

# ---- 告警 ----
ALERTS=""
[ "$MEM_P" -ge 90 ] && ALERTS="$ALERTS\n⚠️ 内存 ${MEM_P}%"
[ "$SW_P" -ge 70 ] && ALERTS="$ALERTS\n⚠️ Swap ${SW_P}%"
RP=$(df / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
[ "${RP:-0}" -ge 85 ] && ALERTS="$ALERTS\n⚠️ 根分区 ${RP}%"
[ -n "$TEMP" ] && [ "$TEMP" -ge 70 ] && ALERTS="$ALERTS\n⚠️ 温度 ${TEMP}°C"

STATUS_ICON="🟢"; TITLE="系统状态 · 正常"
[ -n "$ALERTS" ] && { STATUS_ICON="🟡"; TITLE="系统状态 · 有告警"; }

NOW=$(date '+%Y-%m-%d %H:%M:%S')

# ---- 组装消息 (Telegram HTML) ----
MSG="$STATUS_ICON <b>$TITLE</b>
<code>$NOW</code>

<b>主机</b> $HOST   <b>Uptime</b> $UP
<b>负载</b> $LOAD

<b>内存</b> ${MEM_U}M/${MEM_T}M (${MEM_P}%)  可用 ${MEM_A}M
<b>Swap</b> ${SW_U}M/${SW_T}M (${SW_P}%)
<b>磁盘/</b> $DISK_ROOT
<b>docker盘</b> $DISK_DOCK"
[ -n "$TEMP" ] && MSG="$MSG
<b>温度</b> ${TEMP}°C"
MSG="$MSG

<b>Docker</b> ${DK_RUN} 个容器在跑
$DK_NAMES

<b>服务端口</b>
✅ $SVC_HA
✅ $SVC_NTFY"
[ -n "$ALERTS" ] && MSG="$MSG

<b>告警</b>$ALERTS"

if [ "$DRY" = "1" ]; then
  printf '%b\n' "$MSG"
  exit 0
fi

# ---- 推送 Telegram ----
[ -z "$TG_TOKEN" ] && { echo "ERR: TG_TOKEN 未配置 ($CONF)"; exit 1; }
[ -z "$TG_CHAT_ID" ] && { echo "ERR: TG_CHAT_ID 未配置"; exit 1; }
PX=""; [ -n "$PROXY" ] && PX="-e https_proxy=$PROXY -e http_proxy=$PROXY"
# busybox wget 走代理用 env; 用 curl 更稳(若有)
if command -v curl >/dev/null 2>&1; then
  CURL_PX=""; [ -n "$PROXY" ] && CURL_PX="-x $PROXY"
  curl -s $CURL_PX --max-time 15 \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" \
    -d parse_mode="HTML" \
    --data-urlencode text="$MSG" >/dev/null 2>&1 && echo "推送成功" || echo "推送失败"
else
  # busybox wget POST (走 http_proxy 环境变量)
  TMPF=/tmp/.hermes-tg-$$
  printf 'chat_id=%s&parse_mode=HTML' "$TG_CHAT_ID" > "$TMPF"
  export https_proxy="$PROXY" http_proxy="$PROXY"
  wget -q -O- --post-data "chat_id=${TG_CHAT_ID}&parse_mode=HTML&text=$(echo "$MSG" | sed 's/ /%20/g; s/&/%26/g')" \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null 2>&1 && echo "推送成功" || echo "推送失败"
  rm -f "$TMPF"
fi
