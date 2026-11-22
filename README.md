# TVPN

> 一款适合安卓 6.0 以上车机系统或者网络机顶盒的轻量级 VPN 工具

一套 APK 同时跑在 **Android 车机** 和 **Android 电视盒子** 上的按应用 VPN 客户端：
系统级 `VpnService` + 本地 SOCKS5 relay（native）+ [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)，
只把「白名单里的应用」的流量转发到订阅中的 HTTP CONNECT 代理节点，其它应用照常直连。

- **包名**：`com.tvpn.client`（旧名 `com.sunjunior.caresimvpn` / CarVPN）
- **版本**：1.1.0（versionCode 2）
- **最低系统**：Android 5.0（API 21）；`targetSdk 23`（同时兼容车机 Android 6.0 与盒子 Android 10）
- **ABI**：仅 `armeabi-v7a`
- **签名**：`CN=CarVPN, OU=M1, O=SunJunior`（SHA-256 `6cef2533…59397612`）

> 仓库内不包含任何订阅链接、节点地址、账号密码或签名密钥；节点数据只保存在设备应用的私有目录里。

## 背景

这套客户端不是通用翻墙工具，而是为两台"改不动系统"的设备做的：

| 设备 | 车机 | 电视盒子 |
|---|---|---|
| 型号 | 别克英朗 AC8317 | 创维 Q6011（eros-p1） |
| SoC / 系统 | MT6735 / Android 6.0 | Amlogic / Android 10 |
| 屏幕 | 1024×600 横屏 | 1920×1080 @320dpi |
| 限制 | 无 GMS、系统设置项残缺、不能全局改代理 | 无 root、系统签名校验、不能改 hosts / 装 Xposed |
| 需求 | QQ 音乐、车机浏览器等少数应用要能出网 | YouTube / Netflix / Instagram 等要能出网，同时 B 站、播控应用必须直连（地区版权） |

两条路都被设备堵死了：改 `/etc/hosts`、全局 `http_proxy`、装框架都不现实，而且全局代理会让播控类应用
直接不可用。所以统一走 **`VpnService` + 按应用白名单**：VPN 只对白名单包名生效（`addAllowedApplication`），
其余应用收不到 tun 路由，行为和没装 VPN 完全一样。

两端共用一个 APK 的代价是版本要迁就低端：`targetSdk 23`、只打 `armeabi-v7a`、UI 用最大宽度 840dp 的自适应布局，
同一个包名换机安装即可，同签名可以互相覆盖升级。

## 下载

