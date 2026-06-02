#!/system/bin/sh
# =============================================================================
#  acc-charge-limit.sh
#  一加 8T (kebab / 骁龙865 / 12G / 256G) —— 24x7 常插电场景电池充电限制安装配置脚本
# -----------------------------------------------------------------------------
#  作用:
#    在已 root 的安卓宿主上安装并配置 ACC (Advanced Charging Controller, 作者 VR-25),
#    把充电上限压到 75%/80% 区间,避免电池长期满电高压老化,延长 24 小时常插电运行寿命。
#
#  环境约定 (用户授权的自有设备):
#    - 宿主: 安卓 (一加 8T, codename kebab), 已 root (Magisk / KernelSU 均可)
#    - 架构: ARM64 / aarch64
#    - ACC 工作在安卓宿主层 (操作内核 power_supply sysfs 节点),
#      与上层 Ubuntu 容器 / Docker / AI agent 无关 —— 电池是物理硬件,
#      只能在能直接访问 /sys/class/power_supply 的宿主层控制。
#    - 因此本脚本【必须】在「安卓宿主的 root shell」里跑 (adb shell -> su, 或 Termux + su),
#      不要在 LXC/chroot/Docker 容器内跑 (容器内看不到真实电池 sysfs, 本脚本会直接 die)。
#
#  地区: 中国大陆。ACC 的安装源在 raw.githubusercontent.com / github.com,
#        国内直连经常超时/被墙 —— 脚本内置 curl/wget 两路 + 可选代理, 全失败给手动指引。
#
#  shell 说明: 安卓自带 /system/bin/sh 是 mksh。本脚本用 POSIX sh 写法。
#    `set -eu` 在 mksh 下生效; mksh 不支持 `pipefail`, 故管道处单独显式判错。
#
#  ★ 本版相对初稿的修复 (经 SRE 评审):
#    [FIX1] 在线安装的 branch/commit 是【位置参数】, 官方无 `-s` 选项。
#           初稿 `install-online.sh -s master` 会被解析成 commit=`-smaster` 下载失败/装错版本。
#           已改为位置参数: `install-online.sh master`。
#    [FIX2] 重启守护进程命令初稿写 `acc --restart` (不存在, 退码2)。已改为官方 `acc -D restart`。
#    [FIX3] capacity 数组注释顺序写错。已更正为官方实际顺序与默认值。
#    [FIX4] 非安卓宿主 (无 /system/bin/sh 或无 power_supply) 由 warn 改为直接 die, 防后续崩。
#    [FIX5] 非 Magisk/KernelSU root 需自备 arm64 busybox, 否则 install 退码3。已加显式检查与提示。
# =============================================================================

