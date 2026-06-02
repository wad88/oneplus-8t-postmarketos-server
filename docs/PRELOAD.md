# PRELOAD.md · 一加 8T 自托管 agent 节点 · 到手即抓药清单

> 设备: OnePlus 8T (代号 kebab, 骁龙865, ARM64, 已 root)
> 目标架构: **全部 arm64 / aarch64**(不要下 amd64/x86_64)
> 拓扑: Android 宿主 → Ubuntu (LXC/chroot 容器) → 容器内 Docker
> 用户位置: 中国大陆。GitHub / ghcr.io / npm 在国内可能时通时断,**A 类务必趁手头机器网络好时提前全部下完并随身带(U盘/网盘/手机存储)**,避免到手现下被墙卡死。

---

## 阅读约定

- `releases/latest/download/<文件名>` 是 GitHub 的**稳定语义地址**: 永远重定向到该仓库最新 release 的对应资产,不用记具体版本号。如果某项目改了资产命名,去对应 `releases/latest` 页面核对一眼即可。
- 每项都标注【在哪一层用】: `安卓宿主` = ARM64 Android 原生层(ACC、内核刷写);`Ubuntu容器` = chroot/LXC 内的 Linux 用户态(cloudflared/zellij/Node/Docker 等)。
- 校验优先级: 官方 `*.sha256` / `checksums.txt` / `SHASUMS256.txt` > release 页面公布的哈希 > 自己留存下载时的哈希做二次比对。
- **A/B 槽位设备(8T 是 A/B 无独立 recovery 分区)**: recovery 内置在 boot 里,刷写逻辑和老的 A-only 不同,见 B 类说明。

---

# A 类 ·【设备无关 · 现在就能在任意联网机器/手机预取】

> 这些不依赖你手机的具体固件版本,**到手前全部备齐**。建议建一个目录树:
> `preload/host-arm64/`(安卓宿主用)、`preload/ubuntu-arm64/`(容器用)、`preload/docker-images/`(镜像 tar)、`preload/src/`(源码)。

### A1. cloudflared(Cloudflare Tunnel 客户端)
- **用途**: 内网穿透,把容器内服务(HA/ntfy/agent)安全暴露到公网,无需公网 IP。
- **下载 URL(arm64 .deb,优先)**:
  `https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb`
- **备用(裸二进制,免 apt,直接 chmod +x 跑)**:
  `https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64`
- **架构**: arm64
- **在哪一层用**: Ubuntu容器(也可直接安卓宿主跑,但建议进容器统一管理)
- **校验**: 同一 release 页面有逐文件 sha256;裸二进制可 `sha256sum cloudflared-linux-arm64` 后到 release 页面或 `cloudflared --version` 后比对。官方校验入口: cloudflared releases 页面每个资产旁的 digest / 随附 checksums。

### A2. zellij(终端复用器,替代 tmux,会话常驻)
- **用途**: 在容器里跑长任务(agent / aider / opencode)时保持会话不掉,断连可复连。
- **下载 URL**:
  `https://github.com/zellij-org/zellij/releases/latest/download/zellij-aarch64-unknown-linux-musl.tar.gz`
- **架构**: aarch64(musl 静态,**优先选 musl 版**,不依赖 glibc 版本,chroot/老容器更稳)
- **在哪一层用**: Ubuntu容器
- **校验**: zellij 每个 release 附 `*.sha256`,即同名加 `.sha256` 后缀:
  `https://github.com/zellij-org/zellij/releases/latest/download/zellij-aarch64-unknown-linux-musl.tar.gz.sha256`
  下载后 `sha256sum -c zellij-aarch64-unknown-linux-musl.tar.gz.sha256`(需保证两文件同目录)。

### A3. Node.js LTS(经 nvm 安装)
- **用途**: OpenCode / 部分 agent 工具链的运行时。
- **方式**: 不直接下 Node 二进制,**预取 nvm 安装脚本 + 对应 arm64 Node tarball**,断网也能装。
- **nvm 安装脚本(预存)**:
  `https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh`
  (到手后核对 nvm 最新 tag,把 `v0.40.1` 换成最新;raw 地址带 tag 才稳定,不要用 master)
