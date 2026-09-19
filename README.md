# easy-rpc 协议契约 v3（权威）

本文件是 easy-rpc 所有语言实现的**唯一权威**。实现、测试、生成器均以此为准。

- 版本：v3
- 状态：稳定
- 定位：**Connect 协议的一个简化子集**——保留与 `@connectrpc/*` 的**双向 wire 互通**，
  支持 proto 与 proto3 JSON 两个 codec；砍掉未使用的能力（GET、gRPC、gRPC-Web、
  client/bidi streaming、REST/transcoding）。

---

## 0. 范围

| 项 | 定案 |
|----|------|
| Schema | proto3 |
| 消息编码 | **proto 二进制（默认）+ proto3 JSON codec**（§2；错误信封见 §4） |
| 协议 | **仅 Connect wire**（无 grpc / grpc-web） |
| HTTP 动词 | **仅 POST**（无 GET；无 REST / `google.api.http` / transcoding） |
| 路径 | **`/<pkg>.<Service>/<Method>`**（gRPC 风格，唯一形态） |
| RPC 类型 | **unary + server-stream**（无 client-stream / bidi） |
| 元数据 | 请求 metadata → HTTP 头；响应 metadata → HTTP 头；**trailer** → unary `trailer-*` 头 / streaming END 帧 JSON |
| 传输 | 每语言一个 `Transport` 接口 + 多个 bridge（运行时零绑定） |
| 接口能力 | v2 仅暴露 `cancel()`（背压 `pause()/resume()` 留后续） |
| 互通目标 | `@connectrpc/connect`（v2）客户端 ↔ easy-rpc 服务端，及反向，均须通过 |

---

## 1. 路径映射

每个方法唯一映射为 gRPC 风格路径：

```
/<package>.<Service>/<Method>
```

例：

```proto
package easyrpc.conformance.v1;
service ConformanceService {
  rpc Echo(EchoRequest) returns (EchoResponse);
}
// -> /easyrpc.conformance.v1.ConformanceService/Echo
```

- 无 annotation，无动词选择，无路径变量，无 query 绑定。所有调用均为 `POST`。
- 生成器 `MethodSpec` **不含** `httpMethod` / `body` 字段（结构干净；见 §6）。

---

## 2. Content-Type

仅 proto：

easy-rpc 支持两个 **codec**：`proto`（二进制，默认）与 `json`（proto3 JSON）。
codec 由请求的 Content-Type 决定；响应跟随请求 codec。

| 形状 / codec | proto | json |
|--------------|-------|------|
| unary 请求/响应 | `application/proto` | `application/json` |
| server-stream 请求/响应 | `application/connect+proto` | `application/connect+json` |

- 服务端**必须**接受 `application/proto`（unary）与 `application/connect+proto`（stream）；
  **应当**接受 `application/json` / `application/connect+json`（JSON codec）。
- 消息 body 采用 proto3 JSON 映射（`protojson` 语义）：字段名 lowerCamelCase、
  `int64`/`uint64` 编码为字符串、`bytes` 为 base64、`enum` 为名字、`map` 为对象、
  `Any` 需 `@type`；解析时**忽略未知字段**。
- **JSON 仅改消息编码**：帧信封（§3）不变，server-stream 的每条数据帧 payload 是该
  message 的 JSON（仍是 `[1B flags][4B len][json]`）；END 帧的 Connect end-stream JSON
  与错误信封（§4）本来就是 JSON，不受 codec 影响。
- 空 message 在 JSON 下是 `{}`（**不接受**零长度 payload —— 详见 §3.1）。
- 未知/不支持的 Content-Type：**unary** → HTTP 415 + Connect 错误体 code=2（unknown）；
  **stream** → HTTP 415，无 END 帧。合法但未实现的 codec（若某实现只做 proto）同样 415。
- 请求侧压缩（§3.5）：unary 用 `Content-Encoding: gzip`，stream 用
  `Connect-Content-Encoding: gzip`；两者都与 codec 正交。
