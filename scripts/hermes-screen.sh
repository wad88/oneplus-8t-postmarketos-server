#!/bin/sh
# hermes-screen.sh — 把系统状态卡片定时刷在设备屏幕(tty0 framebuffer)
# 当迷你监控屏。对标 MI10-Hermes 卡片,直接显示在8T屏上。
TTY=/dev/tty0
INTERVAL="${SCREEN_INTERVAL:-15}"

# 大字体(终端字体) + 关光标闪烁
setfont /usr/share/consolefonts/ter-128n.psf.gz -C "$TTY" 2>/dev/null || \
setfont /usr/share/consolefonts/ter-132n.psf.gz -C "$TTY" 2>/dev/null || true
# 关屏幕空白/省电黑屏(让监控屏常亮)
setterm -blank 0 -powersave off -C "$TTY" 2>/dev/null || true
printf '\033[?25l' > "$TTY" 2>/dev/null   # 隐藏光标

draw() {
  HOST=$(hostname)
  UP=$(uptime | sed 's/.*up //; s/,  *[0-9]* user.*//; s/,  *load.*//')
  LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
  MEM_T=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  MEM_A=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  MEM_P=$(( (MEM_T-MEM_A)*100/MEM_T ))
  DROOT=$(df -h /var/lib/docker 2>/dev/null | awk 'NR==2{print $3"/"$2" "$5}')
  [ -z "$DROOT" ] && DROOT=$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" "$5}')
  DKN=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  TEMP=""
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$z" ] || continue; t=$(cat "$z" 2>/dev/null)
    [ "$t" -gt 1000 ] 2>/dev/null && t=$((t/1000))
    [ "$t" -gt "${TEMP:-0}" ] 2>/dev/null && TEMP=$t
  done
  # 服务探活
  ha="X"; ntfy="X"
  wget -q -O /dev/null -T 3 http://127.0.0.1:8123/ 2>/dev/null && ha="OK"
  wget -q -O /dev/null -T 3 http://127.0.0.1:8080/v1/health 2>/dev/null && ntfy="OK"
  agent=$(rc-service hermes-agent status 2>/dev/null | grep -q started && echo OK || echo X)
  NOW=$(date '+%m-%d %H:%M:%S')
  ICON="*"; [ "$MEM_P" -ge 90 ] && ICON="!"

  # 清屏 + 输出卡片
  {
    printf '\033[2J\033[H'   # clear + home
    echo ""
    echo "  [$ICON] HERMES  $NOW"
    echo "  ================================"
    echo "  host : $HOST"
    echo "  up   : $UP"
    echo "  load : $LOAD"
    echo "  mem  : ${MEM_P}% used (${MEM_A}M free)"
    echo "  disk : $DROOT"
    [ -n "$TEMP" ] && echo "  temp : ${TEMP} C"
    echo "  docker: $DKN containers"
    echo "  --------------------------------"
    echo "  HA:$ha  ntfy:$ntfy  agent:$agent"
    echo "  ================================"
  } > "$TTY" 2>/dev/null
}

while true; do
  draw
  sleep "$INTERVAL"
done
