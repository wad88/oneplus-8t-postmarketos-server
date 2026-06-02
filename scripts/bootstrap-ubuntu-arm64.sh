#!/usr/bin/env bash
# =============================================================================
# bootstrap-ubuntu-arm64.sh
# -----------------------------------------------------------------------------
# 在「全新 Ubuntu 容器(arm64/aarch64)」内一次性搭好基础环境。
# 目标: 已 root 的一加 8T(kebab) -> Magisk -> Ubuntu(LXC/chroot) -> 容器内 Docker(~6容器)。
#
# 做的事: 时区 -> apt基础包 -> Docker+compose -> zellij -> 非root工作用户 -> daemon.json日志轮转
# 原则: set -euo pipefail / 幂等 / 中文注释 / 自动探测容器类型并降级
#
# ★ 本版相对初稿的修复 (经 SRE 评审):
#   [FIX1] 最危险: 初稿 proot 探测靠 `grep proot /proc/self/status`(检测不到)+未导出的环境变量,
#          目标若是 Termux proot-distro 会被误判 unknown 照常装 dockerd, 违背"proot 自动降级"承诺。
#          已改为多重可靠探测: which proot / ldd 自身 / /proc/1/comm / mount 痕迹 / $PROOT*。
#   [FIX2] 多个 `trap ... EXIT` 互相覆盖 -> 前面的临时文件永不清理。已统一一个 EXIT trap + 清理列表。
#   [FIX3] NOPASSWD:ALL 免密 sudo + docker组 在 24h 联网机上等于双重 root, 危险默认。
#          已改为默认【关闭】免密(WORK_USER_NOPASSWD=0), 需显式开启。
#   [FIX4] 时区幂等判断 `cat /etc/timezone` 在新版 Ubuntu(timedatectl)可能无此文件 -> 恒走重写。
#          已改为优先 readlink /etc/localtime 比较。
# =============================================================================

set -euo pipefail

# ----- 配置 -----
WORK_USER="${WORK_USER:-agent}"
WORK_USER_SHELL="${WORK_USER_SHELL:-/bin/bash}"
WORK_USER_NOPASSWD="${WORK_USER_NOPASSWD:-0}"   # [FIX3] 默认 0=不配免密sudo; 设1才开
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
ZELLIJ_VERSION="${ZELLIJ_VERSION:-latest}"
DOCKER_LOG_MAX_SIZE="${DOCKER_LOG_MAX_SIZE:-10m}"
DOCKER_LOG_MAX_FILE="${DOCKER_LOG_MAX_FILE:-3}"

# [FIX2] 统一的临时文件清理列表 + 单个 EXIT trap
CLEANUP_PATHS=""
cleanup() { for p in $CLEANUP_PATHS; do rm -rf "$p" 2>/dev/null || true; done; }
add_cleanup() { CLEANUP_PATHS="$CLEANUP_PATHS $1"; }
trap 'echo "[ERROR] 第 ${LINENO} 行失败 (退出码 $?)，已中止。" >&2' ERR
trap cleanup EXIT

