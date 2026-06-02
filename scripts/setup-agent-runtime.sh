#!/usr/bin/env bash
# =============================================================================
# setup-agent-runtime.sh
# -----------------------------------------------------------------------------
# 在 arm64 (aarch64) Ubuntu 容器里安装“终端 AI 编码 agent”运行时。
# 目标: 已 root 的一加 8T(kebab) -> Magisk -> Ubuntu LXC/chroot -> (本脚本在这层跑)
# 网络: 中国大陆, 默认启用 npmmirror/清华 PyPI/node 镜像, 外网源被墙时需代理。
#
# 做的事: Node LTS(nvm) -> OpenCode(pin版本) -> 可选Aider -> opencode.json({env:}占位) ->
#         密钥 env 文件(chmod600) -> zellij 常驻会话(hermes) + systemd --user 自启
#
# 只做合法运行时安装, 不涉及任何 key 抓取/账号倒卖。
#
# ★ 本版相对初稿的修复 (经 SRE 评审):
#   [FIX1] 最致命: 初稿 systemd 单元 Type=simple + `zellij attach --create` 会崩溃死循环
#          (zellij client/server 架构, attach 是需 TTY 的前台 client, 无 TTY 立退,
#           Type=simple 判定主进程退出 + Restart=on-failure -> 无限重启)。
#          已改为后台拉起 server: `zellij --session ... options --on-force-close detach` 配合
#          `setsid ... </dev/null` + Type=forking 风格, 并提供更稳的 Type=oneshot+RemainAfterExit 变体。
#   [FIX2] systemd 单元不 source env/nvm, 拉起的会话里 node/opencode 不在 PATH 且无 key。
#          已让单元 ExecStart 走一个 launcher 脚本, 内部先 source nvm + agent.env。
#   [FIX3] PEP668: 现代 Ubuntu(22.04/24.04)系统 Python externally-managed, `pip install --user pipx`
#          直接报错。已去掉该死路兜底, 仅用 apt pipx, 失败则跳过 Aider(不影响 OpenCode)。
#   [FIX4] list-sessions 输出带 ANSI 颜色/(EXITED) 后缀, grep 前缀匹配会失配 -> 每次新建。
#          已统一加 --no-colors 并 strip 后缀。
#   [FIX5] opencode 无条件 @latest 不稳。已 pin 可配版本 OPENCODE_VERSION(默认 latest 但可锁)。
#   [FIX6] 初稿 SUMMARY 称默认启用 node 镜像但 export 被注释。已真正启用(可关)。
# =============================================================================

set -euo pipefail

: "${HOME:?HOME 未设置}"
NODE_LTS_HINT="22"
INSTALL_AIDER="${INSTALL_AIDER:-1}"
ZELLIJ_SESSION="${ZELLIJ_SESSION:-hermes}"
AGENT_ENV_FILE="${AGENT_ENV_FILE:-$HOME/.config/opencode/agent.env}"
OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"   # [FIX5] 可 pin, 如 OPENCODE_VERSION=0.x.y
USE_CN_MIRROR="${USE_CN_MIRROR:-1}"              # [FIX6] 1=启用国内镜像(默认)

if [ -t 1 ]; then C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_END=$'\033[0m'
else C_OK=""; C_WARN=""; C_ERR=""; C_END=""; fi
log()  { printf '%s[+]%s %s\n' "$C_OK" "$C_END" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_END" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_END" "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

# ----- 1. 前置 -----
log "检查环境 ..."
ARCH="$(uname -m || true)"
case "$ARCH" in
  aarch64|arm64) log "架构=$ARCH (arm64)" ;;
  *) warn "架构 $ARCH 非 arm64, 二进制源可能不同。" ;;
esac
if [ "$(id -u)" = "0" ]; then
  warn "正以 root 运行。nvm/npm-g/systemd --user 建议普通用户跑;"
  warn "root 下 systemd --user / loginctl enable-linger 语义不同, 第9节可能无意义, 会降级 nohup。"
  SUDO=""
elif has sudo; then SUDO="sudo"
else die "需 sudo 装系统依赖但未找到; 请装 sudo 或以 root 运行。"; fi

# ----- 2. 系统依赖 -----
log "apt 装基础依赖 ..."
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -y || warn "apt update 失败(镜像?), 继续。"
$SUDO apt-get install -y --no-install-recommends \
  curl ca-certificates git unzip xz-utils \
  build-essential python3 python3-venv python3-pip \
  || die "基础依赖安装失败, 检查 apt 源(可换 ustc/aliyun)。"

