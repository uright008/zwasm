# snooze fork：与上游的差异清单

上游：<https://github.com/zwasm/zwasm>
基线提交：`442f746a63c517d2545697aa174d9394f88086f7`（v2.7.0 之后、`#512` 修复）
**当前基点：上游 main `bbd151623`**（2026-10-18 以 **merge** 并入 11 个上游提交；#535 之后上游又自行修了 #495，我们的 p3f 随之删除 —— 见 `p3f` 与「2026-10-18 上游 merge」）。
工作分支：`zig-0.18-port`（fork remote：`fork` = https://github.com/uright008/zwasm）
工具链：**以本机为准**。本 fork 的 `minimum_zig_version` 跟随开发机的 dev 构建
（当前 `0.18.0-dev.357+4812a98ce`），snooze 同步。**port gate 已移除**（2026-10-18 决定）：
CI 在运行时解析 master，会和本机装的那个 dev 不一致——同一棵树一边绿一边红，纯粹是工具链在打架，
而它并不能证明代码正确（正确性由本地全套 + spec 语料 + Mac 的 ReleaseSafe 复验保证）。
换 dev 构建时，在同一个提交里改 `minimum_zig_version` 并跑一遍本地全套。

本文件是 rebase 时的工作清单：每条补丁记录动机、上游 issue、以及上游若自行修复后如何降级。
**不要只靠 commit message**——上游一旦采纳其中某条，这里的「处置」列就是删除依据。

## 补丁系列