log()  { echo -e "\033[1;32m[*]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# ----- 0. 前置: root + arm64 -----
if [[ "${EUID}" -ne 0 ]]; then err "请以 root 运行(容器内通常即 root, 否则 sudo)。"; exit 1; fi
ARCH="$(uname -m)"
if [[ "${ARCH}" != "aarch64" && "${ARCH}" != "arm64" ]]; then err "架构 ${ARCH} 非 arm64, 已中止。"; exit 1; fi
log "架构检查通过: ${ARCH}"

# ----- 0.1 [FIX1] 可靠的容器类型探测 -----
CONTAINER_KIND="unknown"
DOCKER_RUNTIME_OK=1

detect_container() {
  # (a) systemd-detect-virt (最权威, 装了 systemd 才有)
  if has_cmd systemd-detect-virt; then
    CONTAINER_KIND="$(systemd-detect-virt --container 2>/dev/null || echo none)"
  fi
  # (b) proot 多重探测 —— 任一命中即判 proot
  local is_proot=0
  # b1: PATH 里有 proot 二进制(Termux proot-distro 环境内常见)
  has_cmd proot && is_proot=1
  # b2: 环境变量(若被导出)
  [[ -n "${PROOT_TMP_DIR:-}${PROOT:-}${PROOT_L2S_DIR:-}" ]] && is_proot=1
  # b3: /proc/1/comm 或 /proc/1/cmdline 含 proot
  if [[ -r /proc/1/comm ]] && grep -qi proot /proc/1/comm 2>/dev/null; then is_proot=1; fi
  if [[ -r /proc/1/cmdline ]] && tr '\0' ' ' </proc/1/cmdline 2>/dev/null | grep -qi proot; then is_proot=1; fi
  # b4: Termux 典型路径痕迹
  [[ -d /data/data/com.termux/files ]] && is_proot=1
  # b5: proot 下 /proc 多为 binfmt 模拟, 常缺 /proc/1/root 或无法读 /proc/1/ns
  if [[ ! -r /proc/1/ns/pid && "${CONTAINER_KIND}" == "none" ]]; then
    warn "无法读取 /proc/1/ns —— 可能是 proot 等受限环境。"
  fi
  [[ "$is_proot" -eq 1 ]] && CONTAINER_KIND="proot"
}
detect_container

case "${CONTAINER_KIND}" in
  proot)
    warn "检测到 proot 环境: 真 Docker 无法在 proot 内运行(无真 namespace/cgroup)。"
    warn "将仅安装 Docker 包但【不启用/不启动 dockerd】。"
    warn "建议把 Docker 放宿主层(真 LXC/chroot); proot 内可考虑 podman+vfs。"
    DOCKER_RUNTIME_OK=0 ;;
  lxc|lxc-libvirt)
    log "LXC 容器。需确认为特权容器或开启 nesting+keyctl(见末尾), 否则 dockerd 起不来。" ;;
  none|unknown)
    log "容器类型: ${CONTAINER_KIND}(可能 chroot/裸环境), 按常规启用 Docker。" ;;
  *)
    log "容器类型: ${CONTAINER_KIND}, 按常规启用 Docker。" ;;
esac

HAVE_SYSTEMD=0
if has_cmd systemctl && [[ -d /run/systemd/system ]]; then HAVE_SYSTEMD=1; fi
[[ "${HAVE_SYSTEMD}" -eq 0 ]] && warn "无运行中 systemd: 服务将用 service 或仅装不自启。"

export DEBIAN_FRONTEND=noninteractive

# ----- 1. [FIX4] 时区 (用 readlink /etc/localtime 比较, 不依赖 /etc/timezone) -----
log "配置时区 ${TIMEZONE} ..."
CUR_TZ=""
if [[ -L /etc/localtime ]]; then
  CUR_TZ="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
elif [[ -f /etc/timezone ]]; then
  CUR_TZ="$(cat /etc/timezone 2>/dev/null || echo '')"
fi
if [[ "${CUR_TZ}" != "${TIMEZONE}" ]]; then
  ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  echo "${TIMEZONE}" > /etc/timezone
  pkg_installed tzdata && dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
  log "时区已设为 ${TIMEZONE}。"
else
  log "时区已是 ${TIMEZONE}(${CUR_TZ}), 跳过。"
fi

# ----- 2. apt 基础包 -----
BASE_PKGS=( curl wget git build-essential ca-certificates gnupg lsb-release
  htop ncdu jq python3 python3-pip tmux openssh-server sudo apt-transport-https )
log "刷新 apt ..."
apt-get update -y
MISSING_PKGS=()
for p in "${BASE_PKGS[@]}"; do pkg_installed "${p}" || MISSING_PKGS+=("${p}"); done
if [[ "${#MISSING_PKGS[@]}" -gt 0 ]]; then
  log "安装: ${MISSING_PKGS[*]}"
  apt-get install -y --no-install-recommends "${MISSING_PKGS[@]}"
