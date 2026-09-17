# easy-rpc 协议契约 v1（权威）

本文件是 easy-rpc 所有语言实现的**唯一权威**。实现、测试、生成器均以此为准。

- 版本：v1
- 状态：第一版（M0，Go + TypeScript 打样）
- 后续：easy-codec（zod 式）v2 将替换 schema 层，但**本 wire/protocol 契约不变**。

---

## 0. 范围

| 项 | 定案 |
|----|------|
| Schema | proto3 |
| 编码 | **仅 proto 二进制**（无 JSON codec） |
| 协议 | **仅 Connect wire**（无 grpc / grpc-web） |
| RPC 类型 | **unary + server-stream**（无 client-stream / bidi；server-stream 承担"服务端推送"，可替代 WebSocket 推送面） |
| 路径 | REST 风格（`google.api.http` annotation）；无 annotation 回退 `<pkg>.<Service>/<Method>` |
| 传输 | 每语言一个 `Transport` 接口 + 多个 bridge（运行时零绑定） |
| 接口能力 | v1 仅暴露 `cancel()`（背压 `pause()/resume()` 留 v1.2） |

---

## 1. 路径映射

### 1.1 REST 风格（优先）
用 `google.api.http` annotation 指定，如：

```proto
import "google/api/annotations.proto";

service RepoService {
  rpc ListRepos(ListReposRequest) returns (ListReposResponse) {
    option (google.api.http) = { get: "/v1/{org}/repos" };
  }
  rpc WatchRepo(WatchRepoRequest) returns (stream WatchEvent) {
    option (google.api.http) = { post: "/v1/{org}/repos/{repo}:watch" };
  }
}
```

- 路径变量 `{org}` / `{repo}` ↔ 请求 message **同名字段**（标准绑定）。
- 动词映射：
  - `get` / `delete` → unary，无 body
  - `post` / `put` / `patch` → unary（`body: "*"` 或 `body: "field"` 决定 body 内容）
  - server-stream → 仅 `post`（用 `:action` 后缀区分语义，如 `:watch`）
- `additional_bindings`：一个方法可多个 HTTP 绑定，均生效。

### 1.2 gRPC 风格回退
无 `google.api.http` 的方法：`/<pkg>.<Service>/<Method>`（沿用 gRPC/connect 默认路由，保生态互操作）。

---

## 2. Content-Type

| 形状 | proto | JSON |
|------|-------|-----|
| unary | `application/proto` | `application/json` |
| server-stream | `application/connect+proto` | `application/connect+json` |

服务端 kind 检测必须同时认 `application/json` 与 `application/connect+json` 前缀（流式 JSON 请求的 content-type 是后者）。

---

## 3. Wire 帧（streaming 信封）

每条消息在流上都是独立帧：

```
[1 字节 flags][4 字节 big-endian 长度][payload]
```

- `flags`：
  - bit0 = Compressed（v1 恒为 0，仅 identity）
  - bit1 = EndStream（客户端或服务端发送的最后一条）
- `payload` = message 的 proto 二进制，或 **end-stream JSON**（仅 END 帧）。

### 3.1 unary
- body = 请求 message 二进制（无帧）。
- 成功：HTTP 200，body = 响应 message 二进制。
- 错误：见 §4。

### 3.2 server-stream
- 请求 = 单条 message 二进制（作为 POST body，无帧）。
- 响应 = 一系列帧，每条 `[1B flags][4B len][msg]`。
- 结束：服务端发送 END 帧（`flags.bit1=1`）。空 payload = 正常结束；非空 payload = **Connect end-stream JSON**：

  ```json
  { "error": { "code": "not_found", "message": "..." }, "metadata": { "k": ["v"] } }
  ```

  客户端 **必须**解析该 JSON：存在 `error` 时抛出对应 code 的 RPCError，而不是当作正常结束。
  `code` 是稳定的字符串名（`codeToString`/`codeFromString`，见 §4）。

---

## 3.3 截止时间（Connect-Timeout-Ms）