| # | 提交 | 内容 | 上游状态 | 处置 |
| --- | --- | --- | --- | --- |
| p1 | `build: port build.zig to the Zig 0.18 std.Build API` | `standardOptimizeOption` 返回可选、`Optimize` 枚举字段改小写、`b.args` 移除、`b.pathFromRoot` → `addFileArg`/`addPrefixedFileArg`（47+5 处） | 上游仍要求 0.16 | 若上游迁 0.18 则整条删除；否则每次上游改动 build.zig 时手工 rebase |
| p2 | `port: run the tree on Zig 0.18-dev` | 四类：`T ** N` → `@splat`/`++`；类型反射（`std.meta.fields`、`Type.Enum.fields`、`Type.Fn.params`）＋ 新增 `src/type_info_compat.zig`；`std.Io` 操作模型（`io.operate(.{ .net_read/.net_write })`）＋ 新增 `src/io_net_compat.zig`；杂项字面量/字段改名 | 同上 | 同上 |
| p3 | `safety: guest faults trap instead of aborting the host (#519, #302 family)` | JIT 入口前置（arm handler + `stack_limit` + 清 latch）已按上游形状收进 `entry.beginJitEntry`，六个入口共用（2026-10-18 同步）；`mapDispatchErr` 的 `else` 已是 `isGuestFault` 窄化 + `HostTrap` 兜底；新增回归 fixture 与测试 | **#302 已合并：上游 `f609b1c35`**（PR [#563](https://github.com/zwasm/zwasm/pull/563)，2026-10-18）；**#519 已由上游 `f45dad90d` 修** | **下次同步上游 main 时删除本地副本**：`entry.zig` 的 `beginJitEntry` 定义 + 5 处调用（`invokeAndCheck`、`invokeAndCheckVoid`、三个 mixed thunk）、`entry_buffer_write.zig` 的调用；**保留 fork 的 0.18 idiom**（`[_]u64{0} ** n` → `@as([n]u64, @splat(0))`），`entry.zig` 的文档注释取上游的三行精简版；`else` / `isGuestFault` 见末尾「注意」 |
| p3b | `refactor: drop the reflection shim for the 0.18 idioms` | 删 `type_info_compat.zig`；用 `@typeInfo(E).@"enum".field_names` + `@field` 取代旧 `std.meta.fields` 视图 | 上游仍 0.16 | 随 p1/p2 一起上游化或删除 |
| p3c | `refactor: use the 0.18 Io idioms for socket reads and writes` | 删 `io_net_compat.zig`；读用 `net.Stream.read(io, bufs)`，写用 `net.Stream.writer(io, buf)` + `writeAll` + `flush` | 同上 | 同上 |
| p3d | `safety: attribute guest faults to the guest, not to the host binding` | `mapDispatchErr` 按 D-445 约定把 10 个 guest 致因错误窄化为 `error.Unreachable`（单一咽喉点，替代改 59 处调用点）；`HostTrap` 保留为兜底 | 与 #519 同类，可合并进该 issue 的评论 | 上游若实现自己的窄化，删除本条 |
| p3e | `safety: two reachable aborts become typed errors` | `invokeFlat` 的 arity assert → `error.ArgArityMismatch`；`Table.set` 的 JIT funcref `@panic` → `error.UnsupportedFuncrefMirror` | 可上游（通用） | 上游若修，删除 |
| p3f | `safety: a large JIT frame traps instead of killing the process (#495)` | ~~`STACK_GUARD_HEADROOM` 统一 1 MiB；两个后端对超 headroom 的帧 decline~~ | **#495 已由上游 `373eceb02` 修**（probe 改成 `LEA RAX,[RSP-frame]` 计入帧 + `LEAF_FRAME_MAX = 8 KiB`） | **已删除**（2026-10-18 merge 按上游取）：`stack_limit.zig` 整文件取上游、两个 emitter 的 prologue decline、`decline_note.frame_bytes`、`cli/run.zig` 的报告分支全部移除 |
| p4a | `feat(http): stream the response body from the live connection` | `handle` 只做 connect/send/head；body 由 guest 的 `read` 按需从活连接拉，固定 16 KiB transfer 缓冲，**去掉 8 MiB eager 上限**；transfer 单块堆分配（std 的指针自引用） | 上游 p2 http 尚缺 | 可上游化 |
| ~~ci1~~ | ~~`ci: a gate for the port branch, on the current Zig 0.18-dev`~~ **已移除（2026-10-18）** | 曾新增 `.github/workflows/port-gate.yml`（运行时解析 master + 跑 spec 语料）。移除原因：它与本机 dev 构建不一致，导致「本地绿、CI 红」的假信号；**验收改回本地**：`zig build` + `zig build test` + spec 语料 + Mac ReleaseSafe。 | — | 已删除，不再维护 |
| p7b | `port: rebase onto upstream af3b0fec1 (#535 landed) and drop our redundant narrowing` | 第二次 rebase（#535「坏句柄 → Unreachable」已上游化）：注册臂改用上游的 `defineMapped(..., mapGuestFault)`；**删掉我们 `hostFnError` 的兜底窄化**（上游 #535 的测试明确要求未 opt-in 的宿主函数保留 embedder 自己的错误）；`isGuestFault` 仅留给非宿主函数路径。移植点：`mapGuestFault` 的 `error_set.?` → `error_names.?`；我们的 `WasiP2Error.OutOfBounds` → `OutOfBoundsLoad` | 上游已实现 D-445 | 分歧已消解，仅剩 `isGuestFault` 兜底 |
| p8a | `feat(host): expose the interrupt and generalize host-IO cancellation` | `Opened.interrupt()` 跨线程停住 guest 调用（解释器每 1024 步轮询中断位 → `error.Interrupted`，`ComponentInstance`/`BuiltComponent` 两种形态都覆盖）；Host 的取消注册表单槽 → `(target, callback)` 列表 + `cancelHostIo()`（`registerHttpCancel`/`cancelHttp` 保留别名；锁跨回调，因为上游测试钉住「unregister 不能在 canceller 还可能用着目标时返回」）；`wasi:clocks` 等待改 20ms 切片 + 让位 `isClosing()`，`Host.clocks_wait_max_ns` 可选硬上限 | 上游无（机制通用；snooze 用它做每插件 deadline） | **可上游化**（通用机制） |
| p8b | `safety: guest lengths and guest addresses are checked, so overflow traps` | `listBytes`/`listBytesOf`/`guestPtr` 三个咽喉点：guest 长度 × 元素大小、guest 基址 + 偏移。溢出 → `OutOfBoundsStore`/`OutOfBoundsLoad`（上游 #535 刻意保留为内存 trap，不折成 Unreachable）。替换 **8 处 size 乘法 + 7 处指针推导**；指针那批即使尺寸已 checked 也必须查（环绕到低地址会静默读写错地方） | 上游同类问题存在（未修） | **可上游化**（通用安全修复） |
| p8c | `test: join the closer thread once (the CI runner caught the double join)` | 测试里 `defer join` + 显式 join 的双重 join：本地侥幸通过、CI runner ABRT。已全局扫描确认树内无第二处 | — | 随 p8a 一起上游化 |
| p9 | `fix(wasi): a trailing .. in remove-directory answers notempty on every host` | `path_remove_directory` 对尾随 `..` **词法**答 `.notempty`（不再落到 syscall）：`X/..` 解析出的目录必然包含 `X`，所以永不为空；Linux 返回 ENOTEMPTY、**macOS 返回 EINVAL**（实测 `rmdir("a/..")` → EINVAL 22，`std.Io` 会把它变成 debug panic，fork 原本映射成 `.io`）。`DottedFinal` 增加 `dotdot_only` | 上游同测试同样在 macOS 失败（无 OS 门控） | **可上游化**（跨平台 errno 一致性） |
| p10 | `fs: kernel-enforced containment for preopens`（**已实现 step A+B**） | 把 `resolve()` 从「词法检查 + 返回相对路径串」改成「**逐组件 `openat(O_NOFOLLOW\|O_DIRECTORY)` 走链**，返回已核验的父目录 fd + 单叶名字」；符号链接组件一律拒（`notcapable`）。关键性质：**全组件禁符号链接后，词法的 `..` 计数与真实深度一致** → 等于内核级包含，不需要 `openat2`（后者只作 Linux 快路）。另加 `PreopenEntry.read_only` 与软配额 | **不上游（用户决定）** | **fork 专属**：优先满足我们自己的严格性，不为上游评审裁剪；但**仍要 rebase 友好**（新文件 `path_walk.zig`，对上游文件改动集中在 11 处 `resolve()` 调用点） |
| p7 | `port: rebase onto upstream main (8 commits) and keep D-445 at the new choke point` | rebase 后上游新代码的 0.18 差异 4 处：① `errdefer \|err\|`（0.18 无捕获式）→ `run` 拆成包装 + `catch \|err\|`；② `@typeInfo(E).error_set` 非可选且不可迭代 → `error_names.?`；③④ `@typeInfo(P).pointer.alignment` → `pointer.attrs.@"align"`。另把 D-445 窄化搬到 `hostFnError`（上游新咽喉点），名单抽成 `Instance.isGuestFault` | 上游仍在 0.16 | 上游迁 0.18 后整条删除；分歧随上游 #535/PR #549 合并而消解 |
| p6f | `feat(cli): say which import a component was refused for` | `zwasm run` 在 `UnsupportedWasiImport` 时追加诊断（接口#函数 + 代）；实测服务端面 `wasi:http/types#[method]incoming-request.consume` 被明确报出 | 通用改进 | 可上游化 |
| p6e | `feat(http): transport failures carry their real error-code` | `handle` 的传输失败不再一律 `internal-error`：`errorCodeFor` 映射到规范错误码（connection-timeout / connection-refused / connection-terminated / destination-unavailable / DNS-error / TLS-protocol-error / TLS-certificate-error / HTTP-protocol-error，catch-all 仍 internal-error）；序号取 0.2.12 声明序。**遗留**：body 读失败仍以调用失败结束，未走 `stream-error::last-operation-failed`（需要 error 资源） | 上游 p2 http 尚缺 | 可上游化 |
| p6d | `feat(http): would-block for non-blocking read, and an honest body pollable` | 非阻塞 `read` 在无数据时返回**空列表**（WASI would-block），`blocking-read` 仍等首字节；body 流的 pollable **真实就绪**（缓冲有字节 / socket 可读（零超时 poll）/ 传输已结束），新 `HTTP_P2_BODY_POLLABLE_RT` 携带 exchange 索引 | 上游 p2 http 尚缺 | 可上游化；「空列表指针须非空悬垂（对齐值 4）」是 canonical ABI 细节，值得上游注意 |
| p6c | `feat(http): request bodies - outgoing-body, write, finish, and POST` | `outgoing-request.body()` → outgoing-body（WIT 只允许一次）；`outgoing-body.write()` → output-stream（一次），写入落进所属请求的缓冲，`check-write`/`flush` 接受该流；缓冲宿主上限 8 MiB；`finish` 定稿（请求 trailers 接受但不承载，已记录），流未 drop 则判为调用失败；`handle` 用 `sendBodyComplete` 发送真实 Content-Length | 上游 p2 http 尚缺 | 可上游化 |
| p6b | `feat(http): response headers and the trailers future` | `incoming-response.headers()` 返回**真实响应头**（`startTransfer` 在 body reader 使 head 失效前复制成不可变 fields，exchange 持有到销毁）；`incoming-body.finish`（static）铸 trailers future；`future-trailers.get` 与 `future-incoming-response.get` 同为**三层嵌套**，本宿主无 trailer → `some(ok(ok(none)))`，第二次 `some(err(()))`；`subscribe` 恒就绪 | 上游 p2 http 尚缺 | 可上游化 |
| p6a | `feat(http): the 0.2 spellings of fields, request-options and outgoing-request` | 0.2 与 0.3 命名差异补齐：`fields` 全量（from-list/get/has/set/delete/append/entries/clone）、`request-options` 三个 getter（0.3 叫 `get-*`）、`outgoing-request` 的 method/set-method/scheme/authority/path-with-query/headers（0.3 改名 `request`）；`headers()` 返回**不可变快照**（set/append/delete → `header-error.immutable`）；未分类 import 现在带诊断（报出 iface#func） | 上游 p2 http 尚缺 | 可上游化 |
| p5a | `feat(host): an embedder seam for component imports, with admission` | `Host.host_imports` 注册自定义接口（`snooze:host/*`，原始签名 + `RawHostFn`，data 经 `caller.host_data`）；未注册且非 WASI 行 → 链接期拒绝（默认拒绝）；`Host.admission_fn` 对**每个** import 生效，返回 false → `ImportDenied`（能力目录唯一真源，WASI helper 不再隐式授权） | 上游无此概念（其 host 注入靠 Rust 侧） | 通用能力，可上游化；snooze 专属语义留在 fork |
| p4c | `feat(http): host-side cancellation, and a per-thread interp stack limit` | 活 transfer 通过 Host 上的原子钩子发布，`Host.cancelHttp()` 可跨线程 shutdown socket，让阻塞的 body 读立刻返回；被取消的传输标记为失败而不是「正常 EOF」；背压在流式模型下天然成立 | 上游 p2 http 尚缺 | 可上游化（含 `native_stack_limit` threadlocal 修复：跨线程调用 guest 曾立即 `CallStackExhausted`） |
| p4b | `feat(http): host-enforced deadlines for the response head and body reads` | 生效 `request-options` 超时：有效期限 = min(guest, 宿主上限)；宿主上限在 `Host`（`http_head_deadline_ns`/`http_read_deadline_ns`，默认 30s）；头超时映射为 `connection-timeout`；重定向改为不自动跟随 | 同上 | 可上游化 |
| p4 | `feat(http): wasi:http@0.2.x client support — a real p2 guest does a GET` | 新增 `component_wasi_p2_http.zig`：`wasi:http/types` 的 fields/outgoing-request/request-options/incoming-response/incoming-body/future-incoming-response + `outgoing-handler.handle`；`adapter.Entry.op_p2` 支持同名函数按代选 op；body 走新的 input-stream backing | 上游 p2 http 尚缺（其实现是 p3 优先） | 可上游化（通用能力）；若上游实现 p2 http，删除本条 |

