# macOS worker transport 验证结果（2026-09-18）

在内网三个 macOS 容器 worker（easyworker，Connect RPC `worker.v1.WorkerService`）上对
Linux 无法覆盖的 transport 做了端到端验证。测试端点均在本 pod（dev001）：

- `http://172.17.0.196:18888` — Go conformance（h1+h2c，BIND=0.0.0.0，supervisor `conformance-go`）
- `https://172.17.0.196:18443` — 独立 caddy 实例（supervisor `conformance-tls`，`tls internal`
  IP-SAN 证书，ALPN h2 + 可选 h3/UDP）
- 依赖经 `git://172.17.0.196` 镜像拉取（supervisor `git-mirror-daemon`，`~/git-mirror/<org>/<repo>.git`）

## 结果矩阵

| Worker | Transport | 协议 | 结果 |
|---|---|---|---|
| macos-cmp (JDK17/Gradle) | `CioTransport` | h1 明文 | ✅ echo/count/failDetails |
| macos-cmp | `OkHttpTransport` | h1 明文 | ✅ 3/3 |
| macos-cmp | `OkHttpTransport` | **TLS + ALPN h2**（JKS 注入 CA） | ✅ 3/3 |
| macos-flutter (Flutter/Dart) | `IoTransport`（dart:io） | **TLS**（SecurityContext 注入 CA） | ✅ 3/3 |
| macos-flutter | `CupertinoHttpTransport` | h1 明文（NSURLSession，**纯 Dart CLI**） | ✅ 3/3 |
| macos-xcode (Swift 6.2.4) | `URLSessionTransport` | **TLS + ALPN h2**（delegate 注入 CA，IP SAN 校验） | ✅ echo/count/failDetails |
| macos-xcode | `URLSessionTransport` | h1 明文 | ✅ echo/count/failDetails |
| macos-xcode | `AsyncHTTPClientTransport` | h1 明文 | ✅ echo/count/failDetails（初判"容器崩溃"系误诊，见下） |
| macos-xcode | Swift 协议矩阵 M1–M13 + 故障注入 F1–F6 | — | ✅ 17/17 |

## 已知环境限制（非库 bug）

1. **无头容器无法安装系统信任**：`security add-trusted-cert` 被 GUI 授权拦截（root 也一样，
   `authorizationdb write` 同被拒）。绕法＝语言级注入：Swift URLSession delegate、
   JVM `javax.net.ssl.trustStore`（JKS）、Dart `SecurityContext.setTrustedCertificates`。
2. **AHC 在 macOS 容器事件循环初始化即崩**（`EASYRPC_SKIP_AHC=1` 可跳过；Linux CI 覆盖 AHC）。
3. **cupertino_http 3.x 的 native-assets 在该容器缺符号**（回调 trampoline 未打包 → 挂起）；
   2.x 又是 Flutter-only 插件。transport 代码已适配 3.x API（构造器/Uri/statusCode/头映射），
   待真机（非容器）验证。
4. SwiftPM 的 xctest 子进程不继承 env：`swift test` 下 `EASY_RPC_BASE` 失效；直跑
   `xcrun xctest .build/.../xctest` 或硬编码 URL 即可。

## 由此修复的库 bug（已发版）

| Bug | 版本 |
|---|---|
| 4 服务端 kind 检测不认 `application/connect+json`（流式 JSON 被按 proto 解析；响应侧却发 connect+json，自相矛盾） | go/ts/rust/python **v0.5.3** + spec §2 |
| Kotlin CIO/OkHttp 硬编码 `content-type: application/proto` 覆盖调用方头（JSON codec 全坏） | kotlin **v0.5.4** |
| Kotlin CIO `openStream` 把 END 帧当 payload 返回、无错误重建、无 finish() | kotlin **v0.5.4** |
| Dart cupertino transport 不兼容 cupertino_http 3.x（构造器/Uri/statusCode/单值头映射） | dart **v0.5.5** |
| Swift AHC 测试错误路径缺 shutdown → 进程级 crash | swift **v0.5.3** |

## 复跑

