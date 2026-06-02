# 一加8T kebab 降固件方案（DDR/ARB/MSM 决定版）2026-06-01

## 三个关键结论（多 agent 一致 + 对抗核验）

### 1. 重要前提纠正：你现在的"OOS15/Android15"几乎一定不是官方系统
- **一加8T 官方最高就是 OxygenOS 14（A14，末版 14.0.0.603），从来没有官方 OOS15。**
- 真机指纹是 `KB2000_15.0.1.402(CN01)` + KernelSU Next + 一堆模块 → 这是**第三方 ROM（LineageOS22/23 或 crDroid11 之类 Android 15）**。
- 这反而对降级**有利**：不涉及官方 ARB 顾虑。

### 2. ARB 防回滚：对 8T 基本无风险（低）
- 会永久烧 efuse、EDL 都救不回的硬件 ARB，只命中 OnePlus 11/12/13/13T/15 等新机的 ColorOS16/A16（2026年初）。
- **8T(骁龙865, 2020机型)从 OOS11→14 历史上从未做过 ARB bump**，社区大量成功降级案例。降级安全。

### 3. DDR 类型：唯一真正的硬砖风险，必须设备实测，禁止猜
- 8T 是**双 DDR 机型**：LPDDR4X(type0→xbl.img) 和 LPDDR5(type1→xbl_lp5.img) 两种批次共用 KB2000 型号。
- 大致 2021年3月前=LPDDR4X，之后=LPDDR5，但**这只是弱指标，绝不能据此刷 XBL**。
- 刷错 XBL = 错误电压打物理内存 = 永久黑砖(Qualcomm Crashdump)。PBL 共用签名不会拦截错刷。
- **fastboot 读不出 DDR 类型**（无该变量，已实测确认）。
- 读法：能进 Android/recovery 时 `getprop ro.boot.ddr_type`(0/1) 或 root `cat /proc/devinfo/ddr_type`(DDR4/DDR5)。

## 最安全执行路径（强烈推荐：MSM 一键，绕开手动刷 XBL）

研究一致结论：**手动 fastboot 刷 XBL 是新手砖机主因；MSM Download Tool(EDL 9008) 会按机器自动刷正确 XBL，从根上绕开 DDR 猜测**。

### 路径 B（推荐）：MsmDownloadTool 9008 一键回 OOS11 官方底座
- 工具就在 8T 救砖 zip 包里（含 MsmDownloadTool V4.0.exe），按区域选包：
  - KB05AA=国际 / KB05BA=欧洲 / KB05DA=印度（KB2000 国行→可用国际/对应区，**不要跨区乱刷**）
- 它把整机低层重刷回 Android 11 官方底座，A/B 双槽都刷，**自动匹配 XBL**，零 DDR 猜测。
- 前置：Win 装 Qualcomm HS-USB QDLoader 9008 驱动(Win11 用 2014版高通驱动)，USB2.0/3.0 蓝口，关机→工具选 Others/Target→Start→按住音量上+下插线进 9008。
- 回到 OOS11 后，firmware 基线就是 mainline pmOS 要的 Android 11/13/14 era，再重刷 pmOS 大概率能起。

### 路径 A（次选，能进 fastboot 时，但要先实测 DDR）：fastboot 刷官方 OOS13/14 ROM
- 必须先实测 DDR 类型，按类型只刷对应 xbl/xbl_lp5。
- 风险高于 MSM，因为要手动选 XBL。

## 当前设备状态与下一步建议
- 设备能进 fastboot（START），未变砖。
- pmOS 之前能启动到早期 boot（屏显 PMIC 错误），但**没有完整 userspace 能读 SMEM DDR**，所以从 pmOS 读 DDR 不现实。
- 最干净：直接走 MSM 9008 回官方底座（不需要知道 DDR，工具自动处理），这是用户"能刷安卓系统"最稳的方式。
- 需要用户提供/下载：对应区域的 8T MSM 救砖包（含 OOS11 官方底座 + MsmDownloadTool）。

## 兜底
- backup-stock/super.img + boot_a-KSU_NEXT.img（当前第三方 A15 ROM 的，已校验）
- MSM 9008 本身就是终极兜底
