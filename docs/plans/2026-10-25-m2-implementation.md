# M2 Implementation Plan：活动采集 + 拦截 + 本地存储 + 同步

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans（或 subagent-driven-development）to implement this plan task-by-task.

**Goal:** 专注期间采集前台 App / 窗口标题 / 浏览器 host / 闲置状态，按黑名单拦截 App 与网站；已完成的专注（含活动 span）先写本地 SQLite，再通过 outbox 幂等上传到后端；Today 页出现只含专注块的简化时间轴。

**Architecture:** 纯逻辑（SpanBuilder、BlockList、LocalStore、SyncService、ActivityTracker）放 `SessionCore`，用协议注入采样器与时钟，XCTest 全覆盖；依赖系统 API 的部分（AX 窗口标题、AppleScript 读/改浏览器 URL、NSWorkspace、CGEventSource 闲置、隐藏 App、浮层）放 `SessionApp`，靠手动验证。后端只加 `sessions` + `activity_spans` 两张表和 `POST /sync/sessions`。

**Tech Stack:** Swift 6.1（Swift 5 语言模式）、SwiftUI、GRDB 7、XCTest；Node 22 + Hono + Drizzle + zod + Vitest。

**前置：** M1 已完成（分支 `feature/phase1-m1`，后端 26 测试、Mac 29 测试通过）。M2 在同一 worktree 继续，或 M1 合并后从 `main` 新建 `feature/phase1-m2`。

---

## 0. 设计取舍（与设计文档的差异先说清）

| 项 | 设计文档 | M2 做法 | 原因 |
|---|---|---|---|
| `breaks` 表 | M2 同步 | **延后到 M3** | M2 时间轴只画专注块，没有消费者（YAGNI） |
| `GET /sessions` | 6.1 列出 | **延后到 M3** | M2 时间轴读本地库；M3 要拉 evaluation 时再做 |
| 时间戳 | 未规定 | 线上与本地统一**毫秒整数** | 避免时区/格式歧义，Drizzle 用 `timestamp_ms` |
| 黑名单来源 | 设置页 | 环境变量 `SESSION_BLOCK_APPS` / `SESSION_BLOCK_DOMAINS`（逗号分隔，bundle id / 域名）+ UserDefaults 键 `blocklist` | 设置页是 M4；M2 先能用 |
| 睡眠 | 记为 idle span | 采样间隔超过 `maxGap`（10 秒）时，间隙补一个 idle span | 与"以时间戳为准"一致 |
| 越权/失效引用 | 未规定 | 同步时 `categoryId` / `entryId` 不属于该用户或不存在 → 存 null，不拒绝整条 | 避免一条坏数据让 outbox 永远卡住 |
| Todoist 项目被删除/归档 | 未规定 | 同步项目时，本地 `todoist_project_id` 不在 Todoist 返回列表里的分类标记为 `archived`；**session 保留**，选择器里不再展示；Todoist 里恢复后自动取消归档 | 用户要求：历史记录不丢，列表不再出现 |
| 其他用户已占用的 session id | 未规定 | 返回 `rejected: [{id, reason:"CONFLICT"}]`，客户端标记 `rejected` 不再重试 | 幂等且不泄露他人数据 |

**不做（留给后续）：** 设置页/黑名单编辑 UI（M4）、LLM 评估与时间轴上的分数/摘要（M3）、`url_path` 采集（默认只存 host；字段保留为 null）、Firefox 网站拦截、系统通知。

## 0.1 约束（与 M1 相同，继续遵守）

- 真实 token（Todoist / API）绝不写入文件、日志或提交，子代理只用假 token 和临时库，不得索要真实 token。
- 只用显式路径 `git add <paths>`，不用 `git add -A`；不用裸 `git stash`。
- 提交信息结尾：`Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`。
- 工作目录限定在 worktree：`.worktrees/phase1-m1`（仓库根目录下）。
- 需要 GUI / 系统权限的步骤（Task D6、E1）不能交给子代理，由用户手动验证。

## 0.2 API 契约（Mac 与后端必须一致）

`POST /sync/sessions`，Bearer 鉴权。

请求：
```json
{
  "sessions": [{
    "id": "uuid-lowercase",
    "categoryId": "cat-id | null",
    "source": "todoist | custom",
    "todoistTaskId": "string | null",
    "entryId": "string | null",
    "title": "标题快照",
    "plannedSeconds": 1500,
    "actualSeconds": 1500,
    "startedAt": 1761300000000,
    "endedAt": 1761301500000,
    "spans": [{
      "id": "uuid-lowercase",
      "kind": "active | idle",
      "appBundleId": "string | null",
      "appName": "string | null",
      "windowTitle": "string | null",
      "urlHost": "string | null",
      "urlPath": null,
      "startedAt": 1761300000000,
      "endedAt": 1761300060000,
      "wasBlocked": false
    }]
  }]
}
```
约束：`sessions` 1–50 条；每条 `spans` ≤ 5000；`endedAt >= startedAt`（span 同理）。

响应 `200`：`{ "accepted": ["id", ...], "rejected": [{ "id": "...", "reason": "CONFLICT" | "INVALID_TIME" }] }`。已存在且属于本人的 id 算 accepted（幂等）。请求体非法 → `400 {"error":"BAD_REQUEST"}`；无/错 token → `401`。

---

## 0.3 参考 activity-clock 的经验（作者本地的 activity-clock 项目）

该项目是用户之前写的 Rust 采集器，`crates/ac-watchers/src/{afk,window}.rs` 里踩过的坑直接并入本计划：

| 问题 | activity-clock 的结论 | M2 的做法 |
|---|---|---|
| 闲置检测 | `CGEventSourceSecondsSinceLastEventType` 在非 .app 的进程里会返回系统开机时长（~67000 秒），改用 IOKit `IOHIDSystem` 的 `HIDIdleTime`（纳秒） | D6 的 `idleSeconds()` 用 `HIDIdleTime`；而我们 `swift run` 正是裸可执行文件，不能用 CGEventSource |
| 看视频被判闲置 | 闲置超过阈值时，检查前台 App 是否持有 `PreventUserIdleDisplaySleep` 电源断言（`IOPMCopyAssertionsByProcess`），有则不算闲置 | D6 同样实现；这顺带解决了设计文档里"看视频/阅读被误判闲置"的已知局限 |
| 前台 App 检测 | 没有 NSRunLoop 的进程里 `NSWorkspace.frontmostApplication` 会缓存不更新，改用 `lsappinfo`（约 6ms/次） | 我们的 App 有 RunLoop，仍以 `NSWorkspace` 为主；E1 第 12 项专门验证切换是否及时，若发现陈旧值，改用 `lsappinfo front` + `lsappinfo info -only bundleid -only name -only pid <asn>` |
| 窗口标题 | `CGWindowList` 需要"屏幕录制"权限，不要用；用 AX 的 `AXFocusedWindow → AXTitle`；失败时记录 AX 错误码（`-25211 APIDisabled`、`-25204 CannotComplete` 等）便于排查 | D6 用 AX；用 `os.Logger` 在 debug 级别输出错误码名 |
| 浏览器 URL | 另有 Chrome 扩展方案（`extension/`），无需 AppleScript 自动化权限 | M2 沿用设计文档的 AppleScript；扩展方案记为后续备选，不在 M2 做 |

---

# Part C — 后端

工作目录 `backend/`。测试：`npm test`；类型：`npm run typecheck`。

### Task C1：sessions 与 activity_spans 表

**Files:**
- Modify: `backend/src/db/schema.ts`
- Create (generated): `backend/drizzle/0001_*.sql`
- Test: `backend/src/db/client.test.ts`

**Step 1: 写失败测试**（追加到 `client.test.ts`，沿用该文件已有的 import 风格）

```ts
it('creates sessions and activity_spans tables via migrations', () => {
  const db = createDb(':memory:')
  const names = db.$client
    .prepare("select name from sqlite_master where type = 'table'")
    .all()
    .map((r) => (r as { name: string }).name)
  expect(names).toEqual(expect.arrayContaining(['sessions', 'activity_spans']))
})
```

> 若 `db.$client` 不可用，先 `cat src/db/client.ts` 看 `createDb` 返回的结构，用同样方式拿到底层连接；不要改 `createDb` 签名。

**Step 2:** `npm test -- client` → FAIL（表不存在）。

**Step 3: 实现** 在 `schema.ts` 顶部 import 加 `index`，文件末尾（`export type` 之前）加：

```ts
export const sessions = sqliteTable(
  'sessions',
  {
    id: text('id').primaryKey(),
    userId: text('user_id').notNull().references(() => users.id),
    categoryId: text('category_id').references(() => categories.id),
    source: text('source', { enum: ['todoist', 'custom'] }).notNull(),
    todoistTaskId: text('todoist_task_id'),
    entryId: text('entry_id').references(() => entries.id),
    titleSnapshot: text('title_snapshot').notNull(),
    plannedSeconds: integer('planned_seconds').notNull(),
    actualSeconds: integer('actual_seconds').notNull(),
    startedAt: integer('started_at', { mode: 'timestamp_ms' }).notNull(),
    endedAt: integer('ended_at', { mode: 'timestamp_ms' }).notNull(),
    status: text('status', { enum: ['completed'] }).notNull().default('completed'),
  },
  (t) => [index('sessions_user_started').on(t.userId, t.startedAt)],
)

export const activitySpans = sqliteTable(
  'activity_spans',
  {
    id: text('id').primaryKey(),
    sessionId: text('session_id').notNull().references(() => sessions.id),
    kind: text('kind', { enum: ['active', 'idle'] }).notNull(),
    appBundleId: text('app_bundle_id'),
    appName: text('app_name'),
    windowTitle: text('window_title'),
    urlHost: text('url_host'),
    urlPath: text('url_path'),
    startedAt: integer('started_at', { mode: 'timestamp_ms' }).notNull(),
    endedAt: integer('ended_at', { mode: 'timestamp_ms' }).notNull(),
    wasBlocked: integer('was_blocked', { mode: 'boolean' }).notNull().default(false),
  },
  (t) => [index('spans_session').on(t.sessionId)],
)

export type SessionRow = typeof sessions.$inferSelect
export type ActivitySpanRow = typeof activitySpans.$inferSelect
```

然后 `npm run db:generate`，确认生成 `drizzle/0001_*.sql` 且只含这两张表与两个索引。

**Step 4:** `npm test && npm run typecheck` → 全绿（26 + 1）。

**Step 5: 提交**
```bash
git add backend/src/db/schema.ts backend/src/db/client.test.ts backend/drizzle
git commit -m "feat(backend): add sessions and activity_spans tables

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task C2：POST /sync/sessions

**Files:**
- Create: `backend/src/routes/sync.ts`, `backend/src/routes/sync.test.ts`
- Modify: `backend/src/app.ts`

**Step 1: 写失败测试** `sync.test.ts`

```ts
import { eq } from 'drizzle-orm'
import { expect, it } from 'vitest'
import { hashToken } from '../crypto.js'
import { activitySpans, categories, sessions, users } from '../db/schema.js'
import { authHeader, makeTestApp } from '../testing.js'

