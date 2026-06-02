#!/usr/bin/env bash
# =============================================================================
# prefetch-assets.sh
# -----------------------------------------------------------------------------
# 下载/缓存一加8T-Hermes 所需离线资产。
#
# 默认定位：在【目标 arm64 Ubuntu/pmOS】上运行。
# 也允许在 x86_64 PC/WSL 上跨架构预取，但必须显式:
#   ALLOW_CROSS_PREFETCH=1 bash prefetch-assets.sh
# 并且 Docker 镜像一律强制 --platform linux/arm64，避免拉成 amd64。
#
# 本脚本不下载 boot.img / 内核镜像 —— 这些依赖 OOS 版本/槽位或 pmOS 构建输出，不能预取。
# =============================================================================

set -euo pipefail

ASSET_DIR="${ASSET_DIR:-$HOME/op8t-assets}"
ALLOW_CROSS_PREFETCH="${ALLOW_CROSS_PREFETCH:-0}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/arm64}"
SKIP_DOCKER="${SKIP_DOCKER:-0}"
ACC_BRANCH="${ACC_BRANCH:-master}"        # 修复: 不用默认 HEAD(dev)，固定 master
NVM_VER="${NVM_VER:-v0.40.3}"
ZELLIJ_VER="${ZELLIJ_VER:-latest}"
GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX:-}"

HA_IMAGE="${HA_IMAGE:-ghcr.io/home-assistant/home-assistant:stable}"
NTFY_IMAGE="${NTFY_IMAGE:-binwiederhier/ntfy:latest}"
KUMA_IMAGE="${KUMA_IMAGE:-louislam/uptime-kuma:1}"

LOG='[prefetch]'
CURL_OPTS=(--fail --location --retry 3 --retry-delay 3 --connect-timeout 20 --max-time 1800 --show-error --silent)
FAIL_COUNT=0
TMP_FILES=()

log(){ printf '%s %s\n' "$LOG" "$*"; }
warn(){ printf '%s [WARN] %s\n' "$LOG" "$*" >&2; }
err(){ printf '%s [ERR ] %s\n' "$LOG" "$*" >&2; }
fail(){ FAIL_COUNT=$((FAIL_COUNT+1)); }
cleanup(){ for f in "${TMP_FILES[@]:-}"; do rm -f "$f" 2>/dev/null || true; done; }
trap cleanup EXIT

need(){ command -v "$1" >/dev/null 2>&1 || { err "缺少命令: $1"; exit 1; }; }

safe_asset_dir(){
  case "$ASSET_DIR" in
    ""|"/"|"/data"|"/system"|"/vendor"|"/product")
      err "ASSET_DIR=$ASSET_DIR 太危险，拒绝写入。请指定普通目录，如 ~/op8t-assets"; exit 1;;
  esac
  mkdir -p "$ASSET_DIR"/{cloudflared,zellij,kernel,nvm,acc,images,meta}
}

arch_guard(){
  local arch; arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64) log "架构=$arch，目标 arm64 OK";;
    *)
      if [[ "$ALLOW_CROSS_PREFETCH" != "1" ]]; then
        err "当前架构=$arch，不是 arm64。为防拉错包，默认拒绝。"
        err "如果你是在 PC/WSL 上给手机预取，请显式: ALLOW_CROSS_PREFETCH=1 bash prefetch-assets.sh"
        exit 1
      fi
      warn "跨架构预取: 当前=$arch, 目标=$DOCKER_PLATFORM。Docker 镜像将强制 --platform $DOCKER_PLATFORM。"
      ;;
  esac
}

