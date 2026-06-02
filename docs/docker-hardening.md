# Docker 加固 + 磁盘/OOM 防护手册（OnePlus 8T / aarch64 / Ubuntu 容器内 Docker）

> 适用环境：OnePlus 8T（kebab，SD865，12GB RAM / 256GB），Android 宿主 + Magisk root + Ubuntu LXC/chroot + 容器内 Docker（约 6 个容器，含 Home Assistant 等），24h 常插电。
> 架构：ARM64 / aarch64。所在地：中国大陆（默认走国内镜像，无需 VPN；需要梯子的步骤会单独标注）。
> 原则：所有脚本 `set -euo pipefail`、尽量幂等、中文注释、保守安全。**改动前先备份，改完先验证再依赖。**

---

## 0. 改动前必做：备份 + 现状盘点

```bash
#!/usr/bin/env bash
# 用途：备份 Docker 配置 + 记录改动前的资源现状，便于回滚和对比
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
BAK="/root/docker-hardening-backup-${TS}"
mkdir -p "${BAK}"

# 1) 备份现有 daemon.json（可能不存在）
if [ -f /etc/docker/daemon.json ]; then
  cp -a /etc/docker/daemon.json "${BAK}/daemon.json.bak"
  echo "[ok] 已备份 /etc/docker/daemon.json -> ${BAK}/daemon.json.bak"
else
  echo "[info] /etc/docker/daemon.json 不存在,本次为首次创建"
fi

# 2) 记录现状(磁盘/内存/容器/镜像/卷)
{
  echo "===== df -h ====="; df -h
  echo "===== free -h ====="; free -h
  echo "===== docker info(节选) ====="; docker info 2>/dev/null | grep -Ei 'storage|logging|root dir|containers|images' || true
  echo "===== docker ps ====="; docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  echo "===== docker system df ====="; docker system df -v
} > "${BAK}/before-snapshot.txt" 2>&1

echo "[ok] 现状快照已写入 ${BAK}/before-snapshot.txt"
```

---

## 1. `/etc/docker/daemon.json`：日志轮转 + 低资源 arm64 合理默认值

