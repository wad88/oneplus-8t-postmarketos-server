# OnePlus 8T → postmarketOS 自托管服务器

把一台退役的 **一加 8T（KB2000，代号 kebab，骁龙 865 / SM8250，12+256G）** 刷成
**postmarketOS（纯 mainline Linux，不是 Android）**，做成 24×7 的 ARM Linux 自托管服务器：
Docker + Home Assistant + 自建推送 + 监控告警 + 双向 Telegram agent。

> ⚠️ **这是个人项目记录，设备特定。** 所有刷机操作有变砖风险，分区 UUID / 序列号 / DT 细节都是
> 本机特有的。照做请先理解原理、备份原厂镜像、并自行适配你的设备。本仓库价值在**方法论和踩坑记录**，
> 不是开箱即用的一键脚本。完整攻坚日志见 **[docs/JOURNEY.md](docs/JOURNEY.md)**。

## 最终达成

- ✅ postmarketOS edge 在 SM8250 上**完全 boot**（Linux 6.16 SMP aarch64，8 核全在线，12G 内存全识别，真磁盘 rootfs）
- ✅ 冷启动自动进系统（boot.img 已落盘，不依赖 fastboot boot）
- ✅ **Docker 底座可用**（cgroup v2 + overlayfs + namespaces 齐全，无需自编内核）
- ✅ 开机自启链（NetworkManager + docker + ntpd 全自动起）
- ✅ 服务栈：Home Assistant + ntfy（`restart: unless-stopped`）
- ✅ 监控：异常告警（容器挂/磁盘/温度/内存超阈值才推 Telegram，带去抖）
- ✅ **双向 Telegram agent**（手机发指令 → 设备执行运维/shell/AI → 回复）

## 两个诚实的硬限制（本机硬件 / 当前内核不可行）

- ❌ **WiFi 独立**：qca6390 走不通。本机 pm8009 这颗 PMIC 已坏（SPMI 无响应），
  断了 qca6390 的正确上电路径，两条 DT binding 都证伪（详见 JOURNEY 第 8a 节）。
  **出路 = USB-C 有线网卡**（usbnet 已 working）。
- ❌ **屏幕动态显示**：SM8250 走 DRM/MSM，屏幕只在 boot 早期刷一次，之后 fb0/tty 写入不上屏。
  无头服务器屏幕定格在开机画面是正常现象。

## 架构

```
一加8T (postmarketOS edge, mainline 6.16, OpenRC)
├── Docker (cgroup v2 + overlayfs, 数据放 224G userdata 分区)
│   ├── homeassistant (host 网络, 8123)
│   ├── ntfy          (自建推送, 8080)
│   └── ...你的服务
├── hermes-alert.sh   (crontab 异常告警 → Telegram)
├── hermes-agent.py   (双向 TG agent, 纯标准库 urllib, 可接大模型)
└── 联网: USB-C 有线网卡 / 上游代理
```

## 目录结构

```
.
├── docs/
│   ├── JOURNEY.md              ★ 完整攻坚踩坑记录（从砖头到服务器，所有弯路+根因）
│   ├── flash-runbook.md        刷机流程
│   ├── ops-runbook.md          长期运维手册
│   ├── docker-hardening.md     docker 加固 + OOM/磁盘防护
│   ├── 落地指南.md             刷机到 agent 安家全流程
│   ├── PRELOAD.md              离线预取资产
│   ├── pmos-专项核验恢复.md     pmOS 核验/恢复
│   ├── 固件基线修复方案.md      固件基线
│   └── DDR降级方案-决定版.md    DDR 处理
├── scripts/
│   ├── hermes-agent.py         双向 Telegram agent（核心）
│   ├── hermes-alert.sh         异常告警
│   ├── hermes-status.sh        状态卡片生成
│   ├── hermes.env.example      配置模板（token/chat_id/AI 后端）
│   ├── deploy-stack.sh         服务栈部署
│   ├── acc-charge-limit.sh     限充
│   ├── setup-remote-access.sh  tailscale + cloudflared 远程访问
│   ├── rollback-to-android.sh  回退安卓
│   └── ...
└── compose/
    └── docker-compose.yml      HA + ntfy + 限额 + 日志轮转
```

## 快速开始（已在 pmOS 系统内）

```bash
# 1. 装 Docker
apk add docker docker-cli-compose
rc-update add cgroups boot
rc-update add networkmanager default
rc-update add docker default          # 注意与 NM 同 runlevel

# 2. 起服务栈
cp compose/docker-compose.yml /opt/hermes/
cd /opt/hermes && docker compose up -d

# 3. 配 Hermes agent
cp scripts/hermes.env.example /etc/hermes-status.conf
vi /etc/hermes-status.conf            # 填 TG_TOKEN / TG_CHAT_ID / AI_BASE / AI_KEY
cp scripts/hermes-agent.py /usr/local/bin/
# 配 OpenRC 服务自启 hermes-agent

# 4. 异常告警
cp scripts/hermes-alert.sh /usr/local/bin/
crontab -e   # */5 * * * * /usr/local/bin/hermes-alert.sh
```

## 配置

`hermes.env.example` → `/etc/hermes-status.conf`：

```ini
TG_TOKEN="<你的 Telegram bot token>"
TG_CHAT_ID="<你的 chat id>"        # agent 只响应这个 chat
AI_BASE="https://your-newapi.example.com"   # 可选, 接大模型
AI_KEY="<你的 API key>"
AI_MODEL="gpt-4o-mini"
```

## License

MIT — 见 [LICENSE](LICENSE)。