- 响应 Content-Type 使用与请求 codec 对应的值（json 请求 → json 响应）。

---

## 3. Wire 帧（streaming 信封）

每条消息在流上都是独立帧（与 Connect 一致）：

```
[1 字节 flags][4 字节 big-endian 长度][payload]
```

- `flags`：
  - bit0 = Compressed（gzip，见 §3.5）
  - bit1 = EndStream（流上最后一条）
- `payload` = message 的 proto 二进制；仅 **END 帧**的 payload 是
  **Connect end-stream JSON**（见 §3.2）——这是 Connect 信封的一部分，不通融为 proto。

### 3.1 unary
- 请求：`POST`，body = 请求 message 的编码（proto 二进制，或 JSON 对象）。
- 成功：HTTP 200，body = 响应 message 的编码（同上）。
- 空 message：proto 下是零长度 body；JSON 下必须是 `{}`（零长度 JSON payload
  不是合法 JSON 对象，按 code=13 处理）。
- 错误：见 §4。

### 3.2 server-stream
- 请求：`POST`，body = 单条请求 message 的 proto 二进制（无帧）。
- 响应：HTTP 200 + 一系列帧 `[1B flags][4B len][msg]`。
- 结束：服务端发送 END 帧（`flags.bit1=1`）。立即结束后又发数据是协议违例。
  - **空 payload** = 正常结束，无 trailer。
  - **非空 payload** = Connect end-stream JSON：

    ```json
    {
      "error":    { "code": "not_found", "message": "...", "details": [ ... ] },
      "metadata": { "x-trl": ["v1"], "k": ["a", "b"] }
    }
    ```

    - `error` 省略 = 正常结束；存在 = 抛对应 code 的 `RPCError`。
    - `metadata` 省略 = 无 trailing metadata；存在 = 该流的 trailing metadata。
    - 二者可同时存在。空对象 `{}` 等价于空 payload。
  - `code` 是稳定的小写字符串名（`codeToString`/`codeFromString`，见 §4）。

### 3.3 Trailer（trailing metadata）

- **unary**：响应 trailer 编码为响应头中前缀 `trailer-` 的字段
  （例如 trailer `x-trl: v1` → 响应头 `trailer-x-trl: v1`）。客户端按前缀解复用
  （大小写不敏感），`Response.trailers` 暴露解复用后的 trailer。
- **server-stream**：trailer 编码在 END 帧 JSON 的 `metadata` 字段（见 §3.2），
  由客户端 `streamPayloads` 解出并暴露。
- 响应头（非 trailer）与 trailer 相互独立；同名可共存（trailer 带前缀）。
- 服务端可为**任意**响应设置 trailer（成功或失败均适用）。

### 3.4 截止时间（Connect-Timeout-Ms）

- 客户端可选地在请求头携带 `Connect-Timeout-Ms: <毫秒>`（整数）。
- 服务端解析该头，作为本次调用 deadline：超时以 code=4（deadline_exceeded）结束。
  - unary：HTTP 504 + Connect 错误体（code=deadline_exceeded）。
  - server-stream：始终 HTTP 200，END 帧携带 `{"error":{"code":"deadline_exceeded",...}}`。
- 客户端亦可本地强制超时（本地 `AbortSignal`），到点取消请求。

### 3.5 压缩（gzip）

- 客户端在请求头 `Connect-Accept-Encoding: gzip`（stream）/ `Accept-Encoding: gzip`（unary）
  表示可接受压缩响应。
- unary：服务端可对响应 body 做 gzip（`>= 1KB`），响应头 `Content-Encoding: gzip`；
  客户端必须解压。请求侧压缩（`Content-Encoding: gzip`）可选支持。
