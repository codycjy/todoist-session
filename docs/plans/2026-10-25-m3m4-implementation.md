# M3 + M4 Implementation Plan

**Goal:** 完成阶段一剩余部分：LLM 评估（M3）、统计页 / 设置页 / 权限引导 / 打包（M4）。

**Architecture:** 后端新增 `evaluations` 表、进程内 worker（10s 扫描 pending，最多 3 次）、`GET /sessions`、`POST /evaluations/:id/retry`、`GET /stats`、`GET/PUT /settings`。Mac 端新增评估展示与轮询、统计页（Swift Charts）、设置页（黑名单 / 时长 / 后端 / 权限）、`.app` 打包脚本。

**Tech Stack:** Hono + Drizzle + zod（后端）；`@anthropic-ai/sdk`（tool use 结构化输出）；SwiftUI + Charts + GRDB（Mac）。

---

## 0. 与设计文档的取舍（已定，不再讨论）

| 项 | 取舍 | 原因 |
|---|---|---|
| `breaks` 表 | **不做** | 没有任何功能读它（无复盘页），YAGNI |
| URL path 采集开关 | **不做** | 采样器目前只取 host；本阶段保持隐私默认，不扩大采集 |
| `GET /sessions?date=` | 改为 `?from=<ms>&to=<ms>` | 客户端按本地时区算边界，避免后端处理时区 |
| 进行中 session 在时间轴实时延伸 | **不做** | 价值低，已有倒计时 |
| 通知权限 | 仅 `.app` 形态下请求；session 结束发本地通知 | `swift run` 无 bundle，通知 API 会崩 |
| LLM Key | 后端环境变量 `ANTHROPIC_API_KEY`，**缺失时 worker 不启动**，评估保持 pending，启动日志提示一次 | 用户自己配置，任何代码/测试/日志不得出现真实 key |

安全约束（沿用）：子任务只用假 token / 内存或临时 DB；LLM 测试一律 mock，不得发真实请求；不要求也不打印真实 token；只用显式路径 `git add <paths>`；提交信息以 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` 结尾。

## 1. API 契约（后端与 Mac 共同遵守）

时间戳全部是毫秒整数。全部需要 `Authorization: Bearer`。

### 1.1 `evaluations` 表
`session_id`(PK, FK sessions) · `user_id` · `status` pending|done|failed · `attempts` int · `focus_score` int null · `summary` text null · `distractions` json（`[{start:ms,end:ms,reason:string}]`）· `model` text · `prompt_version` text · `last_error` text null（只存错误类别，不存响应体/Key）· `created_at` · `updated_at`。迁移用 drizzle-kit 生成，**新增迁移文件，不改旧的**。

### 1.2 `POST /sync/sessions`（已有）
新 session 被接受时在同一事务内插入 `pending` evaluation。重复上传不改已有 evaluation。

### 1.3 `GET /sessions?from=&to=`
`from`/`to` 必须是整数且 `to > from`，区间 ≤ 92 天，否则 `400 {error:'BAD_REQUEST'}`。返回按 `startedAt` 升序：
```json
{"sessions":[{"id":"…","categoryId":null,"source":"todoist","todoistTaskId":"…","entryId":null,
 "title":"…","plannedSeconds":1500,"actualSeconds":1500,"startedAt":0,"endedAt":0,
 "evaluation":null | {"status":"pending|done|failed","focusScore":82,"summary":"…",
   "distractions":[{"start":0,"end":0,"reason":"…"}],"attempts":1}}]}
```
只返回当前用户的 session。`pending/failed` 时 `focusScore/summary` 为 null、`distractions` 为 `[]`。

### 1.4 `POST /evaluations/:sessionId/retry`
非本人或不存在 → 404。否则重置为 `pending`、`attempts=0`、清 `last_error`，返回 `202 {status:'pending'}`。

### 1.5 `GET /stats?from=&to=&tzOffsetMinutes=`
`tzOffsetMinutes` 为客户端 `TimeZone.secondsFromGMT/60`（东八区 = 480），默认 0，范围 ±840。校验同 1.3。
```json
{"totalFocusSeconds":0,"sessionCount":0,"avgFocusScore":null,
 "activeSeconds":0,"idleSeconds":0,
 "days":[{"date":"2026-10-25","focusSeconds":0,"sessionCount":0,"avgFocusScore":null}],
 "byCategory":[{"categoryId":null,"focusSeconds":0}]}