把下面内容写入 `/etc/docker/daemon.json`。**JSON 不允许真正的注释**，所以注释写在代码块下方，文件本身保持纯 JSON。

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "compress": "true"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "default-address-pools": [
    { "base": "172.31.0.0/16", "size": 24 }
  ],
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ],
  "max-concurrent-downloads": 3,
  "max-concurrent-uploads": 3,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 }
  }
}
```

**逐项说明（为什么这么设）：**

| 字段 | 作用 | 在手机上的理由 |
|------|------|----------------|
| `log-driver: json-file` + `max-size/max-file/compress` | **核心**：每容器日志单文件最大 10MB，最多 3 个，旧文件 gzip 压缩 | 默认 json-file **无上限**，最容易把 256GB 根分区写满的就是失控日志。10m×3≈30MB/容器，6 容器约 180MB 封顶 |
| `storage-driver: overlay2` | 显式锁定 overlay2 | 避免落到 vfs（极占空间）。**注意**：容器内 Docker / chroot 环境可能缺 overlay 内核支持，见下方"踩坑" |
| `live-restore: true` | dockerd 重启时容器继续跑 | 手机 24h 常驻，升级/重启 daemon 不想中断 Home Assistant。**注意**：与 swarm mode 互斥，`docker swarm init` 会报 incompatible；本机不跑 swarm 才用，未来要上 swarm/stack 需先移除此项 |
| `default-address-pools` | 自定义网桥网段 172.31/16 | 避开和 Android/LXC/局域网常用 172.17、192.168 段冲突 |
| `registry-mirrors` | 国内镜像加速 | **中国大陆无需 VPN**。1ms.run / xuanyuan.me 为社区可用镜像；如失效见下方备选 |
| `max-concurrent-downloads/uploads: 3` | 限制并发拉取 | 低内存 + 手机网络，避免拉镜像时内存/带宽尖峰触发 OOM |
| `default-ulimits.nofile` | 默认文件句柄数 | HA 等多连接容器避免 "too many open files" |

> **没写 `"default-runtime"`、`"cgroup-parent"`、`"exec-opts native.cgroupdriver"`**：这些在标准 Ubuntu+systemd 上才需要调；容器内/chroot 的 cgroup 拓扑特殊，乱设反而起不来。保持默认，等确认 cgroup 版本后再按需加。

**应用配置（验证再重启）：**

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1) 写入前先用 python 校验 JSON 合法,避免写坏导致 dockerd 起不来
python3 -c "import json,sys; json.load(open('/etc/docker/daemon.json')); print('[ok] daemon.json JSON 合法')"

# 2) 让 dockerd 重新加载(日志/镜像等大部分项支持热加载 reload)
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker; then
  systemctl reload docker || systemctl restart docker
else
  # 容器内常见无 systemd,直接给 dockerd 发 SIGHUP 热加载
  # 注意: 无 systemd 的 chroot/精简 LXC 通常也没有 SysV service 脚本,
  # 故兜底优先 SIGHUP(对日志/镜像配置是有效热加载), service 仅最后尝试。
  HUP_PID="$(pidof dockerd 2>/dev/null | awk '{print $1}')"
  if [ -n "${HUP_PID:-}" ]; then
    kill -HUP "${HUP_PID}" && echo "[ok] 已向 dockerd(${HUP_PID}) 发 SIGHUP 热加载"
  else
    service docker restart 2>/dev/null || echo "[warn] dockerd 未在跑且无 service, 请手动重启 dockerd"
  fi
fi

# 3) 验证日志驱动是否生效
docker info 2>/dev/null | grep -i 'logging driver'
echo "[提示] 已有容器需 docker restart 后才套用新日志策略(老日志不会自动截断)"
```

> **重要**：`daemon.json` 的日志配置**只对新建/重启后的容器生效**。现有 6 个容器要 `docker compose down && up` 或逐个 `docker restart` 才会按新策略轮转。

**镜像加速备选（若上面两个失效）：** 国内镜像源经常变动，可换 `https://docker.m.daocloud.io`、`https://dockerproxy.net`，或自建。验证：`docker pull hello-world` 能秒拉成功即有效。

---

## 2. 磁盘空间防护：定期 `docker system prune`

### 2A. 方案一（首选）：systemd timer

适用于 Ubuntu 容器**带 systemd**（systemd-nspawn / 完整 LXC）。两个文件：

`/etc/systemd/system/docker-prune.service`：

```ini
[Unit]
Description=每周清理 Docker 悬空镜像/停止容器/无用网络/构建缓存(保留 7 天内)
Documentation=man:docker-system-prune(1)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
# --filter "until=168h" 只清理 7 天前的对象,保护近期可能复用的镜像层
# 不加 --volumes:卷里是 HA 数据库等持久数据,绝不能自动删
ExecStart=/usr/bin/docker system prune --all --force --filter "until=168h"
# 限制清理进程自身资源,避免清理时把内存吃爆
Nice=10
IOSchedulingClass=idle
```

> ⚠️ `--all` 会清掉**所有未被任何容器使用的镜像**(不只是悬空 dangling)。手机上镜像越少越好,通常想要这个效果;但如果你常停容器又想保留其镜像,去掉 `--all` 只清 dangling。

`/etc/systemd/system/docker-prune.timer`：