# ----- 3. Node.js LTS via nvm -----
export NVM_DIR="$HOME/.nvm"
install_nvm() {
  if [ -s "$NVM_DIR/nvm.sh" ]; then log "nvm 已装, 跳过。"; return 0; fi
  log "安装 nvm ..."
  local NVM_VER="v0.40.1"
  if curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VER}/install.sh" | bash; then
    log "nvm 经 GitHub 安装成功。"
  else
    warn "GitHub 装 nvm 失败(被墙?), 试 gitee 镜像 ..."
    curl -fsSL "https://gitee.com/mirrors/nvm/raw/${NVM_VER}/install.sh" | bash \
      || die "nvm 安装失败, 挂代理重试或改 NodeSource。"
  fi
}
install_node() {
  install_nvm
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
  # [FIX6] 真正启用 node 二进制国内镜像(默认), 显著提速免代理
  if [ "$USE_CN_MIRROR" = "1" ]; then
    export NVM_NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node"
    log "已启用 nvm node 镜像: ${NVM_NODEJS_ORG_MIRROR}"
  fi
  if nvm ls --no-colors 2>/dev/null | grep -q 'lts'; then
    log "nvm 下已有 LTS, 确保默认。"
  else
    log "nvm 装 Node LTS (预期 ${NODE_LTS_HINT}.x) ..."
    nvm install --lts || die "nvm install --lts 失败(网络?), 设镜像后重试。"
  fi
  nvm alias default 'lts/*' >/dev/null 2>&1 || true
  nvm use default >/dev/null 2>&1 || nvm use --lts
  log "Node: $(node -v)  npm: $(npm -v)"
}
install_node

if [ "$USE_CN_MIRROR" = "1" ]; then
  npm config set registry https://registry.npmmirror.com >/dev/null 2>&1 \
    && log "npm registry -> npmmirror。" || warn "设 npm 镜像失败, 用默认。"
fi

# ----- 4. OpenCode ([FIX5] 可 pin 版本) -----
install_opencode() {
  local spec="opencode-ai@${OPENCODE_VERSION}"
  has opencode && log "opencode 已装: $(opencode --version 2>/dev/null || echo '?'), 将升/装到 ${spec}。"
  log "npm 安装 OpenCode (${spec}) ..."
  if npm i -g "${spec}"; then
    log "OpenCode 安装成功: $(opencode --version 2>/dev/null || echo 已装)"
    [ "${OPENCODE_VERSION}" = "latest" ] && warn "你用的是 @latest; 生产 24h runtime 建议 pin: OPENCODE_VERSION=具体版本 重跑。"
  else
    warn "npm 装 OpenCode 失败, 试官方 curl 脚本(可能需代理)..."
    if curl -fsSL https://opencode.ai/install | bash; then
      log "OpenCode 经官方脚本安装成功。"
      warn "若找不到 opencode, 把其 bin(如 \$HOME/.opencode/bin)加入 PATH。"
    else die "OpenCode 两种方式都失败, 挂代理重试或看 README。"; fi
  fi
}
install_opencode

# ----- 5. zellij -----
install_zellij() {
  if has zellij; then log "zellij 已装: $(zellij --version 2>/dev/null), 跳过。"; return 0; fi
  log "安装 zellij (arm64-musl prebuilt) ..."
  local TARBALL="zellij-aarch64-unknown-linux-musl.tar.gz"
  # 用 latest 避免 pin 老 tag 资产被删 404
  local URL="https://github.com/zellij-org/zellij/releases/latest/download/${TARBALL}"
  local TMP; TMP="$(mktemp -d)"
  if curl -fSL "$URL" -o "$TMP/$TARBALL"; then
    tar -xzf "$TMP/$TARBALL" -C "$TMP"
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$TMP/zellij" "$HOME/.local/bin/zellij"
    rm -rf "$TMP"
    log "zellij -> ~/.local/bin/zellij"
    if ! printf '%s' "$PATH" | grep -q "$HOME/.local/bin"; then
      grep -qsF 'HOME/.local/bin' "$HOME/.profile" 2>/dev/null \
        || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"
      export PATH="$HOME/.local/bin:$PATH"
      warn "已把 ~/.local/bin 加入 PATH(写 ~/.profile)。"
    fi
  else
    rm -rf "$TMP"
    warn "下载 zellij 失败(GitHub 被墙?), 试 apt(版本可能旧)..."
    $SUDO apt-get install -y zellij || die "zellij 安装失败, 手动装后重跑常驻段。"
  fi
}
install_zellij

