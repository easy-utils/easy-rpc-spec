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
| macos-flutter | `CupertinoHttpTransport` | — | ⚠️ 见下 |
| macos-xcode (Swift 6.2.4) | `URLSessionTransport` | **TLS + ALPN h2**（delegate 注入 CA，IP SAN 校验） | ✅ echo/count/failDetails |
| macos-xcode | `URLSessionTransport` | h1 明文（探针） | ✅ HTTP 200 + TLS 套件同栈 |
| macos-xcode | Swift 协议矩阵 M1–M13 + 故障注入 F1–F6 | — | ✅ 17/17 |
| macos-xcode | `AsyncHTTPClientTransport` | — | ⚠️ 见下 |

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
| Swift AHC 测试在沙箱容器崩溃需开关 | swift **v0.5.2** |

## 复跑

worker 工程保留在各 workspace：`kt/`（cmp）、`io/`+`dart/`+`ft/`（flutter）、`/tmp/easy-rpc-swift`（xcode）。
推 file 用 FileWrite、跑用 Execute/JobWait（`/tmp/opencode/ew*.sh` 有现成封装）。
