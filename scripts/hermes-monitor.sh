#!/usr/bin/env bash
# Hermes 健康巡检 + IM 卡片播报
# 复刻 MI10-Hermes 那张系统状态卡片：主机/uptime/负载/内存/swap/磁盘/docker/端口HTTP状态/告警
# 用法：cron 或 systemd-timer 周期触发；也可手动 ./hermes-monitor.sh
# 推送通道：默认 ntfy（国内可达、无需翻墙），可切 telegram / bark / 自建 webhook
set -uo pipefail

# ========== 配置区（按需改） ==========
HOST_LABEL="${HOST_LABEL:-op8t-lxc-ubuntu}"   # 卡片里显示的主机名
PUSH_CHANNEL="${PUSH_CHANNEL:-ntfy}"          # ntfy | telegram | bark | webhook | stdout
# ntfy：自建或公共 ntfy.sh，topic 自己起个不易猜的
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-op8t-hermes-CHANGE-ME}"
# telegram（国内常被墙，需手机能直连或走代理）
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
# bark（iOS 推送）
BARK_URL="${BARK_URL:-}"                       # 形如 https://api.day.app/你的key
# 自建 webhook（POST JSON）
WEBHOOK_URL="${WEBHOOK_URL:-}"

# 阈值
MEM_WARN=85      # 内存使用率告警阈值 %
SWAP_WARN=60     # swap 使用率告警阈值 %
DISK_WARN=80     # 根分区使用率告警阈值 %
LOAD_WARN_PER_CORE=1.5  # 每核 1 分钟负载告警阈值

# 要巡检的生产服务端口（名字:端口:期望路径），HTTP 探活
# 期望路径留空则探 /
SERVICES=(
  "homeassistant:8123:/"
  # "kiro-pool:8787:/"
  # "your-svc:9000:/health"
)
# ====================================

emoji_ok="✅"; emoji_warn="🟡"; emoji_bad="❌"; emoji_dot="🟠"

now="$(date '+%Y-%m-%d %H:%M:%S')"
ncores="$(nproc 2>/dev/null || echo 1)"

# ---- uptime ----
uptime_human="$(uptime -p 2>/dev/null | sed 's/^up //')"
[ -z "$uptime_human" ] && uptime_human="$(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);printf "%dd %dh %dm",d,h,m}' /proc/uptime)"

# ---- load ----
read -r l1 l5 l15 _ < /proc/loadavg
load_warn_thr="$(awk -v c="$ncores" -v p="$LOAD_WARN_PER_CORE" 'BEGIN{printf "%.2f", c*p}')"
load_icon="$emoji_ok"
awk -v a="$l1" -v t="$load_warn_thr" 'BEGIN{exit !(a>t)}' && load_icon="$emoji_warn"

# ---- memory / swap (MiB) ----
mem_total=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
mem_avail=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo)
mem_used=$((mem_total-mem_avail))
mem_pct=$(( mem_total>0 ? mem_used*100/mem_total : 0 ))
swap_total=$(awk '/SwapTotal/{printf "%d",$2/1024}' /proc/meminfo)
swap_free=$(awk '/SwapFree/{printf "%d",$2/1024}' /proc/meminfo)
swap_used=$((swap_total-swap_free))
swap_pct=$(( swap_total>0 ? swap_used*100/swap_total : 0 ))
mem_icon="$emoji_ok"; [ "$mem_pct" -ge "$MEM_WARN" ] && mem_icon="$emoji_warn"
swap_icon="$emoji_ok"; [ "$swap_pct" -ge "$SWAP_WARN" ] && swap_icon="$emoji_warn"

# ---- disk / ----
disk_line=$(df -BG / | awk 'NR==2{gsub("G","");print $3" "$2" "$5}')
read -r disk_used disk_total disk_pctraw <<< "$disk_line"
disk_pct=${disk_pctraw%\%}
disk_icon="$emoji_ok"; [ "$disk_pct" -ge "$DISK_WARN" ] && disk_icon="$emoji_dot"

# ---- docker ----
if command -v docker >/dev/null 2>&1; then
  docker_running=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  docker_total=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
  docker_line="${docker_running} 个容器在跑 (共 ${docker_total})"
else
  docker_line="未安装"
fi

