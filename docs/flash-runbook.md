# OnePlus 8T (kebab / KB2000 国行) → postmarketOS 刷机 Runbook

> 适用设备：本机自有、已授权的 OnePlus 8T，codename `kebab` / `OnePlus8T_CH`，型号 KB2000 国行。
> 目标形态：纯 postmarketOS（`ui=none`，headless），跑 Docker 服务器 / agent 节点。
> 上位机：Windows 11 + WSL2 `Ubuntu-24.04`，已装 `pmbootstrap 3.10.1`（源码安装，`/root/.local/bin/pmbootstrap`）。
> 当前真机状态：Android 15 / OxygenOS `KB2000_15.0.1.402(CN01)`，root（KernelSU Next），bootloader 已解锁（`verifiedbootstate=orange`，`device_state=unlocked`，`flash.locked=0`），当前 slot=`_a`。
>
> 文档版本：2026-06-01。本文件不含任何明文密码 / SSH 私钥 / token，凭据请在执行时另行注入。

---

## ⛔ 破坏性边界警告（先读这一段，再读其余任何内容）

本机刷机的核心风险点：**kebab 使用 dynamic partition（动态分区），postmarketOS 的 initramfs 无法挂载逻辑分区，因此 rootfs 必须直接刷进物理 `super` 分区——这一步会一次性覆盖整个 Android（system / vendor / product 等全部逻辑分区随之消失）。** 这不是“双系统”，是“整机换系统”。

在以下三个前置条件**全部**满足之前，**禁止执行任何 `fastboot flash` / `fastboot erase` / `fastboot format` / `pmbootstrap flasher flash_*` / `dd of=/dev/block/...` 等写操作**：

1. **备份完整性已校验通过**：`super.img` 与 `boot_a` 的 SHA256 与登记值逐字节一致，且尺寸正确（见阶段3）。当前备份**只有 super + boot_a**，dtbo / vbmeta / modem / persist / modemst1/2 / fsg / fsc **尚未备份**——回 Android 的最小退路只依赖 super.img，但 modem/persist 一旦异常将影响射频与校准，**强烈建议补齐这些只读 dump 后再继续**。
2. **WiFi 风险已知情并接受**：kebab 自身 wiki 的 WiFi 仍标 **Untested**。WiFi 芯片为 QCA6390 / ath11k。刷成 headless 后若 WiFi 不工作，且没有可用网络通道（见阶段7 的应急通道），设备将无法远程接入，只能回滚。**接受“可能刷完连不上 WiFi、需立即回滚”这一结果后才可继续。**
3. **usbipd USB 直通已验证稳定**：WSL2 下 fastboot 依赖 `usbipd-win` 把设备转发进 WSL；若直通会掉线 / 重连，**绝不能在刷写中途断流**。建议改用阶段4“在 WSL 生成镜像 + Windows 原生 fastboot 刷写”路线以规避 WSL USB 不稳定（推荐）。

> 任何一条不满足 → **停在非破坏阶段，不要进入阶段6**。

---

## 命令安全分级图例

每条命令都标注分级，执行前务必看清：

- 🟢 **只读安全**：不改变设备任何持久状态（查询、dump 到上位机、本地生成镜像、校验哈希）。可随意重复执行。
- 🟡 **临时/可恢复**：改变运行时状态但不写持久分区（如 `fastboot boot` 临时引导、`usbipd attach`），重启即恢复。
- 🔴 **破坏性**：写持久分区 / 覆盖系统 / 改 active slot。执行即不可逆（除非按回滚还原）。每条 🔴 命令都附带【前置检查】【预期输出】【失败即停】【对应回滚】。

---

## 阶段0 · 上位机就绪检查（全部 🟢 只读安全）

目的：确认工具链版本、备份在位、镜像空间充足，再碰设备。

```powershell
# Windows PowerShell（管理员）
fastboot --version            # 期望 platform-tools 37.0.0 一致
adb --version
usbipd --version              # 需已安装 usbipd-win
```

```bash
# WSL Ubuntu-24.04，使用干净 PATH 避免 "Program Files (x86)" 括号污染
export PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
pmbootstrap --version         # 期望 3.10.1
pmbootstrap status            # 确认已 init 且 device=oneplus-kebab
```