## 2026-10-18 上游 merge（`bbd151623`，11 个提交）

以 **merge**（不是 rebase）并入上游 main。冲突只 3 处，且全是说明文字 ——
`engine/codegen/x86_64/abi.zig`、`engine/codegen/x86_64/op_simd.zig`、
`ir/analysis/local_homing.zig` 都是「x86_64 寄存器池 4→8」（#503/#557/#560）后的文档改写，取上游。

- **#495 取上游形状**（见 p3f）：删掉 1 MiB headroom、两个 emitter 的 prologue decline、
  `decline_note` 的 `frame_bytes` 理由、`cli/run.zig` 的报告分支。
- **0.18 移植的新增点**（上游新代码带进来的）：`[_]T{…} ** N` → `@as([N]T, @splat(v))`
  （`arm64/emit_test_local.zig`、`x86_64/emit_test_int.zig`、`x86_64/abi.zig`）；
  `@typeInfo(E).@"enum".fields.len` → `.field_names.len`（`x86_64/abi.zig`）。
- **验证（本机，0.18-dev.210）**：`zig build` 通过；`zig build test` — 22/22 steps、
  3442/3454（12 skipped）、核心套件 3332 pass / 12 skip；8000-locals 大帧递归冒烟在
  jit 与 interp 均为 `trap kind=stack_overflow`（exit 1），不再是 exit 70。