```ini
[Unit]
Description=每周触发一次 docker system prune

[Timer]
# 每周一凌晨 3:47(避开整点,降低与其他定时任务/续证书撞车)
OnCalendar=Mon 03:47:00
# 手机可能休眠/断电错过,补跑
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

启用 + 验证：

```bash
set -euo pipefail
systemctl daemon-reload
systemctl enable --now docker-prune.timer
systemctl list-timers docker-prune.timer --no-pager   # 看下次触发时间
systemctl start docker-prune.service                   # 手动跑一次测试
journalctl -u docker-prune.service --no-pager -n 30    # 看清理结果
```

### 2B. 方案二（备选）：cron

适用于**容器内/chroot 无 systemd** 的常见情况。

cron 行（`crontab -e` 或写入 `/etc/cron.d/docker-prune`）：

```cron
# /etc/cron.d/docker-prune
# m h dom mon dow user  command
# 每周一 03:47 清理 7 天前的悬空对象,日志追加到 /var/log
47 3 * * 1 root /usr/bin/docker system prune --all --force --filter "until=168h" >> /var/log/docker-prune.log 2>&1
```

> 若 cron 守护进程没在跑（chroot 里常见）：`service cron start` 或在 LXC 启动脚本里拉起 `cron`。无 cron 时退而求其次——做一个带 `sleep` 的常驻清理脚本由 supervisor/启动脚本拉起。

### 2C. 更保守的"只清日志/构建缓存"变体

如果担心 `prune --all` 误删，分级清理更安全：

```bash
# 只清构建缓存(BuildKit 缓存最容易膨胀,删了无害)
docker builder prune --force --filter "until=168h"
# 只清悬空镜像(没 tag 的中间层)
docker image prune --force --filter "until=168h"
# 只清已停止的容器
docker container prune --force --filter "until=168h"
# 卷单独手动确认,绝不放进定时任务:
#   docker volume ls -f dangling=true   # 先列出来肉眼确认再删
```

---

## 3. 单容器内存限制（8–12GB 手机 / ~6 容器）

### 3A. 总体预算（12GB 机型示例）

12GB RAM 不能全分给 Docker。Android 宿主 + LXC + dockerd 自身要留底。**保守分配方案：**

```
总 12GB
├─ Android 宿主 + 系统服务      预留 ~2.5GB（绝不能挤,否则整机卡死/重启）
├─ LXC/Ubuntu + dockerd 本体    预留 ~1.0GB
└─ 6 个容器总配额 ≤ 7.5GB（留 ~1GB 余量给峰值,不要顶满）
```

8GB 机型把容器总配额压到 ≤ 4.5GB，并强烈建议开 zram（见第 5 节）。

### 3B. 各容器建议 `mem_limit`（docker compose）

按"实际占用 ×1.3~1.5 留头"估，先小后调：

| 容器 | `mem_limit` 建议 | `memswap_limit` | 说明 |
|------|------------------|-----------------|------|
| Home Assistant Core | `1.5g` | `1.5g`（=mem_limit，**禁止换 swap**，见下） | HA 偶发峰值,给足；DB 重可上 2g |
| Hermes 网关 / AI 编码 agent | `1g`～`2g` | `=mem_limit` | 关键进程,宁可它撑住别被 OOM；详见第 6 节保护 |
| MQTT (mosquitto) | `128m` | `128m` | 极轻 |
| 数据库 (mariadb/postgres) | `1g` | `1.25g` | 给一点 swap 余量缓冲 |
| 反代 (nginx/traefik/caddy) | `256m` | `256m` | 轻 |
| 其他杂项(zigbee2mqtt/grafana 等) | `256m`~`512m` | `=mem_limit` | 按需 |

compose 写法示例：

```yaml
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    mem_limit: 1.5g
    memswap_limit: 1.5g        # 等于 mem_limit => 该容器不允许用 swap(防慢死)
    mem_reservation: 768m      # 软下限,内存紧张时优先保它
    restart: unless-stopped

  hermes-gateway:
    image: your/hermes:latest
    mem_limit: 1.5g
    memswap_limit: 1.5g
    oom_kill_disable: false    # 不建议设 true,见下方警告
    restart: unless-stopped
