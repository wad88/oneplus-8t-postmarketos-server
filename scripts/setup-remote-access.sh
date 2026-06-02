#!/usr/bin/env bash
# =============================================================================
# setup-remote-access.sh
# -----------------------------------------------------------------------------
# 在一加 8T(kebab, ARM64) 的 Ubuntu 容器(LXC/chroot)里, 一键配置两套远程访问:
#   1) Tailscale       —— 私有 WireGuard mesh, 用于 SSH/管理面 (对公网不可见)
#   2) Cloudflare Tunnel—— 把选定 HTTP 服务经自有域名公开 (无需开端口)
#
# 设计: set -euo pipefail / 幂等 / 全中文注释 / 参数化 / systemd优先,无则降级
# 需要交互式浏览器登录的步骤已用 [需手动浏览器登录] 标注。
#
# ★ 本版相对初稿的修复 (经 SRE 评审):
#   [FIX1] 最严重: 初稿 `cloudflared tunnel list` 裸调用, 不带 $SUDO/TUNNEL_ORIGIN_CERT,
#          会去错误的 ~/.cloudflared 找 cert -> list 恒空 -> 幂等检测永远判定不存在 ->
#          第二次跑 create 报 already exists 触发 set -e 中止 / UUID 解析空。
#          已统一封装 cf() 注入 cert+sudo, 且改用 `--output json` + python 解析, 不依赖列序。
#   [FIX2] 无 systemd 分支 nohup 起 tailscaled 前未 mkdir state/socket 目录 -> 启动失败。已补 mkdir -p。
#   [FIX3] userspace-networking 模式下 --advertise-routes 实际不工作(用户态无内核转发)。已 warn。
#   [FIX4] cred 搬运 find /root/.cloudflared 未带 sudo, 非 root 读不到。已用 cf 上下文统一目录。
# =============================================================================

set -euo pipefail

# ----- 0. 参数 (环境变量覆盖) -----
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"
TS_ADVERTISE_ROUTES="${TS_ADVERTISE_ROUTES:-}"
TS_ENABLE_SSH="${TS_ENABLE_SSH:-1}"
TS_AUTHKEY="${TS_AUTHKEY:-}"

CF_TUNNEL_NAME="${CF_TUNNEL_NAME:-phone-agent-home}"
CF_HOSTNAME="${CF_HOSTNAME:-dash.example.com}"
CF_LOCAL_PORT="${CF_LOCAL_PORT:-8080}"
CF_LOCAL_URL="${CF_LOCAL_URL:-http://localhost:${CF_LOCAL_PORT}}"
CF_HA_HOSTNAME="${CF_HA_HOSTNAME:-}"
CF_HA_LOCAL_URL="${CF_HA_LOCAL_URL:-http://localhost:8123}"

if [ "$(id -u)" -eq 0 ]; then CF_CONFDIR="/etc/cloudflared"; else CF_CONFDIR="${HOME}/.cloudflared"; fi

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else err "非 root 且无 sudo, 特权操作会失败"; exit 1; fi
fi

has_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

arch_guard() {
  local m; m="$(uname -m)"
  case "$m" in
    aarch64|arm64) : ;;
    *) warn "架构=${m}, 本脚本按 ARM64 设计, 继续可能下错二进制。" ;;
  esac
}

# [FIX1+FIX4] cloudflared 统一封装: 始终带 cert 上下文 + sudo, 所有调用(含 list)走它
cf() {
  $SUDO env TUNNEL_ORIGIN_CERT="${CF_CONFDIR}/cert.pem" cloudflared "$@"
}