- 客户端可选地在请求头携带 `connect-timeout-ms: <毫秒>`（整数）。
- 服务端解析该头，将其作为本次调用的 deadline：超时以 code=4（deadline_exceeded）结束。
  - unary：返回 HTTP 504 + `connect-code: 4`（或 Connect JSON 错误体，见 §4）。
  - server-stream：始终 HTTP 200，END 帧携带 `{"error":{"code":"deadline_exceeded",...}}`。
- 客户端亦可本地强制超时（`withTimeout`），到点取消请求。

## 3.4 拦截器（内建扩展点）

core 内建 `Interceptor`（每语言一致）：包装一次调用，可改请求（auth/metadata）、加 deadline、观察、短路。

- 组合顺序：列表首个为最外层。
- 内建拦截器：`MetadataInterceptor`（添加固定头）、`TimeoutInterceptor`（附加 `connect-timeout-ms`）。
- 传输层用 `InterceptorTransport`（或 `interceptors(...)`）包裹；鉴权/重试/日志均以此实现，避免每 transport 手写 wrapper。

## 3.5 压缩（gzip）

- 客户端在请求头 `connect-accept-encoding: gzip` 表示可接受压缩。
- 服务端对 **>= 1KB（compressMinBytes）** 的流式消息帧做 gzip，置 `flags.bit0=1`。
- unary 保持 identity（v1）。
- 客户端收到 bit0=1 的帧必须解压；未声明即不压缩。

## 3.6 组合根（connect）

每语言提供一个 `connect(...)` 组合根，业务只与它交互：

```
connect({ baseUrl, token?, mode, timeoutMs?, interceptors? }) -> Transport
    = InterceptorTransport([metadata, deadline, ...user], adapterFor(mode))
```

- `mode`（统一词表）：`auto`（按环境/平台选择）、以及各语言可用 adapter 名
  （TS `fetch|node|h1`；Dart `io|http2`；Kotlin `okhttp`；C# `h1|h2|h3`；
  Swift `urlSession|asyncHTTPClient`；Rust `auto|hyper`；Python/Go `std|auto`）。
- **换 adapter = 换 `mode`；interceptor 不动**——这是"每语言可更换 transport adapter"的实现方式。
- `token`/`timeoutMs` 由内建 interceptor 实现；调用方无需写任何 wrapper。

## 4. 错误码映射

错误在 HTTP 层表达。覆盖**完整 gRPC/Connect 错误码空间**：

| Code | 名称 | HTTP 状态 | 说明 |
|------|------|----------|------|
| 0 | OK | 200 | 成功 |
| 1 | CANCELLED | 499 | 客户端取消 |
| 2 | UNKNOWN | 500 | 未知 |
| 3 | INVALID_ARGUMENT | 400 | 参数无效 |
| 4 | DEADLINE_EXCEEDED | 504 | 超时 |
| 5 | NOT_FOUND | 404 | 不存在 |
| 6 | ALREADY_EXISTS | 409 | 已存在 |
| 7 | PERMISSION_DENIED | 403 | 无权限 |
| 8 | RESOURCE_EXHAUSTED | 429 | 资源耗尽 |
| 9 | FAILED_PRECONDITION | 400 | 前置条件不满足 |
| 10 | ABORTED | 409 | 中止 |
| 11 | OUT_OF_RANGE | 400 | 越界 |
| 12 | UNIMPLEMENTED | 501 | 未实现 |
| 13 | INTERNAL | 500 | 内部错误 |
| 14 | UNAVAILABLE | 503 | 不可用 |
| 15 | DATA_LOSS | 500 | 数据丢失 |
| 16 | UNAUTHENTICATED | 401 | 未认证 |

- **code → HTTP 状态**：权威方向，`httpStatus(code)`/`HTTPStatus(code)` 完整覆盖 1–16。
- **HTTP 状态 → code**：可变（多对一），返回该状态最常见的 code，`connectFromStatus(status)` 覆盖 400/404/403/401/429/503/409/504/501/499，其余落 `13`。
- unary（Connect 对齐）：HTTP 状态码表达错误**类别**，响应体为 JSON `{"code":"<name>","message":"...","details":[...]}`。
  - 兼容：客户端仍读取旧的 `connect-code`/`connect-error` 头，以及纯文本 body，按 头 → JSON body → 状态码 的顺序回退。