- **后续**：#302 的 PR [#563](https://github.com/zwasm/zwasm/pull/563) 于当日合并为上游 `f609b1c35`
  （REBASE 队列，单提交原样落地；issue #302 同时关闭）—— 下次同步按 p3 的处置删除本地副本。

## 2026-10-17 review 修复

- `Transfer` 使用完整结构体初始化，确保取消状态不依赖分配器返回的内存内容。
- 取消目标的注册、回调和移除共用 `Host.http_cancel_mutex`；销毁先移除目标，等待已进入的取消回调结束。回调只设置 `Io.Event`，不跨线程读取或关闭正在初始化的连接。
- HTTP 使用 `std.Io.Select` 将完整网络操作与绝对期限、宿主取消信号竞争；返回前取消并等待所有任务结束。头期限覆盖 DNS、连接、TLS、发送和完整响应头，取宿主上限与 guest connect/first-byte timeout 的最小值；body 读取也覆盖不完整 chunk/TLS 帧。需要支持 `concurrent` 和取消的 `std.Io` 后端（本机验证为 `Io.Threaded`）。
- 新增 7 项回归：脏内存初始化、取消与移除交错、部分响应头超时、guest first-byte timeout、部分 chunk 头超时、TLS 握手超时、部分响应头期间取消。
- 本机验证：`zig build` 通过；`zig build test` 通过，本次执行 3283 passed / 12 skipped / 0 failed，其余测试目标使用成功缓存。