const post = (body: unknown) => ({
  method: 'POST',
  headers: { ...authHeader, 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
})

const span = (id: string, over: Record<string, unknown> = {}) => ({
  id, kind: 'active', appBundleId: 'com.apple.dt.Xcode', appName: 'Xcode',
  windowTitle: 'a.swift', urlHost: null, urlPath: null,
  startedAt: 1_000, endedAt: 2_000, wasBlocked: false, ...over,
})

const session = (id: string, over: Record<string, unknown> = {}) => ({
  id, categoryId: null, source: 'custom', todoistTaskId: null, entryId: null,
  title: '写周报', plannedSeconds: 1500, actualSeconds: 1500,
  startedAt: 1_000, endedAt: 2_000, spans: [span(`${id}-s1`)], ...over,
})

it('stores sessions with their spans', async () => {
  const { app, db } = makeTestApp()
  const res = await app.request('/sync/sessions', post({ sessions: [session('s1')] }))
  expect(res.status).toBe(200)
  expect(await res.json()).toEqual({ accepted: ['s1'], rejected: [] })
  const row = db.select().from(sessions).where(eq(sessions.id, 's1')).get()
  expect(row).toMatchObject({ userId: 'u1', titleSnapshot: '写周报', actualSeconds: 1500 })
  expect(db.select().from(activitySpans).all()).toHaveLength(1)
})

it('is idempotent: re-posting the same session accepts it without duplicating', async () => {
  const { app, db } = makeTestApp()
  await app.request('/sync/sessions', post({ sessions: [session('s1')] }))
  const res = await app.request('/sync/sessions', post({ sessions: [session('s1')] }))
  expect(await res.json()).toEqual({ accepted: ['s1'], rejected: [] })
  expect(db.select().from(sessions).all()).toHaveLength(1)
  expect(db.select().from(activitySpans).all()).toHaveLength(1)
})

it('nulls out a category that does not exist or belongs to someone else', async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'other', apiTokenHash: hashToken('x'), createdAt: new Date() }).run()
  db.insert(categories).values({ id: 'c-other', userId: 'u2', name: 'n', color: 'red' }).run()
  await app.request('/sync/sessions', post({ sessions: [
    session('a', { categoryId: 'c-other' }), session('b', { categoryId: 'missing' }),
  ] }))
  const rows = db.select().from(sessions).all()
  expect(rows.map((r) => r.categoryId)).toEqual([null, null])
})

it("rejects a session id owned by another user", async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'other', apiTokenHash: hashToken('x'), createdAt: new Date() }).run()
  db.insert(sessions).values({
    id: 'taken', userId: 'u2', source: 'custom', titleSnapshot: 't', plannedSeconds: 1,
    actualSeconds: 1, startedAt: new Date(1), endedAt: new Date(2),
  }).run()
  const res = await app.request('/sync/sessions', post({ sessions: [session('taken'), session('ok')] }))
  expect(await res.json()).toEqual({ accepted: ['ok'], rejected: [{ id: 'taken', reason: 'CONFLICT' }] })
})

it('rejects a session whose end is before its start', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/sync/sessions', post({ sessions: [session('bad', { startedAt: 5, endedAt: 1 })] }))
  expect(await res.json()).toEqual({ accepted: [], rejected: [{ id: 'bad', reason: 'INVALID_TIME' }] })
})

it('returns 400 for a malformed body and 401 without a token', async () => {
  const { app } = makeTestApp()
  expect((await app.request('/sync/sessions', post({ sessions: [] }))).status).toBe(400)
  expect((await app.request('/sync/sessions', post({ nope: 1 }))).status).toBe(400)
  const res = await app.request('/sync/sessions', { method: 'POST', body: '{}' })
  expect(res.status).toBe(401)
})
```

**Step 2:** `npm test -- sync` → FAIL（404 / 模块不存在）。

**Step 3: 实现** `sync.ts`

```ts
import { and, eq } from 'drizzle-orm'
import { Hono } from 'hono'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { activitySpans, categories, entries, sessions } from '../db/schema.js'

const id = z.string().min(1).max(64)
const ms = z.number().int().nonnegative()
const spanSchema = z.object({
  id,
  kind: z.enum(['active', 'idle']),
  appBundleId: z.string().nullable(),
  appName: z.string().nullable(),
  windowTitle: z.string().nullable(),
  urlHost: z.string().nullable(),
  urlPath: z.string().nullable(),
  startedAt: ms,
  endedAt: ms,
  wasBlocked: z.boolean(),
})
const sessionSchema = z.object({
  id,
  categoryId: z.string().nullable(),
  source: z.enum(['todoist', 'custom']),
  todoistTaskId: z.string().nullable(),
  entryId: z.string().nullable(),
  title: z.string().min(1),
  plannedSeconds: z.number().int().positive(),
  actualSeconds: z.number().int().nonnegative(),
  startedAt: ms,
  endedAt: ms,
  spans: z.array(spanSchema).max(5000),
})
const bodySchema = z.object({ sessions: z.array(sessionSchema).min(1).max(50) })

type Rejection = { id: string; reason: 'CONFLICT' | 'INVALID_TIME' }
const SPAN_CHUNK = 200 // 11 列 × 200 = 2200 个绑定参数，低于 SQLite 上限

export function syncRoutes(db: Db) {
  const r = new Hono<AppEnv>()

  r.post('/sessions', async (c) => {
    const parsed = bodySchema.safeParse(await c.req.json().catch(() => null))
    if (!parsed.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const userId = c.get('user').id
    const accepted: string[] = []
    const rejected: Rejection[] = []

    for (const s of parsed.data.sessions) {
      const timesOk = s.endedAt >= s.startedAt && s.spans.every((p) => p.endedAt >= p.startedAt)
      if (!timesOk) { rejected.push({ id: s.id, reason: 'INVALID_TIME' }); continue }

      const outcome = db.transaction((tx) => {
        const existing = tx.select({ userId: sessions.userId }).from(sessions).where(eq(sessions.id, s.id)).get()
        if (existing) return existing.userId === userId ? 'ok' : 'conflict'

        const categoryId = s.categoryId &&
          tx.select({ id: categories.id }).from(categories)
            .where(and(eq(categories.id, s.categoryId), eq(categories.userId, userId))).get()
          ? s.categoryId : null
        const entryId = s.entryId &&
          tx.select({ id: entries.id }).from(entries)
            .where(and(eq(entries.id, s.entryId), eq(entries.userId, userId))).get()
          ? s.entryId : null

        tx.insert(sessions).values({
          id: s.id, userId, categoryId, source: s.source, todoistTaskId: s.todoistTaskId, entryId,
          titleSnapshot: s.title, plannedSeconds: s.plannedSeconds, actualSeconds: s.actualSeconds,
          startedAt: new Date(s.startedAt), endedAt: new Date(s.endedAt),
        }).run()

        for (let i = 0; i < s.spans.length; i += SPAN_CHUNK) {
          tx.insert(activitySpans).values(
            s.spans.slice(i, i + SPAN_CHUNK).map((p) => ({
              ...p, sessionId: s.id, startedAt: new Date(p.startedAt), endedAt: new Date(p.endedAt),
            })),
          ).onConflictDoNothing().run()
        }
        return 'ok'
      })

      if (outcome === 'ok') accepted.push(s.id)
      else rejected.push({ id: s.id, reason: 'CONFLICT' })
    }
    return c.json({ accepted, rejected })
  })

  return r
}
```

`app.ts`：`import { syncRoutes } from './routes/sync.js'`，在 `api.route('/entries', ...)` 后加 `api.route('/sync', syncRoutes(deps.db))`。

**Step 4:** `npm test && npm run typecheck` → 全绿。若 `db.transaction` 的类型在 drizzle 0.45 + better-sqlite3 上要求同步回调，保持回调同步（不要 `async`）。

**Step 5: 提交**
```bash
git add backend/src/routes/sync.ts backend/src/routes/sync.test.ts backend/src/app.ts
git commit -m "feat(backend): add idempotent POST /sync/sessions

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task C3：Todoist 项目被删除后归档分类（保留 session，不再列出）

**Files:**
- Modify: `backend/src/routes/todoist.ts`, `backend/src/routes/categories.ts`
- Test: `backend/src/routes/todoist.test.ts`、`backend/src/routes/sync.test.ts`

**规则**
- `GET /todoist/projects` 成功拿到 Todoist 项目列表后：该用户所有 `todoist_project_id` 非空、且**不在**返回列表中的分类 → `archived = true`；在列表中的分类 → `archived = false`（项目恢复后自动重新出现）。
- 自定义分类（`todoist_project_id` 为 null）永不自动归档。
- 返回 `categories`：仍然只含未归档的（选择器用）；新增 `?all=1` 时包含已归档的，并且每个分类带 `archived` 字段（历史 session 查名称/颜色用）。`/categories` 同样支持 `?all=1`。
- 安全阀：Todoist 返回空列表时**不归档**任何分类（用户至少有 Inbox，空列表更可能是异常）；Todoist 调用抛错时不改动 DB（现有逻辑已在抛错前不写入）。
- session 和 entries 的 `category_id` 不动：历史记录保留，仍能找到分类名与颜色。

**Step 1: 写失败测试**（追加到 `todoist.test.ts`，沿用该文件的 `gatewayWith` 辅助函数与 `authHeader`）

```ts
it('archives categories whose Todoist project disappeared, but keeps them for history', async () => {
  let projects = [
    { id: 'p1', name: 'Work', color: 'blue' },
    { id: 'p2', name: 'Home', color: 'red' },
  ]
  const { app } = makeTestApp({ gateway: gatewayWith({ projects: async () => projects }) })
  const first = await (await app.request('/todoist/projects', { headers: authHeader })).json()
  expect(first.categories.map((c: { name: string }) => c.name).sort()).toEqual(['Home', 'Work'])

  projects = [projects[0]!]
  const second = await (await app.request('/todoist/projects', { headers: authHeader })).json()
  expect(second.categories.map((c: { name: string }) => c.name)).toEqual(['Work'])

  const all = await (await app.request('/categories?all=1', { headers: authHeader })).json()
  expect(all.categories.find((c: { name: string }) => c.name === 'Home')).toMatchObject({ archived: true })
})

it('un-archives a project that comes back', async () => {
  let projects = [{ id: 'p1', name: 'Work', color: 'blue' }]
  const { app } = makeTestApp({ gateway: gatewayWith({ projects: async () => projects }) })
  await app.request('/todoist/projects', { headers: authHeader })
  projects = [{ id: 'p9', name: 'Other', color: 'red' }]
  await app.request('/todoist/projects', { headers: authHeader })
  projects = [{ id: 'p1', name: 'Work', color: 'blue' }, { id: 'p9', name: 'Other', color: 'red' }]
  const res = await (await app.request('/todoist/projects', { headers: authHeader })).json()
  expect(res.categories).toHaveLength(2)
})

it('never archives custom categories and ignores an empty project list', async () => {
  let projects = [{ id: 'p1', name: 'Work', color: 'blue' }]
  const { app } = makeTestApp({ gateway: gatewayWith({ projects: async () => projects }) })
  await app.request('/categories', {
    method: 'POST', headers: { ...authHeader, 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: '阅读', color: 'green' }),
  })
  await app.request('/todoist/projects', { headers: authHeader })
  projects = []
  const res = await (await app.request('/todoist/projects', { headers: authHeader })).json()
  expect(res.categories.map((c: { name: string }) => c.name).sort()).toEqual(['Work', '阅读'])
})
```

再追加到 `sync.test.ts`：一个绑定到已归档分类的 session 仍保留 `categoryId`（归档不等于不存在）：
```ts
it('keeps the category on a session even if that category is archived', async () => {
  const { app, db } = makeTestApp()
  db.insert(categories).values({ id: 'c-old', userId: 'u1', name: 'Old', color: 'red', archived: true }).run()
  await app.request('/sync/sessions', post({ sessions: [session('s1', { categoryId: 'c-old' })] }))
  expect(db.select().from(sessions).get()?.categoryId).toBe('c-old')
})
```

**Step 2:** `npm test` → 前三个 FAIL。

**Step 3: 实现**

`todoist.ts` 的 `/projects`：把 `for` 循环改为在同一事务内 upsert 并归档，且 `set` 里加 `archived: false`：
```ts
    try {
      const projects = await gateway.projects()
      db.transaction((tx) => {
        for (const p of projects) {
          tx.insert(categories)
            .values({ id: randomUUID(), userId: user.id, todoistProjectId: p.id, name: p.name, color: p.color })
            .onConflictDoUpdate({
              target: [categories.userId, categories.todoistProjectId],
              set: { name: p.name, color: p.color, archived: false },
            })
            .run()
        }
        if (projects.length > 0) {
          const live = new Set(projects.map((p) => p.id))
          const known = tx.select().from(categories)
            .where(and(eq(categories.userId, user.id), isNotNull(categories.todoistProjectId))).all()
          for (const row of known) {
            if (row.todoistProjectId && !live.has(row.todoistProjectId) && !row.archived) {
              tx.update(categories).set({ archived: true }).where(eq(categories.id, row.id)).run()
            }
          }
        }
      })
    } catch (e) { ...原有 TodoistAuthError 分支不变... }
```
（`import { and, eq, isNotNull } from 'drizzle-orm'`。）

返回部分改为共用一个函数，放在 `todoist.ts` 导出，`categories.ts` 复用：
```ts
export function listCategories(db: Db, userId: string, includeArchived: boolean) {
  const where = includeArchived
    ? eq(categories.userId, userId)
    : and(eq(categories.userId, userId), eq(categories.archived, false))
  return db.select().from(categories).where(where).all()
}
export const toCategoryDto = (c: typeof categories.$inferSelect, withArchived = false) => ({
  id: c.id, name: c.name, color: c.color, todoistProjectId: c.todoistProjectId,
  ...(withArchived ? { archived: c.archived } : {}),
})
```
两个 GET 路由读 `c.req.query('all') === '1'`，调用 `listCategories(...)` 并 `toCategoryDto(row, all)`。注意：`POST /categories` 的返回和 M1 已有测试不要变（不带 `archived`）。

**Step 4:** `npm test && npm run typecheck` → 全绿（含 M1 原有用例）。

**Step 5: 提交**
```bash
git add backend/src/routes/todoist.ts backend/src/routes/categories.ts backend/src/routes/todoist.test.ts backend/src/routes/sync.test.ts
git commit -m "feat(backend): archive categories for deleted Todoist projects, keep history

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

# Part D — Mac 客户端

工作目录 `mac/`。测试：`swift test`；构建：`swift build`（要求零警告）。

### Task D1：ActivitySample / ActivitySpan 与 SpanBuilder（纯逻辑）

**Files:**
- Create: `mac/Sources/SessionCore/Activity/ActivityModels.swift`, `mac/Sources/SessionCore/Activity/SpanBuilder.swift`
- Test: `mac/Tests/SessionCoreTests/SpanBuilderTests.swift`

**ActivityModels.swift**
```swift
import Foundation

public enum SpanKind: String, Codable, Sendable { case active, idle }

/// 一次采样的前台信息；闲置时不采集标题/URL，全部为 nil。
public struct ActivitySample: Equatable, Sendable {
    public let time: Date
    public let idleSeconds: TimeInterval
    public let appBundleId: String?
    public let appName: String?
    public let windowTitle: String?
    public let urlHost: String?
    public let wasBlocked: Bool

    public init(time: Date, idleSeconds: TimeInterval = 0, appBundleId: String? = nil, appName: String? = nil,
                windowTitle: String? = nil, urlHost: String? = nil, wasBlocked: Bool = false) {
        self.time = time; self.idleSeconds = idleSeconds; self.appBundleId = appBundleId
        self.appName = appName; self.windowTitle = windowTitle; self.urlHost = urlHost
        self.wasBlocked = wasBlocked
    }
}

public struct ActivitySpan: Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let kind: SpanKind
    public let appBundleId: String?
    public let appName: String?
    public let windowTitle: String?
    public let urlHost: String?
    public let urlPath: String?
    public let startedAt: Date
    public let endedAt: Date
    public let wasBlocked: Bool

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    public init(id: String = UUID().uuidString.lowercased(), sessionId: String, kind: SpanKind,
                appBundleId: String?, appName: String?, windowTitle: String?, urlHost: String?,
                urlPath: String? = nil, startedAt: Date, endedAt: Date, wasBlocked: Bool) {
        self.id = id; self.sessionId = sessionId; self.kind = kind; self.appBundleId = appBundleId
        self.appName = appName; self.windowTitle = windowTitle; self.urlHost = urlHost
        self.urlPath = urlPath; self.startedAt = startedAt; self.endedAt = endedAt
        self.wasBlocked = wasBlocked
    }
}
```

**Step 1: 写失败测试** `SpanBuilderTests.swift`

```swift
import XCTest
@testable import SessionCore

