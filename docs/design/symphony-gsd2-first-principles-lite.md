# Symphony × GSD-2（第一性原则精简版）

## 目标

不是做一个“完美的 unattended workflow engine”，而是在 **保留 Symphony 现有使用体验** 的前提下，借用 GSD-2 的少量控制面能力，解决三个最核心的问题：

1. Agent 可以跳过 validation → 需要 orchestrator-level verification
2. 一个 issue 一个长 session，crash 后恢复粗糙，token 消耗高 → 需要 phase/subtask 级 dispatch + ledger
3. Implement 阶段容易漂移 → 需要 subtask-level dispatch

---

## 一句话方案

**保留 Symphony 的 issue/workpad/PR/workflow 外壳，只引入 4 个 GSD-2 元素：**

1. **单位调度**：从 “一个 issue 一个长 session” 改成 “一个 issue 多个短 unit session”
2. **小型 ledger**：每个 unit 的 start / finish / accepted 都持久化
3. **程序化验证**：validation 不再只靠 prompt 约束，必须由 orchestrator 跑命令并记录结果
4. **基于 checklist 的 subtask dispatch**：实现阶段每次只做一个子任务

---

## 设计边界

### 保留 Symphony 的部分

- Linear issue 仍然是顶层工作对象
- `## Codex Workpad` 仍然是主要的人类可读进度载体
- `## Results` 仍然是最终交付摘要
- 现有工作流骨架仍然是：Bootstrap → Plan → Implement → Validate → Handoff
- `Merging` 仍然保留一个专门 fast path

### 借 GSD-2 的部分

- dispatch resolver：由 orchestrator 决定下一步，不由长会话 agent 自行决定
- 一次只执行一个小 unit
- ledger / runtime record：崩溃后从 durable state 恢复
- post-unit closeout：worker 结束后由控制面判断是否接受

### 明确不做的部分（至少第一版不做）

- 不做 full proof model
- 不做 cycle/gate/work-item 的完整状态机
- 不做 remote observable total-truth 系统
- 不做 synthetic findings backlog 引擎
- 不做复杂 revision/cursor/effect receipt 体系
- 不把整个 Symphony 改造成 GSD-2

---

## 最小状态模型

每个 issue 只需要一个很小的 durable 状态文件，例如 `issue_exec.json`：

```json
{
  "phase": "planning | implementing | verifying | handoff | merging",
  "current_subtask_id": "plan-2",
  "last_accepted_unit": "implement_subtask:plan-2",
  "last_commit_sha": "abc123",
  "last_verified_sha": "abc123",
  "plan_hash": "...optional...",
  "attempt": 2
}
```

再加一个 append-only `ledger.jsonl`：

```json
{"ts":"...","event":"unit_started","unit":"plan"}
{"ts":"...","event":"unit_accepted","unit":"plan"}
{"ts":"...","event":"unit_started","unit":"implement_subtask","subtask":"plan-2"}
{"ts":"...","event":"unit_accepted","unit":"implement_subtask","subtask":"plan-2","commit":"abc123"}
{"ts":"...","event":"verify_passed","sha":"abc123"}
```

这就够了。第一版不需要更复杂的数据结构。

---

## Unit 设计：只保留 5+1 个

### 1. `bootstrap`

职责：
- 把 `Todo` 拉到 `In Progress`
- 找/建 workpad
- 确认 branch/workspace
- 跑 baseline validation（如果 ticket 涉及 app code）

accepted 条件：
- workpad 存在
- branch/workspace 就绪
- baseline validation 结果被记录

### 2. `plan`

职责：
- 生成或重整 workpad 里的 checklist
- 要求 checklist 可解析
- 每个 item 都是可独立执行的小步

accepted 条件：
- workpad 的 `Plan` section 存在
- 至少一个未完成 subtask
- checklist 可被 orchestrator 解析

> 第一版不强制引入 `PLAN.md`。直接复用 workpad，避免 authority migration。

### 3. `implement_subtask`

职责：
- 一次只做一个 checklist item
- 结束时更新 workpad
- 完成后提交一个 recovery-point commit

accepted 条件：
- 指定 subtask 已被标记完成
- 有对应代码/文件变化，或明确记录“无代码变更原因”
- 工作树 clean（如果要求每个子任务后 commit）
- ledger 记录 `unit_accepted`

### 4. `verify`

职责：
- orchestrator 自己跑验证命令，而不是相信 agent 说“我已经验证了”
- 至少包括：
  - baseline/full validation
  - 需要时的 surface-specific validation
  - 可选 code-review / visual-review skill

accepted 条件：
- 所需命令 exit 0
- 验证结果落盘/入 ledger
- `last_verified_sha == HEAD`

### 5. `handoff`

职责：
- 写 `## Results`
- push / attach PR URL
- 切到 `Human Review`

