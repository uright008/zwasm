# snooze fork：与上游的差异清单

上游：<https://github.com/zwasm/zwasm>
基线提交：`442f746a63c517d2545697aa174d9394f88086f7`（v2.7.0 之后、`#512` 修复）
工作分支：`snooze/base`
工具链：Zig `0.18.0-dev.210+3626a240e`（上游要求 0.16；本 fork 已迁到 0.18-dev）

本文件是 rebase 时的工作清单：每条补丁记录动机、上游 issue、以及上游若自行修复后如何降级。
**不要只靠 commit message**——上游一旦采纳其中某条，这里的「处置」列就是删除依据。

## 补丁系列

| # | 提交 | 内容 | 上游状态 | 处置 |
| --- | --- | --- | --- | --- |
| p1 | `build: port build.zig to the Zig 0.18 std.Build API` | `standardOptimizeOption` 返回可选、`Optimize` 枚举字段改小写、`b.args` 移除、`b.pathFromRoot` → `addFileArg`/`addPrefixedFileArg`（47+5 处） | 上游仍要求 0.16 | 若上游迁 0.18 则整条删除；否则每次上游改动 build.zig 时手工 rebase |
| p2 | `port: run the tree on Zig 0.18-dev` | 四类：`T ** N` → `@splat`/`++`；类型反射（`std.meta.fields`、`Type.Enum.fields`、`Type.Fn.params`）＋ 新增 `src/type_info_compat.zig`；`std.Io` 操作模型（`io.operate(.{ .net_read/.net_write })`）＋ 新增 `src/io_net_compat.zig`；杂项字面量/字段改名 | 同上 | 同上 |
| p3 | `safety: guest faults trap instead of aborting the host (#519, #302 family)` | `mapDispatchErr` 的 `else` 由 `@panic` 改为 `error.HostTrap`；三个 mixed multi-result thunk 与 `invokeBufferWrite` 补 `ensureInstalled()` + `stack_limit`；新增回归 fixture 与测试 | **#519 / #302 仍 open** | 上游若修，删除对应部分；建议先把发现作为评论发到 issue（见下） |

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