【前置检查清单（人工逐条打勾）】
- [ ] `pmbootstrap status` 显示已 init，device=`oneplus-kebab`、channel=`edge`、kernel=`mainline`、ui=`none`。
- [ ] `extra_packages` 含 `linux-firmware-ath11k,firmware-oneplus-instantnoodlep,linux-firmware-qcom,networkmanager,openssh`。
- [ ] 备份文件在位且尺寸正确：
  - `backup-stock/super.img` = **7516192768** bytes
  - `backup-stock/boot_a-KSU_NEXT.img` = **100663296** bytes
- [ ] 上位机磁盘剩余空间 ≥ 20 GB（super.img 7.5G + sparse 转换临时副本 + pmOS rootfs 镜像）。
- [ ] 一根**确认稳定**的 USB 数据线（非充电线），直插主板 USB 口，不经 hub。

> 阶段0 不涉及任何写操作。任一项不满足，停在此处修复。

---

## 阶段1 · USB 直通到 WSL（usbipd）

> 仅当你选择“在 WSL 内直接 fastboot 刷写”路线时需要本阶段。**推荐路线是阶段4 在 WSL 生成镜像、然后用 Windows 原生 fastboot 刷写**，可完全跳过 usbipd，规避 WSL USB 抖动风险。

### 1.1 列出并定位设备（🟢 只读安全）

```powershell
# Windows PowerShell（管理员）
usbipd list
```
【预期输出】能看到 OnePlus / Qualcomm 相关 BUSID（fastboot 模式下通常显示为 "Android" 或 "QUSB_BULK" / "Fastboot"）。记下 `BUSID`（形如 `2-4`）。

### 1.2 绑定（🟡 临时，一次性共享，可 unbind 还原）

```powershell
usbipd bind --busid 2-4        # 用 1.1 查到的真实 BUSID 替换
```

### 1.3 附加到 WSL（🟡 临时，重启/拔线即断）

```powershell
usbipd attach --wsl --busid 2-4
```

```bash
# WSL 内验证
lsusb                          # 应能看到设备
fastboot devices               # fastboot 模式下应列出序列号
```

【失败即停条件】
- `usbipd attach` 后 WSL 内 `lsusb` 看不到设备，或设备**反复出现/消失**（dmesg 刷 disconnect）→ **判定 USB 直通不稳定，放弃 WSL 直刷，改用阶段4 Windows 原生 fastboot 路线**。绝不能带着抖动的直通进入阶段6。

### 1.4 用完分离（🟢 还原）

```powershell
usbipd detach --busid 2-4
# 如需彻底解除共享： usbipd unbind --busid 2-4
```

---

## 阶段2 · 进 fastboot 只读核验（全部 🟢 只读安全）

目的：在不写任何分区的前提下，确认这就是预期设备、预期 slot、已解锁。

### 2.1 从系统重启进 bootloader

```bash
adb reboot bootloader          # 🟡 仅重启进 fastboot，不改持久状态
```

### 2.2 全量只读核验

```bash
fastboot getvar all 2>&1 | tee fastboot-getvar-all.txt   # 🟢 只读，dump 到上位机
fastboot getvar current-slot   # 🟢
fastboot getvar unlocked       # 🟢
fastboot getvar product        # 🟢
fastboot getvar is-userspace   # 🟢 确认是否 fastbootd（dynamic partition 相关）
```

【预期输出（逐条核对，不符即停）】
- `current-slot: a`（与已知 slot=`_a` 一致）
- `unlocked: yes`
- `product: kebab`（或 `OnePlus8T` / `kona` 平台标识，以实测为准；**必须确认是 kebab，不是其它机型**）
- `getvar all` 中 `partition-size:super` 应约等于 7516192768（0x1C0000000 量级）

【失败即停条件】
- `unlocked: no` → bootloader 未解锁，**禁止继续**，所有 flash 都会被拒绝且可能变砖。
- `product` 不是 kebab / 8T 平台 → **接错设备或镜像不匹配，立即停手**。
- `current-slot` 不是 `a` 而是 `b` → 先核对，确认 pmOS 刷写目标 slot 与备份 slot 一致后再继续。

> 本阶段全程只读，可反复执行，不产生任何回滚需求。

---

## 阶段3 · 备份完整性校验（全部 🟢 只读安全，这是进入破坏阶段的闸门）

目的：在覆盖 Android 之前，确证“回得去”。

### 3.1 校验已有备份哈希

```bash
# 在 backup-stock 目录
cd /mnt/d/claude/workspace/一加8T-Hermes/backup-stock   # WSL 路径
sha256sum -c SHA256SUMS.txt    # 🟢 只读校验
```