final class SpanBuilderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func xcode(_ s: TimeInterval, title: String = "a.swift", idle: TimeInterval = 0, blocked: Bool = false) -> ActivitySample {
        ActivitySample(time: at(s), idleSeconds: idle, appBundleId: "com.apple.dt.Xcode", appName: "Xcode",
                       windowTitle: title, wasBlocked: blocked)
    }
    private func makeBuilder() -> SpanBuilder { SpanBuilder(sessionId: "s", idleThreshold: 120, maxGap: 10) }

    func testSameAppAndTitleExtendsOneSpan() {
        var b = makeBuilder()
        XCTAssertTrue(b.add(xcode(0)).isEmpty)
        XCTAssertTrue(b.add(xcode(2)).isEmpty)
        let closed = b.finish(at: at(4))
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].startedAt, at(0))
        XCTAssertEqual(closed[0].endedAt, at(4))
        XCTAssertEqual(closed[0].kind, .active)
    }

    func testTitleChangeClosesSpanAtNewSample() {
        var b = makeBuilder()
        _ = b.add(xcode(0, title: "a"))
        let closed = b.add(xcode(2, title: "b"))
        XCTAssertEqual(closed.map(\.windowTitle), ["a"])
        XCTAssertEqual(closed[0].endedAt, at(2))
    }

    func testBlockedFlagSplitsSpan() {
        var b = makeBuilder()
        _ = b.add(xcode(0))
        let closed = b.add(xcode(2, blocked: true))
        XCTAssertEqual(closed.count, 1)
        XCTAssertFalse(closed[0].wasBlocked)
        XCTAssertTrue(b.finish(at: at(4))[0].wasBlocked)
    }

    func testIdleStartsWhenInputStoppedNotWhenThresholdCrossed() {
        var b = makeBuilder()
        _ = b.add(xcode(0))
        _ = b.add(xcode(60))                       // 仍有输入
        // 在 t=200 时已无输入 130 秒 → 闲置从 t=70 开始
        let closed = b.add(ActivitySample(time: at(200), idleSeconds: 130))
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].kind, .active)
        XCTAssertEqual(closed[0].endedAt, at(70))
        let rest = b.finish(at: at(210))
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest[0].kind, .idle)
        XCTAssertEqual(rest[0].startedAt, at(70))
        XCTAssertEqual(rest[0].endedAt, at(210))
        XCTAssertNil(rest[0].windowTitle)
    }

    func testIdleNeverStartsBeforeCurrentSpan() {
        var b = makeBuilder()
        _ = b.add(xcode(100))
        // idleSeconds 比 span 已存在的时间还长（专注开始前就没输入）→ 从 span 起点开始
        let closed = b.add(ActivitySample(time: at(102), idleSeconds: 500))
        XCTAssertTrue(closed.isEmpty)               // 长度为 0 的 active 被丢弃
        let rest = b.finish(at: at(110))
        XCTAssertEqual(rest.map(\.kind), [.idle])
        XCTAssertEqual(rest[0].startedAt, at(100))
    }

    func testInputResumingClosesIdleSpanAndOpensActive() {
        var b = makeBuilder()
        _ = b.add(ActivitySample(time: at(0), idleSeconds: 130))
        let closed = b.add(xcode(10))
        XCTAssertEqual(closed.map(\.kind), [.idle])
        XCTAssertEqual(closed[0].endedAt, at(10))
        XCTAssertEqual(b.finish(at: at(12)).map(\.kind), [.active])
    }

    func testBelowThresholdIsNotIdle() {
        var b = makeBuilder()
        _ = b.add(xcode(0))
        XCTAssertTrue(b.add(xcode(2, idle: 119)).isEmpty)
        XCTAssertEqual(b.finish(at: at(4)).map(\.kind), [.active])
    }

    func testLargeGapBecomesIdleSpan() {
        var b = makeBuilder()
        _ = b.add(xcode(0))
        _ = b.add(xcode(2))
        // 合盖睡眠：下一个采样在 600 秒之后
        let closed = b.add(xcode(600))
        XCTAssertEqual(closed.map(\.kind), [.active, .idle])
        XCTAssertEqual(closed[0].endedAt, at(2))
        XCTAssertEqual(closed[1].startedAt, at(2))
        XCTAssertEqual(closed[1].endedAt, at(600))
        XCTAssertEqual(b.finish(at: at(602)).map(\.kind), [.active])
    }

    func testFinishWithoutSamplesReturnsNothingAndDropsZeroLengthSpans() {
        var b = makeBuilder()
        XCTAssertTrue(b.finish(at: at(5)).isEmpty)
        _ = b.add(xcode(5))
        XCTAssertTrue(b.finish(at: at(5)).isEmpty)
    }

    func testSpansCarrySessionId() {
        var b = makeBuilder()
        _ = b.add(xcode(0))
        XCTAssertEqual(b.finish(at: at(3)).first?.sessionId, "s")
    }
}
```

**Step 2:** `swift test --filter SpanBuilderTests` → 编译失败（找不到类型）= 红。

**Step 3: 实现** `SpanBuilder.swift`

```swift
import Foundation

/// 把离散采样点合并为 span。纯值类型，无副作用，便于测试。
public struct SpanBuilder {
    private struct Open {
        var kind: SpanKind
        var appBundleId: String?
        var appName: String?
        var windowTitle: String?
        var urlHost: String?
        var wasBlocked: Bool
        var start: Date

        func sameTarget(as s: ActivitySample) -> Bool {
            kind == .active && appBundleId == s.appBundleId && windowTitle == s.windowTitle
                && urlHost == s.urlHost && wasBlocked == s.wasBlocked
        }
    }

    private let sessionId: String
    private let idleThreshold: TimeInterval
    private let maxGap: TimeInterval
    private var current: Open?
    private var lastSampleTime: Date?

    public init(sessionId: String, idleThreshold: TimeInterval = 120, maxGap: TimeInterval = 10) {
        self.sessionId = sessionId; self.idleThreshold = idleThreshold; self.maxGap = maxGap
    }

    /// 返回因此次采样而关闭的 span（可能为空）。
    public mutating func add(_ s: ActivitySample) -> [ActivitySpan] {
        var closed: [ActivitySpan] = []

        // 采样间隔过大（睡眠/卡死）：把间隙记为闲置。
        if let last = lastSampleTime, s.time.timeIntervalSince(last) > maxGap {
            closed += close(at: last)
            current = Open(kind: .idle, appBundleId: nil, appName: nil, windowTitle: nil,
                           urlHost: nil, wasBlocked: false, start: last)
        }
        lastSampleTime = s.time

        if s.idleSeconds >= idleThreshold {
            if current?.kind == .idle { return closed }
            // 闲置从最后一次输入算起，但不早于当前 span 的起点。
            let floor = current?.start ?? s.time
            let idleStart = max(s.time.addingTimeInterval(-s.idleSeconds), floor)
            closed += close(at: idleStart)
            current = Open(kind: .idle, appBundleId: nil, appName: nil, windowTitle: nil,
                           urlHost: nil, wasBlocked: false, start: idleStart)
            return closed
        }

        if let cur = current, cur.sameTarget(as: s) { return closed }
        closed += close(at: s.time)
        current = Open(kind: .active, appBundleId: s.appBundleId, appName: s.appName,
                       windowTitle: s.windowTitle, urlHost: s.urlHost, wasBlocked: s.wasBlocked,
                       start: s.time)
        return closed
    }

