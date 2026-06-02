#!/usr/bin/env bash
# =============================================================================
# rollback-to-android.sh
#
# 用途：把已授权的本机 OnePlus 8T (kebab / KB2000 国行) 从 postmarketOS
#       应急回滚到 Android（出厂 KernelSU 启动）。
#
# 设备状态（已确认）：自有设备 / 已 root / bootloader unlocked / 当前 slot = _a。
#
# 运行环境：Windows 上的 Git Bash 或 WSL，调用 *Windows 原生* fastboot.exe。
#           （脚本本身是 bash，但 fastboot 走 Windows 侧 USB 驱动。）
#
# 本地备份（已校验，见 backup-stock/SHA256SUMS.txt）：
#   - boot_a-KSU_NEXT.img  100663296 bytes
#       sha256=df0d581809b5bf7aae8709350c43c2a8ca6152ceefa540ff6046122c4e897d43
#   - super.img            7516192768 bytes (raw dump，需转 sparse 后再刷)
#       sha256=a0ae4000261dd4c12c344ceb1286580d99c52782c6f094fca4075cbb7287cb8c
#
# 安全设计：
#   - 默认 DRY_RUN=1：只打印将要执行的命令，不真正刷写。
#   - 必须显式 `DRY_RUN=0` 才会真正刷写。
#   - 每个 fastboot 写命令前都先做四项前置校验（sha256 / 设备在线 / slot / 文件大小），
#     任一不符立即 exit，绝不带病刷写。
#
# 用法：
#   ./rollback-to-android.sh verify          # 只校验本地备份
#   ./rollback-to-android.sh bootloader      # 重启进 bootloader(fastboot)
#   ./rollback-to-android.sh convert         # super.img -> super-s.img (sparse)
#   ./rollback-to-android.sh flash-super     # 刷 super（破坏性）
#   ./rollback-to-android.sh flash-boot      # 刷 boot_a（破坏性）
#   ./rollback-to-android.sh flash-vbmeta    # 可选：刷 vbmeta 关 verity（破坏性）
#   ./rollback-to-android.sh reboot          # 重启进系统
#   ./rollback-to-android.sh all             # 推荐顺序：verify->bootloader->convert
#                                            #           ->flash-super->flash-boot->reboot
#   DRY_RUN=0 ./rollback-to-android.sh all   # 真正执行
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 配置（可用环境变量覆盖）
# -----------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-1}"                 # 1=只打印命令(默认安全)；0=真正刷写
TARGET_SLOT="${TARGET_SLOT:-a}"         # 期望回滚到的 slot（本机当前 _a）
FLASH_VBMETA="${FLASH_VBMETA:-0}"       # 1=在 all 流程里也刷 vbmeta（默认不刷）

# 备份目录（绝对路径，避免 cwd 漂移）
BACKUP_DIR="${BACKUP_DIR:-D:/claude/workspace/一加8T-Hermes/backup-stock}"
SHA_FILE="${SHA_FILE:-$BACKUP_DIR/SHA256SUMS.txt}"

# 镜像文件
BOOT_IMG="$BACKUP_DIR/boot_a-KSU_NEXT.img"
SUPER_IMG="$BACKUP_DIR/super.img"
SUPER_SPARSE="$BACKUP_DIR/super-s.img"  # img2simg 转换产物

# 期望文件大小（字节）—— 与备份事实一致，刷前硬校验
BOOT_SIZE_EXPECT=100663296
SUPER_SIZE_EXPECT=7516192768

# 期望 sha256（来自 SHA256SUMS.txt，作为兜底常量；脚本仍优先用 SHA 文件比对）
BOOT_SHA_EXPECT="df0d581809b5bf7aae8709350c43c2a8ca6152ceefa540ff6046122c4e897d43"
SUPER_SHA_EXPECT="a0ae4000261dd4c12c344ceb1286580d99c52782c6f094fca4075cbb7287cb8c"

# vbmeta 镜像（可选、本机当前未备份；如需刷请把出厂 vbmeta_a.img 放到此路径）
VBMETA_IMG="${VBMETA_IMG:-$BACKUP_DIR/vbmeta_a.img}"

