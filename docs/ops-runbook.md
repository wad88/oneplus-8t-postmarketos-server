# 自托管 Agent 节点 · 长期运维手册 (ops-runbook.md)

> 设备: 一加 8T (kebab, 骁龙865, ARM64, 已root)
> 架构: Android 宿主 → Ubuntu LXC/chroot 容器 → 容器内 Docker
> 网络: 国内大陆, Tailscale + Cloudflare Tunnel 穿透
> 范围: **与 ROM/内核选型无关的长期运维**。内核编译、CONFIG 补齐、ROM 分支选择见单独部署文档。
>
> 全部脚本约定: `set -euo pipefail`、幂等、中文注释、防御式。这是用户授权的自有设备。

---

## 0. 角色与路径约定 (先读这一节)

三层嵌套各有独立的进程/文件系统视角：

| 层级 | 代号 | 说明 | 操作入口 |
|---|---|---|---|
| L0 安卓宿主 | `host` | OxygenOS / 自编译内核, root, Magisk, ACC, KonaBess | `adb shell` / Termux / Magisk |
| L1 容器 | `lxc` | Ubuntu LXC 或 chroot, 跑 Docker Engine + cloudflared + zellij + Node/OpenCode/Aider | `lxc-attach` / chroot shell |
| L2 Docker 容器 | `docker` | Home Assistant / ntfy / agent 服务 | `docker exec` |

统一路径口径，三层都 source：

```bash
# /etc/profile.d/ops-paths.sh —— 统一路径, 防御式默认值, 外部已定义则不覆盖
export OPS_ROOT="${OPS_ROOT:-/opt/agent-node}"          # L1 容器内运维根
export OPS_ENV="${OPS_ENV:-$OPS_ROOT/agent.env}"        # agent 密钥/配置 (chmod 600)
export OPS_SCRIPTS="${OPS_SCRIPTS:-$OPS_ROOT/hermes}"   # 监控/自启/watchdog 脚本(hermes)
export OPS_HA_CONFIG="${OPS_HA_CONFIG:-$OPS_ROOT/ha-config}"  # HA /config 映射到宿主
export OPS_NTFY_URL="${OPS_NTFY_URL:-http://127.0.0.1:8080}"  # 自建 ntfy 地址
export OPS_NTFY_TOPIC="${OPS_NTFY_TOPIC:-ops-kebab}"    # 自建 ntfy 主题
```

> 监控脚本目录统一叫 `hermes`（信使）。下文 `$OPS_SCRIPTS` 即指它。

---

## 1. 散热运维 (SD865 是这套方案的头号长期隐患)

### 1.1 为什么散热是第一优先级

骁龙865 是 2020 旗舰 SoC，设计是"手游几分钟爆发"，**不是 7×24 持续负载**。常驻 agent 后：

- 大核 (A77 @ 2.84GHz) 持续满载 → 结温迅速 90℃+ → 触发热保护降频，长期低频抖动，性能反而不稳。
- Adreno 650 即使不渲染游戏，HA 前端 / 浏览器自动化 / 视频转码也会拉它。
- 手机无主动风冷，靠玻璃后盖被动散热，**平放桌面/床上 = 闷烧**。

长期高温的代价是**电池鼓包**（见第 2 节）和 SoC 寿命衰减。散热做不好这台机器活不过半年。

### 1.2 GPU 降压 (KonaBess, 8T 实测参数)

用 **KonaBess** 给 Adreno 650 降压(undervolt)，降低同频功耗与发热。收益最高、风险可控。

**8T 实测安全起点**（用户已验证，直接用，别盲目拉高）:

| 频率 | 电压 | 状态 |
|---|---|---|
| **905 MHz @ 340 mV** | 起步安全值 | 稳定 |
| **>920 MHz** | 即使 416 mV | 花屏 (artifact) |

操作纪律:

1. KonaBess 改 GPU 表 → 生成 boot 镜像 → 刷入（**务必先 `dd` 备份原 boot 分区**）。
2. 每次只动一档电压，刷完跑 30 分钟 GPU 压力观察是否花屏/重启。
3. **超过 920MHz 不要碰**，实测花屏即使加压也救不回，是体质上限。
4. 留好回退路径：原始 boot 镜像 + fastboot 线缆常备，`fastboot flash boot boot-stock.img`。