## 尚未实施（后续批次）

| 批次 | 内容 | 依赖 |
| --- | --- | --- |
| p4 | 宿主 seam：可注入的 linker/host 定义表、`snooze:host/*` 注册、准入期默认拒绝 | [zwasm-fork-plan.md](zwasm-fork-plan.md) §3/§4 |
| p5b-done | `feat(host): the unload barrier - admission, cancel, drain` | `Host.enterCall/leaveCall` 计数在途调用（typed invoke 与 `wasi:cli/run` 都过闸门）；`beginClose()` 关准入（新调用 → `InstanceClosing`）；`drain(io, timeout)` 等到归零才返回；`cancelHttp()` 是解除宿主 IO 阻塞的前提 | 上游无此概念 | snooze 专属编排留在 fork；闸门本身通用 |
| p5b | drain / 卸载屏障：`BuiltComponent` 的在途调用计数 + `drain()`、`WasiP2Ctx` 在途表清理、p3 栈上 `TaskTable` 提升 | 同上 |
| p6 | 标准 p2 HTTP（`wasi:http/types` + `outgoing-handler`）、流式/背压、取消 | [zwasm-fork-feasibility.md](zwasm-fork-feasibility.md) §4 |
| p7 | snooze 专属语义（能力目录、改权=停旧→drain→重建）——**不进上游** | 同上 |

## 上游 PR 候选（与上游同步用）

**关键前提**：这些提交都坐在 **Zig 0.18 移植**（p1/p2/p3b/p3c）之上，而**上游仍在 0.16**。
所以它们**不能 cherry-pick 到上游** —— 必须按上游的 0.16 形状**重写一遍**（改动本身多数与
Zig 版本无关，重写量很小）。下表给出「载荷在哪」，重写时照着看即可。

