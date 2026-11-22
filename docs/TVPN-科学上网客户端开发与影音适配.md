# TVPN 科学上网客户端：从 VPN 开发到影音适配与车机远程运维（电视 + 车机）

> 合并文档 · 2026-11-09（2026-11-14 增补电视端/车机 SSH 远程访问与密码哈希，见 §4.16 与 §5.5）
> 合并来源：
> - 《设计规格：车机 eSIM 轻量级分流代理客户端（car-esim-vpn）》2026-11-04
> - 《创维 Q6011（eros-p1）无 root 改造与 TVPN 部署记录》2026-11-07 ~ 2026-11-09
>
> 两份文档本质是同一条主线：**先做一个无 root 可用的分流 VPN 客户端，接入节点后再逐个适配视频/播放类应用，最终在电视和车机上实现稳定的科学上网。**
> 本文按这条主线重组；设备取证、反汇编细节保留在原文档中，本文只保留可复现的结论与命令。
>
> 文中订阅地址、节点域名、设备 stb_id、签名口令均以占位符表示，请勿把真实值写入任何公开仓库。

---

## 目录

1. [项目主线与目标](#1-项目主线与目标)
2. [技术路线与总体架构](#2-技术路线与总体架构)
3. [客户端实现：TVPN 1.1.0](#3-客户端实现tvpn-110)
4. [电视端部署与影音适配](#4-电视端部署与影音适配)
5. [车机端部署与影音适配](#5-车机端部署与影音适配)
6. [通用运维与排障](#6-通用运维与排障)
7. [结论与后续方向](#7-结论与后续方向)
8. [附录 A：usrchan 逆向记录与密码算法](#附录-ausrchan-逆向记录与密码算法)
9. [附录 B：关键脚本](#附录-b关键脚本)

---

## 1. 项目主线与目标

### 1.1 为什么要自己做 VPN 客户端

整件事的起点不是“翻墙工具”，而是**网络被中间盒选择性过滤**：

| 层 | 机制 | 表现 |
|---|---|---|
| DNS 域名级 | `.qq.com` 等子域被静默丢弃（裸域放行） | 解析不到正确 CDN |
| IP 级 | 命中名单的 CDN 节点伪造 RST | TCP 握手失败 |
| 传输层 | 明文 HTTP:80 按 Host 做 DPI | 请求被识别、限速或拉黑 |

腾讯系车机/电视应用大量使用明文 HTTP，App 内无法改为 HTTPS，**不在本地建隧道就无法绕过**。隧道封装后，上述三层过滤对被承载的流量全部失效。

同时，电视端没有 GMS，YouTube 官方客户端不可用；车机端需要让 X 浏览器等工具访问境外站点。于是需求统一为一件事：

> **做一个无 root、按应用分流、资源占用低的 VPN 客户端；接入可用节点后，再适配各平台的视频/播放工具。**

### 1.2 目标演进

1. 最初目标：电视去广告、降内存、禁用无风险预装；
2. 广告治理受限于厂商自恢复机制，只做到“可临时压制”；
3. 新需求：让电视能看 YouTube → 卸载 sing-box，基于自研 carvpn 做 TV 版 VPN；
4. 车机需求：同一套客户端 + 分流白名单，让 X 浏览器与 SmartTube 出海；
5. 最终形态：**单包名、单 APK、电视与车机共用**，差异只体现在白名单和节点选择上。

### 1.3 目标设备

| 项目 | 电视 | 车机 |
|---|---|---|
| 型号 | 创维 Q6011 / eros-p1 | ac83xx_evb（AutoChips AC8317） |
| Android | 10（SDK 29） | 6.0（SDK 23） |
| ABI | armeabi-v7a | armeabi-v7a |
| 内存 | 979 MB | 1.8 GB |
| 屏幕 | 1920×1080 | 1024×600 @240dpi |
| root | 无（dm-verity + 厂商改 adbd） | 无 |
| 特殊限制 | 厂商后台白名单、广告包自恢复、无 GMS | 系统较老，WebView 44 |

---

## 2. 技术路线与总体架构

### 2.1 无 root 约束

两台设备都拿不到 root：

- 无 `su`、无 Magisk；
- `/system` 为只读 dm-verity 分区；
- 厂商改写 adbd，`adb root` 返回自定义错误；
- bootloader 为全志精简 fastboot（协议 0.5），不支持标准 OEM 解锁。

因此客户端**只能走官方 `VpnService` API**，不能改系统路由、不能用 TPROXY、不能改 hosts。

> **2026-11-10 修订**：电视上发现厂商内置 su `/system/xbin/usrchan`，可获得 **adb shell 级 root**（见 §4.8）。
> 但 App 级 root（普通应用调用）和 `/system` 写入仍受限，客户端依旧按“无 root”设计。
> 本节以下关于“改系统路由 / TPROXY / hosts”的限制，对普通应用仍然成立；对 adb root shell 不再成立。

电视侧还多一层限制：厂商在 `services.jar` 里拦截了 shell 的 `pm disable/enable`，只能用 Binder 事务绕过（详见第 4 章）。

### 2.2 方案选型

对比后选择：**Java 薄壳 + native tun2socks + 本地 relay**。

| 方案 | 结论 |
|---|---|
| sing-box / 通用内核 | 30MB+，1GB 内存设备压力大，放弃 |
| 纯 Java 实现 | 协议栈与性能风险高，放弃 |
| **VpnService + hev-socks5-tunnel（JNI）+ 本地 relay** | **采用**：APK 约 240KB，内存可控，按包名分流现成 |

早期设计规格中的协议范围是 `ss / socks5 / http`，不支持 vmess/vless/trojan；实际落地后，主链路收敛为 **HTTP CONNECT + TLS 节点**，ss 仅作为历史方案保留在归档分支。

### 2.3 数据面

```text
被代理 App（SmartTube / X 浏览器 / Instagram）
        │ 普通 socket
        ▼
VpnService tun: 26.26.26.1/32
  DNS 26.26.26.2 · route 0.0.0.0/0 · MTU 1400
        │ tun fd
        ▼
hev-socks5-tunnel（JNI 线程，同进程）
        ▼
本地 relay（127.0.0.1）
        ▼
HTTP CONNECT 上游节点
  ├─ 普通节点：直接 CONNECT
  └─ TLS 节点：由本地 TlsUpstream 终结外层 TLS
```

DNS 不直连：tun 内 UDP/53 → relay → `CONNECT <resolver>:53` 转 DNS-over-TCP，并做污染检测。

### 2.4 关键设计决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | **按包名白名单，不做全局** | 官方 API 现成；壳自身流量不进 tun，无需 `protect()`；流量与内存双省 |
| D2 | DNS 走隧道远端 | 绕过域名级过滤；避免本地 DNS 污染 |
| D3 | tun2socks 以 JNI 线程跑在壳进程；relay 子进程隔离 | tun fd 免跨进程传递；relay 崩溃不影响 UI |
| D4 | 协议只做订阅里实际存在的类型 | 自研 vmess 风险过高，明确不做 |
| D5 | 早期用云端构建，后期本地 Gradle + NDK | 以实际维护便利为准 |
| D6 | 先跑通最小链路，再叠加订阅/DNS/保活 | 把最大风险前置验证 |

### 2.5 内存预算

早期目标 18–30MB RSS；实测电视端 TVPN 常驻约 **34MB PSS**（前台服务，Doze 白名单已加），仍在 1GB 设备可接受范围。

---

## 3. 客户端实现：TVPN 1.1.0

### 3.1 工程与包名统一

`carvpn-m1` 与 `tvpn-m1` 同源。长期并行会出现修复只落一侧、包名/签名漂移，因此统一为单主干：

| 项目 | 统一前 | 统一后 |
|---|---|---|
| 应用名 | CarVPN / TVPN | **TVPN** |
| applicationId / namespace | `com.sunjunior.caresimvpn` / `com.tvpn.client` | **`com.tvpn.client`** |
| versionCode / Name | 2 / 0.2.0；1 / 0.2.0 | **2 / 1.1.0** |
| 源码主干 | 两份 | `tvpn-m1`（`carvpn-m1` 只读归档） |

TV 专用项保留，车机上无副作用：

- `android:process="com.skyworthdigital.tvpn"`（命中创维白名单前缀）；
- `BootReceiver`（开机自启）；
- Leanback 入口与 TV banner。

JNI 注意：hev-socks5-tunnel 通过 `JNI_OnLoad` 运行时查找类名，包名宏在 `app/src/main/jni/Application.mk`：

```make
APP_CFLAGS += -DPKGNAME=com/tvpn/client -DCLSNAME=CarVpnTunnel
```

改包名只需同步改该宏并重编 native 库。

### 3.2 分流白名单与 UID 注册

白名单按**包名**配置，界面实时保存；但 `ip rule` 里的 UID 只在**启动代理时**注册一次。

```text
VpnService.Builder.addAllowedApplication(pkg) …
ip rule: … uidrange 10050-10050 lookup tun0
```

由此产生两条硬规则：

1. 修改白名单后必须 **停止代理 → 启动代理**，否则新应用不生效；
2. 应用重装后 UID 会变化，必须重新启停一次代理，无 root 不能手动 `ip rule add`。

电视侧实测白名单：`org.smarttube.stable,com.instagram.lite`
车机侧实测白名单：`com.mmbox.xbrowser,org.smarttube.stable`

### 3.3 节点选择：节点决定成败

同一客户端，不同节点结果完全不同（电视实测）：

| 节点 | DNS（CONNECT 53） | YouTube 播放 |
|---|---|---|
| 印尼 · TLS | ✅ | ❌ `SABR server requested a player response reload` |
| 日本 · TLS | ❌ `502 (resolver:53)` | ❌ |
| 台湾 · TLS | ❌ 节点不可达 | ❌ |
| **美国硅谷7 · TLS** | ✅ | ✅ 正常 |

结论：**固定使用「美国硅谷7」，关闭「自动选择最快可用节点」**，避免自动切回坏节点。车机也沿用同一节点。

### 3.4 构建与签名

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
- minSdk 21 / targetSdk 23，仅 `armeabi-v7a`；
- 证书 SHA-256：`6cef253333cc134dc8965a719f29b1d3d519aeccf93a2dca7d08595559397612`；
- 同签名可覆盖安装，保留数据与 UID。

早期完整流水线（debug 编 native → 拷贝 `.so` → release → zipalign → apksigner）见原文档附录 E。

### 3.5 开机自启与保活

这条链路踩了两个坑，最终都解决了：

**坑 1：厂商拦截第三方开机广播**

```text
E BroadcastQueue: Block auto start app from broadcast: com.tvpn.client
```

把进程名改为 `com.skyworthdigital.tvpn`，命中厂商默认前缀白名单后放行：

```text
V BroadcastQueue: Need to start app [background] com.skyworthdigital.tvpn ...
```

**坑 2：后台 `establish()` 一直返回 null**

根因在 `Vpn.establish()` 的前置判断：

```java
if (Binder.getCallingUid() != mOwnerUID) return null;
if (!isVpnUserPreConsented(mPackage)) return null;
```

`mOwnerUID` 是在 `VpnService.prepare()` 里登记的；开机由 BroadcastReceiver 直接起服务会跳过它。修复：

```java
// 建立隧道前先 prepare，把本应用登记为 VPN owner
if (VpnService.prepare(this) != null) {
    Log.e(TAG, "vpn permission not granted");
    stopSelfFail();
    return;
}
```

同时保留 `establish()` 失败重试（20 次 × 3 秒）。

**结果（2026-11-09 重启实测）**：

| 检查项 | 结果 |
|---|---|
| 开机广播 | `Start proc ... BootReceiver` |
| VPN 建立 | `Established by com.tvpn.client on tun0` |
| relay/TLS | `relay started ... 美国硅谷7 · TLS`、`tunnel start: true` |
| tun0 | `inet 26.26.26.1/32` |
| 分流规则 | 电视 10050 / 10058 自动恢复 |
| SmartTube | 首页与播放正常（tun0 RX 约 12.9MB） |
| Instagram | 未重新登录，信息流正常 |

---

## 4. 电视端部署与影音适配

### 4.1 无 root 边界与 Binder 绕过

电视固件在 `PackageManagerShellCommand` 里按 caller uid 拦截：

```java
if (Binder.getCallingUid() == 2000) {
    pw.println("Error: User no Permission !");
    return;
}
```

于是 `pm disable-user` / `pm suspend` / `pm hide` 全部失效。绕过方式是直接走 PMS Binder（shell 的 `CHANGE_COMPONENT_ENABLED_STATE` 权限是授予的）：

```bash
# 禁用整包
adb shell service call package 95 s16 <包名> i32 3 i32 0 i32 0 s16 com.android.shell
# 恢复整包
adb shell service call package 95 s16 <包名> i32 1 i32 0 i32 0 s16 com.android.shell
```

另外该机 `settings` 命令损坏，必须改用 `cmd settings`。

### 4.2 后台保活：厂商白名单签名

VPN 一切到前台应用就被杀：

```text
E ActivityManager: app not allow running background: com.tvpn.client ...
```

根因是 `ActivityManagerService.checkAllowBackgroundRunning()` 读取 `SkyworthConfig` 名单。名单值不是明文，需要 HMAC 签名：

```text
signature = hex_lower( HMAC_SHA1( key = persist.sys.hwconfig.stb_id,
                                 msg = Base64_NO_WRAP(list) ) )
```

写入 `Settings.System` 的 `com.skyworthdigital.backgroundwhitelist`，并同步更新 `Settings.Secure` 的 `com.forestdata.box` 签名；日志出现 `isInNameList check success` 即成功。

注意：`skycommonpropertymanager` 会定期重写名单，重启后可能需要重跑脚本。

### 4.3 广告包治理（已知不可根治）

8 个广告/统计包可被禁用，但其中 `ottstatsv2` 是 `PERSISTENT`，且 `skycommonpropertymanager` 会在开机后把同簇包重新拉起。实测连续两次重启都会恢复 4 个包，**不 root 无法根治**。

> 2026-11-10 更新：已有 root，其中 7 个包改由开机守卫压制（§4.9）；`ottstatsv2` 因 `PERSISTENT` + system uid，禁用/隐藏会导致开机崩溃循环，最终**保持启用、不处理**。

当前策略：PC 侧脚本 `fix-tv-adpackages.ps1`，每次重启后跑一次：

```text
am force-stop <pkg>
service call package 95 s16 <pkg> i32 3 i32 0 i32 0 s16 com.android.shell
```

同一章还记录了极光免费专区 90–120s 前贴片广告的黑洞实验：广告决策与正片共用域名/CDN，且 App 内置 HTTPDNS + native hook，**按域名/IP 拦截无效**。

### 4.4 SmartTube：4K60 VP9 导致间歇黑屏

现象：播放中随机全黑 0.5–2 秒，声音继续；4K 视频更明显。

排查结论：黑屏时 `screencap` 画面正常、HDMI 链路正常、温度正常 → 问题在解码器层。

根因：SmartTube 未限制清晰度时会选 **4K60 VP9（itag 315）**，该盒子硬解不支持：

```text
D MediaCodecInfo: NoSupport [sizeAndRate.support, 3840x2160x60.0]
W MediaCodecRenderer: Recovering from MediaCodec error,
                      re-initializing decoder (attempt 1/3)
```

修复：SmartTube → 设置 → 视频播放器 → 视频预设，从「禁用」改为 **1080p 30fps vp9**（不要选 2160p/1440p/HDR）。

验证后：不再出现 2160p60 配置与解码器重建，空闲 CPU 从 37% 恢复到 282%，free 内存 43MB → 59–62MB。

### 4.5 Instagram Lite：横屏、登录、播放卡死

**横屏补丁**：apktool 反编译官方 536，把 4 处 `screenOrientation="portrait"` 改为 `landscape`，删掉 `allowCrossUidActivitySwitchFromBelow`（否则编译失败），重签后安装。

**登录**：439 与 536 的密码登录、Facebook 登录都不可用（官方原版同样如此，排除改包因素）。可用路径：

```text
忘记密码 → 登录帮助 → 访问你的账户 → 发送邮件 → 输入验证码
```

**UID 重注册**：重装后 UID 变化（10056 → 10057 → 10058），必须「停止代理 → 启动代理」重新注册分流。

**视频卡死**：偶发解码器初始化后不取流，`gfxinfo` 帧数不增长、AudioTrack 为 idle。处理方式是强制停止 IG 或重启；已把息屏延长到 30 分钟降低触发概率：

```bash
adb shell cmd settings put system screen_off_timeout 1800000
```

**横竖屏双版本**：同签名横屏/竖屏包可直接覆盖切换，保留登录数据：

```bash
adb install -r docs/apks/instagram-lite-536-portrait-signed.apk   # 竖屏完整，左右黑边
adb install -r docs/apks/instagram-lite-536-landscape-signed.apk  # 横屏全屏，图片裁切
```

切换后首次启动可能布局异常，`am force-stop` 再打开即可。

### 4.6 IG 遥控器无障碍辅助

IG Lite 是触屏应用，遥控器方向键大部分场景无效。自建极小 APK `com.fix.igremote`（工程 `D:\AndroidDev\work\igremote`），只对 `com.instagram.lite` 生效：

| 按键 | 行为 |
|---|---|
| 下 | `ACTION_SCROLL_FORWARD`（优先），失败回退上滑 |
| 上 | `ACTION_SCROLL_BACKWARD`（优先），失败回退下滑 |
| 确定 | 点按屏幕中心（播放/暂停） |

要点：

- 优先用**无障碍滚动动作**，比触摸手势可靠（互动贴纸会吃掉触摸事件）；
- 600ms 防抖，避免连按叠加手势把翻页器卡住；
- 进程名 `com.skyworthdigital.igremote`，降低被系统清理概率；
- 只拦截 IG，其他应用不受影响。

```bash
adb shell cmd settings put secure enabled_accessibility_services com.fix.igremote/com.fix.igremote.IgKeyService
adb shell cmd settings put secure accessibility_enabled 1
```

重启后设置持久化、服务自动绑定，已实测。常驻内存约 11–13MB PSS。

### 4.7 替换极光桌面（2026-11-09）

极光桌面 `com.ktcp.launcher` 常驻约 **195MB PSS**，是电视上最大的一块内存。无 root 不能换系统，但可以换桌面。

> **2026-11-10 修订**：已发现 adb shell 级 root（见 §4.8），但 `/` 仍是 dm-verity 只读且只剩约 2.9MB，换桌面仍是当前最现实的减负方案；root 的可选收益是可以“永久禁用”极光而不是仅切换默认 HOME。

#### 厂商限制（实测）

| 机制 | 说明 |
|---|---|
| `cmd package set-home-activity` | 被厂商拦截：`Error: User no Permission !` |
| `pm disable-user com.ktcp.launcher` | 同样被拦截 |
| `service call package 95` 禁用 | 返回成功，但实际 `enabled=1`，对系统桌面无效 |
| `enable_launcher_components` + `com.forestdata.key3` | 控制“哪些包能作为桌面安装/启用”，**每次开机会被厂商重置签名** |
| `com.skyworthdigital.homewhitelist` + `com.forestdata.key` | **真正决定 HOME 归属**，开机不会被重置 |

结论：只改 `enable_launcher_components` 只能临时生效，重启后失效；要持久必须写 `homewhitelist`。

#### 落地步骤

1. 安装 FLauncher（开源、Android 5+、armeabi-v7a）：

```powershell
adb install -r flauncher-armeabi-v7a-release.apk   # me.efesser.flauncher, 2025.07.001
```

2. 把包名加入 `homewhitelist`，并按厂商算法重新签名：

```text
signature = hex_lower( HMAC_SHA1( key = persist.sys.hwconfig.stb_id,
                                 msg = Base64_NO_WRAP(homewhitelist) ) )
```

```bash
# 列表在 Settings.System，签名在 Settings.Secure
adb shell cmd settings put system com.skyworthdigital.homewhitelist \
  "com.skyworthdigital.sky2dlauncher/com.android.provision/com.ktcp.launcher/com.xiaopaitech.plauncher/me.efesser.flauncher"
adb shell cmd settings put secure com.forestdata.key <计算出的签名>
```

3. 设为默认 HOME：

```bash
adb shell cmd role add-role-holder android.app.role.HOME me.efesser.flauncher
adb shell input keyevent 3
```

#### 实测结果

| 指标 | 极光桌面 | FLauncher |
|---|---|---|
| 常驻 PSS | 195 MB | **59.5 MB** |
| 重启后保持 | — | ✅（`homewhitelist` 与签名均未被重置） |
| HOME 键 | — | ✅ 从任意应用返回 FLauncher |
| 后台进程 | 常驻 | 极光不再启动 |
| TVPN | — | ✅ 开机自启，`tun0 26.26.26.1/32` 正常 |

可再释放约 **135MB** 内存，且界面无推荐流/广告位。

#### 回滚

```bash
# 删除自定义列表，恢复厂商默认（默认包含极光与小派桌面）
adb shell cmd settings delete system com.skyworthdigital.homewhitelist
adb shell cmd settings delete secure com.forestdata.key
adb shell cmd role add-role-holder android.app.role.HOME com.ktcp.launcher
adb shell input keyevent 3
```

注意：

- 系统内置的 `com.xiaopaitech.plauncher`（小派桌面，约 118MB）也在默认白名单里，可作为“零配置”备选；
- `enable_launcher_components` 的签名 `com.forestdata.key3` 每次开机会被重置，但**不影响** `homewhitelist` 这条路径；
- 厂商 OTA 可能重置 `homewhitelist`，升级后需复查一次。

### 4.8 本地 root 通道：厂商内置 su `usrchan`（2026-11-10）

> 本节记录一次只读提权面扫描的实测结果。涉及设备安全边界，**请勿外传**。
> 文中不保存明文口令，只记录推导算法。

#### 发现

```text
-rwsr-x--- 1 root shell 15676 /system/xbin/usrchan
```

`usrchan` 是厂商预置的 su 实现，帮助信息与 AOSP `su` 一致：

```text
usage: su [WHO [COMMAND...]]
Switch to WHO (default 'root') and run the given COMMAND (default sh).
```

普通 shell 用户即可执行（属主 root、属组 shell、setuid 位），执行后要求输入密码。

#### 密码校验逻辑（反汇编还原）

关键函数：`checkpw(char*)`、`encrypt(std::string&)`、`android::base::GetProperty()`。

```c
// checkpw(input):
//   serial = GetProperty("ro.serialno", "");
//   if (serial 非空) {
//       encrypt(serial);
//       ok = strncmp(input, serial, min(serial.size(), 22)) == 0;
//   } else {
//       ok = strncmp(input, "skyworth", 8) == 0;
//   }

void encrypt(std::string& s) {
    for (size_t i = 0; i < s.size(); i++)
        s[i] = (uint8_t)(s[i] + i + 0x31);
    for (size_t i = 0; i < s.size(); i++)
        if ((uint8_t)s[i] >= 0x7b)
            s[i] = (uint8_t)(i + 0x61);
}
```

也就是说：

- 有序列号时，口令 = **`encrypt(ro.serialno)`**；
- 序列号为空时，口令回退为固定字符串 `skyworth`；
- 序列号长度按 22 字节截断。

#### 验证结果

```text
$ echo <按上述算法计算的口令> | /system/xbin/usrchan root id
uid=0(root) gid=0(root) groups=0(root),... context=u:r:su:s0
```

已确认的能力（只读验证）：

| 能力 | 结果 |
|---|---|
| `id` | uid=0(root)，SELinux 上下文 `u:r:su:s0` |
| 读取 `/data/data` | ✅（普通 shell 无权） |
| 修改系统设置/属性 | ✅（root 身份） |
| 绕过厂商 `pm disable-user` 拦截 | 预期可（拦截只针对 uid 2000，root 不受限） |
| 读取 OTA/应用私有数据 | ✅ |

#### 边界与风险

1. **不是 App 级 root**：`usrchan` 只对 root/shell 组可执行，普通应用（u0_aXX）无法调用；目前只在 adb shell 内可用。
2. **不是持久 root**：每次执行都要带口令；重启后仍可用，但没有常驻 su daemon。
3. **`/` 是 dm-verity 只读且几乎写满**：

   ```text
   /dev/block/dm-2 on / type ext4 (ro,...)
   884M 已用 881M，剩余约 2.9M
   ```

   因此 remount `/system` 安装常驻 su 不现实，且有触发 verity/无法开机的风险。
4. **口令可预测**：由 `ro.serialno` 推导，等于厂商后门。任何拿到 adb shell 的人都能提权。务必关闭不必要的 WiFi ADB，不要把 5555 暴露到不可信网络。
5. **正常 OTA 不能提权**：更新包由厂商 release key 签名，recovery 用 `/system/etc/security/otacerts.zip` 校验；即使 OTA 接口走 HTTP、只校验 MD5，改包仍会被 recovery 拒绝。当前软件版本 `persist.sys.hwconfig.soft_ver=85101`，即已经是 8.51.01。

#### 复现命令

```bash
# 1) 取序列号
adb shell getprop ro.serialno

# 2) 按 encrypt() 算法计算口令（示例：Python）
python -c "
s='<ro.serialno>'
out=[]
for i,c in enumerate(s):
    v=(ord(c)+i+0x31)&0xff
    if v>=0x7b: v=(i+0x61)&0xff
    out.append(chr(v))
print(''.join(out))
"

# 3) 执行 root 命令
adb shell "echo <口令> | /system/xbin/usrchan root id"
```

#### 可选的后续动作

| 方案 | 说明 | 风险 |
|---|---|---|
| A. 用 root 永久禁用极光桌面与广告/统计包 | `pm disable-user` 在 root 下可绕过厂商拦截 | 低，可 `pm enable` 回滚 |
| B. 在 `/data/local/tmp` 放一个 su 包装脚本 | 减少 adb 下重复输入口令 | 低，仅调试便利 |
| C. remount `/system` 安装常驻 su | 空间仅剩约 2.9MB，且需处理 verity | 高，不建议 |
| D. 保持现状 | 仅保留按需 root | 无 |

> 注意：如果后续执行 A，请先记录原 enabled 状态，便于回滚；系统包禁用后可能影响厂商语音/设置入口。

### 4.9 广告/统计包永久禁用（root + 开机守卫，2026-11-10）

#### 目标

处理 8 个系统级广告/统计包，最终结果是 **6 个整包禁用**、**1 个只禁用启动广告组件**、`ottstatsv2` 保持启用：

```text
整包禁用：
  com.tianci.ad
  com.skyworthdigital.logcollector
  com.skyworthdigital.autotest
  com.android.noticewidget
  com.skyworthdigital.ott.guide
  com.skyworthdigital.skycommonpropertymanager

只禁用组件（包本体必须保持可用）：
  com.skyworthdigital.ott.advert.app
    └─ 禁 .broadcast.AdvertBroadcastReceiver

保留（不压制）：
  com.skyworthdigital.ottstatsv2
```

> `ott.advert.app` 最初也在整包禁用名单里，但它负责厂商的“应用启动广告”管线，整包压制会让所有应用打不开，详见下面的“事故与修订”。

`ottstatsv2` 是 `PERSISTENT` + `sharedUserId=android.uid.system` 的统计上报进程。禁用/挂起/隐藏它都会导致开机崩溃循环，反而拖慢开机，最终决定不动它（见本节末尾）。

#### 第一次尝试：只做 disable/suspend（失败）

root 下执行：

```text
pm disable-user --user 0 <pkg>
pm suspend --user 0 <pkg>
am force-stop <pkg>
```

8 个包全部变成 `enabled=3`、`suspended=true`。但**重启后被厂商恢复**：

| 包 | 重启前 | 重启后 |
|---|---|---|
| `ottstatsv2` | disabled / suspended | **enabled=1 / suspended=false** |
| `skycommonpropertymanager` | disabled / suspended | **enabled=1 / suspended=false** |
| `ott.advert.app` | disabled / suspended | **enabled=1 / suspended=false** |
| `logcollector` | disabled / suspended | **enabled=1 / suspended=false** |
| `tianci.ad` / `autotest` / `noticewidget` / `ott.guide` | disabled | ✅ 保持禁用 |

原因：`ottstatsv2` 带 `PERSISTENT` 标志，`startPersistentApps` 不检查 enabled 状态，开机会被强行拉起；随后同簇包被重新启用。

反过来，一旦把它 `pm hide`，进程重启时 `Resources` 为 null，会触发 `NullPointerException`，AMS 又因 `PERSISTENT` 不停重启，形成崩溃循环（实测 2 分钟内 **691 次崩溃、5～7 次/秒、load average 3.2**）。所以这个包只能“放着不动”。

#### 最终方案：开机守卫

利用厂商自带的 root 启动脚本 `/data/xpclouddrive/run_clouddrive.sh`（system 所有、开机以 root 执行），在开头插入一行：

```sh
( sleep 90; /data/local/tmp/ads_guard.sh ) >/dev/null 2>&1 &
```

守卫脚本 `/data/local/tmp/ads_guard.sh`：

```sh
#!/system/bin/sh
LOG=/data/local/tmp/ads_guard.log
# 注意 1：不包含 ottstatsv2（PERSISTENT，压制会导致崩溃循环）
# 注意 2：不包含 ott.advert.app（它负责应用启动流程，压制会导致所有应用打不开，
#         见下方“事故与修订”；改为只禁用它的启动广告 receiver）
PKGS="com.skyworthdigital.skycommonpropertymanager com.skyworthdigital.logcollector com.tianci.ad com.skyworthdigital.autotest com.android.noticewidget com.skyworthdigital.ott.guide com.skyworthdigital.skywechatclient com.skyworthdigital.skyappupdate"

# PaiAdvert：包本身保持可用，只摘掉“应用启动插播广告”的拦截器
ADVERT_PKG=com.skyworthdigital.ott.advert.app
ADVERT_RCV=$ADVERT_PKG/.broadcast.AdvertBroadcastReceiver

while true; do
  for p in $PKGS; do
    pm disable-user --user 0 "$p" >/dev/null 2>&1
    pm suspend --user 0 "$p" >/dev/null 2>&1
    am force-stop "$p" >/dev/null 2>&1
  done

  pm enable "$ADVERT_PKG" >/dev/null 2>&1
  pm unsuspend --user 0 "$ADVERT_PKG" >/dev/null 2>&1
  pm disable --user 0 "$ADVERT_RCV" >/dev/null 2>&1

  echo "$(date) guard tick" >> "$LOG"

  # 日志自截断：超过 500 行只保留最近 200 行
  n=$(wc -l < "$LOG" 2>/dev/null)
  if [ -n "$n" ] && [ "$n" -gt 500 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
  sleep 120
done
```

开机 90 秒后开始，每 120 秒重新压制一次，抵消厂商的开机恢复。

#### 实测结果（重启 + 等待守卫执行）

| 检查项 | 结果 |
|---|---|
| 守卫日志 | `ads_guard.log` 出现重启后的 tick |
| 3 个易反弹包（`skycommon` / `advert` / `logcollector`） | `enabled=3`、`suspended=true` |
| 其余 4 个包 | 保持 disabled |
| `advert.app` / `logcollector` / `skycommonpropertymanager` 进程 | ✅ 已不存在 |
| `ottstatsv2` 进程 | 保持 `enabled=1`，正常运行，**不再压制**；PSS 约 14.7MB |
| 云桌面 | 仍为 FLauncher |
| clouddrive | ✅ 正常运行（钩子未破坏） |

#### 为什么最终不压制 `ottstatsv2`（实测）

它有三层保活，且无法在不破坏系统的前提下移除：

```text
1) flags=[ ... PERSISTENT ... ] + sharedUserId=android.uid.system
2) 自启动 Service OttStatsNewServiceV3（startRequested=true）
3) BootUpReceiver 监听 BOOT_COMPLETED / OBTAIN_ACTIVE_EVENT
```

实测 `pm hide` 后：

| 指标 | 数值 |
|---|---|
| 崩溃次数 | 2 分钟内 **691 次** |
| 崩溃频率 | 5～7 次/秒 |
| `load average` | 3.22 |
| 崩溃原因 | `Resources.getConfiguration()` NPE（隐藏包资源为 null） |
| CPU 连带 | `zygote` 9.4%、`system_server` 13%、`logd` 5.2% |

它会在开机阶段与 PMS、`system_server`、桌面抢 CPU，确实会拉长开机时间。回滚为 `enabled=1` 后重启实测：

| 指标 | 回滚后 |
|---|---|
| `ottstatsv2` 崩溃次数 | **0** |
| 开机到 `enable_screen` | 17.8s |
| 开机动画结束 | 18.1s |
| `load average` | 1.17 |

结论：**这个包保持启用、不压制**。它只做设备统计上报，不负责广告展示；广告包已由守卫处理。

#### 事故与修订：`ott.advert.app` 不能挂起（2026-11-10）

**现象**：点桌面上的“高清电视”（`com.jerry.livehd`）弹系统框：

```text
应用无法使用
小湃通目前无法使用。该应用是由root所管理。
```

**误判排除**：`dumpsys package` 显示 `com.jerry.livehd` 本身 `enabled=0`、`suspended=false`、`hidden=false`，没有被守卫碰到。

**定位**：弹窗来自系统 `android/com.android.internal.app.SuspendedAppActivity`，其任务记录里：

```text
mCallingPackage=com.skyworthdigital.ott.advert.app
launchedFromPackage=com.skyworthdigital.ott.advert.app
```

同时 `dumpsys package` 里 9 个包是 `suspended=true suspendingPackage=root`（正是守卫名单）。抓 logcat 得到完整因果链：

```text
PaiAdvert: [AdvertBroadcastReceiver] ACTION_APP_OPEN ---- mPackageName:com.jerry.livehd
ActivityManager: Force stopping com.jerry.livehd appid=10044 user=0: from pid <advert>
ActivityManager: app not allow running background: com.jerry.livehd ... otherApp has fg act: false
```

**根因**：`com.skyworthdigital.ott.advert.app`（PaiAdvert，`system` uid）是厂商**应用启动广告**管线的执行者，流程是：

```text
收到 ACTION_APP_OPEN
  -> am force-stop 目标应用
  -> 展示 ThirdPartyLoadingDialog（倒计时 15s 广告）
  -> 广告结束再拉起目标应用
```

守卫把它 `disable-user + suspend` 之后，广告放不出来，“再拉起”这一步也就永远不执行，于是**所有走这条管线的应用（实测 `mThirdPartyApps` 有 182 个）都表现为“应用无法使用”**，并弹出 `SuspendedAppActivity`。

**试过但无效**：改 `/data/data/com.skyworthdigital.ott.advert.app/shared_prefs/setting.xml` 里的 `appLaunchAble=0` / `isPreAppLaunchPaiAd=0`，广告仍在（素材与开关由服务端下发，本地值不生效）。

**最终修复**：包保持 `enabled + unsuspended`，只禁用它的广播接收器：

```sh
pm enable com.skyworthdigital.ott.advert.app
pm unsuspend --user 0 com.skyworthdigital.ott.advert.app
pm disable --user 0 com.skyworthdigital.ott.advert.app/.broadcast.AdvertBroadcastReceiver
```

该 receiver 监听：

```text
android.net.conn.CONNECTIVITY_CHANGE
android.intent.action.BOOT_COMPLETED
com.skyworthdigital.advert.START_UPDATE_TASK
android.intent.action.SCREEN_ON
com.android.usagestatus.action.start
```

禁用后既不再拦截应用启动，也顺带停掉了开机/亮屏的广告排期；`ScreenSaverService`（屏保广告）是独立组件，不受影响。

**修复后实测**：

| 检查项 | 结果 |
|---|---|
| 高清电视 | 4s 内直接进 `LiveActivity`，无插播广告，正常出画面 |
| 设置 / 桌面 | 正常，无 `SuspendedAppActivity` |
| `advert.app` 状态 | `enabled=1`、`suspended=false`、`disabledComponents=AdvertBroadcastReceiver` |
| 残留广告/统计进程 | 无 |
| TVPN | `tun0` 正常，进程未受影响 |

**注意**：

- `pm suspend` 的状态**会跨重启保存**在 PMS 里，所以一旦挂起过 `ott.advert.app`，即使守卫之后没跑，电视也会一直“应用无法使用”，必须显式 `pm unsuspend`。
- adb shell（uid 2000）执行 `pm unsuspend` 会返回 `Error: User no Permission !`，必须用 `usrchan` 拿 root（见附录 A）。
- 屏保仍是广告包自带 `ScreenSaverService`；如需彻底去屏保广告，需另行处理该组件。

#### 机制说明：`ott.advert.app` 不是“启动器”（2026-11-10）

容易误解成“这个包负责启动第三方应用，所以不能动”。**不是**。它只是厂商在启动路径上插的广告钩子。

**AOSP 原生启动路径**：

```text
桌面图标（普通 App） -> startActivity()
  -> ActivityTaskManagerService.startActivity（system_server）
  -> 解析组件 / 检查权限
  -> zygote fork 目标进程
  -> ActivityThread 启动 Activity
```

两个要点：

- 桌面（Launcher）只是声明了 `CATEGORY_HOME` 的**普通应用**，可以随意替换（所以换 FLauncher 能生效）；
- 系统里**没有**“所有应用都要经过的启动器服务”，任何应用都能 `startActivity`，AMS 只负责调度。

**厂商多出来的一层**：

```text
system_server（services.jar） -> 广播 com.android.usagestatus.action.start
  -> com.skyworthdigital.ott.advert.app
       .broadcast.AdvertBroadcastReceiver
  -> am force-stop 目标应用（防止它在广告后面先跑起来）
  -> ThirdPartyLoadingDialog 播 15s 广告
  -> 再 startActivity 把目标应用拉回来
```

所以准确说法是**“劫持启动”而不是“管理启动”**：先把目标杀掉，播完广告再替你重新启动。整包挂起等于把“重新启动”这一步也删掉了，应用自然打不开。

**设备实测证据**：

| 证据 | 结论 |
|---|---|
| `services.jar` 内同时含 `com.android.usagestatus.action.start` 与 `com.skyworthdigital.ott.advert.app` | 广播由**系统框架**发出，与桌面无关 |
| `/system/app/launcher/launcher.apk` 中搜不到 `ott.advert.app` | 换桌面躲不掉 |
| `adb shell am start`（完全不经过桌面）同样被拦截 | 拦截点在 framework，不在 Launcher |
| logcat `Force stopping ... from pid <advert>` | 是广告包自己调 `force-stop`，不是系统主动杀 |
| `mThirdPartyApps:size:182` | 广告包内置了 182 个“插广告”的应用名单 |

**广播语义（实测）**：

- **事件驱动、一条一次**：每次前台应用切换发一条，重复打开同一应用只是新事件，不是重发；
- **没有 ACK / 重试**：Android 广播是 fire-and-forget，`sendBroadcast` 入队一次、`BroadcastQueue` 处理一次，没有接收者就直接丢弃，不会反复发送，也不会超时重试（ordered broadcast 的 ANR 是接收者处理太慢，不是“没应答重发”）；
- **但它带 sticky 标记**：`dumpsys activity broadcasts` 的 `Sticky broadcasts for user 0` 下能看到 `Sticky action com.android.usagestatus.action.start`，值为 `Bundle[{pkgname=<最后打开的应用>}]`。AMS 只保留最后一条，**新注册的接收者会在注册时立刻收到这条旧事件**——这是唯一会“多收一次”的场景；
- 实测值变化：`me.efesser.flauncher` → `com.android.tv.settings` → `com.jerry.livehd`，之后静置 20s 不变，说明不是周期广播；
- 该 action 目前**不止一个消费者**：`com.skyworthdigital.ottstatsv2`（system uid）在运行时也注册了它，所以禁用广告包 receiver 后“并不是没人接”，只是广告链路不再被触发。

> 副作用提醒：如果以后重新 `pm enable` 该 receiver，它注册时可能立刻收到 sticky 的旧事件（上次打开的应用），从而补播一次广告。要避免的话，先在桌面（`pkgname=me.efesser.flauncher`）状态下启用。

#### 事故与修订：`pm suspend` 会让同 uid 应用全部静音（2026-11-10）

**现象**：极光桌面播视频完全没声音；但 SmartTube 同一个 HDMI 输出有声音。

**先排除掉的**：

| 检查 | 结果 |
|---|---|
| 系统媒体音量 | `STREAM_MUSIC 15/15`，`Muted: false` |
| 音轨 | `active`，PCM16/48k/立体声，L/R `0 dB`，`FrmRdy` 持续增长 |
| 输出链路 | codec `RUNNING`，DAPM `DAC/LINEOUT: On`，HAL 同时 `enable_ahub_hdmi_out` |
| 播放器设置 | 极光 prefs 里没有任何 mute/volume 项 |

**关键日志**：

```text
D AF::TrackHandle: OpPlayAudio: track:63 usage:1 muted
I AppOps: Audio disabled for suspended package=com.skyworthdigital.logcollector for uid=1000
```

`OpPlayAudio: ... muted` 在 AOSP 里的含义是 **AppOps `OP_PLAY_AUDIO` 检查未通过**（`hasAppOps ? "not " : ""`），AudioFlinger 会在混音阶段把这路音轨静音，所以音轨音量、数据流一切正常但就是没声音。

**根因**：`ads_guard.sh` 里用了 `pm suspend`。Skyworth 的系统包**共享 uid 1000**，AppOps 按 uid 反查包名时命中了被 suspend 的包（`logcollector` / `skyappupdate`），于是把这整个 uid 的音频播放判为“已挂起”并拒绝。

**修复**：

```sh
# 去掉 suspend，只保留 disable-user
pm disable-user --user 0 <pkg>
pm unsuspend --user 0 <pkg>     # 修复历史遗留
```

**验证**：同一视频重新起播后日志变为 `OpPlayAudio: track:80 usage:1 not muted`，扬声器恢复出声。

> **规则：对 uid 1000 的包永远不要用 `pm suspend`。** `disable-user` 已足够阻止其运行；`suspend` 会误伤同 uid 的音频 AppOps。
>
> 快速判据：**系统应用/极光没声音、SmartTube 有声音** → 先 `logcat | grep OpPlayAudio`，看到 `muted` 再 `logcat | grep "Audio disabled for suspended"`，基本可当场定位。

**附带澄清**：

- `com.skyworthdigital.igremote`（日志里 `IGREMOTE: event type=32 pkg=...`）是另一套应用使用统计监听，与广告无关，目前保留；
- `app not allow running background` 也不是 AOSP 行为，是厂商的后台管控。这就是广告包 `force-stop` 目标后，应用自己“爬”不回来的原因。

**结论**：原生 Android 只有 Launcher（桌面）+ AMS，没有“启动管理器”；`ott.advert.app` 是厂商在启动路径上加的广告钩子，禁用它的 receiver 后，启动走回原生路径。

#### 边界

- **`ottstatsv2` 只能保留**：`PERSISTENT` + system uid，禁用/挂起/隐藏都会引发崩溃循环；`/system` 只读且几乎写满，无法替换 APK。
- **只压制系统级广告/统计服务**：云视听等 App 的**前贴片广告**由 App 自身逻辑控制，与这批系统包无关，仍无法靠禁用系统包去掉。
- **OTA 风险**：厂商升级可能覆盖 `run_clouddrive.sh`，升级后需重新安装守卫。
- 备份：`/data/local/tmp/run_clouddrive.sh.bak`；守卫日志：`/data/local/tmp/ads_guard.log`。

### 4.10 ADB 固化与桌面救援

#### 当前 ADB 状态（实测）

| 项目 | 值 | 说明 |
|---|---|---|
| `adb_enabled` | 1 | USB 调试已开启，跨重启保留 |
| `development_settings_enabled` | 1 | 开发者选项已开启 |
| `persist.sys.usb.config` | `mtp,adb` | 开机默认带 adb |
| `persist.adb.tcp.port` | 5555 | WiFi ADB 端口已固化 |
| `ro.adb.secure` | 0 | 电脑连接**不需要**在电视上点“允许调试” |
| `adbd` 运行身份 | shell | 不是 root |
| `adb root` | 不可用 | adbd 被厂商改写，返回自定义错误 |

结论：

- **USB 调试 + WiFi ADB 已经固化**，重启后自动可用；
- **`adb root` 无法固化**，但可以用 `usrchan` 获得 root shell（§4.8）；
- 安全提示：`5555 + ro.adb.secure=0` 意味着同一局域网内任何人都能控制设备，**只在可信网络开启**，不用时建议关闭：

```powershell
A shell setprop persist.adb.tcp.port -1
A shell stop adbd
```

#### 桌面损坏时的救援流程

即使桌面无法进入，只要 adbd 在跑（开机即启动，与桌面无关）就能恢复：

```powershell
$Adb = 'D:\AndroidDev\android-sdk\platform-tools\adb.exe'
$Dev = '192.168.3.156:5555'

# 0) 重新连接（USB 或 WiFi）
& $Adb connect $Dev

# 1) 直接拉起系统设置（不依赖桌面）
& $Adb -s $Dev shell am start -n com.skyworthdigital.settings/.activity.MainActivity

# 2) 恢复极光桌面为默认 HOME
& $Adb -s $Dev shell cmd role add-role-holder android.app.role.HOME com.ktcp.launcher
& $Adb -s $Dev shell input keyevent 3

# 3) 如果 pm 被厂商拦截，用 root 执行
#    Invoke-Root "pm enable com.ktcp.launcher"
#    Invoke-Root "cmd role add-role-holder android.app.role.HOME com.ktcp.launcher"
```

如果改过桌面白名单，也可以直接删除自定义项回到默认：

```powershell
& $Adb -s $Dev shell cmd settings delete system com.skyworthdigital.homewhitelist
& $Adb -s $Dev shell cmd settings delete secure com.forestdata.key
& $Adb -s $Dev shell input keyevent 3
```

> 建议保留 USB 调试常开；如果担心 WiFi ADB 安全，可只关 WiFi 端口、保留 USB，这样桌面损坏时仍可用数据线救援。

#### 对既有结论的修订

`usrchan` 的发现不影响“客户端架构”，但推翻了此前几条“无 root 所以做不到”的判断：

| 旧结论 | 修订后 | 说明 |
|---|---|---|
| 无 root，不能禁用系统应用/阻止广告包恢复 | **root 可禁用，但需开机守卫** | `pm disable-user` 不受厂商 uid 拦截；其中 3 个包会在开机被恢复，需要 boot guard（见 §4.9）；`ottstatsv2` 是 PERSISTENT + system uid，压制会引发崩溃循环，**保持启用** |
| 无 root，不能手动 `ip rule add` | **root 下可手动加** | 日常仍建议用 TVPN「停止→启动代理」注册，避免规则漂移 |
| 极光桌面无法禁用 | **root 下可禁用** | 但仍建议保留 APK 作为兜底，先禁用验证 |
| `adb root` 走不通 | **仍然成立** | 但“adb root 命令无效”≠“无法提权”；`usrchan` 已提供 root shell |
| 不能改 `/system` | **仍然基本成立** | 有 root 但 `/` 是 dm-verity 只读且只剩约 2.9MB，remount 风险高、收益低 |
| OTA 可以用来提权 | **不成立** | OTA 包由厂商 release key 签名，recovery 验签；正常 OTA 无法注入 root |

一句话总结：**“没有 root”应改成“没有 App 级、持久化的 root；存在 adb shell 级 root 通道”。**

### 4.11 内存与后台服务优化（2026-11-10）

#### 现状（1GB 机型）

| 指标 | 数值 |
|---|---|
| Total RAM | 979 MB |
| Used RAM | 608 MB |
| Free RAM | 238 MB |
| MemAvailable | 347 MB |
| ZRAM/Swap | 总 734 MB，仅用约 6 MB |
| PSI memory | `full avg300=0` |
| 应用进程数 | 24 个 |

结论：**没有内存压力**，OOM 风险低；继续压 RAM 的收益有限，优化重点应放在“减少无用后台服务”。

#### 实际处理：只禁用 2 个

| 包 | PSS | 作用 | 状态 |
|---|---|---|---|
| `com.skyworthdigital.skywechatclient` | 13.4MB | 电视微信客户端（未使用） | `disabled` + `suspended` |
| `com.skyworthdigital.skyappupdate` | 12.5MB | 应用自动更新 | `disabled` + `suspended` |

两个包已加入 `ads_guard.sh` 的 `PKGS`，重启后由守卫维持禁用。

#### 明确保留的包

| 包 | PSS | 原因 |
|---|---|---|
| `com.skyworthdigital.settings` | 12.6MB | 桌面损坏时的救援入口 |
| `com.skyworthdigital.shortcutkeyssetting` | 14.0MB | 遥控器快捷键 |
| `com.android.syswidget` | 14.2MB | 系统小组件服务 |
| `com.skyworthdigital.softap` | 6.5MB | WiFi 热点/投屏 |
| `com.skyworthdigital.skymediacenter` | 16.9MB | 本地媒体中心，缓存态，内核可回收 |
| `com.xiaopaitech.paicd2` | 9.5MB | 语音助手，缓存态 |
| `com.skyworthdigital.mediarender` | 11.3MB | DLNA 投屏接收 |
| `com.skyworthdigital.upgrade` | 11.6MB | OTA 升级（保留升级能力） |
| `com.sohu.inputmethod.sogou.tv` | 27.4MB | 输入法，换轻量输入法收益约 15MB，风险大于收益 |
| `com.skyworthdigital.ottstatsv2` | 15.5MB | PERSISTENT，压制会崩溃循环（§4.9） |
| `tv.newtv.loginservice` | 7.9MB | PERSISTENT，登录服务 |

#### 验证结果（重启后）

| 检查项 | 结果 |
|---|---|
| 两个包状态 | `disabled` + `suspended`，无进程 |
| 守卫日志 | 重启后正常 tick |
| 开机到 `enable_screen` | 17.7s |
| 开机动画结束 | 18.0s |
| 桌面 | FLauncher 正常 |
| TVPN / clouddrive | 正常 |
| `isDefault` HOME | `me.efesser.flauncher` |

> 内存数字会随播放场景波动：SmartTube 播放时自身 PSS 约 175MB、WebView 沙箱 39MB、TVPN 37MB，属于正常现象，不是这次改动导致的。

#### 回滚

```powershell
Invoke-Root "pm enable com.skyworthdigital.skywechatclient"
Invoke-Root "pm enable com.skyworthdigital.skyappupdate"
```

同时从 `/data/local/tmp/ads_guard.sh` 的 `PKGS` 中移除这两项并重启守卫。

---

### 4.12 FLauncher 极光桌面入口与“退出即释放”（2026-11-10，已于 2026-11-11 下线）

> **本节状态：已下线。** 2026-11-11 起极光桌面改为**默认 HOME 并常驻**，入口 App `com.tvpn.auroraentry` 已卸载，`aurora_guard.sh` 已删除。
> 原因与实测数据见 **§4.12.9**；下文保留作为历史设计记录。

#### 需求

| 编号 | 需求 | 约束 |
|---|---|---|
| R1 | 默认桌面仍是 FLauncher | 不改 `HOME` 角色、不改 `homewhitelist` |
| R2 | 能从 FLauncher 手动进入极光桌面 | 极光保留为兜底，不卸载 |
| R3 | 退出极光桌面后内存必须完全释放 | 不能停留在后台 |

#### 4.12.1 为什么极光桌面不会出现在 FLauncher

腾讯极光桌面（`com.ktcp.launcher`）只声明了 `CATEGORY_HOME`：

```text
android.intent.action.MAIN
  Category: "android.intent.category.HOME"
  Category: "android.intent.category.DEFAULT"
  Category: "android.intent.category.MONKEY"
```

它**没有** `LEANBACK_LAUNCHER` / `LAUNCHER`，所以任何第三方桌面都不会把它当成普通应用列出来——这不是被禁用，直接 `am start` 完全正常。

#### 4.12.2 入口 App（`com.tvpn.auroraentry`）

一个约 6KB 的壳应用，点一次就跳到极光桌面然后立刻 `finish()`：

```java
public class EntryActivity extends Activity {
    private static final String PKG = "com.ktcp.launcher";
    private static final String CLS = "com.ktcp.launcher.activity.LauncherMainActivity";

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            Intent i = new Intent(Intent.ACTION_MAIN);
            i.addCategory(Intent.CATEGORY_HOME);
            i.setComponent(new ComponentName(PKG, CLS));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
        } catch (Exception e) {
            Toast.makeText(this, "无法打开极光桌面", Toast.LENGTH_SHORT).show();
        }
        finish();
    }
}
```

`AndroidManifest.xml` 关键点：

```xml
<application android:icon="@mipmap/ic_launcher" android:label="极光桌面">
    <activity android:name=".EntryActivity" android:exported="true"
              android:excludeFromRecents="true" android:noHistory="true"
              android:theme="@android:style/Theme.Translucent.NoTitleBar">
        <intent-filter>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent-filter>
    </activity>
</application>
```

图标直接复用极光桌面自己的 `res/drawable-xhdpi-v4/ic_launcher.png`，视觉上和原生入口一致。

> **坑 1：别加 `android:banner`。** 加了 banner 之后，FLauncher 的 Non-TV 卡片会按“横幅”渲染：图标铺满整张卡片、文字标签消失（只剩一个大 logo）。去掉 banner 才是标准的“小图标 + 文字”样式。
>
> **坑 2：`pm install` 后不要以为图标会立刻出现。** 见下一节，FLauncher 并不是实时枚举。

#### 4.12.3 真正的原因：FLauncher 用 SQLite 决定显示什么

FLauncher 的 Java 侧只是把系统查询结果喂给 Flutter：

```java
private java.util.List z(boolean launcher) {
    return getPackageManager().queryIntentActivities(
        new Intent(Intent.ACTION_MAIN).addCategory(
            launcher ? Intent.CATEGORY_LAUNCHER : Intent.CATEGORY_LEANBACK_LAUNCHER), 0);
}
```

`getApplications` 返回后，Flutter 侧写入 `/data/data/me.efesser.flauncher/app_flutter/db.sqlite`：

| 表 | 作用 |
|---|---|
| `apps` | 包名、名称、版本、`hidden` 标记 |
| `categories` | 行（1 = TV Applications，2 = Non-TV Applications） |
| `apps_categories` | **哪个应用在哪一行、第几位** |
| `launcher_spacers` | 行间留白 |

**只进了 `apps`、没有 `apps_categories` 行 = 永远不会显示。** 实测安装后 `apps` 里已经有 `com.tvpn.auroraentry`，但 `apps_categories` 是空的，所以桌面看起来“装了但没出现”。

补登记（`category_id=2` 即 Non-TV Applications）：

```sql
insert into apps_categories(category_id, app_package_name, "order")
values (2, 'com.tvpn.auroraentry', 6);
```

> **坑 3：每行只显示 5 个，超出的要按遥控器右键横向滚动。** `categories.columns_count` 写的是 6，但 1920 宽下实际只排 5 张卡片。新加的应用排在行尾时，必须先把焦点移到那一行再按右键才会看到——这也是一开始“明明加进去了却找不到”的原因之一。

安全改库步骤（**必须先停桌面**，否则 WAL 会回写覆盖）：

```powershell
A shell am force-stop me.efesser.flauncher
Invoke-Root "cp /data/data/me.efesser.flauncher/app_flutter/db.sqlite* /data/local/tmp/; chmod 666 /data/local/tmp/db.sqlite*"
A pull /data/local/tmp/db.sqlite  flauncher.db
A pull /data/local/tmp/db.sqlite-wal flauncher.db-wal
A pull /data/local/tmp/db.sqlite-shm flauncher.db-shm
# 本地用 sqlite3 执行上面的 insert，然后 PRAGMA wal_checkpoint(TRUNCATE)
A push flauncher.db /data/local/tmp/db.new
Invoke-Root "cd /data/data/me.efesser.flauncher/app_flutter && rm -f db.sqlite-wal db.sqlite-shm && cp /data/local/tmp/db.new db.sqlite && chown u0_a38:u0_a38 db.sqlite && chmod 600 db.sqlite && restorecon db.sqlite"
A shell input keyevent 3
```

> 重新安装入口 App 不会丢这一行（主键是包名，包名不变）；只有卸载才会因为外键 `ON DELETE CASCADE` 一并删除。

#### 4.12.4 退出即释放：`aurora_guard.sh`

实测问题：按 HOME 回 FLauncher 后，`com.ktcp.launcher` 的 **PID 不变**，RSS 仅从 258MB 降到 249MB，仍在后台常驻。

方案：root 常驻脚本，事件触发 + 复核 + `am force-stop`。

```text
on_resume 事件 → 等 3s → dumpsys 看真实前台
                     ├─ 是 com.ktcp.launcher：不动（视频播放也在该进程内）
                     └─ 不是：pidof 存在则 am force-stop
```

关键设计：

| 决策 | 原因 |
|---|---|
| 触发器用 `am_on_resume_called`，不用 `am_resume_activity` | 本 ROM 上 `am_resume_activity` 记录严重缺失（实测 13:20 之后所有真实切换都没写进 events buffer），会漏事件；`am_on_resume_called` 每条都有 |
| 不直接根据事件里的类名判断 | 极光视频的 Activity 类名是 `com.ktcp.video.*`，与 launcher 前缀不同，容易误判；统一用 `dumpsys activity activities` 里的 `mResumedActivity` 复核 |
| 只在前台不是 `com.ktcp.launcher` 时杀 | 视频播放时前台仍是该包，不会被误杀 |
| `aurora_guard.pid` 单实例 | 避免多个 logcat 监听重复 force-stop |
| logcat 退出后 10s 重连 | 防止 logd 重启导致守卫静默失效 |

完整脚本见 [B.9](#b9-极光桌面守卫脚本aurora_guardsh)。

#### 4.12.5 开机自启：`sky_check` 钩子（走过的弯路）

先纠正一个此前的错误结论：**`/data/xpclouddrive/run_clouddrive.sh` 并不是开机钩子。**
init 里虽然有：

```text
service start_clouddrive /system/bin/sh /data/xpclouddrive/run_clouddrive.sh
    user root
    group root
    disabled
    oneshot
    seclabel u:r:su:s0
```

但它是 `disabled`，没有任何 `on property:`/`class_start` 触发它。实测重启后 `clouddrive` 与 `ads_guard` 都没有起来——此前“重启后守卫正常 tick”的观察，实际是手动启动留下的进程。

失败过的方案：

| 方案 | 结果 |
|---|---|
| 在 `/system/etc/init/` 新增 rc/脚本 | ❌ `/system` 已 100% 满（904MB，仅剩 2.9MB），写 1KB 都 `ENOSPC`；删掉 5MB 的 `recovery-resource.dat` 后依然写不进（空闲块位图异常） |
| 新增 `/system/bin/install-recovery.sh` | ❌ `flash_recovery` 服务实际未被启动 |
| 接管 `appsdisable`（boot_completed 触发） | ❌ 服务带 `seclabel u:r:shell:s0`，init 执行时报 `security_bounded_transition denied` → `cannot execve: Permission denied` |
| 入口 App 的 `BOOT_COMPLETED` + 前台服务 | ❌ 厂商按“无前台 Activity”立刻杀；且普通 App 杀不掉 uid 1000 的极光桌面 |

最终方案利用两个特性：

1. **符号链接只占元数据，不占数据块**，所以在写满的 `/system` 上仍能创建；
2. init 的 `sky_check` 服务满足全部条件：

```text
service sky_check /system/bin/sh /system/bin/sky_check.sh
    user root
    group root
    disabled
```

- `on property:sys.boot_completed=1` 时 `start sky_check`（`/init.rc:819`）
- **没有 `seclabel`**，不会触发 bounded transition
- 以 root 运行，`am force-stop` 可用
- 此时 `/data` 已挂载

落地：

```sh
# 原脚本保留并继续运行
cp /system/bin/sky_check.sh /data/local/tmp/sky_check.sh.bak
mv /system/bin/sky_check.sh /system/bin/sky_check.sh.orig
ln -sfn /data/local/tmp/boot.sh /system/bin/sky_check.sh
```

`boot.sh` 负责：后台运行 `sky_check.sh.orig`（保留系统监控）、拉起 `ads_guard.sh` 与 `preroll_guard.sh`，最后 `wait` 常驻——**不能直接退出**，否则 oneshot 服务结束时子进程可能被回收。

> `aurora_guard.sh` 已于 2026-11-11 下线（见 §4.12.9），`boot.sh` 中不再包含该段。

完整脚本见 [B.10](#b10-开机钩子脚本bootsh)。

手动启动（脱离 adb shell）：

```powershell
Invoke-Root "nohup sh /data/local/tmp/boot.sh >/dev/null 2>&1 &"
```

#### 4.12.6 验证结果

| 步骤 | 结果 |
|---|---|
| FLauncher 点击“极光桌面”卡片 | 正常进入 `LauncherHomeSingleTaskActivity` |
| 极光桌面停留 12s | 未被误杀（RSS ≈ 286–296MB） |
| 按 HOME 回 FLauncher | 约 3s 后 `am force-stop`，进程消失 |
| `MemAvailable` | 273MB → 397MB（另一次 365MB → 431MB） |
| 极光视频播放中按 HOME | 按设计同样释放（前台已不是极光桌面） |
| **重启后** | `init.svc.sky_check=running`，`boot.sh` → `sky_check.sh.orig` + `ads_guard.sh` + `preroll_guard.sh` 全部自动拉起 |

> 下表进程树是 2026-11-10 的版本，`aurora_guard` 已于 2026-11-11 移除。
| 重启后再次进/退极光 | 260MB → 3s 内释放，`MemAvailable` 399MB |

重启后的进程树：

```text
2843  1     sh /system/bin/sky_check.sh          # -> /data/local/tmp/boot.sh
2860  2843  sh /system/bin/sky_check.sh.orig
2865  2843  sh /data/local/tmp/aurora_guard.sh
2866  2843  sh /data/local/tmp/ads_guard.sh
2876  2865  sh /data/local/tmp/aurora_guard.sh   # logcat 管道子进程
```

日志样例：

```text
11-10 13:25:59 left com.ktcp.launcher (pid 1751) -> force-stop
11-10 13:26:00 released; MemAvailable=390712 kB
```

#### 4.12.7 系统改动与厂商白名单（重要）

**白名单签名算法**（实测有效）：

```text
signature = hex_lower(HMAC_SHA1(key = persist.sys.hwconfig.stb_id,
                                msg = Base64_NO_WRAP(list)))
```

当前写入值：

| 设置项 | 命名空间 | 当前值 |
|---|---|---|
| `com.skyworthdigital.backgroundwhitelist` | System（完全匹配） | `com.tvpn.auroraentry/com.tvpn.client/me.efesser.flauncher`（`auroraentry` 已卸载，留名无害） |
| `com.forestdata.box` | Secure | 对应签名 |
| `enable_running_backgroud_components` | Secure（前缀匹配） | 原厂列表去掉 `/com.ktcp.launcher`，追加 `/com.tvpn` |
| `com.forestdata.box3` | Secure | 对应签名 |

目的：

- 入口 App 与 FLauncher 在后台不被厂商策略杀；
- **刻意把 `com.ktcp.launcher` 移出白名单**，让系统也可能回收它（释放仍以 root `force-stop` 为准）。

> 注意：一旦 `backgroundwhitelist` 的签名有效，它会**覆盖**该 key 的内置基础表。实测只写入口 App 时 FLauncher 被当场杀掉，所以必须把 FLauncher 一起写进去。

**系统文件改动清单**：

| 路径 | 改动 | 影响 |
|---|---|---|
| `/system/bin/sky_check.sh` | → `/data/local/tmp/boot.sh` 的符号链接；原脚本存为 `.orig` 并继续运行 | 无 |
| `/system/bin/install-recovery.sh` | → `boot.sh` 的符号链接 | `flash_recovery` 实际不触发，无影响 |
| `/system/etc/init/atrace_userdebug.rc` | 变 0 字节（原内容备份 `/data/local/tmp/atrace_userdebug.rc.bak`） | 仅调试 tracing 权限缺失 |
| `/system/etc/recovery-resource.dat` | 已删除（5MB） | OTA recovery 补丁流程失效，日常无影响 |

> `/system` 曾 100% 占满且空闲块位图异常（删文件后 `df` 有空间仍 `ENOSPC`）。
> 2026-11-11 移除预装小湃桌面（16 MB）后已恢复可写，`atrace_userdebug.rc` 原内容也已写回，
> 见 Q6011 §5.8。

#### 4.12.8 回滚

> 其中 1、2、4 步已在 2026-11-11 下线时执行（见 §4.12.9）。

```powershell
# 1) 去掉桌面图标（也可在 FLauncher 设置里删）
Invoke-Root "sqlite3 /data/data/me.efesser.flauncher/app_flutter/db.sqlite \"delete from apps_categories where app_package_name='com.tvpn.auroraentry'\""
A shell am force-stop me.efesser.flauncher

# 2) 停守卫
Invoke-Root "pkill -f boot.sh; pkill -f aurora_guard.sh; pkill -f ads_guard.sh; rm -f /data/local/tmp/aurora_guard.pid"

# 3) 去掉开机自启（恢复 sky_check 原脚本）
Invoke-Root "rm -f /system/bin/sky_check.sh && mv /system/bin/sky_check.sh.orig /system/bin/sky_check.sh"

# 4) 彻底卸载入口 App
A uninstall com.tvpn.auroraentry
```

#### 4.12.9 下线：极光改回默认桌面并常驻（2026-11-11）

**决策依据**：前贴片已拦（§4.13），极光桌面的“内容入口”价值回升；FLauncher+入口 App 的组合反而多一层跳转。

**内存实测**（1 GB 机型，三件套同时运行）：

| 场景 | MemAvailable | SwapFree | 备注 |
|---|---|---|---|
| FLauncher 为桌面（基线） | 437 MB | 620 MB | 极光未运行 |
| 极光桌面前台（首页加载完） | 350 MB | 599 MB | 极光 RSS 310 MB |
| 极光后台 + SmartTube 前台 + TVPN | 295 MB | 541 MB | 极光 264 MB / SmartTube 241 MB / TVPN 57 MB |
| 极光作默认 HOME（重启后） | 393 MB | 750 MB | FLauncher 不再运行 |

全程**没有 LowMemoryKiller，也没有 ActivityManager 主动杀进程**（日志里只有 `empty` 级清理）。结论：1 GB 内存可以承受极光常驻。

**改动**：

| 项目 | 处理 |
|---|---|
| 默认 HOME | `cmd package set-home-activity com.ktcp.launcher/.activity.LauncherMainActivity`（需 root，shell 直接执行报 `User no Permission`） |
| `com.tvpn.auroraentry` | `pm uninstall` 卸载；FLauncher 数据库里对应行同步删除 |
| `aurora_guard.sh` | 停止并从 `/data/local/tmp` 删除；`boot.sh` 中移除启动段 |
| `preroll_guard` | 保留。极光是 HOME，开机即运行，守卫在启动后自动注入 |

**为什么不能沿用“离开即杀”**：极光变成 HOME 后，`aurora_guard` 会在每次打开其它应用时把它 force-stop，按 HOME 就要冷启动 3–5 秒并重新加载 ~300 MB，体验不可接受。

下线前 `aurora_guard.sh` 已加入 `is_default_home()` 判断（默认桌面时只在 `MemAvailable < 120 MB` 才回收），但既然常驻无压力，最终选择直接移除整个脚本。

验证（重启后）：

```text
默认 HOME           com.ktcp.launcher/.activity.LauncherMainActivity
前台                LauncherHomeSingleTaskActivity
极光 RSS            308 MB，pid 2996
MemAvailable        393 MB（SwapFree 750 MB）
preroll_guard       injected pid=2996 rc=0
aurora_guard        已不存在
打开 SmartTube 后按 HOME：pid 仍为 2996，秒回桌面（无冷启动）
```

**后台日志策略**（2026-11-11 补齐截断）：

| 日志 | 写入频率 | 截断规则 |
|---|---|---|
| `ads_guard.log` | 每 120 s 一行 | > 500 行 → 保留最近 200 行 |
| `boot.log` | 每次开机 3 行 | > 2000 行 → 保留最近 500 行 |
| `preroll_guard.log` | 仅在 pid 变化时 | > 2000 行 → 保留最近 500 行 |

三个日志都有上限，长期运行不会持续占用存储。

---

### 4.13 极光免费专区前贴片/中插/暂停/后贴片广告拦截（2026-11-10，2026-11-11 扩展）

#### 4.13.1 结论先行

前贴片/中插/暂停/后贴片**无法在网络层屏蔽**（详见 Q6011 §5.7 的否定实验），但可以在**运行时**干净地关掉：

> 挂钩 `com.tencent.ads.view.c.a(AdRequest)`，当
> `adType` 为 `1`（前贴片）、`2`（暂停）、`3`（后贴片）、`4`（中插）时返回 `ErrorCode(143)`。
> 这是 SDK 自己的“无广告”返回值，调用方 `PlayerAdView.a()`
> 会走 `fireFailedEvent()` 并直接继续正片。

实测效果：

| adType | 类型 | 状态 |
|---|---|---|
| 1 | 前贴片 | ✅ 实测 `block preroll #1/#2` |
| 2 | 暂停 | ✅ 实测 `block pause #3` |
| 3 | 后贴片 | ⚠️ 代码已覆盖，尚未播到片尾实测 |
| 4 | 中插 | ✅ 实测 `block midroll #3/#4` |

角标/挂件（5/6/9/15/16/19/20）不在此处拦截；其中 19（THLS）是服务端拼接进 HLS，客户端 hook 去不掉。

> **2026-11-11 修正**：第一版只拦了 `adType == 1`，漏掉了中插
> `QAdMidVideoImpl.getAdType() == 4`。设备日志里 21:44:29–21:45:39 有一段
> 约 70 秒的 `QAdMidVideoImpl` 播放，证实了这一点。详见 §4.13.9。
> 随后把暂停（2）和后贴片（3）一并加入命中集合；暂停已实测，后贴片待片尾验证。

#### 4.13.2 为什么是这个方法（调用链证据）

抓栈得到真实调用链（`adb` 侧 Frida 挂 `view.c.a` 打印 `Throwable`）：

```text
QAdPreVideoImpl.loadAd            ← TVK 桥接层：前贴片入口
└─ QAdBaseVideoImpl.loadAd
   └─ AdView.loadAdImpl           ← 选择 new/old AdView，旧版会兜底
      └─ videoad.h.loadAd
         └─ PlayerAdView.loadAd
            └─ PlayerAdView.d
               └─ preroll.e.a     ← 前贴片控制器
                  └─ videoad.h.a
                     └─ PlayerAdView.a
                        └─ com.tencent.ads.view.c.a(AdRequest)   ← 唯一“是否允许出广告”的门
```

`PlayerAdView.a()` 中的判定逻辑（反编译复原）：

```java
com.tencent.ads.view.ErrorCode e = new com.tencent.ads.view.c().a(adRequest);
if (e != null) {
    fireFailedEvent(e);   // 走“广告失败”，播放器继续放正片
}
```

同文件里还有两条同样风格的早退分支（小窗 `121/22002`、悟空 `120/22003`），说明“返回 ErrorCode 即跳过广告”是官方设计路径，不是硬改逻辑。

中插走的是同一条“门”，入口换成 `QAdMidVideoImpl`：

```text
QAdManager.handleMidVideoAd(Object)     ← 播放器到达中插断点
└─ QAdMidVideoImpl.loadAd(QAdBreakTimeInfo)
   └─ QAdBaseVideoImpl.loadAd
      └─ AdView.loadAdImpl
         └─ midroll.b.loadAd           ← 继承 videoad.h
            └─ PlayerAdView.a
               └─ com.tencent.ads.view.c.a(AdRequest)   ← adType == 4
```

`QAdMidVideoImpl` 的 adType 归属（反编译）：

```java
@Override
public int getAdType() {
    return 4;          // TYPE_MIDROLL
}
```

设备日志（2026-11-11 21:44–21:45）也抓到了完整的中插播放：

```text
21:44:29  Mosaic-JS-Engine / QuickJS 开始加载创意
21:45:39  QAdBaseVideoImpl.handleAdPlayerComplete
21:45:40  QAdMidVideoImpl.release
```

从 21:44:29 到 21:45:39 约 70 秒，与用户看到的“70s 中插”一致。

`com.tencent.ads.view.c.a()` 内部依次检查：崩溃恢复、`playerScenes` 场景（免费专区场景位）、连播、贴片频次。**本机 `playerScenes` 实测为空集合**，所以配置开关 `scenePreRollDisabled` 永远不生效——这也是“改配置无效”的根本原因。

#### 4.13.3 为什么不用改配置/改包

| 方案 | 结论 |
|---|---|
| 改 `ads.service.AdConfiguration` 的 `ad=false` | ❌ 该键走老链路；且被 `SharedPreferencesHooker` 接管成 MMKV，写 XML 无效 |
| 改广告 SDK 配置 XML（`files/ad_cache/1`）里的 `/root/controller/scenePreRollDisabled` | ❌ 默认值本来就是 `true`，但场景集合为空，判断根本不触发；且配置会被服务端刷新覆盖 |
| 返回 `null` 让 `createNewAdView` 失败 | ❌ `AdView.loadAdImpl` 会**兜底到旧版 AdView**，广告照播（见源码 479–496 行） |
| 重打包 APK | ❌ `sharedUserId=android.uid.system` + 平台签名，重签会丢系统特权（详见 Q6011 §5.7） |
| **运行时 hook `view.c.a()`** | ✅ 已验证 |

#### 4.13.4 设备端自持注入（不依赖 PC）

PC 端 Frida 只能临时验证。要长期生效，用 frida 官方提供的 **`frida-inject`**：

- 它运行在设备上、以 root 注入目标进程，**不需要 `frida-server`**；
- `-e/--eternalize` 让脚本常驻，注入器进程退出后 hook 仍在；
- 进程重启（或被系统回收）后 hook 自然消失，守卫会在新 pid 出现时重新注入（实测换 pid 后自动重注入）。

关键点：hook 只在**起播那一刻**被调用（`PlayerAdView.a()`），所以不要求开机瞬间注入，应用起来后任意时刻注入都有效。

相关文件：

| 路径 | 作用 |
|---|---|
| `/data/local/tmp/frida-inject` | 设备端注入器（22 MB，仅存磁盘，不常驻） |
| `/data/local/tmp/preroll_block.js` | hook 脚本（`view.c.a`：`adType` 1/2/3/4 返回 143） |
| `/data/local/tmp/preroll_guard.sh` | 守护：轮询 `pidof com.ktcp.launcher`，新 pid 就注入并记日志 |
| `/data/local/tmp/preroll_guard.log` | 注入日志（自动截断，保留最近 500 行） |

`boot.sh` 已在拉起 `ads_guard` 之后追加（极光已是默认 HOME，开机即运行，守卫启动后自动注入）：

```sh
if [ -x /data/local/tmp/frida-inject ] && [ -r /data/local/tmp/preroll_block.js ]; then
    sh /data/local/tmp/preroll_guard.sh >/dev/null 2>&1 &
fi
```

#### 4.13.5 部署

```powershell
A push frida-inject       /data/local/tmp/frida-inject
A push preroll_block.js   /data/local/tmp/preroll_block.js
A push preroll_guard.sh   /data/local/tmp/preroll_guard.sh
Invoke-Root "chmod 755 /data/local/tmp/frida-inject /data/local/tmp/preroll_guard.sh"
Invoke-Root "sh /data/local/tmp/preroll_guard.sh >/dev/null 2>&1 &"
```

> `frida-inject` 与主机端 frida 版本要一致（本次用 `16.7.19`，arm）。
> 版本不一致时注入会报协议错误；此时换同版本二进制即可，脚本本身不改。

#### 4.13.6 验证

```powershell
Invoke-Root "tail -5 /data/local/tmp/preroll_guard.log"
# 期望：injected pid=<pid> rc=0

A shell input keyevent 23      # 在极光首页选中「走马上任」并播放
A shell screencap -p /sdcard/v.png
```

三次验证均通过：

| 场景 | 结果 |
|---|---|
| PC 端 Frida 临时注入 | 起播 4 s 已在正片，日志 `[preroll] blocked #1` |
| `frida-inject -e` 注入后关闭注入器 | 仍生效（脚本常驻） |
| **整机重启** | `init.svc.sky_check=running`，`preroll_guard` 自动拉起，极光进程 4132 自动注入，起播直接进正片 |
| **中插（2026-11-11）** | `adType=4` 命中后返回 143，播放器继续正片；日志 tag `TVPNAdHook` |

中插的验证日志：

```powershell
A shell logcat -d -v time | findstr /C:"TVPNAdHook"
# 期望：block midroll #N cid=...
```

开销：极光进程 RSS 296 MB（注入前 301 MB），无可见增长；`preroll_guard.sh` 是纯 shell 轮询，每 2 s 一次 `pidof`。

#### 4.13.7 副作用与回滚

- 拦 `adType == 1/2/3/4`：前贴片、暂停、后贴片、中插；
- 不处理角标/挂件（5/6/9/15/16/19/20）；其中 19（THLS）是服务端拼接进 HLS，客户端 hook 去不掉；
- 广告位缺失时播放器走 `fireFailedEvent`，不弹错误、不卡起播（实测）；
- 应用升级若把 `view.c` / `PlayerAdView.a()` 改名，hook 静默失效 → 广告恢复，不会崩；

回滚：

```powershell
Invoke-Root "pkill -f preroll_guard.sh; rm -f /data/local/tmp/preroll_guard.pid"
# boot.sh 里注释掉 preroll_guard 段即可（或删两个文件，boot.sh 会跳过）
```

> 风险提示：这是运行时注入，依赖 `frida-inject` 能在该进程上工作。
> 若某次系统升级后注入失败，表现只是“广告回来了”，其它功能不受影响。

#### 4.13.8 频次控制要不要处理？——不需要，但它是验证陷阱

App 里确有频控：`com.tencent.ads.view.c.c()`（`view.c.a()` 内部调用）里有

```java
if (adType == 1 || adType == 3) {
    long gap = (now - AdConfig.getInstance().M()) / 1000;
    if (gap > 0 && gap < AdConfig.getInstance().x()) {
        return new ErrorCode(206, "Frequency control.")
            .setSplashErrorCode(22018, "disable preroll ad because of frequency control");
    }
}
```

结论：

1. **不需要单独处理**。它位于 `c()` 内部，在我们的 hook 之后；hook 已经无条件返回 143，频控根本没机会执行。频控只会“少放广告”，不会“绕过 hook”。
2. **不要试图把它改成“永久命中”**。它依赖 `AdConfig.M()`（上次出广告时间）与 `x()`（间隔秒数），这两个值会被服务端配置刷新；改本地值不稳定，而且同样需要运行时注入——成本一样，效果还不如直接拦门函数。
3. **它是验证陷阱**。频控生效时，连续两个视频都不出广告是“正常现象”，与屏蔽手段无关。本次排查早期就吃过这个亏（封域名后“看起来没广告”，其实只是频控窗口）。

因此验证必须按“**单次起播**”判断，而不是“连试几次”：

| 判据 | 含义 |
|---|---|
| 起播后 4–6 s 截图是否已在剧情 | ✅ 可靠 |
| hook 日志 `TVPNAdHook: block preroll #N` | ✅ 可靠（说明门函数被命中并拦截） |
| 连试 2–3 个视频都没广告 | ❌ 不可靠（可能只是频控） |

本次 A/B 对照（同一时段、同一部剧）：不注入 → 5 s 处仍是“太极拳”广告；注入 → 4 s 已在正片。

#### 4.13.9 中插广告为什么第一版漏了（2026-11-11）

**现象**：前贴片已经干净，但免费视频播放到中途会插一段约 70 秒的广告。

**设备证据**（logcat）：

```text
21:44:29  Mosaic-JS-Engine / QuickJS 开始加载广告创意
21:45:39  QAdBaseVideoImpl.handleAdPlayerComplete
21:45:40  QAdMidVideoImpl.release
```

从加载到结束约 70 秒，且释放栈明确是 `QAdMidVideoImpl`。

**根因**：中插的 adType 不是 1，而是 4。

```java
// com.tencent.ads.tvkbridge.videoad.impl.QAdMidVideoImpl
@Override
public int getAdType() {
    return 4;
}
```

第一版 hook 只判断 `req.getAdType() === 1`，所以中插请求原样放行。

**TVK 桥接层的 adType 归属**：

| adType | 含义 | 实现类 |
|---|---|---|
| 1 | 前贴片 | `QAdPreVideoImpl` |
| 2 | 暂停广告 | `QAdPauseVideoImpl` / `QAdPauseProxyVideoView` |
| 3 | 后贴片 | `QAdPostVideoImpl` |
| 4 | **中插** | `QAdMidVideoImpl` |
| 5/6/9/15/16/19/20 | 角标、挂件、整屏、THLS 等 | `v2.normalad.*` / 跟踪类 |

**修正**：hook 命中集合改为 `{1, 2, 3, 4}`（本次先补 4，随后把 2/3 一并加入）：

```js
var BLOCK = { 1: 'preroll', 2: 'pause', 3: 'postroll', 4: 'midroll' };
var type = req.getAdType();
if (BLOCK[type]) {
    var e = EC.$new(143, BLOCK[type] + ' disabled by tvpn hook');
    e.setSplashErrorCode(22001, 'disable ' + BLOCK[type] + ' ad by hook');
    return e;
}
```

返回 143 后仍走 SDK 官方失败路径：

```text
view.c.a() → ErrorCode(143)
→ PlayerAdView.fireFailedEvent()
→ QAdBaseVideoImpl.onFailed()
→ notifyGetAdFail()
→ onAdVideoFinish() / onAdCompletion(4)
→ 播放器继续正片
```

**顺带审计过的其它链路**：

| 链路 | 是否同一问题 | 说明 |
|---|---|---|
| `AdViewOld` 兜底 | 可能漏 | 若服务端把 `TZC` 从 `adTypesUseNewAdView` 移除，会走旧 AdView，不再经过 `c.a`；本机配置包含 `TZC`，当前不走 |
| 后贴片 `adType=3` | 已加入 BLOCK | 播完才出；代码路径与中插一致，待片尾实测 |
| 暂停广告 `adType=2` | 已加入 BLOCK | 暂停时出现；已实测 `block pause` |
| 角标/挂件 `5/6/9/15/16` | 否 | 不播视频，只是贴片/浮层 |
| THLS `adType=19` | 否 | 服务端拼接进 HLS，客户端只做曝光跟踪，不能靠这个 hook 去掉 |
| `DynamicStreamAdManager` / `DynamicNetMovieAdManager` | 否 | 信息流/详情页动态广告，不在播放器中断点 |

**验证**：

```powershell
A shell logcat -d -v time | findstr /C:"TVPNAdHook"
# 期望：block midroll #N cid=...
```

2026-11-11 实测（同一部免费剧）：

```text
22:00:47  TVPNAdHook: block preroll #1 cid=...
22:00:47  TVPNAdHook: block preroll #2 cid=...
22:03:19  TVPNAdHook: block midroll #3 cid=...
22:03:19  TVPNAdHook: block midroll #4 cid=...
22:10:51  TVPNAdHook: block pause  #3 cid=...
```

中插命中后没有出现 `QAdMidVideoImpl` 播放；暂停命中后没有出现暂停广告；
截图确认画面仍在正片（字幕正常），播放器没有卡住或停在广告黑屏。
前贴片也仍然正常拦截。

**后贴片（3）待验证**：代码路径与中插一致，但需要完整播到片尾才能确认；
如果片尾仍出广告，优先检查它是不是 THLS（19）/整屏（16）这类不经过 `view.c.a` 的形态。

### 4.14 SVIP/付费内容的“试看几分钟”限制链路（2026-11-11）

> 目标：解释极光/云视听极光里，未开通 SVIP 时付费内容只播前几分钟是怎么实现的。
> **结论先行：限制参数由服务端 CGI 下发（`st` / `preview`），TVK 播放器负责执行，App 只负责弹付费面板。**
> 本节只做链路分析，不提供绕过付费授权的方法。

#### 4.14.1 角色分工

| 层 | 负责 | 关键产物 |
|---|---|---|
| 服务端 CGI | 判定账号/VIP 状态，下发可播范围 | `<st>`、`<exem>`、`<preview>`、`<startpreview>` |
| TVK 播放器 | 把“总时长”改成试看时长，拦截越界 seek/进度 | `prePlayTime`、`prePlayStartPos/EndPos`、错误码 `111012` |
| App（windowplayer） | 起播提示、结束前弹付费面板、上报埋点 | `previewPay`、`PreviewVideoPayPresenter`、`PreAuthData` |

设备版本：`com.ktcp.launcher` 18.9.0.10035（`classes2.dex`–`classes5.dex`）。

> 下文行号指本地 jadx 反编译输出（`ktcp-full/sources`），不同反编译版本可能略有偏移。

#### 4.14.2 服务端下发的字段

设备 CGI 缓存里的真实结构（下例是一条**免费内容**，用于对照）：

```xml
<root>
  <em>0</em><exem>0</exem>
  ...
  <vi>
    <ch>0</ch>
    <st>2</st>
    <td>466.198</td>          <!-- 全片 466 秒 -->
    ...
  </vi>
  <fl>
    ... <preview>-8</preview> ...   <!-- 格式级字段，不是试看时长 -->
  </fl>
  <preview>466</preview>          <!-- 顶层：播放器真正读取的可播秒数 -->
</root>
```

| 字段 | 含义 | 取值 |
|---|---|---|
| `<st>` | 播放状态 | `2` 正常；`8` 试看 |
| `<exem>` | 试看/免费额度类型 | `0` 无；`>0` 进入试看；`3` 表示从上次位置续看试看 |
| `<preview>` | 可播秒数 | 非试看时等于 `<td>`；试看时由服务端下发（常见 3–5 分钟） |
| `<startpreview>` | 试看起点（秒） | 缺省 `-1`（从 0 开始） |
| `<ch>` | 付费标记 | `0` 免费；`>0` 付费内容 |
| `<td>` | 全片时长（秒） | — |
| `<mst>` | 媒体状态 | **不是**试看标志，免费片里也可能是 `8` |

> 注意：`<fl>` 每个格式节点里也有 `<preview>`，值通常是 `-8`，属于清晰度级字段；
> 顶层 `<preview>` 才是 `el/i.i()` 读取的试看时长。

#### 4.14.3 解析链：CGI → TVKVideoInfo

```text
TVKCGIVideoInfoBuilder.L()/O()      解析 XML：em/exem/preview/startpreview/st/ch
        ↓
TVKCGIVideoInfo                     原始字段
        ↓
el/i.java:237-246                   映射为播放器字段
        ↓
TVKVideoInfo.mPrePlayTime / mPrePlayStartPos
```

关键代码（`el/i.java`）：

```java
if (tVKVideoInfo.getExem() > 0 || tVKVideoInfo.getSt() == 8) {
    tVKVideoInfo.setPrePlayTime(tVKCGIVideoInfo.getPreview());
    tVKVideoInfo.setPrePlayStartPos(tVKCGIVideoInfo.getStartPreview());
} else {
    tVKVideoInfo.setPrePlayTime(tVKVideoInfo.getDuration());
}
```

因此：

- `st=2`（免费或已授权）→ `prePlayTime = 全片时长`，正常播完；
- `st=8`（未授权 SVIP）→ `prePlayTime = preview 秒`，只能播这么多；
- `exem=3`（续看试看）→ 起点取请求参数 `atime`，从上次位置继续试看。

#### 4.14.4 播放器怎么执行

> 以下代码为便于阅读，省略了混淆字段名，只保留判断逻辑；原始实现见括号中的文件与行号。

**① 标记试看并计算窗口**（`playerwrapper/player/l0.java:1057-1075`）：

```java
m0Var.t(true);                         // 标记 preview/trial
if (getPrePlayTime() > 0) {
    long start = getPrePlayStartPos();
    if (getExem() == 3) start = atime;  // 续看试看
    setPrePlayStartPos(start);
    setPrePlayEndPos(start + getPrePlayTime());
}
```

**② 把总时长改成试看时长**（`j0.java:540-550`，`onPrepared`）：

```java
if (!m0.s()) {
    duration = player.getDurationMs();          // 普通播放
} else if (l0.b.u(info)) {                      // 试看且 startpreview < 0
    duration = TimeUnit.SECONDS.toMillis(info.getPrePlayTime());
} else {
    duration = info.getDuration();
}
```

效果：进度条总长和“播完”位置都变成 `preview` 秒。

> 若 `startpreview >= 0`，总时长仍显示全片，改由下面的位置检查把播放限制在试看窗口内。

**③ 起播位置夹到窗口内**（`l0.java:1960-1971`）：

```java
long start = getPrePlayStartPos() * 1000;
if (getSt() != 2 && (startPosition < start ||
    startPosition >= (getPrePlayStartPos() + getPrePlayTime()) * 1000)) {
    startPosition = start;      // 历史进度在窗口外 → 强制回到试看起点
}
```

**④ 越界/播完抛 `111012`**（`j0.java`）：

| 触发点 | 位置 | 错误信息 |
|---|---|---|
| `seekTo` 拖到窗口外 | 3221 | `player seek [preview permission timeout] error` |
| `getCurrentPosition` 越过窗口 | 3549 | `player position [preview permission timeout] error` |
| `onCompletion` 试看播完 | 486-501 | `player completion [preview permission timeout] error` |

错误码统一为 `111012`，通过 `TVKPlayerWrapperException` 抛出。

#### 4.14.5 App 层的提示与付费面板

**① 结束前约 5 秒弹面板**（`module/ui/subpresenter/k2.java`，`PreviewVideoPayPresenter`）：

```java
long end = playerData.m1();       // 试看可播到的位置
if (end <= 0) end = playerData.r();
this.endPos = end - 5000;         // 提前 5 秒

if (this.endPos - currentPos < 500) {
    onPreviewFinishing();         // 弹付费面板
}
```

它监听 `videoUpdate`，因此实际在试看结束前约 5.5 秒触发。

**② 播完/出错的兜底路径**（`module/business/VideoCompletion.java:47-76, 121-182`）：

- 判定需要付费 → 发 `previewPay` 事件；
- `I1(true)` 标记“付费面板已展示”；
- 走 `startPay` / H5 付费页 / `PayPanelViewModel`；
- 上报 `player_preview_end` 埋点（`:254-261`）。

**③ 起播时的试看提示**（`module/ui/presenter/PreviewViewPresenter.java:829-846`）：

- 监听 `played` → 由 `TrialHandlerManager` 选择 `VideoTrialHandler`；
- 文案、按钮、倒计时来自服务端 `PreAuthData`；
- `fade_countdown_seconds` 到点自动收起。

**④ 提示文案的来源**：`f30/a.java`（`PreAuthRequest`）请求 `request_play_trial`，
返回 `PreAuthData`（`text`、`buttons`、`trial_end_action` 等），不是客户端写死。

#### 4.14.6 ICNTV 播控侧同步

设备上确认：

```text
enable_icntv_backend_invoke = 1
com.ott.login = 1|...          # 已登录播控，具体标识不入库
```

`module/business/icntv/IcntvBackendInvoke.java:18-26` 在试看时把授权类型上报为：

```java
VinfoAuthType.PREVIEW
```

也就是说，试看不只是本地行为，播控侧也会收到 `PREVIEW` 授权结果。

#### 4.14.7 验证方法

播放一条 SVIP 内容时抓日志：

```powershell
adb logcat -v time | findstr /C:"preview permission timeout" /C:"PreviewVideoPayPresenter" /C:"TrialHandlerManager" /C:"TVMediaPlayerVideoCompletion"
```

预期：

```text
PreviewVideoPayPresenter: checkPlayingProgress, preview finishing: endPos=..., position=...
PreviewVideoPayPresenter: onPreviewFinishing ...
TVKPlayer: player completion [preview permission timeout] error
```

也可以直接看 CGI 缓存（需 root）：

```text
/data/data/com.ktcp.launcher/cache/LocalCache/<hash>
```

- `st=2` + `preview=td` → 免费/已授权；
- `st=8` + `preview=试看秒数` → 试看。

实测对照（2026-11-11，免费内容）：

```text
<st>2</st> <exem>0</exem> <td>466.198</td> <preview>466</preview>
→ 未触发 111012，正常播完
```

#### 4.14.8 边界

这套逻辑本质是**服务端按账号/VIP 状态授权的付费墙**：`st/preview` 是服务端结论，
客户端只负责执行和弹提示。修改 `st`、`preview` 或 hook `111012` 只能改变本地判定，
属于绕过付费授权，不在本项目协助范围；合法路径仍是登录/开通对应 SVIP 权益。

#### 4.14.9 为什么恰好是 5 分钟（2026-11-12 补充取证）

**先排除“本地写死”**：

- `TVKCGIVideoInfoBuilder` 解析 `<preview>` 时默认值是 `0`，`el/i.java` 直接把它赋给 `prePlayTime`；
- 全量反编译里没有“试看 300 秒”这类常量，唯一出现“5分钟”的是 `com.ktcp.video.activity.self.f` 的时长选项，与播放授权无关；
- 因此 5 分钟只能来自 CGI 下发的 `<preview>` 秒数（不同片源/活动可能是 180/300/600 秒，300 秒最常见）。

**为什么本机缓存看不到 `st=8`**：

试看结果按设计**不写缓存**（`com/tencent/qqlive/tvkplayer/vinfo/vod/h.java:295`）：

```text
TVKPlayer: TVKVideoInfoCache:saveVideoInfo,试看，no cache
```

设备上 25 个 CGI 缓存全部是免费内容（`st=2`、`ch=0`、`preview=td`），
这既不能证明“没播过试看”，也不能用来判断试看时长——它本来就不落盘。

**本机缓存中的账号态**（`shared_prefs/Cocos2dxPrefsFile.xml` 的 `svip_info`，缓存可能滞后于实际登录）：

| 字段 | 值 | 含义 |
|---|---|---|
| `userLogin` | `false` | 极光账号未登录 |
| `login_status` | `32` | 未登录态 |
| `is_support_preview`（mmkv_dev_func） | `1` | 客户端支持试看链路 |

也就是说：未登录/无对应权益时点开 VIP 片源，服务端就按试看下发
（`st=8` + `preview=300`），播放器把总时长改成 300 秒并抛 `111012`。
登录后是否解除，取决于该账号是否拥有该片所需的 SVIP/权益，而不是客户端设置。

**结论与边界**：

- 5 分钟 = 服务端按账号权益给出的授权结果，本地没有可调的开关或配置文件；
- 改 `st`/`preview`、hook `111012`、伪造播放器时长都属于绕过付费授权，本项目不提供；
- 合规路径：登录并开通对应 SVIP/权益包，或选择标记为免费的内容；
  若账号确认已有 SVIP 仍被限 5 分钟，才按故障排查（登录态刷新、权益生效延迟、区域限制）。

### 4.15 酷喵（CIBN）贴片广告链路与拦截（2026-11-13）

> 目标：判断酷喵（`com.cibn.tv`，优酷/CIBN）能否用与极光相同的思路去掉前贴片，
> 并给出可验证的门函数。实测版本 `14.0.1.3`（versionCode `2131400103`），Android 10。

#### 4.15.1 结论先行

**可以，且比极光更直接。** 酷喵的前贴片不是服务端拼进 HLS 的，而是客户端把
广告 m3u8/TS 与正片做“本地合并”（`createMergeUrl ... enable localMergeUrl`）。
在合并之前有一个明确的“广告数据是否为空”门函数：

```text
a.g.a.a.h.f.playm.isAdDataEmpty(com.yunos.tv.player.top.IAdInfoWrapper)
  返回 true
    -> AdPlayerManager.onGetInfoResult 的“无广告”分支
    -> getAdInfoFailedSkipAd
    -> 跳过广告，直接播放正片
```

`playm` 就是 `com.yunos.tv.player` 的 `AdPlayerManager`（jadx 反编译里被重命名）。
它同时覆盖 `adType 7`（前贴片）、`8`（中插）、`10010002`（pre-video-stream）。

**实测**（2026-11-13 00:11）：

```text
00:11:23  AdPlayerManager AdPlayerManager
00:11:24  TVPNAdHook: block kumiao ad #1 (isAdDataEmpty->true) size=3
00:11:25  VpmLogManager: preAdCnt=3; preAdDuration=109000; is_ad_play=0; mAdDuration=0
```

3 条创意合计 109 秒，hook 命中后没有 `onMergeOk`、没有 `IsPreAd` TS 请求，
正片直接起播。广告时长 90–120 秒的差异只是创意条数不同（通常 3 条）。

#### 4.15.2 请求链（旧 xadsdk / youdo）

```text
Player
  └─ com.youdo.ad.api.RequestAdForExternal.loadPreAd(...)
       ├─ PasterAdRequestInfo: adType=7, PROGRAM_PRE
       └─ e.c.a.c.c.a().a(7, requestInfo, callback)   // 旧 AdRequestManager
            └─ AdvInfo（含 AdvItem 列表：每条一个广告视频 URL + duration）
                 └─ a.g.a.a.o.play（AdInfoWrapper）
                      └─ AdPlayerManager（a.g.a.a.h.f.playm）
```

中插走同一条链，只是 `adType=8`（`PluginMid` 里 `getAdType() == 8`）。
暂停广告是另一条链：`e.t.v.e.c.h` 用 `adType 10/30` 请求，`isAdDataEmpty` 不覆盖。

#### 4.15.3 合并与播放

`AdPlayerManager` 拿到 `IAdInfoWrapper` 后：

```java
b(iAdInfoWrapper);                       // VIP 限制提示
setPreAdData(...);                       // 仅记录，供 UI/埋点
if (z && !isAdDataEmpty(iAdInfoWrapper)) {
    mHandler.sendEmptyMessage(4097);     // 进入广告播放/合并
    return;
}
qo();
a(z, obj);                               // getAdInfoFailedSkipAd：跳过广告
```

走广告分支时才会 `createMergeUrl` → `onMergeOk`，把广告 TS 合并进播放列表；
原生层 `IPcdnDownloadFilter::IsPreAd` 负责识别 pre-ad 分片。
所以把 `isAdDataEmpty` 固定为 `true`，等于让播放器永远走“无广告”分支，
广告既不会播放，也不会发生合并。

#### 4.15.4 残留的其它广告形态

`isAdDataEmpty` 只解决“广告视频”。酷喵还有一套 `noveladsdk`（13.5.0.1）浮层广告：

| 形态 | 类 | 位置 | 现状 |
|---|---|---|---|
| 前贴片/中插视频 | `AdPlayerManager.isAdDataEmpty` | 播放器 | ✅ 已拦 |
| Fusion 浮层（角标/二维码） | `com.youku.noveladsdk.playerad.fusion.FusionAdPresenter` | 正片上层 | ⚠️ 仍会出 |
| Inventory 点位 | `InventoryAdPresenter`（adType 20000） | 161/878/1774s 等 | ⚠️ 仍会请求 |
| Soft ad | `SoftAdPresenter`（10002） | 角落浮层 | ⚠️ 未处理 |
| 暂停广告 | `e.t.v.e.c.h`（10/30） | 暂停页 | ⚠️ 未处理 |

日志里能看到 `FusionAd_FusionAdPresenter show` 与
`InventoryAdPresenter Inventory Point start = 161/878/1774`，说明这些是独立点位，
不受视频门函数影响。需要的话可再挂 `FusionAdPresenter.allowShow()` 或
`noveladsdk.request.AdRequestManager.request()` 做统一拦截。

#### 4.15.5 策略与风险

**推荐策略（最小改动）**：

1. 只挂 `a.g.a.a.h.f.playm.isAdDataEmpty`：**只有 `getAdUrlList().size() > 0` 时返回 `true`**，
   没有广告数据时交回原实现，避免改变播放器正常的空判断路径；
2. 观察一周，确认不影响起播、选集、续播、投屏；
3. 若浮层干扰明显，再加第二个 hook（Fusion/Soft/Inventory），不要一开始全关。

**落地方式（已启用）**：

| 文件 | 作用 |
|---|---|
| `/data/local/tmp/kumiao_block.js` | 门函数 hook |
| `/data/local/tmp/kumiao_guard.sh` | 按 pid 轮询注入，日志自截断（>2000 行留 500） |
| `boot.sh` 第 40–45 行 | 开机拉起 `kumiao_guard.sh` |

`kumiao_guard.sh` 用 `timeout 40 frida-inject -p <pid> -s ... -e` 注入，
失败会退避重试；酷喵进程重启后自动重新注入。

**注意：酷喵会被系统后台限制杀掉**（`app not allow running background: com.cibn.tv`），
这是 Q6011 §6 的厂商策略，不是 hook 导致的。酷喵在前台时 guard 正常注入；
从桌面重新打开后 guard 会再次注入，不影响使用。

**风险**：

- 类名是混淆名，随版本升级可能变化；升级后 hook 失效表现为“广告回来”，不会崩；
- 该 hook 同时跳过中插，属于预期行为；
- 暂停广告不受影响，需单独处理；
- 这是运行时注入，依赖 `frida-inject` 能在 `com.cibn.tv` 上工作（当前已验证）。

**回滚**：停掉 `kumiao_guard.sh` 并杀掉注入器即可；不修改 APK、不修改系统文件。

```powershell
Invoke-Root "pkill -f kumiao_guard.sh; pkill -f frida-inject; rm -f /data/local/tmp/kumiao_guard.pid"
# 再从 boot.sh 去掉 kumiao 段
```

#### 4.15.6 验证命令

```powershell
adb shell logcat -d -v time | findstr /C:"TVPNAdHook"
adb shell logcat -d -v time | findstr /C:"preAdDuration"
adb shell cat /data/local/tmp/kumiao_guard.log
```

期望：

```text
TVPNAdHook: block kumiao ad #N size=3
VpmLogManager: preAdCnt=3; preAdDuration=109000; is_ad_play=0; mAdDuration=0
kumiao_guard.log: injected pid=... rc=0
```

第二次实测（2026-11-13 05:59，另一部免费剧）：

```text
05:59:07  TVPNAdHook: block kumiao ad #1 size=4
05:59:08  preAdCnt=4; preAdDuration=113000; is_ad_play=0; mAdDuration=0
```

4 条创意合计 113 秒，同样直接进正片。说明“90–120 秒”只是创意条数不同，
门函数与条数无关。

若仍出现 `onMergeOk` / `IsPreAd`，说明 hook 注入晚于广告请求（需在进程启动后立即注入，
或重启酷喵让 guard 重新注入）。

### 4.16 机顶盒远程访问：sshd-android 与 PBKDF2 密码哈希（2026-11-14）

机顶盒（Q6011）长期在线，远程入口是自写的 Go sshd（模块 `sshd-android`，装在
`/system/bin/sshd`）。它原来把密码**明文**存在 `/data/local/tmp/sshd/password`，
文件属主是 `shell`——同网段任何人 `adb shell` 就能 `cat` 出来。长期在线设备上这是实际风险，
本轮改成哈希校验。

#### 4.16.1 为什么不能用标准 /etc/shadow

Android 的 bionic 没有 `crypt()`，也没有可用的 `getspnam()`，标准 sshd 那套
「`/etc/shadow` + crypt 比对」在 Android 上跑不通；这款 sshd 的认证也是自己实现的
（`gliderlabs/ssh`），原来是「读文件 + 字符串相等」。

#### 4.16.2 改造方案

沿用文件式口令，但文件里只存哈希：

```text
$pbkdf2-sha256$<iterations>$<salt_hex>$<hash_hex>
```

- KDF：PBKDF2-HMAC-SHA256，盐 16 字节随机，派生密钥 32 字节；
- 比较使用 `subtle.ConstantTimeCompare`；
- **只接受上述格式**：明文或未知格式在启动时直接禁用密码认证（公钥不受影响），
  不会回退到明文比较；
- 新增 `-hash` 模式：从 stdin 读一次密码，输出可写入文件的哈希行；`-iter` 可调整迭代次数。

迭代次数实测（Q6011 / Cortex-A53 1.34 GHz）：

| 迭代次数 | 单次校验 | SSH 登录总耗时 | 结论 |
|---|---|---|---|
| 200000 | ~2.5 s | 2.74 s | 太慢，弃用 |
| 60000 | ~0.6–0.8 s | 0.94 s | 采用 |

#### 4.16.3 构建

```text
Go 1.23.12
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0
go build -trimpath -ldflags "-s -w" -o sshd-hashed .
产物 3,932,312 B（原版 4,849,824 B）
```

#### 4.16.4 部署

机顶盒是 Android 10 的 system-as-root：`/system` 不是独立挂载点，属于 `/`
（`/dev/block/dm-2`）。直接 `mount -o rw,remount /` 会偶发报
`not user mountable in fstab`，稳定写法是带设备名：

```sh
mount -o rw,remount /dev/block/dm-2 /
```

部署后：

```text
/system/bin/sshd                    3,932,312 B  root:shell 755
/data/local/tmp/sshd/password       119 B        root:root 600   ← 只有哈希
/data/local/tmp/sshd/host_ed25519   119 B        root:root 600
/data/local/tmp/sshd/authorized_keys  92 B       root:root 600
```

顺带把 `authorized_keys` 从 `shell:shell 666` 收紧为 `root:root 600`。

注意：`/system` 所在分区当时只剩 19 MB。替换的是同一个文件，`cp` 会先截断再写，
空间够用，但不要再往这个分区放大文件。

#### 4.16.5 验证

| 场景 | 结果 |
|---|---|
| 正确密码 | `uid=0(root)`，登录耗时 0.94 s |
| 错误密码 | `Permission denied (password,publickey)` |
| 明文密码文件 | 启动日志 `password auth disabled: unsupported password format...`，`password=false`，仅保留公钥 |
| 密码文件权限 | `root:root 600`（之前 `shell:shell`，adb shell 可直接读） |

#### 4.16.6 改密码

```sh
printf '新密码\n' | /system/bin/sshd -hash
# 输出 $pbkdf2-sha256$60000$...
# 写入 /data/local/tmp/sshd/password（root:root 600），然后重启守护
sh /data/local/tmp/sshd_guard.sh
```

#### 4.16.7 边界与后续

- 哈希只防「文件泄露」；口令本身仍建议 12 位以上随机串，7 位数字离线爆破很快；
- 车机的 dropbear 仍是明文文件（同样是 bionic 无 `crypt()` 的妥协），要统一需要在 C 里
  实现 PBKDF2 或更换服务端，见 §5.5。

---

### 4.17 SmartTube 声音增益（LoudnessEnhancer）复现与关闭（2026-11-14）

来源：车机排查文档 `~/Documents/car-headunit-tvpn-502-and-smarttube-noise.md` §3
（车机 SmartTube 32.71 播放有“收音机杂音”，根因是自动音量把底噪一起放大）。

#### 4.17.1 机顶盒是否也有

**有，且完全同款。** 机顶盒同样是 SmartTube **32.71**（`versionCode 2461`），
`Auto volume adjustment` 默认开启。

修复前边播边抓 AudioFlinger：

```text
1 Tracks of which 1 are active
            233    yes  21037    1297 ... SRate 48000 ... G db -20
  1 Effect Chains
    1 effects for session 1297
    Effect ID 51:
      - UUID: fa415329-2034-4bea-b5dc-5b381c8d1e2c
      - name: Loudness Enhancer
```

`Client` 列就是 SmartTube 的 pid，说明是**应用自己挂的音效**，不是系统全局音效。

#### 4.17.2 增益计算

`VolumeBooster` + `setupVolumeBoost()`（v32.71）：

```text
volume = playerVolume * (auto ? 2.0 : 1.0)      // 默认 playerVolume=1.0
gain   = 20 * log10(volume * 3)  ≈ +15.6 dB     // 挂到 LoudnessEnhancer
```

所以只要 `auto=true` 且播放器音量 > 50%，就会多出约 15.6 dB，把量化噪声/底噪一起抬起来。

#### 4.17.3 配置位置

```text
/data/data/org.smarttube.stable/files/app_prefs/video_player_tweaks_data
```

- `%OB%` 分隔，共 **63** 个字段（本次实测 531 B，末尾无换行）
- **第 41 个字段**（索引 40）= `player_auto_volume`，本次实测值 `true`

#### 4.17.4 修复（只改第 41 字段）

先停应用，否则退出时会用内存值回写覆盖：

```sh
F=/data/data/org.smarttube.stable/files/app_prefs/video_player_tweaks_data
am force-stop org.smarttube.stable
cp -p "$F" /data/local/tmp/video_player_tweaks_data.bak

# 只替换第 41 字段，其余字节原样保留（末尾有无换行也按原样还原）
NL=$(busybox tail -c 1 "$F" | busybox od -An -tx1 | busybox tr -d ' \n')
busybox awk -F'%OB%' -v nl="$NL" 'BEGIN{OFS="%OB%"} {
  if (NF >= 41) $41 = "false";
  printf "%s", $1;
  for (i = 2; i <= NF; i++) printf "%s%s", OFS, $i;
  if (nl == "0a") printf "\n";
}' "$F" > /data/local/tmp/vpt.new

cp /data/local/tmp/vpt.new "$F"
chown u0_a50:u0_a50 "$F"     # 机顶盒上 UID 10050
chmod 600 "$F"
rm -f /data/local/tmp/vpt.new
```

逐字段比对确认只有一处变化：

```text
field 41: true -> false
size 531 -> 532   （"false" 比 "true" 多 1 字节，属正常）
```

#### 4.17.5 验证

重新起播后：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `Effect Chains` | 1 | **0** |
| `Loudness Enhancer` | 挂载（Effect ID 51） | **不存在** |
| 音轨 | 1 条 active | 1 条 active（正常出声） |

退出播放再 `am force-stop` 后复查，第 41 字段仍为 `false`，说明没有被回写。

备份：`/data/local/tmp/video_player_tweaks_data.bak`（531 B，原始 `true` 版本）。

> 界面等价操作：SmartTube → Settings → Player tweaks → **Auto volume adjustment** 关闭；
> 或把播放器音量压到 50% 以下（`volume*2 > 1` 才不会触发）。

#### 4.17.6 顺带核对：TVPN 必须是白名单模式，不能全局

机顶盒上 `addAllowedApplication` 是生效的，`ip rule` 里只有白名单 UID 的规则，
没有 `uidrange 0-99999` 这种全局项：

```text
12000:  from all fwmark 0x0/0x20000 iif lo uidrange 10050-10050 lookup tun0   # SmartTube
12000:  from all fwmark 0x0/0x20000 iif lo uidrange 10058-10059 lookup tun0   # IG Lite / FB Lite
```

对应关系（`pm list packages -U`）：

| UID | 包名 |
|---|---|
| 10050 | `org.smarttube.stable` |
| 10058 | `com.instagram.lite` |
| 10059 | `com.facebook.lite` |

白名单文件：

```xml
<string name="raw">org.smarttube.stable,com.instagram.lite,com.facebook.lite</string>
```

结论：**只有这三个应用走 VPN，其余（桌面、系统、统计等）走直连**，符合白名单要求。

#### 4.17.7 关掉增益能省多少负载（实测）

**结论：几乎不省。** 收益在「几 % 一个核」以内，且会被系统负载噪声淹没；真正的负载是视频软解。

实测（同一台盒子，播放 1080p60 VP9 视频，`/proc/<pid>/stat` 差分 15–60 s）：

| 指标 | 数值 | 说明 |
|---|---|---|
| SmartTube 进程 CPU | 69.4 % / 70.9 % / 100.8 %（一个核） | 软解 1080p60 VP9 |
| 音频线程（`AudioOut_D`） | 1.17 ms / 20 ms 缓冲（无音效） | ≈6 % 一个核 |
| 同上 | 4.72 ms / 20 ms 缓冲（挂 LoudnessEnhancer） | 该次系统同时被软解打满，含抢占/降频，**不能全算到音效头上** |

AOSP 的 `LoudnessEnhancer` 是逐帧增益乘法 + 限幅器，48 kHz 立体声下自身开销很小；
insert 模式额外多两次缓冲拷贝（960 帧 × 4 B ≈ 3.8 KB）。所以它的成本远低于表里的差值。

两个更值得注意的点：

1. **当前格式是 1080p60**：`video_player_data` 第 10 字段为
   `0,0,null,vp9,1920,1080,60.0,...`。文档 §4.4 早就建议限到 **1080p30**（或 720p），
   这一步对负载的收益远大于关音效——60 fps 大约要多解一倍帧。
2. **AC-3 直通时音效根本不挂**：第 11 字段为 `ac-3` 时音频不解码成 PCM，
   `Effect Chains` 恒为 0（本次就复现了 `f41=true` 但 `0 Effect Chains` 的状态）。
   这种场景下关不关自动音量对负载完全没有影响。

---

## 5. 车机端部署与影音适配

### 5.1 环境

| 项目 | 值 |
|---|---|
| ADB 序列号 | `408849cb9e8f016c` |
| product / model | `ac83xx_evb` |
| 厂商 | `autochips`（AC8317） |
| Android | 6.0 / API 23 |
| ABI | `armeabi-v7a` |
| 屏幕 | 1024×600 / 240dpi |
| 内存 | 1.8 GB |
| WebView | 44.0.2403.119 |

TVPN 1.1.0（minSdk 21、armeabi-v7a）与该环境完全兼容。

### 5.2 安装与白名单

```powershell
adb -s 408849cb9e8f016c install -r app-release.apk
# versionCode=2 versionName=1.1.0
```

最终白名单：

```text
com.mmbox.xbrowser,org.smarttube.stable
```

| 应用 | 包名 | UID |
|---|---|---|
| X 浏览器 | `com.mmbox.xbrowser` | 10031 |
| SmartTube | `org.smarttube.stable` | 10069 |

实测踩坑：

- 包名必须完全准确。曾写成 `com.mmbox.xbrowse`（少一个 `r`），代理启动不报错，但 X 浏览器实际不走 VPN；
- 白名单只在启动代理时注册，改完必须「停止代理 → 启动代理」；
- 车机不需要代理 QQ 音乐 / QQ 视频，已从默认白名单移除。

### 5.3 SmartTube 适配

| 项目 | 值 |
|---|---|
| 版本 | 32.71 stable（GitHub 官方 Release） |
| 包名 | `org.smarttube.stable` |
| 架构 | armeabi-v7a（24.3MB） |
| minSdk / targetSdk | 17 / 34 |

结论：**SmartTube 32.71 可在 Android 6.0 车机上正常安装、渲染和播放**；1024×600 下 UI 完整，16:9 视频上下留黑边。实测解码为 itag 136（720p AVC）+ itag 140（AAC），硬解正常。

### 5.4 WiFi 热点上游测试

条件：车机连接荣耀 Magic7 热点（2.4GHz，链路 58Mbps，RSSI -32），节点「美国硅谷7 · TLS」。

| 检查项 | 结果 |
|---|---|
| 上游自动切换 | `upstream changed ... (wifi), rebinding`、`upstream network: wifi` |
| tun0 | `inet 26.26.26.1/32` |
| X 浏览器访问 Google | 正常，显示「Google 提供：English」 |
| 实际出口 | 8 秒内 `wlan0` RX 513KB，`eth0` RX 0KB |
| SmartTube 起播 | 约 10 秒，之后连续播放 |
| 播放稳定性 | 短窗口仅 3 次 `dropOutputBuffer`，画面持续推进 |
| 吞吐 | 约 47–160KB/s（热点国际线路带宽有限） |

结论：

- WiFi 热点的分流代理同样有效，TVPN 会自动把上游从 eth0 切到 WiFi 并重绑 relay；
- 切换瞬间会断开已有连接，正在播放的视频会重新缓冲，重开即可；
- 热点线路带宽低于内置 4G，起播偏慢属正常，可把 SmartTube 清晰度上限设为 480p/720p，或改用香港/新加坡/日本等更近节点。

### 5.5 远程访问：去掉 telnet 2223，改用 dropbear sshd（22）

> 2026-11-14。`/system/bin/hk_oem_init.sh` 末尾曾由 opencode 于 2026-10-24 追加一段
> 「busybox telnetd 2223 + iptables 放行」的调试入口；本轮整段删除，换成标准 SSH（22，密码登录）。

#### 5.5.1 目标

| 项 | 要求 |
|---|---|
| 常驻 | 二进制固化到 `/system`，重启不丢 |
| 入口 | 22 端口 SSH，root 登录 |
| 认证 | 密码登录（任意电脑可接入），公钥可选 |
| 改动纪律 | 只做必要改动；备份留 PC；设备不留备份 |
| 兼容 | 保留 `hk_oem_init.sh` 原有主流程与 eth0 自愈逻辑 |

#### 5.5.2 方案选型与关键结论

先尝试「直接复用机顶盒那款 sshd」：

| 方案 | 结果 |
|---|---|
| 机顶盒 `/system/bin/sshd`（模块 `sshd-android`，Go 1.27.1，静态 ARM32） | 车机启动即 `Illegal instruction (core dumped)` |
| 用 Go 1.23.12 重编同款（`gliderlabs/ssh v0.3.8`、`creack/pty v1.1.24`、`x/crypto v0.31.0`、`anmitsu/go-shlex`，`GOARM=7 CGO_ENABLED=0 -trimpath`） | **仍然 SIGILL** |
| dropbear 2026.94（bionic 动态 PIE） | ✅ 正常 |

**关键结论：与 Go 版本无关**，是这台 3.18.49 内核与 Go 运行时启动路径不兼容。

排除项（全部用实验验证）：

- **不是缺库 / glibc 问题**：产物 `CGO_ENABLED=0`、静态、无 `PT_INTERP`，全文件检索不到
  `glibc` / `musl` / `libc_start_main`；缺库的典型报错是 `CANNOT LINK EXECUTABLE`，不是 SIGILL；
- **不是 CPU / VFP 问题**：用 NDK 编了一个只做一次 VFP 乘加的裸汇编程序（`-nostdlib -static`），
  车机上正常运行；
- **另一类独立问题**：NDK 的静态 bionic 程序（`-static` / `-static-pie`）会被 bionic 拒绝：
  `executable's TLS segment is underaligned: alignment is 8, needs to be at least 32 for ARM Bionic`，
  同样表现为 SIGILL。与 Go 无关，但说明这台机器上「静态 bionic」路线不可用。

core 定位（临时把 `core_pattern` 指向文件后抓取）：

```text
signal = SIGILL(4)
PC     = 0xbef01418      ← 内核映射页（VDSO 区，页首为 ELF 头），不在 sshd 自身 0x10000–0x4a8000
线程数 = 1               ← 崩在运行时初始化，还没进业务代码
```

Go 1.27 与 1.23 的产物里都带 `runtime.vdsoInitFromSysinfoEhdr` / `runtime.vdsoParseSymbols` /
`runtime/vdso_linux.go`（含 `vdso_linux_arm.go`），说明运行时确实在 arm 上走 VDSO 符号解析。
老内核上的具体失败点没有继续深挖，直接换技术栈——**能用标准 bionic 动态程序就不要赌 Go 运行时**。

#### 5.5.3 dropbear 交叉编译

源码：`dropbear-2026.94.tar.bz2`；工具链：NDK 26.3.11579264（clang + make）+ Git Bash（sh/tar）。

```bash
NDK=/d/AndroidDev/android-sdk/ndk/26.3.11579264
BIN=$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin
SYS='D:/AndroidDev/android-sdk/ndk/26.3.11579264/toolchains/llvm/prebuilt/windows-x86_64/sysroot'

export CC="$BIN/clang.exe"
export CPPFLAGS="--target=armv7a-linux-androideabi23 --sysroot=$SYS"
export CFLAGS="-O2"
export LDFLAGS="--target=armv7a-linux-androideabi23 --sysroot=$SYS"
export AR="$BIN/llvm-ar.exe" RANLIB="$BIN/llvm-ranlib.exe" STRIP="$BIN/llvm-strip.exe"

./configure --host=arm-linux-androideabi \
  --disable-zlib --disable-syslog --disable-shadow \
  --disable-lastlog --disable-utmp --disable-utmpx \
  --disable-wtmp --disable-wtmpx --disable-loginfunc
```

```text
make -j4 ARFLAGS=r PROGRAMS="dropbear dropbearkey"

dropbear    342,992 B   ELF32 ARM / PIE / INTERP=/system/bin/linker
dropbearkey 179,000 B
```

构建踩坑（均为实际遇到）：

| 问题 | 现象 | 解决 |
|---|---|---|
| Windows 版 clang 不认 MSYS 路径 | `clang.exe: No such file or directory` | `CC`/`AR` 用 `/d/...`，`--sysroot` 用 `D:/...` |
| sysroot 只放 CFLAGS | `uid_t`/`gid_t` 检测失败 → 宏冲突 → `Cannot find a type to use in place of socklen_t` | 目标参数同时放进 `CPPFLAGS`（autoconf 类型检查用它） |
| Windows 版 make 不认 `SHELL` | `'printf' 不是内部或外部命令` | 把 Git 的 `usr\bin`、`bin` 加进 PATH，让 make 找到 `sh.exe` |
| libtomcrypt 链接命令行过长 | `llvm-ar: error: s: No such file or directory`（参数被截断） | 改用响应文件：`llvm-ar rcs lib.a @objs.txt` |
| bionic 没有 `crypt()` | 编译期 `#error "DROPBEAR_SVR_PASSWORD_AUTH requires crypt()"` | patch 密码校验函数（见 5.5.4） |

#### 5.5.4 对 dropbear 的改动（只有三处）

其余全部保持 2026.94 原样，避免删改过多引入不稳定。

| 文件 | 改动 | 原因 |
|---|---|---|
| `src/svr-authpasswd.c` | 读 `/system/etc/dropbear/password`，去尾部空白后 constant-time 比较，替代 `crypt()` | bionic 无 `crypt()` |
| `src/svr-authpubkey.c` | 允许带 sticky 位（`S_ISVTX`）的目录 | 本 ROM `/` 是 `drwxrwxrwt`，原版从 `/` 逐级校验必然拒绝 |
| `src/default_options.h` | `DEFAULT_PATH`/`DEFAULT_ROOT_PATH` 改为 `/system/bin:/system/xbin` | 原值 `/usr/bin:/bin`，Android 上不存在，登录后 `id: not found` |

**没有做的事**：曾尝试 `#define DROPBEAR_SVR_PUBKEY_AUTH 0` 在编译期关掉公钥认证，但
`DROPBEAR_SIGNKEY_VERIFY` 同时控制签名验证代码，导致 `sign_key_fingerprint` 未声明、
`dropbear_ed25519_verify` 链接失败。该尝试已完全还原，线上二进制与还原后重编产物 MD5 一致
（`2145e359…`）——**关公钥改为删 authorized_keys，不动代码**。

#### 5.5.5 部署清单

```text
/system/bin/dropbear                            342,992 B  root:shell 755
/system/bin/dropbearkey                         179,000 B  root:shell 755
/system/etc/dropbear/dropbear_ed25519_host_key       83 B  root:root  600
/system/etc/dropbear/password                         8 B  root:root  600  （8 位数字，勿外传）
/system/etc/shells                                   15 B  root:root  644  （内容 /system/bin/sh）
/data/local/tmp/dropbear_guard.sh                 1,599 B           755
```

启动命令（守护脚本与手工一致）：

```bash
/system/bin/dropbear -p 22 \
  -r /system/etc/dropbear/dropbear_ed25519_host_key \
  -D /system/etc/dropbear -F -e
```

三个容易踩的点：

1. dropbear 用 `getusershell()` 校验登录 shell。bionic 读 `/etc/shells`（`/etc` → `/system/etc`），
   文件不存在就报 `User 'xxx' has invalid shell, rejected`；
2. `authorized_keys` 位置用 `-D <dir>` 指定。Android 用户 home 是 `/`，默认的 `~/.ssh` 不可写；
3. 本 ROM 的 umask 是 0，`mkdir` 出来的目录是 777，dropbear 会以
   `must be owned by user or root, and not writable by group or others` 拒绝——`/system/etc/dropbear` 必须 `chmod 755`。

#### 5.5.6 开机自启 + 移除 telnet

`/system/bin/hk_oem_init.sh` 尾部调整为：

```sh
# 远程访问: dropbear sshd (22)
if [ -x /data/local/tmp/dropbear_guard.sh ]; then
    sh /data/local/tmp/dropbear_guard.sh
fi
```

- 2026-10-24 追加的「telnetd 2223 + iptables」整段删除；实测无 telnetd 进程、无 2223 监听、无残留规则；
- 同段的 eth0 自愈逻辑保留（等 `sys.boot_completed` → 每 10s 采样 → 连续 5 次 CONNECTED 才收工，
  否则 `ifconfig eth0 down/up`，最多 15 轮）；
- `main()` 前 67 行与出厂 `hk_oem_init.sh.orig` 用 `cmp` 校验逐字节一致；整体 `sh -n` 通过；
- 写完后立即 `mount -o ro,remount /system` 还原。

守护脚本两个要点：

- 用 `busybox pidof` 判活。**Android 6 的 `/system/bin/pidof` 是 toybox 实现，忽略参数、直接返回全部 PID**，
  用它判断会永远认为「已在运行」，守护脚本直接退出；
- 用 `nohup` 启动。否则从 adb shell 触发时，会话结束会把子进程一起挂断（首次验证就是这样失败的）。

#### 5.5.7 验证记录（2026-11-14）

| 项 | 结果 |
|---|---|
| 密码登录（WiFi 直连） | `ssh root@10.73.250.186` → `uid=0(root)` |
| 公钥登录 | `Permission denied (publickey,password)`（authorized_keys 已删除） |
| adb WiFi | `adb connect 10.73.250.186:5555` → `device` |
| 重启自启 | `boot.log`: `dropbear launched (pid 327)`；22 与 5555 均在监听 |
| 挂载 | `/system`、`/` 均为 `ro` |

> 选择「仅密码」后，恢复公钥只需要把 `.pub` 写回 `/system/etc/dropbear/authorized_keys`（600 root），
> 不需要重启 dropbear，也不用改二进制。

#### 5.5.8 回滚

```powershell
# 恢复出厂开机脚本（换回 telnet 版前请确认仍需该入口）
adb shell su 0 sh -c "mount -o rw,remount /system; cp /data/local/tmp/hk_oem_init.sh.orig /system/bin/hk_oem_init.sh; sync; mount -o ro,remount /system"

# 移除 sshd
adb shell su 0 sh -c "mount -o rw,remount /system; rm -rf /system/bin/dropbear /system/bin/dropbearkey /system/etc/dropbear /system/etc/shells; sync; mount -o ro,remount /system"
adb shell rm -f /data/local/tmp/dropbear_guard.sh
```

#### 5.5.9 安全边界

- 车机连着热点时，同一网段任何设备都能尝试 root 密码登录；日常建议用公钥，或只在需要时连热点；
- 密码文件是明文（600，仅 root 可读），会随 `/system` 镜像长期存在；
- 22 端口是直连入口，不经过 TVPN；adb 5555 保留作为兜底。

---

## 6. 通用运维与排障

### 6.1 白名单不生效

```bash
adb shell ip addr show tun0                  # 期望 inet 26.26.26.1/32
adb shell ip rule show | grep uidrange       # 检查目标 UID 是否在规则里
adb shell dumpsys package <pkg> | grep userId=
```

若 UID 不在规则里：打开 TVPN →「停止代理」→「启动代理」。无 root 不要尝试 `ip rule add`。

### 6.2 能连上但不通

按顺序排查：

1. 节点是否支持 `CONNECT <resolver>:53`（DNS 依赖）；
2. 换「美国硅谷7」或关闭自动选路；
3. `logcat -s tvpn` 看 `relay started` / `tunnel start`；
4. 浏览器打开 `https://www.google.com` 验证是否有出口。

### 6.3 播放卡顿/黑屏

- SmartTube：先限制清晰度（电视 1080p30 vp9，车机 720p）；
- 观察是否在缓冲：`dumpsys gfxinfo <pkg> | grep "Total frames"` 间隔对比；
- 4K/VP9 在旧盒子上容易触发解码器重建，属于硬件能力边界；
- 内存紧张时先清广告/统计包，再重启播放器。

### 6.4 应用重装后丢分流

重装会换 UID，必须重启代理；IG 还会丢登录态，需要重新走邮箱验证码。

### 6.5 常用命令速查

```bash
# 安装/覆盖
adb install -r app-release.apk

# 启动与状态
adb shell am start -n com.tvpn.client/com.tvpn.client.MainActivity
adb shell ip addr show tun0
adb shell ip rule show | grep uidrange
adb logcat -s tvpn

# 强制停止应用
adb shell am force-stop <pkg>

# 电视：禁用系统包（Binder 绕过）
adb shell service call package 95 s16 <pkg> i32 3 i32 0 i32 0 s16 com.android.shell

# 电视：无障碍服务
adb shell cmd settings put secure enabled_accessibility_services com.fix.igremote/com.fix.igremote.IgKeyService
adb shell cmd settings put secure accessibility_enabled 1

# 电视：黑屏救援（桌面窗口无表面）
adb shell am force-stop com.ktcp.launcher
adb shell am start -a android.intent.action.MAIN -c android.intent.category.HOME
```

### 6.6 黑屏但系统还醒着：桌面窗口无表面（2026-11-14）

**现象**：屏幕全黑，遥控器按任何键都没反应（连返回、主页都不响应）。

#### 6.6.1 先分清是哪一种黑屏

| 判据 | 命令 | 含义 |
|---|---|---|
| 背光/待机 | `dumpsys power \| grep -E 'mWakefulness|Display Power'` | `Awake` + `state=ON` 说明系统认为屏是亮的 |
| 有没有画面 | `screencap -p /data/local/tmp/x.png` | 抓下来是**黑帧**（RGB 全 0）说明在合成黑图，不是没信号 |
| 谁在前台 | `dumpsys activity activities \| grep mResumedActivity` | 桌面前台 ≠ 桌面有画面 |
| 有没有焦点 | `dumpsys window \| grep mCurrentFocus` | **`null` = 遥控器按键无处可送，这就是"按键没反应"的原因** |
| 有没有表面 | `dumpsys window windows \| grep -E 'Window #\|mHasSurface'` | **`mHasSurface=false` = 窗口没提交任何缓冲** |

> 坑：Android 的 `screencap` PNG 是 32bpp 带 alpha，黑帧的 alpha 可能是 0，
> 在图片查看器里会显示成**纯白**。判断黑白要看 RGB，别被预览骗了：
>
> ```powershell
> $bmp = New-Object System.Drawing.Bitmap('x.png')
> $bmp.GetPixel(960, 540)   # 黑屏应为 A=0,R=0,G=0,B=0
> ```

#### 6.6.2 本次实例

```text
mWakefulness=Awake          Display Power: state=ON
mCurrentFocus=null
Window #0  com.ktcp.launcher/.LauncherHomeSingleTaskActivity
           mViewVisibility=0x4   mHasSurface=false   isVisible=false
```

桌面进程还活着（pid 31105，uid 1000），但主线程卡住：

```text
线程状态统计：17 个 R、151 个 S
主线程 state=R  utime=15428  stime=36936     ← 内核态时间远大于用户态，在系统调用里空转
```

同时 `WindowManager` 持续刷：

```text
W/WindowManager: Failed looking up window callers=...interceptKeyBeforeDispatching
```

即：**桌面进程卡死 → 窗口表面没重建 → 系统仍认为桌面在前台 → 既没画面也没焦点 → 遥控器全失效**。

#### 6.6.3 恢复

不需要重启机器，重启桌面即可（`am force-stop` 后系统会因 HOME 角色自动重建进程）：

```sh
am force-stop com.ktcp.launcher
sleep 3
am start -a android.intent.action.MAIN -c android.intent.category.HOME
```

复验必须同时满足三条：

```text
mCurrentFocus=Window{... com.ktcp.launcher/...LauncherHomeSingleTaskActivity}
mHasSurface=true  isReadyForDisplay()=true
截图出现桌面内容
```

本次执行后 pid 从 31105 变为 6486，窗口表面与焦点恢复，画面正常。

#### 6.6.4 附带发现：残留的僵尸窗口

桌面恢复后，窗口栈里还挂着一个没有表面的全屏窗口：

```text
Window #1  com.xiaodianshi.tv.yst/.videodetail.VideoPlayActivity
           mHasSurface=false  isReadyForDisplay()=false
```

系统随后又按"恢复上个任务"把它拉起来：

```text
I/ActivityManager: Start proc 6171:com.xiaodianshi.tv.yst/... for activity
    {com.xiaodianshi.tv.yst/...VideoPlayActivity}
```

`am force-stop` 掉该应用后，窗口栈只剩桌面，隐患消除。**这类"全屏视频应用被杀/崩溃后留下无表面窗口"是本机黑屏的常见触发点。**

#### 6.6.5 该应用是什么（顺带澄清）

| 项目 | 值 |
|---|---|
| 包名 | `com.xiaodianshi.tv.yst` |
| 应用 | 云视听小电视（B 站 TV 版，CIBN 牌照；进程内有 `com.bilibili.lib.neuron`） |
| 版本 | 1.7.9（`versionCode 107900`） |
| 安装时间 | 2025-12-14 |
| 安装来源 | **`com.mipt.store` = SkyTvMarket（创维电视应用商店，`/system/app/SkyTvMarket-origin`）** |
| 位置 | `/data/app/...`，用户应用，非系统预装 |
| 自启 | 无 `BOOT_COMPLETED`，不会开机自启，只在被商店/广告拉起时运行 |

即：不是病毒，是**电视自带商店推送安装的 B 站 TV 客户端**。不需要时可用
`pm disable-user --user 0 com.xiaodianshi.tv.yst` 停用（可随时恢复），
它是 `/data/app` 应用，卸载也不影响系统。

> 内存提示：恢复桌面后 `MemAvailable` 仅 239 MB（桌面自身 PSS 167 MB），
> LTM 会持续杀后台；这类大屏应用留在后台会进一步挤压内存。

---

## 7. 结论与后续方向

### 7.1 已经跑通的闭环

1. **客户端**：无 root 的 VpnService + tun2socks + relay，按包名分流，单 APK 同时支持 Android 6 与 Android 10；
2. **接入**：Clash 订阅导入、节点测速、TLS 上游、DNS over TCP，固定美国节点可稳定播放；
3. **电视适配**：SmartTube 限清晰度解决 4K 黑屏；Instagram Lite 横屏补丁 + 验证码登录 + 遥控器无障碍映射；
4. **车机适配**：X 浏览器 + SmartTube 白名单，WiFi 热点与内置 4G 都能自动切换上游；
5. **可靠性**：开机自启、后方保活、UID 重注册、重启回归均验证通过。

### 7.2 仍未覆盖

| 事项 | 说明 |
|---|---|
| 长时间稳定性 | 未做 24h 以上连续运行观测 |
| 节点故障切换 | 目前靠人工固定节点，未做自动降级 |
| 订阅更新 | 换订阅需重新导入，未做定时更新 |
| 广告包根治 | 已可用 root 禁用（§4.8），PERSISTENT 包是否被系统强拉待实测 |
| 4K/VP9 硬解 | 硬件能力边界，只能靠限清晰度规避 |
| 车机 WebView 44 | 部分网页登录/验证流程可能不兼容 |

### 7.3 下一步建议

- 客户端增加 **DoH(443) 兜底**，降低对节点 53 端口策略的依赖；
- 增加节点健康检查与自动降级，而不是依赖“自动选最快”；
- 把白名单变更做成“保存即重启代理”，减少用户漏操作；
- 电视端把广告包压制做成可选的定时任务，并明确依赖 PC 的边界；
- 文档继续按“客户端 / 电视适配 / 车机适配”三块维护，避免再次分裂成两份。

---

## 附录 A：usrchan 逆向记录与密码算法

### A.1 目标信息

| 项目 | 值 |
|---|---|
| 路径 | `/system/xbin/usrchan` |
| 大小 | 15,676 bytes |
| 权限 | `-rwsr-x---`（root:shell，setuid） |
| 架构 | ELF32 / ARM / Thumb-2 |
| SHA-256 | `0A45AFAC4FC3107CE20AA4585639A4D80F38E517BECFE8FF60C30D51F780172E` |

该文件内嵌 `.gnu_debugdata`（xz 压缩的符号表），解压后可直接看到 `checkpw`、`encrypt`、`main` 等符号。

### A.2 还原出的关键函数

```c
// 0x1234  checkpw(char* input)
int checkpw(char* input) {
    std::string serial = android::base::GetProperty("ro.serialno", "");
    if (!serial.empty()) {
        encrypt(serial);
        size_t n = std::min(serial.size(), (size_t)22);
        return strncmp(input, serial.c_str(), n) == 0;
    }
    return strncmp(input, "skyworth", 8) == 0;
}

// 0x11cc  encrypt(std::string& s)
void encrypt(std::string& s) {
    for (size_t i = 0; i < s.size(); i++)
        s[i] = (uint8_t)(s[i] + i + 0x31);
    for (size_t i = 0; i < s.size(); i++)
        if ((uint8_t)s[i] >= 0x7b)
            s[i] = (uint8_t)(i + 0x61);
}
```

结论：

```text
password = encrypt(ro.serialno)     // 序列号非空
password = "skyworth"               // 序列号为空
```

### A.3 密码计算

Python：

```python
def usrchan_password(serial: str) -> str:
    out = []
    for i, c in enumerate(serial):
        v = (ord(c) + i + 0x31) & 0xff
        if v >= 0x7b:
            v = (i + 0x61) & 0xff
        out.append(chr(v))
    return ''.join(out)

print(usrchan_password("<ro.serialno>"))
```

PowerShell：

```powershell
function Get-UsrchanPassword([string]$Serial) {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Serial.Length; $i++) {
        $v = ([int][char]$Serial[$i] + $i + 0x31) -band 0xff
        if ($v -ge 0x7b) { $v = ($i + 0x61) -band 0xff }
        [void]$sb.Append([char]$v)
    }
    return $sb.ToString()
}
```

### A.4 执行 root 命令

```bash
adb shell "echo <password> | /system/xbin/usrchan root id"
# uid=0(root) gid=0(root) ... context=u:r:su:s0
```

PowerShell 封装（自动取序列号、算口令）：

```powershell
$Adb    = 'D:\AndroidDev\android-sdk\platform-tools\adb.exe'
$Device = '192.168.3.156:5555'

function Get-UsrchanPassword([string]$Serial) {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Serial.Length; $i++) {
        $v = ([int][char]$Serial[$i] + $i + 0x31) -band 0xff
        if ($v -ge 0x7b) { $v = ($i + 0x61) -band 0xff }
        [void]$sb.Append([char]$v)
    }
    return $sb.ToString()
}

function Invoke-Root([string]$Command) {
    $serial = ((& $Adb -s $Device shell getprop ro.serialno) -join '').Trim()
    $pw = Get-UsrchanPassword $serial
    & $Adb -s $Device shell "echo $pw | /system/xbin/usrchan root $Command"
}

Invoke-Root "id"
Invoke-Root "pm disable-user com.ktcp.launcher"
```

adb shell 便捷包装（放在 `/data/local/tmp/su`，每次仍要手输口令，不保存明文）：

```sh
#!/system/bin/sh
exec /system/xbin/usrchan root "$@"
```

### A.5 反汇编复现

```bash
# 1) 拉取
adb pull /system/xbin/usrchan

# 2) 解压 .gnu_debugdata（偏移/长度对应本版本）
python -c "import lzma; d=open('usrchan','rb').read()[0x32ee:0x32ee+0x68c]; open('usrchan_mini.debug','wb').write(lzma.decompress(d))"
llvm-readelf -sW usrchan_mini.debug | grep FUNC

# 3) 按 Thumb 反汇编关键函数
llvm-objdump -d --triple=thumbv7-linux-gnueabihf \
  --start-address=0x11cc --stop-address=0x1234 usrchan   # encrypt
llvm-objdump -d --triple=thumbv7-linux-gnueabihf \
  --start-address=0x1234 --stop-address=0x1320 usrchan   # checkpw
llvm-objdump -d --triple=thumbv7-linux-gnueabihf \
  --start-address=0x1320 --stop-address=0x1594 usrchan   # main
```

关键地址：`encrypt=0x11cc`、`checkpw=0x1234`、`main=0x1320`、`GetProperty=0x1594`。

### A.6 安全边界

- 仅 shell（属组 shell）可执行，普通应用无法调用；
- 口令可由序列号推导，等同于厂商后门；
- 不提供常驻 su daemon，重启后按需执行；
- `/` 为 dm-verity 只读且仅剩约 2.9MB，不建议 remount `/system`。

---

## 附录 B：关键脚本

> 使用前先改：`adb` 路径、设备序列号 / WiFi ADB 地址、签名口令。
> 所有写操作建议先记录原值，便于回滚。

### B.1 ADB 封装

```powershell
$Adb    = 'D:\AndroidDev\android-sdk\platform-tools\adb.exe'
$Serial = '0332493700221160007899'
$Wifi   = '192.168.3.156:5555'
function A { & $Adb -s $Serial @args }
```

### B.2 后台白名单签名（whitelist_tvpn.py）

用于把 TVPN 进程名加入 `com.skyworthdigital.backgroundwhitelist`，避免切前台后被系统杀。

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

### B.3 桌面 homewhitelist 签名（set_homewhitelist.ps1）

把第三方桌面加入 `com.skyworthdigital.homewhitelist`，签名写入 `com.forestdata.key`。

```powershell
$ErrorActionPreference = 'Stop'
$Adb = 'D:\AndroidDev\android-sdk\platform-tools\adb.exe'
$Dev = '192.168.3.156:5555'

function Q([string]$cmd) {
    ((& $Adb -s $Dev shell $cmd) 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
}

$stb  = (Q 'getprop persist.sys.hwconfig.stb_id').Trim()
$base = 'com.skyworthdigital.sky2dlauncher/com.android.provision/com.ktcp.launcher/com.xiaopaitech.plauncher'
$pkg  = 'me.efesser.flauncher'          # 目标桌面
$new  = "$base/$pkg"

$b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($new))
$hmac = New-Object System.Security.Cryptography.HMACSHA1
$hmac.Key = [Text.Encoding]::ASCII.GetBytes($stb)
$sig = (($hmac.ComputeHash([Text.Encoding]::ASCII.GetBytes($b64)) |
        ForEach-Object { $_.ToString('x2') }) -join '')

Q "cmd settings put system com.skyworthdigital.homewhitelist $new" | Out-Null
Q "cmd settings put secure com.forestdata.key $sig" | Out-Null

Q 'cmd settings get system com.skyworthdigital.homewhitelist'
Q 'cmd settings get secure com.forestdata.key'

# 设为默认 HOME
Q "cmd role add-role-holder android.app.role.HOME $pkg" | Out-Null
Q 'input keyevent 3' | Out-Null
```

### B.4 广告包禁用/恢复（fix-tv-adpackages.ps1）

```powershell
# fix-tv-adpackages.ps1
param([switch]$Quiet)

$ErrorActionPreference = 'SilentlyContinue'
$adb    = 'D:\AndroidDev\android-sdk\platform-tools\adb.exe'
$serial = '0332493700221160007899'
$wifi   = '192.168.3.156:5555'

$pkgs = @(
    'com.tianci.ad',
    # 2026-11-10 修订：不要整包禁用 ott.advert.app，否则所有应用都打不开；
    # 见 §4.9「事故与修订」，改为只禁用它的 AdvertBroadcastReceiver。
    # 'com.skyworthdigital.ott.advert.app',
    # 'com.skyworthdigital.ottstatsv2',   # PERSISTENT + system uid，压制会导致崩溃循环，勿动
    'com.skyworthdigital.logcollector',
    'com.skyworthdigital.autotest',
    'com.android.noticewidget',
    'com.skyworthdigital.ott.guide',
    'com.skyworthdigital.skycommonpropertymanager'
)

function Log($m) { if (-not $Quiet) { Write-Host $m } }

& $adb start-server | Out-Null

$online = $false
for ($i = 0; $i -lt 12; $i++) {
    if ((& $adb devices) -match "$serial\s+device") { $online = $true; break }
    Start-Sleep -Seconds 5
}
if (-not $online) {
    & $adb connect $wifi | Out-Null
    for ($i = 0; $i -lt 6; $i++) {
        if ((& $adb devices) -match "$serial\s+device|$wifi\s+device") { $online = $true; break }
        Start-Sleep -Seconds 5
    }
}
if (-not $online) { Log 'device not connected (USB/WiFi)'; exit 1 }

$target = if ((& $adb devices) -match "$serial\s+device") { $serial } else { $wifi }
Log "device online: $target"

foreach ($p in $pkgs) {
    & $adb -s $target shell am force-stop $p | Out-Null
    & $adb -s $target shell service call package 95 s16 $p i32 3 i32 0 i32 0 s16 com.android.shell | Out-Null
    Log "disabled: $p"
}

Start-Sleep -Seconds 2
Log '--- disabled packages ---'
& $adb -s $target shell "pm list packages -d"
```

有 root 后可改为：

```powershell
Invoke-Root "pm disable-user --user 0 com.ktcp.launcher"
# 广告包同理逐个执行
```

### B.5 TVPN 构建（build_tvpn.ps1）

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
    if (Test-Path $p) { Copy-Item $p (Join-Path $stage 'libcarvpnrelay.so') -Force }
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

### B.6 回滚清单

```powershell
# 1) 恢复默认桌面（删除自定义 homewhitelist）
A shell cmd settings delete system com.skyworthdigital.homewhitelist
A shell cmd settings delete secure com.forestdata.key
A shell cmd role add-role-holder android.app.role.HOME com.ktcp.launcher
A shell input keyevent 3

# 2) 恢复广告/统计包（ottstatsv2 本来就是 enabled，可不处理）
$pkgs = @('com.tianci.ad','com.skyworthdigital.ott.advert.app',
          'com.skyworthdigital.logcollector',
          'com.skyworthdigital.autotest','com.android.noticewidget',
          'com.skyworthdigital.ott.guide','com.skyworthdigital.skycommonpropertymanager')
foreach ($p in $pkgs) {
    A shell service call package 95 s16 $p i32 1 i32 0 i32 0 s16 com.android.shell
}

# 2b) 恢复 ott.advert.app 的启动广告接收器（如曾禁用）
A shell pm enable com.skyworthdigital.ott.advert.app/.broadcast.AdvertBroadcastReceiver

# 3) 恢复后台白名单（如曾追加 TVPN）
#    删除追加项并重新签名，或直接删除以下两项回到默认：
A shell cmd settings delete system com.skyworthdigital.backgroundwhitelist
A shell cmd settings delete secure com.forestdata.box

# 4) 关闭 WiFi ADB（安全）
A shell setprop persist.adb.tcp.port -1
```

### B.7 广告守卫脚本（ads_guard.sh）

```sh
#!/system/bin/sh
# Re-disable Skyworth ad/statistics packages after boot.
# NOTE 1: com.skyworthdigital.ottstatsv2 is intentionally excluded (PERSISTENT
#         system-uid app; suppressing it causes a boot-time crash loop).
# NOTE 2: com.skyworthdigital.ott.advert.app is intentionally excluded from the
#         whole-package list. It runs the app-launch ad pipeline (force-stop
#         target -> play ad -> restart target). Suspending it leaves every app
#         stuck with SuspendedAppActivity ("应用无法使用 / 该应用是由root所管理").
#         Instead only its ACTION_APP_OPEN receiver is disabled.
# NOTE 3: **NEVER use `pm suspend` on these packages.** Every Skyworth system
#         package shares uid 1000. Suspending any of them makes AppOps report
#         "Audio disabled for suspended package=... for uid=1000", which makes
#         AudioFlinger mute OTHER uid-1000 apps (极光桌面视频播放会完全没声音).
#         `pm disable-user` alone is enough.
LOG=/data/local/tmp/ads_guard.log
PKGS="com.skyworthdigital.skycommonpropertymanager com.skyworthdigital.logcollector com.tianci.ad com.skyworthdigital.autotest com.android.noticewidget com.skyworthdigital.ott.guide com.skyworthdigital.skywechatclient com.skyworthdigital.skyappupdate"

ADVERT_PKG=com.skyworthdigital.ott.advert.app
ADVERT_RCV=$ADVERT_PKG/.broadcast.AdvertBroadcastReceiver

while true; do
  for p in $PKGS; do
    pm disable-user --user 0 "$p" >/dev/null 2>&1
    # 修复历史遗留：曾用 suspend 会误伤同 uid 的音频 AppOps
    pm unsuspend --user 0 "$p" >/dev/null 2>&1
    am force-stop "$p" >/dev/null 2>&1
  done

  pm enable "$ADVERT_PKG" >/dev/null 2>&1
  pm unsuspend --user 0 "$ADVERT_PKG" >/dev/null 2>&1
  pm disable --user 0 "$ADVERT_RCV" >/dev/null 2>&1

  echo "$(date) guard tick" >> "$LOG"

  # 日志自截断：超过 500 行只保留最近 200 行
  n=$(wc -l < "$LOG" 2>/dev/null)
  if [ -n "$n" ] && [ "$n" -gt 500 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
  sleep 120
done
```

### B.8 安装/卸载开机钩子

> **已废弃（2026-11-10 修订）**：`run_clouddrive.sh` **不是**开机钩子，init 里的 `start_clouddrive` 是 `disabled`，没有触发者。把守卫写进它，重启后不会执行。请改用 [B.10](#b10-开机钩子脚本bootsh) 的 `sky_check` 方案。
>
> 下面仅保留作历史记录。

安装（历史方案，勿用）：

```sh
#!/system/bin/sh
# install_guard.sh
SRC=/data/xpclouddrive/run_clouddrive.sh
BAK=/data/local/tmp/run_clouddrive.sh.bak
NEW=/data/xpclouddrive/run_clouddrive.sh.new

chmod 755 /data/local/tmp/ads_guard.sh
[ -f "$BAK" ] || cp -p "$SRC" "$BAK"

if ! grep -q ads_guard "$SRC"; then
  {
    echo '#!/bin/sh'
    echo '( sleep 90; /data/local/tmp/ads_guard.sh ) >/dev/null 2>&1 &'
    tail -n +2 "$BAK"
  } > "$NEW"
  chown system:system "$NEW"
  chmod 711 "$NEW"
  mv "$NEW" "$SRC"
fi

nohup /data/local/tmp/ads_guard.sh >/dev/null 2>&1 &
```

调用：

```powershell
A push ads_guard.sh /data/local/tmp/ads_guard.sh
A push install_guard.sh /data/local/tmp/install_guard.sh
Invoke-Root "sh /data/local/tmp/install_guard.sh"
```

卸载（恢复原 clouddrive 脚本并停止守卫）：

```powershell
Invoke-Root "cp -p /data/local/tmp/run_clouddrive.sh.bak /data/xpclouddrive/run_clouddrive.sh"
Invoke-Root "pkill -f ads_guard.sh"
```

### B.9 极光桌面守卫脚本（aurora_guard.sh，已下线）

> **2026-11-11 下线**：极光桌面改为默认 HOME 并常驻，本脚本已从设备与交付包中删除。
> 决策与内存数据见 §4.12.9。以下代码仅作历史记录。

```sh
#!/system/bin/sh
# aurora_guard.sh
# 目的：从 FLauncher 进入极光桌面后，一旦退出（前台不再是 com.ktcp.launcher），
#       立刻 force-stop 极光桌面，释放其常驻的 250MB 左右内存。
# 说明：极光视频播放时前台仍是 com.ktcp.launcher（视频在 launcher 进程内），
#       所以播放中不会被误杀。
# 用法：setsid /data/local/tmp/aurora_guard.sh >/dev/null 2>&1 < /dev/null &

PKG=com.ktcp.launcher
GRACE=3
LOG=/data/local/tmp/aurora_guard.log
PIDFILE=/data/local/tmp/aurora_guard.pid

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }
memavail() { awk '/MemAvailable/{print $2}' /proc/meminfo; }

# 单实例：已在运行就直接退出
if [ -f "$PIDFILE" ]; then
    old=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$PIDFILE"

kill_if_bg() {
    cur=$(dumpsys activity activities 2>/dev/null | grep -m1 mResumedActivity)
    case "$cur" in
        *"$PKG/"*) return 0 ;;
    esac
    pid=$(pidof "$PKG" 2>/dev/null)
    [ -z "$pid" ] && return 0
    log "left $PKG (pid $pid) -> force-stop"
    am force-stop "$PKG" >/dev/null 2>&1
    sleep 1
    left=$(pidof "$PKG" 2>/dev/null)
    if [ -z "$left" ]; then
        log "released; MemAvailable=$(memavail) kB"
    else
        log "WARN still alive: $left"
    fi
}

log "aurora_guard start (pid $$)"
while true; do
    # 用 onResume 事件做触发（这个 ROM 上 am_resume_activity 记录不完整），
    # 触发后等 GRACE 秒让切换落定，再用 dumpsys 确认前台是否仍是极光桌面。
    logcat -b events -s am_on_resume_called:I 2>/dev/null | while read -r line; do
        sleep "$GRACE"
        kill_if_bg
    done
    log "logcat exited; restart in 10s"
    sleep 10
done
```

安装与开机自启：

```powershell
A push aurora_guard.sh /data/local/tmp/aurora_guard.sh
A shell chmod 755 /data/local/tmp/aurora_guard.sh
Invoke-Root "nohup sh /data/local/tmp/boot.sh >/dev/null 2>&1 &"
```

> 开机自启不要写进 `run_clouddrive.sh`——它不是开机钩子。见 [B.10](#b10-开机钩子脚本bootsh)。

### B.10 开机钩子脚本（boot.sh）

由 `/system/bin/sky_check.sh`（符号链接到本文件）在 `sys.boot_completed=1` 时以 root 调用。

```sh
#!/system/bin/sh
# /data/local/tmp/boot.sh
# init 的 sky_check 服务：user root、无 seclabel、sys.boot_completed=1 时启动。
# 不能直接退出：oneshot 服务结束时子进程可能被回收，所以最后 wait 常驻。

LOG=/data/local/tmp/boot.log

# 日志自截断：超过 2000 行只保留最近 500 行
if [ -f "$LOG" ]; then
    n=$(wc -l < "$LOG" 2>/dev/null)
    if [ -n "$n" ] && [ "$n" -gt 2000 ]; then
        tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
fi

echo "$(date '+%F %T') boot hook start (uid=$(id -u))" >> "$LOG"

# 保留原 sky_check 行为（系统重启/内存监控）
if [ -x /system/bin/sky_check.sh.orig ]; then
    /system/bin/sky_check.sh.orig >/dev/null 2>&1 &
    echo "$(date '+%F %T') sky_check.orig launched" >> "$LOG"
fi

# 极光桌面已改为默认 HOME 并常驻，不再需要“离开即杀”的 aurora_guard
# （2026-11-11 下线，见文档 §4.12.9）

# 广告/统计包守卫
sh /data/local/tmp/ads_guard.sh >/dev/null 2>&1 &

# 极光前贴片/中插广告拦截（frida-inject 设备端注入，eternalize 常驻）
if [ -x /data/local/tmp/frida-inject ] && [ -r /data/local/tmp/preroll_block.js ]; then
    sh /data/local/tmp/preroll_guard.sh >/dev/null 2>&1 &
    echo "$(date '+%F %T') preroll_guard launched" >> "$LOG"
else
    echo "$(date '+%F %T') preroll_guard skipped (frida-inject or script missing)" >> "$LOG"
fi

echo "$(date '+%F %T') guards launched, boot.sh stays alive" >> "$LOG"
wait
```

安装（root）：

```sh
mount -o rw,remount / 2>/dev/null
# 符号链接只占元数据，不占数据块；/system 写满时也能创建
cp /system/bin/sky_check.sh /data/local/tmp/sky_check.sh.bak
mv /system/bin/sky_check.sh /system/bin/sky_check.sh.orig
ln -sfn /data/local/tmp/boot.sh /system/bin/sky_check.sh
chmod 755 /data/local/tmp/boot.sh
```

验证：

```powershell
A shell getprop init.svc.sky_check          # running
A shell cat /data/local/tmp/boot.log
A shell ps -A -o PID,PPID,ARGS | findstr /C:"boot.sh" /C:"ads_guard" /C:"preroll_guard"
```

回滚：

```powershell
Invoke-Root "rm -f /system/bin/sky_check.sh && mv /system/bin/sky_check.sh.orig /system/bin/sky_check.sh"
Invoke-Root "pkill -f boot.sh; pkill -f ads_guard.sh; pkill -f preroll_guard.sh"
```

### B.11 前贴片/中插/暂停/后贴片拦截脚本（preroll_block.js / preroll_guard.sh）

#### preroll_block.js

注入到 `com.ktcp.launcher` 的 hook 脚本。拦 `adType` 1/2/3/4，其它广告位不动。

```javascript
/*
 * 极光桌面广告拦截（com.ktcp.launcher）
 * 挂 com.tencent.ads.view.c.a(AdRequest)：
 *   adType == 1  前贴片（QAdPreVideoImpl）
 *   adType == 2  暂停广告（QAdPauseVideoImpl）
 *   adType == 3  后贴片（QAdPostVideoImpl）
 *   adType == 4  中插（QAdMidVideoImpl）
 * 命中后直接返回 ErrorCode(143)，这是 SDK 官方的“无广告”路径，
 * 调用方 PlayerAdView.fireFailedEvent() -> onFailed()/onAdComplete()，
 * 广告结束并继续正片。
 *
 * 注意：角标/挂件（5/6/9/15/16/19/20）不在此处拦截；
 *       其中 19（THLS）是服务端拼接进 HLS，客户端 hook 去不掉。
 */
(function () {
    if (typeof Java === 'undefined') {
        console.log('[ad] Java bridge unavailable');
        return;
    }
    Java.perform(function () {
        var EC = Java.use('com.tencent.ads.view.ErrorCode');
        var C = Java.use('com.tencent.ads.view.c');
        var Log = Java.use('android.util.Log');
        var BLOCK = { 1: 'preroll', 2: 'pause', 3: 'postroll', 4: 'midroll' };
        var count = 0;

        C.a.overloads.forEach(function (ov) {
            ov.implementation = function (req) {
                try {
                    if (req != null) {
                        var type = req.getAdType();
                        if (BLOCK[type]) {
                            count++;
                            var kind = BLOCK[type];
                            try {
                                Log.i('TVPNAdHook', 'block ' + kind + ' #' + count + ' cid=' + req.getCid());
                            } catch (logErr) {}
                            console.log('[ad] blocked ' + kind + ' #' + count);
                            var e = EC.$new(143, kind + ' disabled by tvpn hook');
                            try {
                                e.setSplashErrorCode(22001, 'disable ' + kind + ' ad by hook');
                            } catch (x) {}
                            return e;
                        }
                    }
                } catch (err) {
                    console.log('[ad] hook error: ' + err);
                }
                return ov.call(this, req);
            };
        });

        try {
            Log.i('TVPNAdHook', 'hook installed: block adType 1/2/3/4');
        } catch (e) {}
        console.log('[ad] hook installed: adType 1(preroll), 2(pause), 3(postroll), 4(midroll)');
    });
})();
```

#### preroll_guard.sh

```sh
#!/system/bin/sh
# /data/local/tmp/preroll_guard.sh
# 极光桌面（com.ktcp.launcher）前贴片/中插广告拦截。
# 注入方式：设备端 frida-inject（不需要 PC、不需要 frida-server），
# 启动后 -e（eternalize）常驻，注入器进程退出不影响 hook。

PKG=com.ktcp.launcher
INJECT=/data/local/tmp/frida-inject
SCRIPT=/data/local/tmp/preroll_block.js
LOG=/data/local/tmp/preroll_guard.log
PIDFILE=/data/local/tmp/preroll_guard.pid

# 单实例
if [ -f "$PIDFILE" ]; then
    old=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old" ] && [ -r "/proc/$old/cmdline" ] && \
       tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q preroll_guard; then
        exit 0
    fi
fi
echo $$ > "$PIDFILE"

log() {
    echo "$(date '+%F %T') $*" >> "$LOG"
    lines=$(wc -l < "$LOG" 2>/dev/null)
    [ -n "$lines" ] && [ "$lines" -gt 2000 ] && tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

[ -x "$INJECT" ] || { log "fatal: $INJECT missing/not executable"; exit 1; }
[ -r "$SCRIPT" ] || { log "fatal: $SCRIPT missing"; exit 1; }

log "start (uid=$(id -u))"
last=""

while true; do
    pid=$(pidof "$PKG" 2>/dev/null | awk '{print $1}')
    if [ -z "$pid" ]; then
        last=""
        sleep 2
        continue
    fi
    if [ "$pid" != "$last" ]; then
        sleep 2
        pid=$(pidof "$PKG" 2>/dev/null | awk '{print $1}')
        [ -z "$pid" ] && continue
        out=$("$INJECT" -p "$pid" -s "$SCRIPT" -e 2>&1)
        rc=$?
        case "$out" in
            *"hook installed"*) log "injected pid=$pid rc=$rc" ;;
            *) log "inject pid=$pid rc=$rc out=$(echo "$out" | tr '\n' ' ' | cut -c1-200)" ;;
        esac
        last="$pid"
    fi
    sleep 2
done
```

部署：

```powershell
A push frida-inject     /data/local/tmp/frida-inject
A push preroll_block.js /data/local/tmp/preroll_block.js
A push preroll_guard.sh /data/local/tmp/preroll_guard.sh
Invoke-Root "chmod 755 /data/local/tmp/frida-inject /data/local/tmp/preroll_guard.sh"
Invoke-Root "sh /data/local/tmp/preroll_guard.sh >/dev/null 2>&1 &"
```

> `frida-inject` 版本要与设备端注入协议匹配（本次 16.7.19 / android-arm，22 MB）。
> 它只在注入瞬间运行几十毫秒，不常驻内存。

---

> 本文由两份文档合并而成，重点保留结论、命令与踩坑；完整反汇编取证、广告链路抓包记录、bootloader 实测过程见原文档：
> - `carvpn-internal-docs/superpowers/specs/2026-11-04-car-esim-vpn-client-design.md`
> - `Q6011-无root改造与TVPN部署.md`
