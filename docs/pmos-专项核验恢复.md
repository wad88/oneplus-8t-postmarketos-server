# pmOS 专项核验恢复：OnePlus 8T kebab
恢复时间：2026-06-01 17:35

## 原始归档
- 主专项 workflow 原始 JSON：`recovered-workflows/wf_3670f4ad-351.json`
- broader research workflow 原始 JSON：`recovered-workflows/wf_30e8a624-175.json`
- 旧 task 输出：`recovered-workflows/w2p7zz0ku.output`
- 原旧会话 ID：`9bc4cfa1-abbd-41a1-a879-3b5cc5d6b6c4`
- 主专项 workflow：`wf_3670f4ad-351`，agentCount=14

## 总结结论
- `oneplus-kebab` 刷 postmarketOS 可行，但 `flash_rootfs` 会覆盖整个 `super`，Android 会被清空。
- 推荐顺序：`pmbootstrap install` → `pmbootstrap flasher flash_dtbo` → `pmbootstrap flasher flash_rootfs` → `pmbootstrap flasher flash_kernel`。
- 设备因 dynamic partitions，pmOS initramfs 不能挂载逻辑分区，rootfs 必须直接刷进 `super` 物理分区。
- WiFi 是最大不确定性：SM8250/姊妹机资料支持高概率可用，但 kebab wiki 自身仍标 `Untested`；必须刷后以 `ath11k`/`wlan0` 实测为准。
- `pmbootstrap` 不支持 Windows 原生；上位机应使用 WSL2 Ubuntu 或原生 Linux。
- 在完整核验和回滚路径准备完之前，继续禁止任何 `fastboot flash` / `pmbootstrap flasher flash_*`。

## 1. postmarketOS 刷机命令序列研究 (OnePlus 8T / oneplus-kebab, 2026 现状)

### 摘要
已用 fetch MCP 抓取 wiki.postmarketos.org 的 kebab、instantnoodlep(8Pro 近亲)、SM8250 SoC、Installation、pmbootstrap 安装五个原文页核实。结论:kebab 因 dynamic partition,initramfs 无法挂载逻辑分区,所以 pmOS 的 rootfs 必须用 `pmbootstrap flasher flash_rootfs` 直接刷进 super 物理分区(覆盖整个 super,Android 一并清空,符合你的接受范围);没有 boot/recovery 安装方式,但有 boot/dtbo/kernel 三个独立分区要刷。kebab 自己的 wiki 安装段过简(只写 flash_rootfs + flash_dtbo),但它的内核包/固件与 8Pro instantnoodlep 完全相同(都用 linux-postmarketos-qcom-sm8250 + QCA6390/ath11k),8Pro 页维护更全,命令序列以 8Pro 为准:install → flash_dtbo → flash_rootfs → flash_kernel。WiFi 关键:SoC 层和 8Pro 设备层都标 WiFi=Works,但必须在 pmbootstrap init 时手动追加固件包 linux-firmware-ath11k,firmware-oneplus-instantnoodlep,linux-firmware-qcom,否则 wlan0 起不来——这是你 WiFi 硬需求能否满足的决定性前置。重大风险点:kebab 自己 wiki 上 WiFi 仍标 Untested(只是与 8Pro 同构所以大概率 Works),且 3D 加速在 8Pro 上标 Broken(你做无头服务器不受影响),v6.11 附近曾有 DTS 回归打断 WiFi/BT 后已在 v6.12 修复,务必用 edge/最新内核而非 downstream。pmbootstrap 不支持 Windows——你那台 Win11 必须先装 WSL2(Ubuntu)或一台 Linux 才能跑全部 pmbootstrap 命令;fastboot/adb 部分可在 Windows 跑,但 flasher 全流程建议都在 Linux/WSL2+usbipd 里做。slot 方面:pmbootstrap flasher 默认刷当前 active slot(_a),无需手动切 slot;vbmeta 方面 pmbootstrap 已禁用 AVB 链(刷的 boot 自带绕过),Bootloader 已 orange 解锁状态不强制单独刷 vbmeta,但保险起见可先刷一份 --disable-verity --disable-verification 的空 vbmeta。降低变砖:可先用 pmbootstrap flasher boot 把 initramfs 临时 boot 进 RAM(不落盘),telnet 进 initramfs 验证再决定是否持久化——但注意 dynamic partition 下 initramfs 无法挂 rootfs,这个临时 boot 只能验证内核/USB 起没起、不能验证 WiFi(WiFi 要等 rootfs 真刷进 super 后才能测)。务必先 adb pull super.img 备份,这是唯一的回 Android 退路。