- **Node LTS arm64 tarball(直接预下,nvm 离线安装用)**:
  `https://nodejs.org/dist/latest-lts/`(进目录选 `node-v<版本>-linux-arm64.tar.xz`)
  例: `https://nodejs.org/dist/v22.x.x/node-v22.x.x-linux-arm64.tar.xz`(到手前去 latest-lts 目录确认当前 LTS 版本号)
- **架构**: linux-arm64
- **在哪一层用**: Ubuntu容器
- **校验**: 每个 Node dist 目录有 `SHASUMS256.txt`(常有 GPG 签名 `.asc`):
  `https://nodejs.org/dist/v<版本>/SHASUMS256.txt`
  `grep node-v<版本>-linux-arm64.tar.xz SHASUMS256.txt | sha256sum -c -`
- **离线装 Node 提示**: nvm 支持把 tarball 放到 `~/.nvm/.cache/bin/node-v<版本>-linux-arm64/` 后 `nvm install <版本>` 走本地缓存;或直接解包加 PATH。

### A4. OpenCode(agent CLI)
- **用途**: 终端 agent。
- **方式**: 走 npm,**联网时机器上先 `npm pack` 把 tarball 拉下来**离线带走更稳。
- **包名**: `opencode-ai`
- **在线安装(到手有网时)**: `npm i -g opencode-ai`
- **离线预取(推荐)**: 在有网机器执行 `npm pack opencode-ai`,得到 `opencode-ai-<版本>.tgz`,带到设备后 `npm i -g ./opencode-ai-<版本>.tgz`。
- **架构**: 纯 JS(无原生编译则架构无关);如带原生依赖,需在 arm64 上联网补装,**故 A4 标"半离线",原生依赖部分可能仍需到手有网**。
- **在哪一层用**: Ubuntu容器(依赖 A3 Node)
- **校验**: npm 包自带 integrity(`npm install` 自动校验 lock 中的 `sha512`);手动 `npm view opencode-ai dist.integrity` 比对。

### A5. Aider(pipx 安装的 AI 结对编程 CLI)
- **用途**: 代码改写 agent。
- **方式**: 走 pipx/pip。**离线预取用 `pip download`**。
- **预取(有网机器,指定 arm64 平台)**:
  ```bash
  pip download aider-chat -d ./preload/src/aider-wheels \
    --platform manylinux2014_aarch64 --only-binary=:all: --python-version 3.11
  ```
  (Python 版本按容器内实际版本调整;部分纯源码依赖会下成 sdist)
- **在线安装(到手有网,最省事)**: `pipx install aider-chat`
- **架构**: arm64 wheels(原生依赖如 tree-sitter 等需 aarch64 轮子)
- **在哪一层用**: Ubuntu容器(需 Python3 + pipx)
- **校验**: PyPI wheel 自带哈希,`pip download` 会记录;`pip hash <wheel>` 可复算,与 PyPI 页面 / `pip install --require-hashes` 比对。

### A6. Docker Engine(容器内嵌套 Docker)
- **用途**: 在 Ubuntu 容器里再跑 Docker,承载 HA / ntfy 镜像。
- **方式(两选一)**:
  - **在线脚本(到手有网)**: `https://get.docker.com`(`curl -fsSL https://get.docker.com | sh`,自动识别 arm64)
  - **离线预取 .deb(推荐稳)**: 到 Docker 官方 apt 仓库下 arm64 包:
    `https://download.docker.com/linux/ubuntu/dists/<代号>/pool/stable/arm64/`
    需要的包: `containerd.io_*_arm64.deb`、`docker-ce_*_arm64.deb`、`docker-ce-cli_*_arm64.deb`、`docker-buildx-plugin_*_arm64.deb`、`docker-compose-plugin_*_arm64.deb`
    (`<代号>` 按容器 Ubuntu 版本,如 `jammy`/`noble`)
- **预存 get.docker.com 脚本本体**: `https://get.docker.com`(直接保存为 `get-docker.sh`,可离线审阅后跑)
- **架构**: arm64
- **在哪一层用**: Ubuntu容器(嵌套 Docker 需内核支持,见 B 类内核配置)
- **校验**: Docker apt 仓库有 `Release` + `Release.gpg` + `InRelease`(GPG 签名)和 `Packages` 内每包 SHA256;离线 .deb 用 `sha256sum` 对照 `Packages` 文件里的 `SHA256:` 字段。