```bash
# host 层 (Termux/adb, root): 刷 KonaBess boot 前必做备份
set -euo pipefail
BOOT_PART="$(readlink -f /dev/block/by-name/boot)"   # 8T A/B 分区, 注意当前 slot
OUT="/sdcard/boot-stock-$(date +%Y%m%d).img"
[ -e "$BOOT_PART" ] || { echo "找不到 boot 分区"; exit 1; }
dd if="$BOOT_PART" of="$OUT" bs=4M
[ -s "$OUT" ] || { echo "备份为空, 中止"; exit 1; }
echo "boot 备份完成: $OUT  ($(stat -c%s "$OUT") bytes)"
```

### 1.3 CPU 降频 (需自定义内核, 不能靠 app)

CPU 持续负载降频靠 KonaBess 改不了，**必须在自编译内核里做**（限制大核最高频 / 调 thermal governor）。运维上要知道：

- 推荐把大核 (policy7, A77×1) 锁到 ~2.0–2.2GHz，超大核 burst 用不上反而是发热源。
- 中核 (policy4, A77×3) 限到 ~1.8GHz。
- agent 任务是 IO/网络密集型不是算力密集型，**砍峰值频率几乎不影响吞吐但显著降温**。
- thermal governor 用 `step_wise`，trip point 调保守，宁可早点温和降频也别等结温墙硬刹。

运行期可观测（不改内核也能看）:

```bash
# host 层: 看 CPU 当前频率与热区温度
set -euo pipefail
echo "=== 各 policy 当前频率 ==="
for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq; do
  [ -r "$f" ] && echo "$f -> $(($(cat "$f")/1000)) MHz"
done
echo "=== 热区温度 (>85000=85℃ 需警觉) ==="
for z in /sys/class/thermal/thermal_zone*/temp; do
  [ -r "$z" ] && echo "$z -> $(($(cat "$z")/1000)) ℃"
done
```

### 1.4 物理散热 (最便宜也最有效)

- **散热片 + 小风扇**: 后盖贴铜/铝散热片 + USB 小风扇对吹。被动升级半主动，结温能压 10–15℃，性价比碾压软件方案。
- **别放软表面**: 床、沙发、毛巾堵后盖散热 = 盖被子。
- **屏幕常黑**: 屏幕是发热源也是耗电源。`settings put system screen_off_timeout` 设短或直接息屏；确认息屏不影响后台服务（关省电杀进程，见第 3 节）。
- **架空立式**: 用支架立起来背面留对流通道，比平躺强很多。
- **环境**: 别塞密闭机柜/抽屉；35℃ 室温下被动散热基本失效。

---

## 2. 电池长寿 (配合 ACC 限充)

### 2.1 ACC 限充策略

ACC (VR-25/acc) 在**安卓宿主层**装。8T 限充有专用节点坑（**用户已确认**）:

- 用 OnePlus 专用节点: `mmi_charging_enable` / `oplus_chg`。
- **不要用通用 `input_suspend`**: 8T 上它带 wakelock 坑，会阻止休眠 / 异常耗电与发热。

推荐限充区间（常驻设备）:

```
# acc 配置思路 (语法以 acc --set 为准):
# 上限 70%, 下限 60% —— 长期挂机别贴满
acc --set capacity 60 70 70
acc --set charging_switch mmi_charging_enable
acc -i        # 验证当前 switch / capacity / temp
```

> 为什么是 60–70 而非 80%：常驻设备只需"永远在线"，电量越低、越远离满充电压(~4.4V)，老化越慢。70% 是寿命与可用性的甜点。

### 2.2 为什么不能长期 100% trickle

锂电池长期停 100%(涓流) = 长期承受最高电压(~4.4V) + 充电产热，是**鼓包最快的杀手**，比循环次数更伤。常驻节点 7×24 插电，不限充就是 7×24 满压焖烧。ACC 限充的核心价值就是干掉它。

### 2.3 鼓包监控

- **物理巡检**: 每月看后盖/屏幕是否翘起、缝隙变大、屏幕被顶起。早期就是后盖微鼓。
- **通风**: 见 1.4，电池怕热，散热做好鼓包概率大降。
- **温度告警**: 电池温度纳入监控(第 6 节)，>40℃ 持续就查散热/降负载。
- 发现鼓包**立即断电停用**，有燃爆风险，别继续跑。

### 2.4 为什么不推荐物理拔电池 DC 供电