【登记基准值（用于人工比对，勿改）】
```
super.img            = a0ae4000261dd4c12c344ceb1286580d99c52782c6f094fca4075cbb7287cb8c   (7516192768 bytes)
boot_a-KSU_NEXT.img  = df0d581809b5bf7aae8709350c43c2a8ca6152ceefa540ff6046122c4e897d43   (100663296 bytes)
```

【预期输出】两行均 `OK`。

【失败即停条件】任一行 `FAILED` 或文件尺寸不符 → **备份损坏，禁止进入阶段6**，必须重做 dump 备份。

### 3.2 （强烈建议补齐）补做关键分区只读 dump

当前备份**缺** dtbo / vbmeta / modem / persist / modemst1/2 / fsg / fsc。这些不影响“回到能开机的 Android”（靠 super 即可），但缺 modem/persist 可能导致回滚后射频 / IMEI / 传感器校准异常。补做方法（设备已 root，用 root shell 读 by-name，**只读 dd，输出到上位机，不写设备**）：

```bash
# 在设备 root shell 内（adb shell → su），按 by-name 读取，绝不写回
# 🟢 只读 dump；务必 dump 完用 sha256sum 登记
for P in dtbo_a vbmeta_a vbmeta_system_a modem_a persist modemst1 modemst2 fsg fsc; do
  src=$(ls -l /dev/block/by-name/$P 2>/dev/null)
  echo "== $P -> $src"
done
# 确认 by-name 软链后逐个：
#   su -c "dd if=/dev/block/by-name/persist of=/sdcard/persist.img bs=4M"
#   再 adb pull /sdcard/persist.img backup-stock/
```

> **务必用 `by-name` 或 fastboot 分区名，不要按物理 `sdX` 编号 dd/刷写。** 已实测的物理映射仅供核对：
>
> | 分区 | 物理块 | 尺寸(bytes) |
> |---|---|---|
> | super | /dev/block/sda15 | 7516192768 |
> | boot_a | /dev/block/sde11 | 100663296 |
> | boot_b | /dev/block/sde35 | 100663296 |
> | dtbo_a | /dev/block/sde17 | 25165824 |
> | dtbo_b | /dev/block/sde41 | 25165824 |
> | vbmeta_a | /dev/block/sde16 | 65536 |
> | vbmeta_b | /dev/block/sde40 | 65536 |
> | modem_a | /dev/block/sde4 | 536870912 |
> | modem_b | /dev/block/sde28 | (同 modem_a 量级) |
> | persist | /dev/block/sda2 | 33554432 |
> | modemst1/2 / fsg / fsc | /dev/block/sdf* | 见真机 by-name |
>
> 物理编号（sdX 数字）在不同启动 / 重新分区后**可能漂移**，因此实际刷写/备份一律走 by-name 或 fastboot 分区名。

---

## 阶段4 · 在 WSL 生成 pmOS 镜像（全部 🟢 只读安全）

目的：本地构建 rootfs / boot / dtbo 镜像，全程不碰设备。这一步出错只是重来，不会损坏手机。

```bash
export PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1) 构建并安装 rootfs 到 pmbootstrap 工作目录（🟢 只在上位机生成镜像，不写设备）
pmbootstrap install
```
【预期输出】构建完成，生成 system / boot / dtbo 等镜像于 pmbootstrap chroot 下；无 ERROR 退出。

【失败即停】`pmbootstrap install` 报错（缺 firmware 包 / 依赖 / 磁盘空间）→ 修复后重跑，**不要进入刷写**。重点确认日志里 ath11k / instantnoodlep / qcom firmware 均被纳入。

> 说明：`pmbootstrap install` 本身只在上位机构建镜像，是 🟢 安全的；真正写设备的是后续 `flasher flash_*`（🔴）。

---

## 阶段5 · （可选）临时 boot 验证（🟡 临时，不写持久分区）

目的：在覆盖 super 之前，用临时引导先验证内核能起、能进系统、（理想情况）能识别 WiFi。**临时 boot 不改任何分区，断电即恢复 Android。**

```bash
# 设备处于 fastboot
pmbootstrap flasher boot        # 🟡 临时引导 pmOS 内核+initramfs，不写 flash
# 或手动： fastboot boot <pmbootstrap 生成的 boot.img 路径>
```

【预期输出】设备临时启动进 pmOS（headless 下通过串口 / `dmesg` / 后续网络判断）。