set -eu

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[0;33m'; C_B='\033[0;34m'; C_N='\033[0m'
log()  { printf '%b[*]%b %s\n' "$C_B" "$C_N" "$*"; }
ok()   { printf '%b[+]%b %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%b[!]%b %s\n' "$C_Y" "$C_N" "$*"; }
err()  { printf '%b[x]%b %s\n' "$C_R" "$C_N" "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- 可调参数 ----------------------------------------------------------------
# ACC 简写命令: `acc <pause_capacity> <resume_capacity>` (先上限后下限)。
# [FIX3] 官方 capacity 数组实际顺序与默认:
#   capacity=(shutdown_capacity cooldown_capacity resume_capacity pause_capacity capacity_sync capacity_mask)
#   默认值 = (5 50 70 75 false false)
# 本脚本用 --set pc/rc/sc 单独写, 不直接拼数组, 更稳更可读。
PAUSE_CAPACITY=80      # 充到 80% 暂停 (上限)
RESUME_CAPACITY=75     # 掉到 75% 恢复 (下限)
SHUTDOWN_CAPACITY=5    # 低于 5% 自动关机保护

ACC_BRANCH="master"    # master=稳定; 常插电求稳用 master
ACC_INSTALL_URL="https://raw.githubusercontent.com/VR-25/acc/${ACC_BRANCH}/install-online.sh"
# 可选代理: export ACC_PROXY=http://127.0.0.1:7890 可覆盖
ACC_PROXY="${ACC_PROXY:-}"

# =============================================================================
#  0. 环境与基础探测
# =============================================================================

# --- 0.0 [FIX4] 必须在安卓宿主层: 无 /system/bin/sh 直接 die -------------------
guard_android_host() {
  log "确认运行在安卓宿主层 ..."
  if [ ! -x /system/bin/sh ]; then
    die "未找到 /system/bin/sh —— 你很可能在 Ubuntu 容器/chroot/Docker 内运行本脚本。
         ACC 必须在【安卓宿主 root shell】运行才能控制物理电池。
         请退到宿主层 (adb shell 后 su, 或 Termux+su) 重跑。"
  fi
  if [ ! -d /sys/class/power_supply ]; then
    die "未找到 /sys/class/power_supply —— 当前环境看不到电池硬件 (多半在容器内)。
         请在安卓宿主 root shell 重跑。"
  fi
  ok "安卓宿主环境确认 (/system/bin/sh 与 power_supply 均在)。"
}

detect_root() {
  log "探测 root 权限 ..."
  if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
    ok "当前已是 root (uid=0)。"
    SU_PREFIX=""
    return 0
  fi
  if command -v su >/dev/null 2>&1; then
    if su -c 'id -u' 2>/dev/null | grep -q '^0$'; then
      ok "检测到可用 su, 后续命令通过 'su -c' 执行。"
      SU_PREFIX="su -c"
      return 0
    fi
  fi
  die "未检测到 root。ACC 必须 root 才能操作充电 sysfs。请在 root shell 运行。"
}

rootrun() {
  if [ -z "${SU_PREFIX}" ]; then
    /system/bin/sh -c "$1"
  else
    su -c "$1"
  fi
}

# --- [FIX5] 检测 root 方案 + busybox(arm64) ------------------------------------
detect_root_solution() {
  log "探测 root 方案 (Magisk / KernelSU) 与 busybox ..."
  ROOT_SOLUTION="unknown"
  HAS_BB="no"
  if command -v magisk >/dev/null 2>&1 || [ -d /data/adb/magisk ]; then
    ROOT_SOLUTION="magisk"; ok "检测到 Magisk (自带 busybox)。"; HAS_BB="yes"
  elif command -v ksud >/dev/null 2>&1 || [ -d /data/adb/ksu ]; then
    ROOT_SOLUTION="kernelsu"; ok "检测到 KernelSU (自带 busybox)。"; HAS_BB="yes"
  fi
  # 显式找一个可用 busybox（ACC install-online.sh 的 #BB# 段强依赖, 否则 exit 3）
  if [ "$HAS_BB" = "no" ]; then
    if command -v busybox >/dev/null 2>&1 || [ -x /data/adb/vr25/bin/busybox ]; then
      HAS_BB="yes"; ok "找到可用 busybox。"
    else
      warn "未识别 Magisk/KernelSU, 且 PATH 与 /data/adb/vr25/bin/ 下都没有 busybox。"
      warn "ACC 安装脚本的 #BB# 段需要【arm64 版 busybox】, 否则会 exit 3。"
      warn "解决: 放一个 aarch64 busybox 到 /data/adb/vr25/bin/busybox 并 chmod 755, 再重跑。"
    fi
  fi
}

detect_acc_installed() {
  log "检查 ACC 是否已安装 ..."
  ACC_INSTALLED="no"
  if command -v acc >/dev/null 2>&1; then
    ACC_INSTALLED="yes"
    ok "ACC 已在 PATH 中 (版本: $(acc --version 2>/dev/null | head -n1 || echo '?'))。"
  elif [ -d /data/adb/modules/acc ] || [ -d /data/adb/vr25/acc ]; then
    ACC_INSTALLED="yes"
    warn "发现 ACC 安装目录, 但 acc 不在 PATH (将用绝对路径兜底)。"
  else
    log "未检测到 ACC, 准备安装。"
  fi
}

detect_battery_nodes() {
  log "列出电池充电相关 sysfs 候选 (供 acc -t 参考, 不写死) ..."
  rootrun 'ls -1 /sys/class/power_supply/ 2>/dev/null' | sed 's/^/      - /' || true
  rootrun '
    for f in charging_enabled input_suspend battery_charging_enabled \
             mmi_charging_enable constant_charge_current_max voltage_max; do
      p="/sys/class/power_supply/battery/$f"
      [ -e "$p" ] && echo "      - $p"
    done
    # 新固件 OnePlus 专用节点
    [ -e /sys/class/oplus_chg/battery/mmi_charging_enabled ] && \
      echo "      - /sys/class/oplus_chg/battery/mmi_charging_enabled (OnePlus 专用 hold-at-level)"
    true
  ' || true
}

# =============================================================================
#  1. 安装 ACC ([FIX1] branch 用位置参数, 不用 -s)
# =============================================================================
install_acc() {
  if [ "${ACC_INSTALLED}" = "yes" ]; then
    ok "ACC 已安装, 跳过 (幂等)。升级用: acc --upgrade"
    return 0
  fi
  log "在线安装 ACC (分支: ${ACC_BRANCH}) ..."

  CURL_PROXY=""; WGET_PROXY=""
  if [ -n "${ACC_PROXY}" ]; then
    warn "使用代理: ${ACC_PROXY}"
    CURL_PROXY="--proxy ${ACC_PROXY}"
    WGET_PROXY="-e use_proxy=yes -e https_proxy=${ACC_PROXY} -e http_proxy=${ACC_PROXY}"
  else
    warn "未配置代理 (ACC_PROXY 空): 直连 githubusercontent。卡住=被墙, 请 export ACC_PROXY=... 重跑或用方案C。"
  fi

  TMP=/data/local/tmp/acc-install-online.sh

  # --- curl ---
  if command -v curl >/dev/null 2>&1; then
    log "尝试 curl 安装 ..."
    if rootrun "curl -sSL ${CURL_PROXY} '${ACC_INSTALL_URL}' -o ${TMP}" \
       && rootrun "[ -s ${TMP} ]"; then
      # [FIX1] branch 作为位置参数传入, 不加 -s
      if rootrun "/system/bin/sh ${TMP} ${ACC_BRANCH}"; then
        ok "curl 安装完成。"; rootrun "rm -f ${TMP}" || true; return 0
      fi
      warn "curl 下载成功但安装执行失败, 试 wget。"
    else
      warn "curl 下载失败, 试 wget。"
    fi
  fi

  # --- wget ---
  if command -v wget >/dev/null 2>&1; then
    log "尝试 wget 安装 ..."
    if rootrun "wget ${WGET_PROXY} -qO ${TMP} '${ACC_INSTALL_URL}'" \
       && rootrun "[ -s ${TMP} ]"; then
      if rootrun "/system/bin/sh ${TMP} ${ACC_BRANCH}"; then
        ok "wget 安装完成。"; rootrun "rm -f ${TMP}" || true; return 0
      fi
      warn "wget 下载成功但安装执行失败。"
    else
      warn "wget 下载失败。"
    fi
  fi

  # --- 方案 C: 手动 ---
  err "在线安装失败 (curl/wget 不可用或全被墙)。"
  cat <<'EOF'

  ====== 兜底方案 C: 手动安装 ACC 模块 ======
  1) 在能上网的机器(可能需代理)克隆官方仓库 (勿用第三方镜像, 官方禁止镜像分发):
        git clone https://github.com/VR-25/acc.git
        cd acc && sh build.sh        # 生成 flashable zip
  2) 把 acc-*.zip 传到手机, 二选一刷入:
        Magisk:   App -> 模块 -> 从存储安装 -> 选 zip -> 重启
        KernelSU: App -> 模块 -> 安装 -> 选 zip -> 重启
  3) 重启后重跑本脚本 (幂等, 检测到已装会跳过安装直接配置)。
  ==========================================
EOF
  die "请按方案 C 手动安装后重跑。"
}

resolve_acc_cmd() {
  if command -v acc >/dev/null 2>&1; then ACC_CMD="acc"
  elif [ -x /data/adb/modules/acc/acc.sh ]; then ACC_CMD="/data/adb/modules/acc/acc.sh"
  elif [ -x /data/adb/vr25/acc/acc.sh ]; then ACC_CMD="/data/adb/vr25/acc/acc.sh"
  else die "安装后仍找不到 acc, 请重启设备(守护进程开机约60s初始化)后重试。"; fi
  log "使用 acc 命令: ${ACC_CMD}"
}

# =============================================================================
#  2. 配置充电区间 (80/75)
# =============================================================================
configure_limits() {
  log "配置: 充到 ${PAUSE_CAPACITY}% 暂停, 掉到 ${RESUME_CAPACITY}% 恢复 ..."
  rootrun "${ACC_CMD} --set pc=${PAUSE_CAPACITY}" || die "设置 pause_capacity 失败"
  rootrun "${ACC_CMD} --set rc=${RESUME_CAPACITY}" || die "设置 resume_capacity 失败"
  rootrun "${ACC_CMD} --set sc=${SHUTDOWN_CAPACITY}" || warn "设置 shutdown_capacity 失败(非致命)"
  ok "充电区间已写入。等价简写: ${ACC_CMD} ${PAUSE_CAPACITY} ${RESUME_CAPACITY}"

  cat <<'EOF'

  -------- 关于 24x7 常插电延寿的两点进阶 (按需手动开启) --------
  1) 常插电延寿关键: 让高于上限时尽量进 idle 而非靠放电
        acc --set aiapc=false        # allow_idle_above_pcap=false
  2) ★一加 8T 实测坑: battery/input_suspend 在熄屏几分钟后会被系统 wakelock 重新使能,
     结果仍充到 100%。优先用 OnePlus 专用 hold-at-level 节点 (不 ping-pong):
        /sys/class/power_supply/battery/mmi_charging_enable        (旧固件)
        /sys/class/oplus_chg/battery/mmi_charging_enabled          (新固件)
     用 `acc -t` 让 ACC 实测并自动选出支持的开关; 若它选了 input_suspend 且熄屏失效,
     再手动 `acc -ss` 强制指定 mmi/oplus 节点。
  3) 想更延寿可把区间下移到 60/55 (锂电常插电最佳区间), 代价是续航缓冲变小。
  -------------------------------------------------------------