### 步骤 / 建议
1. 【前置 0·环境】pmbootstrap 不支持 Windows。在 Win11 装 WSL2 Ubuntu:`wsl --install -d Ubuntu`;WSL 内 `sudo apt install python3 python3-pip openssl git`;USB 直通用 usbipd-win:Win 端 `winget install usbipd`,设备进 fastboot 后 `usbipd list` → `usbipd bind --busid <x>` → `usbipd attach --wsl --busid <x>`,WSL 内 `lsusb` 能看到 18d1/05c6 才算通。fastboot/adb 也在 WSL 内装:`sudo apt install android-tools-adb android-tools-fastboot`。
2. 【前置 1·备份 super,唯一退路】Android 下开 root adb(KernelSU 已有 root):`adb root`(若不行用 `adb shell su -c`);`adb pull /dev/block/by-name/super super.img`。这份 super.img 是日后 `img2simg super.img super-s.img && fastboot flash super super-s.img` 回 Android 的唯一依据,务必存好。同时记下当前 slot=_a。
3. 【安装 pmbootstrap(WSL/Linux 内)】`git clone https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git && cd pmbootstrap && mkdir -p ~/.local/bin && ln -s "$PWD/pmbootstrap.py" ~/.local/bin/pmbootstrap`;`export PATH="$HOME/.local/bin:$PATH"`;`pmbootstrap --version` 应回版本号。
4. 【pmbootstrap init·关键 WiFi 配置】运行 `pmbootstrap init`:vendor 选 oneplus,device 选 oneplus-kebab,kernel 选 mainline(不要 downstream),release 选 edge(拿到 v6.12+ 已修 WiFi DTS 的内核;若求稳可 v25.12 stable 但确认其内核 ≥6.12)。在询问额外包(extra packages)时务必填:`linux-firmware-ath11k,firmware-oneplus-instantnoodlep,linux-firmware-qcom`——这是 WiFi 能起的硬前置;UI 选 none(无头服务器)。
5. 【生成镜像】`pmbootstrap install`(生成 rootfs+boot+dtbo+kernel;dtbo.img 只有在 install/initramfs 生成后才存在)。
6. 【进 fastboot】设备关机,插 USB,长按电源等振动,再同时按音量上+下进 fastboot(已解锁 orange 状态正常)。WSL 内 `fastboot devices` 确认在线。
7. 【可选·先 boot 验证降砖险】`pmbootstrap flasher boot`(把 initramfs 临时 boot 进 RAM,不落盘);另开终端 `telnet 172.16.42.1` 进 initramfs,验证内核启动/USB 网络正常。注意:dynamic partition 下此步无法挂 rootfs、无法测 WiFi/GPU,只能验证核心启动链;断电即恢复,零风险。验证 OK 后继续持久化。
8. 【可选·先刷绕 verity 的 vbmeta(保险)】Bootloader 已解锁通常可跳过;若 boot 后卡 verity 报错再补:从 platform-tools 取一份空 vbmeta 或用 `fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img`(当前 slot _a 对应 vbmeta_a)。pmbootstrap 刷的 boot 一般已自带绕过,默认先不刷。
9. 【持久化刷机·命令序列,顺序照 8Pro】依次执行:`pmbootstrap flasher flash_dtbo` → `pmbootstrap flasher flash_rootfs`(这步把 rootfs 写进 super 物理分区,Android 被覆盖)→ `pmbootstrap flasher flash_kernel`(刷 boot)。三条都默认作用于当前 active slot _a,无需手动 --set-active 或加 _a 后缀。
10. 【首次启动+连 WiFi 验证】重启,USB 接 PC,等 SSH 起来:`ssh user@172.16.42.1`(initramfs telnet → 系统 SSH 都是这个地址)。进系统后确认固件加载:`dmesg | grep ath11k` 应看到 qca6390 hw2.0 被识别、`ip link` 有 wlan0 处于 UP;用 nmcli/iwd 连你的路由。WiFi 通了才算达成 24x7 服务器前置。
11. 【回滚 Android(如需)】WSL/Linux 内 `img2simg super.img super-s.img`,设备进 fastboot 后 `fastboot flash super super-s.img`,再刷回原 boot_a/dtbo_a 或切到未动过的 _b slot;若仍异常用 `fastboot wipe-super super_empty.img` 后刷 LineageOS OTA,或 Windows 下 MsmDownloadTool 全量恢复。
12. 【部署目标栈】WiFi+SSH 稳定后,Alpine 上 `apk add docker docker-compose && rc-update add docker && service docker start`;Home Assistant 用容器 `ghcr.io/home-assistant/home-assistant:stable`;内网穿透用 frp/cloudflared/tailscale 容器;监控播报另起容器。注意 Alpine 是 musl,个别镜像需 arm64+glibc 兼容确认。

### 关键事实
- [high] kebab 用 dynamic partition,pmOS initramfs 无法挂载逻辑分区,必须用 pmbootstrap flasher flash_rootfs 把 rootfs 直接刷进 super 物理分区(覆盖整个 super,Android 一并清掉);没有 boot/recovery 安装方式
  - source: wiki.postmarketos.org/wiki/OnePlus_8T_(oneplus-kebab) 安装段原文:'This device uses dynamic partitions...PostmarketOS initramfs cant mount these logical partitions yet. Well need to flash the rootfs directly onto the super partition'
- [high] 完整命令序列(以同内核同固件的 8Pro instantnoodlep 为准,kebab 页过简):pmbootstrap install → pmbootstrap flasher flash_dtbo → pmbootstrap flasher flash_rootfs → pmbootstrap flasher flash_kernel
  - source: wiki OnePlus_8_Pro_(instantnoodlep) Installation 段原文逐行命令;kebab 页只列 flash_rootfs+flash_dtbo,但两机共用 linux-postmarketos-qcom-sm8250 内核包
- [high] WiFi 能否用是硬前置:必须在 pmbootstrap init 额外包里手动加 linux-firmware-ath11k,firmware-oneplus-instantnoodlep,linux-firmware-qcom,否则 wlan0 起不来。芯片 QCA6390/ath11k
  - source: wiki 8Pro 安装段 Warning 原文:'To make OTG and Wi-Fi work, specify these additional packages: linux-firmware-ath11k,firmware-oneplus-instantnoodlep,linux-firmware-qcom'
- [medium] WiFi 在 SoC 层(SM8250)和 8Pro 设备层都标 Works;但 kebab 自己 wiki 仍标 WiFi=Untested,只是同构推断大概率可用——这是你 WiFi 硬需求的主要不确定性
  - source: wiki SM8250 SoC 页 WiFi=Works、8Pro 页 WiFi=Works;但 kebab 页 Connectivity/WiFi=Untested(同页 features 表)