【失败即停 / 决策点】
- 临时 boot 失败、卡 logo、或起来后 `ip link` 看不到 `wlan0`、`dmesg | grep ath11k` 无固件加载 → **强信号：持久化刷写大概率连不上 WiFi**。此时**回到破坏性边界第2条**重新决策：是否接受 headless 无 WiFi 风险。不接受就**停在此处，设备仍是完整 Android（拔电即恢复）**。

【回滚】临时 boot 无需回滚——直接 `fastboot reboot` 重启即回到原 Android slot `_a`。

---

## 阶段6 · 持久化刷写（🔴 破坏性，逐条带闸门）

> **进入本阶段前，确认：阶段3 哈希全 OK + 破坏性边界三条全满足 + usbipd 稳定或已切 Windows 原生 fastboot。**
> 推荐执行环境：**Windows 原生 fastboot**（用阶段4 在 WSL 生成的镜像；通过 `\\wsl$\Ubuntu-24.04\...` 或 `pmbootstrap export` 把镜像取到 Windows），或确认稳定的 WSL 直通。
> 命令顺序固定为：**flash_dtbo → flash_rootfs → flash_kernel**（以同内核姊妹机 8Pro instantnoodlep 为准）。

### 6.1 刷 dtbo（🔴 破坏性）

```bash
pmbootstrap flasher flash_dtbo
```
- 【前置检查】阶段2 `current-slot: a` 且 `unlocked: yes`；阶段3 哈希 OK；dtbo_a 已备份（25165824 bytes）。
- 【预期输出】`OKAY` / `Finished`，写入 `dtbo` 分区成功，无 FAILED。
- 【失败即停】出现 `FAILED (remote: ...)` / `not allowed in locked state` / 写入中途断流 → **立即停手，不要继续 flash_rootfs**。先核对解锁状态与 USB 稳定性。
- 【对应回滚】用备份还原 dtbo（fastboot 分区名）：
  ```bash
  fastboot flash dtbo_a backup-stock/dtbo_a.img    # 需先在阶段3.2 备出 dtbo_a.img
  ```

### 6.2 刷 rootfs 到 super（🔴🔴 最高破坏性 —— 此步覆盖整个 Android）

```bash
pmbootstrap flasher flash_rootfs
```
- 【前置检查】**这是不可逆分水岭**。再次确认：
  - [ ] `super.img` 哈希 = `a0ae4000...87cb8c`，尺寸 7516192768，校验通过；
  - [ ] 已接受“Android 自此被清空”；
  - [ ] WiFi 风险已知情；
  - [ ] 线缆稳定、不经 hub。
- 【预期输出】写入 `super`（约 7.5G，耗时较长）`OKAY` / `Finished`，无中途断流。
- 【失败即停】写到一半断流 / `FAILED` → **不要重启、不要拔线乱试**；super 此刻处于不一致状态。**直接进入阶段8 回滚**，用 `super.img` 重刷恢复 Android，再排查 USB/线缆后从阶段3 重来。
- 【对应回滚】见阶段8.1（fastboot flash super，需 sparse 转换）。

### 6.3 刷 kernel（🔴 破坏性）

```bash
pmbootstrap flasher flash_kernel
```
- 【前置检查】6.1、6.2 均 `OKAY`；boot_a 已备份（100663296 bytes，哈希 `df0d5818...4d43`）。
- 【预期输出】写入 `boot` 分区 `OKAY` / `Finished`。
- 【失败即停】`FAILED` 或断流 → 停手；此时 super 已是 pmOS、boot 可能半写。**进入阶段8**：要么重试 flash_kernel，要么整机回滚到 Android（super.img + boot_a.img 都要还原）。
- 【对应回滚】还原 boot_a：
  ```bash
  fastboot flash boot_a backup-stock/boot_a-KSU_NEXT.img
  ```

### 6.4 重启进系统（🟡）

```bash
fastboot reboot
```

---

## 阶段7 · 首启与 WiFi 验证

目的：确认 pmOS 起来、网络可达。headless 无屏，依赖网络 / 串口判断。

### 7.1 网络发现（🟢 只读）

```bash
# 上位机
ping <设备首启 IP 或 .local 主机名>
nmap -sn 192.168.x.0/24        # 在局域网内扫存活，找设备
```

### 7.2 SSH 接入（🟢 只读连接）

