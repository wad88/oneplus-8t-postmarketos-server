# JOURNEY — 把一加 8T 刷 postmarketOS 做自托管服务器的完整踩坑记录

> 这是一份**真实的攻坚日志**，记录从"刷不进系统的砖头"到"完整自托管 AI 服务器"的全过程，
> 包括所有走过的弯路、证伪的假设和最终的根因。所有设备特定值（序列号、分区 UUID、token）已用占位符替换。
> 设备：一加 8T（KB2000，代号 kebab，SM8250/骁龙865，12+256G）。

---

## 0. 目标

把退役一加 8T 刷 postmarketOS（纯 mainline Linux，**不是** Android），做 24×7 ARM Linux 服务器：Docker + Home Assistant + 监控播报 + 双向 agent。

---

## 1. 第一个拦路虎：PMIC 死锁（内核起不来）

刷入 pmOS mainline 内核后首启失败，卡在早期 boot，报错（A11 官方固件 / A15 第三方固件下**逐字相同**）：

```
spmi-0 pmic_arb_wait_for_done transaction failed(0x3) reg 0x9708/0xa688
pmic-spmi 0-0a/0-0b probe failed error -5(-EIO)
qcom-rpmh-regulator ...smps2 could not find RPMh address
```

### 根因（对抗式核验，high 置信）
- `transaction failed(0x3)` = PMIC_ARB_STATUS_FAILURE = 硬件事务级失败（arbiter 发命令、PMIC 侧没应答）→ -EIO。**区别于** EE-ownership 不匹配（那是 -EPERM）。
- **`kebab.dts` 声明了 pm8009 这颗 PMIC**（pmic@a SID 0xa / pmic@b SID 0xb，正好对上报错地址 0x9708/0xa688），**但这颗 PMIC 在本机不响应 SPMI**。
- 同 SoC 的 Xiaomi pipa 同类 -EIO 是靠**删 DTS pm8009** 修好的（Bjorn Andersson 2025-08 合入），不是换内核。

### 证伪的死路（别再试）
- ❌ pin 内核到 6.13：`spmi-pmic-arb.c` 6.13 vs 6.17 事务/探测路径字节级相同，必复现。
- ❌ 切 stable channel：版本相同。
- ❌ 升 A13/A14：pmOS 与 Android 版本脱钩，A11 已是最匹配底座。

### 解法：DT patch 切除 pm8009（三处联动）
pm8009 自包含可干净切除（它只供 qca6390 WiFi/BT，做服务器不需要）：
```dts
&spmi_bus {            /* SPMI 路径：禁两个 SID 节点 */
    pmic@a { status = "disabled"; };
    pmic@b { status = "disabled"; };
};
&apps_rsc {            /* RPMh 路径：删 pm8009 regulators 块 */
    /delete-node/ regulators-0;
};
/* qca639x consumer 链：删 power-domains 引用 + 禁用，避免悬空 phandle */
&pcie0 { status = "disabled"; };
&pcie0_phy { /delete-property/ power-domains; status = "disabled"; };
```
- **关键**：pcie0 必须连 controller 一起禁（只删 phy 的 power-domains 会让 pcie0 probe 在 `phy_power_on()` hang）。
- **回归检查**：UFS 用的是 pm8150（regulators-1）系列 rail，与删的 pm8009（pmic-id=f）完全独立，未误伤。

**流程**：改 dts → chroot 内 `make dtb`（DTC < 1s）→ mkbootimg 配现有 vmlinuz/initramfs 重组 boot.img → `fastboot boot`（RAM 引导，零落盘）验证。

→ 内核越过 pmic，8 核 SMP 上线，跑到 UFS/USB 初始化。**根因坐实。**

---

## 2. 假象一：以为"卡在 UFS"

`loglevel=7` 静默版下，framebuffer 定格在最后一条 INFO（UFS warning `vdd-hba-supply not found`），误判卡 UFS。