url(){
  local u="$1"
  if [[ -n "$GITHUB_PROXY_PREFIX" && "$u" == https://github.com/* || "$u" == https://raw.githubusercontent.com/* ]]; then
    printf '%s%s' "$GITHUB_PROXY_PREFIX" "$u"
  else
    printf '%s' "$u"
  fi
}

sha_file(){ sha256sum "$1" | awk '{print $1}'; }

fetch(){
  local dest="$1" raw_url="$2" desc="$3"
  mkdir -p "$(dirname "$dest")"
  if [[ -s "$dest" ]]; then
    log "[跳过] $desc 已存在: $dest sha256=$(sha_file "$dest")"
    return 0
  fi
  local tmp; tmp="$(mktemp "${dest}.part.XXXXXX")"; TMP_FILES+=("$tmp")
  local u; u="$(url "$raw_url")"
  log "[下载] $desc"
  log "       $u"
  if curl "${CURL_OPTS[@]}" -o "$tmp" "$u"; then
    mv -f "$tmp" "$dest"
    log "[完成] $dest sha256=$(sha_file "$dest")"
  else
    err "[失败] $desc 下载失败，可设置 HTTPS_PROXY 或 GITHUB_PROXY_PREFIX 后重跑"
    fail
  fi
}

fetch_cloudflared(){
  fetch "$ASSET_DIR/cloudflared/cloudflared-linux-arm64.deb" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb" \
    "cloudflared arm64 deb"
  fetch "$ASSET_DIR/cloudflared/cloudflared-linux-arm64" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" \
    "cloudflared arm64 裸二进制"
  [[ -f "$ASSET_DIR/cloudflared/cloudflared-linux-arm64" ]] && chmod +x "$ASSET_DIR/cloudflared/cloudflared-linux-arm64" || true
}

fetch_zellij(){
  local asset="zellij-aarch64-unknown-linux-musl.tar.gz" base
  if [[ "$ZELLIJ_VER" == "latest" ]]; then
    base="https://github.com/zellij-org/zellij/releases/latest/download"
  else
    base="https://github.com/zellij-org/zellij/releases/download/$ZELLIJ_VER"
  fi
  fetch "$ASSET_DIR/zellij/$asset" "$base/$asset" "zellij aarch64 musl"
  local before_fail="$FAIL_COUNT"
  fetch "$ASSET_DIR/zellij/${asset}.sha256sum" "$base/${asset}.sha256sum" "zellij sha256sum(若官方提供)" || true
  if [[ ! -s "$ASSET_DIR/zellij/${asset}.sha256sum" ]]; then
    FAIL_COUNT="$before_fail"
    warn "zellij 未提供稳定 .sha256sum 资产，已保留本地 sha256 记录。"
  fi
}

fetch_kernel_tools(){
  fetch "$ASSET_DIR/kernel/check-config.sh" \
    "https://raw.githubusercontent.com/moby/moby/master/contrib/check-config.sh" \
    "moby Docker check-config.sh"
  chmod +x "$ASSET_DIR/kernel/check-config.sh" 2>/dev/null || true
}

fetch_nvm(){
  fetch "$ASSET_DIR/nvm/install-${NVM_VER}.sh" \
    "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VER}/install.sh" \
    "nvm install.sh ${NVM_VER}"
}

fetch_acc(){
  need git
  local dir="$ASSET_DIR/acc/acc-src"
  local tar="$ASSET_DIR/acc/acc-${ACC_BRANCH}.tar.gz"
  if [[ -s "$tar" ]]; then
    log "[跳过] ACC 源码包已存在: $tar sha256=$(sha_file "$tar")"
    return 0
  fi
  rm -rf "$dir"
  log "[clone] ACC 源码 branch=$ACC_BRANCH (稳定分支, 不用默认 dev HEAD)"
  if git clone --depth 1 --branch "$ACC_BRANCH" https://github.com/VR-25/acc.git "$dir"; then
    git -C "$dir" rev-parse HEAD > "$ASSET_DIR/acc/acc-${ACC_BRANCH}.commit"
    local tar_abs dir_abs
    tar_abs="$(cd "$(dirname "$tar")" && pwd -P)/$(basename "$tar")"
    dir_abs="$(cd "$dir" && pwd -P)"
    (cd "$dir_abs" && tar --exclude='.git' -czf "$tar_abs" .)
    log "[完成] $tar sha256=$(sha_file "$tar") commit=$(cat "$ASSET_DIR/acc/acc-${ACC_BRANCH}.commit")"
  else
    err "ACC clone 失败"
    fail
  fi
}

save_image(){
  local image="$1" name="$2"
  [[ -z "$image" ]] && return 0
  need docker
  local tar="$ASSET_DIR/images/${name}.linux-arm64.tar"
  if [[ -s "$tar" ]]; then
    log "[跳过] Docker 镜像包已存在: $tar sha256=$(sha_file "$tar")"
    return 0
  fi
  log "[docker pull] $image --platform $DOCKER_PLATFORM"
  if docker pull --platform "$DOCKER_PLATFORM" "$image"; then
    local digest; digest="$(docker image inspect --format '{{json .RepoDigests}}' "$image" 2>/dev/null || echo '[]')"
    echo "$image platform=$DOCKER_PLATFORM digests=$digest" > "$ASSET_DIR/images/${name}.metadata.txt"
    local tmp; tmp="$(mktemp "${tar}.part.XXXXXX")"; TMP_FILES+=("$tmp")
    docker save "$image" -o "$tmp"
    mv -f "$tmp" "$tar"
    log "[完成] $tar sha256=$(sha_file "$tar")"
  else
    err "Docker pull 失败: $image"
    fail
  fi
}

fetch_docker_images(){
  if [[ "$SKIP_DOCKER" == "1" ]]; then
    warn "SKIP_DOCKER=1，跳过 Docker 镜像预拉。"
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    warn "Docker daemon 不可用，跳过镜像预拉。自编内核/pmOS 跑起来后再重跑本脚本。"
    return 0
  fi
  save_image "$HA_IMAGE" "home-assistant_stable"
  save_image "$NTFY_IMAGE" "ntfy_latest"
  save_image "$KUMA_IMAGE" "uptime-kuma_1"
}

gen_manifest(){
  local mf="$ASSET_DIR/manifest.txt" sums="$ASSET_DIR/manifest.sums"
  log "生成 manifest: $mf"
  {
    echo "# op8t-assets manifest"
    echo "generated_at=$(date -Is)"
    echo "asset_dir=$ASSET_DIR"
    echo "host_arch=$(uname -m)"
    echo "target_platform=$DOCKER_PLATFORM"
    echo "allow_cross_prefetch=$ALLOW_CROSS_PREFETCH"
    echo
    find "$ASSET_DIR" -path "$ASSET_DIR/acc/acc-src/.git" -prune -o -type f ! -name 'manifest.txt' ! -name 'manifest.sums' -printf '%P\0' \
      | sort -z \
      | while IFS= read -r -d '' rel; do
          path="$ASSET_DIR/$rel"
          printf '%s  %s  %s bytes\n' "$(sha_file "$path")" "$rel" "$(stat -c%s "$path")"
        done
  } > "$mf"
  (cd "$ASSET_DIR" && find . -path './acc/acc-src/.git' -prune -o -type f ! -name 'manifest.txt' ! -name 'manifest.sums' -print0 \
    | sort -z | xargs -0 sha256sum) > "$sums"
  log "校验: cd <拷贝后的资产根目录> && sha256sum -c manifest.sums"
}

main(){
  need curl; need sha256sum; need tar; need stat; need sort; need find
  arch_guard
  safe_asset_dir
  log "资产目录: $ASSET_DIR"
  log "提示: GitHub 失败可 export HTTPS_PROXY=... 或 GITHUB_PROXY_PREFIX=..."
  fetch_cloudflared
  fetch_zellij
  fetch_kernel_tools
  fetch_nvm
  fetch_acc
  fetch_docker_images
  gen_manifest
  if [[ "$FAIL_COUNT" -eq 0 ]]; then
    log "全部完成。"
  else
    warn "完成但有 $FAIL_COUNT 项失败。设置代理/镜像后重跑即可断点续下。"
    exit 2
  fi
  cat <<EOF

不可预取/必须到手机确认后做:
- boot.img / 自编译内核: 依赖 OxygenOS 版本 + 当前 slot, 不能盲下。
- postmarketOS 刷机镜像: 由 pmbootstrap 根据 device=oneplus-kebab 生成, 或等专项核验后使用。
- Tailscale/Cloudflare token/key: 运行时交互登录/写入 env, 不写进离线包。
EOF
}

main "$@"
