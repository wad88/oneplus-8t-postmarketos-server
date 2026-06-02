#!/usr/bin/env bash
# =============================================================================
# deploy-stack.sh
# -----------------------------------------------------------------------------
# 一加 8T (kebab / 骁龙865) 刷成 postmarketOS 后的【设备侧】部署脚本。
#
# 适用场景：
#   - 已经刷完 pmOS（v25.06+，Alpine 3.22 基底，本机 init=systemd channel=edge,
#     ui=none/console），并且已经 SSH 进入设备。
#   - 目标：无头 24x7 Docker 主机，跑 Docker + Home Assistant + 监控 + 内网穿透。
#   - 本脚本【不涉及刷机本身】，只做刷机后的运行时部署。
#
# 设计原则：
#   - set -euo pipefail：任何未处理错误/未定义变量/管道失败都立即中止。
#   - 幂等：可重复运行；已完成的步骤会检测并跳过，不重复安装/重复 docker run。
#   - 防御式：内核能力缺关键项时【不硬继续】部署 Docker，只告警并给出后续建议。
#   - init 兼容：优先 systemd(systemctl)，自动兜底 OpenRC(rc-update/rc-service)。
#   - 离线优先：检测到 ~/op8t-assets 本地离线资产则优先用本地，否则联网。
#   - 不硬编码任何 token/密钥：穿透/推送的凭据一律环境变量或交互提示，
#     并明确提醒不要写进脚本或日志。
#
# bash -n 自检思路（本机为 x86_64/Windows，无法在目标 arm64 上真正运行，
# 故只能做静态语法核验）：
#   1) 在任意有 bash 的环境执行：  bash -n scripts/deploy-stack.sh
#      只检查语法，不执行任何命令，安全。
#   2) 可选 shellcheck scripts/deploy-stack.sh 做更深静态分析。
#   3) 本脚本所有 here-doc 用引号定界（<<'EOF'）避免变量被宿主机提前展开；
#      所有数组/变量引用都加引号；trap/cleanup 在脚本顶部定义，确保中断可清理。
#
# 用法（在设备上）：
#   chmod +x deploy-stack.sh
#   ./deploy-stack.sh                 # 完整部署
#   DRY_RUN=1 ./deploy-stack.sh       # 只打印不执行（核验流程）
#   SKIP_HA=1 ./deploy-stack.sh       # 跳过 Home Assistant
#   MONITOR=kuma ./deploy-stack.sh    # 监控用 uptime-kuma（默认 ntfy）
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# 可调变量（全部支持环境变量覆盖；默认值与 prefetch-assets.sh 对齐）
# ----------------------------------------------------------------------------
ASSET_DIR="${ASSET_DIR:-$HOME/op8t-assets}"          # 离线资产根目录
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/arm64}"    # 强制 arm64，避免拉错架构
DATA_ROOT="${DATA_ROOT:-/opt/hermes}"                # 容器持久化数据根目录
DRY_RUN="${DRY_RUN:-0}"                              # 1=只打印不执行
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-0}"      # 1=跳过装 Docker（已装好）
SKIP_HA="${SKIP_HA:-0}"                              # 1=跳过 Home Assistant
MONITOR="${MONITOR:-ntfy}"                           # ntfy | kuma | none
FORCE_DOCKER="${FORCE_DOCKER:-0}"                    # 1=内核缺项也强行装 Docker（危险）
THERMAL_WARN_C="${THERMAL_WARN_C:-65}"               # 温度告警阈值(℃)
THERMAL_CRIT_C="${THERMAL_CRIT_C:-80}"               # 温度严重阈值(℃)

HA_IMAGE="${HA_IMAGE:-ghcr.io/home-assistant/home-assistant:stable}"
NTFY_IMAGE="${NTFY_IMAGE:-binwiederhier/ntfy:latest}"
KUMA_IMAGE="${KUMA_IMAGE:-louislam/uptime-kuma:1}"

HA_NAME="${HA_NAME:-homeassistant}"
NTFY_NAME="${NTFY_NAME:-ntfy}"
KUMA_NAME="${KUMA_NAME:-uptime-kuma}"
NTFY_PORT="${NTFY_PORT:-8083}"
KUMA_PORT="${KUMA_PORT:-3001}"