**真相**：加 `ignore_loglevel + initcall_debug` 的诊断版揭穿——内核其实跑到了 1.5s+ 的 bpf initcall，UFS（SAMSUNG）正常挂载（sdd/sde/sdf 全出）。**那个 warning 是无害的，内核一直在往前跑。**

教训：**单帧 framebuffer 照片会骗人**，loglevel 屏蔽的 debug 消息让屏幕"定格"像卡死。用 `ignore_loglevel` 看完整日志才靠谱。

---

## 3. 真正卡 initramfs 的元凶：cmdline UUID 错配

内核过了，initramfs 起来了（USB gadget 出现），但落 debug shell。读 `/pmOS_init.log`：
```
Mount subpartitions of /dev/sdaXX → ERROR: failed to mount subpartitions! → Entering debug shell
```

### 调试通道（关键方法，Windows 不认 pmOS 的 NCM gadget）
pmOS 的 USB 网络 gadget 是 NCM，**Windows 不认**（识别成 "Android ADB 接口"，没出网卡）。解法：
```
usbipd-win → bind --busid X-X --force → attach --wsl   # 把 USB 透传进 WSL
# WSL 里 Linux 原生认 cdc_ncm，得到网卡 enxXXXX
ip addr add 172.16.42.2/24 dev enxXXXX
ping 172.16.42.1   # TTL=64 = 真 pmOS 设备直连
nc 172.16.42.1 23  # telnet 进 debug shell
```

### 根因
super 物理分区（GPT，扇区 4096）内嵌两个子分区：boot(ext2) + rootfs(ext4)。手动 `losetup` 挂出来确认 rootfs 完好（`os-release = postmarketOS edge`）。
**但 boot.img cmdline 里的 `pmos_root_uuid`/`pmos_boot_uuid` 是从旧 boot.img 抄的错值**。`find_root/boot_partition` 用 `blkid --uuid` 精确匹配，错配即 return 不 fallback → mount 失败 → debug shell。

### 解法
把 cmdline 的 UUID 改成实际分区 UUID（`blkid` 读真实值），重打包 boot.img → 直接进系统。

---

## 4. 进系统后：Docker 三连坑

系统起来了（ssh 通），装 Docker（`apk add docker docker-cli-compose`）后，dockerd 起不来，逐个修：

1. **cgroup 没挂** → `rc-update add cgroups boot`（ui=none 最小安装默认没启用）→ cgroup2 挂上。
2. **nf_tables 模块缺失** → docker 报 `iptables: Failed to initialize nft: Protocol not supported`。根因 = **内核/模块版本错配**（boot 用的 vmlinuz 与 rootfs `/lib/modules` 版本不一致）。修复：从匹配版本的构建源补 netfilter 模块（nf_tables/nft_chain_nat/nf_nat/xt_MASQUERADE/br_netfilter/veth/overlay）到设备 `/lib/modules` + `depmod`。⚠️ **boot 内核版本必须与 rootfs /lib/modules 严格匹配。**
3. **系统时间 1970** → docker pull TLS 证书验证失败 → 设对时间（无 RTC，需 NTP/swclock 持久）。

→ `docker run hello-world` 成功，cgroup v2 + overlayfs + cgroupns 全可用。

> **纠正一个常见担忧**：旧 Android 4.19 内核关 PID_NS 的问题，在 mainline 6.x **不存在**——namespaces（pid/net/user/...）齐全，Docker 底座可用，无需自编内核。

---

## 5. 持久化 + 开机自启链

`dd` 刷 boot-final.img 到 boot 分区（当前 slot），冷启动自动进系统。然后修开机自启：

- **存储**：根分区只有 6.4G，docker 数据放不下。把 224G 的 userdata 分区 `mkfs.ext4` 挂到 `/var/lib/docker` + fstab 开机自挂。docker daemon.json 配日志轮转 + data-root。
- **docker 自启的两个坑**：
  1. docker init `need net`，net 由 **NetworkManager 提供**（pmOS 默认，非 ifupdown），但 NM 没加开机自启 → `rc-update add networkmanager default`。
  2. docker 在 boot runlevel 但 NM 在 default，OpenRC 先 boot 后 default → docker 起时 NM 没起 → **把 docker 也移到 default runlevel**。