# =============================================================================
# 第一部分: Tailscale
# =============================================================================
install_tailscale() {
  log "===== 安装/配置 Tailscale ====="
  if command -v tailscale >/dev/null 2>&1; then
    log "tailscale 已装: $(tailscale version | head -n1), 跳过安装。"
  else
    log "官方脚本安装 tailscale (大陆通常可直连 tailscale.com)..."
    if ! curl -fsSL https://tailscale.com/install.sh | $SUDO sh; then
      err "Tailscale 安装脚本下载失败, 检查 DNS 或设 https_proxy 后重试。"; return 1
    fi
  fi

  if has_systemd; then
    log "启用 tailscaled 系统服务..."
    $SUDO systemctl enable --now tailscaled || warn "tailscaled enable/start 告警, 继续。"
  else
    if pgrep -x tailscaled >/dev/null 2>&1; then
      log "tailscaled 已在运行(非 systemd)。"
    else
      warn "无 systemd, 用 nohup 后台起 tailscaled (重启不自恢复, 建议交给 zellij/启动脚本)。"
      # [FIX2] 先建 state/socket 目录, 否则 tailscaled 起不来
      $SUDO mkdir -p /var/lib/tailscale /run/tailscale
      $SUDO sh -c 'nohup tailscaled --tun=userspace-networking \
        --state=/var/lib/tailscale/tailscaled.state \
        --socket=/run/tailscale/tailscaled.sock \
        >/var/log/tailscaled.log 2>&1 &'
      sleep 2
    fi
  fi

  local up_args=(--hostname "$TS_HOSTNAME" --accept-routes)
  [ "$TS_ENABLE_SSH" = "1" ] && up_args+=(--ssh)
  if [ -n "$TS_ADVERTISE_ROUTES" ]; then
    up_args+=(--advertise-routes "$TS_ADVERTISE_ROUTES")
    # [FIX3] 无 systemd 走 userspace 模式时子网路由实际不通, 明确警告
    if ! has_systemd; then
      warn "注意: 当前为 userspace-networking 模式, --advertise-routes 子网路由实际【不会生效】"
      warn "      (用户态网络栈无内核转发能力)。如需子网路由, 用 root+内核态 tailscaled。"
    fi
  fi

  if [ -n "$TS_AUTHKEY" ]; then
    log "用 auth key 自动登录 (无需浏览器)..."
    up_args+=(--authkey "$TS_AUTHKEY")
    $SUDO tailscale up "${up_args[@]}"
  else
    log "===== [需手动浏览器登录] ====="
    log "tailscale up 会打印 https://login.tailscale.com/... 链接, 用浏览器打开登录授权。"
    [ -n "$TS_ADVERTISE_ROUTES" ] && warn "广播子网后还需到后台 Machines 页对本机批准路由。"
    $SUDO tailscale up "${up_args[@]}"
  fi

  log "Tailscale 状态:"; $SUDO tailscale status || true
  log "本机 tailnet IP: $($SUDO tailscale ip -4 2>/dev/null || echo '未分配')"
  echo
}

# =============================================================================
# 第二部分: Cloudflare Tunnel
# =============================================================================
install_cloudflared_binary() {
  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared 已装: $(cloudflared --version 2>/dev/null | head -n1), 跳过。"; return 0
  fi
  log "下载 cloudflared (linux-arm64 .deb)..."
  local deb="/tmp/cloudflared-linux-arm64.deb"
  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"
  if command -v apt-get >/dev/null 2>&1; then
    if curl -fL --retry 3 -o "$deb" "$url"; then
      $SUDO apt-get install -y "$deb" || $SUDO dpkg -i "$deb"; rm -f "$deb"
    else
      warn ".deb 下载失败, 回退裸二进制。"; _install_cloudflared_raw_binary
    fi
  else
    _install_cloudflared_raw_binary
  fi
  command -v cloudflared >/dev/null 2>&1 && log "cloudflared 安装成功: $(cloudflared --version | head -n1)"
}

_install_cloudflared_raw_binary() {
  local bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  curl -fL --retry 3 -o /tmp/cloudflared "$bin_url"
  $SUDO install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared
  rm -f /tmp/cloudflared
}

# [FIX1] 用 --output json + python 解析, 不依赖列序/表头
tunnel_uuid_by_name() {
  local name="$1"
  cf tunnel list --output json 2>/dev/null | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
name = sys.argv[1]
for t in data:
    if t.get("name") == name:
        print(t.get("id", ""))
        break
' "$name" 2>/dev/null || true
}

