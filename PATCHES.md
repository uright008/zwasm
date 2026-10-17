# snooze fork：与上游的差异清单

上游：<https://github.com/zwasm/zwasm>
基线提交：`442f746a63c517d2545697aa174d9394f88086f7`（v2.7.0 之后、`#512` 修复）
工作分支：`zig-0.18-port`（fork remote：`fork` = https://github.com/uright008/zwasm）
工具链：Zig `0.18.0-dev.210+3626a240e`（上游要求 0.16；本 fork 已迁到 0.18-dev）

本文件是 rebase 时的工作清单：每条补丁记录动机、上游 issue、以及上游若自行修复后如何降级。
**不要只靠 commit message**——上游一旦采纳其中某条，这里的「处置」列就是删除依据。

## 补丁系列

| # | 提交 | 内容 | 上游状态 | 处置 |
| --- | --- | --- | --- | --- |
| p1 | `build: port build.zig to the Zig 0.18 std.Build API` | `standardOptimizeOption` 返回可选、`Optimize` 枚举字段改小写、`b.args` 移除、`b.pathFromRoot` → `addFileArg`/`addPrefixedFileArg`（47+5 处） | 上游仍要求 0.16 | 若上游迁 0.18 则整条删除；否则每次上游改动 build.zig 时手工 rebase |
| p2 | `port: run the tree on Zig 0.18-dev` | 四类：`T ** N` → `@splat`/`++`；类型反射（`std.meta.fields`、`Type.Enum.fields`、`Type.Fn.params`）＋ 新增 `src/type_info_compat.zig`；`std.Io` 操作模型（`io.operate(.{ .net_read/.net_write })`）＋ 新增 `src/io_net_compat.zig`；杂项字面量/字段改名 | 同上 | 同上 |
| p3 | `safety: guest faults trap instead of aborting the host (#519, #302 family)` | `mapDispatchErr` 的 `else` 由 `@panic` 改为 `error.HostTrap`；三个 mixed multi-result thunk 与 `invokeBufferWrite` 补 `ensureInstalled()` + `stack_limit`；新增回归 fixture 与测试 | **#519 / #302 仍 open** | 上游若修，删除对应部分；建议先把发现作为评论发到 issue（见下） |
| p3b | `refactor: drop the reflection shim for the 0.18 idioms` | 删 `type_info_compat.zig`；用 `@typeInfo(E).@"enum".field_names` + `@field` 取代旧 `std.meta.fields` 视图 | 上游仍 0.16 | 随 p1/p2 一起上游化或删除 |
| p3c | `refactor: use the 0.18 Io idioms for socket reads and writes` | 删 `io_net_compat.zig`；读用 `net.Stream.read(io, bufs)`，写用 `net.Stream.writer(io, buf)` + `writeAll` + `flush` | 同上 | 同上 |
| p3d | `safety: attribute guest faults to the guest, not to the host binding` | `mapDispatchErr` 按 D-445 约定把 10 个 guest 致因错误窄化为 `error.Unreachable`（单一咽喉点，替代改 59 处调用点）；`HostTrap` 保留为兜底 | 与 #519 同类，可合并进该 issue 的评论 | 上游若实现自己的窄化，删除本条 |
| p3e | `safety: two reachable aborts become typed errors` | `invokeFlat` 的 arity assert → `error.ArgArityMismatch`；`Table.set` 的 JIT funcref `@panic` → `error.UnsupportedFuncrefMirror` | 可上游（通用） | 上游若修，删除 |
| p3f | `safety: a large JIT frame traps instead of killing the process (#495)` | `STACK_GUARD_HEADROOM` 全平台统一 1 MiB；两个后端对超出 headroom 的帧 decline（解释器接管） | **#495 仍 open** | 上游若采用别的修法（信号分类/逐页探测），按新形状重写 |
| p4a | `feat(http): stream the response body from the live connection` | `handle` 只做 connect/send/head；body 由 guest 的 `read` 按需从活连接拉，固定 16 KiB transfer 缓冲，**去掉 8 MiB eager 上限**；transfer 单块堆分配（std 的指针自引用） | 上游 p2 http 尚缺 | 可上游化 |
| p4c | `feat(http): host-side cancellation, and a per-thread interp stack limit` | 活 transfer 通过 Host 上的原子钩子发布，`Host.cancelHttp()` 可跨线程 shutdown socket，让阻塞的 body 读立刻返回；被取消的传输标记为失败而不是「正常 EOF」；背压在流式模型下天然成立 | 上游 p2 http 尚缺 | 可上游化（含 `native_stack_limit` threadlocal 修复：跨线程调用 guest 曾立即 `CallStackExhausted`） |
| p4b | `feat(http): host-enforced deadlines for the response head and body reads` | 生效 `request-options` 超时：有效期限 = min(guest, 宿主上限)；宿主上限在 `Host`（`http_head_deadline_ns`/`http_read_deadline_ns`，默认 30s）；头超时映射为 `connection-timeout`；重定向改为不自动跟随 | 同上 | 可上游化 |
| p4 | `feat(http): wasi:http@0.2.x client support — a real p2 guest does a GET` | 新增 `component_wasi_p2_http.zig`：`wasi:http/types` 的 fields/outgoing-request/request-options/incoming-response/incoming-body/future-incoming-response + `outgoing-handler.handle`；`adapter.Entry.op_p2` 支持同名函数按代选 op；body 走新的 input-stream backing | 上游 p2 http 尚缺（其实现是 p3 优先） | 可上游化（通用能力）；若上游实现 p2 http，删除本条 |

