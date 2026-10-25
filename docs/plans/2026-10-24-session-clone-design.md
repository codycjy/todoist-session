# Session 番茄钟复刻 — 阶段一设计文档

- 日期：2026-10-24
- 范围：阶段一 = 后端 + macOS 客户端
- 定位：自用工具，数据模型按多用户设计（所有表带 `user_id`）

## 1. 目标与范围

### 1.1 核心价值

1. **Todoist 任务一键开始专注**：今日/过期任务直接点击开始番茄钟。
2. **自定义条目快速开始**：不依赖 Todoist，输入标题 + 选择分类即可开始。
3. **LLM 专注评估**：基于专注期间采集的活动元数据（App / 窗口标题 / URL），由 LLM 事后评估专注度。
4. **硬拦截黑名单**：专注期间强制拦截黑名单 App 与网站。
5. **今日时间轴**：直观呈现当天所有专注块及其评估结果。

### 1.2 阶段一包含

- Todoist 任务列表（只读）→ 点击开始
- 自定义条目（标题 + 分类）→ 点击开始；最近使用的自定义条目可复用
- 计时：专注 / 可选休息（短休、长休），时长可配置；菜单栏倒计时；全局快捷键
- 专注期间：活动元数据采集、闲置识别、App/网站硬拦截
- 专注结束后：异步 LLM 评估
- 今日页（任务列表 + 时间轴）、统计页、设置页
- 后端：数据同步、Todoist 代理、LLM 评估服务

### 1.3 阶段一不做（YAGNI）

iOS / Web 端、屏幕截图、专注中实时 LLM 判断、日/周 LLM 汇总、回写 Todoist（完成任务 / 评论）、OAuth、Todoist Webhook、WebSocket 推送、按分类区分黑名单、严格模式、自评打分/复盘页。

### 1.4 关键产品决策

| 决策 | 结论 | 理由 |
|---|---|---|
| Todoist 集成深度 | 只读 | 重复任务 ID 不变，回写评论会在同一任务下无限堆积；专注记录存在自己的后端，按 `todoist_task_id` 关联 |
| Todoist 认证 | Personal API Token | 自用无需 OAuth；数据模型预留扩展 |
| 屏幕采集 | 仅元数据，无截图 | 覆盖大部分判断场景，成本约为截图的 1%，隐私风险低；架构保留截图扩展点 |
| LLM 介入时机 | 仅事后评估 | 实时调用有延迟、成本与误报干扰；每个番茄一次调用 |
| 走神处理 | 硬拦截黑名单 | 对齐 Session，不依赖 LLM |
| 开始方式 | 只能手动点击开始 | 永不自动开始下一个专注 |
| 专注完成 | 直接结束（默认），可选进入休息 | 无复盘页、无自评 |
| 放弃专注 | 直接丢弃记录 | 不要求理由，不计入统计，不产生负面影响；本地数据一并删除且不上传 |
| 闲置时间 | 识别并标记 | 只影响 activity 统计与 LLM 评估输入，不暂停计时、不影响 session 时长 |

## 2. 技术栈

| 层 | 选型 |
|---|---|
| Mac 客户端 | Swift + SwiftUI，macOS 14+，`MenuBarExtra`，本地 SQLite（GRDB） |
| 后端运行时 | Node 20.18.1+（`@doist/todoist-sdk` 要求） |
| Web 框架 | Hono |
| ORM / DB | Drizzle ORM + SQLite（`better-sqlite3`，WAL 模式） |
| Todoist | 官方 `@doist/todoist-sdk`，Todoist API v1（REST v2 / Sync v9 已废弃） |
| LLM | Anthropic SDK，默认 `claude-haiku-5-5`，模型与 prompt 可配置 |
| 部署 | 阶段一本机 Docker Compose（单容器 + volume）；以后可平滑迁到 VPS（SQLite + Litestream 备份） |

注意：Drizzle 的 schema 按方言区分（`sqliteTable` / `pgTable`）。以后如果迁到 PostgreSQL，需要重写 schema 文件，查询代码基本不变。

## 3. 架构