```bash
ssh <用户名>@<设备IP>          # 用户名/口令在 pmbootstrap init 时设定，本文件不记录
```
> 不要在本文件或任何日志写入明文口令 / 私钥。首次登录后建议改用密钥登录并禁用口令登录（具体见 ops-runbook）。

### 7.3 WiFi 实测（🟢 只读，登录后在设备内）

```bash
ip link                        # 期望出现 wlan0
dmesg | grep -i ath11k         # 期望看到固件加载、无 firmware missing 报错
nmcli device status            # NetworkManager 是否管理 wlan0
nmcli device wifi list         # 能否扫到 AP
```

【失败即停 / 决策】
- 无 `wlan0` / `ath11k` 报 `Direct firmware load ... failed` → 固件包没进 rootfs 或驱动不兼容。**这是 kebab WiFi=Untested 的已知风险落地**。
- 若 headless 下既无 WiFi 又无其它网络通道（USB 网卡 / USB tethering / 串口），设备**无法远程管理** → 直接进入**阶段8 回滚**，或改用有线/USB-Ethernet 通道后再排查固件。
- 应急网络通道：QCA6390 还带蓝牙，但 headless 优先考虑 USB-RNDIS / USB Ethernet 适配器作为带外通道。

---

## 阶段8 · 回滚（恢复 Android）

> 唯一可靠退路：用备份的 `super.img` 重刷整个 super，再视情况还原 boot_a / dtbo。
> **dynamic partition 的 super 必须以 sparse 格式刷写**，否则 `fastboot flash super` 会因镜像过大 / 格式不符失败。

### 8.1 super 还原（🔴 破坏性，但目标是恢复 Android）

```bash
# 1) 把 raw super.img 转 sparse（🟢 只在上位机生成，不碰设备）
img2simg backup-stock/super.img backup-stock/super.sparse.img
#   （img2simg 来自 android-sdk-libsparse-utils；尺寸应仍约 7.5G，sparse 表示）

# 2) 设备进 fastboot / fastbootd（dynamic partition 写 super 通常需 fastbootd）
fastboot reboot fastboot       # 🟡 进 userspace fastbootd
fastboot getvar is-userspace   # 🟢 期望 yes

# 3) 刷回 super（🔴）
fastboot flash super backup-stock/super.sparse.img
```
- 【前置检查】`super.img` 哈希 = `a0ae4000...87cb8c`、尺寸 7516192768；`is-userspace: yes`（fastbootd）。
- 【预期输出】`OKAY` / `Finished`。
- 【失败即停】报 `FAILED (remote: 'invalid sparse...')` / 尺寸超限 → 检查 img2simg 是否成功、是否在 fastbootd 模式；不要反复盲刷。

### 8.2 boot / dtbo 还原（🔴，按需）

```bash
fastboot flash boot_a backup-stock/boot_a-KSU_NEXT.img    # 还原 KSU_NEXT boot
fastboot flash dtbo_a backup-stock/dtbo_a.img             # 若阶段3.2 已备出
fastboot set_active a                                     # 🔴 确保 active slot=a
fastboot reboot
```
- 【前置检查】boot_a 哈希 = `df0d5818...4d43`；slot 目标 = `a`。
- 【预期输出】重启后进入原 OxygenOS / 能开机。
- 【失败即停】仍不开机 → 检查是否漏刷 vbmeta（解锁机通常无需，但若刷过 vbmeta 需对应还原）；必要时进 EDL 仅作为**最后手段**（高风险，需匹配的官方 fastboot 包 / MSM 工具，超出本 runbook 范围）。

---

## 附：执行总闸（贴在终端旁）

```
进入阶段6 前必须 ALL YES：
[ ] 阶段3 sha256sum -c 两行全 OK，尺寸正确
[ ] super 缺失分区(persist/modem)已知情或已补 dump
[ ] WiFi=Untested 风险已接受，且有 WiFi 失败后的网络退路计划
[ ] usbipd 稳定 或 已切 Windows 原生 fastboot
[ ] fastboot getvar：current-slot=a / unlocked=yes / product=kebab
[ ] 线缆稳定、直插、不经 hub、电量充足
任一 NO → 停在阶段5 之前，设备仍是完整可用 Android。
```

> 本 runbook 全程区分：🟢 只读安全 / 🟡 临时可恢复 / 🔴 破坏性。除阶段6 与阶段8 的 🔴 命令外，阶段0–5、7 的核验与生成镜像步骤均不改变设备持久状态，可反复执行。