LOG='[deploy]'
INIT_SYSTEM=''            # systemd | openrc | unknown，由 detect_init 填充
KERNEL_BLOCKERS=()        # 缺失的【关键】内核项（缺则不部署 Docker）
KERNEL_WARNINGS=()        # 缺失的【次要/可后补】内核项

# ----------------------------------------------------------------------------
# 日志与执行辅助
# ----------------------------------------------------------------------------
log(){  printf '%s %s\n' "$LOG" "$*"; }
warn(){ printf '%s [WARN] %s\n' "$LOG" "$*" >&2; }
err(){  printf '%s [ERR ] %s\n' "$LOG" "$*" >&2; }
hr(){   printf '%s ----------------------------------------------------------------\n' "$LOG"; }

# run：统一执行入口，支持 DRY_RUN 只打印不执行
run(){
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s [dry-run] %s\n' "$LOG" "$*"
    return 0
  fi
  "$@"
}

# 是否 root：很多步骤需要 root（pmOS console 默认可 su / 或已是 root SSH）
SUDO=''
ensure_privilege(){
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO='sudo'
      warn "当前非 root，已启用 sudo 前缀。若 sudo 不可用请直接以 root 运行。"
    else
      err "当前非 root 且无 sudo。请 'su -' 切 root 后重跑本脚本。"
      exit 1
    fi
  fi
}
# 以 root 权限执行（DRY_RUN 下只打印）
srun(){
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s [dry-run] %s %s\n' "$LOG" "$SUDO" "$*"
    return 0
  fi
  if [[ -n "$SUDO" ]]; then sudo "$@"; else "$@"; fi
}

have(){ command -v "$1" >/dev/null 2>&1; }

# 清理：当前脚本不创建临时文件，预留 trap 以便后续扩展
cleanup(){ :; }
trap cleanup EXIT

# ----------------------------------------------------------------------------
# 0) init 系统检测：systemd 优先，OpenRC 兜底
# ----------------------------------------------------------------------------
detect_init(){
  hr; log "## 0/8 检测 init 系统"
  if have systemctl && { [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; }; then
    INIT_SYSTEM='systemd'
    log "init = systemd（与 pmOS systemd-edge channel 一致）"
  elif have rc-service && have rc-update; then
    INIT_SYSTEM='openrc'
    log "init = OpenRC（systemd 未就绪，已兜底到 OpenRC）"
  else
    INIT_SYSTEM='unknown'
    warn "未能识别 init 系统：systemctl / rc-service 均不可用。"
    warn "服务自启相关步骤将被跳过，需手动处理。"
  fi
}

# 通用：启用并启动一个服务（屏蔽 systemd/OpenRC 差异）
svc_enable_start(){
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd)
      srun systemctl enable "$svc" || warn "systemctl enable $svc 失败（可能无对应 unit）"
      srun systemctl restart "$svc" || warn "systemctl restart $svc 失败"
      ;;
    openrc)
      srun rc-update add "$svc" default || warn "rc-update add $svc 失败（可能无对应 init 脚本）"
      srun rc-service "$svc" restart || warn "rc-service $svc restart 失败"
      ;;
    *)
      warn "init 未知，跳过启用服务 $svc，请手动确认其开机自启。"
      ;;
  esac
}

# 通用：查询服务是否在跑
svc_is_active(){
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd) systemctl is-active --quiet "$svc";;
    openrc)  rc-service "$svc" status >/dev/null 2>&1;;
    *)       return 1;;
  esac
}