```

> **关键概念**：`memswap_limit` = mem_limit + 允许的 swap。设成**等于** mem_limit 即"该容器禁用 swap"——对 HA/网关这种延迟敏感服务很重要，宁可超限被限制也别换到 swap 上慢成龟速。
>
> **不要乱用 `oom_kill_disable: true`**：它会让该容器内存超限时**整组 hang 死而不是被杀**，在低内存手机上可能拖垮整机。保护关键进程请用第 6 节的 `oom_score_adj`，而不是禁用 OOM kill。

对**已运行**容器临时改限制（不重建）：

```bash
docker update --memory 1g --memory-swap 1g <容器名>
# 验证
docker inspect <容器名> --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}'
docker stats --no-stream   # 看实时 MEM USAGE / LIMIT
```

> **前置检查**：`docker info | grep -i 'memory limit'`。若输出 `WARNING: No memory limit support`，说明 LXC/内核没开 memory cgroup，`mem_limit` 不生效——需在 Android 内核 cmdline 加 `cgroup_enable=memory swapaccount=1`（涉及改 boot，谨慎；多数 OnePlus 自定义内核已带）。

---

## 4. 加 swap（需要时）+ 风险

> 参考的原始环境 swap 已到 **75% "已吃深"**——这是**危险信号**：说明物理内存长期不够，系统在拿磁盘/闪存当内存用，已经在慢速降级运行。**首选不是加更多 swap，而是先压容器内存配额 + 上 zram（第 5 节）。** 物理 swap 仅作最后兜底。

### 手机加 swap 的特殊风险

1. **闪存磨损**：手机是 UFS 闪存，不是企业 SSD。swap 频繁读写会**加速磨损、缩短寿命**。
2. **慢**：UFS 当内存用，延迟比 RAM 高几个数量级，HA/网关会卡顿甚至超时。
3. **75% 已用 = 实质性内存不足**：加大 swap 只是推迟崩溃、掩盖问题，不解决根因。
4. **常插电 24h**：持续 swap I/O 也是持续发热，影响电池和稳定性。

### 真要加（用 swapfile，最后手段，建议配合 swappiness 调低）

```bash
#!/usr/bin/env bash
# 用途:在根分区创建 2G swapfile(仅在确认必要且 zram 仍不够时)
set -euo pipefail

SWAPFILE="/swapfile"
SIZE_MB=2048

# 幂等:已存在则跳过
if swapon --show=NAME --noheadings | grep -qx "${SWAPFILE}"; then
  echo "[info] ${SWAPFILE} 已启用,跳过"
else
  # 优先 fallocate,不支持则 dd
  fallocate -l "${SIZE_MB}M" "${SWAPFILE}" 2>/dev/null || \
    dd if=/dev/zero of="${SWAPFILE}" bs=1M count="${SIZE_MB}" status=progress
  chmod 600 "${SWAPFILE}"
  mkswap "${SWAPFILE}"
  swapon "${SWAPFILE}"
  echo "[ok] 已启用 ${SIZE_MB}MB swap @ ${SWAPFILE}"
fi

# 降低 swappiness:尽量晚用 swap(默认 60,手机建议 10)
sysctl -w vm.swappiness=10
# 持久化(兼容 `vm.swappiness=60` 与 `vm.swappiness = 60` 两种写法; 都没有则追加)
if grep -qE '^\s*vm\.swappiness\s*=' /etc/sysctl.conf 2>/dev/null; then
  sed -i -E 's/^\s*vm\.swappiness\s*=.*/vm.swappiness=10/' /etc/sysctl.conf
else
  echo 'vm.swappiness=10' >> /etc/sysctl.conf
fi