- streaming：**始终 HTTP 200**，错误只在 end-stream JSON 里（见 §3.2）；不与 HTTP 头混用。

### 4.1 Error Details（v1.1，可选、向前兼容）

错误可携带**结构化 details**（对齐 Connect Error Details / gRPC `google.rpc.*` 状态详情）：

```json
{
  "code": "resource_exhausted",
  "message": "rate limited",
  "details": [
    { "type": "type.googleapis.com/google.rpc.RetryInfo", "value": "<base64 of protobuf bytes>" }
  ]
}
```

- 位置：unary 错误 body 顶层 `details`；streaming 在 `error.details`。
- 元素结构固定为 `{ "type": "<type URL>", "value": "<base64>" }`；`value` 是任意字节（典型为 protobuf 消息），各语言 API 暴露为 `ErrorDetail{type: string, value: bytes}`。
- **为空必须省略** `details` 字段（保持 v1.0 字节级不变）。
- **向前兼容**：JSON 解析忽略未知字段——v1.0 客户端收到含 `details` 的错误不报错，仅丢弃；服务端可先升级。各语言实现只读 `type`/`value`，其余字段（如未来的 `debug`）原样忽略。
- 语义约定（非强制）：`type` 建议 `type.googleapis.com/google.rpc.<Name>`，value 为对应 `google.rpc` 消息；但 wire 层不做任何校验，opaque 透传。

### 4.2 错误路径矩阵（各语言一致性基准）

下列输入是协议层**必须**具有的一致行为，作为各语言单元测试的公共矩阵（`decodeEndStream` / `decodeErrorJson` / 帧解码 / 截止时间）：

| # | 输入 | 期望行为 |
|---|------|----------|
| M1 | END 帧空 payload | 干净结束，无错误 |
| M2 | END 帧 payload 非 JSON（垃圾字节） | 按干净结束处理（不抛），不得崩溃 |
| M3 | END 帧 `{"error":{}}`（无 code/message） | code=2(unknown)，message="" |
| M4 | END 帧 `error.code` 为未知名字 | code=2 |
| M5 | END 帧 JSON 含未知字段（如 `{"error":{...},"x":1}`） | 正常解析，未知字段忽略 |
| M6 | END 帧 `error.details` 数组 | RPCError.details 携带 `{type,value}`，value 为 base64 解码后的字节 |
| M7 | details 元素缺 `value` 或非 base64 | 忽略该元素，不得崩溃 |
| M8 | 帧头声明长度 > 实际 body（截断） | 读取出错（不得返回部分 payload 当成功） |
| M9 | 帧长度 > 4MB（默认上限） | 拒收，code=8 resource_exhausted |
| M10 | gzip 置位但 payload 损坏 | 解压失败按协议错误处理（不返回原始压缩字节） |
| M11 | unary 错误 body 为纯文本（旧服务器） | 回退：`connect-code` 头 → 状态码映射 |
| M12 | `connect-timeout-ms` 到期（本地） | 抛 code=4，且请求被取消 |
| M13 | 服务端 deadline 到期 | end-stream/unary 错误 code=4 |

### 4.3 故障注入矩阵（F1–F6，v1.1，socket 级/协议级）

在 M 矩阵（单元级）之上，各语言还必须对**畸形流 body**具备一致行为（TS/Go/Rust/Python 为 socket 级 mock 服务端测试，Kotlin/Dart/C#/Swift 为协议级帧读取器测试）：

| # | 输入 | 期望行为 |
|---|------|----------|
| F1 | body 在帧中段截断（EOF 时半帧） | 错误（code=13 truncated frame），已完整收到的帧正常交付 |
| F2 | body 在帧边界结束但**无 END 帧** | 错误（code=13 stream ended without END frame）——Connect 协议要求每个 server-stream 必须以 END 帧终止 |
| F3 | END 帧 payload 为垃圾字节 | 同 M2：干净结束，不抛 |
| F4 | 压缩位置位但 gzip 损坏 | 错误（code=13 corrupt gzip frame），**绝不**把原始压缩字节当 payload 交付 |
| F5 | 帧被任意切成小 chunk 传输 | 正确重组（读取器必须累积，不得因分片丢字节） |
| F6 | 合法 gzip 帧 | 正常解压交付 |

