# Stage-based Workflow Chain — Design (slim)

**状态**: Draft, 精简版
**作者**: 同 v1; 经过 6 轮 Codex review 后反思，砍掉过度工程化的部分
**相关仓库**: `openai/symphony` (upstream), `guangyucoder/symphony` (fork)

## Executive Summary

v1 提了"每个 stage 是同一 AgentRunner 的不同 invocation"的架构。中间版本累积了过多 defensive field/gate。本版回到核心：**4 个机器门 + BEGIN/END bounded marker + 3 个 marker kind**，其他交给 agent + WORKFLOW prompt。

核心意图不变:
1. 不分叉 upstream 代码
2. 自动享受 upstream 升级
3. 我们的增量可上游化

---

## 1. 背景

参见 v1 `stage-workflow-chain.md` §1（fork 43 commits ahead, ~2500 行 Elixir 增量, ~80% bug 来自自己机器层）。本文不重复。

---

## 2. 架构

### 2.1 核心 insight

**Stage = 同一 AgentRunner，不同 WORKFLOW 模板**。

### 2.2 模块架构

```
Upstream (不改):
  Orchestrator / AgentRunner / PromptBuilder / Workspace

Fork 新增:
  StageOrchestrator (~100 行)    # 按 workpad markers + Linear state 决定下一 stage
  StageCloseout (~80 行)         # 4 个机器门
  MarkerParser (~60 行)          # BEGIN/END 截取 + fenced block + YAML 解析

Workflow 文件:
  WORKFLOW.md          # upstream 版 + handoff 指令
  WORKFLOW-review.md   # 独立 review prompt (~80 行)
  WORKFLOW-docfix.md   # 独立 doc-fix prompt (~60 行)
```

### 2.3 三个 Stage

每个 Stage = 一次 `AgentRunner.run/3` 调用 with `max_turns: 1`。一次 Codex turn 内 agent 做完自己的事 (code/review/docs)，写 marker，停 turn。Session 结束后 closeout 跑 + orchestrator 下次 tick 根据 markers 决定 next stage。

- **Stage 1 Implement**: `WORKFLOW.md`。plan→code→test→push→写 `review-request` marker。大 ticket 可能一次 turn 做不完，orchestrator 看到 Linear=In Progress 且无 pending review → 下次 tick 再 dispatch implement (连续多 turn)
- **Stage 2 Review**: `WORKFLOW-review.md`。Reviewer 读 `git diff $(git merge-base HEAD origin/main)..HEAD`，按 consumer repo 提供的 review 协议审查正确性 / 安全 / 风格；diff 若触及 frontend 路径（`apps/web/**`, `apps/*/components/**` 等）则另外起 dev server 截图审视觉 → 写 `code-review` marker。不 commit
- **Stage 3 Doc Fix**: `WORKFLOW-docfix.md`。只改 `*.md` / `docs/**` → 写 `docs-checked` marker

为什么 `max_turns: 1`: upstream `AgentRunner.run/3` 的默认行为是一直 turn 直到 Linear 状态离开 active set。我们要在 marker 写完后切到下一 stage，最简单的做法是每次 dispatch 只跑一 turn，让 session 自然结束。Upstream 已支持 `max_turns` opt，不用额外 patch。

### 2.4 状态机