swapon --show
free -h
```

> **持久化注意**：手机/容器环境 `/etc/fstab` 往往不被读取（LXC/chroot 启动流程不挂 fstab）。靠 fstab 自动挂 swap 多半失效，**改为在 LXC/容器启动脚本里调用上面的脚本**更可靠（脚本本身幂等，重复调用安全）。
>
> **swap 占用排查**：`for f in /proc/*/status; do awk '/VmSwap|Name/{printf "%s ",$2}END{print ""}' "$f"; done | sort -k2 -n -r | head` 看谁在吃 swap。

---

## 5. zram：手机上比磁盘 swap 更好的选择（推荐优先于第 4 节）

**为什么 zram 更适合手机**：zram 在 RAM 里开一块压缩块设备当 swap，**不碰闪存**（无磨损）、速度接近内存、典型压缩比 2~3:1，等于"用少量 CPU 换出更多可用内存"。Android 本身大量用 zram，这是手机内存管理的正道。

```bash
#!/usr/bin/env bash
# 用途:启用 zram 作为高优先级 swap(优先于磁盘 swapfile)
# 注意:zram 是内核功能,LXC/chroot 内可能没有 /dev/zram 与权限,
#      多半需要在 Android 宿主(root)层面创建,再让容器共享内存压力。
set -euo pipefail

# 1) 加载模块(宿主层执行;容器内若无权限会失败,属正常)
modprobe zram num_devices=1 2>/dev/null || { echo "[warn] 无法 modprobe zram,需在 Android 宿主 root 下操作"; }

ZRAM_DEV=/dev/zram0
# 2) 重置(幂等:已配置则先关再设)
if [ -e /sys/block/zram0/disksize ]; then
  swapoff "${ZRAM_DEV}" 2>/dev/null || true
  echo 1 > /sys/block/zram0/reset 2>/dev/null || true
fi

# 3) 选压缩算法(lz4 速度快,zstd 压缩率高;手机推 lz4)
echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true

# 4) 设大小:建议物理内存的 25%~50%。12GB 机型给 3G(压缩后实际占 RAM 约 1~1.5G)
echo 3G > /sys/block/zram0/disksize

# 5) 做成 swap 并以最高优先级启用(priority 越大越先用 => 优先 zram 而非磁盘 swap)
mkswap "${ZRAM_DEV}"
swapon --priority 100 "${ZRAM_DEV}"

echo "[ok] zram swap 已启用:"
swapon --show
cat /sys/block/zram0/mm_stat 2>/dev/null && echo "(orig_data_size compr_data_size mem_used_total ...)"
```

> **优先级策略**：zram `priority 100` > 磁盘 swapfile（默认 -2）。这样内核先用 zram，撑不住才落磁盘。理想状态：**只用 zram，磁盘 swap 仅救命**。
>
> **判断 zram 够不够**：`cat /sys/block/zram0/mm_stat`，看 `mem_used_total`（zram 实际占的 RAM）和压缩比。若 zram 长期满 + 磁盘 swap 还在涨，说明物理内存确实不足，回到第 3 节继续压容器配额或减容器数量。

---

## 6. OOM 防护：用 `oom_score_adj` 保护 Hermes 网关和 sshd 不被先杀

Linux OOM Killer 在内存耗尽时按 `oom_score`（0~1000，越高越先被杀）选目标。`oom_score_adj`（-1000~+1000）是人工偏置：**设负值 = 受保护**，`-1000` = 几乎永不被杀。

**目标**：内存爆掉时，先杀大块头容器（如某个吃内存的 app），**保住 sshd（远程救命通道）和 Hermes 网关（核心服务）**。

### 6A. 保护宿主/容器外的关键进程（sshd、dockerd）

```bash
#!/usr/bin/env bash
# 用途:把 sshd / dockerd 标记为 OOM 高度保护,避免内存爆时丢失远程通道
set -euo pipefail

protect_proc() {
  local name="$1" score="$2"
  # 对该进程名的所有 PID 设 oom_score_adj
  for pid in $(pidof "${name}" 2>/dev/null || true); do
    echo "${score}" > "/proc/${pid}/oom_score_adj" 2>/dev/null \
      && echo "[ok] ${name}(pid ${pid}) oom_score_adj=${score}" \
      || echo "[warn] 设置 ${name}(pid ${pid}) 失败(需 root)"
  done
}

protect_proc sshd     -1000   # 远程救命通道,最高保护
protect_proc dockerd  -800    # daemon 挂了所有容器跟着挂
protect_proc containerd -800

# 验证(pidof 没结果时用 || true 兜底,避免 set -e 在此中止)
for pid in $(pidof sshd || true); do echo "sshd ${pid}: $(cat /proc/${pid}/oom_score_adj)"; done
```

### 6B. 保护 Hermes 网关容器

容器进程的 oom 调整可以在 compose 里声明（推荐，重启自动生效）：

```yaml
services:
  hermes-gateway:
    image: your/hermes:latest
    mem_limit: 1.5g
    memswap_limit: 1.5g
    oom_score_adj: -800        # 关键:内存爆时几乎最后才考虑杀它
    restart: unless-stopped
```

> compose v2 / 较新 docker 支持顶层 `oom_score_adj`。若你的版本不支持，用 `docker run --oom-score-adj=-800 ...`，或运行后用下面脚本对容器主进程动态设置。

对**已运行**容器主进程动态设置（兜底，需 root，重启后失效——可放进定时任务/启动脚本）：

```bash
#!/usr/bin/env bash
# 用途:给指定容器的主进程(PID 1 对应的宿主 PID)设 oom_score_adj
set -euo pipefail

set_container_oom() {
  local cname="$1" score="$2"
  # 拿到容器主进程在宿主上的真实 PID
  local pid
  pid="$(docker inspect --format '{{.State.Pid}}' "${cname}" 2>/dev/null || echo 0)"
  if [ "${pid}" -gt 0 ] 2>/dev/null; then
    echo "${score}" > "/proc/${pid}/oom_score_adj"
    echo "[ok] 容器 ${cname}(host pid ${pid}) oom_score_adj=${score}"
  else
    echo "[warn] 容器 ${cname} 未运行或取 PID 失败"
  fi
}

set_container_oom hermes-gateway -800   # 核心网关,重点保护
set_container_oom homeassistant  -500   # HA 次重要

# 反向:把"可牺牲"的大块头容器设正值,让它先被杀
# set_container_oom some-heavy-app  500
```

> **配套建议**：把 6A + 6B 兜底脚本合并成一个 `oom-protect.sh`，由 LXC 启动脚本 + 一个每 5 分钟的 cron 跑一次（容器重启后 PID 变化、oom_score_adj 会重置，需要重新打标）：
>
> ```cron
> */5 * * * * root /root/oom-protect.sh >> /var/log/oom-protect.log 2>&1
> ```

---

## 7. 排查：谁吃光了根分区 / 内存

### 7A. 根分区谁占满了

```bash
# 0) 先看分区使用率,确认是不是根分区(/)爆了
df -h /