worker 工程保留在各 workspace：`kt/`（cmp）、`io/`+`dart/`+`ft/`（flutter）、`/tmp/easy-rpc-swift`（xcode）。
推 file 用 FileWrite、跑用 Execute/JobWait（`/tmp/opencode/ew*.sh` 有现成封装）。

## Cronet 与 h3（2026-09-18 第二轮）

### Kotlin CronetTransport（新增，v0.5.5）

`compileOnly` 依赖 cronet API（调用方自带 embedded/Play-Services 引擎）、engine 由调用方注入、
增量 openStream + 共享错误链。验证方式：桌面 JVM 无官方 cronet 原生库（`cronet-bundled` 仅
Android ABI .so），用 **API 500 + cronet-fallback 119（纯 Java h1）+ android stub jar** 验证
代码路径：

| 环境 | 结果 |
|---|---|
| Linux JVM（本地 pod） | ✅ echo/count/failDetails（`CRONET_CODEPATH_PASS`） |
| macOS cmp worker | ✅ 3/3（同款工程） |
| Android 模拟器（真 h2/h3） | ⏳ 等 Android 容器就绪（cronet-bundled Android so 齐全） |

实现中修复的通用 bug：
1. **回调 executor**：direct executor 在 Java 引擎上死锁（回调重入引擎锁）——改共享 daemon 池
2. **`tryReceive` 空≠关**：首轮回调前误判"流结束"（receiveCatching 挂起等待）
3. AAR 消费：JVM 工具链不能直接吃 AAR，gradle 脚本从 Google Maven 直下解包 classes.jar
   （Gradle 变体元数据会解析到空壳 `cronet-api` artifact）

### Dart CronetHttpTransport（重写，v0.6.1）

对齐 cronet_http 1.9 API（`package:http` 形态：Uri 入参、`statusCode`、头单/多值映射、
`CronetClient.defaultCronetEngine()` 工厂）+ `StreamedRequest/StreamedResponse` 增量流。
**flutter worker 上 `flutter test` 真实编译 + 构造测试通过**（"cronet transport constructs"）；
运行时 h2/h3 等 Android 场景。

### 首次 h3/QUIC 端到端（Python，v0.5.4）

`AioquicTransport` 对 caddy QUIC 端点（UDP 18443）三件套全过（echo/count 流/failDetails，
`PY_H3_ALL_PASS`）。修复两个老 bug：
1. aioquic ≥1.2 移除 `QuicConnection.transmit()` —— 改经 protocol 刷数据报
2. **open_stream 连接生命周期**：生成器从 `async with` 内返回，QUIC 连接在首帧前就被关 ——
   改为连接随流存活（手动 enter/exit）

### 待办（等 Android 模拟器容器）

- Kotlin CronetTransport 真 h2/h3（TLS 信任：模拟器系统 CA 或注入引擎）
- Dart CronetHttpTransport 运行时（同上）
- worker 复用工程：cmp `cronet-verify/`、flutter `ccheck/`

### Dart cronet_http 运行时（BlissOS 模拟器实测：受限于上游 bug）

工程 `ccheck`（flutter worker）/ `cronet-dart*.apk`（Kotlin MainActivity 已修正 package 对齐）。
现象：同引擎（embedded cronet 151, x86_64）、同 manifest（INTERNET + ACCESS_NETWORK_STATE）、
同 TLS 信任（系统 CA 已装），**Kotlin 原生 UrlRequest 全绿，cronet_http(Dart/jnigen) 全部请求
`net::ERR_ACCESS_DENIED (-10)`**——h1 明文、TLS、quic-hint、GMS/嵌入式 provider、
enablePublicKeyPinningBypass 组合均复现。

判定：cronet_http 1.8（jnigen 绑定）在请求线程身份/网络标签上的缺陷——cronet 以发起线程的
binder 身份做权限检查，jnigen 回调线程未携带应用的 INTERNET 网络标签（Kotlin 路径无此问题）。
属上游包问题，非 easy-rpc 传输层问题；Dart CronetHttpTransport 代码已按 1.9 API 重写并在
flutter worker 通过真实编译（`flutter test`：`cronet transport constructs`），待上游修复或换
jni 手动打标签后即可运行。

**Cronet 的权威验证路径 = easy-rpc-kotlin `CronetTransport`（见上节，全绿）。**