else
  log "基础包齐全, 跳过。"
fi
update-ca-certificates >/dev/null 2>&1 || true

# ----- 3. Docker -----
# 方案A get.docker.com(默认); 方案B 手动apt仓库+国内镜像(注释保留)
if has_cmd docker && docker --version >/dev/null 2>&1; then
  log "Docker 已装: $(docker --version), 跳过。"
else
  log "用 get.docker.com 安装 Docker ..."
  GETDOCKER_TMP="$(mktemp /tmp/get-docker.XXXXXX.sh)"
  add_cleanup "${GETDOCKER_TMP}"   # [FIX2] 加入统一清理列表, 不再各自 trap
  if curl -fsSL --connect-timeout 15 --max-time 120 https://get.docker.com -o "${GETDOCKER_TMP}"; then
    sh "${GETDOCKER_TMP}"
    log "Docker 安装完成: $(docker --version 2>/dev/null || echo '版本获取失败')"
  else
    err "下载 get.docker.com 失败(国内可能需镜像源/代理)。"
    err "可改用官方 apt 仓库+清华镜像(见脚本末尾注释), 或配代理重试。"
    exit 1
  fi
fi
if docker compose version >/dev/null 2>&1; then
  log "docker compose 可用: $(docker compose version | head -n1)"
else
  warn "compose 插件不可用, 尝试 apt 装 docker-compose-plugin ..."
  apt-get install -y docker-compose-plugin || warn "compose 插件安装失败, 请手动检查。"
fi

# ----- 3.1 daemon.json 日志轮转 -----
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
DESIRED_DAEMON_JSON="$(cat <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "${DOCKER_LOG_MAX_SIZE}", "max-file": "${DOCKER_LOG_MAX_FILE}" }
}
EOF
)"
mkdir -p /etc/docker
NEED_DAEMON_RELOAD=0
if [[ -f "${DOCKER_DAEMON_JSON}" ]] && diff -q <(echo "${DESIRED_DAEMON_JSON}") "${DOCKER_DAEMON_JSON}" >/dev/null 2>&1; then
  log "daemon.json 已是期望配置, 跳过。"
else
  if [[ -f "${DOCKER_DAEMON_JSON}" ]]; then
    cp -a "${DOCKER_DAEMON_JSON}" "${DOCKER_DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
    warn "已备份原 daemon.json。若原有 registry-mirrors 等需手动合并!"
  fi
  echo "${DESIRED_DAEMON_JSON}" > "${DOCKER_DAEMON_JSON}"
  log "已写日志轮转 (max-size=${DOCKER_LOG_MAX_SIZE} max-file=${DOCKER_LOG_MAX_FILE})。"
  NEED_DAEMON_RELOAD=1
fi

# ----- 3.2 启动 Docker (按容器类型/init 降级) -----
if [[ "${DOCKER_RUNTIME_OK}" -eq 0 ]]; then
  warn "proot 环境不启用 dockerd。Docker 已装, 请到宿主层运行。"
elif [[ "${HAVE_SYSTEMD}" -eq 1 ]]; then
  log "启用并启动 docker.service ..."
  systemctl enable docker >/dev/null 2>&1 || warn "enable docker 失败。"
  if [[ "${NEED_DAEMON_RELOAD}" -eq 1 ]]; then
    systemctl restart docker || warn "重启 docker 失败, 检查 daemon.json 与内核。"
  else
    systemctl start docker || warn "启动 docker 失败, 检查 overlay/cgroup 或 LXC 嵌套。"
  fi
  docker info >/dev/null 2>&1 && log "Docker 守护进程正常。" || warn "dockerd 未就绪: LXC 确认特权/nesting+keyctl, 检查宿主内核 overlayfs/cgroup。"
else
  warn "无 systemd, 尝试 service 启动 docker ..."
  if has_cmd service; then service docker start 2>/dev/null || warn "service docker start 失败, 可手动 nohup dockerd。"
  else warn "无 service 命令。可手动: nohup dockerd >/var/log/dockerd.log 2>&1 &"; fi