```
┌──────────── Mac App (SwiftUI, macOS 14+) ─────────────┐
│ MenuBarExtra │ 主窗口(今日 / 统计 / 设置)                │
│ TimerEngine  │ ActivityTracker(NSWorkspace+AX+AppleScript+Idle)
│ Blocker(App 隐藏 / Tab 重定向)                           │
│ LocalStore (SQLite/GRDB) ── SyncClient (outbox 队列)   │
└───────────────────────────┬───────────────────────────┘
                            │ HTTP/JSON, Bearer token
┌──────── Backend (Node 20 + Hono + Drizzle) ───────────┐
│ /sync     sessions + activity 批量上传（幂等）          │
│ /todoist  代理拉取任务与项目（Token 只存后端）            │
│ eval worker  时间线 → Claude → 评分与摘要               │
└───────────────────────────┬───────────────────────────┘
                     SQLite │ ── Todoist API v1 / Anthropic API
```

原则：

- **本地优先**：计时、采集、拦截完全不依赖后端。session 先写本地 SQLite，再通过 outbox 异步上传。
- **密钥只在后端**：Todoist Token 和 Anthropic Key 都存在后端；Mac 端只保存后端 API token（Keychain）。
- **离线可用**：Todoist 任务列表缓存在本地；后端不可用时，可以从缓存任务或自定义条目开始专注。

## 4. 数据模型

后端与 Mac 本地使用基本一致的 SQLite 表结构。JSON 字段用 `text({ mode: 'json' })`，时间戳与布尔值存 integer。

```
users          id, name, api_token_hash, todoist_token_enc,
               settings(json), created_at

categories     id, user_id, todoist_project_id(nullable, unique per user),
               name, color, archived

entries        id, user_id, title, category_id, last_used_at
               -- 自定义条目，便于复用；不来自 Todoist

sessions       id(UUID, 客户端生成), user_id, category_id,
               source(todoist|custom),
               todoist_task_id(nullable), entry_id(nullable),
               title_snapshot,
               planned_seconds, actual_seconds,
               started_at, ended_at, status(completed)

breaks         id, user_id, session_id(nullable), kind(short|long),
               started_at, ended_at

activity_spans id, session_id, kind(active|idle),
               app_bundle_id, app_name, window_title,
               url_host, url_path(nullable),
               started_at, ended_at, was_blocked(bool)

evaluations    session_id(PK), status(pending|done|failed), attempts,
               focus_score(0-100), summary, distractions(json),
               model, prompt_version, created_at
```

设计要点：

- **客户端生成 UUID**：离线也能创建 session；上传时 `ON CONFLICT DO NOTHING`，保证幂等。
- **只存已完成的 session**：放弃的 session 在本地直接删除，永不上传。
- **activity 按时间段存储**：前台 App / 标题 / host 不变时延长当前 span；原始采样点不保留。
- **标题快照**：`title_snapshot` 记录开始时的标题。Todoist 任务改名或删除不影响历史；重复任务每次都是独立的 session。
- **分类映射**：首次遇到某个 Todoist 项目时，自动创建对应 category；自定义条目使用用户自建的 category。
- **URL 隐私**：默认只存 host，`url_path` 采集在设置中开启。
- **evaluations 独立成表**：支持失败重试，换 `prompt_version` 后可重新评估历史 session。

## 5. Mac 客户端

### 5.1 TimerEngine 状态机

```
idle ─点击任务/条目→ focusing ─到点→ 完成(保存) ─┬→ idle（默认）
                       │                      └→ breaking ─到点→ idle
                       └─放弃→ 丢弃全部记录 → idle
```

- 计时以结束时间戳为准（`endAt = startAt + duration`），不靠累计 tick；睡眠、卡顿都不会导致漂移。
- 状态持久化到本地；崩溃重启后恢复进行中的 session，如果已过结束时间，按到点完成处理。
- 到点后发通知，提供"开始休息"/"结束"两个选项，默认结束。连续 4 个专注后，建议的休息类型为长休。
- 只能手动开始，休息结束后不会自动开始下一个专注。

### 5.2 开始专注的两种入口