### A7. ACC(Advanced Charging Controller,VR-25)
- **用途**: 充电控制 / 限充(电池长寿,8T 长期常驻供电场景必备)。
- **方式**: 官方在线安装脚本,**预存脚本 + 仓库 tar 离线带走**。
- **在线安装脚本(预存本体)**:
  `https://raw.githubusercontent.com/VR-25/acc/master/install-tarball.sh`
  (或官方 README 给的 `install-online.sh` 一行命令;到手前去 VR-25/acc 仓库 README 核对当前在线安装入口)
- **源码 tar 离线预取**:
  `https://github.com/VR-25/acc/archive/refs/heads/master.tar.gz`
  (或 `releases/latest` 若该项目发 release 包)
- **架构**: shell + 少量原生,跑在 **安卓宿主**(root 层,直接写 sysfs 充电节点)
- **在哪一层用**: **安卓宿主**(不是容器!ACC 要 root 访问 `/sys/class/power_supply` 等)
- **校验**: GitHub 仓库 tar 无官方 sha256,记录下载时哈希自校;脚本本体到手前人工通读一遍(防御式: 不盲跑)。
- **8T 专属注意(已确认事实)**: 8T 限充要用 OnePlus 专用节点 `mmi_charging_enable` / `oplus_chg`,**不要用 `input_suspend`**(有 wakelock 坑会导致设备无法休眠)。配置 ACC 的 charging switch 时指定 OnePlus 节点。

### A8. moby check-config.sh(内核配置自检脚本)
- **用途**: 验证自编译内核是否补齐了 Docker 所需的全部 namespace/cgroup/netfilter 选项。
- **下载 URL**:
  `https://raw.githubusercontent.com/moby/moby/master/contrib/check-config.sh`
- **架构**: 架构无关(shell)
- **在哪一层用**: Ubuntu容器(对着新内核跑,检查 `CONFIG_*`)
- **校验**: 单脚本,记录下载哈希;到手前通读。**这是验证 B 类内核成败的关键工具,务必预存。**
- **必须为 enabled 的关键项(已确认,8T 出厂缺 PID_NS)**:
  `CONFIG_PID_NS` `CONFIG_NET_NS` `CONFIG_USER_NS` `CONFIG_IPC_NS` `CONFIG_UTS_NS`
  `CONFIG_CGROUP_PIDS` `CONFIG_CGROUP_DEVICE`
  `CONFIG_NF_NAT` `CONFIG_NF_NAT_MASQUERADE` `CONFIG_NETFILTER_XT_MATCH_ADDRTYPE`
  (check-config.sh 会逐项标 ✓/✗)

### A9. Home Assistant Docker 镜像
- **用途**: 智能家居中枢服务。
- **镜像**: `ghcr.io/home-assistant/home-assistant:stable`
- **方式(国内 ghcr 易抽风,强烈建议离线 save/load)**:
  在有网机器(arm64,或用 `--platform linux/arm64`)拉取并打包:
  ```bash
  docker pull --platform linux/arm64 ghcr.io/home-assistant/home-assistant:stable
  docker save ghcr.io/home-assistant/home-assistant:stable \
    -o preload/docker-images/ha-stable-arm64.tar
  ```
  到设备后 `docker load -i ha-stable-arm64.tar`。
- **架构**: linux/arm64(`docker save` 时务必 `--platform linux/arm64`,否则在 amd64 机器上会存成 amd64 镜像)
- **在哪一层用**: Ubuntu容器内的 Docker
- **校验**: `docker pull` 自带 content digest 校验;`docker inspect --format '{{.Id}}'` 记录 image digest,跨机 load 后比对一致。

### A10. ntfy Docker 镜像(自建推送服务)
- **用途**: 监控告警推送(Telegram 国内被墙,**用自建 ntfy 替代**)。
- **镜像**: `binwiederhier/ntfy`(Docker Hub,建议指定具体 tag 如 `:latest` 或锁版本)
- **方式(同 HA,离线 save/load)**:
  ```bash
  docker pull --platform linux/arm64 binwiederhier/ntfy:latest
  docker save binwiederhier/ntfy:latest -o preload/docker-images/ntfy-arm64.tar
  ```
- **架构**: linux/arm64
- **在哪一层用**: Ubuntu容器内的 Docker
- **校验**: 同 A9,记录 image digest 比对。
- **配套(可选预取)**: ntfy 也有 arm64 裸二进制 release,若想宿主直跑:
  `https://github.com/binwiederhier/ntfy/releases/latest/download/`(进 releases 选 `ntfy_*_linux_arm64.tar.gz`,附 `checksums.txt`)