fi

# ----- 4. zellij (arm64 musl 静态) -----
ZELLIJ_BIN="/usr/local/bin/zellij"
if has_cmd zellij; then
  log "zellij 已装: $(zellij --version 2>/dev/null || echo '未知'), 跳过。"
else
  log "安装 zellij (GitHub aarch64-musl release) ..."
  ZJ_ASSET="zellij-aarch64-unknown-linux-musl.tar.gz"
  if [[ "${ZELLIJ_VERSION}" == "latest" ]]; then
    ZJ_URL="https://github.com/zellij-org/zellij/releases/latest/download/${ZJ_ASSET}"
  else
    ZJ_URL="https://github.com/zellij-org/zellij/releases/download/${ZELLIJ_VERSION}/${ZJ_ASSET}"
  fi
  ZJ_TMPDIR="$(mktemp -d /tmp/zellij.XXXXXX)"
  add_cleanup "${ZJ_TMPDIR}"   # [FIX2]
  if curl -fSL --connect-timeout 15 --max-time 180 "${ZJ_URL}" -o "${ZJ_TMPDIR}/${ZJ_ASSET}"; then
    tar -xzf "${ZJ_TMPDIR}/${ZJ_ASSET}" -C "${ZJ_TMPDIR}"
    if [[ -f "${ZJ_TMPDIR}/zellij" ]]; then
      install -m 0755 "${ZJ_TMPDIR}/zellij" "${ZELLIJ_BIN}"
      log "zellij 安装完成: $(${ZELLIJ_BIN} --version)"
    else
      warn "tar 内无 zellij 可执行文件, 转 cargo 兜底。"
    fi
  else
    warn "GitHub release 下载失败(可能需代理), 转 cargo 兜底。"
  fi
  if ! has_cmd zellij && [[ ! -x "${ZELLIJ_BIN}" ]]; then
    if has_cmd cargo; then log "cargo 编译 zellij(较慢) ..."; cargo install --locked zellij || warn "cargo 安装失败。"
    else warn "无 cargo 无法兜底, 请装 rustup 后 cargo install --locked zellij, 或挂代理重跑。"; fi
  fi
fi

# ----- 5. 非 root 工作用户 -----
if id -u "${WORK_USER}" >/dev/null 2>&1; then
  log "用户 ${WORK_USER} 已存在, 仅校验组与目录。"
else
  log "创建工作用户 ${WORK_USER} ..."
  useradd -m -s "${WORK_USER_SHELL}" "${WORK_USER}"
  passwd -l "${WORK_USER}" >/dev/null 2>&1 || true   # 锁密码, 强制走 SSH key
fi
getent group docker >/dev/null 2>&1 || groupadd docker
usermod -aG sudo "${WORK_USER}"
usermod -aG docker "${WORK_USER}"
log "用户 ${WORK_USER} 已入 sudo、docker 组。"

# [FIX3] 免密 sudo 默认关闭, 仅 WORK_USER_NOPASSWD=1 时开启
SUDOERS_FILE="/etc/sudoers.d/90-${WORK_USER}-nopasswd"
if [[ "${WORK_USER_NOPASSWD}" == "1" ]]; then
  warn "WORK_USER_NOPASSWD=1: 为 ${WORK_USER} 配置免密 sudo (注意: 24h 联网机上等于双重 root, 谨慎)。"
  if [[ ! -f "${SUDOERS_FILE}" ]]; then
    echo "${WORK_USER} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_FILE}"
    chmod 0440 "${SUDOERS_FILE}"
    if ! visudo -cf "${SUDOERS_FILE}" >/dev/null 2>&1; then
      rm -f "${SUDOERS_FILE}"; warn "sudoers 语法校验失败, 已删除。"
    else log "已配置免密 sudo。"; fi
  else log "免密片段已存在, 跳过。"; fi