```elixir
def next_stage(workpad, linear_state, workspace) do
  cond do
    # Consumer 必须把 Rework 配进 tracker.active_states, 否则 upstream Orchestrator
    # 不会拉取 Rework ticket 派给 StageOrchestrator (见 orchestrator.ex / linear/client.ex
    # 按 active_states 过滤)。所以 StageOrchestrator 只在 Rework 在 active_states 时才会
    # 看到这个 state, 下面的短路是正确的。
    linear_state == "Rework" ->
      :implement

    # 所有非 active 状态直接 stop (active_states 见 Config.settings!().tracker.active_states)
    not active_issue_state?(linear_state) ->
      :stop

    # Review pending: current round 内, BEGIN/END 区最后一个 review-request / code-review
    # 是 review-request (按 workpad 文本顺序，最新 marker 就在 END 之前)
    review_pending?(workpad) ->
      :review

    # Latest code-review verdict=findings → Implement
    latest_code_review_verdict(workpad) == :findings ->
      :implement

    # Review clean 但 HEAD 已推进 → 重审
    latest_code_review_verdict(workpad) == :clean and
        latest_review_sha(workpad) != current_head(workspace) ->
      :review

    # Review clean + HEAD 匹配 + 未 doc_fix for this clean review → Doc Fix
    latest_code_review_verdict(workpad) == :clean and
        not docs_checked_matches_review?(workpad) ->
      :doc_fix

    # Review clean + docs-checked 绑定当前 clean review + HEAD 匹配 → handoff
    docs_checked_matches_review?(workpad) and
        latest_review_sha(workpad) == current_head(workspace) ->
      :implement

    # 其他 active 状态（Todo / In Progress / Merging 等）兜底走 implement。
    # 能走到这条一定是 active (上面 not active_issue_state? 已 :stop)。
    # Merging: WORKFLOW.md 里 agent 会检测到 Merging → 走 land skill。
    # Todo: agent 会把 state 移到 In Progress 再开始实现。
    # 由 WORKFLOW.md 决定具体行为，orchestrator 只需 dispatch implement。
    true ->
      :implement
  end
end
```

Helpers（都在 current_round 内计算，current_round = 最大 round_id 且非 archived）:
- `review_pending?`: BEGIN/END 区内当前 round 的 review-request / code-review marker 按**文本顺序**列出，最后一个是 review-request（初始时 code-review 不存在自然成立）
- `latest_code_review_verdict`: 当前 round 最新 code-review 的 verdict
- `latest_review_sha`: 最新 clean code-review 的 `reviewed_sha`
- `docs_checked_matches_review?`: 当前 round 有 docs-checked marker，且它的 `reviewed_sha` 等于 latest clean code-review 的 `reviewed_sha`（即 docs-checked 是针对当前最新 clean review 跑的，不是旧的 stale）。用共同字段 `reviewed_sha` 比对，不引入新字段

注意: agent 追加新 marker 时**必须**放在 BEGIN/END 区最后一个 marker 之后（END 之前），WORKFLOW 明确写出。这样文本顺序 == 时间顺序。

### 2.5 Marker 合约

#### 2.5.1 Bounded section

所有 marker 写在 workpad 的专属子区:

```
## Codex Workpad

<自由叙述: plan, notes, logs — orchestrator 不解析>

<!-- SYMPHONY-MARKERS-BEGIN -->
```symphony-marker
kind: review-request
round_id: 1
stage_round: 1
reviewed_sha: <40 hex>
issue_identifier: ENT-187
```
<!-- SYMPHONY-MARKERS-END -->
```