accepted 条件：
- `last_verified_sha == HEAD`
- Results 已写
- PR URL 存在（如果 workflow 要求）
- issue 状态迁移成功

### 6. `merge`（特殊 fast path）

职责：
- 当 issue 进入 `Merging` 时，跳过普通 flow，直接 land

accepted 条件：
- merge 成功
- issue → `Done`

---

## 真正关键的 4 条 invariant

### I1. 任何 coding session 只能拥有一个明确 unit

不能再让 agent 在一个长 session 里自己决定“现在顺手把 plan / implement / review / handoff 都做了”。

### I2. 任何 handoff 前都必须满足 `last_verified_sha == HEAD`

只要代码又变了，验证自动失效，必须重新 verify。

### I3. implement 阶段一次只允许消费一个 subtask

这能显著减少漂移和 token 消耗。

### I4. crash 恢复只重放“当前 unit”，不重放整个 issue

这就是 ledger 的价值：恢复粒度从 issue 降到 unit/subtask。

---

## Dispatch 规则（极简版）

```text
if state == Merging:
  dispatch merge
else if state == Rework:
  reset subtask progress, dispatch plan
else if no workpad / not bootstrapped:
  dispatch bootstrap
else if no parseable checklist or plan stale:
  dispatch plan
else if exists unchecked subtask:
  dispatch implement_subtask(next_unchecked_item)
else if last_verified_sha != HEAD:
  dispatch verify
else if doc_audit_pending:
  dispatch doc_fix
else:
  dispatch handoff
```

注意 `doc_audit_pending` 在 verify 之后、handoff 之前。closeout 跑 doc-audit 发现问题后
设置这个 flag，确保文档更新后才 handoff。这保证了下一个 issue 的 agent（甚至同时并发的
其他 agent）读到的仓库文档是最新的。

这是第一版最重要的控制面。简单，而且已经足够解决主要问题。

---

## 为什么这版比 v5/v6 更贴近第一性原则

因为它只回答三个问题：

### 问题 1：Agent 会不会跳过 validation？
回答：不会。因为验证由 orchestrator 决定何时跑、亲自跑、亲自记结果。

### 问题 2：为什么会烧 token？
回答：因为一个 issue 绑定一个长 session。解决方式不是建巨大 proof system，而是把执行拆成短 unit，每个 unit 用新 session。

### 问题 3：为什么 implement 会漂？
回答：因为 session scope 太大。解决方式不是复杂 gate，而是一次只做一个 subtask。

---

## 与当前 Symphony 的最小改动点

### 1. 不再让 continuation prompt 决定 phase

当前 continuation 逻辑是“读 workpad，判断上一个 phase 到哪里，然后继续”。

改成：
- orchestrator 先 resolve next unit
- prompt 只告诉 agent：**你现在只做这个 unit**

### 2. `AgentRunner` 从 issue-runner 变成 unit-runner

当前：
- 一个 issue 启一个 Codex session，turn 内继续

改成：
- orchestrator dispatch `run_unit(issue, unit)`
- unit 完成后退出 session
- 下一个 unit 再新开 session

### 3. 增加一个极轻量 closeout 层

当前 worker 正常退出后，系统主要做的是 active-state continuation check。

改成：
- worker 退出
- orchestrator 跑 verification（validate-app.sh 等命令）
- orchestrator 跑 doc-audit（检查文档是否因本次改动过期）
- closeout 检查该 unit 是否 accepted
- 如果 doc-audit 有发现 → 紧接着派一个 doc-fix unit
- accepted 才推进到下一个 unit

---

## Prompt 也要一起收缩

### `implement_subtask` prompt 只需要：
- issue 摘要
- 当前 subtask 内容
- 相关文件/grep 结果
- workpad 中与当前 subtask 相关的几行
- 完成定义（更新 workpad、必要时 commit、不要做别的 subtask）

### 明确不要塞进去的东西：
- 完整多轮线程历史
- 全量 workflow 讲解
- 所有未来 subtasks 的细节
- 整个 ticket 的所有 review artifact

这才是省 token 的关键。

---

## Context Drift 的解法：Harness Engineering，不是 Summary Chain

### 问题

每个 subtask 用新 session 意味着上下文不连续。前一个 agent 做的设计决策、发现的约束、选择的
API 模式，下一个 agent 不知道。这就像传悄悄话——每一步都积累一点偏移，最后变样。

### 错误的解法

v3-v6 试图用 phase anchor（结构化交接文件）、summary chain（每个 task 完成后写摘要）来解决
这个问题。这些机制有效，但本质上是在 **发明一个新的信息传递管道**。管道越长越脆弱。

### 正确的解法：仓库就是 anchor

根据 [Harness Engineering](docs/engineering/HARNESS_ENGINEERING.md) 的核心原则——**仓库是
唯一的真相源，环境优于努力**——正确的做法不是在 session 之间传递摘要，而是：