    /// 专注结束：关闭仍打开的 span。
    public mutating func finish(at end: Date) -> [ActivitySpan] {
        let out = close(at: end)
        lastSampleTime = nil
        return out
    }

    private mutating func close(at end: Date) -> [ActivitySpan] {
        defer { current = nil }
        guard let cur = current, end > cur.start else { return [] }
        return [ActivitySpan(sessionId: sessionId, kind: cur.kind, appBundleId: cur.appBundleId,
                             appName: cur.appName, windowTitle: cur.windowTitle, urlHost: cur.urlHost,
                             startedAt: cur.start, endedAt: end, wasBlocked: cur.wasBlocked)]
    }
}
```

> 注意 `testLargeGapBecomesIdleSpan`：间隙处理先 `close(at: last)` 再开 idle，随后因本次采样是 active，走到末尾 `close(at: s.time)` 关闭 idle 并开新 active，得到 `[active, idle]`。若 `testIdleNeverStartsBeforeCurrentSpan` 失败，检查 `floor` 逻辑与"长度 0 的 span 丢弃"。

**Step 4:** `swift test --filter SpanBuilderTests` → 全绿；`swift build` 无警告。

**Step 5: 提交**
```bash
git add mac/Sources/SessionCore/Activity mac/Tests/SessionCoreTests/SpanBuilderTests.swift
git commit -m "feat(mac): add SpanBuilder with idle splitting and sleep gaps

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task D2：BlockList（纯函数匹配）

**Files:**
- Create: `mac/Sources/SessionCore/Blocker/BlockList.swift`
- Test: `mac/Tests/SessionCoreTests/BlockListTests.swift`

**Step 1: 测试**
```swift
import XCTest
@testable import SessionCore

final class BlockListTests: XCTestCase {
    private let list = BlockList(apps: ["com.tencent.xinWeChat"], domains: ["youtube.com", "twitter.com"])

    func testBlockedAppIsHidden() {
        XCTAssertEqual(list.decide(bundleId: "com.tencent.xinWeChat", urlHost: nil), .hideApp(bundleId: "com.tencent.xinWeChat"))
    }
    func testExactAndSubdomainMatch() {
        XCTAssertEqual(list.decide(bundleId: "com.google.Chrome", urlHost: "youtube.com"), .redirectSite(host: "youtube.com"))
        XCTAssertEqual(list.decide(bundleId: "com.google.Chrome", urlHost: "www.youtube.com"), .redirectSite(host: "www.youtube.com"))
        XCTAssertEqual(list.decide(bundleId: "com.google.Chrome", urlHost: "m.TWITTER.com"), .redirectSite(host: "m.twitter.com"))
    }
    func testLookalikeDomainIsNotBlocked() {
        XCTAssertEqual(list.decide(bundleId: "com.google.Chrome", urlHost: "notyoutube.com"), .allow)
        XCTAssertEqual(list.decide(bundleId: "com.google.Chrome", urlHost: "youtube.com.evil.org"), .allow)
    }
    func testAppRuleWinsOverSiteRule() {
        let both = BlockList(apps: ["com.google.Chrome"], domains: ["youtube.com"])
        XCTAssertEqual(both.decide(bundleId: "com.google.Chrome", urlHost: "youtube.com"), .hideApp(bundleId: "com.google.Chrome"))
    }
    func testNothingBlockedWhenEmptyOrUnknown() {
        XCTAssertEqual(BlockList().decide(bundleId: "x", urlHost: "youtube.com"), .allow)
        XCTAssertEqual(list.decide(bundleId: nil, urlHost: nil), .allow)
    }
    func testParsesCommaSeparatedLists() {
        let l = BlockList(appsCSV: " a.b , c.d ,,", domainsCSV: "Foo.com, bar.org ")
        XCTAssertEqual(l.apps, ["a.b", "c.d"])
        XCTAssertEqual(l.domains, ["foo.com", "bar.org"])
    }
    func testMergedCombinesBothLists() {
        let m = BlockList(apps: ["a"], domains: ["x.com"]).merged(with: BlockList(apps: ["b"], domains: ["y.com"]))
        XCTAssertEqual(m.apps, ["a", "b"])
        XCTAssertEqual(m.domains, ["x.com", "y.com"])
    }
}
```

**Step 2:** 编译失败 = 红。

**Step 3: 实现**
```swift
import Foundation

public enum BlockDecision: Equatable, Sendable {
    case allow
    case hideApp(bundleId: String)
    case redirectSite(host: String)
}

public struct BlockList: Codable, Equatable, Sendable {
    public var apps: Set<String>
    public var domains: Set<String>

    public init(apps: Set<String> = [], domains: Set<String> = []) {
        self.apps = apps
        self.domains = Set(domains.map { $0.lowercased() })
    }

    public init(appsCSV: String, domainsCSV: String) {
        func parts(_ s: String) -> [String] {
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        self.init(apps: Set(parts(appsCSV)), domains: Set(parts(domainsCSV)))
    }

    public func merged(with other: BlockList) -> BlockList {
        BlockList(apps: apps.union(other.apps), domains: domains.union(other.domains))
    }

    public func decide(bundleId: String?, urlHost: String?) -> BlockDecision {
        if let bundleId, apps.contains(bundleId) { return .hideApp(bundleId: bundleId) }
        if let host = urlHost?.lowercased(),
           domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return .redirectSite(host: host)
        }
        return .allow
    }
}
```

**Step 4:** `swift test --filter BlockListTests` → 绿。

**Step 5: 提交**
```bash
git add mac/Sources/SessionCore/Blocker mac/Tests/SessionCoreTests/BlockListTests.swift
git commit -m "feat(mac): add BlockList matching rules

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task D3：LocalStore（GRDB）

**Files:**
- Modify: `mac/Package.swift`（加 GRDB 依赖）
- Create: `mac/Sources/SessionCore/Store/LocalStore.swift`, `mac/Sources/SessionCore/Store/SessionRecord.swift`
- Test: `mac/Tests/SessionCoreTests/LocalStoreTests.swift`

**Step 0: 依赖**。先用 context7 查 GRDB 当前版本与 `DatabaseQueue` / `DatabaseMigrator` / `Row` API（`mcp__context7__resolve-library-id` → `query-docs`），确认 7.x 在 Swift 6.1 + 5 语言模式下可编译。`Package.swift`：

```swift
let package = Package(
    name: "Session",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SessionApp", targets: ["SessionApp"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")],
    targets: [
        .target(name: "SessionCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "SessionApp", dependencies: ["SessionCore"]),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"]),
    ]
)
```
`swift build` 能解析并通过后再继续。若依赖解析需要联网而失败，停下来报告，不要换成别的存储方案。

**SessionRecord.swift**
```swift
import Foundation

public enum SyncState: String, Sendable { case pending, synced, rejected }

public struct SessionRecord: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let categoryId: String?
    public let source: SessionSource
    public let todoistTaskId: String?
    public let entryId: String?
    public let plannedSeconds: Int
    public let actualSeconds: Int
    public let startedAt: Date
    public let endedAt: Date
    public var syncState: SyncState

    public init(id: String, title: String, categoryId: String?, source: SessionSource,
                todoistTaskId: String?, entryId: String?, plannedSeconds: Int, actualSeconds: Int,
                startedAt: Date, endedAt: Date, syncState: SyncState = .pending) {
        self.id = id; self.title = title; self.categoryId = categoryId; self.source = source
        self.todoistTaskId = todoistTaskId; self.entryId = entryId; self.plannedSeconds = plannedSeconds
        self.actualSeconds = actualSeconds; self.startedAt = startedAt; self.endedAt = endedAt
        self.syncState = syncState
    }

    public init(_ done: CompletedFocus) {
        self.init(id: done.run.id.uuidString.lowercased(), title: done.run.title,
                  categoryId: done.run.categoryId, source: done.run.source,
                  todoistTaskId: done.run.todoistTaskId, entryId: done.run.entryId,
                  plannedSeconds: done.run.plannedSeconds, actualSeconds: done.actualSeconds,
                  startedAt: done.run.startedAt, endedAt: done.endedAt)
    }
}
```

**Step 1: 测试** `LocalStoreTests.swift`
```swift
import XCTest
@testable import SessionCore

final class LocalStoreTests: XCTestCase {
    private func record(_ id: String, start: TimeInterval = 1_000, end: TimeInterval = 2_500) -> SessionRecord {
        SessionRecord(id: id, title: "写周报", categoryId: "c1", source: .custom, todoistTaskId: nil,
                      entryId: nil, plannedSeconds: 1500, actualSeconds: 1500,
                      startedAt: Date(timeIntervalSince1970: start), endedAt: Date(timeIntervalSince1970: end))
    }
    private func span(_ id: String, session: String, kind: SpanKind = .active, blocked: Bool = false) -> ActivitySpan {
        ActivitySpan(id: id, sessionId: session, kind: kind, appBundleId: "com.apple.dt.Xcode", appName: "Xcode",
                     windowTitle: "a.swift", urlHost: nil, startedAt: Date(timeIntervalSince1970: 1_000),
                     endedAt: Date(timeIntervalSince1970: 1_060), wasBlocked: blocked)
    }

    func testSaveAndReadBackSession() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("s1"))
        let got = try store.sessions(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(got, [record("s1")])
    }

    func testSavingSameSessionTwiceKeepsOneRow() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("s1")); try store.save(record("s1"))
        XCTAssertEqual(try store.sessions(from: .distantPast, to: .distantFuture).count, 1)
    }

    func testSessionsFilteredByRangeAndOrderedByStart() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("late", start: 5_000, end: 6_000))
        try store.save(record("early", start: 1_000, end: 2_000))
        try store.save(record("outside", start: 90_000, end: 91_000))
        let got = try store.sessions(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(got.map(\.id), ["early", "late"])
    }

    func testSpansRoundTripAndAreDeletableBySession() throws {
        let store = try LocalStore(path: nil)
        try store.append([span("p1", session: "s1", blocked: true), span("p2", session: "s1", kind: .idle), span("p3", session: "s2")])
        let s1 = try store.spans(sessionId: "s1")
        XCTAssertEqual(s1.map(\.id), ["p1", "p2"])
        XCTAssertTrue(s1[0].wasBlocked)
        try store.deleteSpans(sessionId: "s1")
        XCTAssertTrue(try store.spans(sessionId: "s1").isEmpty)
        XCTAssertEqual(try store.spans(sessionId: "s2").count, 1)
    }

    func testPruneOrphanSpansKeepsSavedSessionsAndTheActiveOne() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("saved"))
        try store.append([span("a", session: "saved"), span("b", session: "active"), span("c", session: "dead")])
        try store.pruneOrphanSpans(keeping: "active")
        XCTAssertEqual(try store.spans(sessionId: "saved").count, 1)
        XCTAssertEqual(try store.spans(sessionId: "active").count, 1)
        XCTAssertTrue(try store.spans(sessionId: "dead").isEmpty)
    }

    func testPendingReturnsOnlyPendingWithSpansAndRespectsLimit() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("a", start: 1_000)); try store.save(record("b", start: 2_000)); try store.save(record("c", start: 3_000))
        try store.append([span("p1", session: "a")])
        try store.markSynced(["b"])
        let batch = try store.pending(limit: 5)
        XCTAssertEqual(batch.map(\.session.id), ["a", "c"])
        XCTAssertEqual(batch[0].spans.map(\.id), ["p1"])
        XCTAssertEqual(try store.pending(limit: 1).count, 1)
    }

    func testMarkSyncedAndRejectedChangeState() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("a")); try store.save(record("b"))
        try store.markSynced(["a"]); try store.markRejected(["b"])
        let all = try store.sessions(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.syncState) }), ["a": .synced, "b": .rejected])
        XCTAssertTrue(try store.pending(limit: 10).isEmpty)
    }

    func testPendingCount() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("a")); try store.save(record("b")); try store.markSynced(["a"])
        XCTAssertEqual(try store.pendingCount(), 1)
    }
}
```

**Step 2:** 红（类型不存在）。

**Step 3: 实现** `LocalStore.swift`

```swift
import Foundation
import GRDB