### A11.(可选)KonaBess(GPU 调频/降压工具)
- **用途**: 散热 / 降功耗(已确认 8T 实测可 905MHz@340mv 稳定)。
- **下载 URL**:
  `https://github.com/libxzr/KonaBess/releases/latest`(选 APK 资产)
- **架构**: arm64 Android APK
- **在哪一层用**: 安卓宿主(改 GPU 频率表,刷 boot/vendor_boot dtb,**有风险,谨慎**)
- **校验**: release 页面哈希;APK 可 `apksigner verify`。
- **注意**: 改 GPU 表属于 B 类边缘(依赖具体固件 dtb),**实际操作前确认与你固件匹配**,这里仅预下工具本体。

---

## A 类离线清单速查表

| 编号 | 名称 | 层 | 关键文件 |
|------|------|----|---------|
| A1 | cloudflared | 容器 | cloudflared-linux-arm64.deb |
| A2 | zellij | 容器 | zellij-aarch64-unknown-linux-musl.tar.gz(+.sha256) |
| A3 | Node LTS+nvm | 容器 | node-v*-linux-arm64.tar.xz + nvm install.sh + SHASUMS256.txt |
| A4 | OpenCode | 容器 | opencode-ai-*.tgz(npm pack) |
| A5 | Aider | 容器 | aider wheels(pip download arm64) |
| A6 | Docker Engine | 容器 | get-docker.sh 或 5 个 arm64 .deb |
| A7 | ACC | 宿主 | acc master.tar.gz + install 脚本 |
| A8 | check-config.sh | 容器 | check-config.sh |
| A9 | HA 镜像 | 容器Docker | ha-stable-arm64.tar |
| A10 | ntfy 镜像 | 容器Docker | ntfy-arm64.tar |
| A11 | KonaBess(可选) | 宿主 | KonaBess APK |

---

# B 类 ·【设备 + 版本特定 · 必须手机到手后才能定/下】

> **核心原因**: 这些产物绑定你手机**当前确切的 OxygenOS 版本、A/B 槽位状态、机器实际分区镜像**。版本不匹配轻则功能异常,**重则 bootloop / 变砖**。预下别人的或猜版本的镜像 = 自杀。

### 到手后必须先确认的 4 个信息(B 类全部依赖它们)
1. **OxygenOS 完整版本号**: 设置→关于手机→版本号(如 `KB2000_11_H.xx` / `kebab` 对应区域版本)。
   → 决定内核源码分支、stock boot.img 来源。
2. **当前激活 A/B 槽位**: `fastboot getvar current-slot`(或 `getprop ro.boot.slot_suffix`,返回 `_a`/`_b`)。
   → 8T 是 **A/B 设备,无独立 recovery 分区**,recovery 在 boot 内,刷写要认准当前 slot。
3. **boot.img 来源**: 必须是**与你当前固件完全同版本**的官方/可信完整刷机包(payload.bin)里抽取的 boot.img,**不能跨版本**。
4. **是否已解锁 Bootloader**: `fastboot oem device-info` / 设置里 OEM 解锁开关状态。

---

### B1. stock boot.img 备份(原厂 boot 镜像)
- **为什么不能预下**: boot.img 与固件版本一一绑定。刷错版本的 boot → 内核/ramdisk 与系统不匹配 → bootloop。**必须从你这台机当前固件提取或下载完全同版本完整包再抽取。**
- **到手后怎么拿**:
  - 法一(最可信): 找到与当前版本**完全一致**的官方完整刷机包(`OnePlus 8T Oxygen OS 完整 OTA zip`),用 `payload-dumper-go` 解 `payload.bin` 抽 `boot.img`。
  - 法二: 已 root 后 `dd if=/dev/block/by-name/boot_<slot> of=/sdcard/boot_stock.img`(直接备份当前在用的)。
- **风险**: 跨版本 boot → bootloop;抽错 slot → 备份的是空闲槽未必和运行槽一致。
- **必做**: 备份后**同时拷出设备多处保存**(电脑+网盘),这是 Magisk/自编译内核翻车后的救命底片。