1. **865 的 PMIC 强依赖电池做电压缓冲/基准**，拔了可能开不了机或充电握手失败。
2. 拔电池要破坏防水胶、撕排线，**不可逆且得不偿失**。
3. DC 直供时电流尖峰无电池缓冲，**反而可能烧 PMIC**。
4. 正确做法：留电池 + ACC 限充 60–70% + 散热，让电池只做缓冲不做满充储能。寿命和安全都更好。

---

## 3. 可靠性 / 自启 (重启后自动拉起整条链)

目标链路：**手机重启 → L1 容器起 → dockerd 起 → 业务容器(HA/ntfy/agent)起 → cloudflared tunnel 起 → 监控起**。任何一环断下一环都拉不起，所以逐层钉死。

### 3.1 第 0 步: 关省电杀进程 (否则一切自启白搭)

```bash
# host 层 (adb shell, root): 给关键 app 解除电池优化 / 后台限制
set -euo pipefail
for pkg in com.termux com.termux.boot; do
  dumpsys deviceidle whitelist +$pkg || true              # Doze 豁免
  cmd appops set $pkg RUN_IN_BACKGROUND allow || true
  cmd appops set $pkg RUN_ANY_IN_BACKGROUND allow || true
done
settings put global low_power 0 || true
settings put global adaptive_battery_management_enabled 0 || true
echo "省电豁免已应用 (重启后部分需复查)"
```

系统 UI 里再手动确认: **设置 → 电池 → 后台冻结/智能省电** 把 Termux/相关 app 设为"不优化/允许后台"。UI 比命令可靠，重启后复查。

### 3.2 第 1 环: 安卓宿主开机触发

**方案 A — Magisk `service.d`（推荐, late_start, 无需解锁屏幕）:**

```bash
# host: /data/adb/service.d/00-agent-node.sh  (chmod 755)
#!/system/bin/sh
set -u
LOG=/data/local/tmp/agent-boot.log
exec >>"$LOG" 2>&1
echo "=== boot $(date) ==="
# 等 data 与开机完成 (最多 120s)
i=0
while [ $i -lt 120 ]; do
  [ -d /data/local ] && getprop sys.boot_completed | grep -q 1 && break
  sleep 2; i=$((i+2))
done
# 拉起 L1 容器
if command -v lxc-start >/dev/null 2>&1; then
  lxc-start -n agent-node -d || echo "lxc-start 失败"
else
  /data/local/agent-node/start-chroot.sh || echo "chroot 启动失败"
fi
echo "boot 链路触发完成"
```

**方案 B — Termux:Boot（栈跑在 Termux 时）:**

```bash
# host: ~/.termux/boot/00-agent-node.sh  (chmod +x)
#!/data/data/com.termux/files/usr/bin/sh
set -u
termux-wake-lock                 # 关键: 防息屏被杀
proot-distro login ubuntu -- /opt/agent-node/hermes/boot-chain.sh \
  >> $HOME/agent-boot.log 2>&1
```

> 装 **Termux:Boot** 并**手动开一次**授权开机权限，否则不触发。`termux-wake-lock` 必加。

### 3.3 第 2 环: LXC 自启 + 容器内服务自启

```bash
# L1 宿主侧 /var/lib/lxc/agent-node/config 追加
lxc.start.auto = 1
lxc.start.delay = 10
lxc.start.order = 50
```

L1 是 systemd 容器时最干净:

```bash
set -euo pipefail
systemctl enable --now docker
systemctl enable --now agent-hermes.timer
echo "docker / hermes 自启已 enable"
```

### 3.4 第 3 环: dockerd + 业务容器自启

业务容器靠 `restart: unless-stopped` 自愈:

```yaml
# L1: $OPS_ROOT/docker-compose.yml
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    restart: unless-stopped
    network_mode: host             # HA 设备发现(mDNS/SSDP)需要 host 网络
    volumes:
      - ${OPS_HA_CONFIG}:/config
      - /etc/localtime:/etc/localtime:ro
    environment:
      - TZ=Asia/Shanghai

  ntfy:
    image: binwiederhier/ntfy
    container_name: ntfy
    command: serve
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:80"        # 只绑本地, 外部经 tunnel/tailscale
    volumes:
      - ntfy-cache:/var/cache/ntfy
      - ntfy-etc:/etc/ntfy
    environment:
      - TZ=Asia/Shanghai

volumes:
  ntfy-cache:
  ntfy-etc:
```

> 用 `unless-stopped` 而非 `always`：手动维护 `docker stop` 时不抢着重启，但崩溃/重启会自愈。

无 systemd 的 chroot 启动脚本:

```bash
# L1: $OPS_SCRIPTS/boot-chain.sh —— chroot 内无 systemd 时的链路拉起
#!/usr/bin/env bash
set -euo pipefail
source /etc/profile.d/ops-paths.sh
log(){ echo "[$(date '+%F %T')] $*"; }

# 1) 起 dockerd
if ! pgrep -x dockerd >/dev/null; then
  log "启动 dockerd"; dockerd >/var/log/dockerd.log 2>&1 &
fi
for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null 2>&1 || { log "dockerd 起不来, 见 /var/log/dockerd.log"; exit 1; }

# 2) 拉业务容器 (compose up 幂等)
log "拉起 docker-compose 服务"
docker compose -f "$OPS_ROOT/docker-compose.yml" up -d

# 3) 起 cloudflared / tailscale
systemctl is-active --quiet cloudflared 2>/dev/null || "$OPS_SCRIPTS/start-cloudflared.sh" &
systemctl is-active --quiet tailscaled 2>/dev/null || tailscaled --tun=userspace-networking >/var/log/tailscaled.log 2>&1 &

# 4) 起 agent
"$OPS_SCRIPTS/start-agent.sh" &

# 5) 起监控
"$OPS_SCRIPTS/watchdog.sh" &
log "boot 链路全部拉起"
```

### 3.5 第 4 环: cloudflared / tailscale 自启 (systemd)

```ini
# L1: /etc/systemd/system/cloudflared.service 关键项
[Service]
ExecStart=/usr/bin/cloudflared tunnel run --token <REDACTED_TUNNEL_TOKEN>
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
```

```bash
set -euo pipefail
systemctl enable --now cloudflared
systemctl enable --now tailscaled
echo "cloudflared / tailscaled 自启已 enable"
```

### 3.6 Watchdog 模式 (任一环死了自动拉回)

`restart: unless-stopped` 管不了 dockerd 本身、cloudflared、agent 崩的情况。周期 watchdog 兜底:

```bash
# L1: $OPS_SCRIPTS/watchdog.sh —— 巡检关键进程, 死了拉回并告警
#!/usr/bin/env bash
set -euo pipefail
source /etc/profile.d/ops-paths.sh
notify(){ curl -fsS -m 10 -H "Title: kebab-watchdog" -d "$1" "$OPS_NTFY_URL/$OPS_NTFY_TOPIC" >/dev/null 2>&1 || true; }
check_and_revive(){
  local name="$1" check_cmd="$2" revive_cmd="$3"
  if ! eval "$check_cmd" >/dev/null 2>&1; then
    notify "$name 掉线, 尝试拉回"
    eval "$revive_cmd" || notify "$name 拉回失败"
  fi
}
check_and_revive "dockerd" "docker info" "dockerd >/var/log/dockerd.log 2>&1 & sleep 5"
check_and_revive "compose" "test \$(docker compose -f $OPS_ROOT/docker-compose.yml ps -q | wc -l) -ge 2" "docker compose -f $OPS_ROOT/docker-compose.yml up -d"
check_and_revive "cloudflared" "pgrep -x cloudflared" "systemctl restart cloudflared 2>/dev/null || $OPS_SCRIPTS/start-cloudflared.sh &"
check_and_revive "tailscale" "tailscale status --json | grep -q '\"Online\":true'" "tailscale up 2>/dev/null || true"
check_and_revive "agent" "pgrep -f 'opencode\\|aider'" "$OPS_SCRIPTS/start-agent.sh &"
```

systemd timer 每 2 分钟跑（比 `while true;sleep` 可靠，崩了 timer 还在）:

```ini
# L1: /etc/systemd/system/agent-hermes.service
[Service]
Type=oneshot
ExecStart=/opt/agent-node/hermes/watchdog.sh

# L1: /etc/systemd/system/agent-hermes.timer
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
```

```bash
systemctl enable --now agent-hermes.timer
```

---

## 4. 备份 (要备份什么 + restic/rsync 到 NAS)

### 4.1 必须备份清单 (按重要性)

| 优先级 | 内容 | 路径 | 为什么 |
|---|---|---|---|
| P0 | **HA `/config`** | `$OPS_HA_CONFIG` | 全部自动化/集成/设备/历史, 丢了从零重建 |
| P0 | **agent.env** | `$OPS_ENV` | 密钥/token, 丢了所有服务挂 (备份须加密!) |
| P1 | **hermes 脚本** | `$OPS_SCRIPTS` | 自启/监控/watchdog 全套 |
| P1 | **OpenCode 配置** | `~/.config/opencode`, `~/.local/share/opencode` | agent 行为/会话/凭据 |
| P1 | **docker-compose.yml** | `$OPS_ROOT/docker-compose.yml` | 服务编排定义 |
| P2 | **ntfy 数据** | volume `ntfy-etc` | 用户/ACL, 重建成本中等 |
| P2 | **Aider 配置** | `~/.aider.conf.yml`, `~/.aider/` | agent 配置 |