/// 本地 SQLite：已完成的专注、活动 span，以及上传状态（outbox = sync_state 为 pending 的行）。
public final class LocalStore: @unchecked Sendable {
    private let db: DatabaseQueue

    /// path 为 nil 时使用内存库（测试）。
    public init(path: String?) throws {
        if let path {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            db = try DatabaseQueue(path: path)
        } else {
            db = try DatabaseQueue()
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, category_id TEXT, source TEXT NOT NULL,
                  todoist_task_id TEXT, entry_id TEXT, planned_seconds INTEGER NOT NULL,
                  actual_seconds INTEGER NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL,
                  sync_state TEXT NOT NULL DEFAULT 'pending');
                CREATE INDEX sessions_started ON sessions(started_at);
                CREATE TABLE spans (
                  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, kind TEXT NOT NULL,
                  app_bundle_id TEXT, app_name TEXT, window_title TEXT, url_host TEXT, url_path TEXT,
                  started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL, was_blocked INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX spans_session ON spans(session_id);
                """)
        }
        try migrator.migrate(db)
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    // MARK: 写

    public func save(_ r: SessionRecord) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO sessions(id, title, category_id, source, todoist_task_id, entry_id,
                  planned_seconds, actual_seconds, started_at, ended_at, sync_state)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [r.id, r.title, r.categoryId, r.source.rawValue, r.todoistTaskId, r.entryId,
                                 r.plannedSeconds, r.actualSeconds, Self.ms(r.startedAt), Self.ms(r.endedAt),
                                 r.syncState.rawValue])
        }
    }

    public func append(_ spans: [ActivitySpan]) throws {
        guard !spans.isEmpty else { return }
        try db.write { db in
            for s in spans {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO spans(id, session_id, kind, app_bundle_id, app_name, window_title,
                      url_host, url_path, started_at, ended_at, was_blocked)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [s.id, s.sessionId, s.kind.rawValue, s.appBundleId, s.appName, s.windowTitle,
                                     s.urlHost, s.urlPath, Self.ms(s.startedAt), Self.ms(s.endedAt), s.wasBlocked])
            }
        }
    }

    public func deleteSpans(sessionId: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM spans WHERE session_id = ?", arguments: [sessionId]) }
    }

    /// 清理崩溃/放弃遗留的 span：既没有对应 session，也不是当前进行中的那次。
    public func pruneOrphanSpans(keeping activeId: String?) throws {
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM spans WHERE session_id NOT IN (SELECT id FROM sessions)
                  AND session_id IS NOT ?
                """, arguments: [activeId])
        }
    }

    public func markSynced(_ ids: [String]) throws { try mark(ids, .synced) }
    public func markRejected(_ ids: [String]) throws { try mark(ids, .rejected) }

    private func mark(_ ids: [String], _ state: SyncState) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE sessions SET sync_state = ? WHERE id = ?", arguments: [state.rawValue, id])
            }
        }
    }

    // MARK: 读

    public func sessions(from: Date, to: Date) throws -> [SessionRecord] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sessions WHERE started_at >= ? AND started_at < ? ORDER BY started_at",
                             arguments: [Self.ms(from), Self.ms(to)]).map(Self.record)
        }
    }

    public func spans(sessionId: String) throws -> [ActivitySpan] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM spans WHERE session_id = ? ORDER BY started_at, rowid",
                             arguments: [sessionId]).map(Self.span)
        }
    }

    public func pending(limit: Int) throws -> [(session: SessionRecord, spans: [ActivitySpan])] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM sessions WHERE sync_state = 'pending' ORDER BY started_at LIMIT ?",
                                        arguments: [limit])
            return try rows.map { row in
                let rec = Self.record(row)
                let spans = try Row.fetchAll(db, sql: "SELECT * FROM spans WHERE session_id = ? ORDER BY started_at, rowid",
                                             arguments: [rec.id]).map(Self.span)
                return (rec, spans)
            }
        }
    }

    public func pendingCount() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions WHERE sync_state = 'pending'") ?? 0 }
    }

    private static func record(_ r: Row) -> SessionRecord {
        SessionRecord(id: r["id"], title: r["title"], categoryId: r["category_id"],
                      source: SessionSource(rawValue: r["source"]) ?? .custom,
                      todoistTaskId: r["todoist_task_id"], entryId: r["entry_id"],
                      plannedSeconds: r["planned_seconds"], actualSeconds: r["actual_seconds"],
                      startedAt: date(r["started_at"]), endedAt: date(r["ended_at"]),
                      syncState: SyncState(rawValue: r["sync_state"]) ?? .pending)
    }

    private static func span(_ r: Row) -> ActivitySpan {
        ActivitySpan(id: r["id"], sessionId: r["session_id"], kind: SpanKind(rawValue: r["kind"]) ?? .active,
                     appBundleId: r["app_bundle_id"], appName: r["app_name"], windowTitle: r["window_title"],
                     urlHost: r["url_host"], urlPath: r["url_path"],
                     startedAt: date(r["started_at"]), endedAt: date(r["ended_at"]),
                     wasBlocked: r["was_blocked"])
    }
}
```

> 注意：`pruneOrphanSpans` 里 `session_id IS NOT ?` 在 `activeId` 为 nil 时变成 `IS NOT NULL`，对 `NOT NULL` 列恒真，即"没有保留项"，行为正确。若 GRDB 版本对 `Row` 下标的泛型推断报歧义，改成 `row["x"] as String` 等显式标注。

**Step 4:** `swift test --filter LocalStoreTests` → 全绿；`swift build` 零警告。

**Step 5: 提交**
```bash
git add mac/Package.swift mac/Package.resolved mac/Sources/SessionCore/Store mac/Tests/SessionCoreTests/LocalStoreTests.swift
git commit -m "feat(mac): add GRDB-backed LocalStore with outbox state

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```
（若仓库不跟踪 `Package.resolved`，去掉该路径；先 `git status` 看有没有这个文件。）

---

### Task D4：同步（APIClient.syncSessions + SyncService）

**Files:**
- Modify: `mac/Sources/SessionCore/API/APIClient.swift`, `mac/Sources/SessionCore/API/Models.swift`
- Create: `mac/Sources/SessionCore/Sync/SyncService.swift`
- Test: `mac/Tests/SessionCoreTests/SyncServiceTests.swift`、追加到 `APIClientTests.swift`

**Models.swift 追加**
```swift
public struct SyncResult: Decodable, Equatable, Sendable {
    public struct Rejection: Decodable, Equatable, Sendable { public let id: String; public let reason: String }
    public let accepted: [String]
    public let rejected: [Rejection]
}
```

**APIClient 追加**（同一个类内；请求体手写 JSON，时间用毫秒整数、nil 显式 `NSNull`，与 M1 的 `createEntry` 同样原因）
```swift
public func syncSessions(_ batch: [(session: SessionRecord, spans: [ActivitySpan])]) async throws -> SyncResult {
    func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    func orNull(_ s: String?) -> Any { s ?? NSNull() }
    let sessions: [[String: Any]] = batch.map { item in
        let s = item.session
        return [
            "id": s.id, "categoryId": orNull(s.categoryId), "source": s.source.rawValue,
            "todoistTaskId": orNull(s.todoistTaskId), "entryId": orNull(s.entryId),
            "title": s.title, "plannedSeconds": s.plannedSeconds, "actualSeconds": s.actualSeconds,
            "startedAt": ms(s.startedAt), "endedAt": ms(s.endedAt),
            "spans": item.spans.map { p -> [String: Any] in [
                "id": p.id, "kind": p.kind.rawValue, "appBundleId": orNull(p.appBundleId),
                "appName": orNull(p.appName), "windowTitle": orNull(p.windowTitle),
                "urlHost": orNull(p.urlHost), "urlPath": orNull(p.urlPath),
                "startedAt": ms(p.startedAt), "endedAt": ms(p.endedAt), "wasBlocked": p.wasBlocked,
            ] },
        ]
    }
    let body = try JSONSerialization.data(withJSONObject: ["sessions": sessions])
    return try await send("POST", "/sync/sessions", body: body)
}
```

**APIClientTests 追加**：沿用该文件里已有的 `URLProtocol` 桩（先 `sed -n 1,60p Tests/SessionCoreTests/APIClientTests.swift` 看桩的用法），断言：①请求 `POST /sync/sessions`，带 Bearer；②body 里 `startedAt` 为毫秒整数、`categoryId` 为 `null`（`NSNull`）、`spans[0].wasBlocked` 为 `true`；③响应 `{"accepted":["s1"],"rejected":[{"id":"s2","reason":"CONFLICT"}]}` 被解码。

**SyncService.swift**
```swift
import Foundation

public protocol SessionUploading: Sendable {
    func syncSessions(_ batch: [(session: SessionRecord, spans: [ActivitySpan])]) async throws -> SyncResult
}
extension APIClient: SessionUploading {}

/// 指数退避：失败 n 次后等待 min(base * 2^(n-1), cap) 秒；成功后清零。
public struct Backoff: Equatable, Sendable {
    public private(set) var failures = 0
    private let base: TimeInterval, cap: TimeInterval
    public init(base: TimeInterval = 5, cap: TimeInterval = 900) { self.base = base; self.cap = cap }
    public mutating func recordFailure() { failures += 1 }
    public mutating func recordSuccess() { failures = 0 }
    public var delay: TimeInterval { failures == 0 ? 0 : min(base * pow(2, Double(failures - 1)), cap) }
}

public enum SyncOutcome: Equatable, Sendable {
    case nothingToSync
    case synced(accepted: Int, rejected: Int)
    case failed
}

public final class SyncService: @unchecked Sendable {
    private let store: LocalStore
    private let uploader: SessionUploading
    private let batchSize: Int
    private let lock = NSLock()
    private var running = false
    private var backoff = Backoff()
    private var nextAttempt: Date = .distantPast
    private let clock: Clock

    public init(store: LocalStore, uploader: SessionUploading, clock: Clock = SystemClock(), batchSize: Int = 20) {
        self.store = store; self.uploader = uploader; self.clock = clock; self.batchSize = batchSize
    }

    /// 是否到了可以重试的时间（给定时器用）。
    public var isDue: Bool { lock.withLock { clock.now >= nextAttempt } }