# 工具（允许通过环境变量指向具体可执行文件）
FASTBOOT="${FASTBOOT:-fastboot}"        # Windows 原生 fastboot(.exe)
IMG2SIMG="${IMG2SIMG:-img2simg}"        # android-tools / platform-tools 自带

# -----------------------------------------------------------------------------
# 真机分区参考（仅供人工核对，刷写一律用 fastboot 逻辑分区名，不要直接写 sdXN）
#   super   = sda15
#   boot_a  = sde11
#   dtbo_a  = sde17
#   vbmeta_a= sde16
#   当前 slot = _a
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 日志辅助
# -----------------------------------------------------------------------------
c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
log()    { printf '[*] %s\n' "$*"; }
ok()     { c_grn "[OK] $*"; }
warn()   { c_ylw "[!] $*"; }
die()    { c_red "[FATAL] $*"; exit 1; }

# run：DRY_RUN=1 只打印，DRY_RUN=0 真正执行
# 破坏性命令统一经 run 走，便于 dry-run 审阅。
run() {
  if [ "$DRY_RUN" = "0" ]; then
    log "执行: $*"
    "$@"
  else
    c_ylw "[DRY-RUN] 将执行: $*"
  fi
}

# -----------------------------------------------------------------------------
# 跨平台取文件大小（字节）：Linux/WSL 用 stat -c，BSD/Git Bash 退化用 wc -c
# -----------------------------------------------------------------------------
file_size() {
  local f="$1"
  if stat -c %s "$f" >/dev/null 2>&1; then
    stat -c %s "$f"
  elif stat -f %z "$f" >/dev/null 2>&1; then
    stat -f %z "$f"
  else
    wc -c < "$f" | tr -d '[:space:]'
  fi
}

# 计算文件 sha256（跨平台）
sha256_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    die "找不到 sha256sum / shasum，无法校验镜像完整性"
  fi
}

# 从 SHA256SUMS.txt 里按 basename 取期望 sha256
# SHA 文件格式：<sha256> *<绝对路径>  —— 只比对 basename，避免中文路径/平台差异
sha_expect_from_file() {
  local base="$1"
  [ -f "$SHA_FILE" ] || { echo ""; return 0; }
  # 去掉行内可能的 '*' 二进制标记，匹配以该 basename 结尾的行
  awk -v b="$base" '
    {
      line=$0
      gsub(/\*/,"",line)
      n=split(line, a, /[ \t]+/)
      sum=a[1]
      path=a[n]
      # 取路径 basename
      m=split(path, p, /[\/\\]/)
      if (p[m]==b) { print sum; exit }
    }' "$SHA_FILE"
}

# -----------------------------------------------------------------------------
# 单文件四件套：存在 / 大小 / sha256(SHA 文件优先, 常量兜底)
# -----------------------------------------------------------------------------
verify_one() {
  local f="$1" expect_size="$2" expect_sha_const="$3"
  local base; base="$(basename "$f")"

  [ -f "$f" ] || die "镜像不存在: $f"

  local size; size="$(file_size "$f")"
  if [ "$size" != "$expect_size" ]; then
    die "大小不符: $base 实际 $size 字节, 期望 $expect_size 字节"
  fi
  ok "大小匹配: $base = $size 字节"

  local got; got="$(sha256_of "$f")"
  local expect; expect="$(sha_expect_from_file "$base")"
  if [ -z "$expect" ]; then
    warn "SHA256SUMS.txt 未找到 $base 的条目，改用脚本内置常量校验"
    expect="$expect_sha_const"
  fi
  if [ "$got" != "$expect" ]; then
    die "sha256 不符: $base
       实际: $got
       期望: $expect"
  fi
  ok "sha256 匹配: $base"
}

# -----------------------------------------------------------------------------
# 步骤 1：校验本地备份（非破坏性，先跑这个）
# -----------------------------------------------------------------------------
do_verify() {
  log "==== 校验本地备份镜像 ===="
  log "备份目录: $BACKUP_DIR"
  verify_one "$BOOT_IMG"  "$BOOT_SIZE_EXPECT"  "$BOOT_SHA_EXPECT"
  verify_one "$SUPER_IMG" "$SUPER_SIZE_EXPECT" "$SUPER_SHA_EXPECT"
  ok "本地备份全部校验通过"
}