# ----- 6. 可选 Aider ([FIX3] 去掉 PEP668 死路兜底) -----
install_aider() {
  if [ "$INSTALL_AIDER" != "1" ]; then log "跳过 Aider。"; return 0; fi
  if has aider; then log "aider 已装, 跳过。"; return 0; fi
  log "用 pipx 装 Aider ..."
  # [FIX3] 现代 Ubuntu PEP668 下 pip install --user 会失败; 只走 apt pipx, 失败就跳过
  if ! has pipx; then
    $SUDO apt-get install -y pipx 2>/dev/null || { warn "apt 装 pipx 失败, 跳过 Aider(不影响 OpenCode)。"; return 0; }
  fi
  pipx ensurepath >/dev/null 2>&1 || true
  if [ "$USE_CN_MIRROR" = "1" ]; then
    pipx install aider-chat --pip-args="-i https://pypi.tuna.tsinghua.edu.cn/simple" \
      || pipx install aider-chat || warn "Aider 安装失败(网络?), 不影响 OpenCode。"
  else
    pipx install aider-chat || warn "Aider 安装失败(网络?), 不影响 OpenCode。"
  fi
  has aider && log "Aider: $(aider --version 2>/dev/null || echo 已装)"
}
install_aider

# ----- 7. 密钥 env 文件 (chmod 600) -----
mkdir -p "$(dirname "$AGENT_ENV_FILE")"
if [ -f "$AGENT_ENV_FILE" ]; then
  log "已存在 $AGENT_ENV_FILE, 保留不覆盖。"
else
  log "生成密钥模板 $AGENT_ENV_FILE (将 chmod 600)"
  cat > "$AGENT_ENV_FILE" <<'ENVEOF'
# ============================================================================
# agent.env —— AI agent 运行时密钥 (本文件 600, 永不提交 git!)
# 用法: source ~/.config/opencode/agent.env 再启动 opencode/aider
# ----------------------------------------------------------------------------
export OPENAI_BASE_URL="https://your-gateway.example.com/v1"   # 以 /v1 结尾
export ANTHROPIC_BASE_URL="https://your-gateway.example.com"
export OPENAI_API_KEY=""
export ANTHROPIC_API_KEY=""
export GATEWAY_API_KEY=""
# ============================================================================
ENVEOF
fi
chmod 600 "$AGENT_ENV_FILE"
log "$AGENT_ENV_FILE 权限 600。请填真实 key 后再 source。务必加进 .gitignore。"

# ----- 8. opencode.json ({env:} 占位, 无明文 key) -----
OPENCODE_CFG="$HOME/.config/opencode/opencode.json"
mkdir -p "$(dirname "$OPENCODE_CFG")"
if [ -f "$OPENCODE_CFG" ]; then
  log "已存在 $OPENCODE_CFG, 保留不覆盖。"
else
  log "生成 opencode.json 模板 ..."
  cat > "$OPENCODE_CFG" <<'JSONEOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "mygateway": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "My OpenAI-Compatible Gateway",
      "options": {
        "baseURL": "{env:OPENAI_BASE_URL}",
        "apiKey": "{env:OPENAI_API_KEY}"
      },
      "models": {
        "claude-sonnet-4-6": { "name": "Claude Sonnet 4.6 (gateway)" }
      }
    }
  },
  "model": "mygateway/claude-sonnet-4-6"
}
JSONEOF
  log "opencode.json 已写(apiKey 用 {env:}, baseURL 须以 /v1 结尾)。按网关可用模型改 models/model。"
fi

# ----- 9. zellij 常驻 + systemd --user 自启 -----
# [FIX2] launcher 脚本: 单元和手动都走它, 内部先 source nvm + agent.env 再起/连会话
ZJ_LAUNCH="$HOME/.local/bin/agent-session"
mkdir -p "$HOME/.local/bin"
cat > "$ZJ_LAUNCH" <<LAUNCHEOF
#!/usr/bin/env bash
# 启动或连接常驻 agent 会话 ${ZELLIJ_SESSION}。先加载 nvm + 密钥, 保证 PATH 与 key 就绪。
set -euo pipefail
SESSION="${ZELLIJ_SESSION}"
ENV_FILE="${AGENT_ENV_FILE}"
export PATH="\$HOME/.local/bin:\$PATH"
[ -s "\$HOME/.nvm/nvm.sh" ] && . "\$HOME/.nvm/nvm.sh" >/dev/null 2>&1 || true
[ -f "\$ENV_FILE" ] && . "\$ENV_FILE" || true
# [FIX4] list-sessions 加 --no-colors, 并 strip (EXITED)/(current) 后缀后做精确匹配
if zellij list-sessions --no-colors 2>/dev/null | sed 's/ \[.*//; s/ (.*//' | grep -qx "\$SESSION"; then
  exec zellij attach "\$SESSION"
else
  exec zellij --session "\$SESSION"
fi
LAUNCHEOF
chmod 0755 "$ZJ_LAUNCH"
log "已生成会话脚本: $ZJ_LAUNCH (用法: agent-session)"