- [high] v6.11 附近 SM8250 DTS 回归曾打断 WiFi/BT,已在 v6.12 分支修复;应选 mainline+edge/最新内核,不要 downstream
  - source: WebSearch sm8250-mainline GitLab MR !8 'Restore Wi-Fi/BT functionality' + 8Pro 安装段 'Dont recommend use of downstream kernel...Choose mainline during pmbootstrap init'
- [high] 3D 加速在 8Pro 设备层标 Broken(SoC 层 GPU 标 Works,设备集成层坏);你做无头 24x7 Docker 服务器不受影响
  - source: wiki 8Pro features 表 3D Acceleration=Broken;SM8250 SoC 表 GPU=Works(矛盾源于设备 panel/display 集成)
- [high] pmbootstrap 不支持 Windows,你那台 Win11 必须装 WSL2/Linux 才能跑;Other operating systems 段明确不支持,仅提及有人用 WSL
  - source: wiki pmbootstrap/Installation 'Other operating systems' 段:'Running pmbootstrap on other operating systems than Linux is not supported...Some people also made it work with WSL...not officially supported'
- [medium] slot 无需手动管:pmbootstrap flasher 默认刷当前 active slot(你的 _a);vbmeta 通常不需单独刷(已 orange 解锁+pmbootstrap boot 自带绕 AVB),仅卡 verity 时再 fastboot --disable-verity --disable-verification flash vbmeta
  - source: kebab/8Pro 安装段全程未出现 vbmeta 或 set-active 步骤,仅 flash_dtbo/flash_rootfs/flash_kernel;Bootloader 已解锁 verifiedbootstate=orange(用户实测指纹);vbmeta 绕过为通用 AVB 实践推断
- [high] 回 Android 唯一退路:刷机前 adb pull /dev/block/by-name/super super.img 备份;恢复时 img2simg super.img super-s.img 后 fastboot flash super super-s.img
  - source: wiki kebab 与 8Pro 两页 'Getting back to Android'/'Back to Android' 段原文命令
- [medium] 可先 pmbootstrap flasher boot 临时 boot initramfs 进 RAM(不落盘)telnet 172.16.42.1 验证启动链降砖险,但 dynamic partition 下此步无法挂 rootfs、无法测 WiFi/GPU
  - source: 通用 pmbootstrap flasher boot 语义 + kebab 页 'initramfs cant mount logical partitions yet' 限制推断;SM8250 USB Networking telnet(initramfs)/SSH 均 Works
- [high] 当前 stable=v25.12,edge 为滚动版;WiFi DTS 修复需内核≥6.12,优先 edge 或确认 stable 内核版本
  - source: wiki Installation guide 'latest stable release is v25.12' + edge 滚动说明

### 风险
- WiFi 是你的硬性需求,但 kebab 自己 wiki 上 WiFi 仍标 Untested(仅因与 8Pro 同内核同固件而推断 Works);若实刷后 ath11k 不起,这台机器作为 24x7 服务器的核心价值就没了。强烈建议刷前先在 sm8250-mainline Matrix/OFTC 频道问一句 kebab 最新内核 WiFi 实测,或接受先刷验证、不行就用 super.img 回滚的方案。
- flash_rootfs 会覆盖整个 super 物理分区,你现有的 Tricky Store/Shamiko/LSPosed/PIF 过检测环境、KernelSU、Android 全部清空且不可逆(除非用备份的 super.img 回滚)。务必先 adb pull super.img,否则无退路。
- pmbootstrap 不支持 Windows。你目前只有 platform-tools 没装 pmbootstrap,且 WSL 能力未知。WSL2 下 fastboot USB 直通要靠 usbipd-win 转发,配置失败率不低;最稳是临时找一台原生 Linux 跑 flasher。
- 3D/GPU 在 8Pro 上 Broken、kebab 上 Untested,且 Display 整体 Partial——做无头服务器没问题,但别指望接屏幕跑桌面。
- 你当前内核是第三方 4.19 KSU_NEXT downstream,与 pmOS mainline 6.12 完全无关;刷 pmOS 后内核被 pmOS 自己的 boot/dtbo 接管,不要试图保留现有内核。
- modem 报废你已接受;额外注意 GPS/蓝牙/传感器在 8Pro 多为 Broken,若后续想用 BT 接外设需另行验证。
- v6.11 那次 WiFi 回归说明该 SoC 的 DTS 偶发性 break WiFi/BT,edge 滚动更新有再次踩雷风险;生产服务器建议锁定一个验证过 WiFi 可用的内核版本,别盲目随 edge 升级。

## 2. postmarketOS oneplus-kebab/SM8250 上运行 Docker + Home Assistant 的可行性研究

### 摘要
结论: OnePlus 8T(kebab) 刷 postmarketOS 后跑 Docker 在方向上可行,关键阻塞不在 musl/Alpine,而在实际刷入的 linux-postmarketos-qcom-sm8250 内核配置、模块是否随包安装、以及 WiFi 固件/主线支持是否在你的构建里完整。pmOS v25.06 已以 Alpine 3.22 为基底并引入 systemd,主流 UI 预构建镜像偏 systemd,Sxmo 仍是 OpenRC；作为 24x7 服务器建议选 console/no UI 的最小系统,OpenRC 或 systemd 都可,但如果按 Alpine 官方 Docker 文档走,OpenRC 路径最直接。已核到 sm8250-mainline 的旧 pmaports 配置中 PID_NS、USER_NS、CGROUP_PIDS、MEMCG、OVERLAY_FS、VETH、NAT/iptables 关键项大多已启用或模块化,明显优于你当前真机 4.19 KSU 内核缺 PID_NS/USER_NS/CGROUP_PIDS 的状态。风险点是该旧配置里 BRIDGE_NETFILTER 为 not set,而 postmarketOS 当前 kconfigcheck 的 containers 类别要求 BRIDGE_NETFILTER=true；因此不能只凭旧配置断言当前官方包 100% 免自编译,刷机后必须用 /proc/config.gz 和 Docker check-config 实测。Alpine 主机是 musl 不影响容器内 glibc/Alpine 用户态,Home Assistant ARM64 容器只共享宿主内核,不会因为宿主 musl 而无法运行 glibc 镜像。若 Docker bridge/NAT 或 iptables/nftables 出错,最可能要补的是内核 netfilter/bridge 模块或切 iptables-legacy,不是换 glibc 发行版。