- Orchestrator 用 regex 先截 BEGIN/END 区，再找 fenced block
- 区外任何 ` ```symphony-marker ` 都不被解析（防碰撞）
- Agent 在 WORKFLOW.md 里被明确要求 marker 只能写在 BEGIN/END 之间

#### 2.5.2 Schema

3 种 `kind`，共享通用字段:

| 字段 | 类型 | 所有 kind |
|---|---|---|
| `kind` | `review-request` / `code-review` / `docs-checked` | 必填 |
| `round_id` | integer ≥ 1 | 必填，同一 review→doc_fix 链路共享。初始值: workpad 里从未有 marker（包括 archived）时 `round_id = 1`；否则 `round_id = max(所有 marker 的 round_id) + 1`（新 round 开启时）或 `= 当前 round id`（同 round 内追加）|
| `stage_round` | integer ≥ 1 | 必填，同 round_id 同 kind 重试 +1。**不同 kind 各自独立计数** —— `review-request.stage_round` 和 `code-review.stage_round` 不共享序号，也不需要对齐。e.g. 同 round_id=1 里可以有 review-request(stage_round=1) → code-review(stage_round=1, findings) → review-request(stage_round=2) → code-review(stage_round=2, clean)，两个 kind 各走到自己的 2 |
| `reviewed_sha` | 40-char hex | 必填，写 marker 时的 `git rev-parse HEAD` |
| `issue_identifier` | string | 必填，必须等于当前 ticket |

Per-kind 字段:

- **`review-request`**: 无
- **`code-review`**: `verdict: clean | findings`。`verdict: findings` 时可选加 `findings: [{severity: high|medium|low, summary: string}]`（作为 reviewer 给 implement 看的摘要，不参与 closeout 校验）
- **`docs-checked`**: `docfix_outcome: no-updates | updated`

#### 2.5.3 解析规则

- YAML 解析失败 / 缺通用必填字段 / `issue_identifier` 不匹配 → 该 block 无效
- Per-kind 必填字段缺失也视为 invalid: `code-review` 缺 `verdict` 无效；`docs-checked` 缺 `docfix_outcome` 无效。防止 agent 写漏 verdict 后 `latest_code_review_verdict` 返回 nil 让状态机误路由
- 解析单位 = BEGIN/END 区内的 raw valid markers 按**文本顺序**列出（agent 只能在区末尾追加新 marker，见 §2.5.1）。`latest_*` / `review_pending?` / `docs_checked_matches_review?` 都按文本顺序取最末的一条判断。不做 max-stage_round collapse
- Gate 3（findings→clean flip 检测，§2.6）同样看 raw 文本顺序的相邻 code-review marker 对
- 跨 `round_id` 的 marker 不参与当前状态机，仅用于 `round_id` bump
- **空 round 时** (新 ticket 第一次进来 / Rework 刚 archive 完还没写新 review-request): helpers 默认 `review_pending? = false`, `latest_code_review_verdict = nil`, `latest_review_sha = nil`, `docs_checked_matches_review? = false`。这样状态机会落到末尾 `true → :implement` 兜底 clause（Rework 由 §2.4 顶部的短路处理）

### 2.6 机器门

4 个，各自在对应 stage 结束时 closeout (非 "每 stage 都跑所有门"):

1. **`review_stage_clean?`** (Review stage only): Review stage 结束时，workspace 必须干净 — (a) `git rev-parse HEAD` 等于 dispatch 时 snapshot 的 SHA（reviewer 没 commit）且 (b) `git status --porcelain` 为空（没有 uncommitted 改动和 untracked 文件）。StageOrchestrator 在 dispatch `:review` 前存 HEAD snapshot 进 closeout context。任一条件不满足 → 拒绝 + 转 Rework
2. **`reviewed_sha matches head + working tree clean`** (Review + Doc-Fix stages): Marker 的 `reviewed_sha` 必须等于 closeout 时的 HEAD；同时 `git status --porcelain` 为空（无 uncommitted/untracked 文件）。防止 stage 结束时留脏 workspace 流到下一 stage
3. **`findings→clean flip at same HEAD rejected`** (Review stage only): 同一 HEAD 上 code-review 从 findings 翻 clean 拒绝。Agent 若要消 false-positive，必须让 HEAD 推进一次（即便是空格修改）
4. **`doc_fix only touched *.md / docs/**`** (Doc-Fix stage only): `git diff $(latest_review_sha(workpad))..HEAD --name-only` 的所有路径必须匹配 `*.md` 或 `docs/**`。Base 锚定 doc-fix 开始前的 clean review SHA（即 §2.4 helper `latest_review_sha`），不是 merge-base/origin/main，否则会把之前 implement 阶段的代码变更也算进 doc_fix 的 diff

Implement stage 结束不跑任何 gate — 实现的正确性靠 WORKFLOW.md + CI + 下一 Review stage 把关。

**所有 gate 失败的处理** (fix v15-H1): 统一 — StageCloseout 把 ticket 转 Rework，在 Linear workpad 追加一条自由叙述（区外）说明失败原因 (`gate_failed: <name>, reason: <detail>`)。Orchestrator 下一 tick 按 Rework 短路走 `:implement`，agent 执行 §3.4 reset 流程重新来过。

### 2.7 跟 Upstream 的接口

只需 upstream 改 `PromptBuilder` 看 `opts[:workflow_path]`。`AgentRunner.run/3` 已经支持 opts 透传 (`max_turns`, etc)，无需改动。

**改动范围**（基于 `rg` 审计 `elixir/lib/` + `elixir/test/` + `elixir/priv/` + `scripts/`）:

| 模块 | 改动 | ~行数 |
|---|---|---|
| `Workflow.load/1` 已存在 (upstream `workflow.ex:49`) — 无改动 | 按 path 读文件 + front matter 解析 | 0 |
| `AgentRunner.run/3` 已支持 opts 透传 (`max_turns`, 等) — 无改动 | — | 0 |
| `PromptBuilder.build_prompt/2` | 加 `opts[:workflow_path]` 分支（`Workflow.current()` → `Workflow.load(path)`）；当显式传入 path 时**不走** `default_prompt/1` fallback，body 空 → `raise` 防 silent 跑 default implement prompt | ~8 |
| `StageOrchestrator.dispatch/2` (fork 新增) | 按 stage 选 path，dispatch closeout HEAD snapshot | ~10 |
| Property test: 并发不同 stage 隔离 | 新增 | ~30 |
| **合计 non-test** | | **~18 行** |
| **合计含测试** | | **~48 行** |

关键保证:
- `Workflow.load/1` upstream 已实现（会解析 front matter）。Stage workflow 文件可以带 front matter，`load/1` 会照常解析；但 runtime config 仍由 `WorkflowStore.current()` 的 default workflow 决定 —— PromptBuilder 从 stage workflow 取 prompt body，`Config` 从 default workflow 取 config。这样 stage front matter 即便存在也不影响 runtime，符合"只影响 prompt 文本"的设计
- 若 stage workflow file 里的 front matter 声明了 Linear token 或其他全局字段，会在 `Workflow.load/1` 返回的 struct 里但被 PromptBuilder 忽略。对 reader 不造成 silent misconfig 印象（因为 `Config` 不从那读）
- `WorkflowStore` 仍只缓存 default `WORKFLOW.md`；stage-specific path 每次 dispatch 直接 `Workflow.load/1`，不进 Store

两条路径并行:
- **A** PR 给 upstream（~24 行 non-test）
- **B** Fork patch 同样内容，等 upstream 合并后 rebase 掉

---

## 3. Workflow 文件

### 3.1 `WORKFLOW.md` (Implement)

基本是 upstream 那份加几处:
- **加** Handoff 指令: "实现完成且 CI 绿后，不要直接移 Linear 到 Human Review。在 workpad BEGIN/END 区（最后一个 marker 之后）写 `review-request` marker，然后停 turn。"
- **加** Handoff 模式: "若当前 round 有 `docs-checked` marker 且 latest code-review verdict=clean + reviewed_sha==HEAD，可以移 Linear 到 Human Review"
- **加** Findings loop: "收到 review findings 后，新 commit 修完，再写一个更高 stage_round 的 review-request 请 reviewer 重看。**不要**在没有新 commit 的情况下请 reviewer 翻 clean"
- **加** doc_fix 后 code 改动: "如果 Stage 3 doc-fix 写完 `docs-checked` 之后你还要动代码，同一次改动里顺手更新相关 docs（inline）后，按 Findings loop 的规则在**同** `round_id` 下写新的 `review-request`（bump stage_round）。状态机看到 HEAD 已推进 + 新 review-request 会自动重走 review → docs-checked 路径"
- **加** 工作区洁净: "写 review-request 之前必须 `git status --porcelain` 为空（所有改动 commit 或丢弃）。留脏文件会让下一 stage closeout gate 误 fail，ticket 被错转 Rework"
- **加** Rework 指令（见 §3.4）

净变化 ~40 行。

### 3.2 `WORKFLOW-review.md`

~80 行。核心指令:

```markdown
你是 second-opinion reviewer。不要 commit、不要改源码、不要动 Linear state。

读 diff: `git diff $(git merge-base HEAD origin/main)..HEAD`。审查正确性、安全、错误处理、风格（consumer repo 自己提供具体 review 协议，例如放在 `.codex/skills/` 或 `.claude/skills/` 下的 review skill，或 AGENTS.md 里的 review checklist；Symphony 本身不规定具体协议）。
如果 diff 触及 frontend 路径（`apps/web/`、`apps/*/components/**`、`apps/*/app/**/*.tsx` 等），额外起 `pnpm --dir apps/web dev`，打开相关 route 截图审视觉（对照 PR 关联 ticket 描述的意图），审完 kill dev server。

把 verdict 写到 workpad BEGIN/END 区:

```symphony-marker
kind: code-review
round_id: <从 workpad 读最新 review-request 的 round_id>
stage_round: <同 round_id 下第几次 review, 从 1 开始>
reviewed_sha: <git rev-parse HEAD>
issue_identifier: <ticket ID>
verdict: clean | findings
findings:
  - severity: high
    summary: ...