## 尚未实施（后续批次）

| 批次 | 内容 | 依赖 |
| --- | --- | --- |
| p4 | 宿主 seam：可注入的 linker/host 定义表、`snooze:host/*` 注册、准入期默认拒绝 | [zwasm-fork-plan.md](zwasm-fork-plan.md) §3/§4 |
| p5 | drain / 卸载屏障：`BuiltComponent` 的在途调用计数 + `drain()`、`WasiP2Ctx` 在途表清理、p3 栈上 `TaskTable` 提升 | 同上 |
| p6 | 标准 p2 HTTP（`wasi:http/types` + `outgoing-handler`）、流式/背压、取消 | [zwasm-fork-feasibility.md](zwasm-fork-feasibility.md) §4 |
| p7 | snooze 专属语义（能力目录、改权=停旧→drain→重建）——**不进上游** | 同上 |

## 需要发到上游的内容（issue 文案见 zwasm-fork-plan.md 附录）

1. 评论 [#519](https://github.com/zwasm/zwasm/issues/519)：一行安全网 + 注册边界归一化建议。
2. 新 issue：未归一化的宿主错误是一类（p2 层 `mapAsyncFault` 0 处调用 vs 59 处直通；坏 `(ptr,len)` 走 `OutOfBounds` 同样 abort）。
3. 评论 [#495](https://github.com/zwasm/zwasm/issues/495)：探针在 `SUB RSP` 之前、处理器不分类栈 fault；四个修法方向请上游选。
4. 评论 [#302](https://github.com/zwasm/zwasm/issues/302)：生产路径 `entry_buffer_write.zig` 同样缺 `ensureInstalled`（本 fork 已修）。
5. 新 issue：Zig 0.18 迁移计划询问（若上游要迁，p1/p2 可贡献）。

## rebase 流程

```sh
git fetch upstream
git rebase --onto upstream/<new-tag> 442f746a6 snooze/base   # 或按需 cherry-pick
zig build && zig build test                                  # 见下
```

**本机已验证（2026-10-15，`zig-0.18-port`）：**

- `zig build`：通过（仅 spec-assert 目标因缺外部 `wasm-tools` 失败，非代码问题）。
- 核心测试套件：**3268 passed / 12 skipped / 0 failed**。
- 冒烟：`--version` 正常；`add(2,40)` 在 interp 与 JIT 下均为 42；`wasi_p2_hello.wasm` 输出 `hello`。
- 进程存活：`invalid_pollable.wasm` → exit 1 + `Unreachable`（规范 guest trap；撤掉安全网则测试进程 SIGABRT，红绿已验）。
- 大帧：`recursive-large-frame.wasm` 在 `--engine jit` 下由 **exit 70（fatal signal）** 变为 `trap kind=stack_overflow`（exit 1）。
- 真实负载未被误伤：ed25519 JIT 测试通过（16 KiB decline 阈值会把它打回解释器，故 headroom 抬到 1 MiB）。
- **p2 HTTP 端到端**：真实 Rust wasip2 1.0.4 + wasi:http 0.2.12 guest（`test/component/http_p2_client.wasm`）对回环服务器 GET：`open` → 200，`read` → `hello-http`，`close` 正常。
- **真流式**：服务器发一半、等 300 ms 再发另一半；guest 在第二块尚未发出时就读到第一块（1 ms），证明宿主不再整体缓冲。
- **宿主期限**：服务器静默不答、guest 要 1 小时超时、宿主上限 300 ms → 调用在期限内失败（`connection-timeout`）。
- **可取消**：服务器只发 head 不发 body，guest 的 `read` 阻塞；主线程 `host.cancelHttp()` 让它在毫秒级返回并把调用判为失败（宿主 30s 期限未参与）。
- 顺带修掉一个真 bug：解释器 `native_stack_limit` 缓存在 Runtime 上（应随线程），跨线程驱动同一 guest 调用会立即 `CallStackExhausted`；已改为 threadlocal。
- 核心套件 **3272 passed / 12 skipped / 0 failed**。

回归基线（本机）：

- `zig build`：需通过（唯一已知非代码失败是 spec-assert 目标缺外部 `wasm-tools`）。
- `zig build test`：core + cli + spec_assert_base；`-Dtest-filter=<substring>` 可定向。
- 直接跑核心套件（不依赖 wasm-tools）：
  `zig test -Odebug -I include --dep build_options --dep zwasm=root -Mroot=src/zwasm.zig -Mbuild_options=.zig-cache/o/<hash>/options.zig -lc`
- 冒烟：`./zig-out/bin/zwasm run --invoke add=2,40 <core.wasm>`、`./zig-out/bin/zwasm run test/component/wasi_p2_hello.wasm`。
- 进程存活：`./zig-out/bin/zwasm run test/component/invalid_pollable.wasm` 必须 exit 1（HostTrap），**不得** SIGABRT。

## 注意

- `test/component/invalid_pollable.{wat,wasm}` 是本 fork 新增的 fixture（合法组件 + `pollable.ready(999)`），上游没有。
- 上游若改变 `mapDispatchErr` 的语义（例如新增 trap 种类），p3 需要按新形状重写，而不是简单保留。
- 上游 HEAD 在本 fork 建立时只比基线多 1 个无关提交（`51634833f`），rebase 成本目前很低。