### 步骤 / 建议
1. 刷机选择建议: 用 pmbootstrap 构建 oneplus-kebab,UI 选 none/console 或最轻量 shell,不要选 GNOME/Plasma 这类重 UI；若需要完全按 Alpine 文档管理服务,优先 OpenRC；若使用 pmOS v25.06 默认 systemd 也可,但 Docker 服务命令需改为 systemctl。
2. 刷后先验 WiFi: `ip link`, `dmesg | grep -Ei 'ath11k|wlan|firmware|qcom'`, `nmcli dev wifi list` 或 iwd/NetworkManager 对应命令；只有 WiFi 稳定后再进入 Docker 部署。
3. 核对当前内核配置: `zcat /proc/config.gz | egrep 'CONFIG_(NAMESPACES|PID_NS|USER_NS|NET_NS|CGROUPS|CGROUP_PIDS|MEMCG|OVERLAY_FS|VETH|BRIDGE|BRIDGE_NETFILTER|NF_NAT|IP_NF_FILTER|IP_NF_TARGET_MASQUERADE)='`。
4. 核对 cgroup v2: `mount | grep cgroup`, `test -f /sys/fs/cgroup/cgroup.controllers && cat /sys/fs/cgroup/cgroup.controllers`；若走 OpenRC 且没有 unified,编辑 `/etc/rc.conf` 设置 `rc_cgroup_mode="unified"`,然后 `rc-update add cgroups default` 并重启。
5. OpenRC 安装 Docker: `apk update && apk add docker docker-cli-compose iptables ip6tables`；然后 `rc-update add cgroups default`, `rc-update add docker default`, `service cgroups start`, `service docker start`。
6. 非 root 使用 Docker: `addgroup <用户名> docker`；注意这等价于给该用户宿主 root 权限,服务器环境建议只给可信运维用户。
7. 验证 Docker: `docker info`, `docker run --rm hello-world`, `docker run --rm --network bridge alpine:latest ip addr`,再测端口映射 `docker run --rm -p 8080:80 nginx:alpine`。
8. 如果 Docker 网络失败: 先看 `dmesg`, `lsmod | egrep 'overlay|veth|bridge|br_netfilter|nf_nat|ip_tables|iptable_nat|iptable_filter'`,尝试 `modprobe overlay veth bridge br_netfilter nf_nat iptable_nat iptable_filter`;再检查 nftables/iptables-legacy 切换。
9. 部署 Home Assistant: 建议先用官方或 LinuxServer 多架构 ARM64 镜像,数据目录放持久路径,典型命令为 `docker run -d --name homeassistant --restart unless-stopped --network host -v /srv/homeassistant:/config -e TZ=Asia/Shanghai ghcr.io/home-assistant/home-assistant:stable`。
10. 最终验收清单: WiFi 断电重启后自动连上,Docker daemon 自启动,`docker compose version` 正常,HA Web 8123 可访问,mDNS/UPnP 发现正常,24 小时温度/负载/网络无异常。

### 关键事实
- [high] postmarketOS v25.06 目标基底是 Alpine Linux 3.22,并正式加入 systemd；主流 UI 走 systemd,Sxmo 预构建镜像仍使用 OpenRC。
  - source: https://postmarketos.org/blog/2025/06/22/v25.06-release/
- [high] Alpine 官方 Docker 安装路径是 apk add docker, OpenRC 下 rc-update add docker default 和 service docker start；docker-cli-compose 是 Alpine 3.15 起的 Compose 包名。
  - source: https://wiki.alpinelinux.org/wiki/Docker
- [high] Alpine 官方文档明确 rootless Docker 需要 cgroups v2,编辑 /etc/rc.conf 设置 rc_cgroup_mode="unified",并 rc-update add cgroups default。
  - source: https://wiki.alpinelinux.org/wiki/Docker
- [high] postmarketOS 当前 kconfigcheck.toml 的 containers 类别要求 NAMESPACES、NET_NS、PID_NS、IPC_NS、UTS_NS、CGROUPS、CGROUP_CPUACCT、CGROUP_DEVICE、CGROUP_FREEZER、CGROUP_SCHED、CPUSETS、KEYS、VETH、BRIDGE、BRIDGE_NETFILTER、IP_NF_FILTER、IP_NF_TARGET_MASQUERADE 等为 true。
  - source: https://gitlab.com/postmarketOS/pmaports/-/raw/master/kconfigcheck.toml
- [medium] sm8250-mainline/pmos-pmaports 的 linux-postmarketos-qcom-sm8250 配置中 CONFIG_NAMESPACES=y、CONFIG_PID_NS=y、CONFIG_USER_NS=y、CONFIG_NET_NS=y、CONFIG_CGROUP_PIDS=y、CONFIG_MEMCG=y、CONFIG_OVERLAY_FS=m、CONFIG_VETH=m、CONFIG_NF_NAT=m、CONFIG_IP_NF_TARGET_MASQUERADE=m。
  - source: https://raw.githubusercontent.com/sm8250-mainline/pmos-pmaports/master/linux-postmarketos-qcom-sm8250/config-postmarketos-qcom-sm8250.aarch64