1. **Todoist 任务**：今日页左侧列出今日 + 过期任务，点击 ▶ 开始。分类取自项目映射。
2. **自定义条目**：输入框里填标题 + 选分类 → 开始。条目保存到 `entries`，下次出现在"最近使用"中，可一键复用。

### 5.3 ActivityTracker（仅在 focusing 状态运行）

- `NSWorkspace.didActivateApplicationNotification` 监听前台 App 切换。
- 每 2 秒轮询：用 Accessibility API（`AXFocusedWindow` → `AXTitle`）读窗口标题；前台是浏览器时，用 AppleScript 读当前标签页 URL（Safari / Chrome / Arc / Edge）。
- SpanBuilder 把采样点合并为时间段。
- **闲置识别**：用 `CGEventSource.secondsSinceLastEventType(.combinedSessionState, .any)` 检测无键鼠输入的时长，超过阈值（默认 120 秒，可配置）就关闭当前 active span，开一个 `kind=idle` 的 span；有输入后恢复。闲置期间不读标题/URL。
  - 闲置**不暂停计时**，也不影响 session 的 `actual_seconds`。
  - 闲置**只影响**：activity 统计（活跃/闲置占比）与 LLM 评估输入（时间线中标注 `IDLE`）。
  - 已知局限：看视频、阅读长文时可能被误判为闲置。prompt 中会说明，由 LLM 结合上下文判断。

### 5.4 Blocker

- **App**：黑名单 App 被激活时 `hide()`，并显示浮层"正在专注：{标题}，剩余 mm:ss"。
- **网站**：复用 URL 采集；命中黑名单域名时，用 AppleScript 把当前标签页重定向到本地拦截页。Firefox 不支持；页面可能先闪现一下。
- 黑名单全局一份，被拦截的 span 标记 `was_blocked=true`。

### 5.5 权限引导（首次启动）

辅助功能 → 各浏览器的自动化权限 → 通知。缺少权限时降级（只按 App 粒度采集和拦截），并在设置页标红提示。

### 5.6 UI

- **菜单栏**：剩余时间 + 当前标题；点开是小面板（开始 / 暂停 / 放弃、今日任务、快速输入自定义条目）。
- **主窗口** tab：
  - **今日**（默认）：左边 Todoist 任务 + 自定义条目输入/最近使用；右边纵向时间轴。每个 session 是一个色块（颜色跟随分类），显示 LLM 分数（评估中显示 `…`，失败显示 `—`）。点击色块展开 LLM 总结、偏离片段、activity 明细（被拦截的标红，闲置段为灰色）。进行中的 session 实时延伸。可以切换日期查看历史。
  - **统计**：每日/每周专注时长、按分类分布、专注度趋势、活跃/闲置占比。
  - **设置**：时长、黑名单、闲置阈值、URL path 采集开关、后端地址与 Token、重新评估。

```
┌─ 今日 ─────────────────────────┬─ 时间轴 ──────────────────┐
│ [ 标题…        ][分类▾][▶ 开始] │ 09:00 ┃                    │
│ 最近：读论文 · 健身计划          │ 09:30 ┃█ 写周报 25m  82分   │
│ ── Todoist 今日 / 过期 ──       │       ┃░ 休息 5m           │
│ ▸ 写周报        [▶]             │ 10:00 ┃█ Code review 25m …  │
│ ▸ 每日英语      [▶]             │ 10:30 ┃                    │
│ 今日：3 个番茄 · 75 分钟         │ 11:00 ┃ ← 现在              │
└────────────────────────────────┴───────────────────────────┘
```

### 5.7 数据流

```
Todoist 任务 ←(GET /todoist/tasks，本地缓存)   或   自定义条目
  → 点击开始 → focusing（采集 + 闲置识别 + 拦截）
  → 到点 → 保存到本地 → outbox
  → SyncClient 批量 POST /sync/sessions → 后端创建 pending evaluation
  → 今日页拉取 / 轮询 → 显示评估结果
```

## 6. 后端

### 6.1 API（全部需要 `Authorization: Bearer <api_token>`）