```

停 turn。
```

### 3.3 `WORKFLOW-docfix.md`

~60 行。核心指令:

```markdown
你是 docs sweeper。只可以改 *.md / docs/**，其他路径会被 closeout 拒绝。

检查 AGENTS.md、docs/、README.md 是否跟当前 HEAD 的代码一致。

**顺序**:
- 如果不需要改: 直接写 `docs-checked` marker with `docfix_outcome: no-updates`, `reviewed_sha: <current HEAD>`
- 如果需要改: 先改、commit (message 前缀 `docs:`)、push，**然后** 写 marker with `docfix_outcome: updated`, `reviewed_sha: <post-commit git rev-parse HEAD>`

Marker 写在 workpad BEGIN/END 区最后一个 marker 之后:

```symphony-marker
kind: docs-checked
round_id: <同 review 的 round_id>
stage_round: <max(已有 docs-checked stage_round in 同 round_id) + 1; 首次=1>
reviewed_sha: <git rev-parse HEAD, 在所有 commit 之后>
issue_identifier: <ticket>
docfix_outcome: no-updates | updated
```

停 turn。
```

### 3.4 Rework

进入 Rework 时 (WORKFLOW.md 的 Rework 段指令):

1. 读 workpad，定位 BEGIN/END 区
2. 把区内所有 ` ```symphony-marker ` 改写成 ` ```symphony-marker-archived `（只改 fence 语言标识符）
3. 清 workspace: `git reset --hard HEAD && git clean -fdx`（丢掉上次 stage 遗留的 uncommitted / untracked 文件，否则 branch 切换可能失败或泄露到新 branch）
4. close 旧 PR，fresh branch，implement 新 plan
5. code + test + push
6. 在 BEGIN/END 区最后追加新 round 的 `review-request`，`round_id = max(archived) + 1`, `stage_round = 1`（**必须先写 marker 再移 Linear**；若 crash 在 6 和 7 之间，下一 tick 仍看到 Linear=Rework 走短路重入 implement，agent 看到 marker 已写只需做 step 7）
7. 把 Linear state 从 Rework 移回 In Progress，停 turn