- server-stream：服务端对 `>= 1KB` 的**数据帧**做 gzip，`flags.bit0=1`；END 帧不压缩。
- 客户端收到 bit0=1 的帧必须解压。
- gzip wrapper 一律 RFC-1952（`1f 8b` 魔数）。压缩是**机会性**的；解压是**严格**的
  （失败=协议错误，见 §4.3 F4）。

### 3.6 协议版本

- 客户端在**每个请求**携带 `Connect-Protocol-Version: 1`（unary 与 stream 均发送）。
- 服务端若收到显式且不支持的版本，拒绝：unary 与 stream 均为 HTTP 501
  （code=12 = unimplemented）+ 错误体 code=12（stream 无 END 帧）。缺失视为兼容。

### 3.7 拦截器（内建扩展点）

core 内建 `Interceptor`（每语言一致）：包装一次调用，可改请求（auth/metadata）、加 deadline、观察、短路。

- 组合顺序：列表首个为最外层。
- 内建拦截器：`MetadataInterceptor`（添加固定头）、`TimeoutInterceptor`（附加 `Connect-Timeout-Ms`）。
- 传输层用 `InterceptorTransport`（或 `interceptors(...)`）包裹；鉴权/重试/日志均以此实现。

### 3.8 组合根（connect）

每语言提供一个 `connect(...)` 组合根，业务只与它交互：

```
connect({ baseUrl, token?, mode, timeoutMs?, interceptors? }) -> Transport
    = InterceptorTransport([metadata, deadline, ...user], adapterFor(mode))
```

- `mode`（统一词表）：`auto`、以及各语言可用 adapter 名
  （TS `fetch|node|h1`；Dart `io|http2`；Kotlin `okhttp`；C# `h1|h2|h3`；
  Swift `urlSession|asyncHTTPClient`；Rust `auto|hyper`；Python/Go `std|auto`）。
- **换 adapter = 换 `mode`；interceptor 不动**。
- `token`/`timeoutMs` 由内建 interceptor 实现。

---

## 4. 错误码映射

覆盖**完整 gRPC/Connect 错误码空间**：

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

- **code → HTTP 状态**：权威方向，`httpStatus(code)` 覆盖 1–16。
- **HTTP 状态 → code**：可变（多对一），`connectFromStatus(status)` 覆盖
  400/404/403/401/429/503/409/504/501/499，其余落 `13`。
- **unary 错误**（Connect 对齐）：HTTP 状态表达类别，body 为 Connect 错误 JSON：

  ```json
  { "code": "invalid_argument", "message": "...", "details": [ ... ] }
  ```

  兼容回退顺序：`connect-code`/`connect-error` 头 → JSON body → 状态码映射。
- **streaming 错误**：**始终 HTTP 200**，错误只在 END 帧 JSON 里（§3.2）。

### 4.1 Error Details（可选）

错误可携带**结构化 details**（对齐 Connect Error Details / gRPC `google.rpc.*`）：

- 位置：unary 错误 body 顶层 `details`；streaming 在 `error.details`。
- 元素结构固定 `{ "type": "<type URL>", "value": "<base64>" }`；各语言 API 暴露为
  `ErrorDetail{type: string, value: bytes}`。
- **为空必须省略** `details`。
- 解析忽略未知字段；`type`/`value` 之外一律忽略，opaque 透传。

### 4.2 错误路径矩阵（各语言一致性基准）

| # | 输入 | 期望行为 |
|---|------|----------|
| M1 | END 帧空 payload | 干净结束，无错误、无 trailer |
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
| M12 | `Connect-Timeout-Ms` 到期（本地） | 抛 code=4，且请求被取消 |
| M13 | 服务端 deadline 到期 | end-stream/unary 错误 code=4 |
| M14 | END 帧 `{"metadata":{...}}`（无 error） | 干净结束，trailer = metadata |
| M15 | unary 响应头含 `trailer-*` | Response.trailers 解复用后含对应键 |
| M16 | JSON Content-Type 请求 | unary 415 + code=3；stream 415（无 END 帧） |