configure_cloudflared_tunnel() {
  log "===== 配置 Cloudflare Tunnel ====="
  $SUDO mkdir -p "$CF_CONFDIR"

  # 步骤1: 登录 (颁发 cert.pem)
  if $SUDO test -f "${CF_CONFDIR}/cert.pem"; then
    log "已存在 ${CF_CONFDIR}/cert.pem, 跳过登录。"
  else
    log "===== [需手动浏览器登录] ====="
    log "cloudflared tunnel login 会打印 dash.cloudflare.com 链接 -> 选域名(zone) -> 授权。"
    cf tunnel login
  fi

  # 步骤2: 创建命名隧道 (幂等, [FIX1] 用统一 cf + json 解析)
  local tunnel_uuid
  tunnel_uuid="$(tunnel_uuid_by_name "$CF_TUNNEL_NAME")"
  if [ -n "$tunnel_uuid" ]; then
    log "隧道 '${CF_TUNNEL_NAME}' 已存在(UUID=${tunnel_uuid}), 复用。"
  else
    log "创建隧道 '${CF_TUNNEL_NAME}' ..."
    cf tunnel create "$CF_TUNNEL_NAME"
    tunnel_uuid="$(tunnel_uuid_by_name "$CF_TUNNEL_NAME")"
  fi
  [ -z "${tunnel_uuid:-}" ] && { err "未能解析隧道 UUID, 请手动检查 'cloudflared tunnel list'。"; return 1; }
  log "隧道 UUID = ${tunnel_uuid}"

  # [FIX4] create 默认把凭据写到 cert 所在目录(因为我们注入了 TUNNEL_ORIGIN_CERT),
  # 即 ${CF_CONFDIR}/${uuid}.json; 用 sudo test 确认, 不再跨家目录 find。
  local cred_file="${CF_CONFDIR}/${tunnel_uuid}.json"
  if ! $SUDO test -f "$cred_file"; then
    warn "未在 ${cred_file} 找到凭据文件, 尝试从默认家目录搬运(带 sudo)..."
    local found
    found="$($SUDO find /root/.cloudflared "${HOME}/.cloudflared" -maxdepth 1 -name "${tunnel_uuid}.json" 2>/dev/null | head -n1 || true)"
    if [ -n "$found" ] && [ "$found" != "$cred_file" ]; then
      $SUDO cp "$found" "$cred_file"; log "已搬运凭据到 ${cred_file}。"
    else
      warn "仍未找到凭据文件, tunnel run 可能失败, 请手动确认。"
    fi
  fi

  # 步骤3: 写 config.yml
  log "写入 ${CF_CONFDIR}/config.yml ..."
  $SUDO tee "${CF_CONFDIR}/config.yml" >/dev/null <<EOF
# cloudflared 隧道配置 (由 setup-remote-access.sh 生成)
tunnel: ${tunnel_uuid}
credentials-file: ${cred_file}

ingress:
  # 主服务: 仪表盘 / 自定义 HTTP
  - hostname: ${CF_HOSTNAME}
    service: ${CF_LOCAL_URL}
EOF
  if [ -n "$CF_HA_HOSTNAME" ]; then
    $SUDO tee -a "${CF_CONFDIR}/config.yml" >/dev/null <<EOF

  # Home Assistant (含 WebSocket)
  - hostname: ${CF_HA_HOSTNAME}
    service: ${CF_HA_LOCAL_URL}
    originRequest:
      noTLSVerify: true
      connectTimeout: 30s
EOF
  fi
  $SUDO tee -a "${CF_CONFDIR}/config.yml" >/dev/null <<'EOF'

  # 兜底(必须最后): 未匹配域名一律 404
  - service: http_status:404
EOF

  # 步骤4: DNS 路由
  log "配置 DNS: ${CF_HOSTNAME} -> 隧道 ${CF_TUNNEL_NAME}"
  cf tunnel route dns "$CF_TUNNEL_NAME" "$CF_HOSTNAME" || warn "DNS 路由可能已存在/失败, 到 CF 后台确认 CNAME。"
  if [ -n "$CF_HA_HOSTNAME" ]; then
    cf tunnel route dns "$CF_TUNNEL_NAME" "$CF_HA_HOSTNAME" || warn "HA 域名 DNS 路由可能已存在/失败。"
  fi
  echo
}

setup_cloudflared_autostart() {
  log "===== cloudflared 自启动 ====="
  if has_systemd; then
    log "用 systemd 注册 cloudflared..."
    $SUDO cloudflared --config "${CF_CONFDIR}/config.yml" service install || warn "service install 可能已执行过, 继续。"
    $SUDO systemctl enable --now cloudflared || warn "启动告警, 用 systemctl status cloudflared 排查。"
    log "日志: journalctl -u cloudflared -f"
  else
    warn "无 systemd, cloudflared 无法注册系统服务。手机 24h 场景推荐 zellij 持久会话:"
    echo  "  # zellij 持久会话(断连不杀):"
    echo  "  zellij attach -c cloudflared -- \\"
    echo  "        cloudflared --config ${CF_CONFDIR}/config.yml tunnel run ${CF_TUNNEL_NAME}"
    echo  "  # 或 nohup(重启不恢复):"
    echo  "  nohup cloudflared --config ${CF_CONFDIR}/config.yml tunnel run ${CF_TUNNEL_NAME} >/var/log/cloudflared.log 2>&1 &"
  fi
  echo
}

main() {
  arch_guard
  log "参数预览:"
  log "  TS_HOSTNAME=${TS_HOSTNAME}  TS_SSH=${TS_ENABLE_SSH}  ROUTES=${TS_ADVERTISE_ROUTES:-<无>}"
  log "  TS_AUTHKEY=$([ -n "$TS_AUTHKEY" ] && echo '<已设置,自动登录>' || echo '<未设置,浏览器登录>')"
  log "  CF_TUNNEL=${CF_TUNNEL_NAME}  ${CF_HOSTNAME}->${CF_LOCAL_URL}"
  [ -n "$CF_HA_HOSTNAME" ] && log "  HA: ${CF_HA_HOSTNAME}->${CF_HA_LOCAL_URL}"
  log "  CF_CONFDIR=${CF_CONFDIR}"
  echo

  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y || true
    $SUDO apt-get install -y curl ca-certificates python3 >/dev/null 2>&1 || true
  fi

  install_tailscale
  install_cloudflared_binary
  configure_cloudflared_tunnel
  setup_cloudflared_autostart

  log "================ 完成 ================"
  [ -z "$TS_AUTHKEY" ] && log "  1) Tailscale: 打开 up 打印的 login 链接登录"
  log "  2) Cloudflare: 首次运行已要求浏览器授权域名(cert.pem)"
  log "  - tailscale ip -4 拿手机 IP, 从任意节点 ssh 用户@<IP>"
  log "  - 浏览器访问 https://${CF_HOSTNAME} 即公网访问本地 ${CF_LOCAL_URL}"
}

main "$@"