Orchestrator 只认 `symphony-marker`，忽略 `symphony-marker-archived`。Rework 期间 orchestrator 看到 Linear=Rework 时命中顶部 Rework 短路 → dispatch `:implement`。Agent 按上述 7 步执行。若 agent 崩在中间（如步 2 完但步 6 未完），下一 tick 仍看到 Linear=Rework → 再 dispatch implement，WORKFLOW 指示 idempotent: 已 archive 的不再 archive，review-request 已写的不重写；agent 直接补完剩下步骤。一旦步 7 move 了 Linear state，Rework 短路不再触发，marker 路由接管（看到新 review-request → `:review`）。

---

## 4. 流程图

### 4.1 Happy path

```
Linear: In Progress
    │
    ▼
Stage 1: Implement (WORKFLOW.md)
    │   code + test + push
    │   write review-request (round_id=1, stage_round=1)
    ▼
Stage 2: Review (WORKFLOW-review.md)
    │   diff review per consumer protocol (+ visual check if frontend diff)
    │   write code-review verdict=clean (round_id=1, stage_round=1)
    │   closeout: review_stage_clean? ✓ (HEAD unchanged + working tree clean)
    ▼
Stage 3: Doc Fix (WORKFLOW-docfix.md)
    │   audit docs; no changes needed
    │   write docs-checked docfix_outcome=no-updates
    │   closeout: only docs paths changed (here: 0 changes) ✓
    ▼
Stage 1 (handoff mode):
    agent sees clean review + docs-checked + HEAD match
    → moves Linear to Human Review
    → orchestrator next_stage returns :stop
```