```
`days` 按客户端时区逐日补齐（无 session 的日子为 0 / null）；`avgFocusScore` 只统计 `done` 的评估，四舍五入取整；`activeSeconds/idleSeconds` 由 `activity_spans` 按 `kind` 汇总时长；`byCategory` 按秒数降序，`categoryId` 可为 null（无分类）。

### 1.6 `GET /settings` / `PUT /settings`
```json
{"focusSeconds":1500,"idleThresholdSeconds":120,"blockApps":["com.tencent.xinWeChat"],"blockDomains":["youtube.com"]}
```
存于 `users.settings`（json）。GET 缺省值如上。PUT 接受**部分**字段并合并，zod 校验：`focusSeconds` 60–7200，`idleThresholdSeconds` 30–1800，数组 ≤ 200 项、每项非空且 ≤ 200 字符；`blockDomains` 保存时转小写去重去首尾空白。未知字段忽略。返回合并后的完整对象。

### 1.7 评估 worker 与 prompt
- 配置：`ANTHROPIC_API_KEY`（必需才启用）、`EVAL_MODEL`（默认 `claude-haiku-5-5`）、`EVAL_PROMPT_VERSION`（默认 `v1`）。
- 每 10 秒领取至多 5 个 `pending` 且 `attempts < 3` 的 evaluation，顺序处理（不并发，避免限流）。同一个 evaluation 不得被重复领取（进程内用 in-flight 集合 + 状态检查）。
- 成功 → `done` + 结果；失败 → `attempts+1`，`attempts >= 3` 标 `failed`，否则仍 `pending` 等下一轮。`last_error` 只存类别（如 `API_ERROR` / `BAD_OUTPUT` / `TIMEOUT`）。
- Prompt 输入：标题、分类名、计划时长、实际时长、压缩后的 activity 时间线（格式见设计文档 §6.3，时间用相对 `mm:ss`，`was_blocked` 标 `(BLOCKED)`，idle 标 `IDLE`；窗口标题截断到 120 字符；span 超过 200 条时合并相邻同 App 的 span 后再截断）。
- 用 tool use 强制结构化输出：`{focus_score:int 0-100, summary:string≤200字, distractions:[{start_sec,end_sec,reason}]}`；解析后 clamp 分数、丢弃越界的 distraction，把相对秒换算回绝对毫秒。无法解析 → `BAD_OUTPUT`。
- 评估器抽象为接口 `Evaluator { evaluate(input): Promise<EvalResult> }`，worker 与 Anthropic 实现解耦；测试只用 fake。

## 2. 任务

### Backend（B1–B4，按顺序，由一个子任务批次完成）

- **B1 schema + 迁移 + sync 创建 pending**：加 `evaluations` 表，生成新迁移；`routes/sync.ts` 在新 session 事务内插入 pending；补测试（新 session 有 pending、重复上传不重置、他人 session 冲突不建）。
- **B2 评估内核**：`src/eval/{prompt,parse,worker,anthropic}.ts`。`prompt.ts` 纯函数（含截断/合并，测试覆盖边界）；`parse.ts` 纯函数（clamp、越界丢弃、`BAD_OUTPUT`）；`worker.ts` 用注入的 `Evaluator` 与 `now`，提供 `runOnce()` 供测试直接调用（不依赖 setInterval）；`anthropic.ts` 用 `@anthropic-ai/sdk` 的 tool use 实现 `Evaluator`（先用 context7 查当前 SDK 用法；测试不得触网）。`index.ts` 在有 `ANTHROPIC_API_KEY` 时启动定时器，否则打印一次提示；退出时清理定时器。
- **B3 读取路由**：`routes/sessions.ts`（1.3 + 1.4）、`routes/stats.ts`（1.5）。测试覆盖：他人隔离、区间校验、`days` 补零与时区边界（东八区跨午夜的 session 落在正确的日子）、`avgFocusScore` 只算 done、idle/active 汇总、`byCategory` 排序与 null 分类。
- **B4 settings 路由**：`routes/settings.ts`（1.6）。测试覆盖缺省值、部分合并、校验失败 400、域名规范化、他人隔离。
- 收尾：`.env.example` 增加 `ANTHROPIC_API_KEY` / `EVAL_MODEL` / `EVAL_PROMPT_VERSION` 说明；`npm test` 与 `npx tsc --noEmit` 全绿。

### Mac（M-A、M-B、M-C，后端完成后进行）

- **M-A API + 评估展示（M3）**：`SessionCore/API` 增加 `sessions(from:to:)`、`retryEvaluation(id:)`、`stats(...)`、`settings()`/`updateSettings(_:)` 与对应 Codable 模型（测试用 `URLProtocol` 假响应）。`AppModel` 持有 `evaluations: [String: Evaluation]`：今日页出现与同步完成后各拉取一次；存在 `pending` 时每 15 秒轮询，全部终态后停止。时间轴色块显示分数（pending `…`、failed `—`、done 数字）；点开详情顶部显示 summary、偏离片段列表（时间 + reason），`failed` 时有“重新评估”按钮。未配置后端或离线时静默降级（不显示错误条）。
- **M-B 设置 + 权限（M4）**：主窗口改为 `TabView`（今日 / 统计 / 设置）。`SettingsStore`（Core，可测）把设置落 UserDefaults，并与后端 `/settings` 同步：启动时拉取，修改后 1 秒防抖 PUT，失败保留本地并在设置页标注“未同步”。生效规则：环境变量（开发覆盖）> 设置页 > 默认值。设置页：专注时长、闲置阈值、黑名单 App（输入 bundle id，另有“从正在运行的 App 添加”菜单）、黑名单域名、后端地址与 API Token（Token 存 Keychain，`KeychainStore` 封装 SecItem；环境变量仍可覆盖）、权限状态区（辅助功能 / 自动化 / 通知：显示已授权或缺失，缺失时标红并带“打开系统设置”按钮，用 `x-apple.systempreferences:` URL；自动化权限只能在首次实际控制浏览器时由系统弹窗，页面上说明这点）。首次启动（UserDefaults 标记）弹出一次权限引导 sheet。黑名单与时长变更要对**下一个** session 生效，进行中的不改。
- **M-C 统计页 + 打包（M4）**：统计页：范围切换（今日 / 本周 / 最近 30 天）；顶部指标（总专注时长、番茄数、平均专注度）；每日专注时长柱状图；按分类分布（颜色用分类色）；专注度趋势折线（无评估的日子断开）；活跃 / 闲置占比。后端不可达时显示占位文案，不崩溃。打包：`mac/scripts/build-app.sh`（`swift build -c release`，组装 `Session.app/Contents/{MacOS,Resources,Info.plist}`，`Info.plist` 含 `CFBundleIdentifier`、`LSMinimumSystemVersion 14.0`、`NSAppleEventsUsageDescription`、`NSUserNotificationsUsageDescription`，`codesign --force --sign "${SIGN_IDENTITY:--}"`；脚本末尾 `plutil -lint` 与 `codesign --verify`）。README 说明：ad-hoc 签名每次重编译后系统可能重新询问权限，想稳定请用自签证书并设置 `SIGN_IDENTITY`。session 结束时在 `.app` 形态下发本地通知（`Bundle.main.bundleIdentifier != nil` 才调用）。

### 收尾（我执行）
全量测试 → 整分支代码审查 → 更新 `docs/plans/2026-10-25-m3m4-verification.md`（含需要用户真机验证的清单）→ 与用户确认后合并。

## 3. 需要用户真机验证（计划）
1. 配置 `ANTHROPIC_API_KEY` 后完成一个 session，色块从 `…` 变为分数，详情有总结与偏离片段；故意让 key 无效，确认 3 次后显示 `—` 且可重新评估。
2. 设置页修改黑名单 / 时长 → 后端重启后仍在 → 下个 session 生效。
3. 统计页各图表与数字和今日页一致；切换范围正常。
4. `build-app.sh` 产出的 `Session.app` 能启动，权限引导出现，授权后拦截与采集可用，session 结束有系统通知。