| 候选 | fork 提交 | 载荷（重写时看这些文件/函数） | 关联上游 |
| --- | --- | --- | --- |
| host fn 错误归一化 | `987bbfec8`（部分） | `zwasm/host_func_marshal.zig` 的 `hostFnError`；`zwasm/instance.zig` 的 `mapDispatchErr` | **#519 已由上游 `f45dad90d` 修** |
| ~~大帧 JIT decline~~ | ~~`f8183217d`~~ | 已作废：上游 `373eceb02` 以另一形状修了 #495，本地已按上游取（2026-10-18 merge） | #495 **已修** |
| ~~thunk 武装~~ | ~~`987bbfec8`（后半）~~ | 已合并：上游 `f609b1c35`（PR [#563](https://github.com/zwasm/zwasm/pull/563)，2026-10-18，单提交原样落地）。本地副本待下次同步删除，只留 0.18 idiom | #302 **已修** |
| 跨线程中断 | `4f8f79605` | `zwasm/instance.zig:interrupt`（上游已有）+ `api/component.zig` 的 `Opened.interrupt`/`ComponentInstance.interrupt` + `api/component_wasi_p2.zig` 的 `BuiltComponent.interrupt` | 新（无 issue） |
| 泛化宿主 IO 取消 | `4f8f79605` | `wasi/host.zig` 的注册表（`registerHostCancel`/`unregisterHostCancel`/`cancelHostIo`）+ `component_wasi_p2_http.zig` 的注册调用点 | 新（无 issue） |
| 时钟等待可中断 | `4f8f79605` | `component_wasi_ctx.zig:p2WaitDeadlineSync` 切片 + `Host.clocks_wait_max_ns` | 新（无 issue） |
| checked 算术 | `111629ca5` | `component_wasi_ctx.zig` 的 `listBytes`/`listBytesOf`/`guestPtr` + 15 处调用点 + `test/component/poll_huge_len.{wat,wasm}` | 新（无 issue） |
| 嵌入者 seam | `24a9f3ca6` | `wasi/host.zig` 的 `host_imports`/`admission_fn` + `component_wasi_p2.zig:synthDef` 的准入点 | 新（无 issue） |
| p2 HTTP 客户端 | `d8866db63`…`7fa86e1fe` | 整个 `api/component_wasi_p2_http.zig` + `wasi/adapter.zig` 的 `Entry.op_p2` + 注册臂 | 新（无 issue） |

**怎么取载荷**：`git show <commit> -- <file>`；在上游 0.16 检出上按同样语义重写，**不要直接
`git apply`**（0.18 移植的语法改动会冲突：`errdefer |err|`、`error_set.error_names`、
`pointer.attrs.@"align"`、`std.Io` 操作模型等）。

**不上游的**：`p7`（snooze 专属语义）、`p10`（fs 内核级包含，用户 2026-10-18 决定留在 fork）。
`p10` 进度：**step A**（`path_walk.zig`：走链 + 叶子助手 + 单测）、**step B**（`resolve()` 与 `fd.zig:pathOpen` 接线、
三处叶子跟随堵住、端到端逃逸测试红/绿已验）、**step C-1**（`addPreopenWith(..., .{ .read_only = true })`：权位表里抹掉
`WRITE_RIGHTS`，只读 preopen 的每个写操作由既有的 `has(needed)` 自然拒为 `notcapable`，测试同时验证同一操作在读写
preopen 上成功）**完成**；**step C-2**（写入计量软配额）待做。
snooze 侧配套（不在本表，属接入层）：`catalog.FsGrant`/`preopensFor` —— grant 默认关闭，开启时**唯一合法目标是插件
自己的目录**，且 plugin id 按敌意输入校验（`..`/分隔符/绝对路径/盘符/前导点/内嵌 NUL 一律拒绝而非净化）。
判断标准：如果一条改动是**我们的严格性选择**（而非上游缺的能力），留在 fork；上游若哪天自己做了等价物，
我们按新形状重写或直接删掉自己的。

**同步节奏建议**：每次上游 rebase 后回头核对本表 —— 上游修掉的候选（如 #519）立即从表中删除，
并删掉 fork 里对应的那部分（`p3` 的前半就是这么消失的）。

**探针 PR 的结论（2026-10-18）：欢迎。** `#563` 被维护者 `jtakakura` 逐条评审（`CHANGES_REQUESTED`）：
指出 stack-limit 那一半**没有测试覆盖**（删掉 `rt.stack_limit` 行后 `test-all` 仍全绿），并**直接给出**
fixture（`rec_i32f64`）与 runner 行；另有 `dbg.initFromEnv`、散文措辞、注释精简三点。我们按四点全部回推
（含新增第 5 行、把 fixture 改成 `addFileArg` 以免缓存造成假覆盖），并附上「只删 stack_limit 行 → 该行
报 `no_trap`」的对照测量。**结论：这类贡献上游是认真接的**，后续候选可以按同一套（披露 + 可复现测量 +
红/绿对照）继续发。

**原始探针协议（保留作参考）**：`#563`（thunk 武装 / #302）是**第一发**，用途是先探上游维护者对这类贡献的态度。
观察顺序：① 维护者是否**批准 workflow 运行**（fork 首次贡献者默认 `action_required`，单这一步就说明
他们愿意看）；② 是否有 review 意见；③ 若长期无回应，则默认「不欢迎」，**停止再开新 PR**，改为继续在
fork 里积累（本表的候选不丢，随时可再发）。在 #563 有信号之前，**不要开第二发**。

## 需要发到上游的内容（issue 文案见 zwasm-fork-plan.md 附录）

**已不需要**：`#519`（上游 `f45dad90d` 已修，语义与我们一致）、`#512`（本 fork 的基线就是它的修复）、`#535`（上游已并入，我们的兜底随之删除）。

仍要发的：

1. ~~评论 [#495](https://github.com/zwasm/zwasm/issues/495)~~ → 上游已自行修复（`373eceb02`：probe 计入帧），无需评论。
2. ~~评论 [#302](https://github.com/zwasm/zwasm/issues/302)~~ → PR [#563](https://github.com/zwasm/zwasm/pull/563) **已于 2026-10-18 合并为上游 `f609b1c35`**，issue #302 同时关闭。
3. 新 issue / PR：上表里标「新（无 issue）」的通用机制（中断、泛化取消、checked 算术、嵌入者 seam）——建议**直接开 PR**，比 issue 更有说服力。
4. 询问：Zig 0.18 迁移计划（若上游要迁，p1/p2/p3b/p3c 可贡献；目前上游仍 0.16）。

## rebase 流程（当前配方）

```sh
cd /home/uright/zwasm-fork
git fetch origin main
git rev-list --count HEAD..origin/main            # 领先多少提交
git branch -f backup-$(date +%m%d) HEAD           # 先留后路
git rebase --onto origin/main <上一次的基点> zig-0.18-port
```

**基点写在文件顶部**（当前 `af3b0fec1`）。rebase 冲突通常只有一类：**上游改了注册臂的风格**
（如 #535 把 `lk.defineFuncCtx(...)` 换成 `defineMapped(..., mapGuestFault)`），而我们那些提交
在同一个 switch 里加臂 —— 解法是取上游风格，把我们新增的臂按同样风格重写，**不要整文件取一边**
（会把该提交里非臂的改动一起丢掉：import、drop 分支、subscribe、write 路由都吃过这个亏）。

**rebase 后必查的移植点**（上游新代码里的 0.18 差异，每类都出现过）：

| 上游写法 | 0.18 的改法 |
| --- | --- |
| `errdefer \|err\| ...` | 0.18 无捕获式 errdefer → 拆包装函数 + `catch \|err\|` |
| `@typeInfo(E).error_set.?` / `inline for (...error_set)` | → `error_set.error_names.?` + `@field(E, name)` |
| `@typeInfo(P).pointer.alignment` | → `pointer.attrs.@"align"` |
| `b.standardOptimizeOption(.{})` / `std.builtin.OptimizeMode` | → `orelse .debug` / `lang.Optimize` 小写字段 |
| 内存错误 `OutOfBounds` | → 上游拆成 `OutOfBoundsLoad`/`OutOfBoundsStore` |

**验收顺序（本地为准）**：`zig build` → `zig build test`（核心套件）→ spec 语料
（`test-spec-assert` / `-wasm-2.0-assert` / `-threads-assert` / `test-edge-cases` / `test-component-spec` /
`test-spec-wasm-3.0-assert`）→ 需要时在 Mac 上跑一遍 `-Doptimize=ReleaseSafe`（arm64 + 另一个 OS）。
**换 dev 构建后必跑全套**：dev 之间会有 breaking（`ArrayListUnmanaged` 移除、
`standardOptimizeOption` 从可选变非可选各一次），一次本地全套比事后猜快得多。

**最新验证（2026-10-17，`zig-0.18-port` @ `fc553bf0e`）：**

- 核心套件 **3303 passed / 12 skipped / 0 failed**；`zig build` 0 错误。
- 本地 spec 语料全绿（wasm 1.0 212/0、2.0 25543/0、threads 294/0、组件模型 170/0、wasm 3.0 interp
  14579/0、jit 8 个已知 #378、边界用例 252/0），另有 Mac（arm64 macOS）ReleaseSafe 复验。
- 新增回归：跨线程 `Opened.interrupt()` 停住自旋 guest（`< 1s`，`error.Interrupted`）；
  `Host.cancelHostIo()` 多目标取消（含 unregister 等待语义）；一小时 `wait-until` 被 `beginClose()` 打断；
  `in_len = 0x4000_0000` 调 `wasi:io/poll#poll` → guest 看到 `OutOfBoundsStore`（**未检查时该 fixture 会
  `panic: integer overflow` 打死进程**，红/绿已验）。

**更早（2026-10-15）：**

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
- **宿主 seam**：`test/component/host_import_probe.{wat,wasm}` 导入 `snooze:host/probe#answer`：(1) 未注册 → `UnsupportedWasiImport`；(2) 注册 → guest 拿到宿主返回的 4242；(3) 注册但准入拒绝 → `ImportDenied`。
- **卸载屏障**：guest 调用阻塞在 body 读时，`beginClose()` → 新调用 `InstanceClosing`；`cancelHttp()` 解除阻塞；`drain()` 返回 true 且 `inFlight()==0`；此后才销毁组件，取消目标已清空。
- **0.2 面补齐**：`test/component/http_fields_probe.wasm`（Rust wasip2 1.0.4 guest）自跑约 25 项检查（含无效 header 名、不可变视图两条错误路径），返回失败清单；实测为空。
- **响应头/trailers**：probe 的 `fetch-report` 真发 GET，校验服务器自定义头、`content-length`、头视图不可变（`header-error.immutable`）、body 完整、trailers `some(ok(ok(none)))` 且第二次 `some(err(()))`。
- **请求体/POST**：probe 的 `post-report` 经 output-stream 写体、验证 `write()` 只允许一次、`finish` 后发送；回显服务器返回的 body 与写入完全一致。
- **would-block / 就绪**：probe 的 `nonblocking-report` 对「先发头、body 延后 300ms」的服务器：pollable 报未就绪 → 非阻塞 `read` 返回空 → `block()` 在 body 到达时唤醒 → 读到 `slow-body!`。
- **error-code 保真**：probe 的 `refused-report` 对「已绑定后关闭的端口」→ guest 看到 `ErrorCode::ConnectionRefused`（而非泛化失败）。
- **服务端面诊断**：`zwasm run` 对导入 `[method]incoming-request.consume` 的组件输出 `UnsupportedWasiImport (unclassified component import 'wasi:http/types#[method]incoming-request.consume' (p2))`。
- 核心套件 **3286 passed / 12 skipped / 0 failed**。
- 注：定义表（`host_imports`）已可注入；`Linker` 对象本身仍由内部创建——注册表已覆盖「自定义 import + 默认拒绝」的需求，暂不需要暴露 Linker 对象。

回归基线（本机）：

- `zig build`：需通过（唯一已知非代码失败是 spec-assert 目标缺外部 `wasm-tools`）。
- `zig build test`：core + cli + spec_assert_base；`-Dtest-filter=<substring>` 可定向。
- 直接跑核心套件（不依赖 wasm-tools）：
  `zig test -Odebug -I include --dep build_options --dep zwasm=root -Mroot=src/zwasm.zig -Mbuild_options=.zig-cache/o/<hash>/options.zig -lc`
- 冒烟：`./zig-out/bin/zwasm run --invoke add=2,40 <core.wasm>`、`./zig-out/bin/zwasm run test/component/wasi_p2_hello.wasm`。
- 进程存活：`./zig-out/bin/zwasm run test/component/invalid_pollable.wasm` 必须 exit 1（HostTrap），**不得** SIGABRT。

## 跨架构验证（aarch64 macOS，2026-10-18）

首次把 fork 的 gate 搬到 Apple M6 / macOS 27.0.1 上跑（Zig `0.18.0-dev.253+16d31ceed`
aarch64-macos + wasm-tools 1.262.0，`~/zwork/fork` @ `4d5d4eb`）。**spec 语料与 x86_64 Linux
逐项一致**（wasm 1.0 212/0、2.0 25543/0、threads 294/0、组件模型 170/0、wasm 3.0 interp
14579/0、jit 8 个已知 #378、边界用例 242/0）——0.18 移植与全部改动架构中立。

两个 macOS 侧发现（**都不是 fork 的代码问题，未改动**）：

1. **Debug 单元套件在 macOS arm64 上必挂**：std 的 Mach-O 回溯器在
   `SafeAllocator.captureStackTrace` → `SelfInfo.MachO.unwindFrameInner` 里 `switch on corrupt
   value`，随后 panic 路径死锁（`MachO.findModule` → `Io.Mutex.lock`）。Debug 下测试分配器每次
   free 都抓栈，必踩。**用 `-Doptimize=ReleaseSafe` 绕过**（3419/3432 passed）。值得报给 zig。
2. **上游测试的 Linux 假设 → 已修（`p9`）**：`path_remove_directory` 的 `a/..` 用例期望
   `ENOTEMPTY`，而 macOS 实测 `rmdir("a/..")` 返回 **EINVAL**（直接验过；该测试是上游的、无 OS 门控）。
   修法是**词法**答 `.notempty`（`X/..` 必然非空），不落 syscall —— 修完 **macOS ReleaseSafe
   22/22 steps、3413/3425 passed、0 failed**。

复现：`~/zwork/run-rs.sh`（ReleaseSafe 单元套件）、`~/zwork/run-spec.sh`（spec 语料）。

## 注意

- **#302 已上游化**（上游 `f609b1c35`，2026-10-18 合并）：本地那份 `entry.beginJitEntry` 及其 6 处调用，**下次同步上游 main 时删除**；删除时**保留 0.18 idiom**（`entry_buffer_write.zig` 的 `@splat`），`entry.zig` 的注释取上游的三行精简版 —— 是纯删除，不需要按新形状重写。
- `test/component/invalid_pollable.{wat,wasm}` 是本 fork 新增的 fixture（合法组件 + `pollable.ready(999)`），上游没有。
- 上游若改变 `mapDispatchErr` 的语义（例如新增 trap 种类），p3 需要按新形状重写，而不是简单保留。
- 上游 HEAD 在本 fork 建立时只比基线多 1 个无关提交（`51634833f`）；2026-10-17 复查时领先 8 个提交，已 rebase（零冲突）。
- **上游仍在 Zig 0.16**（`b.standardOptimizeOption(.{})` 非可选、`std.builtin.OptimizeMode`），所以 p1/p2/p3b/p3c 的 0.18 移植**仍然必要**。
- **工具链现状**：本机与 snooze 的 `minimum_zig_version` 都是 `0.18.0-dev.210+3626a240e`，而**该 dev 构建已被 ziglang.org 清理**（现在 master 是 dev.253+）。所以 CI 改为运行时解析当前 master；首次运行全绿说明移植在更新的 dev 上也成立。若要复现 dev.210，需要另存该 tarball 或统一升到当时的 dev。
- 上游 `f45dad90d`（#519）已在 marshal 边界把 host fn 的错误规范成 `HostTrap` —— 与 fork 的 p3 前半重叠；fork 把 D-445 归因搬到了这个新咽喉点（`Instance.isGuestFault`，`hostFnError` 与 `mapDispatchErr` 共用一份名单），并在上游那条 #519 测试里记录了**有意分歧**（期望 `Unreachable`）。上游 #535 / PR #549 正在走同一方向，合并后本分歧与窄化都可删。