```
GET  /todoist/tasks?filter=today|overdue   代理 Todoist API v1，返回精简字段
GET  /todoist/projects                     同步项目，并 upsert 到 categories
GET  /categories   POST /categories        分类管理
GET  /entries                              最近使用的自定义条目
POST /sync/sessions                        批量上传 session + spans（含 entries，幂等）
GET  /sessions?date=YYYY-MM-DD             今日时间轴数据（含 evaluation）
GET  /stats?range=day|week                 统计聚合
GET/PUT /settings                          黑名单、时长、闲置阈值等
POST /evaluations/:sessionId/retry         重新评估
```

### 6.2 Todoist 代理

- 内存缓存 60 秒，避免触发限流。
- 只返回需要的字段：`id, content, project_id, due, priority, is_recurring`。
- Token 失效时返回 `401 TODOIST_AUTH`，Mac 端提示去设置里重新填写。

### 6.3 LLM 评估流水线

- `/sync` 收到已完成的 session 后，插入 `pending` evaluation。
- 进程内 worker 每 10 秒扫描 pending，最多重试 3 次，之后标记 `failed`。不引入队列中间件。
- Prompt 输入：标题、分类/项目名、计划时长、压缩后的 activity 时间线：

  ```
  [00:00-08:12] VS Code — "weekly-report.md"
  [08:12-09:40] Chrome — github.com
  [09:40-11:02] Chrome — youtube.com (BLOCKED)
  [11:02-14:30] IDLE
  ```

- 用 tool use 强制结构化输出：`{ focus_score, summary, distractions: [{start, end, reason}] }`。
- 默认模型 `claude-haiku-5-5`；模型名与 `prompt_version` 可配置。
- 回传：今日页打开时拉取一次；存在 pending 时每 15 秒轮询，直到全部出结果。

## 7. 错误处理与降级

| 场景 | 处理 |
|---|---|
| 后端不可达 | 计时、采集、拦截照常；outbox 指数退避重试；今日页显示"未同步"标记 |
| Todoist 不可用 | 使用本地缓存任务；自定义条目始终可用 |
| LLM 失败 | 重试 3 次后标记 `failed`，色块显示 `—`，可手动重新评估 |
| 缺少辅助功能 / 自动化权限 | 降级为 App 粒度采集和拦截，设置页提示 |
| 崩溃 / 强制退出 | 重启后恢复进行中的 session；已过结束时间则按完成处理 |
| 睡眠 / 合盖 | 以时间戳为准；睡眠期间记为 idle span |

## 8. 测试策略

- **后端（Vitest）**：sync 幂等性、stats 聚合（含 idle 占比）、prompt 构造与输出解析（LLM mock）、Todoist 客户端（录制的 fixture）。
- **Mac（XCTest）**：TimerEngine 注入可控时钟，测状态机 / 漂移 / 崩溃恢复；SpanBuilder 测采样点合并与闲置切分；Blocker 测匹配规则（纯函数）。
- **端到端**：本地 Docker 起后端，手动跑主流程。阶段一不做 UI 自动化。

## 9. 仓库结构

```
todo-session/
├─ backend/        Node 20 + Hono + Drizzle + better-sqlite3
│  ├─ src/{routes,todoist,eval,db}
│  └─ Dockerfile, docker-compose.yml
├─ mac/            Xcode 工程 (SwiftUI, macOS 14+, GRDB)
│  └─ Sources/{Timer,Tracker,Blocker,Store,Sync,UI}
└─ docs/plans/
```

## 10. 里程碑

1. **M1**：后端骨架 + SQLite + Todoist 代理；Mac 菜单栏计时器 + 今日任务列表 + 自定义条目，能点击开始专注。
2. **M2**：ActivityTracker（含闲置识别）+ Blocker + 本地存储 + sync。
3. **M3**：LLM 评估 + 今日时间轴。
4. **M4**：统计页 + 设置页 + 权限引导 + 降级打磨。

## 11. 后续阶段扩展点

- 截图 + 视觉模型（元数据判断不了时才截图，本地先 OCR）
- 专注中实时 LLM 判断、日/周 LLM 汇总
- 可选的"完成 Todoist 任务"按钮
- iOS / Web 端、OAuth、Todoist Webhook、云端部署