# ----------------------------------------------------------------------------
# 1) 环境自检：网络 / WiFi(ath11k) / 包管理器
# ----------------------------------------------------------------------------
self_check_env(){
  hr; log "## 1/8 环境自检（系统 / 网络 / WiFi）"
  log "uname: $(uname -a 2>/dev/null || echo '?')"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    log "os-release: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
  fi
  local arch; arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64) log "架构=$arch（目标 arm64 OK）";;
    *) warn "架构=$arch 不是 arm64？请确认是否真的在 8T 设备上运行。";;
  esac

  # 包管理器探测（pmOS=apk；脚本仅在确需装包时用到）
  if have apk; then log "包管理器: apk（Alpine 基底，符合预期）"
  elif have apt-get; then warn "包管理器: apt-get（非 Alpine？请确认目标系统）"
  else warn "未发现 apk/apt-get，装包步骤可能失败。"; fi

  # --- WiFi / ath11k 自检 ---
  log "WiFi 芯片自检（QCA6390 / ath11k）："
  if have dmesg; then
    local ath; ath="$(dmesg 2>/dev/null | grep -i ath11k | tail -n 5 || true)"
    if [[ -n "$ath" ]]; then
      log "  dmesg ath11k 命中（尾部）："
      printf '%s        %s\n' "$LOG" "$ath" | sed "s/^/    /"
    else
      warn "  dmesg 未见 ath11k：固件可能未加载，wlan0 可能不存在。"
      warn "  检查固件: ls /lib/firmware/ath11k/QCA6390/ ；缺则需补 firmware 包/文件。"
    fi
  else
    warn "  dmesg 不可用，跳过内核日志检查。"
  fi

  # 网卡链路状态
  if have ip; then
    log "  网络接口链路状态："
    ip -brief link 2>/dev/null | sed "s/^/    /" || true
    if ip link show wlan0 >/dev/null 2>&1; then
      log "  wlan0 已存在。"
    else
      warn "  未发现 wlan0：WiFi 未起来。无头机请确保有【可用网络】（USB 网卡/有线/已配好 wlan0）。"
    fi
  else
    warn "  ip 命令不可用。"
  fi

  # NetworkManager 设备状态（pmOS 默认 NM）
  if have nmcli; then
    log "  nmcli 设备状态："
    nmcli -t -f DEVICE,TYPE,STATE dev 2>/dev/null | sed "s/^/    /" || true
  else
    warn "  nmcli 不可用（可能用 iwd/wpa_supplicant 直连，按你的实际配置确认网络）。"
  fi

  # 出网连通性（不强制，仅提示离线模式）
  log "  出网连通性探测（curl/ping，失败不致命）："
  if have curl && curl -fsS --connect-timeout 8 --max-time 15 -o /dev/null https://github.com 2>/dev/null; then
    log "    出网 OK（可联网拉取）。"
  elif have ping && ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
    log "    ICMP 通但 HTTPS 可能受限：建议优先用离线资产 $ASSET_DIR。"
  else
    warn "    出网失败：将【强依赖】本地离线资产 $ASSET_DIR；缺资产的步骤会失败。"
  fi
}