EOF
}

# =============================================================================
#  3. 验证 ([FIX2] 重启守护进程用 acc -D restart)
# =============================================================================
verify() {
  log "重启 ACC 守护进程使配置即时生效 ..."
  # [FIX2] 官方重启守护进程命令是 acc -D restart, 不是 --restart
  rootrun "${ACC_CMD} -D restart" || warn "重启守护进程返回非0(配置仍会数秒内自动拾取)"

  echo
  ok "============ 验证步骤 (人工核对) ============"
  cat <<EOF
  1) 看充电状态/电流/电压/开关/idle 是否支持, 阈值是否 ${PAUSE_CAPACITY}/${RESUME_CAPACITY}:
        ${ACC_CMD} -i
  2) 实测并自动选出可用充电开关 (会临时开关充电属正常):
        ${ACC_CMD} -t
        # 退码 10 = All charging switches fail (当前内核未暴露可用开关)
  3) 确认配置落盘:
        ${ACC_CMD} --set | grep -iE 'capacity|pause|resume'
  4) 最可靠: 充到 ${PAUSE_CAPACITY}% 看是否自动停, 熄屏 30 分钟后再看电量没继续涨。

  应急恢复 (出现无法充电/异常重启时):
        pkill -9 -f accd
        ${ACC_CMD} --set pc=101 rc=0     # 临时放开限制
        ${ACC_CMD} --uninstall           # 彻底卸载
EOF
  ok "============================================="
}

main() {
  log "===== 一加 8T (kebab) ACC 充电限制 开始 ====="
  guard_android_host       # 0.0 [FIX4] 必须宿主层
  detect_root              # 0.1
  detect_root_solution     # 0.2 [FIX5] busybox 检查
  detect_acc_installed     # 0.3
  detect_battery_nodes     # 0.4
  install_acc              # 1   [FIX1]
  resolve_acc_cmd
  configure_limits         # 2
  verify                   # 3   [FIX2]
  ok "===== 完成。请按上面 acc -i / acc -t 输出人工核对。 ====="
}

main "$@"