- [high] 同一份 sm8250-mainline 旧配置里 CONFIG_BRIDGE_NETFILTER is not set,这与当前 pmaports containers 类别要求存在差异,所以需要在实机上核对当前包的 /proc/config.gz。
  - source: 本次命令解析 raw.githubusercontent.com/sm8250-mainline/pmos-pmaports/master/linux-postmarketos-qcom-sm8250/config-postmarketos-qcom-sm8250.aarch64 与 https://gitlab.com/postmarketOS/pmaports/-/raw/master/kconfigcheck.toml
- [medium] OnePlus 8T(kebab) 的 postmarketOS 包依赖 linux-postmarketos-qcom-sm8250 和 OnePlus 固件；公开资料显示主线支持曾达到 GNOME shell、连接 WiFi、浏览网页和 GPU 加速。
  - source: https://pkgs.postmarketos.org/package/master/postmarketos/aarch64/device-oneplus-kebab ; https://wiki.postmarketos.org/wiki/OnePlus_8T_(oneplus-kebab) ; https://lwn.net/Articles/979482/
- [high] 容器内的 libc 由镜像自身提供,宿主 Alpine/musl 不会阻止运行 glibc 用户态镜像；Docker 文档将 glibc/musl 作为镜像内部兼容性选择来讨论。
  - source: https://docs.docker.com/dhi/core-concepts/glibc-musl/
- [medium] Home Assistant/相关容器在 ARM64 上有多架构镜像实践；HA 发现 mDNS/UPnP 设备通常需要 --net=host。
  - source: https://docs.linuxserver.io/images/docker-homeassistant/ ; https://www.home-assistant.io/installation/linux#install-home-assistant-container

### 风险
- WiFi 是你的硬性前提: kebab 主线资料显示 WiFi 可工作,但仍依赖具体 pmOS 构建、firmware-oneplus-instantnoodlep/board firmware、regdb 和 ath11k/qcom 固件加载；刷前要准备回滚镜像和刷后先验 WiFi。
- sm8250-mainline 旧配置存在 CONFIG_BRIDGE_NETFILTER 未启用,而 Docker bridge 网络、iptables/nftables、容器端口映射可能受影响；当前 pmaports 官方包可能已修,但必须实机核对。
- Docker 新版本对 iptables/raw/nftables 模块要求更严格,社区案例里出现过缺 IP_NF_RAW/IP6_NF_RAW 或需要 iptables-legacy 的情况。
- OpenRC 下 cgroup v2 是挂载/初始化问题,不只是内核 config；若 /sys/fs/cgroup/cgroup.controllers 不存在,需要调整 rc_cgroup_mode 或排查内核。
- Rootless Docker 比 rootful Docker 多 USER_NS、subuid/subgid、fuse-overlayfs、XDG_RUNTIME_DIR 等要求；服务器首跑建议 rootful Docker,稳定后再考虑 rootless。
- Home Assistant 用 --net=host 最省事,但这意味着容器网络隔离减少；手机作为 24x7 服务器需另做防火墙、自动更新、备份和温控/电池策略。

## 3. postmarketOS on OnePlus 8T oneplus-kebab headless WiFi server viability

### 摘要
结论：OnePlus 8T kebab 刷 pmOS 后做无显示器服务器有可行路径，但 WiFi 不是 kebab 设备页上的已验证项，属于“高概率可用、必须首启实测确认”的关键风险。kebab 设备页显示 Flashing、USB Networking、Screen、Touchscreen 为 Works，WiFi 与 Battery 仍标 Untested；但同平台 SM8250 页把 WiFi 标为 Works，姊妹机 OnePlus 8 instantnoodle 的 WiFi 也已 Works，且其硬件状态表明确 WiFi 是 qca6390、需要 ath11k firmware。首启 headless 最稳方案不是完全赌 WiFi，而是预配 SSH key + NetworkManager + WiFi profile，同时保留 USB Networking 作为兜底通道。屏幕对 headless 服务器不构成必要条件；kebab 设备页现在 Screen 是 Works，SM8250 平台 Display 是 Partial，reset GPIO quirk 更像显示初始化/面板恢复问题，不影响 SSH/WiFi 服务器用途。24x7 常插电方面，kebab 页 Battery/charging 仍 Untested；OnePlus 8 页显示 bq27411 电量上报准确、pm8150b charger 只能 5W、Warp 快充无驱动，所以服务器常插电建议按“能慢充和读电量但不一定能原生限充”设计，并在 pmOS 首启后检查 power_supply sysfs 是否有 charge_control_end_threshold 或设备特定充电开关。