### 4.2 Findings loop

```
Stage 2 writes verdict=findings
    ▼
next_stage → :implement
    ▼
Stage 1: agent fixes, new commit, writes new review-request (round_id=1, stage_round=2)
    ▼
Stage 2: $code-review again, writes code-review (round_id=1, stage_round=2)
    ▼
verdict=clean → continues to §4.1
```

### 4.3 Rework

```
Human moves ticket → Rework
    ▼
next_stage (Rework 短路) → :implement
    ▼
Stage 1: agent 读 WORKFLOW.md Rework 段
    archive old markers
    close PR, fresh branch
    implement + test + push
    write review-request (round_id=max_archived+1, stage_round=1)  (先写 marker)
    move Linear → In Progress                                       (再移 state)
    ▼
next_stage 看到新 review-request + Linear=In Progress → :review
    ▼
走 §4.1 正常流程
```

### 4.4 Doc fix updated 后

```
Stage 3 docs-checked outcome=updated (新 commit 在 docs/, HEAD=new)
    ▼
next_stage:
  - review_pending? false (last review-request 被 code-review 应答)
  - latest_code_review_verdict = :clean, latest_review_sha = old-HEAD != new-HEAD
  → :review (clause 5)
    ▼
Stage 2: 重审 new HEAD, 写新 code-review (round_id=1, stage_round=2)
    verdict=clean + HEAD 匹配
    ▼
next_stage: docs_checked_matches_review? true + HEAD matches → :implement (handoff)
```

注意: WORKFLOW.md 里 Implement 指令加一句 "如果你在 doc_fix 之后还要动代码, 同一次改动里顺手更新相关 docs, 在**同** round_id 下写新的 review-request（bump stage_round）"。状态机看到 HEAD 已推进会自动重走 review → docs-checked 路径。不需要 Stage 3 有多轮计数器。

---

## 5. 迁移路径

### Phase 0: 准备
- [ ] 同步 upstream: `git merge upstream/main`
- [ ] 所有测试绿

### Phase 1: 上游接口
- [ ] PR upstream: `workflow_path` option（~24 行 non-test）
- [ ] Fork patch 同步（不等合并）

### Phase 2: 新增 stage 层
- [ ] `StageOrchestrator` (~100 行)
- [ ] `StageCloseout` 4 个门 (~80 行)
- [ ] `MarkerParser` BEGIN/END + YAML (~60 行)
- [ ] 3 份 WORKFLOW 文件