# 1) ncdu:交互式目录占用浏览器(最直观,强烈推荐先装)
#    国内 apt 直接装,无需 VPN
apt-get install -y ncdu
ncdu -x /            # -x 不跨文件系统,只看根分区本身
ncdu -x /var/lib/docker   # Docker 默认数据目录,重点看这里

# 2) du:无 ncdu 时的命令行版,列根分区下最大的 15 个目录
du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -15
# 钻进 docker 目录看是镜像/容器/卷/日志哪块大
du -xh --max-depth=1 /var/lib/docker 2>/dev/null | sort -rh | head

# 3) 单独揪失控日志(最常见的根分区杀手)
du -ah /var/lib/docker/containers 2>/dev/null | grep -E '\-json\.log' | sort -rh | head
#   找到超大日志后:要么 docker restart 让轮转生效,要么手动清空(容器在跑时):
#   truncate -s 0 /var/lib/docker/containers/<id>/<id>-json.log
```

### 7B. Docker 自身的空间分布

```bash
# docker 视角的空间分布:镜像/容器/卷/构建缓存各占多少,RECLAIMABLE=可回收
docker system df -v

# 列出未被任何容器使用的镜像(可回收目标)
docker images --filter dangling=true

# 列出所有卷,标出悬空卷(没容器挂的卷;删前务必确认不是 HA 数据!)
docker volume ls
docker volume ls -f dangling=true