- **时间**：`rc-update add ntpd default + swclock boot`，删 hwclock（无 RTC）。

→ 最终 reboot 验证：docker + 容器全部开机自动起来。

---

## 6. 服务栈

`docker compose` 起 Home Assistant（host 网络，8123）+ ntfy（推送，8080），`restart: unless-stopped` 保证重启自恢复。compose 关键：每个容器设 `mem_limit` 防 OOM 拖垮整机。

---

## 7. 监控播报 + 双向 agent

- **监控**：`hermes-alert.sh` + crontab，只在异常（容器挂/磁盘≥85%/温度≥70/内存≥90）时推 Telegram，带去抖。（最初做的是每 10 分钟推状态卡片，太吵，改成异常才推。）
- **双向 agent**：`hermes-agent.py`（纯标准库 urllib，无依赖），long-poll Telegram，收指令在设备执行：`/status /docker /sh <命令> /ai <问题>（接大模型）/restart <容器>` 等，只响应主人 chat_id。OpenRC 服务自启。
- 配置走 `/etc/hermes-status.conf`（token/chat_id/AI 后端，**不硬编码进脚本**）。

---

## 8. 两个最终判定为"不可行"的硬限制

### 8a. WiFi 独立 —— 当前内核 + 本机硬件不可行
qca6390 WiFi 死结（穷尽两条 DT binding 都不通）：
- PCI 枚举出的是**裸 ID `0x0306`**（MHI 固件加载前）；ath11k_pci 只认 `0x1101`（固件加载后重枚举）。`0306→1101` 需驱动先给芯片加载固件上电。
- **新 binding**（`qcom,qca6390-pmu` + pwrseq）：上游成功版的 vddpmu/vddrfa0p95 依赖 **pm8009 的 smps2**——而本机这颗 pm8009 已坏（第 1 节）→ pwrseq enable 阶段死等 regulator → **内核态 hang**。
- **旧 binding**（直接 supply，走 dummy power-domain）：能进系统、能枚举 0306，但没驱动让它变 1101（`ath11k_pci new_id 17cb 0306` → `Unknown PCI device 0x306` → `-95 EOPNOTSUPP` 硬拒绝）。
- 结论：**pm8009 坏（个体硬件问题）断了 qca6390 的正确上电路径，软件绕不过。** 出路：USB-C 有线网卡（usbnet 已 working）。

### 8b. 屏幕动态显示 —— DRM 冻结
SM8250 走 DRM/MSM 显示，屏幕只在 boot 早期刷一次（那些日志），之后 `fb0`/tty 写入不触发 panel 刷新（`dd` 填白填黑都不上屏）。要动态显示需完整图形栈（weston/X），ui=none 不值得。**无头服务器屏幕 = 开机定格画面，正常现象。**

---

## 9. 关键经验总结

1. **framebuffer 单帧照片会骗人**——loglevel 屏蔽让屏幕定格像卡死。用 `ignore_loglevel + initcall_debug` 看完整日志。
2. **boot 内核版本必须与 rootfs /lib/modules 严格匹配**——否则模块全加载不了（docker 网络挂）。
3. **dtb 是版本无关的硬件描述**——pmic-disable 这种 DT 改动跨内核版本通用，6.13 编的 dtb 能配 6.16 内核。
4. **OpenRC 服务依赖 + runlevel 顺序**是 docker 自启的隐形坑（need net / boot vs default）。
5. **USB gadget 调试**：Windows 不认 NCM，用 usbipd 透传进 WSL，Linux 原生认。
6. **个体硬件故障（坏 PMIC）软件绕不过**——认清边界，及时转向（USB 网卡）而非无限啃。