### B2. super.img / 动态分区备份
- **为什么不能预下**: super 是动态分区集合(system/vendor/product/odm 等逻辑卷),体积大且**完全绑定你机器当前固件状态**。没有通用版本。
- **到手后怎么拿**:
  - 完整 super 备份(空间够才做): `dd if=/dev/block/by-name/super of=/sdcard/super_backup.img`(数 GB,需足够存储)。
  - 或仅备份关键逻辑卷,或保留好对应版本完整刷机包作为还原源(更省空间)。
- **风险**: 改 vendor/system 后无备份且无对应完整包 → 难以回滚。
- **建议**: 优先**保存好对应版本完整官方刷机包**(等价于 super 还原源),完整 dd super 仅在你要改逻辑卷且空间充裕时做。

### B3. 自编译容器内核(本项目核心难点)
- **为什么不能预下**: 8T 出厂内核**关闭了 PID_NS**,Docker 跑不起来,必须**以匹配你 OxygenOS 版本的内核源码分支为基底自编译**。别人编的内核基于别的固件 → 驱动/ABI 不匹配 → bootloop 或硬件失灵。
- **源码基底(已确认)**:
  `OnePlus OSS android_kernel_oneplus_sm8250` 仓库中**匹配你当前 OxygenOS 版本的分支**。
  仓库: `https://github.com/OnePlusOSS/android_kernel_oneplus_sm8250`(到手后按你的版本号选对应 branch/tag)
- **必补内核配置(用 A8 check-config.sh 验证)**:
  `CONFIG_PID_NS` `CONFIG_NET_NS` `CONFIG_USER_NS` `CONFIG_IPC_NS` `CONFIG_UTS_NS`
  `CONFIG_CGROUP_PIDS` `CONFIG_CGROUP_DEVICE`
  `CONFIG_NF_NAT` `CONFIG_NF_NAT_MASQUERADE` `CONFIG_NETFILTER_XT_MATCH_ADDRTYPE`
- **编译要点**: 需对应 GCC/Clang 工具链(AOSP prebuilt clang)、设备 defconfig(kebab/sm8250)、生成的内核打进 boot.img(或用 Magisk 的 boot patch 流程合并)。
- **风险**: 配置漏项 → Docker 仍报缺 namespace;ABI 不匹配 → 无法开机;**务必先 `fastboot boot`(临时引导,见下方 30 分钟清单第 4 步)验证,绝不直接 `fastboot flash boot` 覆盖!**
- **可提前做(不算预下,算预研)**: 现在就把内核源码仓库 clone 一份、AOSP clang 工具链下好、编译环境(Linux x86_64 编译机)备好,**唯独 defconfig/分支选择留到确认版本号后**。

### B4. TWRP / recovery(如需)
- **为什么不能预下/谨慎**: 8T 是 **A/B 无独立 recovery 分区**设备,TWRP 以 `boot`/`recovery-in-boot` 形式临时引导,且**强依赖具体设备代号(kebab)和固件版本**。错版本 TWRP 不识别加密分区或无法挂载。
- **到手后怎么拿**: 确认版本后,从 TWRP 官方 kebab 页面或可信社区(XDA OnePlus 8T)取**对应代号 kebab 的镜像**,优先 `fastboot boot twrp.img` 临时引导,**不轻易 flash**。
- **是否必需**: 若你的备份/刷写流程靠 `fastboot boot 自编译kernel` + `dd 备份` + Magisk 即可完成,**TWRP 非必需**,可跳过以降风险。仅当需要图形化分区操作/线刷救砖辅助时才上。
- **风险**: 错版本 recovery → 无法解密 → 误以为变砖;在 A/B 设备上误 flash 到错 slot。

---

# 「手机到手后前 30 分钟」有序操作清单

> 原则: **先备份,再验证(临时引导),最后才落盘**。每一步 OK 再下一步,任一步异常立刻停。