# ----------------------------------------------------------------------------
# 2) 内核容器能力自检（最关键的一步）
#    检查 zcat /proc/config.gz 中 Docker/容器所需的内核选项。
#    缺关键项时【不硬继续】，只告警并给出 modprobe / 自编内核 建议。
# ----------------------------------------------------------------------------
self_check_kernel(){
  hr; log "## 2/8 内核容器能力自检（Docker 前置硬条件）"

  local cfg_src='' cfg_data=''
  if [[ -r /proc/config.gz ]] && have zcat; then
    cfg_src='/proc/config.gz'
    cfg_data="$(zcat /proc/config.gz 2>/dev/null || true)"
  elif [[ -r "/boot/config-$(uname -r)" ]]; then
    cfg_src="/boot/config-$(uname -r)"
    cfg_data="$(cat "$cfg_src" 2>/dev/null || true)"
  fi

  if [[ -z "$cfg_data" ]]; then
    warn "无法读取内核配置（无 /proc/config.gz 也无 /boot/config-*）。"
    warn "退而求其次：可运行 moby check-config.sh（离线资产里有）做能力探测："
    warn "  $ASSET_DIR/kernel/check-config.sh"
    if [[ -x "$ASSET_DIR/kernel/check-config.sh" ]]; then
      log "  检测到本地 check-config.sh，执行（仅供参考，不作为门禁）："
      "$ASSET_DIR/kernel/check-config.sh" 2>/dev/null | sed "s/^/    /" || true
    fi
    # 没有配置就无法做门禁判断，标记为未知风险但不阻断（交由用户决定）
    KERNEL_WARNINGS+=("无法读取内核配置，能力门禁被跳过")
    return 0
  fi
  log "内核配置来源: $cfg_src"

  # cfg_has NAME：检查 CONFIG_NAME 是 =y 或 =m（built-in 或 module 都算可用）
  cfg_has(){
    local key="CONFIG_$1"
    grep -Eq "^${key}=(y|m)\b" <<<"$cfg_data"
  }

  # 关键项：缺任何一个都视为 Docker 不可靠 -> blocker
  local CRIT=( NAMESPACES PID_NS NET_NS OVERLAY_FS \
               CGROUP_PIDS MEMCG \
               VETH BRIDGE \
               NF_NAT )
  # 次要项：缺了功能受限但常可后补（modprobe / 配置调整）-> warning
  #   BRIDGE_NETFILTER 在旧 sm8250 配置里曾是 'not set'，是已知风险点，
  #   它影响容器间/对外的 NAT 与 iptables 桥接转发，单列重点提示。
  local MINOR=( USER_NS BRIDGE_NETFILTER IP_NF_TARGET_MASQUERADE )

  local k
  log "关键内核项（缺失则阻断 Docker 部署）："
  for k in "${CRIT[@]}"; do
    if cfg_has "$k"; then
      log "  [OK ] CONFIG_$k"
    else
      err "  [MISS] CONFIG_$k  <-- 关键缺失"
      KERNEL_BLOCKERS+=("CONFIG_$k")
    fi
  done

  log "次要/可后补内核项："
  for k in "${MINOR[@]}"; do
    if cfg_has "$k"; then
      log "  [OK ] CONFIG_$k"
    else
      warn "  [MISS] CONFIG_$k  <-- 次要缺失（功能受限，常可 modprobe/后补）"
      KERNEL_WARNINGS+=("CONFIG_$k")
    fi
  done

  # 针对 BRIDGE_NETFILTER 的已知风险点单独强调
  if printf '%s\n' "${KERNEL_WARNINGS[@]:-}" | grep -q 'BRIDGE_NETFILTER'; then
    warn "已知风险点命中：CONFIG_BRIDGE_NETFILTER 缺失（旧 sm8250 配置常见）。"
    warn "  影响：docker 默认 bridge 网络的跨容器/对外 iptables NAT 可能失效。"
    warn "  缓解：HA 用 --network host 可绕开 bridge；若必须用 bridge，"
    warn "        尝试 modprobe br_netfilter，或在自编内核打开 CONFIG_BRIDGE_NETFILTER=y/m。"
  fi

  # 门禁判断
  if [[ "${#KERNEL_BLOCKERS[@]}" -gt 0 ]]; then
    hr
    err "内核缺少关键容器能力，共 ${#KERNEL_BLOCKERS[@]} 项: ${KERNEL_BLOCKERS[*]}"
    err "Docker 在此内核上无法可靠运行。后续处理建议（按成本从低到高）："
    err "  1) 若缺项可作为模块加载：尝试 modprobe（如 overlay / br_netfilter / nf_nat 等），"
    err "     然后重跑本脚本看是否补齐。"
    err "  2) 检查 pmOS 是否提供了更完整的设备内核包（apk search linux-*kebab* / 升级内核）。"
    err "  3) 终极方案：用 pmbootstrap 自编内核，确保打开上述 CONFIG_* （8T 出厂内核"
    err "     曾关闭 PID_NS 等项，这是已知坑，必须自编内核解决）。"
    if [[ "$FORCE_DOCKER" == "1" ]]; then
      warn "FORCE_DOCKER=1：你选择无视门禁强行继续，后果自负。"
    else
      err "已停止后续 Docker 部署（防御式）。修内核后重跑，或 FORCE_DOCKER=1 强行继续。"
      exit 3
    fi
  else
    log "关键内核项齐全，可继续 Docker 部署。"
  fi
}