预编译 APK 见 [Releases](https://github.com/sunjunior/tvpn/releases)；当前源码版本为 **1.1.0**。
安装包由 GitHub Actions 在打标签时构建（签名材料通过 secrets 注入，不进仓库）。

## 功能

- **订阅导入**：解析 Clash / 通用订阅 YAML，只取 `type: http` 节点，自动识别 `tls: true`
- **多节点管理**：下拉选择、协议标注（`· TLS` / `· 明文`）、持久化
- **自动选路**：TCP 预筛 + 分批「TLS 握手 + CONNECT 200」完整探活，按时延选最快可用节点
- **故障切换**：运行期看门狗检测节点健康，连续失败自动切换；上游连续拒绝也会触发切换
- **按应用代理**：只代理白名单包名，其余应用完全不受影响
- **开机自启**：`BootReceiver` 在 `BOOT_COMPLETED` 后直接拉起前台 `VpnService`（首次仍需手动授权一次）
- **出口网络自适应（WiFi-first）**：有 WiFi 走 WiFi，没有走 eth0，再退蜂窝；relay、TLS 适配器、探活统一绑定同一出口
- **隧道内 DNS**：UDP/53 转 DNS-over-TCP 经节点转发，带污染检测与多解析器回退
- **加密上游**：`tls: true` 节点由本地 TLS 适配器终结外层 TLS，链路上看不到内层 SNI
- **宽屏自适应**：内容区最大宽度 840dp，宽屏居中、窄屏铺满；同一 APK 适配车机与电视

## 软件架构

### 数据流

```text
被代理应用（白名单包名）
        │  普通 socket
        ▼
VpnService tun：26.26.26.1/32，DNS 26.26.26.2，route 0.0.0.0/0，MTU 1400
        │  tun fd 通过 JNI 交给原生层
        ▼
hev-socks5-tunnel（libhev-socks5-tunnel.so，lwIP 用户态协议栈）
        │  SOCKS5
        ▼
127.0.0.1:8101  native relay（libcarvpnrelay.so，独立进程）
        │
   ┌────┴─────────────────────────────┐
   │ TCP                              │ UDP/53
   ▼                                  ▼
HTTP CONNECT 上游                DNS-over-TCP（2 字节长度前缀）
   │                                  │
   │  tls:true ? TlsUpstream（127.0.0.1:<临时端口>，SNI=节点域名）
   └────────────────┬─────────────────┘
                    ▼
                 代理节点 ──▶ 目标站点
```

### 模块划分

| 文件 | 职责 |
|---|---|
| `MainActivity.java` | UI：订阅、节点选择、白名单、启停；宽屏自适应布局 |
| `EsimVpnService.java` | `VpnService` 主体：配置 tun、启动 relay / 隧道、看门狗与故障切换、通知 |
| `CarVpnTunnel.java` | hev-socks5-tunnel 的 JNI 绑定与配置生成（`cache/hev_current.yml`） |
| `CarVpnRelay.java` | relay 可执行文件（`libcarvpnrelay.so`）与端口常量（8101） |
| `TlsUpstream.java` | TLS 上游适配器：为明文 CONNECT 节点套一层本地 TLS |
| `NodeProbe.java` | TCP 预筛 + TLS + `CONNECT 200` 完整探活，输出 `tcp=…ms full=…ms` |
| `NodeStore.java` / `NodeConfig.java` | 多节点持久化、编解码与参数校验 |
| `SubImporter.java` | 订阅解析（Clash / 通用 YAML，只收 `type: http`） |
| `HttpFetcher.java` | 拉订阅：证书链 + 绑定出口网络的 HTTP(S) 客户端 |
| `UpstreamNet.java` | 出口网络选择（WiFi → eth0 → 蜂窝 → 其它，优先系统已验证网络） |
| `WhitelistStore.java` | 白名单包名存储 |
| `BootReceiver.java` | 开机自启 |

### 三个绕不开的设计决策

1. **relay / 探活 socket 必须绑定真实出口。**
   这台车机的 VPN 是全局的（没有 `uidrange`），如果上游连接不显式 `bindProcessToNetwork`，
   就会把自己的隧道套进 tun，形成回环。`UpstreamNet` 因此严格按 WiFi → eth0 → 蜂窝 → 其它排序，
   并跳过 `TRANSPORT_VPN`。

2. **`tls: true` 节点必须有本地 TLS 适配器。**
   relay 只会发明文 CONNECT，而订阅里的节点是 HTTPS 代理。`TlsUpstream` 监听
   `127.0.0.1:<临时端口>`，对节点完成 TLS（SNI=节点域名）后再转发 CONNECT，双向透传。

3. **DNS 不能直连。**
   tun 内的 DNS 请求交给 relay，用 `CONNECT resolver:53` 转成 DNS-over-TCP，
   避开 UDP 被链路丢弃；对 `198.18.0.0/15`、`0.0.0.0` 这类污染结果会自动换解析器重试。

另外两个实现约定：配置固定单文件 `cache/hev_current.yml`（每次启动覆盖，不随启动次数增长）；
白名单改动后需要重启代理才生效（tun 的 `addAllowedApplication` 只在建立时生效）。

## 目录结构

```text
.
├── app/
│   ├── build.gradle                          # applicationId com.tvpn.client / targetSdk 23 / armeabi-v7a
│   └── src/
│       ├── main/
│       │   ├── AndroidManifest.xml
│       │   ├── java/com/tvpn/client/          # 13 个类，见上表
│       │   ├── jni/                           # relay 源码 + Android.mk / Application.mk
│       │   ├── jniLibs/                       # 构建时生成的 relay 可执行文件（gitignore）
│       │   └── res/                           # 布局、图标、banner、extra_roots.pem
│       └── test/java/com/tvpn/client/         # JVM 单元测试
├── docs/
│   ├── VENDORED.md                            # 原生依赖版本 / SHA256 / JNI 接口
│   ├── Q6011-无root改造与TVPN部署.md          # 电视盒子侧部署与排障
│   ├── TVPN-科学上网客户端开发与影音适配.md    # 开发过程、影音适配与实测记录
│   ├── probe-results.md                       # 早期节点探测记录（历史资料）
│   └── evidence/                              # 机顶盒取证材料
├── scripts/
│   ├── fetch_deps.sh                          # 解压内置的 hev-socks5-tunnel 源码包
│   └── build-release.{sh,bat}                 # release 构建 + 签名
├── third_party/hev-socks5-tunnel-0c68850.tar.gz
├── gradlew / gradlew.bat                      # Gradle Wrapper 8.9
└── .github/workflows/build.yml                # CI：单测 + APK 构建（打标签时签名）
```

## 构建

### 环境

- JDK 17
- Android SDK：`platforms;android-34`、`build-tools;34.0.0`
- NDK：`26.3.11579264`
- 环境变量：`ANDROID_HOME`（或 `ANDROID_SDK_ROOT`）

### 解压原生依赖

```bash
./scripts/fetch_deps.sh
```

脚本把 `third_party/hev-socks5-tunnel-0c68850.tar.gz` 解压到 `app/src/main/cpp/`（该目录被 `.gitignore` 忽略）。
版本与 SHA256 见 [docs/VENDORED.md](docs/VENDORED.md)。

### 单元测试与 Debug 构建

```bash
./gradlew test
./gradlew assembleDebug      # 产物 app/build/outputs/apk/debug/app-debug.apk
```

### Release 构建与签名

签名材料不进入仓库，`app/build.gradle` 通过环境变量读取：

```bash
export KEYSTORE_PATH=/path/to/release.jks
export KEYSTORE_PASSWORD='***'
export KEY_ALIAS=carvpn
export KEY_PASSWORD='***'
./gradlew assembleRelease    # 产物 app/build/outputs/apk/release/app-release.apk
```

也可以用 `scripts/build-release.sh`（Windows: `scripts\build-release.bat`），它会先编译 relay、
拷入 `jniLibs`，再 `assembleRelease` + `zipalign` + `apksigner`（v1 + v2）。

> 换签名后覆盖安装会失败，需要先卸载旧版本。

## 部署

### 车机（Android 6.0）

```bash
adb install -r app-release.apk
adb shell am start -n com.tvpn.client/.MainActivity
# 首次启动在界面上授权 VPN（系统会记住，之后 BootReceiver 可自动拉起）
```

### 电视盒子（创维 Q6011 / Android 10 / 无 root）

```bash
adb connect 192.168.3.156:5555
adb install -r app-release.apk
adb shell dumpsys package com.tvpn.client | grep -E 'versionName|versionCode'
adb shell am start -n com.tvpn.client/.MainActivity
```

盒子侧注意：

- 首次仍需在界面上点一次「允许」授予 VPN 权限，之后开机自动生效；
- 白名单里只放需要出网的应用（如 `com.google.android.youtube`、`com.netflix.ninja`），
  播控类应用不要加进去，否则会因为出口地区不符直接不可用；
- 验证是否在跑：`adb shell ps -A | grep -i tvpn` 与
  `adb shell dumpsys activity services com.tvpn.client | grep -E 'ServiceRecord|isForeground'`。

详细的盒子改造与排障见 [docs/Q6011-无root改造与TVPN部署.md](docs/Q6011-无root改造与TVPN部署.md)。

## 使用

1. 安装 APK 并打开，首次启动授予 VPN 权限。
2. 填入 Clash / 通用订阅链接，点「导入订阅」（只导入 `type: http` 节点）。
3. 勾选「自动选择最快可用节点」会立即探活并选路；也可在下拉框手动选。
4. 在「分流白名单包名」里填需要代理的包名，逗号或空格分隔，例如：

   ```text
   com.tencent.qqmusiccar, com.tencent.qqlive.audiobox, com.mmbox.xbrowser
   com.google.android.youtube, com.netflix.ninja, com.instagram.android
   ```

5. 点「启动代理」。运行期间可在通知栏停止，或回到应用点「停止代理」。

排查：

```bash
adb logcat -s tvpn tvpn-relay
adb shell dumpsys connectivity | grep -i vpn
```

`tvpn` 标签下能看到选中的节点、TLS 适配器端口、逐节点探活结果（`tcp=…ms full=…ms`）；
`tvpn-relay` 是原生 relay 的日志。

## 已知限制

- 只支持 HTTP CONNECT 上游（`type: http`）；`socks5` / `ss` / `vmess` / `tuic` 等节点导入时会被跳过。
- 除 DNS 外不转发 UDP，走 QUIC（UDP 443）的应用会回退 TCP，首次连接可能偏慢。
- 仅打包 `armeabi-v7a`，不适用于 64 位设备。
- `targetSdk 23` 是为车机 Android 6.0 兼容性固定，不满足 Google Play 上架要求。
- 白名单修改后需要重启代理才生效。
- 节点可用性依赖出口链路：同一订阅里可能有部分地区节点的 TLS 握手被链路丢弃，自动选路会避开。
- 可播放内容、推荐内容受节点出口地区与版权授权影响，属于内容侧限制，不是隧道故障。

## 安全说明

- 订阅链接、节点账号密码只保存在应用私有 `SharedPreferences`（`node_store`），不写源码、不写日志。
- `res/raw/extra_roots.pem` 只含公共根证书（补齐 Android 6 缺失的 ISRG Root），不含私钥。
- 发布用 keystore 放在仓库外，由构建脚本通过环境变量读取。
- 原生依赖以源码包随仓库分发，构建前可核对 [docs/VENDORED.md](docs/VENDORED.md) 的 SHA256。

## 文档

- [docs/VENDORED.md](docs/VENDORED.md)：原生依赖版本、JNI 接口与配置字段
- [docs/TVPN-科学上网客户端开发与影音适配.md](docs/TVPN-科学上网客户端开发与影音适配.md)：开发过程、影音适配与实测
- [docs/Q6011-无root改造与TVPN部署.md](docs/Q6011-无root改造与TVPN部署.md)：机顶盒无 root 部署、adb/权限/排障
- [docs/probe-results.md](docs/probe-results.md)：早期节点探测记录（历史资料）

## 致谢

- [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)（MIT）及其子模块：tun 转发与 SOCKS5 客户端
- [lwIP](https://savannah.nongnu.org/projects/lwip/)：轻量 TCP/IP 协议栈

## 许可

本项目采用 **GNU General Public License v3.0（GPLv3）**，完整条款见 [LICENSE](LICENSE)。

第三方组件 `hev-socks5-tunnel` 采用 MIT 协议，与 GPLv3 兼容；分发包含该组件的二进制时，
需保留其版权与许可声明（见 [docs/VENDORED.md](docs/VENDORED.md)）。