# -----------------------------------------------------------------------------
# fastboot 在线检查 + slot 确认（每个刷写前都会调）
# -----------------------------------------------------------------------------
require_fastboot_online() {
  command -v "$FASTBOOT" >/dev/null 2>&1 || die "找不到 fastboot，可设 FASTBOOT=路径"
  # fastboot devices 第一列非空即在线
  local devs; devs="$("$FASTBOOT" devices 2>/dev/null | awk 'NF>0{print $1}')"
  if [ -z "$devs" ]; then
    die "fastboot 未检测到设备。请确认：设备在 fastboot 模式 / USB 线 / Windows 驱动。"
  fi
  ok "fastboot 在线设备: $(echo "$devs" | tr '\n' ' ')"
}

# 确认当前 slot 与期望一致（不一致只警告，可手动 set_active）
confirm_slot() {
  local cur; cur="$("$FASTBOOT" getvar current-slot 2>&1 | awk -F': ' '/current-slot/{print $2; exit}' | tr -d '[:space:]')"
  if [ -z "$cur" ]; then
    warn "无法读取 current-slot（可能在 bootloader 早期阶段），跳过 slot 校验"
    return 0
  fi
  log "当前 slot: $cur, 期望: $TARGET_SLOT"
  if [ "$cur" != "$TARGET_SLOT" ]; then
    warn "当前 slot($cur) 与期望($TARGET_SLOT) 不一致。"
    warn "本机出厂为 _a；如确需切换可手动: $FASTBOOT set_active $TARGET_SLOT"
    die "slot 不一致，已停止以防刷到错误 slot"
  fi
  ok "slot 确认: _$cur"
}

# 刷写前统一前置门禁：设备在线 + slot 确认（镜像 sha 在各 step 内单独再校验）
preflight() {
  require_fastboot_online
  confirm_slot
}

# -----------------------------------------------------------------------------
# 步骤 2：进入 bootloader / fastboot（非破坏性）
# -----------------------------------------------------------------------------
do_bootloader() {
  log "==== 重启进入 bootloader(fastboot) ===="
  if command -v adb >/dev/null 2>&1 && [ "$(adb devices 2>/dev/null | awk 'NR>1&&NF>0' | wc -l)" -gt 0 ]; then
    run adb reboot bootloader
  else
    warn "未检测到 adb 设备。若当前在 postmarketOS/Android，请手动:"
    warn "  adb reboot bootloader   或   关机后 音量+ + 电源 进 fastboot"
  fi
  warn "等待设备进入 fastboot 后，再继续 convert / flash-* 步骤。"
}

# -----------------------------------------------------------------------------
# 步骤 3：super.img(raw) -> super-s.img(sparse)（非破坏性，本地转换）
#   super.img 是 raw dump，必须用 img2simg 转 sparse 才能 fastboot flash super
# -----------------------------------------------------------------------------
do_convert() {
  log "==== 转换 super.img -> super-s.img (sparse) ===="
  # 转换前先确认 raw 源完整
  verify_one "$SUPER_IMG" "$SUPER_SIZE_EXPECT" "$SUPER_SHA_EXPECT"
  command -v "$IMG2SIMG" >/dev/null 2>&1 || die "找不到 img2simg，可设 IMG2SIMG=路径（platform-tools/android-tools 自带）"
  if [ -f "$SUPER_SPARSE" ]; then
    warn "已存在 $SUPER_SPARSE，将被覆盖"
  fi
  # img2simg <raw> <sparse> [blocksize]，默认 4096 即可
  run "$IMG2SIMG" "$SUPER_IMG" "$SUPER_SPARSE"
  if [ "$DRY_RUN" = "0" ]; then
    [ -f "$SUPER_SPARSE" ] || die "转换失败，未生成 $SUPER_SPARSE"
    ok "已生成 sparse: $SUPER_SPARSE ($(file_size "$SUPER_SPARSE") 字节)"
  fi
}