# ----------------------------------------------------------------------------
# 3) 温度自检（骁龙865 7x24 是头号隐患）
# ----------------------------------------------------------------------------
self_check_thermal(){
  hr; log "## 3/8 温度自检（骁龙865 长期满载散热是头号隐患）"
  local zones found=0 maxc=-1
  zones=$(ls /sys/class/thermal/thermal_zone*/temp 2>/dev/null || true)
  if [[ -z "$zones" ]]; then
    warn "未发现 thermal_zone：无法读取温度。请物理确认散热（贴散热片/小风扇/拆电池长供电）。"
    return 0
  fi
  local z raw c type
  for z in $zones; do
    raw="$(cat "$z" 2>/dev/null || echo '')"
    [[ -z "$raw" || ! "$raw" =~ ^-?[0-9]+$ ]] && continue
    # thermal 一般是毫摄氏度；做个保守换算（>1000 视为 m℃）
    if [[ "$raw" -gt 1000 ]]; then c=$(( raw / 1000 )); else c="$raw"; fi
    type="$(cat "${z%/temp}/type" 2>/dev/null || echo zone)"
    found=$((found+1))
    printf '%s    %-22s %s°C\n' "$LOG" "$type" "$c"
    [[ "$c" -gt "$maxc" ]] && maxc="$c"
  done
  if [[ "$found" -eq 0 ]]; then
    warn "thermal_zone 存在但读数异常，跳过温度判断。"
    return 0
  fi
  log "  当前最高温区: ${maxc}°C（告警阈值 ${THERMAL_WARN_C}°C / 严重 ${THERMAL_CRIT_C}°C）"
  if [[ "$maxc" -ge "$THERMAL_CRIT_C" ]]; then
    err "  温度已达严重阈值！7x24 满载极可能过热降频甚至损坏，请立即加强散热再上业务。"
  elif [[ "$maxc" -ge "$THERMAL_WARN_C" ]]; then
    warn "  温度偏高。无头长跑建议：物理散热片+风扇、限制 CPU 频率、限制容器资源。"
  else
    log "  温度正常。仍建议长期运行做好被动散热并定期巡检（可纳入监控告警）。"
  fi
  log "  提示：可用监控（ntfy/uptime-kuma）周期采集 thermal_zone 温度并推送告警。"
}

# ----------------------------------------------------------------------------
# 4) 安装 Docker（Alpine 用 apk 装 docker；其它系统给提示）
# ----------------------------------------------------------------------------
install_docker(){
  hr; log "## 4/8 安装 Docker"
  if have docker; then
    log "docker 已存在: $(docker --version 2>/dev/null || echo '?')，跳过安装。"
  elif [[ "$SKIP_DOCKER_INSTALL" == "1" ]]; then
    warn "SKIP_DOCKER_INSTALL=1 但未发现 docker，后续步骤可能失败。"
    return 0
  elif have apk; then
    log "用 apk 安装 docker / docker-cli-compose ..."
    srun apk update || warn "apk update 失败（离线？继续尝试本地缓存）"
    # docker-cli-compose 提供 `docker compose` 子命令；幂等：已装会被 apk 跳过
    srun apk add docker docker-cli-compose || {
      err "apk add docker 失败。请确认仓库可达或已配置本地镜像源。"
      exit 4
    }
  elif have apt-get; then
    warn "检测到 apt 系统（非典型 pmOS）。请按官方文档装 docker，再 SKIP_DOCKER_INSTALL=1 重跑。"
    return 0
  else
    err "无 apk/apt-get，无法自动装 Docker。请手动安装后 SKIP_DOCKER_INSTALL=1 重跑。"
    exit 4
  fi

  # 启用并启动 docker 守护进程（systemd 优先，OpenRC 兜底）
  svc_enable_start docker

  # 把当前登录用户加入 docker 组（免 sudo 用 docker；幂等）
  local real_user="${SUDO_USER:-${USER:-}}"
  if [[ -n "$real_user" && "$real_user" != "root" ]] && have addgroup 2>/dev/null; then
    if ! id -nG "$real_user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      srun addgroup "$real_user" docker 2>/dev/null \
        || warn "把 $real_user 加入 docker 组失败（可后续手动 addgroup）。"
      warn "已尝试将 $real_user 加入 docker 组，需【重新登录】后生效。"
    fi
  fi
}