else
  # 默认: 若残留旧的免密片段, 主动清掉, 收紧到需密码 sudo
  [[ -f "${SUDOERS_FILE}" ]] && { rm -f "${SUDOERS_FILE}"; warn "已移除残留免密 sudo 片段(默认安全)。"; }
  log "未配置免密 sudo(默认安全)。${WORK_USER} 凭 sudo 组用密码提权。要免密请 WORK_USER_NOPASSWD=1 重跑。"
fi

# SSH key 目录
WORK_HOME="$(getent passwd "${WORK_USER}" | cut -d: -f6)"
SSH_DIR="${WORK_HOME}/.ssh"; AUTH_KEYS="${SSH_DIR}/authorized_keys"
if [[ ! -d "${SSH_DIR}" ]]; then
  install -d -m 0700 -o "${WORK_USER}" -g "${WORK_USER}" "${SSH_DIR}"; log "已建 ${SSH_DIR} (0700)。"
else chmod 0700 "${SSH_DIR}"; fi
if [[ ! -f "${AUTH_KEYS}" ]]; then
  install -m 0600 -o "${WORK_USER}" -g "${WORK_USER}" /dev/null "${AUTH_KEYS}"
  log "已建空 ${AUTH_KEYS} (0600)。把公钥追加: echo '<你的公钥>' >> ${AUTH_KEYS}"
fi

# ----- 5.1 sshd host key + 启动 -----
if has_cmd sshd || [[ -x /usr/sbin/sshd ]]; then
  ssh-keygen -A >/dev/null 2>&1 || true
  if [[ "${HAVE_SYSTEMD}" -eq 1 ]]; then
    systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || warn "enable ssh 失败。"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || warn "启动 ssh 失败。"
    log "sshd 已启用启动。"
  else
    warn "无 systemd: sshd 已装未自启。手动: /usr/sbin/sshd 或 service ssh start"
  fi
fi

# ----- 6. 摘要 -----
log "================ 安装摘要 ================"
echo "  架构        : ${ARCH}"
echo "  容器类型    : ${CONTAINER_KIND}  (systemd: $([[ ${HAVE_SYSTEMD} -eq 1 ]] && echo yes || echo no))"
echo "  时区        : ${TIMEZONE}  / $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Docker      : $(docker --version 2>/dev/null || echo '未装/不可用')"
echo "  compose     : $(docker compose version 2>/dev/null | head -n1 || echo '不可用')"
echo "  zellij      : $(zellij --version 2>/dev/null || echo '未装(看上面日志)')"
echo "  工作用户    : ${WORK_USER}  (组: $(id -nG "${WORK_USER}" 2>/dev/null || echo '?'))"
echo "  免密sudo    : $([[ "${WORK_USER_NOPASSWD}" == "1" ]] && echo '已开(WORK_USER_NOPASSWD=1)' || echo '关(默认安全)')"
echo "  SSH 目录    : ${SSH_DIR}  (把公钥写入 ${AUTH_KEYS})"
echo "  daemon.json : ${DOCKER_DAEMON_JSON} (日志 ${DOCKER_LOG_MAX_SIZE}x${DOCKER_LOG_MAX_FILE})"
log "=========================================="
log "完成。重新登录 ${WORK_USER} 或 newgrp docker 让 docker 组生效。"

# =============================================================================
# 附: 方案B 手动 apt 仓库 + 国内镜像(若 get.docker.com 太慢, 取消注释手动跑):
#   install -m 0755 -d /etc/apt/keyrings
#   curl -fsSL https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu/gpg \
#     | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
#   chmod a+r /etc/apt/keyrings/docker.gpg
#   echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] \
#     https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu $(lsb_release -cs) stable" \
#     > /etc/apt/sources.list.d/docker.list
#   apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io \
#     docker-buildx-plugin docker-compose-plugin
#
# 附: LXC 跑 Docker 需在【宿主 LXC 配置】(非本容器内)开启:
#   security.nesting = true
#   security.syscalls.intercept.mknod = true
#   security.syscalls.intercept.setxattr = true
#   (或直接设特权容器) + 宿主内核加载 overlay/br_netfilter
# =============================================================================

exit 0