# ---- 服务端口 HTTP 探活 ----
svc_lines=""
for s in "${SERVICES[@]}"; do
  IFS=':' read -r sname sport spath <<< "$s"
  [ -z "$spath" ] && spath="/"
  code=$(curl -sk --connect-timeout 4 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${sport}${spath}" 2>/dev/null || echo "000")
  if [ "$code" = "000" ]; then sicon="$emoji_bad"
  elif [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then sicon="$emoji_ok"
  elif [ "$code" = "404" ]; then sicon="$emoji_ok"   # 404 = 服务活着只是没首页
  else sicon="$emoji_warn"; fi
  svc_lines+="${sicon} ${sname} (${sport}) HTTP ${code}\n"
done

# ---- 告警汇总 ----
alerts=""
[ "$swap_pct" -ge "$SWAP_WARN" ] && alerts+="⚠️ Swap 使用 ${swap_pct}% (已吃深)\n"
[ "$disk_pct" -ge "$DISK_WARN" ] && alerts+="⚠️ 根分区 ${disk_pct}% (留意)\n"
[ "$mem_pct" -ge "$MEM_WARN" ] && alerts+="⚠️ 内存 ${mem_pct}%\n"
awk -v a="$l1" -v t="$load_warn_thr" 'BEGIN{exit !(a>t)}' && alerts+="⚠️ 负载 ${l1} 超过 ${load_warn_thr}\n"

if [ -n "$alerts" ]; then status_emoji="🟡"; status_text="系统状态 · 有告警"; else status_emoji="🟢"; status_text="系统状态 · 正常"; fi

# ---- 组装卡片（纯文本，多通道通用） ----
card="$(printf '%s %s\n%s\n\n主机: %s    Uptime: %s\n负载 1/5/15: %s %s / %s / %s\nHermes Gateway: %s active\n\n内存 %s %sM / %sM (%s%%)  可用 %sM\nSwap   %s %sM / %sM (%s%%)\n磁盘 / %s %sG / %sG (%s%%)\nDocker: %s\n\n生产服务端口:\n%b' \
  "$status_emoji" "$status_text" "$now" \
  "$HOST_LABEL" "$uptime_human" \
  "$load_icon" "$l1" "$l5" "$l15" \
  "$emoji_ok" \
  "$mem_icon" "$mem_used" "$mem_total" "$mem_pct" "$mem_avail" \
  "$swap_icon" "$swap_used" "$swap_total" "$swap_pct" \
  "$disk_icon" "$disk_used" "$disk_total" "$disk_pct" \
  "$docker_line" \
  "${svc_lines:-（无）\n}")"

if [ -n "$alerts" ]; then
  card+="$(printf '\n告警:\n%b' "$alerts")"
fi

# ---- 推送 ----
push() {
  local title="$1" body="$2"
  case "$PUSH_CHANNEL" in
    stdout)
      printf '%s\n' "$body" ;;
    ntfy)
      curl -s --connect-timeout 8 \
        -H "Title: ${title}" \
        -H "Priority: $([ -n "$alerts" ] && echo high || echo default)" \
        -H "Tags: $([ -n "$alerts" ] && echo warning || echo white_check_mark)" \
        -d "$body" "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null ;;
    telegram)
      curl -s --connect-timeout 8 \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${title}"$'\n'"${body}" \
        -d "disable_web_page_preview=true" >/dev/null ;;
    bark)
      curl -s --connect-timeout 8 \
        -X POST "${BARK_URL}" \
        -d "title=${title}" --data-urlencode "body=${body}" >/dev/null ;;
    webhook)
      curl -s --connect-timeout 8 -X POST "$WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        --data "$(printf '{"title":%s,"text":%s}' "$(printf '%s' "$title" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" "$(printf '%s' "$body" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")" >/dev/null ;;
    *)
      printf '%s\n' "$body" ;;
  esac
}

push "${status_emoji} ${HOST_LABEL} ${status_text}" "$card"

# 同时落地一份到本地日志，便于排查
log_dir="${HERMES_LOG_DIR:-$HOME/.hermes}"
mkdir -p "$log_dir"
printf '===== %s =====\n%s\n\n' "$now" "$card" >> "$log_dir/status.log"
# 只保留最近 2000 行
tail -n 2000 "$log_dir/status.log" > "$log_dir/status.log.tmp" 2>/dev/null && mv "$log_dir/status.log.tmp" "$log_dir/status.log"
