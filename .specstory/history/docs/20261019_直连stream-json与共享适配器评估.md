# 直连 `stream-json` 传输与共享 ACP 适配器评估

> @author ixxxxoooo
> 日期:2026-10-19
> 背景:与 `~/baocode`(Flutter,直接 `claude -p --input-format stream-json --output-format stream-json --include-partial-messages`)对比后,评估 OhMyAgent 是否应绕过 Node 适配器(`claude-agent-acp`)直连 CLI,或让多个会话共享一个适配器进程。**结论:本轮不实现,仅作决策记录。**

## 1. 现状

```
OhMyAgent ──ACP(JSON-RPC/stdio)──▶ Node 适配器(每会话一个) ──▶ claude CLI(每会话一个)
```

- 每个活跃会话 ≈ 380 MB:Node 适配器 ~100 MB + `claude` CLI ~265 MB(实测见 `20261019_内存与CPU占用优化方案.md`)。
- 已落地的缓解:会话休眠/唤醒 + 驻留策略(闲置 10 分钟或超过 3 个进程时休眠),待命池预热。
- 事件链路:`Transport` 行读取 → `ACPClient` 事件流 → `EventCoalescer` 合批 → 主线程 `SessionModel.handle`。本轮已把合批窗口改为随主线程处理耗时自适应,并给两个积压点加了阈值告警(`backlog.acpLines`/`backlog.events`,5000 条)。

## 2. 方案 A:直连 `stream-json`(去掉 Node 适配器)

收益:
- 每会话省 ~100 MB 内存与一次 Node 冷启动(约 200~400 ms);少一层 JSON 转换,首字延迟略低。
- 与 BaoCode 同构,可直接对照其事件处理。

代价与风险:
- **协议能力回退**:适配器实现了 ACP 的权限请求(`session/request_permission`)、文件读写代理、终端代理、`session/resume`/`load` 回放、模式切换、斜杠命令、`additionalDirectories` 等。直连后这些都要在 Swift 侧用 `stream-json` 的控制消息(`can_use_tool`、`control_request` 等)重新实现,且协议随 CLI 版本漂移,没有 ACP 这种稳定契约。
- **多引擎失去统一抽象**:`AgentRegistry` 里 Codex/OpenCode/Gemini 等引擎都走 ACP,直连只适用 Claude Code,会长期维护两条传输路径。
- **现有功能依赖面大**:休眠/唤醒(`session/resume`)、待命池、Bridge MCP 注入、模型映射代理、计划/子代理卡片、历史回放均基于 ACP 事件模型,迁移面覆盖 `ACPKit`、`ChatKit`、`WorkbenchKit` 多个模块与大量测试。
- 内存收益有限:主要成本是 `claude` CLI 自身(~265 MB),直连不改变它。

估算:约 3~5 周(协议适配 + 权限/回放/恢复对等 + 回归),且需要为每次 CLI 升级做兼容跟踪。

## 3. 方案 B:多会话共享一个适配器进程

- 适配器基于 Claude Agent SDK,**一个会话对应一个 CLI 子进程**。共享适配器只能合并 Node 运行时(~100 MB × N → ~100 MB + 少量增量),CLI 部分(~265 MB × N)不变。
- 引入的风险:适配器内部状态隔离(崩溃/挂起会拖垮所有会话)、需要修改或 fork 上游适配器(当前以 `Vendor/acp` 原样使用)、会话级环境变量(`ANTHROPIC_*`、网关令牌)按进程隔离的假设被打破。
- 收益/风险比低于方案 C。

## 4. 方案 C:继续控制「同时存活的会话数」(当前采用)

- 休眠/唤醒把闲置会话的两个进程都结束,单会话省 ~380 MB,而不是只省 100 MB;唤醒 1.5~2.1 秒。
- 可选增强(未做,按需):
  1. 休眠态在侧栏/标签显示专属状态点(K49 偏差里已记录)。
  2. 驻留上限随物理内存自适应(现为固定 3)。
  3. 把「首个事件到达」之前的适配器冷启动放到待命池里完成(已有 `EngineWarmPool`)。

## 5. 决策

| 方案 | 内存收益 | 工作量 | 风险 | 结论 |
|---|---|---|---|---|
| A 直连 stream-json | 中(每会话 -100 MB) | 大 | 高(协议/多引擎/回归) | **暂不做**,需要产品层面明确「只支持 Claude Code」后再评估 |
| B 共享适配器 | 小~中 | 中 | 中高(隔离、上游分叉) | **不做** |
| C 休眠 + 驻留策略 | 大(每会话 -380 MB) | 已完成 | 低 | **继续**,按实测迭代 |

重新评估的触发条件:① 流式首字延迟被用户明确感知为瓶颈且已排除渲染侧问题;② 同时活跃会话数的实际需求 > 5 且内存仍是首要投诉;③ ACP 适配器停止维护或与 CLI 新版本不兼容。