    /// 上传一批待同步的 session。并发调用时后来者直接返回 .nothingToSync。
    @discardableResult
    public func flush(force: Bool = false) async -> SyncOutcome {
        let proceed: Bool = lock.withLock {
            if running || (!force && clock.now < nextAttempt) { return false }
            running = true
            return true
        }
        guard proceed else { return .nothingToSync }
        defer { lock.withLock { running = false } }

        do {
            let batch = try store.pending(limit: batchSize)
            guard !batch.isEmpty else { return .nothingToSync }
            let result = try await uploader.syncSessions(batch)
            try store.markSynced(result.accepted)
            try store.markRejected(result.rejected.map(\.id))
            lock.withLock { backoff.recordSuccess(); nextAttempt = .distantPast }
            return .synced(accepted: result.accepted.count, rejected: result.rejected.count)
        } catch {
            lock.withLock {
                backoff.recordFailure()
                nextAttempt = clock.now.addingTimeInterval(backoff.delay)
            }
            return .failed
        }
    }
}
```

**SyncServiceTests**（用 `FakeUploader`：记录收到的批次，可配置返回/抛错；`FakeClock` 若 M1 测试里已有就复用——先 `grep -n "class.*Clock" Tests`，没有则在本测试文件里定义一个可变时钟）：

1. `testUploadsPendingAndMarksAccepted`：存 2 条 pending，uploader 返回全部 accepted → store `pendingCount == 0`，outcome `.synced(2,0)`。
2. `testRejectedAreMarkedAndNotRetried`：返回 `rejected:[b]` → b 的 `syncState == .rejected`，再次 flush 返回 `.nothingToSync`。
3. `testFailureKeepsPendingAndBacksOff`：uploader 抛错 → outcome `.failed`，仍 pending；时钟前进不足 `delay` 时 `flush()` 返回 `.nothingToSync` 且 uploader 未被再次调用；前进超过后再次调用；`flush(force: true)` 无视退避。
4. `testSuccessResetsBackoff`：失败一次后成功，`isDue == true`。
5. `testBackoffDoublesAndCaps`：`Backoff` 纯值测试：`recordFailure` ×1→5，×2→10，×3→20，×10→900（封顶）；`recordSuccess` → 0。
6. `testNothingToSyncDoesNotCallUploader`。

**Step 2/4:** 先红后绿：`swift test --filter "SyncServiceTests|APIClientTests"`；全量 `swift test` 与 `swift build` 零警告。

**Step 5: 提交**
```bash
git add mac/Sources/SessionCore/API mac/Sources/SessionCore/Sync mac/Tests/SessionCoreTests
git commit -m "feat(mac): add session sync client and outbox flush with backoff

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task D5：ActivityTracker（协议注入，纯逻辑可测）

**Files:**
- Create: `mac/Sources/SessionCore/Activity/ActivityTracker.swift`
- Test: `mac/Tests/SessionCoreTests/ActivityTrackerTests.swift`

职责：每次 `sample()`（定时器每 2 秒、前台 App 切换时各调用一次）→ 读闲置秒数 → 非闲置才读前台信息 → 交给 `BlockList.decide` → 若需拦截则通知执行器并给样本打 `wasBlocked` → 喂给 `SpanBuilder` → 把关闭的 span 立即写入 `LocalStore`。

**ActivityTracker.swift**
```swift
import Foundation

public struct FrontmostInfo: Equatable, Sendable {
    public let bundleId: String?
    public let appName: String?
    public let windowTitle: String?
    public let urlHost: String?
    public init(bundleId: String?, appName: String?, windowTitle: String?, urlHost: String?) {
        self.bundleId = bundleId; self.appName = appName; self.windowTitle = windowTitle; self.urlHost = urlHost
    }
}

/// 系统采样能力的抽象：真实实现在 SessionApp（AX / AppleScript / CGEventSource）。
public protocol ActivitySampler: AnyObject {
    func idleSeconds() -> TimeInterval
    func frontmost() -> FrontmostInfo
}

/// 拦截动作的抽象：真实实现在 SessionApp（隐藏 App / 重定向标签页 / 浮层）。
public protocol BlockEnforcer: AnyObject {
    func enforce(_ decision: BlockDecision, focusTitle: String, remainingSeconds: Int)
}

public final class ActivityTracker {
    private let sampler: ActivitySampler
    private let enforcer: BlockEnforcer
    private let store: LocalStore
    private let clock: Clock
    private let blocklist: BlockList
    private let idleThreshold: TimeInterval

    private var builder: SpanBuilder?
    private var sessionId: String?
    private var title = ""
    private var endAt = Date.distantFuture

    public init(sampler: ActivitySampler, enforcer: BlockEnforcer, store: LocalStore, clock: Clock,
                blocklist: BlockList, idleThreshold: TimeInterval = 120) {
        self.sampler = sampler; self.enforcer = enforcer; self.store = store; self.clock = clock
        self.blocklist = blocklist; self.idleThreshold = idleThreshold
    }

    public var isRunning: Bool { builder != nil }

    public func start(run: FocusRun) {
        sessionId = run.id.uuidString.lowercased()
        title = run.title
        endAt = run.endAt
        builder = SpanBuilder(sessionId: sessionId!, idleThreshold: idleThreshold)
        sample()
    }

    /// 正常结束：在 endedAt 处关闭最后一个 span 并落盘。
    public func stop(at end: Date) {
        guard var b = builder else { return }
        persist(b.finish(at: end))
        builder = nil; sessionId = nil
    }

    /// 放弃：丢弃已落盘的 span，不留任何记录。
    public func discard() {
        let id = sessionId
        builder = nil; sessionId = nil
        if let id { try? store.deleteSpans(sessionId: id) }
    }

    public func sample() {
        guard var b = builder else { return }
        let now = clock.now
        let idle = sampler.idleSeconds()
        let sample: ActivitySample
        if idle >= idleThreshold {
            sample = ActivitySample(time: now, idleSeconds: idle)          // 闲置期间不读标题/URL
        } else {
            let f = sampler.frontmost()
            let decision = blocklist.decide(bundleId: f.bundleId, urlHost: f.urlHost)
            if decision != .allow {
                enforcer.enforce(decision, focusTitle: title,
                                 remainingSeconds: max(0, Int(endAt.timeIntervalSince(now).rounded(.up))))
            }
            sample = ActivitySample(time: now, idleSeconds: idle, appBundleId: f.bundleId, appName: f.appName,
                                    windowTitle: f.windowTitle, urlHost: f.urlHost, wasBlocked: decision != .allow)
        }
        persist(b.add(sample))
        builder = b
    }

    private func persist(_ spans: [ActivitySpan]) {
        // 存储失败不应打断专注；丢一个 span 比崩溃更好。
        try? store.append(spans)
    }
}
```

**测试**（`FakeSampler` 可设置 idle/front；`SpyEnforcer` 记录调用；`FakeClock` 可前进；`LocalStore(path: nil)`）：

1. `testRecordsActiveSpanAcrossSamplesAndPersistsOnStop`：start → 时钟 +2 sample ×2 → `stop(at:)`，`store.spans(sessionId:)` 得到 1 个 active span，起止正确。
2. `testIdleSampleDoesNotReadFrontmost`：sampler 的 `frontmost()` 调用计数，在 `idleSeconds=200` 时不增加；产出 `.idle` span。
3. `testBlockedAppIsEnforcedAndSpanFlagged`：blocklist 含 `com.tencent.xinWeChat`，sampler 返回该 App → `SpyEnforcer` 收到 `.hideApp`，且参数里的 `focusTitle`、`remainingSeconds` 正确；落盘的 span `wasBlocked == true`。
4. `testBlockedSiteTriggersRedirectDecision`：host `www.youtube.com` → `.redirectSite`。
5. `testDiscardRemovesPersistedSpans`：先 sample 两次并切换标题让一个 span 落盘 → `discard()` → `store.spans` 为空。
6. `testSampleAfterStopIsNoOp`：`stop` 后 `sample()` 不调用 sampler。
7. `testNoEnforcementWhenNothingMatches`：`SpyEnforcer.calls` 为空。

**Step 2/4:** 红 → 绿；全量 `swift test` 通过，`swift build` 零警告。

**Step 5: 提交**
```bash
git add mac/Sources/SessionCore/Activity/ActivityTracker.swift mac/Tests/SessionCoreTests/ActivityTrackerTests.swift
git commit -m "feat(mac): add ActivityTracker driving SpanBuilder, blocklist and local persistence

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task D6：系统适配层（需要 GUI 与系统权限，**用户手动验证**）

**Files:**（均在 `mac/Sources/SessionApp/`）
- Create: `MacActivitySampler.swift`, `MacBlockEnforcer.swift`, `BrowserScript.swift`, `Permissions.swift`, `BlockPage.swift`

这些文件调用 AX、AppleScript、NSWorkspace，无法单元测试。实现要求是"小而直白"；每个文件不超过约 100 行。

**BrowserScript.swift**——浏览器 AppleScript 读/改当前标签页
```swift
import AppKit

/// 支持的浏览器：bundle id → AppleScript 里的应用名与"当前标签页"写法。
enum Browser {
    struct Spec { let appName: String; let tab: String }   // tab 例如 "current tab of front window"
    static let specs: [String: Spec] = [
        "com.apple.Safari": .init(appName: "Safari", tab: "current tab of front window"),
        "com.google.Chrome": .init(appName: "Google Chrome", tab: "active tab of front window"),
        "company.thebrowser.Browser": .init(appName: "Arc", tab: "active tab of front window"),
        "com.microsoft.edgemac": .init(appName: "Microsoft Edge", tab: "active tab of front window"),
        "com.brave.Browser": .init(appName: "Brave Browser", tab: "active tab of front window"),
    ]

    /// 返回当前标签页 URL；无权限/无窗口时返回 nil。必须在主线程调用（NSAppleScript 非线程安全）。
    static func currentURL(bundleId: String) -> URL? {
        guard let spec = specs[bundleId] else { return nil }
        let script = NSAppleScript(source: "tell application \"\(spec.appName)\" to return URL of \(spec.tab)")
        var error: NSDictionary?
        guard let out = script?.executeAndReturnError(&error).stringValue, error == nil else { return nil }
        return URL(string: out)
    }

    @discardableResult
    static func redirect(bundleId: String, to url: URL) -> Bool {
        guard let spec = specs[bundleId] else { return false }
        let src = "tell application \"\(spec.appName)\" to set URL of \(spec.tab) to \"\(url.absoluteString)\""
        var error: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&error)
        return error == nil
    }
}
```

**BlockPage.swift**——本地拦截页（写到 Application Support，避免依赖后端）
```swift
import Foundation

enum BlockPage {
    static func url() -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("Session", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("blocked.html")
        let html = """
        <!doctype html><meta charset="utf-8"><title>专注中</title>
        <body style="font:20px -apple-system;display:grid;place-items:center;height:100vh;margin:0;color:#444">
        <div style="text-align:center"><div style="font-size:64px">🍅</div><p>正在专注，这个网站已被屏蔽。</p></div></body>
        """
        try? html.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
```

**MacActivitySampler.swift**
```swift
import AppKit
import ApplicationServices
import IOKit
import IOKit.pwr_mgt
import os
import SessionCore

final class MacActivitySampler: ActivitySampler {
    /// 距上次键鼠输入的秒数。用 IOKit HIDIdleTime，而不是 CGEventSource——后者在非 .app 的进程里
    /// 会返回系统开机时长（见 activity-clock b887f94）。若前台 App 持有"阻止显示器休眠"断言
    /// （正在播放视频/演示），超过阈值也不算闲置：此时返回 0。
    func idleSeconds() -> TimeInterval {
        let hid = Self.hidIdleSeconds()
        guard hid >= Self.assertionCheckFloor else { return hid }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           Self.holdsDisplaySleepAssertion(pid: pid) { return 0 }
        return hid
    }

    /// 只在已经接近闲置阈值时才去查电源断言，避免每 2 秒都查。
    private static let assertionCheckFloor: TimeInterval = 60

    private static func hidIdleSeconds() -> TimeInterval {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return 0 }
        return TimeInterval(prop.int64Value) / 1_000_000_000
    }

    /// IOPMCopyAssertionsByProcess 返回 { PID(CFNumber) → [断言字典] }；断言字典里 "AssertType" 为
    /// "PreventUserIdleDisplaySleep" 表示该进程在阻止显示器休眠（视频播放等）。
    private static func holdsDisplaySleepAssertion(pid: pid_t) -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        return (dict[NSNumber(value: pid)] ?? []).contains { ($0["AssertType"] as? String) == "PreventUserIdleDisplaySleep" }
    }

