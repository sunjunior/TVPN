# TVPN

<p align="center"><img src="assets/logo.png" width="128" alt="TVPN logo"></p>

> 一款适合安卓 6.0 以上车机系统或者网络机顶盒的轻量级 VPN 工具

通用型横屏 VPN 客户端：系统级 `VpnService` + 本地 SOCKS5 relay（native）+ [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)，
**只把白名单应用的流量**转发到订阅里的 HTTP CONNECT 代理节点，其余应用照常直连。

- **包名**：`com.tvpn.client`
- **版本**：1.1.1（versionCode 3）
- **最低系统**：Android 5.0（API 21）；`targetSdk 23`
- **ABI**：`armeabi-v7a`、`arm64-v8a`（Releases 里按 ABI 分包，另有 universal 通用包）
- **界面**：横屏优先，内容区最大宽度 840dp，宽屏居中、窄屏铺满
- **签名**：`CN=CarVPN, OU=M1, O=SunJunior`（SHA-256 `6cef2533…59397612`）

> 仓库内不包含任何订阅链接、节点地址、账号密码或签名密钥；节点数据只保存在设备应用的私有目录里。

## 适用场景

- 运行 Android 5.0+ 的**横屏设备**：车机、平板、电视盒子、广告机等；
- 只需要**少数应用**走代理，其余应用必须保持直连（例如本地播放器、播控类应用、内网应用）；
- 设备**不能改系统**：无 root、不能改 hosts、不能装 Xposed / 框架、全局 `http_proxy` 不生效或会连带影响其它应用。

这类设备上全局代理往往不可用：要么系统设置项残缺，要么会让不该走代理的应用直接失效。
本项目的做法是把代理范围收敛到**包名白名单**——`VpnService` 只用 `addAllowedApplication`
放行白名单内的应用，其它应用连 tun 路由都收不到，行为与未安装 VPN 完全一致。

## 功能

- **订阅导入**：解析 Clash / 通用订阅 YAML，只取 `type: http` 节点，自动识别 `tls: true`
- **多节点管理**：下拉选择、协议标注（`· TLS` / `· 明文`）、持久化
- **自动选路**：TCP 预筛 + 分批「TLS 握手 + CONNECT 200」完整探活，按时延选最快可用节点
- **故障切换**：运行期看门狗检测节点健康，连续失败自动切换；上游连续拒绝也会触发切换
- **按应用代理**：只代理白名单包名，其余应用完全不受影响
- **开机自启**：`BootReceiver` 在 `BOOT_COMPLETED` 后拉起前台 `VpnService`（首次仍需手动授权一次）
- **出口网络自适应（WiFi-first）**：有 WiFi 走 WiFi，没有走以太网，再退蜂窝；relay、TLS 适配器、探活统一绑定同一出口
- **隧道内 DNS**：UDP/53 转 DNS-over-TCP 经节点转发，带污染检测与多解析器回退
- **加密上游**：`tls: true` 节点由本地 TLS 适配器终结外层 TLS，链路上看不到内层 SNI
- **横屏自适应**：内容区最大宽度 840dp，宽屏居中、窄屏铺满

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
| `MainActivity.java` | UI：订阅、节点选择、白名单、启停；横屏自适应布局 |
| `EsimVpnService.java` | `VpnService` 主体：配置 tun、启动 relay / 隧道、看门狗与故障切换、通知 |
| `CarVpnTunnel.java` | hev-socks5-tunnel 的 JNI 绑定与配置生成（`cache/hev_current.yml`） |
| `CarVpnRelay.java` | relay 可执行文件（`libcarvpnrelay.so`）与端口常量（8101） |
| `TlsUpstream.java` | TLS 上游适配器：为明文 CONNECT 节点套一层本地 TLS |
| `NodeProbe.java` | TCP 预筛 + TLS + `CONNECT 200` 完整探活，输出 `tcp=…ms full=…ms` |
| `NodeStore.java` / `NodeConfig.java` | 多节点持久化、编解码与参数校验 |
| `SubImporter.java` | 订阅解析（Clash / 通用 YAML，只收 `type: http`） |
| `HttpFetcher.java` | 拉订阅：证书链 + 绑定出口网络的 HTTP(S) 客户端 |
| `UpstreamNet.java` | 出口网络选择（WiFi → 以太网 → 蜂窝 → 其它，优先系统已验证网络） |
| `WhitelistStore.java` | 白名单包名存储 |
| `BootReceiver.java` | 开机自启 |