> **不备份**: docker 镜像本身(`pull` 能拉回)、运行态、cache volume。**备配置与数据, 不备可重建物。**

### 4.2 restic 增量加密备份到 NAS (推荐)

```bash
# L1: $OPS_SCRIPTS/backup.sh —— restic 增量加密备份到 NAS
#!/usr/bin/env bash
set -euo pipefail
source /etc/profile.d/ops-paths.sh
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-sftp:nas@192.168.1.10:/volume1/backup/kebab}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$OPS_ROOT/.restic-pass}"  # chmod 600
log(){ echo "[$(date '+%F %T')] $*"; }
notify(){ curl -fsS -m 10 -H "Title: kebab-backup" -d "$1" "$OPS_NTFY_URL/$OPS_NTFY_TOPIC" >/dev/null 2>&1 || true; }

# 仓库不存在则初始化 (幂等)
restic snapshots >/dev/null 2>&1 || { log "初始化 restic 仓库"; restic init; }

# HA sqlite 热备可能损坏, 短停保证一致性
docker compose -f "$OPS_ROOT/docker-compose.yml" stop homeassistant || true

set +e
restic backup \
  "$OPS_HA_CONFIG" "$OPS_ENV" "$OPS_SCRIPTS" \
  "$OPS_ROOT/docker-compose.yml" "$HOME/.config/opencode" \
  --tag kebab --tag auto \
  --exclude '*.log' --exclude '*/__pycache__/*' --exclude '*.db-wal'
rc=$?
set -e

# 无论成败都拉回 HA
docker compose -f "$OPS_ROOT/docker-compose.yml" start homeassistant || true
if [ $rc -ne 0 ]; then notify "restic 备份失败 rc=$rc"; exit $rc; fi

# 保留策略
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
notify "restic 备份完成 $(date '+%F %T')"
log "备份完成"
```

### 4.3 rsync 简易方案 (不加密时的轻量替代)

```bash
# L1: $OPS_SCRIPTS/backup-rsync.sh
#!/usr/bin/env bash
set -euo pipefail
source /etc/profile.d/ops-paths.sh
DEST="nas@192.168.1.10:/volume1/backup/kebab-rsync/"
# 不加 --delete 避免误删, 用日期目录隔离
rsync -aH --info=progress2 --exclude '*.log' --exclude '__pycache__' \
  "$OPS_HA_CONFIG" "$OPS_SCRIPTS" "$OPS_ROOT/docker-compose.yml" \
  "$DEST$(date +%Y%m%d)/"
```

> agent.env/密钥**不走明文 rsync**，要么 restic(加密)要么 gpg 加密后再传。

### 4.4 定时 (systemd timer, 凌晨)

```ini
# L1: /etc/systemd/system/agent-backup.service  -> ExecStart=/opt/agent-node/hermes/backup.sh (Type=oneshot)
# L1: /etc/systemd/system/agent-backup.timer
[Timer]
OnCalendar=*-*-* 04:17:00     # 避开整点, 凌晨负载低
Persistent=true               # 错过(关机)开机补跑
RandomizedDelaySec=600
[Install]
WantedBy=timers.target
```

```bash
systemctl enable --now agent-backup.timer
```

> **恢复演练**: 备份没演练 = 没备份。每季度 `restic restore latest --target /tmp/restore-test` 验证。

---

## 5. 网络韧性 (4G/WiFi 切换不掉链)

国内 + 手机节点，网络是流动的：WiFi 断切 4G，信号差切回 WiFi，运营商 NAT 还换公网 IP。两条穿透链路都要自动重连。

### 5.1 Tailscale: 网络变了自动重连 + 优选 direct

```bash
# L1: tailscaled.service 提供 Restart=on-failure; 网络切换后通常自动重建链路, 卡住时:
tailscale up    # 重新协商
```

诊断 direct vs DERP:

```bash
set -euo pipefail
PEER="${1:-100.x.y.z}"
tailscale ping "$PEER"     # 含 "via DERP(...)"=走中继(慢但通); "direct"=直连(理想)
tailscale status           # 总览各 peer 链路类型
tailscale netcheck         # 看本机 NAT 类型 / 各 DERP 延迟, 判断为何走中继
```

> 国内 4G 常是对称 NAT，打洞失败退化为 DERP(官方中继)，**能通但延迟高**。要稳定 direct 可自建 DERP 或固定走 WiFi。

### 5.2 Cloudflare Tunnel: Restart=on-failure 自愈

```ini
# L1: /etc/systemd/system/cloudflared.service
[Service]
ExecStart=/usr/bin/cloudflared tunnel run --token <REDACTED>
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=0      # 不因频繁重启被 systemd 拉黑
[Install]
WantedBy=multi-user.target
```

cloudflared 自带重连重试 edge；`Restart=on-failure` 兜进程崩；watchdog 再兜一层。

### 5.3 双链路定位

```bash
# L1: $OPS_SCRIPTS/net-diag.sh —— 一键看两条穿透链路状态
#!/usr/bin/env bash
set -euo pipefail
echo "=== 出口连通性 ==="
ping -c2 -W2 1.1.1.1 >/dev/null 2>&1 && echo "外网 OK" || echo "外网 不通"
echo "=== Tailscale ==="
tailscale status 2>/dev/null | head -5 || echo "tailscale 未运行"
echo "=== Cloudflared ==="
pgrep -x cloudflared >/dev/null && echo "cloudflared 进程在" || echo "cloudflared 不在"
echo "=== 当前默认出口 ==="
ip route get 1.1.1.1 2>/dev/null | head -1 || true
```

---

## 6. "开机后 10 分钟"自检清单

重启后给链路 10 分钟稳定再跑。可手动跑，也可做成开机延迟 10 分钟触发的 oneshot timer 自动推 ntfy。

```bash
# L1: $OPS_SCRIPTS/healthcheck.sh —— 开机后 10 分钟自检, 结果推 ntfy
#!/usr/bin/env bash
set -uo pipefail              # 自检不用 -e, 要跑完所有项
source /etc/profile.d/ops-paths.sh
PASS=0; FAIL=0; REPORT=""
chk(){ if eval "$2" >/dev/null 2>&1; then REPORT+="[OK] $1"$'\n'; PASS=$((PASS+1)); else REPORT+="[FAIL] $1"$'\n'; FAIL=$((FAIL+1)); fi; }

chk "L1 容器在线"            "true"
chk "dockerd 就绪"           "docker info"
chk "HA 容器 running"        "docker ps --filter name=homeassistant --filter status=running -q | grep -q ."
chk "ntfy 容器 running"      "docker ps --filter name=ntfy --filter status=running -q | grep -q ."
chk "HA 8123 响应"           "curl -fsS -m5 http://127.0.0.1:8123 -o /dev/null"
chk "cloudflared 在"         "pgrep -x cloudflared"
chk "tailscale Online"       "tailscale status --json | grep -q '\"Online\":true'"
chk "agent 进程在"           "pgrep -f 'opencode\\|aider'"
chk "watchdog timer active"  "systemctl is-active --quiet agent-hermes.timer"
chk "backup timer active"    "systemctl is-active --quiet agent-backup.timer"
chk "根分区 <90%"            "[ \$(df / | awk 'END{print int(\$5)}') -lt 90 ]"
chk "内存可用 >100MB"        "[ \$(free -m | awk '/^Mem:/{print \$7}') -gt 100 ]"
chk "无热区 >85℃"           "! for z in /sys/class/thermal/thermal_zone*/temp; do [ -r \$z ] && [ \$(cat \$z) -gt 85000 ] && exit 0; done; exit 1"

TITLE="kebab 自检 PASS=$PASS FAIL=$FAIL"
curl -fsS -m10 -H "Title: $TITLE" -d "$REPORT" "$OPS_NTFY_URL/$OPS_NTFY_TOPIC" >/dev/null 2>&1 || true
echo "$REPORT"
[ "$FAIL" -eq 0 ]
```

```ini
# L1: agent-healthcheck.service (Type=oneshot -> healthcheck.sh)
# L1: /etc/systemd/system/agent-healthcheck.timer
[Timer]
OnBootSec=10min
[Install]
WantedBy=timers.target
```

**人工 10 分钟检查口诀**（脚本之外用眼睛确认）:

1. 手机不烫手、后盖无鼓包、散热风扇在转。
2. `acc -i` 显示限充生效、电量 60–70%、电池温度正常。
3. ntfy 收到开机自检报告（监控链路通）。
4. 外网(手机流量)能打开 HA 的 Cloudflare Tunnel 域名（公网链路通）。
5. Tailscale 后台能 ping 通这台机器（内网穿透通）。

---

## 7. 故障排查表 (症状 → 可能原因 → 排查命令)

> 通用首步永远看日志: `docker logs <容器>`、`journalctl -u <服务> -n 100`、`/var/log/dockerd.log`、`/data/local/tmp/agent-boot.log`。

### 7.1 容器无网

| 可能原因 | 排查 / 处置 |
|---|---|
| 内核缺 NF_NAT/MASQUERADE/ADDRTYPE (该机内核需手补) | `lsmod \| grep -E 'nf_nat\|masquerade'`；`iptables -t nat -L POSTROUTING -n` 看有无 MASQUERADE；缺则回查 `check-config.sh` |
| ip_forward 关了 | `sysctl net.ipv4.ip_forward` 应为 1；`sysctl -w net.ipv4.ip_forward=1` |
| docker0 网桥异常 | `ip a show docker0`；`docker network inspect bridge`；`systemctl restart docker` |
| DNS 没传进容器 | `docker exec ntfy cat /etc/resolv.conf`；`docker exec ntfy nslookup cloudflare.com`；`daemon.json` 加 `"dns":["1.1.1.1","223.5.5.5"]` 重启 |
| 上游(手机)断网 | `$OPS_SCRIPTS/net-diag.sh` |

### 7.2 dockerd 起不来

| 可能原因 | 排查 / 处置 |
|---|---|
| 内核缺 cgroup/namespace (该机痛点) | 前台跑 `dockerd --debug` 看报错；`docker info` 看 WARNING；跑 moby `check-config.sh` 复核 CONFIG_CGROUP_PIDS/DEVICE 等 |
| storage driver 不支持 | `/var/log/dockerd.log` 看 overlay2 报错；`daemon.json` 改 `"storage-driver":"vfs"` 兜底(慢但兼容) |
| cgroup v1/v2 混乱 | `cat /sys/fs/cgroup/cgroup.controllers`；`stat -fc %T /sys/fs/cgroup` |
| socket/pid 残留 | `rm -f /var/run/docker.pid`；`pgrep dockerd` 杀残留后重启 |
| 磁盘满 | `df -h /var/lib/docker` |

### 7.3 OOM 杀进程

| 可能原因 | 排查 / 处置 |
|---|---|
| 确认是否 OOM | `dmesg \| grep -i 'killed process\|oom'`；`journalctl -k \| grep -i oom` |
| 看谁吃内存 | `docker stats --no-stream`；`ps aux --sort=-%mem \| head` |
| HA recorder 膨胀 | HA 配置 `recorder: purge_keep_days: 7`；关不用的集成 |
| 没配 swap | `free -m`；`fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`(写 fstab 持久) |
| 容器撑爆全机 | compose 加 `mem_limit`(HA 给 1.5–2G, 别太死) |

### 7.4 根分区满

| 可能原因 | 排查 / 处置 |
|---|---|
| 定位大头 | `df -h`；`du -sh /var/lib/docker/* \| sort -h \| tail`；`du -sh /var/log/* \| sort -h \| tail` |
| 镜像/层堆积 | `docker system df`；`docker system prune -af --volumes`(`--volumes` 会删未用卷, 确认无数据再用) |
| 日志膨胀 | `daemon.json`: `"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}` 重启生效 |
| journald 膨胀 | `journalctl --disk-usage`；`journalctl --vacuum-size=200M` |
| HA 数据库巨大 | HA `recorder: purge_keep_days: 7` + `auto_purge: true` |

```bash
# 应急释放 (从最不伤数据开始)
journalctl --vacuum-size=200M
docker image prune -af
docker builder prune -af
```

### 7.5 限充失效 / 充到 100%

| 可能原因 | 排查 / 处置 |
|---|---|
| ACC 没起/挂了 | `acc -i` 看运行；`acc -D` 重启 daemon；确认开机自启 |
| 用错节点(input_suspend wakelock 坑) | 确认 `acc --set charging_switch` 是 `mmi_charging_enable`/`oplus_chg`, **不是** input_suspend |
| 节点路径变了(ROM 更新后) | `ls /sys/class/power_supply/`；找 `mmi_charging_enable`/`oplus_chg` 真实路径；`acc -t` 测可用 switch |
| 内核更新覆盖 ACC | 刷机后重装/重确认 ACC |
| 已到 100% 涮电 | 临时手动 `echo 0 > .../mmi_charging_enable`(路径以实际为准), 长期靠修好 ACC |