# 看某个具体容器的可写层占用(找哪个容器在往自己写大文件)
docker ps -s --format 'table {{.Names}}\t{{.Size}}'

# 清理(按第 2 节,先 dry 思路:先看再删)
docker builder prune -f --filter "until=168h"   # 构建缓存通常最肥,删最安全
docker image prune -af --filter "until=168h"    # 无用镜像
# 卷:永远手动确认后再删,不要 prune --volumes 进定时任务
```

### 7C. 内存/OOM 现场排查

```bash
# 1) 整体内存 + swap
free -h
# 2) 各容器实时内存
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'
# 3) 是否发生过 OOM kill(看内核日志;容器内可能没 dmesg 权限)
dmesg -T 2>/dev/null | grep -i -E 'killed process|out of memory|oom' | tail -20
journalctl -k --no-pager 2>/dev/null | grep -i oom | tail -20
# 4) 谁在吃 swap(按进程列出 VmSwap)
for f in /proc/[0-9]*/status; do
  awk '/^Name:/{n=$2} /^VmSwap:/{if($2+0>0) printf "%8d kB  %s\n",$2,n}' "$f"
done | sort -rn | head
```

---

## 8. 落地顺序（建议照此推进）

1. 跑 **第 0 节** 备份 + 快照。
2. 写 **第 1 节** daemon.json，校验 JSON，reload，逐个 `docker restart` 现有容器让日志轮转生效。
3. 装 ncdu，跑 **第 7 节** 摸清当前磁盘/内存大头，先手动 prune 一次回收空间。
4. 配 **第 2 节** 定时 prune（有 systemd 用 timer，否则 cron）。
5. 按 **第 3 节** 给 6 个容器逐个加 `mem_limit` / `memswap_limit`，`docker stats` 观察一周微调。
6. 上 **第 5 节** zram（优先），**第 4 节** 磁盘 swap 仅作兜底，且把 swappiness 调到 10。
7. 部署 **第 6 节** `oom-protect.sh` + 5 分钟 cron，保住 sshd 和 Hermes 网关。
8. 一周后对比 `df -h` / `free -h` / `docker system df`，确认日志不再涨、swap 不再持续逼近满。

## 9. 已知踩坑（手机/容器内 Docker 特有）

- **memory cgroup 没开** → `mem_limit` 静默失效。先 `docker info | grep -i memory` 确认；缺则需改内核 cmdline `cgroup_enable=memory swapaccount=1`（改 boot，谨慎）。
- **overlay2 不可用**（chroot/老内核）→ dockerd 起不来或回退 vfs（极占空间）。`docker info | grep -i storage` 确认；不行就别在 daemon.json 强写 overlay2，先解决内核 overlay 支持。
- **systemd 不存在**（chroot/精简 LXC）→ 第 2/6 节一律走 cron + 启动脚本版本，别依赖 timer/`systemctl`。
- **fstab 不生效** → swap/zram 持久化靠 LXC 启动脚本，不靠 fstab。
- **容器内无权限写 `/proc/<pid>/oom_score_adj` 或 modprobe zram** → 这些是宿主内核级操作，需在 Android Magisk root 宿主层做，容器内会 permission denied 属正常。
- **镜像加速源会失效** → 用 `docker pull hello-world` 周期性验证，失效就换源。
- **`live-restore` 与 swarm 互斥** → 本机不跑 swarm 才开 live-restore；未来要 `docker swarm init` 须先从 daemon.json 移除 live-restore。