**gzip wire 语义**：压缩帧一律使用 RFC-1952 gzip wrapper（`1f 8b` 魔数），与 Go/Python/Rust/Dart/Kotlin/C#/Swift 实现一致。TS 实现曾在 v0.5.0 前误用 raw deflate（跨语言不可互通），v0.5.1 起修正。压缩是**机会性**的（失败可退化为不压缩）；解压是**严格**的（失败=协议错误）。

### 4.4 组合根注入语义（v1.1）

`connect()` 组合根在全部 8 语言支持**自定义 adapter 注入**：注入时跳过 mode 选择，内建 metadata/deadline 拦截器与用户拦截器包装**该 adapter**。

| 语言 | 注入方式 |
|------|---------|
| C# | `ConnectOptions.Adapter` |
| Swift | `connect(transport:)` |
| TS | `connect({ transport })` |
| Go | `ConnectOptions.Adapter` |
| Rust | `connect_with_adapter(..)` |
| Python | `connect(transport=...)` |
| Kotlin | `connect(client = OkHttpClient)`（OkHttp 层注入） |
| Dart | `connect(httpClient:)`（dart:io HttpClient 层注入） |

---

## 5. Transport 接口（核心概念）

每语言实现，**语义一致、签名不强求逐字同**。

```
Transport {
  send(Request) -> Response                              // unary
  openStream(Request) -> ResponseStream                  // server-stream
}
ResponseStream {
  recv() -> Bytes                                        // 每帧
  cancel()                                               // v1 仅取消
  // pause()/resume() -> v1.2（可选）
}
Request  { url, method, headers: Headers, body: Bytes }
Response { status: int, headers: Headers, body: Stream<Bytes>, trailers: Headers }
```

约束：
- **零运行时绑定**：`Transport` 是一个接口；具体 HTTP 运行时不进 core，只由 bridge 实现。
- **bridge 只做适配**：core Request ↔ 运行时请求、运行时响应/流 → core Response/ResponseStream，并处理 `cancel()`。
- **协议逻辑在 core**：信封帧、错误码、Content-Type 由 core 的 protocol 层处理，与 bridge 无关。

---

## 6. 生成器输出边界

- `protoc-gen-easyrpc-<lang>` 产出：
  - 方法表（`method_spec`/路径映射）
  - `XxxClient`（接受任意 `Transport`）
  - `XxxServer`/Handler（服务端骨架，接受分派函数）
  - 拦截器类型（可选）
- **不产出** `Transport` 实现。`Transport` 由 bridge 提供。
- **消息类型**由官方 `protoc-gen-*` 产出（`Message`），easy-rpc 生成器不重复。

---

## 7. 依赖（仅 protobuf 运行库）

| 语言 | 消息生成(官) | protobuf 运行库 | 传输 bridge |
|------|------------|----------------|------------|
| Go | protoc-gen-go | google.golang.org/protobuf | net/http |
| TS | protoc-gen-es | @bufbuild/protobuf | fetch / node http2 |

（M0 仅 Go + TS。其余 6 语言按里程碑补。）

---

## 7.1 客户端桥接（realm 二选一：std / auto）

每语言暴露两种 client 桥，按"依赖多少"二选一：

- **`realm = std`**（少依赖）：只覆盖 **h1 + h2 + h2c**，不引入任何 QUIC 依赖。
- **`realm = auto`**（完整功能）：覆盖 **h1 + h2 + h2c + h3**，内部自动协商 `h3 → h2/h2c → h1`，引入 QUIC 依赖。

| 语言 | std（少依赖） | auto（+h3） | 入口 | 备注 |
|------|--------------|--------------|------|------|
| **Go** | `net/http`（`http.Protocols`） | `net/http` + `quic-go/http3` | `NewTransport(realm)` | h3 依赖 `github.com/quic-go/quic-go`，可选构建 |
| **Rust** | `reqwest`（无 http3） | `reqwest`（`http3` feature + `quinn`） | `NewClient(base)` | Cargo feature 切换；h3 需 `RUSTFLAGS=--cfg reqwest_unstable` |
| **TS** | web=`fetch`；node=`node:http`+`node:http2` | web `fetch` 天然 h1/h2/h3；**node 不支持 h3** | `createDefaultTransport(realm)` | node 仅 h1+h2c+h2；h3 由浏览器 fetch 覆盖 |
| **Python** | `httpx`（h1+h2/h2c） | `httpx` + `aioquic`（h3） | `default_client(realm)` | h3 依赖 `aioquic`（可选） |

