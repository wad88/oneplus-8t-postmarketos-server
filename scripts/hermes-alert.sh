#!/bin/sh
# hermes-alert.sh — 只在异常时推TG(正常静默)。crontab 定时跑。
# 状态去抖: 用 /tmp 标记文件,同一告警10分钟内不重复推; 恢复正常时推一条"恢复"
CONF="${HERMES_CONF:-/etc/hermes-status.conf}"
[ -f "$CONF" ] && . "$CONF"
[ -z "$TG_TOKEN" ] && exit 0
STATE=/tmp/.hermes-alert-state

send() {
  body="chat_id=${TG_CHAT_ID}&parse_mode=HTML&text=$1"
  if command -v curl >/dev/null 2>&1; then
    curl -s --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d chat_id="${TG_CHAT_ID}" -d parse_mode=HTML --data-urlencode text="$1" >/dev/null 2>&1
  else
    wget -q -O- --timeout 15 --post-data "chat_id=${TG_CHAT_ID}&parse_mode=HTML&text=$(echo "$1"|sed 's/ /%20/g')" \
      "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null 2>&1
  fi
}

ALERTS=""
# 内存
MEM_T=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
MEM_A=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
MEM_P=$(( (MEM_T-MEM_A)*100/MEM_T ))
[ "$MEM_P" -ge 90 ] && ALERTS="$ALERTS\n⚠️ 内存 ${MEM_P}%"
# 根分区
RP=$(df / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}')
[ "${RP:-0}" -ge 85 ] && ALERTS="$ALERTS\n⚠️ 根分区 ${RP}%"
# docker盘
DP=$(df /var/lib/docker 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}')
[ "${DP:-0}" -ge 85 ] && ALERTS="$ALERTS\n⚠️ docker盘 ${DP}%"
# 温度
TEMP=""
for z in /sys/class/thermal/thermal_zone*/temp; do
  [ -f "$z" ] || continue; t=$(cat "$z" 2>/dev/null)
  [ "$t" -gt 1000 ] 2>/dev/null && t=$((t/1000))
  [ "$t" -gt "${TEMP:-0}" ] 2>/dev/null && TEMP=$t
done
[ -n "$TEMP" ] && [ "$TEMP" -ge 70 ] && ALERTS="$ALERTS\n⚠️ 温度 ${TEMP}°C"
# 容器挂(期望homeassistant+ntfy都在)
for c in homeassistant ntfy; do
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c" || ALERTS="$ALERTS\n⚠️ 容器 $c 不在运行"
done

PREV=""; [ -f "$STATE" ] && PREV=$(cat "$STATE")

if [ -n "$ALERTS" ]; then
  # 有告警: 内容变了才推(避免重复刷屏)
  if [ "$ALERTS" != "$PREV" ]; then
    send "🔴 <b>Hermes 异常</b>\n<code>$(date '+%m-%d %H:%M')</code>$ALERTS"
    echo "$ALERTS" > "$STATE"
  fi
else
  # 正常: 若上次有告警,推一条恢复
  if [ -n "$PREV" ]; then
    send "🟢 <b>Hermes 恢复正常</b>\n<code>$(date '+%m-%d %H:%M')</code>"
    rm -f "$STATE"
  fi
fi