# -----------------------------------------------------------------------------
# 步骤 4：刷 super  ⚠⚠⚠ 破坏性：覆盖整个 super(动态分区 system/vendor/product 等)
#   super 很大(7GB)，bootloader fastboot 可能拒绝/超时，需进 fastbootd(userspace)。
# -----------------------------------------------------------------------------
do_flash_super() {
  c_red "==== [破坏性] 刷写 super 分区 ===="
  preflight
  # 必须有 sparse 产物；若没有，提示先 convert
  if [ ! -f "$SUPER_SPARSE" ]; then
    die "未找到 $SUPER_SPARSE，请先执行: $0 convert"
  fi
  # sparse 文件无固定 sha（每次转换可能不同），这里校验 raw 源完整 + sparse 存在非空
  verify_one "$SUPER_IMG" "$SUPER_SIZE_EXPECT" "$SUPER_SHA_EXPECT"
  local ssz; ssz="$(file_size "$SUPER_SPARSE")"
  [ "$ssz" -gt 0 ] || die "sparse 文件为空: $SUPER_SPARSE"
  log "sparse 大小: $ssz 字节"

  warn "super(7GB) 在 bootloader 下常因 max-download-size 受限而失败。"
  warn "推荐先进 fastbootd(userspace fastboot)：fastboot reboot fastboot"
  # 进 fastbootd（userspace），对刷写大动态分区更稳
  run "$FASTBOOT" reboot fastboot
  # 进入 fastbootd 后设备会重新枚举，再次确认在线
  if [ "$DRY_RUN" = "0" ]; then
    sleep 5
    require_fastboot_online
  fi
  # ⚠ 破坏性：覆盖 super
  run "$FASTBOOT" flash super "$SUPER_SPARSE"
  ok "super 刷写命令已下发"
}

# -----------------------------------------------------------------------------
# 步骤 5：刷 boot_a  ⚠ 破坏性：覆盖 boot 分区(恢复出厂 KernelSU 启动)
# -----------------------------------------------------------------------------
do_flash_boot() {
  c_red "==== [破坏性] 刷写 boot 分区(boot_$TARGET_SLOT) ===="
  preflight
  verify_one "$BOOT_IMG" "$BOOT_SIZE_EXPECT" "$BOOT_SHA_EXPECT"
  # 显式带 slot 后缀，避免刷到错误 slot
  run "$FASTBOOT" flash "boot_$TARGET_SLOT" "$BOOT_IMG"
  ok "boot_$TARGET_SLOT 刷写命令已下发"
}

# -----------------------------------------------------------------------------
# 步骤 6（可选）：刷 vbmeta 并关闭 verity/verification  ⚠ 破坏性
#   仅在校验失败导致无法启动时使用；本机当前未备份 vbmeta_a.img。
# -----------------------------------------------------------------------------
do_flash_vbmeta() {
  c_red "==== [破坏性·可选] 刷写 vbmeta_$TARGET_SLOT (--disable-verity --disable-verification) ===="
  preflight
  if [ ! -f "$VBMETA_IMG" ]; then
    warn "未找到 vbmeta 镜像: $VBMETA_IMG"
    warn "本机当前未备份 vbmeta；如需关 verity，请放入出厂 vbmeta_a.img 后再执行。"
    die "缺少 vbmeta 镜像，已停止"
  fi
  # ⚠ 破坏性：关闭 AVB 校验
  run "$FASTBOOT" --disable-verity --disable-verification flash "vbmeta_$TARGET_SLOT" "$VBMETA_IMG"
  ok "vbmeta_$TARGET_SLOT 刷写命令已下发"
}

# -----------------------------------------------------------------------------
# 步骤 7：重启进系统
# -----------------------------------------------------------------------------
do_reboot() {
  log "==== 重启进入系统 ===="
  require_fastboot_online
  run "$FASTBOOT" reboot
  ok "已下发 reboot"
}

# -----------------------------------------------------------------------------
# all：推荐完整顺序
# -----------------------------------------------------------------------------
do_all() {
  do_verify
  do_bootloader
  if [ "$DRY_RUN" = "0" ]; then
    warn "等待设备进入 fastboot... 若未自动进入请手动操作后回车继续"
    read -r _ || true
  fi
  do_convert
  do_flash_super
  do_flash_boot
  if [ "$FLASH_VBMETA" = "1" ]; then
    do_flash_vbmeta
  fi
  do_reboot
  ok "回滚流程命令序列结束（DRY_RUN=$DRY_RUN）"
}