    func frontmost() -> FrontmostInfo {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return FrontmostInfo(bundleId: nil, appName: nil, windowTitle: nil, urlHost: nil)
        }
        let bundleId = app.bundleIdentifier
        let host = bundleId.flatMap { Browser.currentURL(bundleId: $0) }?.host?.lowercased()
        return FrontmostInfo(bundleId: bundleId, appName: app.localizedName,
                             windowTitle: Self.windowTitle(pid: app.processIdentifier), urlHost: host)
    }

    /// 需要"辅助功能"权限；没有权限时返回 nil（降级为只按 App 粒度）。
    private static func windowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        let werr = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window)
        guard werr == .success, let window else {
            // -25211 APIDisabled（未授权）、-25204 CannotComplete 等，排查权限问题时看这里。
            log.debug("AXFocusedWindow pid=\(pid) failed: \(werr.rawValue)")
            return nil
        }
        var title: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard err == .success else { log.debug("AXTitle pid=\(pid) failed: \(err.rawValue)"); return nil }
        let text = title as? String
        return (text?.isEmpty ?? true) ? nil : text   // 空标题按"没有标题"处理
    }

    private static let log = Logger(subsystem: "session", category: "sampler")
}
```

**MacBlockEnforcer.swift**——隐藏 App、重定向标签页、浮层
```swift
import AppKit
import SessionCore

final class MacBlockEnforcer: BlockEnforcer {
    private var overlay: NSPanel?
    private var overlayTimer: Timer?

    func enforce(_ decision: BlockDecision, focusTitle: String, remainingSeconds: Int) {
        switch decision {
        case .allow:
            return
        case .hideApp(let bundleId):
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).forEach { _ = $0.hide() }
        case .redirectSite:
            guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  let page = BlockPage.url() else { return }
            Browser.redirect(bundleId: bundleId, to: page)
        }
        showOverlay("正在专注：\(focusTitle)　剩余 \(AppModel.format(remainingSeconds))")
    }

    private func showOverlay(_ text: String) {
        overlayTimer?.invalidate()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: label.frame.height + 28)
        let panel = overlay ?? NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        label.textColor = .white
        label.frame.origin = NSPoint(x: 20, y: 14)
        panel.setContentSize(size)
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        panel.contentView?.addSubview(label)
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY))
        }
        panel.orderFrontRegardless()
        overlay = panel
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.overlay?.orderOut(nil)
        }
    }
}
```

**Permissions.swift**——权限状态与引导
```swift
import ApplicationServices
import AppKit

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// 弹出系统的"辅助功能"授权提示（每次启动最多触发一次）。
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
```

> 浏览器"自动化"权限由系统在首次 AppleScript 调用时自行弹窗（`NSAppleEventsUsageDescription` 只在 .app 的 Info.plist 里生效；`swift run` 的裸可执行文件由终端宿主承担授权，需要在 *系统设置 → 隐私与安全 → 自动化* 里允许终端控制浏览器）。M4 打包 .app 时再补 Info.plist 文案。

**Step：** 只做构建验证——`swift build` 零警告，`swift test` 全部通过。真实行为在 Task E1 手动验证。若 Swift 6.1 对 `AppModel.format`（`nonisolated static`）调用或 `CGEventType(rawValue: ~0)!` 报警告，按警告修复，不要用 `@preconcurrency` 之类整体压制。

**提交**
```bash
git add mac/Sources/SessionApp/MacActivitySampler.swift mac/Sources/SessionApp/MacBlockEnforcer.swift \
  mac/Sources/SessionApp/BrowserScript.swift mac/Sources/SessionApp/Permissions.swift mac/Sources/SessionApp/BlockPage.swift
git commit -m "feat(mac): add macOS sampler, block enforcer and permission helpers

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task D7：把它们接进 AppModel

**Files:**
- Modify: `mac/Sources/SessionApp/AppModel.swift`, `mac/Sources/SessionApp/SessionApp.swift`（不需要改动则跳过）

目标行为：
- 启动：打开 `LocalStore`（路径 `~/Library/Application Support/Session/session.db`，环境变量 `SESSION_DB_PATH` 可覆盖）；`pruneOrphanSpans(keeping: 当前进行中的 run id)`；若引擎恢复到 `.focusing`，直接启动 tracker。
- 开始专注（`begin` 成功后）：`tracker.start(run:)`，并开始每 2 秒 `sample()`；监听 `NSWorkspace.didActivateApplicationNotification` 立即补一次 `sample()`。
- 到点（`complete`）：`tracker.stop(at: done.endedAt)`；`store.save(SessionRecord(done))`；触发 `sync.flush()`。
- 放弃（`abandon`）：`tracker.discard()`；**不**写 session。
- 休息期间 tracker 不运行。
- 恢复路径 `engine.recovered`：直接 `store.save(SessionRecord(recovered))`（没有 tracker，spans 仅保留已落盘部分）。
- 同步：启动时、每次完成后、每 30 秒（`sync.isDue` 为真时）调用 `flush()`；`pendingCount` 发布到 `@Published var unsynced: Int` 供 UI 显示。
- 黑名单：`BlockList` = UserDefaults 键 `blocklist`（JSON）与环境变量 `SESSION_BLOCK_APPS` / `SESSION_BLOCK_DOMAINS` 合并。
- `finishedToday` 改为从 `LocalStore` 读：`@Published var todaySessions: [SessionRecord]`，每次完成/启动/同步后 `reloadToday()`。
- 辅助功能权限：专注开始时若未授权，调用一次 `Permissions.requestAccessibility()`（每次启动只提示一次）；未授权时在 `errorMessage` 之外增加 `@Published var accessibilityMissing: Bool` 供 UI 提示"仅按 App 粒度采集"。

具体改动（在现有 `AppModel` 上增量修改，保持现有公开方法签名不变）：

1. 新增属性
```swift
@Published var todaySessions: [SessionRecord] = []
@Published var unsynced = 0
@Published var accessibilityMissing = false

private let store: LocalStore?
private let tracker: ActivityTracker?
private let sync: SyncService?
private var sampleTimer: Timer?
private var syncTimer: Timer?
private var askedAccessibility = false
```

2. `init()`：在创建 `engine` 与 `api` 之后（`engine.onCompleted` 赋值之前）加入
```swift
let dbPath = env["SESSION_DB_PATH"] ?? Self.defaultDBPath()
store = try? LocalStore(path: dbPath)
if store == nil { errorMessage = "无法打开本地数据库，专注记录不会保存" }
let blocklist = Self.loadBlocklist(env: env)
tracker = store.map {
    ActivityTracker(sampler: MacActivitySampler(), enforcer: MacBlockEnforcer(), store: $0,
                    clock: SystemClock(), blocklist: blocklist)
}
sync = zip(store, api).map { SyncService(store: $0, uploader: $1) }
```
（`zip` 对两个 Optional 的写法若不通过编译，用 `if let` 展开赋值。）

3. 启动恢复（`init()` 里，原来的 `if let recovered = engine.recovered { complete(recovered) }` 保留；在它之后）：
```swift
var activeId: String?
if case .focusing(let run) = engine.phase { activeId = run.id.uuidString.lowercased(); tracker?.start(run: run); startSampling() }
try? store?.pruneOrphanSpans(keeping: activeId)
reloadToday()
Task { await flushSync() }
```
注意：`tracker?.start` 里的 `sessionId` 取自 `run.id`，与 `activeId` 一致。

4. 采样与同步定时器
```swift
private func startSampling() {
    sampleTimer?.invalidate()
    let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tracker?.sample() }
    }
    RunLoop.main.add(t, forMode: .common)
    sampleTimer = t
    if !askedAccessibility && !Permissions.accessibilityGranted {
        askedAccessibility = true
        Permissions.requestAccessibility()
    }
    accessibilityMissing = !Permissions.accessibilityGranted
}

private func stopSampling() { sampleTimer?.invalidate(); sampleTimer = nil }

private func flushSync() async {
    guard let sync else { return }
    await sync.flush()
    unsynced = (try? store?.pendingCount()) ?? 0
    reloadToday()
}
```
`init()` 里再加一个 30 秒的 `syncTimer`：`if sync?.isDue == true { Task { await flushSync() } }`；以及
```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { [weak self] _ in Task { @MainActor in self?.tracker?.sample() } }
```
`deinit` 里 invalidate 两个定时器。

5. 开始/放弃/完成
```swift
// begin(_:) 成功分支里，pendingCompletion = nil 之后：
if case .focusing(let run) = engine.phase { tracker?.start(run: run); startSampling() }

// abandon()：
func abandon() {
    tracker?.discard(); stopSampling()
    engine.abandon(); objectWillChange.send()
}

// complete(_:)：替换原实现
private func complete(_ done: CompletedFocus) {
    tracker?.stop(at: done.endedAt); stopSampling()
    try? store?.save(SessionRecord(done))
    pendingCompletion = done
    reloadToday()
    objectWillChange.send()
    Task { await flushSync() }
}
```
注意 `complete` 里 **不要**再 `finishedToday.append`；删除 `finishedToday` 属性，并把 `TodayView` / `MenuPanel` 中对它的引用改为 `todaySessions`（见 Task D8）。

6. 辅助方法
```swift
private func reloadToday() {
    let start = Calendar.current.startOfDay(for: Date())
    let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    todaySessions = (try? store?.sessions(from: start, to: end)) ?? []
}

private static func defaultDBPath() -> String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Session/session.db").path
}

private static func loadBlocklist(env: [String: String]) -> BlockList {
    let fromEnv = BlockList(appsCSV: env["SESSION_BLOCK_APPS"] ?? "", domainsCSV: env["SESSION_BLOCK_DOMAINS"] ?? "")
    let saved = UserDefaults.standard.data(forKey: "blocklist")
        .flatMap { try? JSONDecoder().decode(BlockList.self, from: $0) } ?? BlockList()
    return saved.merged(with: fromEnv)
}
```

**验证：** `swift build` 零警告，`swift test` 全绿（28 + 新增）。此任务不新增单元测试（接线代码；逻辑都已在 D1–D5 测过）。**提交**
```bash
git add mac/Sources/SessionApp/AppModel.swift
git commit -m "feat(mac): wire tracker, blocker, local store and sync into AppModel

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```
（此时 `TodayView` 仍引用 `finishedToday` 的话构建会失败——与 D8 合并成一次提交也可以，但先尽量让每步可构建：临时在 `AppModel` 保留 `var finishedToday: [CompletedFocus] { [] }` 兼容属性，D8 里删除。）

---

### Task D8：Today 页简化时间轴

**Files:**
- Create: `mac/Sources/SessionApp/TimelineView.swift`
- Create (pure, testable): `mac/Sources/SessionCore/Timeline/TimelineLayout.swift`
- Test: `mac/Tests/SessionCoreTests/TimelineLayoutTests.swift`
- Modify: `mac/Sources/SessionApp/TodayView.swift`, `mac/Sources/SessionApp/MenuPanel.swift`

**TimelineLayout（纯函数）**：把 session 映射为纵向坐标，供视图使用。