### 步骤 / 建议
1. 在 Linux VM 或 WSL2 中安装最新版 pmbootstrap；官方推荐 Linux，Windows/WSL 非官方支持。
2. 初始化配置：`pmbootstrap init`，device 选 `oneplus-kebab`，UI 选 none/console 类 headless 方案，user/hostname 按需设置；不要启用 FDE。
3. 配置 SSH key 与基础包：`pmbootstrap config ssh_keys True`，`pmbootstrap config ssh_key_glob ~/.ssh/id_ed25519.pub`，`pmbootstrap config extra_packages "networkmanager openssh vim curl htop docker"`；若 extra_packages 覆盖已有值，先用 `pmbootstrap config extra_packages` 查看再合并。
4. 预置 WiFi：构建 rootfs 后进入目标 rootfs chroot 或挂载镜像，在 `/etc/NetworkManager/system-connections/home.nmconnection` 写入 SSID/PSK profile，权限设为 `600 root:root`，内容包含 `[connection] id=home type=wifi autoconnect=true`、`[wifi] ssid=你的SSID`、`[wifi-security] key-mgmt=wpa-psk psk=你的密码`、`[ipv4] method=auto`、`[ipv6] method=auto`。
5. 生成并刷机：`pmbootstrap install --password '<临时强密码>'`，手机进 fastboot 后执行 `pmbootstrap flasher flash_rootfs`，然后按 kebab wiki 要求执行 `pmbootstrap flasher flash_dtbo`；通常还需要按设备信息刷 kernel/vbmeta，具体以 `pmbootstrap flasher list_flavors` 和 deviceinfo 为准。
6. 首启后先从路由器 DHCP 租约找 IP；SSH 登录：`ssh <user>@<ip>`。若 WiFi 没起来，用 USB Networking 兜底，因为 kebab 页 USB Networking=Works。
7. 进系统后验证 WiFi：`ip link`、`nmcli dev`、`dmesg | grep -Ei 'ath11k|qca6390|wlan|firmware'`、`nmcli dev wifi list`、`ping -c 3 1.1.1.1`。若 wlan 不存在，优先查 ath11k/qca6390 firmware 是否缺失。
8. 验证 headless 无屏依赖：不接屏幕/熄屏状态重启，确认路由器拿到 DHCP、`ssh` 可进、`rc-service sshd status` 与 `rc-service networkmanager status` 正常；屏幕 quirk 不应阻塞该链路。
9. 验证充电与限充：`ls /sys/class/power_supply/`，逐个看 `type capacity status voltage_now current_now charge_control_end_threshold charge_control_start_threshold input_current_limit`；若有 `charge_control_end_threshold`，测试 `echo 80 | sudo tee .../charge_control_end_threshold`。
10. 若无标准限充接口，采用保守 24x7 策略：低功率 5V 充电器/智能插座周期供电、温度监控、容量 40-80% 区间用户态脚本轮询，或后续针对 pm8150b/qcom-battery 写设备特定限充服务。

### 关键事实
- [high] OnePlus 8T kebab 的 pmOS 设备页类别为 testing，Mainline=yes，kernel package 是 linux-postmarketos-qcom-sm8250，Flashing/USB Networking/Screen/Touchscreen 为 Works，WiFi 与 Battery 为 Untested。
  - source: postmarketOS Wiki OnePlus 8T (oneplus-kebab): https://wiki.postmarketos.org/wiki/OnePlus_8T_%28oneplus-kebab%29
- [high] 同平台 SM8250 的 postmarketOS SoC 页显示 WiFi=Works、Bluetooth=Works、GPU=Works、Display=Partial，并列出 OnePlus 8T oneplus-kebab 为 testing 设备。
  - source: postmarketOS Wiki Qualcomm Snapdragon 865/865+/870 (SM8250): https://wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_865/865%2B/870_%28SM8250%29
- [medium] 姊妹机 OnePlus 8 instantnoodle 设备页显示 WiFi=Works、Battery=Works，硬件表列 WiFi 为 qca6390 且需要 ath11k firmware；这支持 kebab WiFi 高概率可 bring-up，但不能替代 kebab 真机验证。
  - source: postmarketOS Wiki OnePlus 8 (oneplus-instantnoodle): https://wiki.postmarketos.org/wiki/OnePlus_8_%28oneplus-instantnoodle%29
- [high] pmbootstrap 可在 install 阶段把 SSH 公钥写入新镜像用户的 authorized_keys；配置项为 ssh_keys=True 与 ssh_key_glob。
  - source: pmbootstrap SSH Key Handling: https://docs.postmarketos.org/pmbootstrap/main/ssh-keys.html
- [high] pmbootstrap install 默认启用 SSH daemon，除非使用 --no-sshd；config 支持 device、extra_packages、hostname、ssh_keys、ssh_key_glob、ui、user 等 headless 相关配置。
  - source: pmbootstrap Usage: https://docs.postmarketos.org/pmbootstrap/main/usage.html
- [high] postmarketOS WiFi 文档建议使用 NetworkManager/nmcli 连接无线网络；示例为 nmcli device wifi connect "$SSID" password "$PASSWORD" ifname wlan0。
  - source: postmarketOS Wiki WiFi: https://wiki.postmarketos.org/wiki/Wifi
- [high] kebab 安装要直接 flash rootfs 到 super 动态分区，并在启动前 flash_dtbo；这与用户实测 super=sda15、dtbo_a=sde17 的目标机分区信息吻合。
  - source: postmarketOS Wiki OnePlus 8T Installation: https://wiki.postmarketos.org/wiki/OnePlus_8T_%28oneplus-kebab%29
- [medium] Linux/UPower 的通用限充能力依赖内核/驱动暴露 ChargeEndThreshold/charge_control_end_threshold；若 kebab 对应 power_supply 不暴露该接口，就只能走设备特定 sysfs、用户态轮询停充、降低充电电压/电流或物理供电策略。
  - source: UPower Device docs: https://upower.freedesktop.org/docs/Device.html ; postmarketOS user example: https://wiki.postmarketos.org/wiki/User%3AFlamingradian

### 风险
- 最大风险是 kebab 设备页 WiFi 仍为 Untested；同 SoC/姊妹机 Works 只能说明驱动栈成熟，不能保证 KB2000 国行固件组合首启即连。
- 无显示器全靠 WiFi 首启有失联风险；必须保留 USB Networking、fastboot、adb/备份 super.img 作为恢复路径。
- kebab Battery/charging 未在设备页验证；24x7 常插电可能没有标准限充接口，且 Warp Charge 没有现成驱动时大概率退化为 5W 慢充。
- 刷 rootfs 到 super 会覆盖 Android 动态分区，用户已接受清空 Android，但仍应先备份 super/boot/dtbo/vbmeta/persist/modem 等关键分区。
- Windows 不能官方运行 pmbootstrap；WSL 有人使用但官方不支持，最稳是 Linux VM/实体 Linux。
- 若启用 FDE，headless 首启会卡在解密输入；服务器 headless 方案不建议首刷启用 FDE，除非另配 unl0kr/USB 解锁流程。