# ----------------------------------------------------------------------------
# 5) 验证 Docker 真能跑容器（不只是 daemon 起来）
# ----------------------------------------------------------------------------
verify_docker(){
  hr; log "## 5/8 验证 Docker 运行时"
  if ! have docker; then err "docker 不存在，无法验证。"; exit 5; fi

  # 等 daemon 就绪（最多 ~30s）
  local i ok=0
  for i in $(seq 1 15); do
    if docker info >/dev/null 2>&1; then ok=1; break; fi
    log "  等待 docker daemon 就绪 ($i/15) ..."
    sleep 2
  done
  if [[ "$ok" -ne 1 ]]; then
    err "docker daemon 未就绪。排查: 日志 / 内核能力 / iptables。"
    err "  systemd: journalctl -u docker -e   |  OpenRC: cat /var/log/docker.log"
    exit 5
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "  [dry-run] 跳过 hello-world 实跑验证。"
    return 0
  fi

  # 优先用离线 hello-world（若预取过），否则联网拉
  log "  跑 hello-world 验证容器创建/网络/overlay ..."
  if docker run --rm --platform "$DOCKER_PLATFORM" hello-world >/dev/null 2>&1; then
    log "  Docker 运行时验证通过。"
  else
    warn "  hello-world 失败（可能无出网或镜像拉取受限）。尝试本地已加载镜像验证..."
    if docker image inspect hello-world >/dev/null 2>&1 \
       && docker run --rm hello-world >/dev/null 2>&1; then
      log "  本地镜像验证通过。"
    else
      err "  Docker 能起 daemon 但跑容器失败。多半是内核网络/overlay 能力或 iptables 问题。"
      err "  这正是 2/8 内核自检关注的点，请回看 BRIDGE_NETFILTER/NF_NAT/OVERLAY_FS。"
      exit 5
    fi
  fi
}

# ----------------------------------------------------------------------------
# 离线/在线镜像准备：检测 ~/op8t-assets/images/<name>.linux-arm64.tar 优先 load
# ----------------------------------------------------------------------------
ensure_image(){
  local image="$1" asset_name="$2"
  if docker image inspect "$image" >/dev/null 2>&1; then
    log "  镜像已在本地: $image"
    return 0
  fi
  local tar="$ASSET_DIR/images/${asset_name}.linux-arm64.tar"
  if [[ -s "$tar" ]]; then
    log "  检测到离线镜像包，docker load: $tar"
    run docker load -i "$tar" || warn "  docker load 失败，将尝试联网拉取。"
  fi
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "  联网拉取镜像: $image (--platform $DOCKER_PLATFORM)"
    run docker pull --platform "$DOCKER_PLATFORM" "$image" || {
      err "  拉取镜像失败: $image。请预取到 $tar 或配置出网/镜像源。"
      return 1
    }
  fi
}

# 幂等地 run 一个容器：已存在同名容器则跳过（不删除已有数据）
container_run_idempotent(){
  local name="$1"; shift
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      log "  容器已在运行: $name（跳过；如需更新请手动 stop/rm 后重跑）。"
    else
      log "  容器已存在但未运行: $name，启动它。"
      run docker start "$name" || warn "  docker start $name 失败。"
    fi
    return 0
  fi
  log "  创建容器: $name"
  run docker run "$@"
}