```swift
import Foundation

public struct TimelineBlock: Equatable, Identifiable, Sendable {
    public let id: String
    public let top: Double      // 距时间轴起点的 pt
    public let height: Double   // 至少 minHeight，保证短 session 也能点到
}

public enum TimelineLayout {
    /// 时间轴起点取最早 session 所在整点（没有 session 时取当天 9:00 或当前整点，较早者），终点取当前时间所在整点 + 1。
    public static func range(sessions: [SessionRecord], now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let dayStart = calendar.startOfDay(for: now)
        let nine = calendar.date(byAdding: .hour, value: 9, to: dayStart) ?? dayStart
        let earliest = sessions.map(\.startedAt).min() ?? min(nine, now)
        let startHour = calendar.dateInterval(of: .hour, for: min(earliest, now))?.start ?? earliest
        let endHour = calendar.dateInterval(of: .hour, for: max(now, sessions.map(\.endedAt).max() ?? now))?.end ?? now
        return (startHour, endHour)
    }

    public static func blocks(sessions: [SessionRecord], rangeStart: Date, pointsPerMinute: Double = 1.4,
                              minHeight: Double = 22) -> [TimelineBlock] {
        sessions.map { s in
            let top = s.startedAt.timeIntervalSince(rangeStart) / 60 * pointsPerMinute
            let height = max(minHeight, s.endedAt.timeIntervalSince(s.startedAt) / 60 * pointsPerMinute)
            return TimelineBlock(id: s.id, top: top, height: height)
        }
    }
}
```

**TimelineLayoutTests**：固定 `Calendar(identifier: .gregorian)` + `TimeZone(secondsFromGMT: 0)`，断言：①`range` 起点取最早 session 的整点、终点为现在所在整点 +1；②无 session 时起点不晚于 9:00 且不晚于 now 所在整点；③25 分钟 session 在 1.4pt/min 下 height = 35、top 按相对起点分钟数计算；④极短（10 秒）session 高度为 `minHeight`；⑤两个 session 的 block 顺序与输入一致。

**TimelineView.swift（SwiftUI）**：
- 左侧每个整点一行刻度（`HH:mm`），右侧用 `ZStack(alignment: .topLeading)` + `.offset(y: block.top)` 摆放色块，颜色取分类色（`AppModel.category(for:)` 的 `color` 字符串映射到 `Color`，先复用 M1 里已有的颜色映射函数，若无则写一个 `Color(todoistColor:)`，未知色回退灰色）。
- 色块显示标题、时长（分钟）；`syncState == .pending` 的右上角显示一个小云朵斜杠图标（`icloud.slash`），表示"未同步"。
- 点击色块弹出 `.popover`，显示：开始/结束时间、实际时长、活动明细（`store.spans(sessionId:)`，经 `AppModel.spans(for:)` 暴露）：每行 `HH:mm–HH:mm  App — 标题/host`，`wasBlocked` 行红色，`idle` 行灰色并显示"闲置"。无 span 时显示"没有采集到活动（可能未授权辅助功能）"。
- 当前时间画一条红色横线。
- 评估分数留空（M3）；不要渲染任何占位分数。

**AppModel 增加**（供视图读取，已在 D7 的 `store` 之上）：
```swift
func spans(for sessionId: String) -> [ActivitySpan] { (try? store?.spans(sessionId: sessionId)) ?? [] }
```

**TodayView**：右侧原来的 "时间轴将在 M3 实现" 占位替换为 `TimelineView(sessions: model.todaySessions)`；"今日：N 个番茄 · M 分钟"统计改用 `todaySessions`；`MenuPanel` 里若用到 `finishedToday` 同样替换；删除 D7 中的兼容属性。顶部状态区在 `model.unsynced > 0` 时显示"N 条未同步"，在 `model.accessibilityMissing` 且专注中显示"未授权辅助功能：仅按 App 粒度采集"。

**验证：** `swift test --filter TimelineLayoutTests` 绿；全量 `swift test`、`swift build` 零警告。视图外观在 E1 手动检查。

**提交**
```bash
git add mac/Sources/SessionCore/Timeline mac/Tests/SessionCoreTests/TimelineLayoutTests.swift \
  mac/Sources/SessionApp/TimelineView.swift mac/Sources/SessionApp/TodayView.swift \
  mac/Sources/SessionApp/MenuPanel.swift mac/Sources/SessionApp/AppModel.swift
git commit -m "feat(mac): add simplified focus-block timeline to Today view

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task D9：Mac 端处理已归档分类

**Files:**
- Modify: `mac/Sources/SessionCore/API/Models.swift`, `mac/Sources/SessionCore/API/APIClient.swift`, `mac/Sources/SessionApp/AppModel.swift`, `mac/Sources/SessionApp/TodayView.swift`
- Test: `mac/Tests/SessionCoreTests/APIClientTests.swift`

目标：选择器（开始自定义条目时选分类）不再出现已归档分类；时间轴里历史 session 仍显示分类名与颜色。

1. `Category` 增加 `public var archived: Bool`，解码时缺省为 false（后端不带 `?all=1` 时没有该字段）：
```swift
public struct Category: Codable, Equatable, Identifiable, Sendable {
    public let id: String, name: String, color: String, todoistProjectId: String?
    public let archived: Bool
    public init(id: String, name: String, color: String, todoistProjectId: String?, archived: Bool = false) { ... }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        color = try c.decode(String.self, forKey: .color)
        todoistProjectId = try c.decodeIfPresent(String.self, forKey: .todoistProjectId)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }
}
```
2. `APIClient.allCategories()`：`GET /categories?all=1`，其余同 `categories()`。
3. `APIClientTests`：①响应不带 `archived` 时解码为 false；②`allCategories()` 请求带 `all=1`，并能解码 `"archived": true`。
4. `AppModel`：新增 `@Published var allCategories: [Category]`（历史查找用）；`categories` 保持"未归档"（选择器与 `startTask` 的项目映射用）。`refresh()` 里在 `syncProjects()` 之后再 `try? await api.allCategories()` 赋值；失败不影响其余数据。`category(for:)` 改为先在 `allCategories` 里找，找不到再在 `categories` 里找。
5. 时间轴 `TimelineView` 取色与标题用 `category(for:)`（已覆盖归档分类）；类别选择器 `Picker` 用 `categories`。
6. `entries`（最近使用）里引用已归档分类的条目：保留显示，开始时分类沿用；不做额外处理。

验证：`swift test` 全绿，`swift build` 零警告。

```bash
git add mac/Sources/SessionCore/API mac/Sources/SessionApp/AppModel.swift mac/Sources/SessionApp/TodayView.swift mac/Tests/SessionCoreTests/APIClientTests.swift
git commit -m "feat(mac): hide archived categories from pickers but keep them for history

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

# Part E — 手动端到端验证（用户执行，不能交给子代理）

### Task E1：权限与真实行为走查

准备：

```bash
# 终端 1：后端（用户自己的 token 只在自己的终端里输入）
cd backend && APP_SECRET=dev-secret npm start

# 终端 2：Mac 客户端。黑名单示例：屏蔽微信与 youtube.com
cd mac && SESSION_API_TOKEN=<API token> SESSION_FOCUS_SECONDS=90 \
  SESSION_BLOCK_APPS=com.tencent.xinWeChat SESSION_BLOCK_DOMAINS=youtube.com \
  swift run SessionApp
```

首次需在 *系统设置 → 隐私与安全* 中给**运行 `swift run` 的终端**授予：辅助功能；自动化（允许控制 Safari/Chrome 等）。授权后重启客户端。

| # | 操作 | 期望 |
|---|---|---|
| 1 | 开始一个 90 秒专注，期间切换到 Xcode/编辑器/浏览器各停留一会 | 到点后 Today 时间轴出现色块；点开 popover，能看到各 App 与窗口标题的 span |
| 2 | 专注中打开浏览器访问任意网站 | span 中带 host（如 `github.com`）；没有授权自动化时只有 App 粒度，且界面有提示 |
| 3 | 专注中切到黑名单 App（微信） | App 被隐藏，屏幕中央出现"正在专注：…　剩余 mm:ss"浮层，约 2.5 秒后消失；popover 里对应 span 标红 |
| 4 | 专注中在浏览器打开 youtube.com | 标签页被重定向到本地"专注中"拦截页；对应 span 标红 |
| 5 | 专注中 2 分钟以上不碰键鼠（把 `SESSION_FOCUS_SECONDS` 设为 240 测） | 时间轴 popover 中出现灰色"闲置"段，起点约为最后一次输入时间；计时与 session 时长不受影响 |
| 6 | 专注中放弃 | 时间轴无新增色块；`sqlite3 ~/Library/Application\ Support/Session/session.db "select count(*) from spans"` 不包含该次 span |
| 7 | 停掉后端，完成一次专注 | 色块带"未同步"图标，状态区显示"1 条未同步"；重新启动后端后最多 30 秒内自动同步，图标消失 |
| 8 | 同步后检查后端库 | `sqlite3 backend/data/session.db "select title_snapshot, actual_seconds from sessions; select count(*) from activity_spans"` 有记录；重复重启客户端不产生重复行 |
| 9 | 专注中强制退出客户端再启动（未到点） | 恢复到进行中的专注并继续采集；到点后正常完成 |
| 10 | 专注中合上屏幕睡眠 1 分钟以上再打开 | 睡眠期间记为一个闲置 span；计时仍以时间戳为准 |
| 11 | 休息期间切换 App | 不产生 span，不触发拦截 |
| 12 | 专注中频繁切换 App | 新 span 的 App 随切换及时更新（不是停在旧 App）；若出现陈旧值，按 0.3 节改用 `lsappinfo` |
| 13 | 专注中全屏播放视频 5 分钟不碰键鼠 | 不出现闲置段（前台 App 持有阻止休眠断言）；停止播放后再不动 2 分钟才出现闲置段 |
| 14 | 在 Todoist 删除一个有过专注记录的项目，等客户端刷新 | 选择器里不再有该分类；时间轴里历史色块仍显示原分类颜色；在后端 `select archived from categories` 该行为 1，session 行仍在 |

结果写入 `docs/plans/2026-10-25-m2-verification.md` 并提交。有不对的项，把现象告诉实现者修复后重测。

---

## 完成标准（Definition of Done）

- 后端：`npm test`、`npm run typecheck` 全绿（≥ 26 + C1/C2 新增用例）。
- Mac：`swift build` 零警告；`swift test` 全绿（含 SpanBuilder、BlockList、LocalStore、SyncService、ActivityTracker、TimelineLayout、APIClient 新增用例）。
- E1 走查 11 项通过（或明确记录已知限制）。
- 所有代码按 Task 粒度提交；没有任何真实 token 进入仓库或日志。
- 整分支代码审查（`superpowers:code-reviewer`）无 Critical / Important 遗留项。

## 风险与备注

- **AX / 自动化权限**：对象是"运行 `swift run` 的终端"，不是 SessionApp 本身；M4 打包成 .app 后才会以应用身份授权。授权变更后需要重启客户端。
- **AppleScript 读 URL** 每 2 秒一次，会在主线程短暂阻塞；若 E1 发现菜单栏倒计时卡顿，把读取移到后台串行队列，并改用 `NSAppleScript` 之外的 ScriptingBridge（作为 M2 内的修复项，不推迟）。
- **Firefox** 不支持读 URL 与重定向，按 App 粒度处理。
- **闲置误判**：已用电源断言规避看视频；纯阅读长文仍可能被判为闲置，prompt 里会说明，由 M3 的 LLM 结合上下文判断。
- **窗口标题隐私**：标题会上传到后端；`url_path` 不采集。这符合"个人自用 + 自托管"的前提，若以后多用户，需要在设置里加"不上传标题"开关（M4 备选）。
- **GRDB 版本**：D3 Step 0 里用 context7 核对 API，不要凭记忆写。
