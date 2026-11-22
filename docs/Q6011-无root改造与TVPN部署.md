# 创维 Q6011（eros-p1）无 root 改造与 TVPN 部署记录

> 设备专用文档，包含设备标识与厂商签名算法，**请勿外传**。
> 记录日期：2026-11-07
> 设备：Skyworth Q6011 / eros-p1 / Android 10
>
> 主线总览已合并到 [TVPN-科学上网客户端开发与影音适配.md](TVPN-科学上网客户端开发与影音适配.md)；本文继续保留完整设备取证、反汇编与脚本细节。
> 本地 root 通道（厂商内置 su `usrchan`）的实测与算法见合并版 **§4.8**。

---

## 目录

1. [背景与目标](#1-背景与目标)
2. [软硬件环境与工具链](#2-软硬件环境与工具链)
3. [权限模型与无 root 边界](#3-权限模型与无-root-边界)
4. [预装/广告包治理](#4-预装广告包治理)
5. [极光免费专区 90–120s 前贴片广告分析](#5-极光免费专区-90120s-前贴片广告分析)
6. [后台保活：厂商 SkyworthConfig 白名单逆向](#6-后台保活厂商-skyworthconfig-白名单逆向)
7. [TVPN：从 carvpn 派生](#7-tvpn从-carvpn-派生)
8. [VPN 运行与节点选择](#8-vpn-运行与节点选择)
9. [完整复现步骤](#9-完整复现步骤)
10. [遗留问题与后续方向](#10-遗留问题与后续方向)
11. [附录：脚本与证据](#11-附录脚本与证据)
12. [2026-11-08 阶段性结论](#12-2026-11-08-阶段性结论)
13. [Instagram Lite 横屏适配与登录问题](#13-instagram-lite-横屏适配与登录问题2026-11-09)
14. [TVPN / CarVPN 工程统一](#14-tvpn--carvpn-工程统一方案-a2026-11-09)

---

## 1. 背景与目标

### 1.1 设备定位

这是一台 1GB 内存的入门级智能电视（网络盒子形态），系统为厂商深度定制的 Android 10：

| 项目 | 值 |
|---|---|
| 型号 | Q6011 |
| 内部代号 | eros-p1 |
| Android 版本 | 10（SDK 29） |
| CPU ABI | `armeabi-v7a`（仅 32 位） |
| 内存 | 979 MB，MemAvailable 约 330–350 MB |
| 分辨率 | 1920×1080 |
| 系统启动器 | 腾讯极光 `com.ktcp.launcher`（UPDATED_SYSTEM_APP，v17.7.0.10070） |
| 设备序列号 | `0332493700221160007899` |
| WiFi ADB | `192.168.3.156:5555` |

### 1.2 初始目标（内存/自启优化）

- 在**保留开机能力**的前提下禁用无风险预装；
- 屏蔽开机广告、统计上报；
- 降低开机自启占用的内存。

### 1.3 目标演进

1. 发现无 root 路径后，用 Binder 直连禁用整包；
2. 用户要求暂缓内存优化（A/B 档清单已给出，未执行）；
3. 新需求：去掉「云视听小电视 / 极光免费专区」播放前的 **90–120 秒前贴片广告**；
4. 实测结论：**无 root 无法可靠去除**（见第 5 章）；
5. 最终需求：卸载 sing-box，基于自研 carvpn 做 TV 版 VPN，让 YouTube 可播放。

---

## 2. 软硬件环境与工具链

### 2.1 TV 侧关键属性

```text
ro.build.version.sdk = 29
ro.product.cpu.abilist = armeabi-v7a,armeabi
ro.product.model = Q6011
```

### 2.2 PC 侧工具

| 工具 | 路径 |
|---|---|
| adb / fastboot | `D:\AndroidDev\android-sdk\platform-tools\adb.exe` |
| build-tools 34 | `D:\AndroidDev\android-sdk\build-tools\34.0.0` |
| JDK 17 | `D:\AndroidDev\jdk17` |
| Gradle 8.9 | `D:\AndroidDev\gradle-8.9` |
| NDK 26.3.11579264 | `D:\AndroidDev\android-sdk\ndk\26.3.11579264` |
| jadx | `D:\AndroidDev\tools\jadx\bin\jadx.bat` |
| apktool | `D:\AndroidDev\tools\apktool\apktool.bat` |
| dexdump | `D:\AndroidDev\android-sdk\build-tools\34.0.0\dexdump.exe` |
| Python + Pillow | 系统 Python 3（Pillow 13） |
| 抓包代理 | 自写 Python CONNECT 日志代理（见附录 D） |

### 2.3 ADB 通道

- USB 与 WiFi 双通道均可用；
- WiFi ADB 已持久化：

```bash
adb shell setprop persist.adb.tcp.port 5555
```

- 重启后 WiFi transport 可能变为 offline，USB 通道仍然可用。

---

## 3. 权限模型与无 root 边界

### 3.1 root 不可行

- 无 `su`、无 Magisk；
- `/system` 为只读 dm-verity 分区；
- 厂商改写了 `restart_root_service`，`adb root` 走不通。

> **2026-11-10 修订**：`adb root` 仍不可用，但已发现厂商内置 su `/system/xbin/usrchan`，可获得 adb shell 级 root，详见第 16 章。

### 3.2 厂商对 shell 的拦截

`services.jar` 的 `PackageManagerShellCommand` 中直接判断调用者 uid：

```java
if (Binder.getCallingUid() == 2000) {
    pw.println("Error: User no Permission !");
    return;
}
```

因此：

```text
pm disable-user <pkg>   -> Error: User no Permission !
pm suspend <pkg>        -> Error: User no Permission !
pm hide <pkg>           -> Error: User no Permission !
pm uninstall --user 0   -> Error: Unknown option: --user
pm uninstall <pkg>      -> 对 /data 第三方包有效；系统包 DELETE_FAILED_INTERNAL_ERROR
```

### 3.3 绕过：直接调用 PackageManager Binder

拦截只发生在 shell command 层；PMS 的权限检查仍按 uid 进行，而 shell 的 `CHANGE_COMPONENT_ENABLED_STATE` 是 granted 的。于是直接走 Binder 事务：

**禁用整包（事务 95，setApplicationEnabledSetting）**

```bash
adb shell service call package 95 s16 <包名> i32 3 i32 0 i32 0 s16 com.android.shell
```

**恢复整包**

```bash
adb shell service call package 95 s16 <包名> i32 1 i32 0 i32 0 s16 com.android.shell
```

参数含义（实测可用）：

| 位置 | 类型 | 值 |
|---|---|---|
| 1 | `s16` | 包名 |
| 2 | `i32` | state：3=禁用，1=启用，0=默认 |
| 3 | `i32` | flags：0 |
| 4 | `i32` | userId：0 |
| 5 | `s16` | callingPackage：`com.android.shell` |

**组件级禁用（事务 93）**

尝试过（当时记录的 parcel 形式）：

```text
service call package 93 i32 1 s16 <pkg> s16 <full.class> i32 <state> i32 0 i32 0
```

但系统包会被 AOSP 规则拒绝（`Shell cannot change component state for ...`），只有第三方包可用。
（该事务参数未能对系统包生效，仅作记录，未作为最终方案。）

### 3.4 `settings` 命令损坏

设备上的 `settings` 可执行文件调用会直接 `error: closed`，必须改用 `cmd settings`：

```bash
adb shell cmd settings get global private_dns_mode
adb shell cmd settings put global http_proxy 192.168.3.121:8888
```

### 3.5 边界结论

| 能力 | 无 root 可行性 |
|---|---|
| 禁用/启用第三方 App | ✅ `service call package 95` / `pm uninstall` |
| 禁用/启用系统 App 整包 | ✅ `service call package 95` |
| 改系统 App 单个组件 | ❌ 被 AOSP 拒绝 |
| 改 hosts / 系统文件 | ❌ 只读分区 |
| 替换 adbd / 提权 | ❌ 厂商已改 |
| 修改其他 App 私有数据 | ❌ 无 root、非 debuggable |
| 安装 VpnService 应用 | ✅ 普通 APK 即可 |

---

## 4. 预装/广告包治理

### 4.1 已禁用清单（首轮）

| 包名 | 作用 |
|---|---|
| `com.tianci.ad` | 开机/系统广告 |
| `com.skyworthdigital.ott.advert.app` | 广告投放下发；**兼管应用启动管线，不能整包禁用**（见下方注） |

> **2026-11-10 修订**：`ott.advert.app` 收到 `ACTION_APP_OPEN` 后会先 `force-stop` 目标应用、播 15 秒启动广告、再拉起目标。整包 `disable/suspend` 会让广告放不出来、目标应用也永远拉不起来，表现为桌面点任何应用都弹“应用无法使用 / 该应用是由root所管理”（系统 `SuspendedAppActivity`）。正确做法是保持包可用，只禁用 `com.skyworthdigital.ott.advert.app/.broadcast.AdvertBroadcastReceiver`。
>
> 注意它**不是启动器**：应用启动仍走原生 `startActivity → ActivityTaskManagerService → zygote` 路径，桌面只是普通 App；厂商在 `services.jar` 里加了 `com.android.usagestatus.action.start` 广播（已确认 `services.jar` 同时含该 action 与广告包名，`launcher.apk` 则不含），广告包只是接住广播做“杀进程→播广告→再拉起”的劫持。详见合并版《TVPN-科学上网客户端开发与影音适配》§4.9「事故与修订」「机制说明」。
| `com.skyworthdigital.ottstatsv2` | 统计上报 |
| `com.skyworthdigital.logcollector` | 日志采集 |
| `com.skyworthdigital.autotest` | 工厂自测 |
| `com.android.noticewidget` | 通知挂件 |
| `com.skyworthdigital.ott.guide` | 引导 |
| `com.skyworthdigital.skycommonpropertymanager` | 属性/黑白名单管理，会在开机后把广告包重新置为 enabled |

另已卸载：

```text
com.hezi.remoteinstaller
```

广告相关系统属性：

```bash
adb shell setprop persist.sys.coocaa.ad.stand no
adb shell setprop persist.sys.coocaa.ad.switch notshow
adb shell setprop persist.sys.bootvideo.enable false
```

### 4.2 反弹问题（重要）

后续实测发现：系统会把除 `com.tianci.ad` 之外的上述包**重新启用**。2026-11-07 23:14 复查时只有 4 个仍是禁用状态（`tianci.ad`、`autotest`、`noticewidget`、`ott.guide`），`advert.app`、`ottstatsv2`、`logcollector`、`skycommonpropertymanager` 已被恢复为 `enabled=1`。设备当时**没有重启**（uptime 约 1h43m），说明是运行中被重新启用的。

进一步排查：

- `com.skyworthdigital.ottstatsv2` 以 `persistent=true` 常驻（pid 2991），内部有 `CheckManager` 上报逻辑（打印 `getTopActivity` / `aLaunchCount` / `report isnewtime`）；
- `com.skyworthdigital.skycommonpropertymanager` 的 dex 里包含广告包名和 `setApplicationEnabledSetting` 调用；
- 处理顺序改为：先 `am force-stop` + 禁用 `skycommonpropertymanager`，再禁用其余包。

复查结果：8 个包全部 `enabled=3`，60 秒后无反弹。

> 注意：`ottstatsv2` 是 persistent 应用，`am force-stop` 无法结束其进程，**必须重启**才会彻底消失。重启后需再复查一次，确认厂商是否会在开机阶段重新拉起。

需要时重新执行 4.1 的禁用命令即可。

### 4.3 脚本

见附录 B。

---

## 5. 极光免费专区 90–120s 前贴片广告分析

### 5.1 现象

- 免费专区部分视频有前贴片，部分没有；
- 广告时长 60–120 秒（实测为 **2 条 60 秒创意拼接**，倒计时出现 121s/118s/113s/103s）；
- 右上角只有「按 ⓘ 键开通 SVIP 关闭该广告」，**没有跳过按钮**；
- 返回键只能退出全屏，不能跳过广告。

### 5.2 抓包方法

由于无 root，无法 tcpdump。利用 Android 全局 HTTP 代理 + 自写 CONNECT 日志代理：

```bash
adb shell cmd settings put global http_proxy 192.168.3.121:8888
```

代理记录所有 `CONNECT host:port` 与明文 HTTP 请求，并可对指定 host 返回 403 做「黑洞」实验。

> 注意：实验结束后必须清除：
> ```bash
> adb shell cmd settings put global http_proxy :0
> ```

### 5.3 广告链路（实测）

| 环节 | 域名 |
|---|---|
| 广告决策 | `trpc.kt_st_advertisement.tv_ads_access.tv_ads_access/GetAdsInfo`（路径来自 APK；实际 host 与正片 API 相同，为 `tv.t002.ottcn.com`，属推断） |
| 广告素材 | `xsgdt.play.t002.ottcn.com`、`pgdt.gtimg.cn`、`ugc*.gtimg.com` |
| 程序化 SSP | `v2.reachmax.cn`、`dm.reachmax.cn`、`sdk.youpintechs.com`、`*.mathpool.cn`、`volsj.open.adsaide.cn` |
| 第三方监测 | `*.miaozhen.com`、`t.in-neo.cn`、`h.trace.qq.com` |
| 酷开广告监测 | `39.102.55.136`（明文 HTTP，参数含 `appver=...COOCAA_TVAPP`、`cx_plan`、`adtotal=3`） |
| 正片 API | `tv.t002.ottcn.com`、`vv.play.t002.ottcn.com` |
| 正片 CDN | `ugc*.qq.com`、`ugc*.gtimg.com` |

**关键点：广告决策与正片共用 `tv.t002.ottcn.com`，广告素材与正片共用 `ugc*.gtimg.com` 同一 CDN。按域名/IP 拦截无法区分广告与正片。**

### 5.4 黑洞实验

将下列域名全部在代理层返回 403：

```text
xsgdt.play.t002.ottcn.com
pgdt.gtimg.cn
v2.reachmax.cn
sdk.youpintechs.com
configssp.mathpool.cn / proxyapi.mathpool.cn / newapim1g.mathpool.cn
volsj.open.adsaide.cn
tencent-dtv.m.cn.miaozhen.com
t.in-neo.cn
```

结果：**广告仍然完整播放 120 秒**。原因是广告决策走主 API，素材走主 CDN，且存在本地预缓存。

### 5.5 结论

> 不 root、不改包，**无法可靠屏蔽**极光免费专区的 90–120 秒前贴片。

> **2026-11-10 修订**：已发现 root shell，可进一步考虑替换/修改 APK 或冻结广告进程；但“按域名/IP 拦截”依然不可行（广告与正片共用域名和 CDN）。root 后的三种新路径评估见 §5.7。

补充原因：

- App 内置 `AppHttpDns`（腾讯 HTTPDNS3），并在 native 层 hook libc DNS，系统 DNS / Private DNS / hosts 对其不可靠；
- 广告与正片共用域名与 CDN，无法按域名切断；
- 无「跳过」按钮，只有 SVIP。

### 5.6 为什么有些视频没广告

App 内有频次控制逻辑（dex 字符串：`disable preroll ad because of frequency control`）。看完一条广告后，一定时间窗口内的后续视频不再出广告——这解释了「连试 2 个视频没广告」的现象，与禁用系统包无关。

### 5.7 root 后的重估（2026-11-10）

已拿到 root 通道（`usrchan root`），可以对 §5.5 的“无解”结论做一次修正性评估。**先明确不变的部分**：

| 手段 | root 后是否可行 | 原因 |
|---|---|---|
| 按域名/IP 拦截 | ❌ 仍不可行 | 广告决策 `GetAdsInfo` 与正片 API 同为 `tv.t002.ottcn.com`；素材与正片共用 `ugc*.gtimg.com` 系 CDN |
| 直接 freeze 广告进程 | ❌ 不可行 | 广告 SDK 与播放器同在 `com.ktcp.launcher` 进程内，冻结等于冻结正片 |
| hosts / Private DNS | ❌ 仍不可行 | App 内置 `AppHttpDns` + native hook libc DNS |

**root 才具备的三种新手段（按代价从低到高）**：

1. **tcpdump 精确取证（最低风险，建议先做）**
   root 下可直接抓包，绕过之前“全局 HTTP 代理看不全 QUIC/私有协议”的限制：
   ```bash
   tcpdump -i any -s 0 -w /data/local/tmp/aurora.pcap host tv.t002.ottcn.com
   ```
   目标是拿到 `GetAdsInfo` 请求/响应与素材请求的**完整五元组与时序**，确认是否存在可单独阻断的广告创意请求（而非决策请求）。只有找到独立 endpoint，方案 2 才有意义。

2. **本地频控改值（中等代价，需改包）**
   `disable preroll ad because of frequency control` 说明客户端本地就有一层频控。若能在 dex 里定位该判断并把阈值/时间窗改成“永久命中”，即可在**不联网拦截**的前提下大幅减少前贴片。
   代价：`/data/app/.../base.apk` 是系统预装应用，改包需重签 + 处理 `pm install -r` 的签名校验与后续 OTA，风险明显高于前两项；且可能触发腾讯侧的完整性校验。

3. **广告决策请求丢弃（高风险，待验证）**
   若抓包证明确实存在独立的广告决策 endpoint，可用 `iptables -m string` 精准丢弃该请求（保留正片），观察播放器是“降级为无广告”还是“卡住等超时”。极光没有跳过按钮，一旦卡住体验会更差，**必须先做方案 1 再评估**。

> 结论：root 把“不可能”变成了“可以试”，但目前**还没有实测通过**的方案。§5.5 中“不改包无法可靠屏蔽”的结论对“域名/IP 拦截”依然成立，需要修改的只是“root 之后仍无解”这半句。

**2026-11-10 实测否定的方案**：

| 尝试 | 结果 |
|---|---|
| 改 `ads.service.AdConfiguration` 的 `ad=false`（`AdService.preCheckAd()` 的总开关） | ❌ 无效。该键被 `com.tencent.qqlivetv.hooksp.SharedPreferencesHooker` 接管为 **MMKV**（`files/mmkv/mmkvwrapper_ads.service.AdConfiguration`），写 `shared_prefs/*.xml` 根本不生效；而且真正的前贴片走 `com.tencent.ads.v2` → `preroll.e`（TVK 桥接层），并不读这个键 |
| `iptables` 按 SNI 封 `v2.reachmax.cn` | ❌ 规则命中 19 个包，广告照播 |
| 封 `xsgdt.play.t002.ottcn.com` + 清空 `ad_cache`/`tad_cache` | ❌ 无效。App 会在起播前重新拉取素材（缓存文件时间戳更新到操作之后） |
| 把 `ad_cache` / `tad_cache` 目录换成不可写文件 | ❌ 仍照播（实时流，不依赖缓存目录） |
| 按 IP 封广告 CDN | ❌ 不可行。`61.241.57.66` 与 `qrapi`（扫码登录）、`aiseet` 等业务共用；且播放流量大量走 **P2P/本机代理**（目的地址就是设备自身 IP 的高位端口） |

**抓包结论（2026-11-10）**：

实测前贴片时长 60–90 秒（倒计时 121/118/87/77/64/63 秒都出现过），来源链：

```text
广告决策  v2.reachmax.cn（ReachMax）
素材/上报 xsgdt.play.t002.ottcn.com、vmmp.qpic.cn、tencent-dtv.m.cn.miaozhen.com
内容 API  tv.t002.ottcn.com（与广告决策共用）
视频传输  大量 P2P/本机代理流量（192.168.3.156:高端口）
```

因此**按域名/IP 拦截在原理上不可行**：广告素材与正片共用 CDN/P2P 通道，且决策请求与内容 API 同域。

**最终方案（2026-11-10 前贴片落地，2026-11-11 扩展暂停/后贴片/中插）**：

不做网络拦截，也不改包，改为**运行时挂钩 SDK 的“是否允许出广告”门函数**：

```text
com.tencent.ads.view.c.a(AdRequest)
  ├─ adType == 1（前贴片，QAdPreVideoImpl）→ ErrorCode(143)
  ├─ adType == 2（暂停，QAdPauseVideoImpl）→ ErrorCode(143)
  ├─ adType == 3（后贴片，QAdPostVideoImpl）→ ErrorCode(143)
  └─ adType == 4（中插，QAdMidVideoImpl）  → ErrorCode(143)
```

`PlayerAdView.a()` 拿到非空 ErrorCode 会走 `fireFailedEvent()`，播放器随即继续正片——这是 SDK 自带的“无广告”路径（源码里“小窗 121”“悟空 120”两条早退分支同款），不是硬改。

> **2026-11-11 补漏**：第一版只拦了 `adType == 1`，免费视频播放中途仍会插约 70 秒中插。
> 设备日志 21:44:29–21:45:39 完整记录了 `QAdMidVideoImpl` 的加载、播放和 release；
> 中插的 `getAdType()` 返回 **4**，已在 hook 中一并拦截。详细链路见主文档 §4.13.9。
>
> 补漏后的实测（同一部免费剧）：22:00:47 命中 `block preroll #1/#2`，
> 22:03:19 命中 `block midroll #3/#4`，22:10:51 命中 `block pause #3`；
> 之后截图仍在正片，未出现对应广告播放。后贴片（3）代码已覆盖，待片尾实测。

注入用设备端 `frida-inject -e`（不需要 `frida-server`、不需要 PC），由 `/data/local/tmp/preroll_guard.sh` 按 pid 自动注入，`boot.sh` 开机拉起。整机重启、进程重启均已验证：起播 4–6 秒直接进剧情，无倒计时。

完整的调用链证据、部署、验证与回滚见主文档 **§4.13**。

**关于“频次控制”**（`disable preroll ad because of frequency control`，错误码 206/22018）：

- 它在 `view.c.a() → c()` 内部，位置在我们的 hook **之后**，被无条件绕过；
- 它只是“看完一条广告后，窗口期内后续视频不出广告”，属于**验证陷阱**：连续试两个视频都没广告，不能证明屏蔽生效；
- 判断是否真被拦截，必须看**同一次起播**的表现（起播 4–6 秒是否已在正片）或 hook 日志，而不是“接连几次没广告”。

本次验证已做 A/B 对照：同一时间段，不注入时 5 秒处仍是广告（太极拳素材），注入后 4–5 秒已是正片。

---

### 5.8 预装“小湃桌面”取证与移除（2026-11-10）

#### 5.8.1 身份

| 项目 | 值 |
|---|---|
| 包名 | `com.xiaopaitech.plauncher` |
| 路径 | `/system/app/app-release/app-release.apk`（16.6 MB + odex/vdex 0.26 MB） |
| 版本 | 1.11.03（versionCode 4675，minSdk 19，targetSdk 28） |
| 身份 | `sharedUserId=android.uid.system`（uid 1000），平台签名 |
| 入口 | `com.xiaopaitech.plauncher/.ui.main.HomeActivity`（HOME + LAUNCHER） |

同族还有两个包（**未动**）：

| 包名 | 位置 | 版本 | 用途 |
|---|---|---|---|
| `com.xiaopaitech.paicd2` | `/data/app/...` | 1.09.003 | 小湃配套应用（uid 1000） |
| `com.xiaopaitech.packageinstaller` | `/system/app/PaiPackageInstaller-origin` | 1.01.14 | 小湃安装器 |

#### 5.8.2 效果（截图取证）

**不是应用列表型桌面，而是内容推荐型**：

- 左侧竖排应用坞：全部应用 / 芒果TV版 / 银河奇异果 / 云视听小电视 / 南瓜电影 / 酷喵 / 小米儿童；
- 顶部搜索，右侧多行大图推荐流（锦绣安宁、星期六2024、时光音乐会、七夜雪、二十一天、暗夜与黎明…）；
- “全部应用”页是普通应用网格，提示“长按 OK 键进行移动或卸载”；
- 点未安装的入口只会弹 toast「请先安装应用商店应用」。

实测开销：打开后进程 RSS **≈296 MB**（uid 1000，普通 `killBackgroundProcesses` 无效，只有 root 能 force-stop），对 1GB 内存的机器不友好。

#### 5.8.3 能不能删？——可以，但按风险分三档

| 方案 | 可逆 | 释放空间 | 说明 |
|---|---|---|---|
| `pm disable-user --user 0` | ✅ `pm enable` | ❌ | 最稳，先做这个 |
| `pm uninstall -k --user 0` | ✅ `cmd package install-existing` | ❌（数据在 /data） | 系统应用可卸载到当前用户 |
| **删 `/system` 里的 APK** | ⚠️ 需备份 | ✅ 16 MB | 本次采用 |

**红线**：不要用 `pm suspend`。它与极光桌面同属 uid 1000，suspend 会连带把同 uid 的音频 AppOps 判为 `Audio disabled for suspended package`，表现为全机静音。

#### 5.8.4 本次操作（已执行）

1. 本地备份（校验 md5 `c61cda45c9190b83744df4b89a0e3f48`）；
2. 设备内备份到 `/data/local/tmp/xiaopai-plauncher-backup/`；
3. `pm disable-user` + `am force-stop`；
4. `mount -o rw,remount /` 后 `rm -rf /system/app/app-release`；
5. 重启，PackageManager 自动清理其数据目录：

```text
W PackageManager: System package com.xiaopaitech.plauncher no longer exists; it's data will be wiped
W PackageManager: Destroying /data/user/0/com.xiaopaitech.plauncher ... unknown
```

**空间变化**：

| 指标 | 删除前 | 删除后 |
|---|---|---|
| `/` 已用 | 876 MB | 860 MB |
| `/` 可用 | **0** | **24 MB** |
| 向 `/system` 写文件 | `ENOSPC` | `WRITE_OK` |

> 关键收益不是那 16 MB 本身，而是**恢复了 `/system` 的可写能力**。此前“删文件后 df 有空间仍 ENOSPC”的空闲块位图异常，在释放出连续空间后消失，后续可以正常新增/回写系统文件（例如把 `atrace_userdebug.rc` 原内容写回）。

**功能验证（重启后）**：

| 项目 | 结果 |
|---|---|
| 默认 HOME | `me.efesser.flauncher/.MainActivity`（正常） |
| 极光入口 | 正常启动 |
| 前贴片拦截 | 进程 4229 自动注入，起播直接进正片 |
| 退出极光释放 | 当时由 `aurora_guard` 执行；2026-11-11 起极光改为默认 HOME 常驻，该脚本已下线 |
| 音频 | 无 `Audio disabled for suspended` 记录 |

#### 5.8.5 回滚

```powershell
# 1) 恢复 APK（需 root，/ 已可写）
Invoke-Root "mount -o rw,remount /"
Invoke-Root "mkdir -p /system/app/app-release && cp -a /data/local/tmp/xiaopai-plauncher-backup/. /system/app/app-release/"
Invoke-Root "chmod 644 /system/app/app-release/app-release.apk; chown root:root /system/app/app-release/app-release.apk"

# 2) 重启后重新启用
A reboot
Invoke-Root "pm enable com.xiaopaitech.plauncher"
```

> 注意：删除后它的用户数据已被 PackageManager 清空，恢复后历史记录/偏好会回到默认值。

#### 5.8.6 配套包 `paicd2` 一并移除

| 项目 | 值 |
|---|---|
| 包名 | `com.xiaopaitech.paicd2` |
| 路径 | `/data/app/com.xiaopaitech.paicd2-*/base.apk` |
| 版本 | 1.09.003 |
| 大小 | 20,097,149 B（19.17 MB） |
| md5 | `b9694794a90156258742152a21293a83` |

```powershell
Invoke-Root "pm uninstall com.xiaopaitech.paicd2"
# Success
```

重启后 `pm list packages | grep xiaopai` 只剩 `com.xiaopaitech.packageinstaller`（安装器，保留）。

> 说明：它装在 `/data/app`，卸载释放的是 **/data** 空间；与 `/system` 的 16 MB 是两笔独立的收益。

#### 5.8.7 恢复 `atrace_userdebug.rc`

之前为省空间把它清成了 0 字节（原内容 1178 B 备份在 `/data/local/tmp/atrace_userdebug.rc.bak`，md5 `225f6a812081eba44468eae472fcfe26`）。`/system` 恢复可写后按原样写回：

```powershell
Invoke-Root "mount -o rw,remount /"
Invoke-Root "cp -f /data/local/tmp/atrace_userdebug.rc.bak /system/etc/init/atrace_userdebug.rc"
Invoke-Root "chown root:root /system/etc/init/atrace_userdebug.rc; chmod 644 /system/etc/init/atrace_userdebug.rc"
A reboot
```

验证：

```powershell
A shell ls -l /system/etc/init/atrace_userdebug.rc     # 1178
A shell md5sum /system/etc/init/atrace_userdebug.rc    # 225f6a...
A shell logcat -d -b system | findstr /I atrace        # 无解析报错
```

#### 5.8.8 清理与空间收益

删除/恢复完成后，机顶盒内的临时文件已清理：

| 位置 | 处理 | 收益 |
|---|---|---|
| `/data/local/tmp` | 删除 ad.pcap/log、全部 probe/test/install 脚本、两组备份目录 | 58 MB → 21 MB（剩余主要是 `frida-inject` 21 MB） |
| `/sdcard` 根目录 | 删除 373 个 png + 172 个 xml（全是调试截图/UI dump） | 约 198 MB |
| **/data 可用** | — | **1.61 GB → 1.85 GB（+237 MB）** |
| **/ 可用** | — | **0 → 24 MB**（且恢复可写） |

保留项（运行必需，不要删）：

```text
/data/local/tmp/boot.sh              开机钩子
/data/local/tmp/ads_guard.sh         广告包守卫
/data/local/tmp/preroll_guard.sh     前贴片/中插注入守护
/data/local/tmp/preroll_block.js     hook 脚本
/data/local/tmp/frida-inject         设备端注入器
/data/local/tmp/sky_check.sh.bak     原 sky_check 备份
/data/local/tmp/install-recovery.sh.bak
/data/local/tmp/*.log               运行日志（自动截断）
```

> `aurora_guard.sh` 已于 2026-11-11 下线（极光改为默认 HOME 常驻），见主文档 §4.12.9。

> `/sdcard/tad`（约 56 MB）是广告 SDK 的外部缓存，属于应用数据不是本次临时文件，未动；需要的话可以单独清。

### 5.9 附带：SVIP 试看限制的取证结论（2026-11-11）

排查“付费内容只播前几分钟”时，确认了完整链路（详细分析见主文档 §4.14）：

| 项目 | 实测 |
|---|---|
| App 版本 | `com.ktcp.launcher` 18.9.0.10035 |
| 试看开关 | CGI 顶层 `<st>8</st>`，`<preview>` 为可播秒数 |
| 正常内容 | `<st>2</st>`，`<preview>` 等于 `<td>`（实测 466 = 466.198） |
| 播放器 | 时长改为 `preview` 秒；越界/播完抛 `111012` |
| App 提示 | `PreviewVideoPayPresenter` 在结束前约 5 秒弹付费面板 |
| 播控同步 | `enable_icntv_backend_invoke=1`，试看按 `VinfoAuthType.PREVIEW` 上报 |

CGI 缓存位置（root）：

```text
/data/data/com.ktcp.launcher/cache/LocalCache/<hash>
```

补充取证（2026-11-12）：

- **5 分钟不是客户端常量**：`<preview>` 由 CGI 解析（默认 0），全量代码里没有 300 秒的试看常量；
- **试看响应不落缓存**：`TVKVideoInfoCache:saveVideoInfo,试看，no cache`，
  所以缓存里查不到 `<st>8</st>` 属正常现象，不能据此判断“没试看”；
- **本机缓存账号态**：`svip_info.userLogin=false`（缓存值，可能滞后于实际登录），`is_support_preview=1`；
  未登录/无权益点开 VIP 片源，服务端按游客试看下发（常见 `preview=300`）；
- 若账号已有 SVIP 仍被限 5 分钟，按故障排查（登录态、权益生效、区域限制），
  而不是改客户端判定。

> 这是服务端按账号/VIP 状态下发的付费授权结果，客户端只负责执行；
> 本项目不提供绕过方式。

---

### 5.10 附带：酷喵（CIBN）前贴片广告链路（2026-11-13）

酷喵 `com.cibn.tv` 14.0.1.3 的前贴片走的是“客户端本地合并”，
与极光的服务端 THLS 不同，因此可以在合并前拦掉。

| 项目 | 实测 |
|---|---|
| 请求入口 | `RequestAdForExternal.loadPreAd` → `e.c.a.c.c.a().a(7, ...)` |
| 广告数据 | `AdvInfo`，实测 `preAdCnt=3`、`preAdDuration=109000`（约 109 秒） |
| 合并 | `createMergeUrl ... enable localMergeUrl` → `onMergeOk` |
| 门函数 | `a.g.a.a.h.f.playm.isAdDataEmpty(IAdInfoWrapper)` |
| 返回 true | `onGetInfoResult` → `getAdInfoFailedSkipAd` → 直接播正片 |
| 实测（3 条） | `block kumiao ad #1 size=3`，之后无 `onMergeOk`、无 `IsPreAd` |
| 实测（4 条） | `block kumiao ad #1 size=4`，`preAdDuration=113000`，同样直接进正片 |
| 覆盖 | adType 7 前贴片、8 中插、10010002 pre-video-stream |
| 不覆盖 | Fusion/Soft/Inventory 浮层，暂停广告（10/30） |
| 落地 | `kumiao_block.js` + `kumiao_guard.sh`（pid 轮询注入，已加入 boot.sh） |

结论：与极光同样的 Frida 运行时思路可行，但门函数不同；
酷喵更简单，不需要处理服务端拼流。详细链路与风险见主文档 §4.15。

---

## 6. 后台保活：厂商 SkyworthConfig 白名单逆向

### 6.1 现象

VPN 启动后，一切到 SmartTube 前台，VPN 进程立刻被杀：

```text
E ActivityManager: app not allow running background: com.sunjunior.caresimvpn, userId: 0, uid: 10049, pid: 27134, otherProcess has fg act: false, app.mCurSchedGroup: 2
D ActivityManager: force stop app: com.sunjunior.caresimvpn, uid: 10049
```

### 6.2 定位

`services.jar` → `com.android.server.am.ActivityManagerService.checkAllowBackgroundRunning(WindowProcessController, long)`。

控制流程（还原）：

```java
boolean allow = false;
SkyworthConfig c = SkyworthConfig.getInstance(mContext);

if (c.isBlackListEnable("com.forestdata.pass")) {
    // 黑名单模式
    if (procName != null &&
        c.isInNameBlackList("com.skyworthdigital.backgroundblacklist", procName)) {
        allow = true;
    }
} else {
    // 白名单模式（本机实际走这里，日志 "sw checkValue = false"）
    if (procName != null &&
        (c.isInNameList("enable_running_backgroud_components", procName) ||
         c.isInNameList("com.skyworthdigital.backgroundwhitelist", procName))) {
        allow = true;
    }
}
```

### 6.3 数据结构与匹配规则

`SkyworthConfig` 的 key 与存储位置：

| 名单 key | 存储位置 | 匹配方式 |
|---|---|---|
| `com.skyworthdigital.backgroundwhitelist` | **Settings.System** | **完全相等** |
| `enable_running_backgroud_components` | **Settings.Secure** | **前缀匹配** |
| `com.skyworthdigital.backgroundblacklist` | Settings.System | 完全相等 |
| `com.forestdata.pass` | Settings.Secure | 黑名单模式开关（签名为 `Base64("true")`） |

规则：`getStringFromSettings()` 中，凡是以 `com.skyworthdigital` 开头的 key 读 `Settings.System`，其余读 `Settings.Secure`。

`isInCurrWhiteList()`：listType 以 `com.skyworthdigital` 开头 → `equals`；否则 → `startsWith`（所以默认表里 `com.skyworth`、`com.ktcp.launcher` 等是前缀）。

### 6.4 签名算法（关键）

名单值不是明文信任的，必须通过 `CryptUtils.requestIsLegal` 校验：

```java
// checkList(authKey, value)
String readAuthKey = getString(authKey);          // 存签名的 settings key
String mListValue  = Base64.encodeToString(
        value.getBytes(), Base64.NO_WRAP);        // Android flag=2
return CryptUtils.requestIsLegal(readAuthKey, mListValue);

// requestIsLegal(key, param2)
String readKey = SystemProperties.get("persist.sys.hwconfig.stb_id", "");
String serverKey = hmacSHA1(/*data*/ param2, /*key*/ readKey);
return serverKey.equals(key);
```

即：

```text
signature = hex_lower( HMAC_SHA1( key = stb_id, msg = Base64_NO_WRAP(list) ) )
```

本机：

```text
persist.sys.hwconfig.stb_id = C8138B98DA132125JoSYc
```

验证：对当前 `com.skyworthdigital.backgroundwhitelist` 计算 HMAC，得到
`fbdcfa07f157081ce72edefc31b2273960a1d9e2`，与设备内 `com.forestdata.box` **完全一致**，证明算法正确。

各名单对应的签名 key：

| 名单 | 签名存放 key | 命名空间 |
|---|---|---|
| `com.skyworthdigital.backgroundwhitelist` | `com.forestdata.box` | Secure |
| `enable_running_backgroud_components` | `com.forestdata.box3` | Secure |
| `com.skyworthdigital.backgroundblacklist` | `com.forestdata.box2` | Secure |
| `com.forestdata.pass` | 自身 | Secure |

### 6.5 写入与验证

因为我们走的是白名单分支（`sw checkValue = false`），只需要维护 `com.skyworthdigital.backgroundwhitelist`（完全匹配）：

```text
1) 读取当前列表（Settings.System）
2) 追加 com.tvpn.client
3) 重新计算 HMAC 签名
4) 写回 Settings.System 的名单 + Settings.Secure 的 com.forestdata.box
```

实测日志：

```text
I SkyworthConfig: isInNameList check success,read server list
```

写入后 TVPN 进程在 SmartTube 前台时保持存活，问题解决。

### 6.6 脚本

见附录 C。

---

## 7. TVPN：从 carvpn 派生

### 7.1 为什么选 carvpn

- 系统级 `VpnService` + 本地 SOCKS5 relay（hev-socks5-tunnel），无需 root；
- 支持按应用白名单分流（只代理 YouTube，其他 App 直连）；
- 仅 `armeabi-v7a`，与 Q6011 完全匹配；
- minSdk 21 / targetSdk 23，在 Android 10 上可直接运行；
- APK 只有 ~242KB，远轻于 sing-box（30MB+），对 1GB 内存友好。

### 7.2 改造清单

源码副本：

```text
D:\AndroidDev\work\carvpn-m1  ->  D:\AndroidDev\work\tvpn-m1
```

| 项目 | 原值 | 新值 |
|---|---|---|
| 应用名 | CarVPN | **TVPN** |
| applicationId / namespace | `com.sunjunior.caresimvpn` | `com.tvpn.client` |
| Java 包路径 | `com/sunjunior/caresimvpn` | `com/tvpn/client` |
| versionCode / Name | 2 / 0.2.0 | 1 / 1.0.0 |
| 图标 | 默认 | 新绘制（盾牌 + 播放键） |
| TV banner | 无 | `drawable-xhdpi/tv_banner.png` (320×180) |
| Leanback 入口 | 无 | 增加 `LEANBACK_LAUNCHER` + banner |

### 7.3 JNI 注意事项（重要）

hev-socks5-tunnel 的 JNI 不是编译期符号名，而是 `JNI_OnLoad` 里运行时查找：

```c
klass = (*env)->FindClass(env, STR(PKGNAME) "/" STR(CLSNAME));
RegisterNatives(env, klass, native_methods, ...);
```

`PKGNAME` 来自 `app/src/main/jni/Application.mk`：

```make
APP_CFLAGS += -DPKGNAME=com/tvpn/client -DCLSNAME=CarVpnTunnel
```

所以**改包名只需要同步改 `Application.mk` 并重新编译 native 库**，不需要改 C 源码或 JNI 符号。

原生依赖解压（`app/src/main/cpp` 被 gitignore，构建前必须解压）：

```bash
tar -xzf third_party/hev-socks5-tunnel-0c68850.tar.gz -C app/src/main/cpp
```

### 7.4 构建

构建流水线（实测通过）：

1. `gradle assembleDebug`（编译 native relay + hev）
2. 把 `app/build/intermediates/cxx/Debug/*/obj/local/armeabi-v7a/carvpnrelay`
   复制为 `app/src/main/jniLibs/armeabi-v7a/libcarvpnrelay.so`
3. `gradle assembleRelease`
4. `zipalign -p -f 4`
5. `apksigner sign`（v1+v2，v3=false）

完整脚本见附录 E。

产物：

```text
D:\AndroidDev\TVPN.apk   242,863 bytes   versionCode=1 versionName=1.0.0
```

签名证书沿用 `D:\AndroidDev\keys\carvpn-release.jks`（别名 `carvpn`，密码见 `D:\AndroidDev\README.md`）。

### 7.5 图标

代码绘制（Pillow，4× 超采样后缩放）：

- 1024×1024 圆角方形，深蓝 → 青绿渐变；
- 白色盾牌描边，内部青色播放三角；
- 输出 mipmap：mdpi 48 / hdpi 72 / xhdpi 96 / xxhdpi 144 / xxxhdpi 192；
- 另生成 320×180 TV banner（盾牌 + `TVPN`）。

---

## 8. VPN 运行与节点选择

### 8.1 工作方式

```text
被代理 App (SmartTube)
   ↓ 普通 socket
VpnService tun: 26.26.26.1/32, DNS 26.26.26.2, route 0.0.0.0/0, MTU 1400
   ↓ tun fd
hev-socks5-tunnel → SOCKS5 → 127.0.0.1:8101 (本地 relay)
   ↓
HTTP CONNECT 上游节点
```

- 分流白名单为 `org.smarttube.stable`，其他 App 直连；
- App 自带 TlsUpstream：`tls: true` 节点由本地 TLS 适配器终结外网 TLS；
- DNS 不直连：tun 内 UDP/53 → relay → `CONNECT <resolver>:53` 转 DNS-over-TCP，并做污染检测。

### 8.2 DNS 路径与坑

relay 的 DNS 依赖**节点允许 CONNECT 到 53 端口**。不同节点策略不同，实测：

| 节点 | DNS（CONNECT 53） | YouTube 播放 |
|---|---|---|
| 印尼 · TLS | ✅ 正常 | ❌ `SABR server requested a player response reload` |
| 日本 · TLS | ❌ `502 Bad Gateway (resolver:53)` → `UnknownHostException` | ❌ |
| 台湾 · TLS | ❌ 节点本身不可达（TCP 443 超时） | ❌ |
| **美国硅谷7 · TLS** | ✅ | ✅ **正常播放** |

结论：**节点决定成败**。当前固定使用「美国硅谷7」，并关闭「自动选择最快可用节点」，避免自动切回坏节点。

### 8.3 开机自启

已写入：

```bash
adb shell cmd settings put secure always_on_vpn_app com.tvpn.client
adb shell cmd settings put secure always_on_vpn_lockdown 0
```

`lockdown=0` 表示 VPN 未连上时允许直连，不会断网。

> 待验证：重启后 always-on VPN 是否会被厂商的后台清理逻辑影响，需要实际重启一次确认。

### 8.4 客户端

TV 无 GMS（`pm list packages | grep google` 为空），因此安装 **SmartTube**（`org.smarttube.stable`，v32.71，armeabi-v7a），无需 Google 服务即可播放 YouTube。

---

## 9. 完整复现步骤

> 假设 TV 已开启 USB 调试，PC 已配置 adb。

### 9.1 基础 ADB

```bash
adb -s 0332493700221160007899 shell echo ok
```

### 9.2 卸载 sing-box / 旧 CarVPN

```bash
adb -s 0332493700221160007899 shell pm uninstall io.nekohasekai.sfa
adb -s 0332493700221160007899 shell pm uninstall com.sunjunior.caresimvpn
```

### 9.3 安装 TVPN

```bash
adb -s 0332493700221160007899 install -r D:\AndroidDev\TVPN.apk
```

### 9.4 写入后台白名单（核心）

```bash
python whitelist_tvpn.py com.tvpn.client
```

脚本见附录 C。执行后确认：

```text
I SkyworthConfig: isInNameList check success,read server list
```

### 9.5 首次配置 TVPN

1. 启动：

```bash
adb shell am start -n com.tvpn.client/.MainActivity
```

2. 输入订阅链接（长文本用 adb 注入，先禁用全屏输入法）：

```bash
adb shell ime disable com.sohu.inputmethod.sogou.tv/.SogouIME
adb shell input tap 900 205
adb shell input text "https://<订阅地址>"
adb shell input tap 960 300          # 导入订阅
adb shell ime enable com.sohu.inputmethod.sogou.tv/.SogouIME
adb shell ime set com.sohu.inputmethod.sogou.tv/.SogouIME
```

3. 分流白名单填 `org.smarttube.stable`；
4. 选择「美国硅谷7」，取消勾选「自动选择最快可用节点」；
5. 点「启动代理」，在系统 VPN 授权对话框点「确定」；
6. 确认隧道：

```bash
adb shell ip addr show tun0
# inet 26.26.26.1/32
```

### 9.6 安装并验证 SmartTube

```bash
adb shell monkey -p org.smarttube.stable -c android.intent.category.LAUNCHER 1
```

首页能出缩略图、点开视频能全屏播放，即成功。

---

## 10. 遗留问题与后续方向

| 事项 | 状态 / 建议 |
|---|---|
| 厂商广告包反弹 | 仅 `com.tianci.ad` 仍禁用，其余已恢复；需要重新执行附录 B，并观察 `skycommonpropertymanager` 是否再次拉起 |
| 重启后 always-on VPN | 未实测，建议重启一次验证 `tun0` 与 TVPN 进程 |
| SmartTube 后台被杀 | 系统日志出现 `app not allow running background: org.smarttube.stable`；播放时在前台不受影响，后台播放可能被清理 |
| 节点 DNS 依赖 | relay 只走 `CONNECT resolver:53`，节点不支持 53 就会 DNS 失败；后续可在 relay 增加 **DoH(443)** 兜底 |
| 前贴片广告 | 已确认无 root 无法可靠屏蔽；可选：SVIP、手机 App 投屏、BBLL（仅 bilibili 内容） |
| 内存优化 A/B 档 | 用户已暂停，未执行 |
| TVPN UI | 手机式表单，改节点建议插 USB 鼠标；日常使用无需进入界面 |

---

## 11. 附录：脚本与证据

### A. adb 封装（PowerShell）

```powershell
$adb = "D:\AndroidDev\android-sdk\platform-tools\adb.exe"
$ser = "0332493700221160007899"
function A { & $adb -s $ser @args }
```

### B. 包禁用 / 启用

```powershell
param([string]$Pkg, [ValidateSet('disable','enable')][string]$Mode)

$adb = "D:\AndroidDev\android-sdk\platform-tools\adb.exe"
$ser = "0332493700221160007899"
$state = if ($Mode -eq 'disable') { 3 } else { 1 }

& $adb -s $ser shell service call package 95 `
    s16 $Pkg i32 $state i32 0 i32 0 s16 com.android.shell
```

批量禁用（首轮清单）：

```powershell
$pkgs = @(
  'com.tianci.ad',
  'com.skyworthdigital.ott.advert.app',
  'com.skyworthdigital.ottstatsv2',
  'com.skyworthdigital.logcollector',
  'com.skyworthdigital.autotest',
  'com.android.noticewidget',
  'com.skyworthdigital.ott.guide',
  'com.skyworthdigital.skycommonpropertymanager'
)
foreach ($p in $pkgs) {
  & $adb -s $ser shell service call package 95 s16 $p i32 3 i32 0 i32 0 s16 com.android.shell
}
```

### C. 后台白名单签名脚本

`whitelist_tvpn.py`（通用版，参数为要加入的包名）：

```python
import subprocess, hmac, hashlib, base64, sys

ADB = r'D:\AndroidDev\android-sdk\platform-tools\adb.exe'
SER = '0332493700221160007899'
PKG = sys.argv[1] if len(sys.argv) > 1 else 'com.tvpn.client'

def sh(*args):
    r = subprocess.run([ADB, '-s', SER, 'shell'] + list(args),
                       capture_output=True, text=True,
                       encoding='utf-8', errors='ignore')
    return r.stdout.strip()

stb = sh('getprop', 'persist.sys.hwconfig.stb_id')
cur = sh('cmd', 'settings', 'get', 'system',
         'com.skyworthdigital.backgroundwhitelist')

items = [x.strip() for x in cur.split(',') if x.strip()]
if PKG not in items:
    items.append(PKG)
new = ','.join(items)

sig = hmac.new(stb.encode(),
               base64.b64encode(new.encode()),
               hashlib.sha1).hexdigest()

sh('cmd', 'settings', 'put', 'system',
   'com.skyworthdigital.backgroundwhitelist', new)
sh('cmd', 'settings', 'put', 'secure',
   'com.forestdata.box', sig)

back = sh('cmd', 'settings', 'get', 'system',
          'com.skyworthdigital.backgroundwhitelist')
backsig = sh('cmd', 'settings', 'get', 'secure',
             'com.forestdata.box')
print('verify:', back == new and backsig == sig)
```

### D. CONNECT 日志代理（广告抓包 / 黑洞实验）

`proxy.py` 精简版：

```python
import socket, threading, socketserver, time

LOG = r'C:\Users\John\AppData\Local\Temp\opencode\proxy_log.txt'
BLOCK = {
    'xsgdt.play.t002.ottcn.com',
    'pgdt.gtimg.cn',
    'v2.reachmax.cn',
    'sdk.youpintechs.com',
    'configssp.mathpool.cn',
    'proxyapi.mathpool.cn',
    'newapim1g.mathpool.cn',
    'volsj.open.adsaide.cn',
    'tencent-dtv.m.cn.miaozhen.com',
    't.in-neo.cn',
}

def log(m):
    open(LOG, 'a', encoding='utf-8').write(
        time.strftime('%H:%M:%S ') + m + '\n')

class H(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            data = b''
            while b'\r\n\r\n' not in data:
                c = self.request.recv(8192)
                if not c:
                    return
                data += c
            head, _, rest = data.partition(b'\r\n\r\n')
            line = head.split(b'\r\n')[0].decode('latin-1')
            method, target = line.split(' ')[:2]

            if method.upper() == 'CONNECT':
                host, _, port = target.rpartition(':')
                port = int(port or 443)
                log('CONNECT %s:%d' % (host, port))
                if host in BLOCK:
                    self.request.sendall(b'HTTP/1.1 403 Forbidden\r\n\r\n')
                    log('BLOCKED %s' % host)
                    return
                up = socket.create_connection((host, port), timeout=15)
                self.request.sendall(
                    b'HTTP/1.1 200 Connection Established\r\n\r\n')
                self.pipe(self.request, up)
                return

            from urllib.parse import urlsplit
            u = urlsplit(target)
            log('HTTP %s %s%s' % (method, u.hostname, u.path))
            if u.hostname in BLOCK:
                self.request.sendall(
                    b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')
                return
            up = socket.create_connection((u.hostname, u.port or 80), timeout=15)
            newhead = ('%s %s HTTP/1.1\r\n' % (method, u.path)).encode() \
                      + b'\r\n'.join(head.split(b'\r\n')[1:]) + b'\r\n\r\n'
            up.sendall(newhead + rest)
            self.pipe(self.request, up)
        except Exception as e:
            log('ERR %s' % e)

    def pipe(self, a, b):
        def fwd(src, dst):
            try:
                while True:
                    d = src.recv(32768)
                    if not d:
                        break
                    dst.sendall(d)
            except Exception:
                pass
            finally:
                try: dst.shutdown(socket.SHUT_WR)
                except Exception: pass
        t = threading.Thread(target=fwd, args=(b, a), daemon=True)
        t.start()
        fwd(a, b)
        t.join(timeout=5)

class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

open(LOG, 'w').close()
S(('0.0.0.0', 8888), H).serve_forever()
```

### E. TVPN 构建脚本

`build_tvpn.ps1`：

```powershell
$ErrorActionPreference = 'Stop'
$env:JAVA_HOME = 'D:\AndroidDev\jdk17'
$env:ANDROID_HOME = 'D:\AndroidDev\android-sdk'
$env:ANDROID_SDK_ROOT = 'D:\AndroidDev\android-sdk'
$env:GRADLE_HOME = 'D:\AndroidDev\gradle-8.9'
$env:Path = "$env:JAVA_HOME\bin;$env:GRADLE_HOME\bin;$env:Path"

$proj = 'D:\AndroidDev\work\tvpn-m1'
Set-Location $proj
$BT = 'D:\AndroidDev\android-sdk\build-tools\34.0.0'
$out = 'D:\AndroidDev\TVPN.apk'

gradle assembleDebug --console=plain
if ($LASTEXITCODE -ne 0) { throw 'assembleDebug failed' }

$stage = 'app\src\main\jniLibs\armeabi-v7a'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($d in Get-ChildItem 'app\build\intermediates\cxx\Debug' -Directory) {
    $p = Join-Path $d.FullName 'obj\local\armeabi-v7a\carvpnrelay'
    if (Test-Path $p) {
        Copy-Item $p (Join-Path $stage 'libcarvpnrelay.so') -Force
    }
}

gradle assembleRelease --console=plain
if ($LASTEXITCODE -ne 0) { throw 'assembleRelease failed' }

& "$BT\zipalign.exe" -p -f 4 `
    'app\build\outputs\apk\release\app-release-unsigned.apk' "$out.unsigned"

& "$BT\apksigner.bat" sign `
    --ks 'D:\AndroidDev\keys\carvpn-release.jks' `
    --ks-key-alias carvpn `
    --ks-pass "pass:$env:KS_PASS" `
    --key-pass "pass:$env:KS_PASS" `
    --min-sdk-version 21 `
    --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled false `
    --out $out "$out.unsigned"
```

### F. UI 自动化片段（无触摸屏）

```bash
# 隐藏/恢复全屏输入法（Sogou 会遮住整个界面）
adb shell ime disable com.sohu.inputmethod.sogou.tv/.SogouIME
adb shell ime enable  com.sohu.inputmethod.sogou.tv/.SogouIME
adb shell ime set     com.sohu.inputmethod.sogou.tv/.SogouIME

# 文本注入（光标定位到行尾）
adb shell input tap 1500 648
adb shell input keyevent 123
adb shell input keyevent 67 67 67 ...      # 批量退格
adb shell input text "org.smarttube.stable"

# 滚动 / 截图 / 抓屏
adb shell input swipe 960 900 960 300 400
adb shell screencap -p /sdcard/s.png
adb pull /sdcard/s.png .
```

### G. 证据文件

分析过程中产生的反汇编/字符串证据（临时目录可能被清理，建议转存）：

| 文件 | 内容 |
|---|---|
| `svc_dump.txt`（339MB，UTF-16） | `services.jar` dexdump，含 `checkAllowBackgroundRunning` / `SkyworthConfig` / `CryptUtils` |
| `fw_dump.txt` | `framework.jar` dexdump，含 IPackageManager 事务号 |
| `adbd.bin` / `libadbd_services.so` | adbd 降权分析 |
| `skycfg.txt` | `SkyworthConfig` 类完整 dump |
| `isinlist.txt` | `isInNameList` 方法 dump |
| `checklist.txt` | `checkList` 方法 dump |
| `initAuthMap.txt` | 名单与签名 key 映射 |
| `crypt.txt` | `hmacSHA1Encrypt` / `requestIsLegal` / `byteToHexString` |
| `yst_strings.txt` / `yst/` | 云视听小电视 APK 的广告相关字符串与 dex |
| `ktcp.apk` / `ktcp/` | 极光 launcher APK 与 dex |
| `proxy_log.txt` | 广告链路 CONNECT 日志 |

关键代码位置：

```text
com.android.server.am.ActivityManagerService.checkAllowBackgroundRunning
com.android.server.SkyworthConfig
  - isInNameList / isInNameBlackList / isInCurrWhiteList
  - checkList / getStringFromSettings / getStringFromMemory
  - initAuthMap
com.android.server.skyworth.CryptUtils
  - hmacSHA1Encrypt / requestIsLegal / byteToHexString
```

---

## 12. 2026-11-08 阶段性结论

> 本章记录 NewTV 升级后暴露的新问题与验证结果，避免重复踩坑。

### 12.1 升级与包状态现状

- NewTV（腾讯极光）已从 `17.7.0.10070` 升级到 **`18.9.0.10035`**；
- 升级触发了重启，之后 8 个禁用包只剩 4 个：

| 保持禁用 | 被恢复为 enabled=1 |
|---|---|
| `com.tianci.ad` | `com.skyworthdigital.ott.advert.app` |
| `com.skyworthdigital.autotest` | `com.skyworthdigital.ottstatsv2` |
| `com.android.noticewidget` | `com.skyworthdigital.logcollector` |
| `com.skyworthdigital.ott.guide` | `com.skyworthdigital.skycommonpropertymanager` |

连续两次普通重启均复现，**不是升级的一次性重置**，而是常态开机行为。

### 12.2 路由器拦截（荣耀 X2）实测

荣耀路由 X2 为华为 HiLink 固件，支持「儿童上网 → 网址黑名单」（智慧生活 App，最多 64 条）。

已加入：

```text
ott.xiaopaitech.com
ota.skyworthbox.com
```

验证结果：

```text
adb shell ping -c 1 ott.xiaopaitech.com   -> unknown host
adb shell ping -c 1 ota.skyworthbox.com   -> unknown host
skyupgradeV2: url https://ota.skyworthbox.com/otav2/checkupgrade
           -> java.net.UnknownHostException
```

结论：**DNS 拦截对“控制名单下载”有效**，但**挡不住本地自恢复**。

控制名单地址（来自 APK 逆向）：

```text
getSystemControlUrl() = https://<BoxManagerHost>/boxManager/v1/appConfig/getSystemManagerList?
ro.license.tag = skyworth  -> ott.xiaopaitech.com
失败回退 -> ota.skyworthbox.com （同路径）
```

### 12.3 本地开机恢复链（关键）

开机事件（events log）：

```text
00:03:49 am_proc_start  com.skyworthdigital.ottstatsv2  reason=added application
00:03:52 am_proc_start  com.skyworthdigital.skycommonpropertymanager  reason=broadcast (SkyPropretyReceiver)
00:03:55 am_proc_start  com.skyworthdigital.logcollector  reason=broadcast (LogCmdReceiver)
00:03:55 am_proc_start  com.skyworthdigital.ott.advert.app  reason=broadcast (AdvertBroadcastReceiver)
00:05:34 downloadSystemControlList（此时 DNS 已被拦，下载失败）
```

`com.skyworthdigital.ottstatsv2` 的 `flags` 含 **`PERSISTENT`**：

```text
flags=[ SYSTEM HAS_CODE PERSISTENT ALLOW_CLEAR_USER_DATA UPDATED_SYSTEM_APP ALLOW_BACKUP ]
```

`startPersistentApps` 不检查 enabled 状态，因此 `pm disable` / `service call 95` 对它无效；它启动后配合 BOOT_COMPLETED 广播把同簇包重新拉起。

**结论：不 root 无法阻止这 4 个包在每次开机后恢复。**

> **2026-11-10 修订**：已获得 root shell，可用 root 执行 `pm disable-user` 处理；`PERSISTENT` 包是否仍被系统强拉需要实测，详见第 16 章。

### 12.4 当前采用：PC 侧一键脚本（有依赖）

脚本：

```text
C:\Users\John\Documents\fix-tv-adpackages.ps1
```

原理：Windows 上用 adb 连到机顶盒，对 8 个包执行：

```text
am force-stop <pkg>
service call package 95 s16 <pkg> i32 3 i32 0 i32 0 s16 com.android.shell
```

**依赖说明（重要）**：

- 脚本运行在 PC 上，机顶盒自身没有权限改这些系统包；
- 因此需要 **PC 开机 + 与机顶盒在同一局域网（或 USB 连接）**；
- Windows 计划任务只是自动化手段，**不是必需**；
- 若不想依赖 PC，只能考虑 12.7 的其他路线。

可选自动化（每 5 分钟检查一次）：

```powershell
schtasks /create /tn "FixTVAdPackages" /sc minute /mo 5 /f `
  /tr "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\John\Documents\fix-tv-adpackages.ps1 -Quiet"
```

### 12.5 TVPN 开机自启现状（未完成）

已做的尝试：

1. 增加 `BootReceiver`（BOOT_COMPLETED → `startForegroundService(EsimVpnService)`）；
2. 厂商 `BroadcastQueue` 会拦截第三方自启：

   ```text
   E BroadcastQueue: Block auto start app from broadcast: com.tvpn.client
   ```

3. 通过 `SkyworthConfig` 的前缀白名单绕过：给 `<application>` 增加

   ```xml
   android:process="com.skyworthdigital.tvpn"
   ```

   进程名命中厂商默认名单里的 `com.skyworthdigital` 前缀，开机广播**放行**：

   ```text
   V BroadcastQueue: Need to start app [background] com.skyworthdigital.tvpn ...
   I am_proc_start: [0,3868,10051,com.tvpn.client,broadcast,{com.tvpn.client/.BootReceiver}]
   ```

4. 但 `VpnService.Builder.establish()` 在开机后台场景下持续返回 null：

   ```text
   W tvpn: tun establish null, retry 1/20 ... retry 20/20
   ```

   手动从界面启动（前台）则立即成功，且**不弹 VPN 授权框**，说明授权没问题，限制在“后台建立 VPN”这一层。

**状态：开机拉起进程已解决，自动建立隧道未解决。** 目前仍需开机后手动进 TVPN 点一次「启动代理」。

内存占用（运行中实测）：

```text
PSS Total ≈ 33,970 KB（约 34 MB）
Private Dirty ≈ 18,992 KB
Swap PSS ≈ 300 KB
curProcState=2（前台服务），Doze 白名单已加
```

### 12.6 白名单签名备忘（会被厂商覆盖）

| 名单 key | 命名空间 | 签名 key | 匹配 |
|---|---|---|---|
| `com.skyworthdigital.backgroundwhitelist` | System | `com.forestdata.box` | 完全匹配 |
| `enable_running_backgroud_components` | Secure | `com.forestdata.box3` | 前缀匹配 |
| `enable_auto_launch_components` | Secure | `com.forestdata.setup3` | 前缀匹配 |
| `com.skyworthdigital.startupwhitelist` | System | `com.forestdata.setup` | 完全匹配 |

签名算法：

```text
signature = hex_lower( HMAC_SHA1( key = persist.sys.hwconfig.stb_id,
                                 msg = Base64_NO_WRAP(list) ) )
```

注意：`com.skyworthdigital.skycommonpropertymanager`（日志 tag `kuangxinyi`）会定期重写这些名单，System 名单尤其容易被覆盖；Secure 名单相对稳定。

### 12.7 不依赖电脑的选项（按改动量排序）

1. **厂商自带的应用管理/自启动界面**（未验证）
   - 若电视设置里有“禁止自启动/后台限制”，可能写入厂商自己的数据库，优先级高于服务器名单；
   - 需要实测重启后是否保持。
2. **Device Owner 方案**（一次性 adb 配置，之后机顶盒自理）
   - `adb shell dpm set-device-owner <pkg>/<receiver>`（需无账号、未配置工作资料）；
   - 自建一个最小 App，作为 Device Owner 在开机时调用 `setPackagesSuspended()` 挂起广告包；
   - 复杂度中等，需确认系统是否允许挂起系统应用。
3. **Root / 改固件**（改动最大，唯一彻底）
   - 冻结或删除 `ottstatsv2` 等包，或直接改 `PackageManagerService` 的开机恢复逻辑。

### 12.8 最终状态与使用方式（2026-11-08 定稿）

经确认，**当前状态已满足使用要求**：VPN 能连通，YouTube 能正常播放。

- TVPN：手动启动可用，`tun0` 正常建立；
- 实测：`inet 26.26.26.1/32`，进程名 `com.skyworthdigital.tvpn`；
- SmartTube：可正常加载 YouTube 内容并播放；
- 8 个广告/统计包：已通过脚本重新禁用；
- WiFi ADB：已确认可用（见 12.10）。

**日常使用流程（每次开机后）**：

1. 打开 TVPN；
2. 点「启动代理」（节点固定为「美国硅谷7」，不要开自动选路）；
3. 打开 SmartTube 看 YouTube。

**开机自动启动：暂不启用**。原因有两点：

1. 应用若处于 `stopped=true`（被 force-stop 过），Android 不会投递隐式 `BOOT_COMPLETED`；
2. 安装带自启逻辑的新版本后，曾出现一次开机阶段 `system_server` 死锁：

   ```text
   boot_progress_pms_ready -> StartSystemUI -> Watchdog: WAITED_HALF
   watchdog: Blocked in monitor com.android.server.am.ActivityManagerService
   -> 抓栈 -> Watchdog 自动重启
   ```

   该次开机 TVPN 实际并未运行（`stopped=true`，无 `am_proc_start`），因此**不能确认与 TVPN 有关**，但为避免在开机最脆弱阶段介入，决定保持手动启动。

**内存清理器行为（意外收益）**：

```text
OptimizationManager: packageName:com.skyworthdigital.tvpn
ActivityManager: Invalid packageName: com.skyworthdigital.tvpn
OptimizationManager: Kill com.skyworthdigital.tvpn mem ...
```

系统「加速」用进程名当包名去 `forceStopPackage`，而真实包名是 `com.tvpn.client`，因此杀不掉 TVPN。代价是它也不会帮你重连。

### 12.9 关键修复：`VpnService.prepare()`

`com.android.server.connectivity.Vpn.establish()` 的前两个判断（dexdump 还原）：

```java
if (Binder.getCallingUid() != mOwnerUID) return null;
if (!isVpnUserPreConsented(mPackage)) return null;
```

`mOwnerUID` / `mPackage` 是在 **`VpnService.prepare()`** 里登记的：

- 手动启动时，MainActivity 先调 `VpnService.prepare(this)` → 登记成功 → `establish()` 正常；
- 开机由 BootReceiver 直接起服务时跳过了 `prepare()` → `mOwnerUID` 仍为 -1 → `establish()` 一直返回 null。

修复（已合入 EsimVpnService）：

```java
// 建立隧道前必须先 prepare，把本应用登记为 VPN owner
if (VpnService.prepare(this) != null) {
    Log.e(TAG, "vpn permission not granted");
    stopSelfFail();
    return;
}
```

同时保留 `establish()` 失败重试（20 次 × 3 秒）。

> 说明：该修复已编入当前 APK，手动启动路径已验证；开机自启路径因上述 `stopped` 状态与一次开机死锁，未再做完整回归，暂按手动方案使用。

### 12.10 调试环境持久化（已确认）

当前实测值：

```text
development_settings_enabled = 1
adb_enabled                  = 1
persist.adb.tcp.port         = 5555
persist.sys.usb.config       = mtp,adb
ro.adb.secure                = 0
```

WiFi ADB 连通性实测：

```text
adb connect 192.168.3.156:5555   -> connected
adb devices                      -> 192.168.3.156:5555  device
adb -s 192.168.3.156:5555 shell "echo wifi-adb-ok"
                                 -> wifi-adb-ok
```

结论：

- 开发者选项、USB 调试、WiFi ADB 端口均跨重启保留；
- `ro.adb.secure=0`，连接时不需要在电视上点“允许调试”；
- 重启后若 WiFi 通道短暂 `offline`，执行一次 `adb connect 192.168.3.156:5555` 即可恢复；
- 安全提示：5555 端口 + 无授权意味着同一局域网内任何人都能控制该设备。

### 12.11 SmartTube 播放时短暂黑屏：4K60 VP9 解码器反复重建

#### 现象

TVPN 正常、SmartTube 能播放，但播放过程中画面会**间歇性短暂全黑**（约 0.5–2 秒），声音可能继续，之后自动恢复。频率不固定，在打开 4K 视频时更明显。

#### 排查过程与排除项

先确认黑屏发生在哪一层：

| 检查项 | 实测结果 | 结论 |
|---|---|---|
| 黑屏瞬间 `screencap` | 截图有完整视频画面 | Android 合成正常，问题不在图层/应用画面 |
| `dumpsys display` / `dumpsys power` | `mScreenState=ON`、`mWakefulness=Awake`、亮度正常 | 不是息屏/待机 |
| HDMI 内核节点轮询（200ms） | `HPD=1`、`RxSense=1`、`PhyLock=1`、`AvMute=0` 连续十余分钟无变化 | 不是 HDMI 掉线/重新锁相 |
| 内核 HDMI 日志 | 无 mode set、无 AVMute、无 HPD 中断 | 盒子没有主动改分辨率/静音 |
| CEC | `mHdmiControlEnabled: false` | 排除电视输入被 CEC 切走 |
| 温度/降频 | CPU 65°C、GPU 63°C、VE 63°C，`scaling_cur_freq = 1344000`（满频） | 不是过热降频 |
| 屏幕开关事件 | `screen_toggled` 仅两次，均为用户手动按电源键 | 不是系统异常息屏 |

关键判据：**黑屏时 Android 侧合成画面是正常的**，说明黑屏发生在视频解码器这一层，而不是 HDMI 链路或电视端。

#### 根因

SmartTube 在「视频预设 = 禁用」（不限制清晰度）时会选择 **4K60 VP9（itag 315 / 2160p60）**，而这台盒子的硬件解码器明确不支持：

```text
D MediaCodecInfo: NoSupport [sizeAndRate.support, 3840x2160x60.0]
                  [OMX.allwinner.video.decoder.vp9, video/x-vnd.on2.vp9]
D MediaCodecInfo: NoSupport [sizeAndRate.support, 2560x1440x60.0]
                  [OMX.allwinner.video.decoder.vp9, video/x-vnd.on2.vp9]

I MediaCodecRenderer: onInputFormatChanged: format =
    Format(315, 2160p60, video/x-vnd.on2.vp9, [3840, 2160, 60.0])
I CodecNameUnknown-MediaCodecVideoRenderer: configureCodec: ...
    Format(315, 2160p60, ... [3840, 2160, 60.0])
```

解码器仍然按 4K 分配缓冲：

```text
D gralloc: alloc buffer:W:3840 H:2160 S:3840 ... SZ:16817248   ← 单块 16.8MB
D omx_vdec: PORT:>>>>>>>out, x allocate 8 buffers              ← 一次约 130MB
D ACodec: switchBuffer when play 4k video to avoid to malloc
          double fbm buffer amount memory between different video
```

初始化失败后 ExoPlayer 会销毁并重建解码器，重建期间视频图层没有帧，即表现为短暂黑屏：

```text
W MediaCodecRenderer: Recovering from MediaCodec error,
                      re-initializing decoder (attempt 1/3)   ← 08:24:02
W MediaCodecRenderer: Recovering from MediaCodec error,
                      re-initializing decoder (attempt 1/3)   ← 08:24:26
```

同时，8 个 16.8MB 的 4K 缓冲把 1GB 内存直接压垮，触发 OOM 与后台进程清理：

```text
I am_low_memory: 21
I am_proc_died: [0,1552,org.smarttube.stable:phoenix,0,2]
I lowmemorykiller: Suppressed 1 failed kill reports
Mem: 979M total, 43M free     Swap: 734M total, 229M used
```

#### 修复

在 SmartTube 中限制最高清晰度：

```text
设置 → 视频播放器 → 视频预设
  禁用（原）  →  1080p 30fps vp9（现）
```

该设置由 SmartTube 自身持久化，重启后保留。不要选择任何 `2160p` / `1440p` 或带 `hdr` 的档位。

#### 验证

修改后播放同一个 4K HDR 视频，解码格式被限制在 720p/1080p：

```text
I MediaCodecRenderer: onInputFormatChanged: format =
    Format(247, 720p, video/x-vnd.on2.vp9, [1280, 720, 30.0])
I CodecNameUnknown-MediaCodecVideoRenderer: configureCodec: ... 720p ...
```

- 不再出现 `2160p60` 的 `configureCodec`；
- 不再出现 `Recovering from MediaCodec error`；
- 系统负载下降：`400%cpu` 中空闲从 37% 恢复到 **282% idle**；
- 内存压力缓解：free 从 43MB → **59–62MB**，swap 从 229MB → **160–164MB**。

#### 说明与建议

1. 这台盒子的 VP9 硬解**支持 1080p60**（`NoSupport` 仅针对 3840×2160×60 与 2560×1440×60），所以 1080p 档位是安全的；若觉得 720p 偏软，可改选 `1080p 60fps vp9`，但免费 VPN 带宽可能仍将其压回 720p。
2. `自动帧率`（AFR，`DisplaySyncHelper`）默认开启。本机 `supportedModes` 只有 `1920x1080@60`，AFR 无实际收益，只会在每次播放时做一次模式保存/恢复；如需最简路径可在设置中关闭。
3. 排查期间 4 个广告/统计包（`advert.app`、`ottstatsv2`、`logcollector`、`skycommonpropertymanager`）又自行恢复并常驻，是额外的内存压力来源，重启后建议重跑 `fix-tv-adpackages.ps1`。
4. 复现与取证时可用：

```bash
# 查看解码器实际配置与重建
adb logcat -d | grep -E "configureCodec|onInputFormatChanged|Recovering from MediaCodec"

# 查看系统内存压力
adb shell top -n 1 -b | head -6

# 查看 HDMI 链路（全志节点）
adb shell cat /sys/class/hdmi/hdmi/attr/hdmi_source
# 关注 HPD / RxSense / PhyLock / AvMute / VideoFormat
```

### 12.12 内存治理实测（2026-11-08）

#### 背景

投屏失败留下的黑色 `TVPlayerActivity` 长期占着前台，`com.ktcp.launcher` PSS 达到 **182MB**；叠加常驻广告/升级服务后，系统出现：

```text
MemFree 37MB / MemAvailable 253MB
Swap 已用 233MB（ZRAM 物理占用 74MB）
Lost RAM 218MB
pgsteal_direct 47,013 页（直接回收，分配会卡顿）
pswpout 164,167 页（开机约 8 小时换出 641MB）
am_low_memory: 21
```

#### 操作顺序与结果

| 步骤 | 操作 | 效果 |
|---|---|---|
| 1 | 黑屏投屏页按 HOME 退出，再 `am force-stop com.ktcp.launcher` 后回到桌面 | launcher 188MB → 120MB（重新加载后回落到约 198MB，属于桌面本身体量） |
| 2 | 重跑 `fix-tv-adpackages.ps1`（8 个广告/统计包） | `advert.app` 32MB、`logcollector` 6MB 等被清掉 |
| 3 | `am force-stop com.skyworthdigital.shortcutkeyssetting` | 释放约 41–45MB，未自行重启 |
| 4 | 额外禁用 `com.ktcp.autoupgrade`、`com.skyworthdigital.upgrade`、`com.skyworthdigital.skyappupdate`、`com.mipt.store` | 升级/商店类常驻被清掉（随后部分被厂商白名单恢复） |

#### 前后对比

| 指标 | 治理前 | 治理后 | 变化 |
|---|---:|---:|---:|
| MemAvailable | 253 MB | **390 MB** | **+137 MB** |
| Free RAM | 165 MB | **278 MB** | **+113 MB** |
| Used RAM | 731 MB | 676 MB | -55 MB |
| Used PSS | 610 MB | 565 MB | -45 MB |
| Lost RAM | 218 MB | 143 MB | **-75 MB** |
| ZRAM 物理占用 | 74 MB | 61 MB | -13 MB |
| swap 已用 | 233 MB | 199 MB | -34 MB |

治理后占用最高的进程：

```text
198 MB  com.ktcp.launcher        ← 桌面本身，最大头
 74 MB  system (system_server)
 29 MB  搜狗输入法
 24 MB  mediarender（DLNA 接收，投屏要用）
 21 MB  TVPN
 18 MB  ott.advert.app           ← 白名单恢复后再次常驻
 18 MB  ottstatsv2               ← PERSISTENT，杀不掉
 16 MB  DisplayDaemon (app_process)
 16 MB  system:ui
 13 MB  systemui:ui
 12 MB  clouddrive（root 守护进程）
```

#### 关键发现

1. **厂商白名单会快速恢复禁用**：实测禁用列表在几分钟内从 12 个缩回 6 个，`advert.app`、`logcollector`、`skycommonpropertymanager`、`upgrade`、`skyappupdate` 自行回到启用状态。脚本只能临时压制，重启或一段时间后需重跑。
2. **`ottstatsv2` 是 PERSISTENT**：即使 `am force-stop` + 禁用，仍会被系统拉起。
3. **`clouddrive` 不是 APK**：它是 `/data/xpclouddrive/clouddrive`（root 运行），由 `/init.rc` 的 `start_clouddrive` 执行 `/data/xpclouddrive/run_clouddrive.sh` 启动；目录权限 `0700 system`，shell 无法停止或改写。
4. **桌面本身是最大常驻**：`com.ktcp.launcher` 约 198MB，属于正常体量，无法通过禁用解决；只能通过减少其前台驻留时间（少停在投屏/播放页）间接缓解。
5. **`mediarender`、`DisplayDaemon`、输入法、systemui 不应动**：分别关系到投屏、显示输出、输入和系统 UI。

#### 日常建议

- 每次重启后运行一次 `fix-tv-adpackages.ps1`；
- 投屏失败出现黑屏时，先按 HOME 退出黑色播放页，避免 `TVPlayerActivity` 长期占用大量内存；
- 如需进一步压内存，可临时 `am force-stop` 升级/商店类应用，但不要禁用 `mediarender` 与 `DisplayDaemon`。

### 12.13 adb root 可行性复核（2026-11-08）

#### 设备事实

```text
ro.build.type      = userdebug
ro.debuggable      = 1
ro.secure          = 1
ro.adb.secure      = 0
SELinux            = Permissive
su                 = 不存在
/                  = /dev/block/dm-2 ext4 ro（dm-verity）
/vendor            = /dev/block/dm-1 ext4 ro
```

adbd 被厂商拆分/改写：

```text
/system/bin/adbd                 30 KB（壳）
/system/lib/libadbd.so          240 KB
/system/lib/libadbd_services.so 329 KB
```

`adb root` 实测返回的是厂商自定义字符串：

```text
adbd can't run as root
```

而 `libadbd_services.so` 中仍导出：

```text
restart_root_service
restart_unroot_service
```

AOSP 原文 `adbd cannot run as root in production builds` 也仍然存在。说明**不是函数被删除，而是调用分支/init 触发被改掉**。

同时所有可读的 rc 中都没有：

```text
service.adb.root
```

因此 `setprop service.adb.root 1` 也不会触发 init 重启为 root。

#### 结论

在不修改 `/system`、不先取得 root 的前提下，`adb root` **走不通**。

“破解 so” 的闭环问题：

- `libadbd_services.so` 位于 `/system/lib`，而 `/` 是 dm-verity 只读；
- 要改它，必须先 remount rw 或关闭 verity → 又需要 root；
- 当前没有 `su`，也没有可写的 root 执行入口（`/data/xpclouddrive` 为 `0700 system`）。

#### “不关机验证”的风险

| 验证方式 | 风险 |
|---|---|
| 仅执行 `adb root`，不改文件 | 低。adbd 会重启并以 shell 回来，USB/WiFi 均可恢复（已实测） |
| 把改过的 so/二进制写入 `/system` 后验证 | 写入本身做不到（dm-verity 只读）；若通过漏洞写入：运行中的 adbd 仍用旧映射，必须重启 adbd 才生效；改坏则**立刻失去 ADB（USB+WiFi）**，只能物理断电；dm-verity 会让**下一次开机**校验失败，严重时无法启动 |

因此“不关机”**不能消除风险，只是把风险延后**，且中途可能先丢失远程访问。

#### 建议

1. 若目标只是去广告/省内存，**不要动 `/system`**，维持当前无 root 方案；
2. 若确实需要 root，先确认 bootloader 是否可解锁、是否有官方烧录包/恢复工具，再考虑 fastboot 刷 boot/adbd 并关闭 verity；
3. 在没有串口或烧录恢复手段前，不建议对 `/system` 或 boot 分区做任何写入验证。

> 备注：SELinux 为 Permissive、`ro.debuggable=1`，一旦存在可用的内核/守护进程提权漏洞，成功率会比正常生产机高；但当前仍缺少可写的 root 执行入口，不能仅凭这两点直接提权。

### 12.14 bootloader / fastboot 实测（2026-11-08）

#### 目的

判断这台 Q6011 的 bootloader 是否支持标准的 OEM 解锁，为“替换 adbd / 改 `/system` / 关 verity”提供前提。

#### 第一步：打开 Android 侧 OEM 解锁

开发者选项中有 **「OEM 解锁」** 开关（`com.android.tv.settings/.system.development.DevelopmentActivity`），默认关闭。打开后：

```text
ro.oem_unlock_supported = 1
sys.oem_unlock_allowed  = 1
```

注意：这只是 Android 侧的“允许解锁”标志，**不会解锁，也不会清数据**；但会关闭 FRP/设备保护。该状态跨重启保留。

其他相关属性：

```text
ro.build.type          = userdebug
ro.debuggable          = 1
ro.secure              = 1
ro.adb.secure          = 0
ro.boot.secure_os_exist= 0
ro.bootloader          = unknown
ro.boot.vbmeta.device_state 等 = 空（厂商未按标准 AVB 上报）
```

#### 第二步：进入 bootloader 并识别接口

```bash
adb reboot bootloader
```

Windows 上出现新设备：

```text
USB\VID_1F3A&PID_1010
iManufacturer = Android Bootloader Interface
iProduct      = USB Developer
Interface 0   = class 0xFF / sub 0x42 / proto 0x03
Endpoints     = 0x81 IN / 0x02 OUT（bulk 512）
CompatibleIds = USB\Class_FF&SubClass_42&Prot_03
```

`FF/42/03` 就是标准 fastboot 接口，说明 **bootloader 确实支持 fastboot**。

主机侧问题：

- Windows 默认没有匹配 `1F3A:1010` 的驱动，设备管理器显示“USB Developer”+感叹号；
- 用 **Zadig 2.9**（官方签名 Akeo Consulting）给它绑定 **WinUSB** 后，设备正常（`ProblemCode=0`、`Service=WinUSB`）；
- 但 `fastboot.exe devices`（platform-tools 37 与 33 均试过）仍然枚举不到；
- 改用 **PyUSB** 直接打开设备并走 fastboot 协议，通信正常。

因此后续查询用 PyUSB 完成（只读 `getvar`）。

#### 第三步：bootloader 实际回答

| 查询 | 结果 |
|---|---|
| `getvar:version` | `OKAY 0.5` |
| `getvar:product` | `OKAY ac001415688148c1f4e` |
| `getvar:secure` | **`OKAY yes`** |
| `getvar:unlocked` | `not supported` |
| `getvar:unlock_ability` | `not supported` |
| `flashing:get_unlock_ability` | `FAIL` |
| `oem device-info` | `FAIL unknown cmd` |
| `getvar:all` | `not supported` |
| `getvar:max-download-size` | `0x02000000`（32MB） |
| `getvar:current-slot` / `slot-count` / `is-userspace` / `partition-type:*` | `not supported` |

内核 cmdline 同时给出了 U-Boot 版本：

```text
uboot_message = 2018.05(06/25/2025-14:43:50)
console       = ttyS0,115200
partitions    = bootloader/env/boot/super/misc/recovery/cache/
                vbmeta/vbmeta_system/vbmeta_vendor/metadata/private/frp/...
```

#### 结论

**这台机器没有 Android 标准的 bootloader 解锁机制。**

- 它是全志 U-Boot 2018.05 的精简 fastboot（协议 0.5），主要用于产线烧写；
- 不支持 `unlocked` / `unlock_ability` / `oem unlock` / `flashing unlock`；
- 当前 `secure: yes`，处于锁定/安全状态；
- Android 的「OEM 解锁」开关只改变 `sys.oem_unlock_allowed`，bootloader 不执行对应解锁动作。

因此：

```text
fastboot flashing unlock   → 不存在
fastboot oem unlock        → 不存在
```

要修改系统，只剩两条路：

1. **直接刷写**：`fastboot flash <分区>`。`secure: yes` 是否拦截写入未知，必须实际写分区才能验证，风险高；
2. **全志 FEL + 厂商烧录工具**：这类盒子的正常刷机路径，但需要拆机/按键进 FEL、完整固件包与烧录工具。

即使能刷，`/system` 仍是 dm-verity 只读，还要同时处理 `vbmeta` / verity，否则刷完也无法启动。

#### 副作用与恢复

| 项目 | 状态 |
|---|---|
| 盒子 | 已 `reboot` 回 Android，ADB 正常 |
| `sys.oem_unlock_allowed` | 1（已开启，跨重启保留，会关闭 FRP；如不继续建议手动关回） |
| PC 驱动 | 已给 `1F3A:1010` 绑定 WinUSB，可在设备管理器卸载恢复 |
| 分区 | **未写入任何内容，未清数据** |

#### 取证命令（PyUSB 方式）

```python
# 需要: pip install pyusb libusb-package
import usb.core, usb.util, time
d = usb.core.find(idVendor=0x1f3a, idProduct=0x1010)
d.set_configuration()
cfg = d.get_active_configuration(); intf = cfg[(0,0)]
ep_out = usb.util.find_descriptor(intf, custom_match=lambda e:
    usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
ep_in = usb.util.find_descriptor(intf, custom_match=lambda e:
    usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)

ep_out.write(b"getvar:version")
print(ep_in.read(512, timeout=2000))     # b'OKAY0.5'
```

> 不要发送 `flashing:unlock` / `oem unlock` 之类未确认的写命令；在 `secure: yes` 的 U-Boot 上，行为不可预期。

---

## 13. Instagram Lite 横屏适配与登录问题（2026-11-09）

### 13.1 目标与最终结果

目标：在 Q6011 上使用 Instagram Lite，全屏横屏、无黑边，能正常登录和浏览。

最终结果：**已达成**。

| 项目 | 值 |
|---|---|
| 应用 | Instagram Lite `com.instagram.lite` |
| 版本 | 536.0.0.12.107（versionCode 1109087351，armeabi-v7a） |
| 安装包 | `docs/apks/instagram-lite-536-landscape-signed.apk`（重签横屏版） |
| 当前 UID | 10058 |
| TVPN 分流 | 已注册 UID 10058（与 SmartTube 10050 并行） |
| 显示 | 1920×1080 全屏横屏，主页信息流无黑边 |
| 登录 | 已登录（邮箱验证码流程，见 13.6） |

> 结论先行：439 和 536 的**密码登录**与**Facebook 登录**在这台设备上都不可用，且与改包/重签无关；可用路径是 App 内的「访问你的账户 → 发送邮件 → 验证码」流程。

### 13.2 版本选择

| 版本 | 结果 |
|---|---|
| 439 armv7 | 可以启动，但密码登录被拒，FB 登录回跳失败（下文） |
| 536 armv7 | 当前最新版，同样存在登录问题；横屏补丁后全屏正常 |

- APKMirror 上 arm-v7a 最新版就是 **536.0.0.12.107**（2026-11-06 发布），没有更新的官方版本可换。
- GitHub 上没有官方新版 APK，只有基于官方包的补丁工具（HushGram、InstaEclipse 等），不提供应用本体。
- 536 曾出现过一次“启动后闪退回桌面”，重装后正常；判断为首次安装 dexopt/系统休眠状态导致的偶发问题，不是版本不兼容。

### 13.3 横屏补丁流程

工具：`D:\AndroidDev\tools\apktool\apktool.bat`、build-tools 34 的 `zipalign` / `apksigner`、自建签名 `iglite.keystore`。

```bash
apktool d -f -o dec instagram-lite-536-armv7.apk
# 1) AndroidManifest.xml 中 4 处 android:screenOrientation="portrait"
#    全部改为 "landscape"（MainActivity、AlbumGalleryActivity、
#    PhoneNumberHint、FullScreenNotificationActivity）
# 2) 删除 android:allowCrossUidActivitySwitchFromBelow="false"
#    （不删会报 attribute not found，apktool 编译失败）
apktool b -f -o instagram-lite-536-landscape.apk dec

zipalign -p -f 4 instagram-lite-536-landscape.apk aligned.apk
apksigner sign --ks iglite.keystore --out signed.apk aligned.apk
```

要点：

- 重签后签名与官方不同，**不能覆盖安装**，必须先 `adb uninstall com.instagram.lite`，应用数据会清空；
- 卸载重装后 UID 会变化（本次依次经历 10056 → 10057 → 10058），必须重新注册 TVPN 分流（见 13.4）；
- 横屏补丁只改 Manifest，不改代码，不影响登录逻辑（已用官方原版 536 对照验证）。

### 13.4 TVPN 分流 UID 重新注册（关键坑）

TVPN 的白名单是**按包名**配置的，但 ip rule 里的 UID 只在**代理启动时**注册一次；之后新装/重装应用不会自动加入。

现象与限制：

```text
ip rule show | grep 10058   # 重装后没有该 UID 的规则 → Instagram 不走 VPN
adb shell am force-stop com.skyworthdigital.tvpn   # 无效，进程仍在
adb shell kill -9 <pid>                            # Operation not permitted
adb shell ip rule add ...                          # RTNETLINK: Operation not permitted
```

正确做法（已验证）：

1. 打开 TVPN（`com.tvpn.client/.MainActivity`）；
2. 滑动到底部，点 **「停止代理」**；
3. 再点 **「启动代理」**；
4. 检查规则：

```bash
adb shell ip rule show | grep uidrange
# 期望看到类似：
# 12000: from all fwmark 0x0/0x20000 iif lo uidrange 10058-10058 lookup tun0
# 13000: from all fwmark 0x1006d/0x1ffff iif lo uidrange 10058-10058 lookup tun0
# 14000: from all iif lo oif tun0 uidrange 10058-10058 lookup tun0
```

白名单内容保持：

```text
org.smarttube.stable,com.instagram.lite
```

> 注意：TVPN 的「完全退出程序」会停止代理；「退出到后台」代理继续运行。只按 Home 键不会重建规则。

### 13.5 登录问题与实测结论

#### 现象 A：密码登录被拒

- 439 横屏版、536 横屏版、536 官方原版，输入正确账号 + 密码后都弹出：

```text
忘记 <账号> 的密码了
你可以用绑定的 Facebook 帐户登录。
[重试] [使用 Facebook]
```

- 同一密码在手机 IG 客户端可正常登录；
- 用物理键盘、明文显示逐字符核对后仍然被拒；
- 换邮箱/手机号作为账号标识，结果相同。

结论：**服务器侧返回 bad_password / 安全校验**，不是电视键盘输错，也不是改包导致。官方原版 536 表现一致，可排除重签、横屏补丁、版本新旧。

#### 现象 B：Facebook 登录回跳失败

- FB 账号密码本身可用：登录后会弹出「保存登录信息？我们会保存 Sun Jun 的登录信息」；
- 但点「以后再说」或继续后，回跳 `fbconnect://success` 失败：
  - 439：显示「出错啦」；
  - 536：显示「This Page Isn't Available / The link may be broken」；
- 回退后回到 IG 登录页，未登录。

结论：**OAuth 回跳链路（fbconnect 自定义 scheme）在当前客户端/网络环境下不可用**，与账号无关。

#### 尝试过的无效方案

| 方案 | 结果 |
|---|---|
| 439 横屏版密码登录 | 被拒 |
| 536 横屏版密码登录 | 被拒 |
| 536 官方原版密码登录 | 被拒（证明与改包无关） |
| 439 / 536 Facebook 登录 | 回跳失败 |
| 手动 `ip rule add` 注册 UID | 无权限 |
| 同手机号注册新账号 | 未采用（号码已绑定，IG 不允许复用） |

### 13.6 可用登录路径（已验证，可重复）

```
登录页
  → 「忘记密码？」
  → 登录帮助（账号自动带入，点「继续」）
  → 访问你的账户
  → 「发送邮件」
  → 确认弹窗（点主按钮）
  → 输入邮箱收到的验证码
  → 确认弹窗（点上方主按钮）
  → 登录成功，进入主页
```

实测记录：

- 官方原版 536：通过该流程成功登录一次；
- 重装横屏版后：重新走同一流程（发送新邮件、使用新验证码）再次成功登录。

注意事项：

- 验证码发送到账号绑定邮箱，一次性有效；重新发送后旧验证码作废；
- 竖屏（原版）下部分弹窗会被窗口裁切，文字看不全；横屏版显示完整；
- 该流程不依赖密码，重装/清数据后可重复使用；
- 登录成功后 IG 不再弹「保存登录信息」；如出现，可按需选「保存」或「以后再说」，不影响登录。

### 13.7 当前状态与回滚

当前（2026-11-09）：

- 已安装 536 横屏重签版，UID 10058；
- TVPN 运行中（美国硅谷7 · TLS），tun0 `26.26.26.1/32`；
- ip rule 已注册 10050（SmartTube）与 10058（Instagram）；
- Instagram 已登录，横屏全屏主页正常。

回滚方式：

```bash
adb uninstall com.instagram.lite
adb install -r docs/apks/instagram-lite-536-armv7.apk     # 官方原版（竖屏）
# 或
adb install -r docs/apks/instagram-lite-439-landscape.apk # 旧横屏版
```

重装后需按 13.4 重新注册 TVPN UID；如需登录，按 13.6 重新走邮箱验证码。

### 13.8 安全与后续

- **立即建议**：调试过程中曾在电视上开启密码明文显示并截图留证，建议尽快修改一次 IG 密码；不要把密码写入任何文档或脚本。
- 不要再用 `ip rule add` 手动加规则（无权限），统一用 TVPN「停止代理 → 启动代理」。

> **2026-11-10 修订**：root shell 下已可手动 `ip rule add`，但日常仍建议走 TVPN 启停，详见第 16 章。
- 卸载重装必然丢失登录态，需重新走邮箱验证码流程。
- 如果以后 IG 更新了版本，优先测试官方原版能否登录；登录通过后再做横屏补丁，避免重复折腾。
- 若遇到启动即闪退，先检查是否是首次 dexopt/休眠导致，重启应用或重装后再观察；旧版 439 曾需要 `com.fix.mediaprovider` 媒体 authority 占位包才能进入登录页。

### 13.9 复现命令摘录

```bash
# 查看版本与 ABI
aapt2 dump badging instagram-lite-536-armv7.apk | grep -E "package:|native-code|sdkVersion"

# 安装并查看 UID
adb install -r docs/apks/instagram-lite-536-landscape-signed.apk
adb shell dumpsys package com.instagram.lite | grep userId=

# 验证 VPN 分流
adb shell ip addr show tun0 | grep inet
adb shell ip rule show | grep uidrange

# 启动应用
adb shell am start -n com.instagram.lite/com.facebook.lite.MainActivity
```

### 13.10 已知问题：全屏横屏后图片/人物被裁切（待优化）

现象：

- 主页信息流、个人头像、快拍封面中的人物显示不全（顶部/底部或两侧被裁掉）；
- 视频/Reels/快拍（原始比例 9:16）在 16:9 横屏全屏下必然裁切。

原因：

- IG Lite 的布局按手机竖屏比例设计，强制 landscape 后窗口变成 1920×1080；
- 图片控件使用 `centerCrop`（按短边铺满后裁切溢出部分），窗口比例从 ~9:16 变成 16:9，裁切量明显增大；
- 全屏（隐藏系统栏）进一步放大了这个问题。

可选优化方向（按风险从低到高）：

1. **接受裁切的折中**：保留全屏，仅调整 `wm size` / `wm density` 让 UI 元素比例更接近手机（如 1600×900 或调低 density），能缓解但不彻底；
2. **保留黑边换完整画面**：把应用窗口限制在接近手机比例的宽度（例如居中 608×1080），图片不裁切，但两侧有黑边——与“无黑边”目标冲突，需要权衡；
3. **改 `scaleType`**：把信息流/头像的 `ImageView` 从 `centerCrop` 改为 `fitCenter`。需要定位到具体 View 或资源，smali/资源改动量大、易随版本失效，风险最高；
4. **竖屏内容单独处理**：Reels/Stories 属于 9:16 视频，横屏全屏无法同时满足“铺满 + 不裁切”，只能在“黑边”与“裁切”之间取舍。

结论：这是横屏全屏的固有取舍，不是补丁错误。

#### 实测补充（2026-11-09）

- `wm size 810x1080`（把逻辑分辨率改成手机比例）：因为 Activity 已被锁定 `landscape`，系统在竖屏画布中又套了一个横向窗口，个人页内容反而被裁；已恢复 1920×1080，不采用。
- 自由窗口：系统 `supports-multiwindow=true`，但 `am start --windowingMode 5` 被忽略，任务仍是 fullscreen，无法给 IG 单独开手机比例窗口。
- 结论：这台 Android 10 TV 没有 per-app 窗口/比例能力，**纯分辨率自适应无法同时做到“全屏 + 不裁切”**。

#### 可行替代：同签名双版本切换（2026-11-09）

- 已生成竖屏完整版（原版 536 + 同一 `iglite` 签名）：
  `docs/apks/instagram-lite-536-portrait-signed.apk`
- 横屏全屏版：
  `docs/apks/instagram-lite-536-landscape-signed.apk`
- 两者包名、签名一致，可直接覆盖安装，**登录状态与数据保留**（无需重新走验证码）：

```bash
# 切竖屏：内容完整，左右黑边（相当于电视中间一个手机窗口）
adb install -r docs/apks/instagram-lite-536-portrait-signed.apk    # 约 30 秒

# 切回横屏全屏：无黑边，信息流图片上下裁切
adb install -r docs/apks/instagram-lite-536-landscape-signed.apk
```

- 只有 `adb uninstall` 才会清数据；`install -r` 不会。
- 建议：日常刷信息流用横屏；看图片/快拍/Reels 时切竖屏完整版。
- **切换版本后的首次启动可能异常**：界面只占左侧约 608px、右侧黑屏，或竖屏时底部导航只显示前两个图标（导航栏按 1920 宽排版后被窗口裁掉）。强制停止再打开即可恢复：

```bash
adb shell am force-stop com.instagram.lite
adb shell am start -n com.instagram.lite/com.facebook.lite.MainActivity
```

---

### 13.11 视频无法播放 / 画面卡住的排查（2026-11-09）

现象：

- 信息流或 Reels 的视频只显示封面，画面不动（间隔 3 秒截图逐帧完全一致）；
- `dumpsys gfxinfo` 的 `Total frames` 不增长；
- `dumpsys audio` 中 IG 的 AudioTrack 为 `idle`；
- `tun0` 无新增下载；
- logcat 可见解码器已经初始化：

```text
MediaCodec: [OMX.allwinner.video.decoder.avc] setting surface generation ...
ACodec: [OMX.allwinner.video.decoder.avc] setPortMode on output to DynamicANWBuffer failed w/ err -1010
ACodec: [OMX.allwinner.video.decoder.avc] Allocating 9 buffers from a native window ...
```

但之后没有任何输出/取流。

对照测试：

| 测试 | 结果 |
|---|---|
| 同版本竖屏包播放 Reels | 正常（帧数 1527→1672，AudioTrack `started`） |
| 横屏包重装后强制停止再启动 | 视频正常（信息流、Reels 均持续出帧） |
| 先播 SmartTube 再切 IG | 未复现卡死 |

结论：

- **与横屏补丁无关**，是偶发的播放器/解码器初始化卡死；
- 最可疑诱因是应用在**屏幕休眠/唤醒切换**时初始化解码器（本机默认 4 分钟息屏），首帧后停止取流；
- 处理：强制停止 IG 再打开，或重启盒子即可恢复；
- 已把息屏时间延长到 30 分钟，降低触发概率：

```bash
adb shell cmd settings put system screen_off_timeout 1800000
```

- 注意：IG 默认静音自动播放，AudioTrack 可能一直 `idle`，这属于正常现象；判断是否在播放请看帧数是否增长、画面是否变化。

排查命令：

```bash
adb shell dumpsys gfxinfo com.instagram.lite | grep "Total frames"   # 间隔 3 秒对比
adb shell am force-stop com.instagram.lite
adb shell am start -n com.instagram.lite/com.facebook.lite.MainActivity
```

### 13.12 IG 遥控器按键绑定（无障碍辅助，2026-11-09）

问题：IG Lite 是触屏应用，电视遥控器的方向键大部分场景无效：实测 Reels 里**下键原生可用一次**，**上键完全无效**，确定键无反应。

方案：自建一个极小的无障碍辅助 APK（`com.fix.igremote`，工程在 `D:\AndroidDev\work\igremote`），只对 `com.instagram.lite` 生效：

| 遥控器按键 | 行为 |
|---|---|
| 下 | `ACTION_SCROLL_FORWARD`（优先），失败则模拟上滑 |
| 上 | `ACTION_SCROLL_BACKWARD`（优先），失败则模拟下滑 |
| 确定 / 回车 | 点按屏幕中心（播放/暂停） |

实现要点：

- 优先使用**无障碍滚动动作**，比触摸手势可靠（IG 的互动贴纸/轮播会吃掉触摸事件）；
- 滚动动作失败时回退到 `dispatchGesture` 竖直滑动；
- 600ms 防抖，避免连续按键叠加手势把翻页器卡住；
- 服务进程名设为 `com.skyworthdigital.igremote`，命中创维白名单前缀，降低被系统清理的概率；
- 通过 `getWindows()` 判断当前前台包名，只在 IG 内拦截，其他应用不受影响。

构建与安装：

```bash
cd D:\AndroidDev\work\igremote
gradlew assembleDebug          # 复用 tvpn-m1 的 gradlew 也可以
adb install -r app\build\outputs\apk\debug\app-debug.apk

# 启用无障碍服务（本机 settings 命令损坏，用 cmd settings）
adb shell cmd settings put secure enabled_accessibility_services com.fix.igremote/com.fix.igremote.IgKeyService
adb shell cmd settings put secure accessibility_enabled 1
```

注意：

- 本机固件切换 `accessibility_enabled` 不一定会重新绑定服务；更新 APK 或服务失效后，重新执行上面两条 `cmd settings put` 即可；
- 验证：Reels 里连续按“下”可连续切换；按“上”可返回上一个；
- 重启验证（2026-11-09）：重启后无障碍设置持久化，服务自动绑定，遥控器上下键仍可正常切换视频；
- 关闭：`adb shell cmd settings put secure accessibility_enabled 0`，或卸载 `com.fix.igremote`；
- 只影响按键，不修改 IG 本身。

---

## 14. TVPN / CarVPN 工程统一（方案 A，2026-11-09）

### 14.1 背景

`carvpn-m1` 与 `tvpn-m1` 同一 Git 历史，TVPN 是在 carvpn 基础上改名并做 TV 适配的分支。两份代码长期并行会出现：

- 修复只落在一侧（如 `VpnService.prepare()`、`establish()` 重试只加在 TVPN）；
- 包名/签名/配置漂移，车机与电视无法复用同一安装包；
- 文档、图标、Manifest 各改各的。

### 14.2 逐项差异对比（统一前）

| 项目 | carvpn | TVPN | 处理 |
|---|---|---|---|
| 包名/namespace | `com.sunjunior.caresimvpn` | `com.tvpn.client` | 统一为 `com.tvpn.client` |
| 应用名/图标 | CarVPN / 旧图标 | TVPN / 新图标 | 保留 TVPN 资源 |
| `main.xml` | 相同 | 相同 | 保留并加自适应 |
| `MainActivity.java` | 相同 | 相同 | 保留并加自适应 |
| JNI / relay / 隧道 / 节点 / 订阅 / 白名单 | 相同 | 相同（仅 `PKGNAME` 宏改名） | 以 TVPN 为准 |
| Manifest | 基础版 | 增加 BootReceiver、Leanback、TV banner、`android:process="com.skyworthdigital.tvpn"` | 保留（车机无害） |
| 服务修复 | 无 | `VpnService.prepare()` + `establish()` 20×3s 重试 | 保留（两边都受益） |
| 版本 | 0.2.0 / code 2 | 0.2.0 / code 1 | 统一为 1.1.0 / code 2 |
| 文档 | README | README + 本文档 | 合并到 TVPN 主干 |

> 结论：不存在架构级差异。UI 布局全部使用 `match_parent` / `wrap_content` / `dp`，此前看到的“宽度差异”来自设备 density（车机 1024×600、电视 1920×1080 @320dpi），不是硬编码。

### 14.3 统一方案（方案 A）

- **单分支**：`tvpn-m1` 为主干，继续维护；`carvpn-m1` 只读归档，不再提交；
- **单包名**：`com.tvpn.client`，车机与电视安装同一个 APK；
- **TV 专用项保留**：
  - `android:process="com.skyworthdigital.tvpn"`：命中创维白名单前缀，车机上无副作用；
  - `BootReceiver`：保留（车机也支持开机自启，如需关闭可后续加设置开关）；
  - Leanback / banner：车机上无副作用；
- **运行时宽度自适应**：
  - 内容区最大宽度 **840dp**，超出则居中，窄屏保持铺满；
  - 不写死像素，按 `Configuration.screenWidthDp` + `density` 计算。

### 14.4 代码改动

`app/src/main/res/layout/main.xml`：

```xml
<LinearLayout
    android:id="@+id/content"
    android:orientation="vertical"
    android:layout_width="match_parent" android:layout_height="wrap_content"
    android:padding="16dp">
```

`MainActivity.java` 新增（`onCreate` 里 `setContentView` 之后调用）：

```java
private void applyResponsiveWidth() {
    View content = findViewById(R.id.content);
    if (content == null) return;
    int widthDp = getResources().getConfiguration().screenWidthDp;
    final int maxDp = 840;
    if (widthDp <= maxDp + 32) return;
    int px = (int) (maxDp * getResources().getDisplayMetrics().density + 0.5f);
    ViewGroup.LayoutParams raw = content.getLayoutParams();
    if (raw instanceof FrameLayout.LayoutParams) {
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) raw;
        lp.width = px;
        lp.gravity = Gravity.CENTER_HORIZONTAL;
        content.setLayoutParams(lp);
    }
}
```

效果：

| 设备 | 屏幕 | 内容宽度 |
|---|---|---|
| Q6011 电视 | 1920×1080 @320dpi（960dp 宽） | 840dp 居中，左右各约 60dp 留白 |
| 车机 | 1024×600（dp 宽约 640–1024） | 保持 match_parent 铺满（视 density 而定） |

### 14.5 构建与签名

签名沿用原有 release key（与设备上已安装版本一致，可覆盖升级、数据保留）：

```powershell
$env:JAVA_HOME="D:\AndroidDev\jdk17"
$env:KEYSTORE_PATH="D:\AndroidDev\keys\carvpn-release.jks"
$env:KEYSTORE_PASSWORD="<keystore 密码>"
$env:KEY_ALIAS="carvpn"
$env:KEY_PASSWORD="<key 密码>"
& "D:\AndroidDev\work\tvpn-m1\gradlew.bat" -p "D:\AndroidDev\work\tvpn-m1" assembleRelease --no-daemon
```

产物：`app/build/outputs/apk/release/app-release.apk`

- 包名 `com.tvpn.client`，versionCode 2 / versionName 1.1.0；
- 证书 SHA-256：`6cef253333cc134dc8965a719f29b1d3d519aeccf93a2dca7d08595559397612`（CN=CarVPN, O=SunJunior）。

### 14.6 部署与验证

```bash
adb install -r app-release.apk        # 同签名覆盖，保留数据和 UID
adb shell am start -n com.tvpn.client/com.tvpn.client.MainActivity
# 安装会杀掉旧进程/代理，需在界面重新「启动代理」
adb shell ip rule show | grep uidrange
```

实测（2026-11-09）：

- 覆盖安装成功，UID 不变，订阅/节点/白名单配置保留；
- 重新启动代理后 `tun0 = 26.26.26.1/32`，规则含 10050（SmartTube）/ 10058（Instagram）；
- 状态显示「运行中 · 美国硅谷7 · TLS」；
- 电视上内容宽度 840dp 居中，车机窄屏保持铺满。

### 14.7 车机迁移步骤

1. 卸载旧 `com.sunjunior.caresimvpn`（不卸载会并存，数据不互通）；
2. 安装统一的 `com.tvpn.client` 1.1.0；
3. 导入订阅、选节点、填写分流白名单；
4. 如需开机自启，保留 BootReceiver 即可（已内置）。

### 14.8 重启验证（2026-11-09，1.1.0 实测）

执行 `adb reboot` 后实测：

| 检查项 | 结果 |
|---|---|
| 开机广播 | `Start proc ... for broadcast {com.tvpn.client/com.tvpn.client.BootReceiver}` |
| VPN 建立 | `Vpn: Switched from [Legacy VPN] to com.tvpn.client` / `Established by com.tvpn.client on tun0` |
| relay / TLS | 日志出现 `relay started ... 美国硅谷7 · TLS`、`tunnel start: true` |
| tun0 | `inet 26.26.26.1/32` |
| 分流规则 | 10050（SmartTube）、10058（Instagram）均自动恢复 |
| SmartTube | 首页推荐正常加载，点开视频可正常播放（tun0 RX 约 12.9 MB） |
| Instagram | 重启后未重新登录，信息流可正常刷新 |

结论：**1.1.0 的开机自启与分流恢复已验证通过**。

仍未覆盖：长时间运行稳定性、节点故障切换、重新导入订阅。

---

## 15. 车机实机部署与 WiFi 上游测试（2026-11-09）

### 15.1 车机环境

| 项目 | 值 |
|---|---|
| ADB 序列号 | `408849cb9e8f016c` |
| product / model | `ac83xx_evb` / `ac83xx_evb` |
| 厂商 | `autochips`（AC8317 方案） |
| Android | 6.0 / API 23 |
| ABI | `armeabi-v7a`（仅 32 位） |
| 屏幕 | 1024×600 / 240dpi |
| 内存 | 1.8 GB（MemTotal 1843044 kB） |
| `/data` 可用 | 约 904 MB |
| WebView | 44.0.2403.119（较旧，仅影响网页登录类功能） |

TVPN 1.1.0（`minSdk 21`、`armeabi-v7a`）与该环境完全兼容。

### 15.2 安装 TVPN

```powershell
adb -s 408849cb9e8f016c install -r app-release.apk
# package:/data/app/com.tvpn.client-1/base.apk
# versionCode=2 versionName=1.1.0
```

首次安装后无订阅/节点，需在界面重新导入订阅并选择节点。

### 15.3 分流白名单

车机最终白名单（界面「分流白名单包名」，逗号分隔）：

```
com.mmbox.xbrowser,org.smarttube.stable
```

| 应用 | 包名 | UID |
|---|---|---|
| X 浏览器 | `com.mmbox.xbrowser` | 10031 |
| SmartTube | `org.smarttube.stable` | 10069 |

注意事项（实测踩坑）：

- 包名必须完全准确。曾误写成 `com.mmbox.xbrowse`（少一个 `r`），代理启动不报错，但该应用实际不走 VPN；
- 白名单只在**启动代理**时注册，修改后必须「停止代理 → 启动代理」，无 root 无法手动补 `ip rule`（2026-11-10 修订：root shell 下可手动加，见第 16 章）；
- 车机不需要代理 QQ 音乐 / QQ 视频，已从白名单移除（默认值里的 `com.tencent.qqmusiccar`、`com.tencent.qqlive.audiobox` 不再保留）。

### 15.4 SmartTube 安装与适配

| 项目 | 值 |
|---|---|
| 版本 | 32.71 stable（GitHub 官方 Release） |
| 包名 | `org.smarttube.stable` |
| 架构 | `armeabi-v7a`（24.3 MB） |
| minSdk / targetSdk | 17 / 34 |

结论：**SmartTube 32.71 可以在 Android 6.0 车机上正常安装、渲染与播放**，1024×600 下 UI 完整（16:9 视频上下留黑边）。

```powershell
adb -s 408849cb9e8f016c install -r SmartTube_stable_32.71_armeabi-v7a.apk
```

实测播放参数：itag 136（720p AVC）+ itag 140（AAC），硬解正常，连续截图画面持续推进。

### 15.5 WiFi 上游（手机热点）测试

测试条件：车机连接荣耀 Magic7 热点（2.4 GHz，链路 58 Mbps，RSSI -32），TVPN 节点「美国硅谷7 · TLS」。

| 检查项 | 结果 |
|---|---|
| 上游自动切换 | 日志 `upstream changed ... (wifi), rebinding`、`upstream network: wifi` |
| tun0 | `inet 26.26.26.1/32` |
| X 浏览器访问 Google | 正常，页面显示「Google 提供：English」（美国节点生效） |
| 实际出口 | 播放 8 s 内 `wlan0` RX 513 KB，`eth0` RX 0 KB → 确认全部走 WiFi |
| SmartTube 起播 | 从点击到出画面约 10 s，之后连续播放 |
| 播放稳定性 | 短窗口内仅 3 次 `dropOutputBuffer`，画面持续更新 |
| 吞吐 | 约 47–160 KB/s（热点国际线路带宽有限） |

结论：

- **WiFi 热点的分流代理同样有效**，TVPN 会自动把上游从 eth0 切到 WiFi 并重绑 relay；
- 切换瞬间会断开已有连接，正在播放的视频会重新缓冲，重开即可；
- 热点线路带宽低于内置 4G，起播偏慢属正常现象，可把 SmartTube 清晰度上限设为 480p/720p，或改用香港/新加坡/日本等更近节点。

### 15.6 车机侧结论

1. 统一版 TVPN 1.1.0 在 Android 6.0 / armeabi-v7a 车机上安装、导入订阅、分流代理均正常；
2. 只需白名单 `com.mmbox.xbrowser,org.smarttube.stable`，X 浏览器与 SmartTube 即可同时出海；
3. 车机后续维护与电视使用同一套 APK、同一套白名单机制，不再区分 carvpn 分支。

---

## 16. 结论修订：本地 root 通道（2026-11-10）

> 本章用于修正前文“没有 root”的结论。完整算法与验证记录见合并版 **§4.8**。

### 16.1 新事实

电视 `/system/xbin/usrchan` 是厂商内置的 su（`-rwsr-x--- root shell`）。密码 = `encrypt(ro.serialno)`（序列号为空时回退 `skyworth`），实测可得到：

```text
uid=0(root) gid=0(root) ... context=u:r:su:s0
```

### 16.2 需要修订的旧结论

| 位置 | 旧说法 | 修订 |
|---|---|---|
| §3.1 / §12.13 | 无 root / `adb root` 走不通 | `adb root` 仍无效，但存在 `usrchan` root shell；“无法提权”改为“无法通过 adb root 提权” |
| §12.3 | 不 root 无法阻止 4 个广告包开机恢复 | root 可禁用，但厂商开机仍会恢复其中 3 个包，需要 boot guard（见合并版 §4.9）；`ottstatsv2` 是 PERSISTENT + system uid，禁用/隐藏会导致崩溃循环（实测 691 次/2 分钟），最终保持启用不处理 |
| §13.4 / §15.3 | 无 root 不能手动 `ip rule add` | root 下可以；日常仍建议走 TVPN 启停注册 |
| §4.7（合并版） | 极光桌面无法禁用 | root 下可禁用，但建议保留 APK 兜底 |
| §12.14 | 改系统只剩刷机/烧录 | 仍不建议改 `/system`：dm-verity 只读且仅剩约 2.9MB |

### 16.3 仍然成立的边界

- **不是 App 级 root**：普通应用无法执行 `usrchan`；
- **不是持久 root**：每次需口令，无常驻 su daemon；
- **不能随意改 `/system`**：`/` 为 dm-verity 只读，884MB 已用 881MB；
- **OTA 不能提权**：更新包由厂商 release key 签名，recovery 验签；当前 `persist.sys.hwconfig.soft_ver=85101`。

### 16.4 安全提示

`usrchan` 口令可由序列号推导，等同于厂商后门。任何能拿到 adb shell 的人都能提权，务必关闭不必要的 WiFi ADB，不要将 5555 暴露到不可信网络。

---

> 文档结束。后续优先看第 6 章（保活）、第 8 章（节点/DNS）、第 12 章（开机恢复链、最终状态、黑屏、内存治理、adb root 与 bootloader 实测）、第 13 章（Instagram Lite 横屏与登录）、第 14 章（TVPN/CarVPN 工程统一）、第 15 章（车机实机部署与 WiFi 上游测试）、第 16 章（本地 root 通道与结论修订）。