# ----------------------------------------------------------------------------
# 6) 部署 Home Assistant（官方镜像 + --network host）
# ----------------------------------------------------------------------------
deploy_home_assistant(){
  hr; log "## 6/8 部署 Home Assistant"
  if [[ "$SKIP_HA" == "1" ]]; then warn "SKIP_HA=1，跳过 Home Assistant。"; return 0; fi

  local ha_config="$DATA_ROOT/homeassistant/config"
  run mkdir -p "$ha_config"

  ensure_image "$HA_IMAGE" "home-assistant_stable" || { warn "HA 镜像不可用，跳过。"; return 0; }

  # --network host：绕开 docker bridge（规避 BRIDGE_NETFILTER 缺失风险），
  # 也便于设备/服务发现（mDNS、SSDP）。--privileged 便于访问串口/蓝牙等外设。
  container_run_idempotent "$HA_NAME" \
    -d \
    --name "$HA_NAME" \
    --restart unless-stopped \
    --network host \
    --privileged \
    -e TZ="${TZ:-Asia/Shanghai}" \
    -v "$ha_config":/config \
    -v /run/dbus:/run/dbus:ro \
    "$HA_IMAGE"

  log "  Home Assistant 部署完成。首启需几分钟，随后访问: http://<设备IP>:8123"
  log "  配置目录: $ha_config"
}

# ----------------------------------------------------------------------------
# 7) 部署监控（ntfy 默认 / uptime-kuma 可选 / none）
#    凭据/token 不硬编码：ntfy 可匿名自托管；如需鉴权用环境变量另行配置。
# ----------------------------------------------------------------------------
deploy_monitor(){
  hr; log "## 7/8 部署监控 ($MONITOR)"
  case "$MONITOR" in
    none)
      log "  MONITOR=none，跳过监控部署。"
      ;;
    ntfy)
      local ntfy_data="$DATA_ROOT/ntfy"
      run mkdir -p "$ntfy_data/cache" "$ntfy_data/etc"
      ensure_image "$NTFY_IMAGE" "ntfy_latest" || { warn "ntfy 镜像不可用，跳过。"; return 0; }
      # 自托管 ntfy：监听本机端口；如需公网/鉴权请用 ntfy 自身的 auth 配置，
      # token/密码不要写进本脚本或日志，放到 $ntfy_data/etc/server.yml 并 chmod 600。
      container_run_idempotent "$NTFY_NAME" \
        -d \
        --name "$NTFY_NAME" \
        --restart unless-stopped \
        -p "${NTFY_PORT}:80" \
        -v "$ntfy_data/cache":/var/cache/ntfy \
        -v "$ntfy_data/etc":/etc/ntfy \
        "$NTFY_IMAGE" serve
      log "  ntfy 部署完成: http://<设备IP>:${NTFY_PORT}"
      log "  订阅示例: curl -s http://<设备IP>:${NTFY_PORT}/op8t-hermes/json"
      log "  鉴权/公网暴露请走 ntfy server.yml（凭据不要写进脚本/日志）。"
      ;;
    kuma)
      local kuma_data="$DATA_ROOT/uptime-kuma"
      run mkdir -p "$kuma_data"
      ensure_image "$KUMA_IMAGE" "uptime-kuma_1" || { warn "uptime-kuma 镜像不可用，跳过。"; return 0; }
      container_run_idempotent "$KUMA_NAME" \
        -d \
        --name "$KUMA_NAME" \
        --restart unless-stopped \
        -p "${KUMA_PORT}:3001" \
        -v "$kuma_data":/app/data \
        "$KUMA_IMAGE"
      log "  uptime-kuma 部署完成: http://<设备IP>:${KUMA_PORT}（首次访问设管理员账号，勿写进脚本）。"
      ;;
    *)
      warn "  未知 MONITOR=$MONITOR（支持 ntfy|kuma|none），跳过监控。"
      ;;
  esac
}