### 三个关键设计

1. **relay / 探活 socket 必须绑定真实出口。**
   部分 ROM 的 VPN 是全局的（没有 `uidrange`），如果上游连接不显式 `bindProcessToNetwork`，
   就会把自己的隧道套进 tun，形成回环。`UpstreamNet` 因此严格按 WiFi → 以太网 → 蜂窝 → 其它排序，
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
│   ├── build.gradle                          # applicationId com.tvpn.client / targetSdk 23 / 多 ABI
│   └── src/
│       ├── main/
│       │   ├── AndroidManifest.xml
│       │   ├── java/com/tvpn/client/          # 13 个类，见上表
│       │   ├── jni/                           # relay 源码 + Android.mk / Application.mk
│       │   ├── jniLibs/                       # 构建时生成的 relay 可执行文件（gitignore）
│       │   └── res/                           # 布局、图标、banner、extra_roots.pem
│       └── test/java/com/tvpn/client/         # JVM 单元测试
├── assets/logo.png                            # README 用图标（与 APK 启动图标一致）
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

- 上游：[hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) `0c68850`
- 源码包 SHA-256：`aef4c3abb9614c17be3a758260f4b40fd557a33a99c16d59871c18e0101cf10e`

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

## 安装与使用

```bash
adb install -r app-release.apk
adb shell am start -n com.tvpn.client/.MainActivity
# 首次启动在界面上授权 VPN（系统会记住，之后 BootReceiver 可自动拉起）
```

1. 打开应用，首次启动授予 VPN 权限。
2. 填入 Clash / 通用订阅链接，点「导入订阅」（只导入 `type: http` 节点）。
3. 勾选「自动选择最快可用节点」会立即探活并选路；也可在下拉框手动选。
4. 在「分流白名单包名」里填需要代理的包名，逗号或空格分隔，例如：

   ```text
   com.google.android.youtube, com.netflix.ninja, com.instagram.android
   ```

5. 点「启动代理」。运行期间可在通知栏停止，或回到应用点「停止代理」。

排查：

```bash
adb logcat -s tvpn tvpn-relay
adb shell dumpsys connectivity | grep -i vpn
adb shell ps -A | grep -i tvpn
adb shell dumpsys activity services com.tvpn.client | grep -E 'ServiceRecord|isForeground'
```

`tvpn` 标签下能看到选中的节点、TLS 适配器端口、逐节点探活结果（`tcp=…ms full=…ms`）；
`tvpn-relay` 是原生 relay 的日志。

## 已知限制

- 只支持 HTTP CONNECT 上游（`type: http`）；`socks5` / `ss` / `vmess` / `tuic` 等节点导入时会被跳过。
- 除 DNS 外不转发 UDP，走 QUIC（UDP 443）的应用会回退 TCP，首次连接可能偏慢。
- 只提供 `armeabi-v7a` / `arm64-v8a` 两种 ARM 包；x86 模拟器需要自行编译。
- `targetSdk 23`，不满足 Google Play 上架要求。
- 白名单修改后需要重启代理才生效。
- 节点可用性依赖出口链路：同一订阅里可能有部分地区节点的 TLS 握手被链路丢弃，自动选路会避开。
- 可播放内容、推荐内容受节点出口地区与版权授权影响，属于内容侧限制，不是隧道故障。

## 安全说明

- 订阅链接、节点账号密码只保存在应用私有 `SharedPreferences`（`node_store`），不写源码、不写日志。
- `res/raw/extra_roots.pem` 只含公共根证书（补齐 Android 6 缺失的 ISRG Root），不含私钥。
- 发布用 keystore 放在仓库外，由构建脚本通过环境变量读取。
- 原生依赖以源码包随仓库分发，构建前可核对上面的 SHA-256。

## 致谢

- [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)（MIT）及其子模块：tun 转发与 SOCKS5 客户端
- [lwIP](https://savannah.nongnu.org/projects/lwip/)：轻量 TCP/IP 协议栈

## 许可

本项目采用 **GNU General Public License v3.0（GPLv3）**，完整条款见 [LICENSE](LICENSE)。

第三方组件 `hev-socks5-tunnel` 采用 MIT 协议，与 GPLv3 兼容；分发包含该组件的二进制时，
需保留其版权与许可声明。