```bash
# host: 快速看充电状态
acc -i
cat /sys/class/power_supply/battery/capacity      # 应 <=70
cat /sys/class/power_supply/battery/status        # Charging/Not charging/Full
```

### 7.6 agent 掉线

| 可能原因 | 排查 / 处置 |
|---|---|
| 进程崩了 | `pgrep -f 'opencode\|aider'`；看 agent 日志；查 `journalctl -u agent-hermes`(watchdog 应已拉回) |
| 被省电杀了 | 复查 3.1 豁免；`dumpsys deviceidle whitelist`；`termux-wake-lock` 是否在 |
| 依赖 API/网络断 | `$OPS_SCRIPTS/net-diag.sh`；`curl -m5 <endpoint>` |
| Node/nvm 环境丢失 | start-agent.sh 里显式 `source ~/.nvm/nvm.sh && nvm use --lts` |
| 凭据过期 | 日志 401/403；更新 agent.env |

### 7.7 tunnel 断

| 可能原因 | 排查 / 处置 |
|---|---|
| cloudflared 死了 | `pgrep -x cloudflared`；`systemctl status cloudflared`；`journalctl -u cloudflared -n 50` |
| token 失效/tunnel 被删 | 日志 "Unauthorized"/"tunnel not found"；CF 后台确认健康、重签 token |
| 上游断网 | `ping -c2 1.1.1.1` 先修网络 |
| public hostname 没指对 | CF Zero Trust → Tunnels → public hostname service 应指 `http://127.0.0.1:8123` |
| 运营商干扰 QUIC | 强制 http2: `cloudflared tunnel run --protocol http2` |

### 7.8 HA 无法发现设备

| 可能原因 | 排查 / 处置 |
|---|---|
| 非 host 网络 → mDNS/SSDP 过不去 | `docker inspect homeassistant --format '{{.HostConfig.NetworkMode}}'` 应为 host |
| 容器与设备不同二层 | 发现要求同子网；手机 WiFi 与设备同网段；`ip a` 确认 |
| 宿主防火墙挡广播 | `iptables -L -n` 看 DROP；mDNS 5353/udp、SSDP 1900/udp |
| 走 4G 与家里 WiFi 设备天然隔离 | 4G 模式本地发现必然失效, 这是物理隔离非 bug；本地发现只在连家 WiFi 时可用 |
| 没装对应集成 | HA → 设置 → 设备与服务 → 手动添加 IP |

---

## 8. 维护节奏速查

| 周期 | 动作 |
|---|---|
| 每次重启后 | 跑 `healthcheck.sh`（开机 10 分钟自动），收 ntfy 报告 |
| 每天 | 自动 restic 备份(timer)，看 ntfy 有无 FAIL |
| 每周 | 看 `docker system df` / `df -h`，手摸机身温度，瞄后盖鼓包 |
| 每月 | 物理巡检鼓包 + 散热片/风扇积灰，`acc -i` 复核限充 |
| 每季度 | restic 恢复演练，`docker compose pull` 更新镜像并重建 |
| ROM/内核更新后 | 重确认 ACC 节点、KonaBess boot、内核 CONFIG、各 systemd 自启 |

---

## 9. 关键纪律 (别犯的错)

1. **刷 KonaBess/内核前必备份 boot 分区**，常备 fastboot 线缆，花屏/砖机能回退。
2. **GPU 不要超过 920MHz**（8T 体质墙，加压也救不回花屏）。
3. **限充只用 `mmi_charging_enable`/`oplus_chg`，永远不碰 `input_suspend`**（wakelock 坑）。
4. **别长期 100% 涮电**，60–70% 限充，鼓包了立刻停用。
5. **不要拔电池做 DC 直供**（PMIC 依赖 + 不可逆拆机风险）。
6. **手机别平躺软表面**，立起来 + 散热片 + 小风扇 + 屏幕常黑。
7. **省电杀进程必须全关 + wake-lock**，否则所有自启形同虚设。
8. **备份含密钥走 restic 加密**，明文 rsync 不传 agent.env。
9. **备份没演练过 = 没有备份**，季度恢复演练别省。
10. **故障先看日志再动手**，`docker logs`/`journalctl`/`dockerd --debug` 是排查起点。