```text
0. 准备(已备齐 A 类离线包 + 编译机就绪)
   - 电脑装好 platform-tools(adb/fastboot,arm64 设备也是用电脑端 x86 工具)
   - USB 数据线确认能传数据(不是只充电)
   - 电量充到 ≥60%

1. 开发者选项 + USB 调试 + OEM 解锁开关
   - 设置→关于→连点版本号开启开发者选项
   - 开发者选项: 打开「USB 调试」「OEM 解锁(允许解锁 Bootloader)」
   - 记录 OxygenOS 完整版本号(B 类全部依赖)→ 写进 当前任务状态.md

2. 确认槽位 + 设备信息(写下来)
   adb reboot bootloader
   fastboot getvar current-slot        # 记录 _a / _b
   fastboot oem device-info            # 看是否已解锁
   ⚠ 此处仅读取,不写入

3. 解锁 Bootloader(⚠ 会清空数据,务必在空机/已备份个人数据时做)
   fastboot oem unlock                 # 或 fastboot flashing unlock,按提示音量键确认
   - 解锁后设备自动 wipe + 重启,重新过开机引导、再开一次 USB 调试

4. 备份 stock boot(救命底片,B1)—— 重启回系统、获取 root 后
   - 完成 Magisk patch boot 获取 root(用对应版本完整包里的 boot.img → Magisk 修补 → fastboot boot 临时引导验证 → 确认 OK 再 flash)
   - root 后:
     dd if=/dev/block/by-name/boot_<当前slot> of=/sdcard/boot_stock.img
   - 立刻拷到电脑 + 网盘,sha256sum 记录

5. (可选)备份 super / 保存对应版本完整刷机包(B2)
   - 空间够: dd if=/dev/block/by-name/super of=/sdcard/super_backup.img
   - 空间紧: 仅确保已存好与当前版本完全一致的官方完整 OTA 包

6. 临时验证自编译内核(B3)—— 绝不直接 flash!
   fastboot boot boot_with_custom_kernel.img    # 临时引导,重启即失效
   - 进系统后验证:
     adb shell uname -a                          # 确认是新内核
     adb shell zcat /proc/config.gz | grep -E 'PID_NS|NET_NS|USER_NS|CGROUP_PIDS'
     # 或把 A8 check-config.sh 推进去跑
   - 全 ✓ 且系统稳定 → 才进入第 7 步;有 ✗ 或开不了机 → 设备会因临时引导自动恢复 stock,回去改内核配置重编

7. 确认无误后落盘(此时已有 B1 备份兜底)
   fastboot flash boot boot_with_custom_kernel.img   # 写入当前 slot
   - 重启,再次 uname -a / check-config.sh 复验

8. 进系统,搭安卓宿主层
   - 安装 ACC(A7),配置 8T 专用充电节点(mmi_charging_enable / oplus_chg,⚠ 不用 input_suspend)
   - (可选)KonaBess 降压(905MHz@340mv 实测值,谨慎)

9. 进容器层(Ubuntu chroot/LXC),离线装 A 类
   - cloudflared(A1) / zellij(A2) / Node+nvm(A3) / OpenCode(A4) / Aider(A5)
   - Docker Engine(A6)→ 容器内启 dockerd
     docker info        # 确认 Storage Driver / cgroup 正常,无 namespace 报错

10. 起服务镜像
    docker load -i ha-stable-arm64.tar && 起 HA(A9)
    docker load -i ntfy-arm64.tar && 起 ntfy(A10)
    - cloudflared tunnel 把 HA/ntfy 暴露;Tailscale 装好做内网直连兜底

11. 监控闭环
    - 周期脚本(set -euo pipefail / 幂等 / 防御式)采集温度/电量/服务存活 → 推自建 ntfy
    - 不依赖 Telegram(国内墙)

12. 收尾
    - 更新 D:\claude\workspace\当前任务状态.md(版本号/槽位/已落盘内核/各服务端口)
    - 脱敏结论写 D:\AI\文件记忆(tunnel token / tailscale key / ntfy 凭据一律 redact)
```

---

## 红线提醒(防变砖)

- **任何 boot/recovery/kernel 都先 `fastboot boot`(临时)验证,确认进系统且功能正常,再 `fastboot flash`(永久)。**
- **B1 stock boot 备份没拷到电脑之前,不碰任何 flash 操作。**
- **跨版本镜像 = bootloop**: 自编译内核分支、boot.img、TWRP 都必须匹配你当前 OxygenOS 版本号。
- **A/B 槽位认准**: flash 前 `fastboot getvar current-slot`,别写错槽。
- **8T 充电节点**: ACC 用 `mmi_charging_enable`/`oplus_chg`,**禁用 input_suspend**(wakelock 坑)。
- 所有脚本统一: `set -euo pipefail`、幂等、中文注释、防御式;敏感凭据不入报告/记忆明文。