## 4. Windows 11 上位机为 OnePlus 8T / oneplus-kebab 刷 postmarketOS 的可行性研究

### 摘要
结论：Windows 原生不能跑 pmbootstrap，WSL2 跑 pmbootstrap也不是官方支持路径；最稳的 Windows 方案是 WSL2/Ubuntu 只负责生成和导出镜像，刷写交给 Windows 原生 fastboot。pmbootstrap 官方当前安装文档对 WSL 的态度比旧 PyPI 说明宽松一些：有人跑通过，但仍不支持，官方建议 Linux 安装或虚拟机。WSL2 的 USB 直通可以通过 usbipd-win 做到，理论上能让 WSL 内 fastboot 看到设备，但 fastboot 重枚举、占用切换、驱动和权限都会让刷机链路更脆。oneplus-kebab 官方 Wiki 的关键问题不是刷不刷得上，而是 WiFi 标为 Untested；对你“WiFi 必须能用，当 24x7 服务器”的目标，这是目前的阻断风险。oneplus-kebab 安装还会直接覆盖 super 动态分区，刷前必须备份 super.img，并确认回滚路径。社区预编译镜像方面，本次只确认官方 BPO 目录存在、搜索未发现 oneplus-kebab，images.postmarketos.org/bpo 抓取被 robots.txt 阻止，所以不能断言有可直接 fastboot 刷的官方预编译包。建议先用 WSL 生成镜像和导出文件做非破坏性准备，同时寻找或自行验证 WiFi 驱动状态；没有 WiFi 实证前不要清空 Android。

### 步骤 / 建议
1. 结论优先：不要把 WSL2 里的 pmbootstrap + WSL fastboot 当主刷机路径；推荐路径是“真 Linux/VM 或 WSL2 只生成镜像 + Windows 原生 fastboot 刷写”，但在 WiFi Untested 未实测前先暂停破坏性刷机。
2. 在 Windows 11 安装 WSL2 Ubuntu：以管理员 PowerShell 运行 `wsl --install -d Ubuntu`，重启后运行 `wsl --update`，再进 Ubuntu 执行 `uname -a` 确认 WSL kernel 较新。
3. 在 WSL2 Ubuntu 安装依赖与 pmbootstrap（优先 git 版，不建议 pip/PyPI）：`sudo apt update && sudo apt install -y git python3 openssl sudo tar xz-utils android-sdk-platform-tools-common android-tools-adb android-tools-fastboot`，然后 `git clone --depth=1 https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git ~/pmbootstrap && mkdir -p ~/.local/bin && ln -sf ~/pmbootstrap/pmbootstrap.py ~/.local/bin/pmbootstrap && echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile && . ~/.profile && pmbootstrap --version`。
4. 运行初始化：`pmbootstrap init`；通道建议先选 `edge`，vendor 选 `oneplus`，device 选 `kebab`，architecture 应为 `aarch64`，UI 若当服务器可选 `none` 或最小 UI，用户/hostname/locale/timezone 按需填写。
5. 生成 rootfs：`pmbootstrap install --add openssh,docker`；如果只做服务器，先别加桌面环境，避免资源和图形栈变量。
6. 导出镜像到 Windows 可见路径，推荐显式导出：`mkdir -p /mnt/c/Users/22443/Downloads/pmos-kebab-export && pmbootstrap export /mnt/c/Users/22443/Downloads/pmos-kebab-export`；也可默认导出后从 Windows 访问 `\\wsl$\Ubuntu\tmp\postmarketOS-export\`。
7. 导出后在 WSL 里列出文件：`ls -lah /mnt/c/Users/22443/Downloads/pmos-kebab-export`；重点找 rootfs/super/root.img/dtbo.img/boot.img 等文件，实际文件名必须以导出目录为准。
8. 刷机前在 Android 仍可用时备份 super：`adb shell su -c 'dd if=/dev/block/by-name/super of=/sdcard/super.img bs=8M'`，再 `adb pull /sdcard/super.img D:/claude/workspace/一加8T-Hermes/backup-stock/super.img`；或者按 Wiki 用 `adb pull /dev/block/by-name/super super.img`，但你的设备需要 root 权限时用 su/dd 更稳。
9. 进入 bootloader：`adb reboot bootloader`；Windows 原生确认设备：`fastboot devices`，不要在 WSL 和 Windows 同时占用 USB。
10. 若用 Windows 原生 fastboot 刷 WSL 导出文件，思路是从 `C:\Users\22443\Downloads\pmos-kebab-export` 取文件，再执行与 Wiki 等价的刷写；pmbootstrap 自动 flasher 的等价目标是 rootfs 到 `super`，dtbo 到 `dtbo_a` 或当前槽位 dtbo 分区，但实际命令需先根据导出文件名和当前 slot 核对，例如 `fastboot getvar current-slot`、`fastboot flash super <rootfs-or-super-image>`、`fastboot flash dtbo_a <dtbo.img>`。
11. 如果坚持测试 WSL fastboot，先装 usbipd-win：管理员 PowerShell 运行 `winget install --interactive --exact dorssel.usbipd-win`，插入 bootloader 模式手机后 `usbipd list`、`usbipd bind --busid <BUSID>`、`usbipd attach --wsl --busid <BUSID>`，然后 WSL 中 `lsusb && fastboot devices`；从 ADB 切 fastboot 后若 BUSID 变化，需要重新 list/bind/attach。
12. 查预编译镜像的替代路径：手工打开 `https://images.postmarketos.org/bpo/edge/`、`https://images.postmarketos.org/bpo/v25.12/`、`https://images.postmarketos.org/bpo/v25.06/` 搜 `oneplus-kebab`；本次搜索未发现官方 oneplus-kebab 预编译目录，不能把“直接下载镜像 fastboot 刷”当可用方案。
13. 最终验收条件：刷前必须先找到至少一份同机型 oneplus-kebab 在 pmOS 下 WiFi 可用的近期实测证据，或准备 USB-C 有线网卡/以太网兜底；否则该设备不满足你的 24x7 WiFi 服务器目标。