# ----------------------------------------------------------------------------
# 8) 打印内网穿透手动步骤（cloudflared / tailscale）
#    一律不自动登录、不硬编码 token；只给可复制的命令模板。
# ----------------------------------------------------------------------------
print_tunnel_steps(){
  hr; log "## 8/8 内网穿透（手动，token/密钥不要写进脚本或日志）"
  local cf_bin=''
  if [[ -x "$ASSET_DIR/cloudflared/cloudflared-linux-arm64" ]]; then
    cf_bin="$ASSET_DIR/cloudflared/cloudflared-linux-arm64"
    log "  检测到离线 cloudflared 二进制: $cf_bin"
  fi

  cat <<'EOF'
[deploy]
[deploy] === 方案 A: Cloudflare Tunnel (cloudflared) ===
[deploy]   1) 安装（若未装）：
[deploy]        # 离线包: 直接用 ~/op8t-assets/cloudflared/cloudflared-linux-arm64
[deploy]        sudo install -m0755 ~/op8t-assets/cloudflared/cloudflared-linux-arm64 /usr/local/bin/cloudflared
[deploy]        # 或在线: cloudflared 官方 arm64 release
[deploy]   2) 登录（会打开浏览器授权，token 写进 ~/.cloudflared，勿贴进日志）：
[deploy]        cloudflared tunnel login
[deploy]   3) 建隧道并路由到本机服务（示例把 HA 8123 暴露到你的域名）：
[deploy]        cloudflared tunnel create op8t
[deploy]        cloudflared tunnel route dns op8t ha.example.com
[deploy]        # 写 ~/.cloudflared/config.yml: tunnel/credentials-file/ingress -> http://localhost:8123
[deploy]   4) 装成服务常驻（systemd 优先，OpenRC 兜底）：
[deploy]        sudo cloudflared service install      # systemd 环境
[deploy]        # OpenRC: 自己写 /etc/init.d/cloudflared 包一层 `cloudflared tunnel run op8t`
[deploy]
[deploy] === 方案 B: Tailscale（更省心，适合纯私网访问）===
[deploy]   1) 安装: apk add tailscale   （Alpine/pmOS）
[deploy]   2) 起服务:
[deploy]        systemctl enable --now tailscaled     # systemd
[deploy]        rc-update add tailscale && rc-service tailscale start   # OpenRC
[deploy]   3) 登录（auth key 用环境变量传入，别写进脚本）：
[deploy]        sudo tailscale up --authkey "$TS_AUTHKEY"   # TS_AUTHKEY 临时 export，用完 unset
[deploy]        # 或交互式: sudo tailscale up   然后浏览器授权
[deploy]   4) 可选当子网路由器/出口节点: tailscale up --advertise-routes=... / --advertise-exit-node
[deploy]
[deploy] 安全提醒：
[deploy]   - 所有 token/authkey/credentials 文件 chmod 600，且不要 echo 到日志、不要进 git。
[deploy]   - 公网暴露的服务（HA/ntfy/kuma）务必开启各自的鉴权，最小化 ingress 暴露面。
EOF
  [[ -n "$cf_bin" ]] && log "  （上面命令里的 cloudflared 可直接用离线二进制 $cf_bin）"
}

# ----------------------------------------------------------------------------
# 收尾汇总
# ----------------------------------------------------------------------------
summary(){
  hr; log "## 部署汇总"
  log "  init 系统      : ${INIT_SYSTEM:-unknown}"
  log "  数据根目录     : $DATA_ROOT"
  log "  离线资产目录   : $ASSET_DIR $( [[ -d "$ASSET_DIR" ]] && echo '(存在)' || echo '(不存在,走在线)')"
  if [[ "${#KERNEL_BLOCKERS[@]}" -gt 0 ]]; then
    err "  内核关键缺失   : ${KERNEL_BLOCKERS[*]}（已按门禁处理）"
  else
    log "  内核关键能力   : 齐全"
  fi
  if [[ "${#KERNEL_WARNINGS[@]}" -gt 0 ]]; then
    warn "  内核次要缺失   : ${KERNEL_WARNINGS[*]}"
  fi
  if have docker && [[ "$DRY_RUN" != "1" ]]; then
    log "  运行中的容器   :"
    docker ps --format '    {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed "s/^/$LOG/" || true
  fi
  log "  后续：按 8/8 的提示手动配置 cloudflared / tailscale（凭据走环境变量，勿入库）。"
  hr; log "完成。"
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
main(){
  log "一加8T-Hermes 设备侧部署开始 (DRY_RUN=$DRY_RUN, MONITOR=$MONITOR)"
  ensure_privilege
  detect_init
  self_check_env
  self_check_kernel       # 内核缺关键项会在此 exit 3（除非 FORCE_DOCKER=1）
  self_check_thermal
  install_docker
  verify_docker
  deploy_home_assistant
  deploy_monitor
  print_tunnel_steps
  summary
}

main "$@"