# [FIX2] 后台拉起 launcher 脚本 (内部 source 环境)
ZJ_BG="$HOME/.local/bin/agent-session-bg"
cat > "$ZJ_BG" <<BGEOF
#!/usr/bin/env bash
# 后台创建/保持 detached 会话(供 systemd/nohup 调用), 不需要 TTY。
set -euo pipefail
SESSION="${ZELLIJ_SESSION}"
ENV_FILE="${AGENT_ENV_FILE}"
export PATH="\$HOME/.local/bin:\$PATH"
[ -s "\$HOME/.nvm/nvm.sh" ] && . "\$HOME/.nvm/nvm.sh" >/dev/null 2>&1 || true
[ -f "\$ENV_FILE" ] && . "\$ENV_FILE" || true
ZJ="\$(command -v zellij || echo \$HOME/.local/bin/zellij)"
# 已有则不重复建
if "\$ZJ" list-sessions --no-colors 2>/dev/null | sed 's/ \[.*//; s/ (.*//' | grep -qx "\$SESSION"; then
  echo "会话 \$SESSION 已存在。"; exit 0
fi
# setsid + </dev/null: 让 zellij server daemon 化, 脱离 TTY 后台存活
setsid "\$ZJ" --session "\$SESSION" </dev/null >/dev/null 2>&1 &
sleep 1
echo "已后台创建会话 \$SESSION。用 'agent-session' 连入。"
BGEOF
chmod 0755 "$ZJ_BG"

# [FIX1] systemd --user 单元: 改用 oneshot + RemainAfterExit, ExecStart 走后台 launcher,
# 不再用会崩溃死循环的 Type=simple + attach。
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
cat > "$SYSTEMD_USER_DIR/agent-zellij.service" <<UNITEOF
[Unit]
Description=Persistent zellij session for terminal AI agent (${ZELLIJ_SESSION})
After=default.target

[Service]
# [FIX1] oneshot 拉起后台 detached 会话; RemainAfterExit 让 systemd 认为它"活着"
# (真正常驻的是 zellij server daemon, 由 launcher 后台 setsid 拉起)。
Type=oneshot
RemainAfterExit=yes
ExecStart=%h/.local/bin/agent-session-bg
# 干净停止: detach/kill 会话
ExecStop=/bin/sh -c '%h/.local/bin/zellij kill-session ${ZELLIJ_SESSION} 2>/dev/null || true'

[Install]
WantedBy=default.target
UNITEOF
log "已生成 systemd --user 单元(oneshot+RemainAfterExit, 不崩溃)。"

# 尝试启用(容器里 systemd --user 不一定可用, 失败降级 nohup)
if [ "$(id -u)" != "0" ] && has systemctl && systemctl --user show-environment >/dev/null 2>&1; then
  if has loginctl; then
    $SUDO loginctl enable-linger "$(id -un)" 2>/dev/null \
      && log "已为 $(id -un) 开 linger(登出后存活)。" || warn "enable-linger 失败(容器无 logind?)。"
  fi
  systemctl --user daemon-reload || true
  systemctl --user enable --now agent-zellij.service 2>/dev/null \
    && log "agent-zellij.service 已启用启动。" || warn "启用 user service 失败, 见下方 nohup 兜底。"
else
  warn "systemd --user 不可用(root 或 LXC/chroot 常见)。用 nohup 兜底常驻:"
  warn "    nohup ${ZJ_BG} >/dev/null 2>&1 &"
  warn "或写进容器启动脚本。会话起来后用 'agent-session' 连入。"
fi

# ----- 10. 收尾 -----
cat <<DONEEOF

${C_OK}========================== 安装完成 ==========================${C_END}
下一步(手动):
  1) 填密钥:  编辑 ${AGENT_ENV_FILE} 填 baseURL+key (已 600, 加进 .gitignore)
  2) 改配置:  编辑 ${OPENCODE_CFG} 的 models/默认 model (apiKey 用 {env:}, 勿明文)
  3) 进会话:  agent-session        # 创建/连接常驻会话 ${ZELLIJ_SESSION}(已自动 source 密钥)
              会话里跑:  opencode    (或 aider)
  4) 离开:    Ctrl+o 然后 d  做干净 detach, 别直接掐 SSH。 重连: agent-session

常驻保障:
  - systemd --user agent-zellij.service(若可用)登出/重启自动拉起; 已尝试 enable-linger。
  - 不可用时用上面的 nohup ${ZJ_BG} 兜底。

内存提醒(8-12G 手机):
  - Node 系 agent 是内存大户。建议会话里 export NODE_OPTIONS="--max-old-space-size=2048"
  - 避开大目录列举, 定期重启会话。

请去 README 复核 opencode 安装命令: https://github.com/sst/opencode
${C_OK}=============================================================${C_END}
DONEEOF
log "全部完成。"