**让仓库本身始终是最新的。每个新 session 读仓库就能获得完整上下文。**

具体机制：

1. **每个 unit closeout 强制跑 doc-audit。** 不是可选的。Orchestrator 在 verification 之后、
   dispatch 下一个 unit 之前，跑 doc-audit skill 检查这次改动是否让文档过期。过期了就作为
   下一个 unit 修复。

2. **AGENTS.md / docs/ 就是天然的 anchor。** 不需要发明 `.symphony/anchors/plan.json`。
   仓库里的 `AGENTS.md`、`docs/ARCHITECTURE.md`、`docs/engineering/` 已经描述了"我们为什么
   这样做、关键约束是什么"。只要它们是 fresh 的，新 session 读完就知道一切。

3. **Capability over retry 应用到 context drift。** 如果第 5 个 subtask 的 agent 做出了跟前面
   不一致的设计选择，正确的反应不是"加一个 anchor 传递机制"，而是问："AGENTS.md 或
   architecture doc 里是不是缺了这个约束？"然后补上。这样第 6 个 subtask 也不会犯。

4. **代码本身是 ground truth。** Agent 不是在传话，是在改代码。代码在 workspace 里，每个
   session 开始时 agent 直接读。文件存不存在、函数写没写、测试过不过——这些不会因为"传话"
   失真。

### Closeout 流程（更新版）

```text
unit 完成（worker 退出）
→ orchestrator 跑 verification（validate-app.sh 等）
→ orchestrator 跑 doc-audit（文档是否因这次改动而过期）
→ 如果 doc-audit 有发现 → 记录，作为紧接的下一个 unit 处理
→ 记录 unit_accepted → 派发下一个 unit
```

### 为什么这比 summary chain 更好

| 方式 | 信息载体 | 腐化风险 | 受益者 |
|------|----------|----------|--------|
| Summary chain | 专用 .symphony/ 文件 | 每次传递都有 loss | 只有下一个 session |
| Phase anchor | 专用 JSON 文件 | 需要 agent 配合写入 | 只有下一个 session |
| **仓库文档常新** | AGENTS.md / docs/ | 由 doc-audit 机械化维护 | **所有未来 session + 人类** |

仓库文档不只服务下一个 subtask 的 agent——它服务所有人：其他 issue 的 agent、人类 reviewer、
未来的维护者。投资在仓库文档上的回报是复利，投资在 session 间传递文件上的回报是一次性的。

---

## 恢复语义（第一版）

如果在 `implement_subtask(plan-2)` 崩溃：

- 读取 `issue_exec.json`
- 发现当前 unit 是 `implement_subtask(plan-2)`
- 重新 dispatch 同一个 subtask
- prompt 中加一句：检查现有代码与 workpad，补齐该 subtask 未完成部分，不要扩展范围

恢复语义不需要复杂 forensics 也能先成立。

---

## 什么时候再加复杂度

只有在这些问题真的出现后，再加下一层：

1. **subtask 之间的设计决策不一致** → 先检查：AGENTS.md / docs 是否缺了约束？doc-audit 是否
   在跑？如果文档是 fresh 的还不一致，再考虑加 summary chain 或 anchor
2. **review finding 经常反复 reopen** → 再加 stable finding IDs
3. **Rework 语义混乱** → 再加 cycle_id
4. **remote side effect 经常观察不一致** → 再加 effect receipt / awaiting_observation
5. **handoff/merge correctness 经常出错** → 再加更严格 remote proof

在这些问题出现前，不要预付系统复杂度。

特别注意第 1 条：**context drift 的第一道防线是仓库文档质量，不是 session 间传递机制。**
只有在 doc-audit 持续运行、文档始终 fresh 的情况下仍然出现 drift，才说明需要更重的方案。

---

## 推荐落地顺序

### Phase A：先切断长 session
- `AgentRunner` 改成 per-unit session
- 加 `ledger.jsonl`
- orchestrator 解析 workpad checklist，按 subtask dispatch

### Phase B：把 validation 提到 orchestrator
- baseline validate before coding
- full verify before handoff
- `last_verified_sha` 失效规则接上

### Phase C：补 recovery-point commit
- 每个 subtask 完成后 commit
- crash 恢复回到上一个 accepted unit

### Phase D：再考虑 review 单元化
- 如果需要，再把 code-review / visual-review 从 `verify` 里拆出来
- 这一步不是第一版必需

---

## 最终结论

这版系统的本质不是“Symphony 变成 GSD-2”，而是：

> **Symphony 继续做 issue/workflow 外壳，GSD-2 只提供小单位调度、ledger、programmatic verification、subtask discipline。**

如果目标是：
- 更少 token
- 更少 session 漂移
- 更强执行控制
- 不推翻现有 Symphony

那这版比 v5/v6 更对路。