### 4.3 故障注入矩阵（F1–F6，socket 级/协议级）

| # | 输入 | 期望行为 |
|---|------|----------|
| F1 | body 在帧中段截断（EOF 时半帧） | 错误（code=13 truncated frame），已完整收到的帧正常交付 |
| F2 | body 在帧边界结束但**无 END 帧** | 错误（code=13 stream ended without END frame） |
| F3 | END 帧 payload 为垃圾字节 | 同 M2：干净结束，不抛 |
| F4 | 压缩位置位但 gzip 损坏 | 错误（code=13 corrupt gzip frame），**绝不**把原始压缩字节当 payload 交付 |
| F5 | 帧被任意切成小 chunk 传输 | 正确重组（读取器必须累积） |
| F6 | 合法 gzip 帧 | 正常解压交付 |

**gzip wire 语义**：压缩帧一律 RFC-1952 gzip wrapper（`1f 8b` 魔数）。
压缩是**机会性**的（失败可退化为不压缩）；解压是**严格**的（失败=协议错误）。

### 4.4 组合根注入语义

`connect()` 在全部 8 语言支持**自定义 adapter 注入**：注入时跳过 mode 选择，
内建 metadata/deadline 拦截器与用户拦截器包装**该 adapter**。

| 语言 | 注入方式 |
|------|---------|
| C# | `ConnectOptions.Adapter` |
| Swift | `connect(transport:)` |
| TS | `connect({ transport })` |
| Go | `ConnectOptions.Adapter` |
| Rust | `connect_with_adapter(..)` |
| Python | `connect(transport=...)` |
| Kotlin | `connect(client = OkHttpClient)` |
| Dart | `connect(httpClient:)` |

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
  trailers() -> Headers                                  // END 后可用（streaming trailer）
  cancel()
}
Request  { url, headers: Headers, body: Bytes }
Response { status: int, headers: Headers, body: Bytes, trailers: Headers }
```

约束：
- **零运行时绑定**：`Transport` 是接口；具体 HTTP 运行时不进 core，只由 bridge 实现。
- **bridge 只做适配**：core Request ↔ 运行时请求、运行时响应/流 → core Response/ResponseStream，
  并处理 `cancel()` 与 unary `trailer-*` 解复用。
- **协议逻辑在 core**：信封帧、错误码、Content-Type、trailer 编解码由 core 的 protocol 层处理。
- `Request` 不再带 `method`（恒 POST，由 core 决定）。

---

## 6. 生成器输出边界

- `protoc-gen-easyrpc-<lang>` 产出：
  - 方法表 `MethodSpec { service, name, path, clientStream, serverStream }`
    （**不含** `httpMethod` / `body`；路径由 §1 推导）
  - `XxxClient`（接受任意 `Transport`）
  - `XxxService`/Handler（服务端骨架；handler 可接收 context 以写 trailer/读 metadata）
  - 拦截器类型（可选）
- **不产出** `Transport` 实现。`Transport` 由 bridge 提供。
- **消息类型**由官方 `protoc-gen-*` 产出，easy-rpc 生成器不重复。

---

## 7. 依赖（仅 protobuf 运行库）

| 语言 | 消息生成(官) | protobuf 运行库 | 传输 bridge |
|------|------------|----------------|------------|
| Go | protoc-gen-go | google.golang.org/protobuf | net/http |
| TS | protoc-gen-es | @bufbuild/protobuf | fetch / node http2 |

---

## 7.1 客户端桥接（realm 二选一：std / auto）

- **`realm = std`**：只覆盖 **h1 + h2 + h2c**，不引入 QUIC 依赖。
- **`realm = auto`**：覆盖 **h1 + h2 + h2c + h3**，内部自动协商 `h3 → h2/h2c → h1`。

| 语言 | std（少依赖） | auto（+h3） | 入口 |
|------|--------------|--------------|------|
| **Go** | `net/http`（`http.Protocols`） | `net/http` + `quic-go/http3` | `NewTransport(realm)` |
| **Rust** | `reqwest`（无 http3） | `reqwest`（`http3` feature + `quinn`） | `NewClient(base)` |
| **TS** | web=`fetch`；node=`node:http`+`node:http2` | web `fetch` 天然 h1/h2/h3；**node 不支持 h3** | `createDefaultTransport(realm)` |
| **Python** | `httpx`（h1+h2/h2c） | `httpx` + `aioquic`（h3） | `default_client(realm)` |

> Go/Rust/TS/Python 支持 `realm` 二选一；C#/Kotlin/Swift/Dart 拆分多个独立桥，由使用者自选。

### 7.1.2 C# / Kotlin / Swift / Dart（多桥自选）

| 语言 | 桥 | 平台 | 协议 |
|------|-----|------|------|
| **C#** | `HttpClientTransport`（`.H1()` `.H2()` `.H3()`） | Linux/桌面/Android/iOS | h1 / h2(https) / h3 |
| **Kotlin** | `OkHttpTransport` | Linux/JVM | h1+h2c+h2 |
| | `CioTransport` | 非JVM原生 | h1 |
| | `CronetTransport` | JVM(嵌入式)/Android | h1+h2+h3 |
| **Swift** | `URLSessionTransport` | iOS/macOS | h1+h2+h3 |
| | `AsyncHTTPClientTransport` | Linux/服务端 | h1+h2c+h2 |
| **Dart** | `Transport`(dart:io) | Linux/VM | h1 |
| | `Http2Transport` | Linux/VM | h1+h2c+h2 |
| | `CronetHttpTransport` | Android | h1+h2+h3 |
| | `CupertinoHttpTransport` | iOS/macOS | h1+h2+h3 |
| | `FetchTransport` | Web | h1+h2+h3 |

---

## 8. Conformance（验证）

标准服务定义见 `proto/easyrpc/conformance/v1/`：
- unary：`Echo`、`Health`、`Empty`、`EchoBytes`（非 UTF-8）
- server-stream：`Count`、`BigStream`（多帧 / gzip 边界）
- 错误用例：`Fail`、`StreamFail`
- 错误 details：`FailDetails`、`StreamFailDetails`
- 元数据：`EchoMeta`（请求 metadata 回显）、`EchoTrailer`（unary trailer）、
  `CountTrailer`（streaming trailing metadata）
- 截止时间：`Sleep`（服务端 sleep → `connect-timeout-ms` → code 4）
- 边界：`Big`（大 payload，含 unary gzip）

### 8.1 四层验证（协议 / transport 解耦）

| 层 | 位置 | 依赖 transport？ | 作用 |
|----|------|:---:|------|
| **Wire 向量** | `conformance/wire-vectors.json` + 各语言 `wire_vectors*` 测试 | **否**（纯协议层） | 唯一能抓"两个实现同源 bug"的 oracle：帧、END 帧、错误 JSON、trailer mux/demux、码表必须字节/语义一致 |
| **故障注入** | 各语言 `fault_injection*` 测试 | 是（mock socket） | F1–F6 畸形流 body |
| **Raw-wire oracle** | `cli/raw-wire.sh` | 否（仅 curl） | 独立于所有实现，校验真实 HTTP 线上契约：**全部 16 个 Connect code**、流边界 0/N/error、非法请求（verb/path/content-type/version/encoding）/畸形信封（截断/oversize/corrupt-gzip 标志）/limits/metadata/HTTP 版本协商 |
| **h2 并发 oracle** | `cli/h2-concurrent.py` | 是（h2 库） | 单条 h2c 连接上并发多路 server-stream：无串扰、真正交错、流后连接可复用 |
| **h3 并发 oracle** | `cli/h3-concurrent.py` | 是（aioquic） | 单条 QUIC 连接上并发多路 h3 server-stream：无串扰、真正交错、流后连接可复用（自签 CA + IP-SAN 即可，对 caddy `tls internal` 端点） |
| **互通矩阵** | `cli/matrix/run-matrix.sh` | 是 | (client × transport) × (server) 全组合 |
| **官方 ConnectRPC suite** | `conformance/official/run-official.sh` | 是 | 用 vendored 官方 proto + `connectconformance` runner 对表（可编程 `ConformanceService`），server 侧 292/292（h1+h2c、proto、identity+gzip、unary+server-stream） |

**协议正确性** = Wire 向量 + 故障注入 + 真 `@connectrpc` 双向互测（`easy-rpc-ts/tests/connectrpc-interop.test.ts`）+ 官方 suite。
**transport 正确性** = 互通矩阵里每个 client 用**每个** transport 跑同一份 checklist（`EASY_RPC_TRANSPORT` 选择）+ raw-wire / h2 并发 oracle。

共享清单见 `conformance/checklist.json`（v2）：client 用例 + server 侧
（16 码、流边界、非法请求、畸形信封、limits、metadata、HTTP 版本、取消）。

### 8.2 transport 轴（`EASY_RPC_TRANSPORT`）

统一词表（spec §7.1）：未设 = 各语言默认。

| 语言 | 取值 |
|------|------|
| TS | `fetch` `node` `h1` `auto` |
| Go | `std` `auto` |
| Rust | `reqwest` `hyper` |
| Python | `std`（`auto` 需 aioquic） |
| Kotlin | `okhttp` `cio`（`cronet` 见 device matrix） |
| C# | `h1` `h2` `h3` |
| Swift | `urlsession` `ahc` |
| Dart | `io` `http2`（`cronet`/`cupertino`/`fetch` 见 device matrix） |

设备专用 transport（Cronet/Cupertino/URLSession-h3）无法在 Linux pod 运行，见
`cli/matrix/device-matrix.sh`（在对应 worker 上执行）。

**h3/QUIC 本身可在 pod 上验证**：`cli/h3-concurrent.py`（aioquic 客户端）对
caddy `tls internal` 的 IP-SAN 端点做单连接并发多路流；**自签 CA + IP 即可**
（证书需含 IP SAN，caddy `tls internal` 对按 IP 寻址的站点默认如此）。
`cli/ci/run-all.sh h3` 已接入。真正跑在设备上的 transport（Cronet/URLSession-h3）
仍需设备信任库（Android 系统 CA / macOS System keychain），故仍归 device matrix。

### 8.3 错误路径矩阵 M1–M16

各语言单元测试直接对 `decode*`/帧解码函数构造输入（`wire-vectors.json` 是
跨语言共享的字节级来源）。

### 8.4 故障注入矩阵 F1–F6

| # | 输入 | 期望行为 |
|---|------|----------|
| F1 | body 在帧中段截断（EOF 时半帧） | 错误（code=13 truncated frame），已完整收到的帧正常交付 |
| F2 | body 在帧边界结束但**无 END 帧** | 错误（code=13 stream ended without END frame） |
| F3 | END 帧 payload 为垃圾字节 | 同 M2：干净结束，不抛 |
| F4 | 压缩位置位但 gzip 损坏 | 错误（code=13 corrupt gzip frame），**绝不**把原始压缩字节当 payload 交付 |
| F5 | 帧被任意切成小 chunk 传输 | 正确重组（读取器必须累积） |
| F6 | 合法 gzip 帧 | 正常解压交付 |

**gzip wire 语义**：压缩帧一律 RFC-1952 gzip wrapper（`1f 8b` 魔数）。
压缩是**机会性**的；解压是**严格**的。

---

## 9. 版本约定

- 生成器版本锁定在 `cli/` 脚本与 `buf.gen.*.yaml`（用 `local:` 插件，不用远程）。
- 各语言产出的 `gen/` 提交进仓库；CI 直接用已提交代码。