> **客户端桥接说明**：Go/Rust/TS/Python 支持 `realm` 二选一；C#/Kotlin/Swift/Dart 则**拆分多个独立桥，由使用者自选**（不做 realm 自动协商）。各桥协议覆盖见下表。

### 7.1.1 Go / Rust / TS / Python（realm 二选一）

| 语言 | std（h1+h2c+h2） | auto（+h3） | 入口 |
|------|------------------|-------------|------|
| **Go** | `net/http`（`http.Protocols`） | `net/http` + `quic-go/http3` | `NewTransport(realm)` |
| **Rust** | `reqwest`（无 h3） | `reqwest`（`http3` feature + `quinn`） | `NewClient(base)` |
| **TS** | web=`fetch`；node=`node:http`+`node:http2` | web `fetch` 天然 h1/h2/h3；**node 不支持 h3** | `createDefaultTransport(realm)` |
| **Python** | `httpx`（h1+h2/h2c） | `httpx` + `aioquic`（h3） | `default_client(realm)` |

### 7.1.2 C# / Kotlin / Swift / Dart（多桥自选）

| 语言 | 桥 | 平台 | 协议 |
|------|-----|------|------|
| **C#** | `HttpClientTransport`（`.H1()` `.H2()` `.H3()`） | Linux/桌面/Android/iOS | h1 / h2(https) / h3（System.Net.Http+msquic/平台handler） |
| **Kotlin** | `OkHttpTransport` | Linux/JVM | h1+h2c+h2 |
| | `CioTransport` | 非JVM原生（全target） | **仅 h1**（纯Kotlin，最小依赖） |
| | `CronetTransport` | Android | h1+h2+h3（Cronet） |
| | `DarwinTransport` | iOS/macOS | h1+h2+h3（NSURLSession） |
| **Swift** | `URLSessionTransport` | iOS/macOS | h1+h2+h3（系统） |
| | `AsyncHTTPClientTransport` | Linux/服务端 | h1+h2c+h2（async-http-client） |
| **Dart** | `Transport`(dart:io) | Linux/VM | h1 |
| | `Http2Transport` | Linux/VM | h1+h2c+h2（`http2` 包） |
| | `CronetHttpTransport` | Android | h1+h2+h3（`cronet_http`，Flutter） |
| | `CupertinoHttpTransport` | iOS/macOS | h1+h2+h3（`cupertino_http`，Flutter） |
| | `FetchTransport` | Web | h1+h2+h3（`fetch`） |

> **h3 落地原则**：仅系统栈（Cronet/Cupertino/URLSession/浏览器 fetch）与 .NET msquic 提供 h3；Linux 通用默认 h1+h2c+h2（C# 可经 msquic 达 h3）。Cronet/Cupertino 依赖 Flutter SDK，`cronet_http`/`cupertino_http` 不随纯 Dart VM 拉取。

---

## 8. Conformance（验证）

标准服务定义见 `proto/easyrpc/conformance/v1/`：
- unary：`Echo`
- server-stream：`Count`（计数推送）
- 错误用例：`Fail`、`StreamFail`
- 错误 details：`FailDetails`（unary）、`StreamFailDetails`（stream 中途失败，均带 `details`）
- 元数据/边界：`EchoMeta`、`Big`、非 UTF-8、空消息、EndStream。

验证方式：
- §4.2 **错误路径矩阵** M1–M13：各语言单元测试直接对 `decode*`/帧解码函数构造输入（不需要起服务）。
- 互操作：同一 `Transport` 跨 Go 服务端 ↔ 各语言客户端互测，对比协议一致性。

---

## 9. 版本约定

- 生成器版本锁定在 `cli/` 的脚本与 `buf.gen.*.yaml`（用 `local:` 插件，不用远程）。
- 各语言产出的 `gen/` 提交进仓库；CI 直接用已提交代码。