### 关键事实
- [high] pmbootstrap 不支持 Windows 原生运行；官方安装文档明确说 pmbootstrap 运行在 Linux/POSIX shell + python3/openssl/git 环境，非 Linux OS 不受支持，建议使用 Linux 虚拟机。
  - source: https://docs.postmarketos.org/pmbootstrap/main/installation.html
- [high] WSL/WSL2 跑 pmbootstrap 属于非官方路径；官方文档说有人让 WSL 跑通过，但不受官方支持；PyPI 旧说明更保守，写着 WSL does not work 且 PyPI 安装已 deprecated/yanked。实际决策应按“不建议作为刷机主路径”处理。
  - source: https://docs.postmarketos.org/pmbootstrap/main/installation.html ; https://pypi.org/project/pmbootstrap/
- [high] WSL2 可以通过 usbipd-win 做 USB 直通；Microsoft 官方文档要求 Windows 11 Build 22000+、WSL2、较新 WSL kernel，并使用 usbipd list / bind / attach --wsl，附加期间设备不能被 Windows 使用。
  - source: https://learn.microsoft.com/windows/wsl/connect-usb ; https://devblogs.microsoft.com/commandline/connecting-usb-devices-to-wsl/
- [medium] WSL2 里让 fastboot 看到手机理论上可行，但不如 Windows 原生 fastboot 稳；Android 从 ADB 切到 bootloader/fastboot 后 USB 枚举身份可能变化，常需要重新 usbipd attach，且 WSL/pmbootstrap 本身非官方推荐。
  - source: https://learn.microsoft.com/windows/wsl/connect-usb ; https://www.xda-developers.com/wsl-connect-usb-devices-windows-11/
- [high] oneplus-kebab 的 postmarketOS Wiki 页面显示设备类别为 testing、架构 aarch64、主线方向 yes、Flash/USB Networking/Screen/Touchscreen 为 Works，但 WiFi 是 Untested，不满足“WiFi 必须能用”的硬性要求。
  - source: https://wiki.postmarketos.org/wiki/OnePlus_8T_%28oneplus-kebab%29
- [high] oneplus-kebab 使用 dynamic partitions；postmarketOS 当前安装说明要求把 rootfs 直接刷到 super 分区，并在启动前刷 dtbo，官方页面给出的命令是 pmbootstrap flasher flash_rootfs 和 pmbootstrap flasher flash_dtbo。
  - source: https://wiki.postmarketos.org/wiki/OnePlus_8T_%28oneplus-kebab%29
- [high] pmbootstrap 的标准生成流程是先 pmbootstrap init，再 pmbootstrap install；若要把镜像导出到本机文件而不是直接刷机，可运行 pmbootstrap export，默认导出目录是 /tmp/postmarketOS-export。
  - source: https://docs.postmarketos.org/pmbootstrap/main/usage.html
- [high] 在 WSL2 里生成镜像后，Windows 可通过 \\wsl$\Ubuntu\tmp\postmarketOS-export\ 或在 WSL 中复制到 /mnt/c/... 访问导出文件；pmbootstrap export 支持显式指定导出目录，因此可直接导出到 /mnt/c/Users/<用户名>/Downloads/pmos-kebab-export。
  - source: https://docs.postmarketos.org/pmbootstrap/main/usage.html
- [medium] 官方 BPO 预编译镜像目录存在，但搜索结果未发现 oneplus-kebab；可见 oneplus-enchilada/oneplus-fajita 等邻近机型，oneplus-kebab 更像需要通过 pmbootstrap 本地生成。fetch 对 images.postmarketos.org/bpo 被 robots.txt 拒绝，因此该结论以搜索结果和设备 Wiki 为依据。
  - source: https://images.postmarketos.org/bpo/ ; https://wiki.postmarketos.org/wiki/OnePlus_8T_%28oneplus-kebab%29

### 风险
- 最大风险：oneplus-kebab Wiki 标注 WiFi 为 Untested，而你的目标是 24x7 服务器且 WiFi 必须能用；在没有同机型实测 WiFi 证据前，不建议直接清空 Android。
- 刷 rootfs 会覆盖 super 分区；回 Android 需要提前备份 super.img，且可能还要恢复 boot/dtbo 或用 MSMDownloadTool/ROM 工具救回。
- 当前手机是 Android 15 / OxygenOS 15、KernelSU Next 第三方内核，而 Wiki 的 pmOS kernel 标注 4.19.110、页面属于 testing；固件/分区/slot 细节可能和页面记录不完全一致。
- WSL2 + usbipd-win 的 USB 直通链路在刷机时多一层变量；fastboot 重枚举、线材/驱动/权限问题都可能导致中途断连。
- 用 Windows 原生 fastboot 刷 WSL 导出的镜像可行性高，但需要确认导出的 rootfs/dtbo 文件名、是否 sparse、以及目标分区名完全匹配 deviceinfo；不能盲刷未知文件。
- 社区预编译镜像未确认存在；使用第三方非官方镜像会增加供应链和可恢复性风险。