### Phase 3: 砍掉旧机器层
- [ ] 删除 `DispatchResolver` (457 行)
- [ ] 删除 `Closeout` 大部分 (~700 行)
- [ ] 删除 `unit-lite` mode 和所有 unit kind (~600 行)
- [ ] 删除 `WorkpadParser` 大部分 (~450 行)
- [ ] 删除 `issue_exec.json` 的 warm-session / unit state 字段
- [ ] 删除对应 tests (~3000 行)

### Phase 4: 验证
- [ ] 所有测试绿
- [ ] 端到端 smoke test: happy path + findings loop + rework
- [ ] Tag `v1-baseline` before Phase 3，允许 rollback cherry-pick

### 工作量
2-3 天。

---

## 6. Trade-offs

### 6.1 Cold boundary between stages
每 stage 是 fresh Codex session，跨 stage context 丢失。**Mitigation**: workpad 是 persistent context（upstream pattern）；cold boundary 有价值（review agent 无 implementer 偏见）。**Cost**: 每 stage 一次 codex boot ~几秒。

### 6.2 Findings→clean 同 HEAD 拒绝
Reviewer 报 false-positive 时，implement 必须让 HEAD 推进（空格改动也行）才能翻 clean。简单合约胜过可辨 dismiss 机制。

### 6.3 Stage workflow files 无 config
stage files 只有 prompt body。不支持 stage-specific `max_turns` / `sandbox`。如需，future 单独 PR 扩展。

### 6.4 Verify / CI / Merge
Upstream WORKFLOW.md 里 agent self-check + `land` skill 已处理。删掉我们的 `verify` / `merge-sync-*` unit 不损失。

### 6.5 Rework 的脆弱性
Agent 如果漏掉 archive 步或漏写新 review-request，下一 orchestrator tick 仍看到 Linear=Rework 继续 dispatch implement。WORKFLOW Rework 段要求 idempotent（archive 已 archived 的是 no-op；已存在新 review-request 则跳过），让 retry 安全。若 agent 反复失败（如 3 次连续 Rework tick 但 linear state 未变回 In Progress），orchestrator 可以记 Linear comment 提醒人工。这个 counter 若要加，可以放在 orchestrator 的 GenServer state，但当前简化版不 implement — 先观察真实发生频率再决定。

---

## 7. 对比总结

```
                        当前 fork    本提案       上游 baseline
─────────────────────────────────────────────────────────────
新增 Elixir             ~2500 行    ~240 行      0
新增 Markdown           ~500 行     ~200 行      0
Upstream 代码改动       ~1500 行    ~24 行       0
新增测试                ~4600 行    ~800 行      0
─────────────────────────────────────────────────────────────
Marker kinds            — (implicit) 3           —
Closeout gates          10+         4            —
Upstream 升级冲突        严重        极低         —
可 PR 回上游            否          是           —
```

---

## 8. 请 reviewer 看的点

1. §2.4 状态机 8 个 clause 能否覆盖所有 happy / findings / rework / docfix-updated 路径
2. §2.5.2 3 个 marker kind 的字段是否够；有没有真实 edge case 需要额外字段
3. §2.6 4 个 gate 是否够；哪些可以删
4. §2.7 patch size 估算（~24 行 non-test）是否合理
5. §3.4 Rework 流程是否足够 robust

---

## 9. 为什么不用 Codex Hooks

2026-04 研究：`codex_hooks` feature flag 仍 experimental；仅 `command` handler 支持（无 Prompt/Agent）；Stop hook 的 `decision:"block"` 只注入 continuation prompt，实际不 block；PreToolUse/PostToolUse 只 fire Bash。

结论: 当前 risk/reward 不划算。orchestrator 读 marker + 派下一 AgentRunner 是 Elixir level 可观测 + 可测试，比 hook side-effect 更清晰。Hooks 成熟后再评估。

---

## Appendix

v1 原始 design doc: `stage-workflow-chain.md` (保留供对照)
Upstream 关键文件: `agent_runner.ex` (203 行), `prompt_builder.ex` (64 行), `WORKFLOW.md` (327 行)

---

*End of design doc.*