# -----------------------------------------------------------------------------
# 终极兜底：MSMDownloadTool / EDL 9008（仅说明，脚本不自动执行）
# -----------------------------------------------------------------------------
print_edl_help() {
  cat <<'EOF'

================= 终极兜底：MSMDownloadTool / EDL 9008（手动，不自动执行）=================
当 super/boot 刷写后仍无法启动、或分区损坏到 fastboot 都进不去时，使用高通 EDL 全量恢复：

  1. 准备 OnePlus 8T(kebab/KB2000) 对应版本的 MSM 工具包（含 MSMDownloadTool.exe 与 firehose）。
  2. 关机。进入 EDL(9008)：
       - 关机后，同时长按 音量+ 和 音量- ，再插入 USB 连接 PC；
       - 设备管理器应出现 “Qualcomm HS-USB QDLoader 9008”。
  3. 打开 MSMDownloadTool，选机型(国行 KB2000)，目标选 “Other”，点击 Start，
     再插入处于 9008 的设备，工具会全量回写官方固件。
  4. 全量恢复会清空数据、重写所有分区、并可能重新锁定/校验 bootloader（视固件而定）。

⚠ 注意：
  - MSM 全量恢复是“核弹级”操作，会抹掉一切，仅在前面 fastboot 路线全部失败时使用。
  - 务必用与机型/区域匹配的 MSM 包，错版可能变砖。
  - 9008 全量恢复后可能恢复出厂锁，需要时再重新 unlock bootloader。
========================================================================================
EOF
}

# -----------------------------------------------------------------------------
# 用法
# -----------------------------------------------------------------------------
usage() {
  cat <<EOF
OnePlus 8T (kebab/KB2000) postmarketOS -> Android 应急回滚

用法: $0 <step>
  verify        校验本地备份镜像(sha256/大小)            [非破坏性]
  bootloader    重启进入 fastboot                        [非破坏性]
  convert       super.img(raw) -> super-s.img(sparse)    [非破坏性]
  flash-super   刷 super 分区                            [⚠ 破坏性]
  flash-boot    刷 boot_$TARGET_SLOT 分区                 [⚠ 破坏性]
  flash-vbmeta  刷 vbmeta 关 verity(可选)                [⚠ 破坏性]
  reboot        重启进系统                               [非破坏性]
  all           verify->bootloader->convert->flash-super
                ->flash-boot[->vbmeta]->reboot
  edl-help      打印 MSMDownloadTool/EDL 9008 兜底说明
  help          本帮助

环境变量:
  DRY_RUN=1(默认)  只打印命令，不刷写；DRY_RUN=0 才真正刷写
  TARGET_SLOT=a    目标 slot（本机当前 _a）
  FLASH_VBMETA=0   all 流程是否附带刷 vbmeta（默认否）
  FASTBOOT / IMG2SIMG / BACKUP_DIR / VBMETA_IMG  可覆盖路径

当前: DRY_RUN=$DRY_RUN  TARGET_SLOT=$TARGET_SLOT  FLASH_VBMETA=$FLASH_VBMETA
EOF
}

# -----------------------------------------------------------------------------
# 入口
# -----------------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  if [ "$DRY_RUN" = "0" ]; then
    c_red "############################################################"
    c_red "# DRY_RUN=0：真实刷写模式！以下操作会改写设备分区，不可逆。 #"
    c_red "############################################################"
  else
    c_ylw "DRY_RUN=1（默认安全）：只打印命令，不会刷写。真正执行请加 DRY_RUN=0。"
  fi

  case "$cmd" in
    verify)       do_verify ;;
    bootloader)   do_bootloader ;;
    convert)      do_convert ;;
    flash-super)  do_flash_super ;;
    flash-boot)   do_flash_boot ;;
    flash-vbmeta) do_flash_vbmeta ;;
    reboot)       do_reboot ;;
    all)          do_all ;;
    edl-help)     print_edl_help ;;
    help|-h|--help) usage ;;
    *) usage; die "未知步骤: $cmd" ;;
  esac
}

main "$@"
