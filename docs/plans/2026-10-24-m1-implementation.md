# M1 Implementation Plan — 后端骨架 + Todoist 代理 + Mac 计时器与今日页

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 后端能代理 Todoist 任务并管理分类/自定义条目；Mac 端菜单栏计时器 + 今日页，能"点任务（或输入自定义条目）开始专注"。

**Architecture:** `backend/` 是 Node + Hono + Drizzle(SQLite) 的 HTTP 服务，通过可注入的 `TodoistGateway` 接口访问 Todoist，便于测试。`mac/` 是 SwiftPM 包：`SessionCore`（计时状态机、API 客户端，可单测）+ `SessionApp`（SwiftUI `MenuBarExtra` + 主窗口）。设计依据见 `docs/plans/2026-10-24-session-clone-design.md`。

**Tech Stack:** Node 20.18.1+（本机 22）、Hono、`@hono/node-server`、Drizzle ORM + `better-sqlite3`、`@doist/todoist-sdk`（Todoist API v1）、Vitest、zod；Swift 6.1 / SwiftUI / macOS 14+ / XCTest。

**M1 明确不做（留给后续里程碑）：** session 同步与 `sessions` 表（M2）、活动采集/拦截（M2）、LLM 评估与时间轴（M3）、统计/设置页/系统通知（M4）。M1 的"完成"提示用应用内按钮，不用系统通知（SwiftPM 可执行文件没有 app bundle，`UNUserNotificationCenter` 会崩溃，M4 打包 .app 后再接）。

**约定：**
- 所有 commit message 末尾加一行：`Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`
- 先写失败测试，再写实现（TDD）。
- 工作目录均为 worktree：`.worktrees/phase1-m1`（仓库根目录下）

**API 响应约定（后端与 Mac 共用，务必一致）：**

| 路由 | 响应 |
|---|---|
| `GET /health` | `{ "ok": true }`（无需认证） |
| `GET /todoist/tasks?filter=today\|overdue` | `{ "tasks": [{ id, content, projectId, priority, dueDate: string\|null, isRecurring }] }` |
| `GET /todoist/projects` | `{ "categories": [Category] }`（同时 upsert 到 categories） |
| `GET /categories` | `{ "categories": [Category] }` |
| `POST /categories` `{name,color}` | `{ "category": Category }` |
| `GET /entries` | `{ "entries": [Entry] }`（按最近使用倒序，最多 10 条） |
| `POST /entries` `{title,categoryId}` | `{ "entry": Entry }`（同标题同分类则复用并刷新 `lastUsedAt`） |
| 错误 | `{ "error": "UNAUTHORIZED" \| "TODOIST_NOT_CONFIGURED" \| "TODOIST_AUTH" \| "BAD_REQUEST" }` |

`Category = { id, name, color, todoistProjectId: string\|null }`，`Entry = { id, title, categoryId: string\|null }`。响应里不返回时间字段（避免 Swift 解析带毫秒的 ISO 日期）。

---

## Part A — 后端

### Task A1: 后端脚手架

**Files:**
- Create: `backend/package.json`, `backend/tsconfig.json`, `backend/vitest.config.ts`, `backend/drizzle.config.ts`
- Create: `backend/src/health.test.ts`, `backend/src/app.ts`

**Step 1: 初始化并安装依赖**

```bash
mkdir -p backend && cd backend
cat > package.json <<'EOF'
{
  "name": "session-backend",
  "private": true,
  "type": "module",
  "engines": { "node": ">=20.18.1" },
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "start": "tsx src/index.ts",
    "test": "vitest run",
    "typecheck": "tsc --noEmit",
    "db:generate": "drizzle-kit generate",
    "seed": "tsx src/scripts/seed.ts"
  }
}
EOF
npm install hono @hono/node-server drizzle-orm better-sqlite3 @doist/todoist-sdk zod
npm install -D typescript tsx vitest drizzle-kit @types/better-sqlite3 @types/node
```

**Step 2: 写配置文件**

`backend/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "noEmit": true
  },
  "include": ["src", "drizzle.config.ts", "vitest.config.ts"]
}
```

`backend/vitest.config.ts`:
```ts
import { defineConfig } from 'vitest/config'

export default defineConfig({ test: { include: ['src/**/*.test.ts'] } })
```

`backend/drizzle.config.ts`:
```ts
import { defineConfig } from 'drizzle-kit'

export default defineConfig({
  dialect: 'sqlite',
  schema: './src/db/schema.ts',
  out: './drizzle',
})
```

**Step 3: 写失败测试** — `backend/src/health.test.ts`

```ts
import { expect, it } from 'vitest'
import { Hono } from 'hono'
import { createApp } from './app.js'

it('GET /health returns ok without auth', async () => {
  const app: Hono = createApp()
  const res = await app.request('/health')
  expect(res.status).toBe(200)
  expect(await res.json()).toEqual({ ok: true })
})
```

**Step 4: 运行确认失败**

Run: `cd backend && npx vitest run src/health.test.ts`
Expected: FAIL，找不到 `./app.js`。

**Step 5: 最小实现** — `backend/src/app.ts`

```ts
import { Hono } from 'hono'

export function createApp() {
  const app = new Hono()
  app.get('/health', (c) => c.json({ ok: true }))
  return app
}
```

**Step 6: 运行确认通过**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: 1 passed；tsc 无输出。

**Step 7: Commit**

```bash
git add backend/package.json backend/package-lock.json backend/tsconfig.json backend/vitest.config.ts backend/drizzle.config.ts backend/src
git commit -m "feat(backend): scaffold Hono app with health route"
```

---

### Task A2: Schema、迁移与数据库客户端

**Files:**
- Create: `backend/src/db/schema.ts`, `backend/src/db/client.ts`, `backend/src/db/client.test.ts`
- Generate: `backend/drizzle/`

**Step 1: 写 schema** — `backend/src/db/schema.ts`

```ts
import { integer, sqliteTable, text, uniqueIndex } from 'drizzle-orm/sqlite-core'

export const users = sqliteTable('users', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  apiTokenHash: text('api_token_hash').notNull().unique(),
  todoistTokenEnc: text('todoist_token_enc'),
  settings: text('settings', { mode: 'json' })
    .$type<Record<string, unknown>>()
    .notNull()
    .$defaultFn(() => ({})),
  createdAt: integer('created_at', { mode: 'timestamp' }).notNull(),
})

export const categories = sqliteTable(
  'categories',
  {
    id: text('id').primaryKey(),
    userId: text('user_id').notNull().references(() => users.id),
    todoistProjectId: text('todoist_project_id'),
    name: text('name').notNull(),
    color: text('color').notNull(),
    archived: integer('archived', { mode: 'boolean' }).notNull().default(false),
  },
  (t) => [uniqueIndex('categories_user_project').on(t.userId, t.todoistProjectId)],
)

export const entries = sqliteTable('entries', {
  id: text('id').primaryKey(),
  userId: text('user_id').notNull().references(() => users.id),
  title: text('title').notNull(),
  categoryId: text('category_id').references(() => categories.id),
  lastUsedAt: integer('last_used_at', { mode: 'timestamp' }).notNull(),
})

export type User = typeof users.$inferSelect
export type Category = typeof categories.$inferSelect
export type Entry = typeof entries.$inferSelect
```

`todoist_project_id` 允许为 NULL；SQLite 唯一索引视 NULL 互不相等，所以自定义分类可以有多个。

**Step 2: 生成迁移**

Run: `cd backend && npx drizzle-kit generate`
Expected: 生成 `backend/drizzle/` 目录，里面有包含 3 张表 `CREATE TABLE` 的 SQL。

**Step 3: 写失败测试** — `backend/src/db/client.test.ts`

```ts
import { expect, it } from 'vitest'
import { createDb } from './client.js'
import { users } from './schema.js'

it('createDb applies migrations and supports inserts', () => {
  const db = createDb(':memory:')
  db.insert(users).values({ id: 'u1', name: 'me', apiTokenHash: 'h', createdAt: new Date() }).run()
  const row = db.select().from(users).get()
  expect(row?.name).toBe('me')
  expect(row?.settings).toEqual({})
})
```

**Step 4: 运行确认失败**

Run: `cd backend && npx vitest run src/db/client.test.ts`
Expected: FAIL，找不到 `./client.js`。

**Step 5: 实现** — `backend/src/db/client.ts`

```ts
import Database from 'better-sqlite3'
import { drizzle } from 'drizzle-orm/better-sqlite3'
import { migrate } from 'drizzle-orm/better-sqlite3/migrator'
import * as schema from './schema.js'

export type Db = ReturnType<typeof createDb>

export function createDb(path: string) {
  const sqlite = new Database(path)
  sqlite.pragma('journal_mode = WAL')
  sqlite.pragma('foreign_keys = ON')
  const db = drizzle(sqlite, { schema })
  migrate(db, { migrationsFolder: new URL('../../drizzle', import.meta.url).pathname })
  return db
}
```

**Step 6: 运行确认通过**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: 全部通过。

**Step 7: Commit**

```bash
git add backend/src/db backend/drizzle
git commit -m "feat(backend): add users/categories/entries schema and migrations"
```

---

### Task A3: Token 加密与 Bearer 认证

**Files:**
- Create: `backend/src/crypto.ts`, `backend/src/crypto.test.ts`
- Create: `backend/src/auth.ts`, `backend/src/testing.ts`, `backend/src/auth.test.ts`
- Modify: `backend/src/app.ts`

**Step 1: 写失败测试** — `backend/src/crypto.test.ts`

```ts
import { expect, it } from 'vitest'
import { decrypt, encrypt, hashToken } from './crypto.js'

it('encrypt/decrypt round-trips', () => {
  const enc = encrypt('todoist-secret', 'app-secret')
  expect(enc).not.toContain('todoist-secret')
  expect(decrypt(enc, 'app-secret')).toBe('todoist-secret')
})

it('decrypt fails with the wrong secret', () => {
  const enc = encrypt('x', 'right')
  expect(() => decrypt(enc, 'wrong')).toThrow()
})

it('hashToken is deterministic', () => {
  expect(hashToken('a')).toBe(hashToken('a'))
  expect(hashToken('a')).not.toBe(hashToken('b'))
})
```

**Step 2: 运行确认失败**

Run: `cd backend && npx vitest run src/crypto.test.ts`
Expected: FAIL（模块不存在）。

**Step 3: 实现** — `backend/src/crypto.ts`

```ts
import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto'

const keyOf = (secret: string) => createHash('sha256').update(secret).digest()

export const hashToken = (token: string) => createHash('sha256').update(token).digest('hex')

/** AES-256-GCM；输出 base64(iv | tag | ciphertext)。 */
export function encrypt(plain: string, secret: string): string {
  const iv = randomBytes(12)
  const cipher = createCipheriv('aes-256-gcm', keyOf(secret), iv)
  const ct = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()])
  return Buffer.concat([iv, cipher.getAuthTag(), ct]).toString('base64')
}

export function decrypt(enc: string, secret: string): string {
  const buf = Buffer.from(enc, 'base64')
  const decipher = createDecipheriv('aes-256-gcm', keyOf(secret), buf.subarray(0, 12))
  decipher.setAuthTag(buf.subarray(12, 28))
  return Buffer.concat([decipher.update(buf.subarray(28)), decipher.final()]).toString('utf8')
}
```

**Step 4: 运行确认通过**

Run: `cd backend && npx vitest run src/crypto.test.ts`
Expected: 3 passed。

**Step 5: 写失败测试** — `backend/src/auth.test.ts`，同时建测试辅助 `backend/src/testing.ts`

`backend/src/testing.ts`（后续所有路由测试复用）:
```ts
import { createApp } from './app.js'
import { encrypt, hashToken } from './crypto.js'
import { createDb } from './db/client.js'
import { users } from './db/schema.js'
import type { TodoistGateway } from './todoist/gateway.js'

export const TEST_SECRET = 'test-secret'
export const TEST_TOKEN = 'test-token'
export const authHeader = { Authorization: `Bearer ${TEST_TOKEN}` }

export function makeTestApp(opts: { gateway?: TodoistGateway; todoistConfigured?: boolean; now?: () => number } = {}) {
  const db = createDb(':memory:')
  db.insert(users)
    .values({
      id: 'u1',
      name: 'me',
      apiTokenHash: hashToken(TEST_TOKEN),
      todoistTokenEnc: opts.todoistConfigured === false ? null : encrypt('todoist-token', TEST_SECRET),
      createdAt: new Date(),
    })
    .run()
  const gateway = opts.gateway ?? { tasks: async () => [], projects: async () => [] }
  const app = createApp({ db, makeGateway: () => gateway, secret: TEST_SECRET, now: opts.now })
  return { app, db, gateway }
}
```

`backend/src/auth.test.ts`:
```ts
import { expect, it } from 'vitest'
import { authHeader, makeTestApp } from './testing.js'

it('rejects requests without a bearer token', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/categories')
  expect(res.status).toBe(401)
  expect(await res.json()).toEqual({ error: 'UNAUTHORIZED' })
})

it('rejects an unknown token', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/categories', { headers: { Authorization: 'Bearer nope' } })
  expect(res.status).toBe(401)
})

it('accepts a valid token', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/categories', { headers: authHeader })
  expect(res.status).toBe(200)
})

it('health stays public', async () => {
  const { app } = makeTestApp()
  expect((await app.request('/health')).status).toBe(200)
})
```

**Step 6: 运行确认失败**

Run: `cd backend && npx vitest run src/auth.test.ts`
Expected: FAIL（`./todoist/gateway.js`、`createApp` 签名、`/categories` 都还没有）。这会在 A4/A5 补齐；本任务先实现认证，并在最后统一让 `auth.test.ts` 变绿。

**Step 7: 实现认证** — `backend/src/auth.ts`

```ts
import { eq } from 'drizzle-orm'
import type { MiddlewareHandler } from 'hono'
import { hashToken } from './crypto.js'
import type { Db } from './db/client.js'
import { users, type User } from './db/schema.js'

export type AppEnv = { Variables: { user: User } }

export function auth(db: Db): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const match = /^Bearer (.+)$/.exec(c.req.header('Authorization') ?? '')
    const user = match?.[1]
      ? db.select().from(users).where(eq(users.apiTokenHash, hashToken(match[1]))).get()
      : undefined
    if (!user) return c.json({ error: 'UNAUTHORIZED' }, 401)
    c.set('user', user)
    await next()
  }
}
```

**Step 8: Commit（auth.test 暂时仍红，在 A5 之后变绿）**

```bash
git add backend/src/crypto.ts backend/src/crypto.test.ts backend/src/auth.ts backend/src/testing.ts backend/src/auth.test.ts
git commit -m "feat(backend): add token encryption and bearer auth middleware"
```

---

### Task A4: Todoist 网关与代理路由

**Files:**
- Create: `backend/src/todoist/gateway.ts`, `backend/src/todoist/sdk.ts`, `backend/src/todoist/cache.ts`, `backend/src/todoist/cache.test.ts`
- Create: `backend/src/routes/todoist.ts`, `backend/src/routes/todoist.test.ts`

**Step 1: 定义网关接口** — `backend/src/todoist/gateway.ts`

```ts
export interface TodoistTask {
  id: string
  content: string
  projectId: string
  priority: number
  dueDate: string | null
  isRecurring: boolean
}

export interface TodoistProject {
  id: string
  name: string
  color: string
}

export interface TodoistGateway {
  tasks(query: string): Promise<TodoistTask[]>
  projects(): Promise<TodoistProject[]>
}

export class TodoistAuthError extends Error {
  constructor() {
    super('Todoist rejected the token')
  }
}
```

**Step 2: 写失败测试** — `backend/src/todoist/cache.test.ts`

```ts
import { expect, it } from 'vitest'
import { TtlCache } from './cache.js'

it('returns the cached value within the ttl and refetches after', async () => {
  let t = 0
  let calls = 0
  const cache = new TtlCache<number>(60_000, () => t)
  const load = async () => ++calls

  expect(await cache.get('k', load)).toBe(1)
  t = 59_999
  expect(await cache.get('k', load)).toBe(1)
  t = 60_000
  expect(await cache.get('k', load)).toBe(2)
})

it('keeps keys independent', async () => {
  const cache = new TtlCache<string>(1000, () => 0)
  expect(await cache.get('a', async () => 'A')).toBe('A')
  expect(await cache.get('b', async () => 'B')).toBe('B')
})
```

**Step 3: 运行确认失败**

Run: `cd backend && npx vitest run src/todoist/cache.test.ts`
Expected: FAIL（模块不存在）。

**Step 4: 实现缓存** — `backend/src/todoist/cache.ts`

```ts
export class TtlCache<T> {
  private entries = new Map<string, { value: T; expiresAt: number }>()

  constructor(
    private ttlMs: number,
    private now: () => number = Date.now,
  ) {}

  async get(key: string, load: () => Promise<T>): Promise<T> {
    const hit = this.entries.get(key)
    if (hit && this.now() < hit.expiresAt) return hit.value
    const value = await load()
    this.entries.set(key, { value, expiresAt: this.now() + this.ttlMs })
    return value
  }
}
```

**Step 5: 运行确认通过**

Run: `cd backend && npx vitest run src/todoist/cache.test.ts`
Expected: 2 passed。

**Step 6: 实现真实网关** — `backend/src/todoist/sdk.ts`

```ts
import { TodoistApi } from '@doist/todoist-sdk'
import { TodoistAuthError, type TodoistGateway } from './gateway.js'

function mapError(e: unknown): never {
  const status = (e as { httpStatusCode?: number }).httpStatusCode
  if (status === 401 || status === 403) throw new TodoistAuthError()
  throw e
}

export function createTodoistGateway(token: string): TodoistGateway {
  const api = new TodoistApi(token)
  return {
    async tasks(query) {
      try {
        const out = []
        let cursor: string | null = null
        do {
          const page = await api.getTasksByFilter({ query, cursor, limit: 200 })
          for (const t of page.results) {
            out.push({
              id: t.id,
              content: t.content,
              projectId: t.projectId,
              priority: t.priority,
              dueDate: t.due?.date ?? null,
              isRecurring: t.due?.isRecurring ?? false,
            })
          }
          cursor = page.nextCursor
        } while (cursor)
        return out
      } catch (e) {
        return mapError(e)
      }
    },
    async projects() {
      try {
        const out = []
        let cursor: string | null = null
        do {
          const page = await api.getProjects({ cursor, limit: 200 })
          for (const p of page.results) out.push({ id: p.id, name: p.name, color: p.color })
          cursor = page.nextCursor
        } while (cursor)
        return out
      } catch (e) {
        return mapError(e)
      }
    },
  }
}
```

注意：SDK 的 `getTasksByFilter` / `getProjects` 参数类型、`color` 字段名以安装版本的类型为准。运行 `npx tsc --noEmit`，若有类型报错就按实际类型调整（例如 `color` 的位置、`cursor` 是否允许 `null`），不要用 `any` 糊过去。

**Step 7: 写失败测试** — `backend/src/routes/todoist.test.ts`

```ts
import { expect, it, vi } from 'vitest'
import { TodoistAuthError, type TodoistGateway } from '../todoist/gateway.js'
import { authHeader, makeTestApp } from '../testing.js'
import { categories } from '../db/schema.js'

const task = { id: 't1', content: '写周报', projectId: 'p1', priority: 4, dueDate: '2026-10-24', isRecurring: false }

function gatewayWith(overrides: Partial<TodoistGateway> = {}): TodoistGateway {
  return {
    tasks: vi.fn(async () => [task]),
    projects: vi.fn(async () => [{ id: 'p1', name: 'Work', color: 'blue' }]),
    ...overrides,
  }
}

it('returns tasks; filter=today also includes overdue', async () => {
  const gateway = gatewayWith()
  const { app } = makeTestApp({ gateway })
  const res = await app.request('/todoist/tasks?filter=today', { headers: authHeader })
  expect(res.status).toBe(200)
  expect(await res.json()).toEqual({ tasks: [task] })
  expect(gateway.tasks).toHaveBeenCalledWith('today | overdue')
})

it('filter=overdue queries overdue only', async () => {
  const gateway = gatewayWith()
  const { app } = makeTestApp({ gateway })
  await app.request('/todoist/tasks?filter=overdue', { headers: authHeader })
  expect(gateway.tasks).toHaveBeenCalledWith('overdue')
})

it('rejects an unknown filter', async () => {
  const { app } = makeTestApp({ gateway: gatewayWith() })
  const res = await app.request('/todoist/tasks?filter=weird', { headers: authHeader })
  expect(res.status).toBe(400)
  expect(await res.json()).toEqual({ error: 'BAD_REQUEST' })
})

it('caches task lookups for 60 seconds', async () => {
  let t = 0
  const gateway = gatewayWith()
  const { app } = makeTestApp({ gateway, now: () => t })
  await app.request('/todoist/tasks', { headers: authHeader })
  t = 30_000
  await app.request('/todoist/tasks', { headers: authHeader })
  expect(gateway.tasks).toHaveBeenCalledTimes(1)
  t = 61_000
  await app.request('/todoist/tasks', { headers: authHeader })
  expect(gateway.tasks).toHaveBeenCalledTimes(2)
})

it('returns 409 when no Todoist token is configured', async () => {
  const { app } = makeTestApp({ todoistConfigured: false })
  const res = await app.request('/todoist/tasks', { headers: authHeader })
  expect(res.status).toBe(409)
  expect(await res.json()).toEqual({ error: 'TODOIST_NOT_CONFIGURED' })
})

it('maps a Todoist auth failure to 401 TODOIST_AUTH', async () => {
  const gateway = gatewayWith({
    tasks: async () => {
      throw new TodoistAuthError()
    },
  })
  const { app } = makeTestApp({ gateway })
  const res = await app.request('/todoist/tasks', { headers: authHeader })
  expect(res.status).toBe(401)
  expect(await res.json()).toEqual({ error: 'TODOIST_AUTH' })
})

it('projects upserts categories idempotently and picks up renames', async () => {
  let name = 'Work'
  const gateway = gatewayWith({ projects: async () => [{ id: 'p1', name, color: 'blue' }] })
  const { app, db } = makeTestApp({ gateway })

  const first = await app.request('/todoist/projects', { headers: authHeader })
  expect((await first.json()).categories).toHaveLength(1)

  name = 'Work 2'
  const second = await app.request('/todoist/projects', { headers: authHeader })
  const body = await second.json()
  expect(body.categories).toHaveLength(1)
  expect(body.categories[0]).toMatchObject({ name: 'Work 2', color: 'blue', todoistProjectId: 'p1' })
  expect(db.select().from(categories).all()).toHaveLength(1)
})
```

**Step 8: 运行确认失败**

Run: `cd backend && npx vitest run src/routes/todoist.test.ts`
Expected: FAIL（`createApp` 还不接受依赖、路由不存在）。

**Step 9: 实现路由** — `backend/src/routes/todoist.ts`

```ts
import { and, eq } from 'drizzle-orm'
import { Hono } from 'hono'
import { randomUUID } from 'node:crypto'
import type { AppEnv } from '../auth.js'
import { decrypt } from '../crypto.js'
import type { Db } from '../db/client.js'
import { categories } from '../db/schema.js'
import { TtlCache } from '../todoist/cache.js'
import { TodoistAuthError, type TodoistGateway, type TodoistTask } from '../todoist/gateway.js'

export interface TodoistRouteDeps {
  db: Db
  makeGateway: (token: string) => TodoistGateway
  secret: string
  now: () => number
}

const QUERIES: Record<string, string> = { today: 'today | overdue', overdue: 'overdue' }

export function todoistRoutes({ db, makeGateway, secret, now }: TodoistRouteDeps) {
  const r = new Hono<AppEnv>()
  const taskCache = new TtlCache<TodoistTask[]>(60_000, now)

  const gatewayFor = (enc: string | null) => (enc ? makeGateway(decrypt(enc, secret)) : null)

  r.get('/tasks', async (c) => {
    const query = QUERIES[c.req.query('filter') ?? 'today']
    if (!query) return c.json({ error: 'BAD_REQUEST' }, 400)
    const user = c.get('user')
    const gateway = gatewayFor(user.todoistTokenEnc)
    if (!gateway) return c.json({ error: 'TODOIST_NOT_CONFIGURED' }, 409)
    try {
      const tasks = await taskCache.get(`${user.id}:${query}`, () => gateway.tasks(query))
      return c.json({ tasks })
    } catch (e) {
      if (e instanceof TodoistAuthError) return c.json({ error: 'TODOIST_AUTH' }, 401)
      throw e
    }
  })

  r.get('/projects', async (c) => {
    const user = c.get('user')
    const gateway = gatewayFor(user.todoistTokenEnc)
    if (!gateway) return c.json({ error: 'TODOIST_NOT_CONFIGURED' }, 409)
    try {
      for (const p of await gateway.projects()) {
        db.insert(categories)
          .values({ id: randomUUID(), userId: user.id, todoistProjectId: p.id, name: p.name, color: p.color })
          .onConflictDoUpdate({
            target: [categories.userId, categories.todoistProjectId],
            set: { name: p.name, color: p.color },
          })
          .run()
      }
    } catch (e) {
      if (e instanceof TodoistAuthError) return c.json({ error: 'TODOIST_AUTH' }, 401)
      throw e
    }
    const rows = db
      .select()
      .from(categories)
      .where(and(eq(categories.userId, user.id), eq(categories.archived, false)))
      .all()
    return c.json({ categories: rows.map(toCategoryDto) })
  })

  return r
}

export const toCategoryDto = (c: typeof categories.$inferSelect) => ({
  id: c.id,
  name: c.name,
  color: c.color,
  todoistProjectId: c.todoistProjectId,
})
```

**Step 10: 在 `app.ts` 挂载**（同时把 `createApp` 改成接收依赖；A5 会再加 categories/entries）

```ts
import { Hono } from 'hono'
import { auth, type AppEnv } from './auth.js'
import type { Db } from './db/client.js'
import { todoistRoutes } from './routes/todoist.js'
import type { TodoistGateway } from './todoist/gateway.js'

export interface AppDeps {
  db: Db
  makeGateway: (token: string) => TodoistGateway
  secret: string
  now?: () => number
}

export function createApp(deps: AppDeps) {
  const now = deps.now ?? Date.now
  const app = new Hono()
  app.get('/health', (c) => c.json({ ok: true }))

  const api = new Hono<AppEnv>()
  api.use('*', auth(deps.db))
  api.route('/todoist', todoistRoutes({ ...deps, now }))
  app.route('/', api)
  return app
}
```

同步更新 A1 的 `health.test.ts`，改成用 `makeTestApp()`：

```ts
import { expect, it } from 'vitest'
import { makeTestApp } from './testing.js'

it('GET /health returns ok without auth', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/health')
  expect(res.status).toBe(200)
  expect(await res.json()).toEqual({ ok: true })
})
```

**Step 11: 运行确认通过**

Run: `cd backend && npx vitest run src/todoist src/routes src/health.test.ts && npx tsc --noEmit`
Expected: 全部通过（`auth.test.ts` 的 `/categories` 仍 404，等 A5）。

**Step 12: Commit**

```bash
git add backend/src
git commit -m "feat(backend): proxy Todoist tasks and projects with cache and error mapping"
```

---

### Task A5: 分类与自定义条目路由

**Files:**
- Create: `backend/src/routes/categories.ts`, `backend/src/routes/entries.ts`, `backend/src/routes/entries.test.ts`
- Modify: `backend/src/app.ts`

**Step 1: 写失败测试** — `backend/src/routes/entries.test.ts`

```ts
import { expect, it } from 'vitest'
import { authHeader, makeTestApp } from '../testing.js'

const json = (body: unknown) => ({
  method: 'POST',
  headers: { ...authHeader, 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
})

it('creates a custom category', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/categories', json({ name: '阅读', color: 'green' }))
  expect(res.status).toBe(200)
  const { category } = await res.json()
  expect(category).toMatchObject({ name: '阅读', color: 'green', todoistProjectId: null })

  const list = await (await app.request('/categories', { headers: authHeader })).json()
  expect(list.categories).toHaveLength(1)
})

it('rejects an invalid category body', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/categories', json({ name: '' }))
  expect(res.status).toBe(400)
})

it('creates an entry and lists it', async () => {
  const { app } = makeTestApp()
  const { category } = await (await app.request('/categories', json({ name: 'c', color: 'red' }))).json()
  const res = await app.request('/entries', json({ title: '读论文', categoryId: category.id }))
  const { entry } = await res.json()
  expect(entry).toMatchObject({ title: '读论文', categoryId: category.id })

  const list = await (await app.request('/entries', { headers: authHeader })).json()
  expect(list.entries).toEqual([entry])
})

it('reuses an entry with the same title and category and moves it to the top', async () => {
  let t = 1_000
  const { app } = makeTestApp({ now: () => t })
  const a = (await (await app.request('/entries', json({ title: 'A', categoryId: null }))).json()).entry
  t = 2_000
  await app.request('/entries', json({ title: 'B', categoryId: null }))
  t = 3_000
  const again = (await (await app.request('/entries', json({ title: 'A', categoryId: null }))).json()).entry
  expect(again.id).toBe(a.id)

  const list = await (await app.request('/entries', { headers: authHeader })).json()
  expect(list.entries.map((e: { title: string }) => e.title)).toEqual(['A', 'B'])
})

it('rejects an entry referencing a category that does not exist', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/entries', json({ title: 'x', categoryId: 'missing' }))
  expect(res.status).toBe(400)
})
```

**Step 2: 运行确认失败**

Run: `cd backend && npx vitest run src/routes/entries.test.ts src/auth.test.ts`
Expected: FAIL（路由不存在，返回 404）。

**Step 3: 实现分类路由** — `backend/src/routes/categories.ts`

```ts
import { and, eq } from 'drizzle-orm'
import { Hono } from 'hono'
import { randomUUID } from 'node:crypto'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { categories } from '../db/schema.js'
import { toCategoryDto } from './todoist.js'

const body = z.object({ name: z.string().trim().min(1), color: z.string().min(1) })

export function categoryRoutes(db: Db) {
  const r = new Hono<AppEnv>()

  r.get('/', (c) => {
    const rows = db
      .select()
      .from(categories)
      .where(and(eq(categories.userId, c.get('user').id), eq(categories.archived, false)))
      .all()
    return c.json({ categories: rows.map(toCategoryDto) })
  })

  r.post('/', async (c) => {
    const parsed = body.safeParse(await c.req.json().catch(() => null))
    if (!parsed.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const row = { id: randomUUID(), userId: c.get('user').id, todoistProjectId: null, ...parsed.data }
    db.insert(categories).values(row).run()
    return c.json({ category: toCategoryDto({ ...row, archived: false }) })
  })

  return r
}
```

**Step 4: 实现条目路由** — `backend/src/routes/entries.ts`

```ts
import { and, desc, eq, isNull } from 'drizzle-orm'
import { Hono } from 'hono'
import { randomUUID } from 'node:crypto'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { categories, entries, type Entry } from '../db/schema.js'

const body = z.object({ title: z.string().trim().min(1), categoryId: z.string().nullable() })

const toDto = (e: Entry) => ({ id: e.id, title: e.title, categoryId: e.categoryId })

export function entryRoutes(db: Db, now: () => number) {
  const r = new Hono<AppEnv>()

  r.get('/', (c) => {
    const rows = db
      .select()
      .from(entries)
      .where(eq(entries.userId, c.get('user').id))
      .orderBy(desc(entries.lastUsedAt))
      .limit(10)
      .all()
    return c.json({ entries: rows.map(toDto) })
  })

  r.post('/', async (c) => {
    const parsed = body.safeParse(await c.req.json().catch(() => null))
    if (!parsed.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const userId = c.get('user').id
    const { title, categoryId } = parsed.data

    if (categoryId) {
      const owned = db
        .select()
        .from(categories)
        .where(and(eq(categories.id, categoryId), eq(categories.userId, userId)))
        .get()
      if (!owned) return c.json({ error: 'BAD_REQUEST' }, 400)
    }

    const lastUsedAt = new Date(now())
    const existing = db
      .select()
      .from(entries)
      .where(
        and(
          eq(entries.userId, userId),
          eq(entries.title, title),
          categoryId ? eq(entries.categoryId, categoryId) : isNull(entries.categoryId),
        ),
      )
      .get()

    if (existing) {
      db.update(entries).set({ lastUsedAt }).where(eq(entries.id, existing.id)).run()
      return c.json({ entry: toDto(existing) })
    }
    const row = { id: randomUUID(), userId, title, categoryId, lastUsedAt }
    db.insert(entries).values(row).run()
    return c.json({ entry: toDto(row) })
  })

  return r
}
```

**Step 5: 在 `app.ts` 挂载**

在 `api.route('/todoist', ...)` 之后加：
```ts
  api.route('/categories', categoryRoutes(deps.db))
  api.route('/entries', entryRoutes(deps.db, now))
```
并在文件顶部加对应的 import。

**Step 6: 运行全部测试**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: 全部通过，包括 `auth.test.ts` 的 4 个用例。

**Step 7: Commit**

```bash
git add backend/src
git commit -m "feat(backend): add category and custom entry routes"
```

---

### Task A6: 入口、种子脚本与 Docker

**Files:**
- Create: `backend/src/index.ts`, `backend/src/scripts/seed.ts`, `backend/Dockerfile`, `docker-compose.yml`, `backend/.env.example`

**Step 1: 入口** — `backend/src/index.ts`

```ts
import { serve } from '@hono/node-server'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { createApp } from './app.js'
import { createDb } from './db/client.js'
import { createTodoistGateway } from './todoist/sdk.js'

const secret = process.env.APP_SECRET
if (!secret) throw new Error('APP_SECRET is required')

const dbPath = process.env.DB_PATH ?? './data/session.db'
mkdirSync(dirname(dbPath), { recursive: true })

const app = createApp({ db: createDb(dbPath), makeGateway: createTodoistGateway, secret })
const port = Number(process.env.PORT ?? 8787)
serve({ fetch: app.fetch, port }, () => console.log(`session-backend listening on :${port}`))
```

**Step 2: 种子脚本** — `backend/src/scripts/seed.ts`

```ts
import { randomBytes, randomUUID } from 'node:crypto'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { encrypt, hashToken } from '../crypto.js'
import { createDb } from '../db/client.js'
import { users } from '../db/schema.js'

function arg(name: string) {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 ? process.argv[i + 1] : undefined
}

const secret = process.env.APP_SECRET
const todoistToken = arg('todoist-token')
if (!secret || !todoistToken) {
  console.error('usage: APP_SECRET=... npm run seed -- --name <name> --todoist-token <token>')
  process.exit(1)
}

const dbPath = process.env.DB_PATH ?? './data/session.db'
mkdirSync(dirname(dbPath), { recursive: true })

const apiToken = randomBytes(24).toString('hex')
createDb(dbPath)
  .insert(users)
  .values({
    id: randomUUID(),
    name: arg('name') ?? 'me',
    apiTokenHash: hashToken(apiToken),
    todoistTokenEnc: encrypt(todoistToken, secret),
    createdAt: new Date(),
  })
  .run()

console.log(`API token (save it, it is shown only once):\n${apiToken}`)
```

**Step 3: Docker**

`backend/Dockerfile`:
```dockerfile
FROM node:22-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json drizzle.config.ts ./
COPY drizzle ./drizzle
COPY src ./src
ENV DB_PATH=/data/session.db
VOLUME /data
EXPOSE 8787
CMD ["npx", "tsx", "src/index.ts"]
```

`docker-compose.yml`（仓库根目录）:
```yaml
services:
  backend:
    build: ./backend
    ports:
      - "8787:8787"
    environment:
      APP_SECRET: ${APP_SECRET:?set APP_SECRET}
    volumes:
      - session-data:/data
    restart: unless-stopped
volumes:
  session-data:
```

`backend/.env.example`:
```
APP_SECRET=change-me-to-a-long-random-string
PORT=8787
DB_PATH=./data/session.db
```

**Step 4: 手动验证**

```bash
cd backend
export APP_SECRET=dev-secret
npm run seed -- --name me --todoist-token <你的 Todoist API token>
# 记下输出的 API token
npm start &
curl -s localhost:8787/health
curl -s -H "Authorization: Bearer <API token>" "localhost:8787/todoist/tasks?filter=today"
curl -s -H "Authorization: Bearer <API token>" localhost:8787/todoist/projects
```
Expected: `{"ok":true}`；tasks 返回你真实的今日/过期任务；projects 返回分类列表。验证后 `kill %1`。

> Todoist token 是用户自己的密钥，由用户在自己的终端里输入，不要写进任何被提交的文件。

**Step 5: （可选）Docker 验证**

```bash
cd .. && APP_SECRET=dev-secret docker compose up --build -d && curl -s localhost:8787/health && docker compose down
```
Expected: `{"ok":true}`。

**Step 6: Commit**

```bash
git add backend/src backend/Dockerfile backend/.env.example docker-compose.yml
git commit -m "feat(backend): add server entrypoint, seed script and docker compose"
```

---

## Part B — Mac 端

### Task B1: SwiftPM 脚手架

**Files:**
- Create: `mac/Package.swift`, `mac/Sources/SessionCore/Placeholder.swift`, `mac/Sources/SessionApp/SessionApp.swift`, `mac/Tests/SessionCoreTests/PlaceholderTests.swift`

选 SwiftPM 而不是手建 Xcode 工程：CLI 可直接 `swift build` / `swift test`，工程文件也不会进 git 冲突。M4 再用脚本把产物打成 `.app`。

**Step 1: `mac/Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Session",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SessionApp", targets: ["SessionApp"])],
    targets: [
        .target(name: "SessionCore"),
        .executableTarget(name: "SessionApp", dependencies: ["SessionCore"]),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"]),
    ]
)
```

**Step 2: 占位文件**

`mac/Sources/SessionCore/Placeholder.swift`:
```swift
public enum SessionCoreInfo {
    public static let name = "SessionCore"
}
```

`mac/Sources/SessionApp/SessionApp.swift`:
```swift
import SwiftUI
import SessionCore

@main
struct SessionApp: App {
    var body: some Scene {
        Window("Session", id: "main") {
            Text(SessionCoreInfo.name).padding()
        }
    }
}
```

`mac/Tests/SessionCoreTests/PlaceholderTests.swift`:
```swift
import XCTest
@testable import SessionCore

final class PlaceholderTests: XCTestCase {
    func testName() { XCTAssertEqual(SessionCoreInfo.name, "SessionCore") }
}
```

**Step 3: 验证**

Run: `cd mac && swift build && swift test`
Expected: 构建成功；1 test passed。

**Step 4: Commit**

```bash
git add mac/Package.swift mac/Sources mac/Tests
git commit -m "chore(mac): scaffold SwiftPM package"
```

---

### Task B2: TimerEngine 状态机（TDD）

**Files:**
- Create: `mac/Sources/SessionCore/Timer/TimerEngine.swift`, `mac/Sources/SessionCore/Timer/StateStore.swift`
- Create: `mac/Tests/SessionCoreTests/TimerEngineTests.swift`
- Delete: `mac/Sources/SessionCore/Placeholder.swift`, `mac/Tests/SessionCoreTests/PlaceholderTests.swift`（并把 `SessionApp.swift` 里的 `SessionCoreInfo` 引用换成固定文本）

**设计要点（来自设计文档 §5.1）：**
- 以结束时间戳为准，不累计 tick；`tick()` 只是"检查是否到点"，由 UI 层每秒调用。
- 状态持久化；重启后若已过结束时间，按到点完成处理，通过 `recovered` 暴露。
- 只能手动开始；专注中再次 `start` 抛错。
- 放弃 = 直接丢弃：不触发 `onCompleted`，不留痕迹。
- 完成后默认回到 `idle`；休息是可选的，`startBreak` 才进入。
- 每完成 4 个专注，`suggestedBreak` 为长休。

**Step 1: 写失败测试** — `mac/Tests/SessionCoreTests/TimerEngineTests.swift`

```swift
import XCTest
@testable import SessionCore

final class FakeClock: Clock, @unchecked Sendable {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_000_000)) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class InMemoryStateStore: StateStore {
    var saved: TimerPhase?
    var completedCount = 0
    func load() -> TimerPhase? { saved }
    func save(_ phase: TimerPhase) { saved = phase }
}

final class TimerEngineTests: XCTestCase {
    var clock: FakeClock!
    var store: InMemoryStateStore!

    override func setUp() {
        clock = FakeClock()
        store = InMemoryStateStore()
    }

    func makeEngine() -> TimerEngine { TimerEngine(clock: clock, store: store) }

    func spec(_ title: String = "写周报", seconds: Int = 1500) -> FocusSpec {
        FocusSpec(title: title, categoryId: "c1", source: .todoist, todoistTaskId: "t1", entryId: nil, plannedSeconds: seconds)
    }

    func testStartEntersFocusingWithFullRemaining() throws {
        let engine = makeEngine()
        try engine.start(spec())
        guard case .focusing(let run) = engine.phase else { return XCTFail("expected focusing") }
        XCTAssertEqual(run.title, "写周报")
        XCTAssertEqual(run.startedAt, clock.now)
        XCTAssertEqual(engine.remainingSeconds, 1500)
    }

    func testRemainingDecreasesWithClockNotTicks() throws {
        let engine = makeEngine()
        try engine.start(spec())
        clock.advance(600)
        XCTAssertEqual(engine.remainingSeconds, 900)
    }

    func testTickBeforeEndKeepsFocusing() throws {
        let engine = makeEngine()
        try engine.start(spec())
        clock.advance(1499)
        engine.tick()
        if case .focusing = engine.phase {} else { XCTFail("should still be focusing") }
    }

    func testTickAtEndCompletesAndReturnsToIdle() throws {
        let engine = makeEngine()
        var completed: [CompletedFocus] = []
        engine.onCompleted = { completed.append($0) }
        try engine.start(spec())
        clock.advance(1500)
        engine.tick()

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].actualSeconds, 1500)
        XCTAssertEqual(completed[0].endedAt, completed[0].run.endAt)
    }

    func testLateTickStillRecordsPlannedEnd() throws {
        // 合盖睡眠 10 分钟后才 tick：结束时间仍是计划结束，而不是醒来的时间。
        let engine = makeEngine()
        var completed: [CompletedFocus] = []
        engine.onCompleted = { completed.append($0) }
        try engine.start(spec())
        clock.advance(1500 + 600)
        engine.tick()
        XCTAssertEqual(completed[0].actualSeconds, 1500)
    }

    func testStartWhileFocusingThrows() throws {
        let engine = makeEngine()
        try engine.start(spec())
        XCTAssertThrowsError(try engine.start(spec("另一个"))) { error in
            XCTAssertEqual(error as? TimerError, .busy)
        }
    }

    func testAbandonDiscardsWithoutCompletion() throws {
        let engine = makeEngine()
        var completed: [CompletedFocus] = []
        engine.onCompleted = { completed.append($0) }
        try engine.start(spec())
        clock.advance(300)
        engine.abandon()

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertTrue(completed.isEmpty)
        XCTAssertEqual(engine.completedCount, 0)
        XCTAssertEqual(store.saved, .idle)
    }

    func testStateIsPersistedOnStart() throws {
        let engine = makeEngine()
        try engine.start(spec())
        XCTAssertEqual(store.saved, engine.phase)
    }

    func testRecoveryResumesRunningFocus() throws {
        try makeEngine().start(spec())
        clock.advance(400)
        let recovered = makeEngine()
        XCTAssertEqual(recovered.remainingSeconds, 1100)
        XCTAssertNil(recovered.recovered)
    }

    func testRecoveryAfterEndTimeCompletes() throws {
        try makeEngine().start(spec())
        clock.advance(2000)
        let recovered = makeEngine()
        XCTAssertEqual(recovered.phase, .idle)
        XCTAssertEqual(recovered.recovered?.run.title, "写周报")
        XCTAssertEqual(recovered.recovered?.actualSeconds, 1500)
    }

    func testBreakIsOptionalAndEndsByClock() throws {
        let engine = makeEngine()
        try engine.start(spec(seconds: 60))
        clock.advance(60)
        engine.tick()
        XCTAssertEqual(engine.phase, .idle)   // 默认不进入休息

        try engine.startBreak(.short, seconds: 300)
        XCTAssertEqual(engine.remainingSeconds, 300)
        clock.advance(300)
        engine.tick()
        XCTAssertEqual(engine.phase, .idle)
    }

    func testEndBreakEarly() throws {
        let engine = makeEngine()
        try engine.startBreak(.short, seconds: 300)
        engine.endBreak()
        XCTAssertEqual(engine.phase, .idle)
    }

    func testCannotStartFocusDuringBreak() throws {
        let engine = makeEngine()
        try engine.startBreak(.short, seconds: 300)
        XCTAssertThrowsError(try engine.start(spec())) { XCTAssertEqual($0 as? TimerError, .busy) }
    }

    func testEveryFourthCompletionSuggestsLongBreak() throws {
        let engine = makeEngine()
        for i in 1...4 {
            try engine.start(spec("t\(i)", seconds: 60))
            clock.advance(60)
            engine.tick()
            XCTAssertEqual(engine.suggestedBreak, i == 4 ? .long : .short)
        }
    }
}
```

**Step 2: 运行确认失败**

Run: `cd mac && swift test --filter TimerEngineTests`
Expected: 编译失败，`TimerEngine` / `Clock` 等未定义。

**Step 3: 实现状态存储协议** — `mac/Sources/SessionCore/Timer/StateStore.swift`

```swift
import Foundation

public protocol StateStore: AnyObject {
    func load() -> TimerPhase?
    func save(_ phase: TimerPhase)
    /// 自启动以来累计的完成数；用于"每 4 个专注建议长休"。
    var completedCount: Int { get set }
}

public final class UserDefaultsStateStore: StateStore {
    private let defaults: UserDefaults
    private let phaseKey = "timer.phase"
    private let countKey = "timer.completedCount"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> TimerPhase? {
        defaults.data(forKey: phaseKey).flatMap { try? JSONDecoder().decode(TimerPhase.self, from: $0) }
    }

    public func save(_ phase: TimerPhase) {
        if let data = try? JSONEncoder().encode(phase) { defaults.set(data, forKey: phaseKey) }
    }

    public var completedCount: Int {
        get { defaults.integer(forKey: countKey) }
        set { defaults.set(newValue, forKey: countKey) }
    }
}
```

> `completedCount` 持久化到 store，这样重启不会丢失"已完成几个"。测试里的 `InMemoryStateStore` 已有该属性。

**Step 4: 实现引擎** — `mac/Sources/SessionCore/Timer/TimerEngine.swift`

```swift
import Foundation

public protocol Clock: Sendable { var now: Date { get } }
public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public enum SessionSource: String, Codable, Sendable { case todoist, custom }
public enum BreakKind: String, Codable, Sendable { case short, long }
public enum TimerError: Error, Equatable { case busy }

/// 开始一次专注所需的信息（来自 Todoist 任务或自定义条目）。
public struct FocusSpec: Equatable, Sendable {
    public let title: String
    public let categoryId: String?
    public let source: SessionSource
    public let todoistTaskId: String?
    public let entryId: String?
    public let plannedSeconds: Int

    public init(title: String, categoryId: String?, source: SessionSource,
                todoistTaskId: String?, entryId: String?, plannedSeconds: Int) {
        self.title = title; self.categoryId = categoryId; self.source = source
        self.todoistTaskId = todoistTaskId; self.entryId = entryId; self.plannedSeconds = plannedSeconds
    }
}

public struct FocusRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let categoryId: String?
    public let source: SessionSource
    public let todoistTaskId: String?
    public let entryId: String?
    public let startedAt: Date
    public let plannedSeconds: Int
    public var endAt: Date { startedAt.addingTimeInterval(TimeInterval(plannedSeconds)) }
}

public struct CompletedFocus: Equatable, Sendable {
    public let run: FocusRun
    public let endedAt: Date
    public var actualSeconds: Int { Int(endedAt.timeIntervalSince(run.startedAt).rounded()) }
}

public enum TimerPhase: Codable, Equatable, Sendable {
    case idle
    case focusing(FocusRun)
    case breaking(kind: BreakKind, until: Date)
}

public final class TimerEngine {
    public private(set) var phase: TimerPhase
    /// 启动时发现上次的专注已经过了结束时间，在这里交给调用方入库。
    public private(set) var recovered: CompletedFocus?
    public var onCompleted: ((CompletedFocus) -> Void)?

    private let clock: Clock
    private let store: StateStore
    private let longBreakEvery: Int

    public var completedCount: Int { store.completedCount }
    public var suggestedBreak: BreakKind {
        let n = store.completedCount
        return n > 0 && n % longBreakEvery == 0 ? .long : .short
    }

    public init(clock: Clock, store: StateStore, longBreakEvery: Int = 4) {
        self.clock = clock
        self.store = store
        self.longBreakEvery = longBreakEvery
        self.phase = store.load() ?? .idle
        if case .focusing(let run) = phase, clock.now >= run.endAt {
            recovered = finish(run)
        } else if case .breaking(_, let until) = phase, clock.now >= until {
            setPhase(.idle)
        }
    }

    public var remainingSeconds: Int {
        switch phase {
        case .idle: return 0
        case .focusing(let run): return max(0, Int(run.endAt.timeIntervalSince(clock.now).rounded(.up)))
        case .breaking(_, let until): return max(0, Int(until.timeIntervalSince(clock.now).rounded(.up)))
        }
    }

    public func start(_ spec: FocusSpec) throws {
        guard phase == .idle else { throw TimerError.busy }
        setPhase(.focusing(FocusRun(
            id: UUID(), title: spec.title, categoryId: spec.categoryId, source: spec.source,
            todoistTaskId: spec.todoistTaskId, entryId: spec.entryId,
            startedAt: clock.now, plannedSeconds: spec.plannedSeconds)))
    }

    /// 放弃：直接丢弃，不触发 onCompleted，不计入统计。
    public func abandon() {
        guard case .focusing = phase else { return }
        setPhase(.idle)
    }

    public func startBreak(_ kind: BreakKind, seconds: Int) throws {
        guard phase == .idle else { throw TimerError.busy }
        setPhase(.breaking(kind: kind, until: clock.now.addingTimeInterval(TimeInterval(seconds))))
    }

    public func endBreak() {
        guard case .breaking = phase else { return }
        setPhase(.idle)
    }

    /// 由 UI 层每秒调用；只检查是否到点，不累计时间。
    public func tick() {
        switch phase {
        case .focusing(let run) where clock.now >= run.endAt:
            // 先求值再回调：`onCompleted?(finish(run))` 在回调为 nil 时会跳过参数求值，导致永远不会完成。
            let completed = finish(run)
            onCompleted?(completed)
        case .breaking(_, let until) where clock.now >= until:
            setPhase(.idle)
        default:
            break
        }
    }

    private func finish(_ run: FocusRun) -> CompletedFocus {
        store.completedCount += 1
        setPhase(.idle)
        return CompletedFocus(run: run, endedAt: run.endAt)
    }

    private func setPhase(_ new: TimerPhase) {
        phase = new
        store.save(new)
    }
}
```

**Step 5: 清理占位文件**

```bash
git rm mac/Sources/SessionCore/Placeholder.swift mac/Tests/SessionCoreTests/PlaceholderTests.swift
```
并把 `SessionApp.swift` 里的 `Text(SessionCoreInfo.name)` 换成 `Text("Session")`。

**Step 6: 运行确认通过**

Run: `cd mac && swift test`
Expected: `TimerEngineTests` 全部通过（14 个用例）。若 `testRecoveryResumesRunningFocus` 失败，检查两个引擎是否共用同一个 `store`（它们应该共用）。

**Step 7: Commit**

```bash
git add mac
git commit -m "feat(mac): add TimerEngine state machine with persistence and recovery"
```

---

### Task B3: API 模型与客户端

**Files:**
- Create: `mac/Sources/SessionCore/API/Models.swift`, `mac/Sources/SessionCore/API/APIClient.swift`
- Create: `mac/Tests/SessionCoreTests/APIClientTests.swift`

**Step 1: 写失败测试** — `mac/Tests/SessionCoreTests/APIClientTests.swift`

```swift
import XCTest
@testable import SessionCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return APIClient(baseURL: URL(string: "http://localhost:8787")!, token: "tok", session: URLSession(configuration: config))
    }

    func testTasksDecodesAndSendsBearerToken() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { req in
            captured = req
            return (200, Data(#"{"tasks":[{"id":"t1","content":"写周报","projectId":"p1","priority":4,"dueDate":"2026-10-24","isRecurring":true}]}"#.utf8))
        }
        let tasks = try await makeClient().tasks(filter: .today)
        XCTAssertEqual(tasks, [TodoistTask(id: "t1", content: "写周报", projectId: "p1", priority: 4, dueDate: "2026-10-24", isRecurring: true)])
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(captured?.url?.path, "/todoist/tasks")
        XCTAssertEqual(captured?.url?.query, "filter=today")
    }

    func testNullDueDateDecodes() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"tasks":[{"id":"t","content":"c","projectId":"p","priority":1,"dueDate":null,"isRecurring":false}]}"#.utf8))
        }
        let tasks = try await makeClient().tasks(filter: .overdue)
        XCTAssertNil(tasks[0].dueDate)
    }

    func testErrorCodeIsSurfaced() async {
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":"TODOIST_AUTH"}"#.utf8)) }
        do {
            _ = try await makeClient().tasks(filter: .today)
            XCTFail("should throw")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 401, code: "TODOIST_AUTH"))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testCreateEntryPostsJSON() async throws {
        var body: [String: Any?]?
        StubURLProtocol.handler = { req in
            let data = req.httpBody ?? req.httpBodyStream.map { s -> Data in
                s.open(); defer { s.close() }
                var d = Data(); var buf = [UInt8](repeating: 0, count: 1024)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: 1024); if n <= 0 { break }; d.append(buf, count: n) }
                return d
            }
            body = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any?]
            return (200, Data(#"{"entry":{"id":"e1","title":"读论文","categoryId":null}}"#.utf8))
        }
        let entry = try await makeClient().createEntry(title: "读论文", categoryId: nil)
        XCTAssertEqual(entry, Entry(id: "e1", title: "读论文", categoryId: nil))
        XCTAssertEqual(body?["title"] as? String, "读论文")
        XCTAssertTrue(body?.keys.contains("categoryId") == true)   // null 必须显式发送，后端要求该字段存在
    }
}
```

**Step 2: 运行确认失败**

Run: `cd mac && swift test --filter APIClientTests`
Expected: 编译失败（类型未定义）。

**Step 3: 模型** — `mac/Sources/SessionCore/API/Models.swift`

```swift
import Foundation

public struct TodoistTask: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let content: String
    public let projectId: String
    public let priority: Int
    public let dueDate: String?
    public let isRecurring: Bool

    public init(id: String, content: String, projectId: String, priority: Int, dueDate: String?, isRecurring: Bool) {
        self.id = id; self.content = content; self.projectId = projectId
        self.priority = priority; self.dueDate = dueDate; self.isRecurring = isRecurring
    }
}

public struct Category: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let color: String
    public let todoistProjectId: String?
}

public struct Entry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let categoryId: String?

    public init(id: String, title: String, categoryId: String?) {
        self.id = id; self.title = title; self.categoryId = categoryId
    }
}

public enum TaskFilter: String, Sendable { case today, overdue }
```

**Step 4: 客户端** — `mac/Sources/SessionCore/API/APIClient.swift`

```swift
import Foundation

public enum APIError: Error, Equatable {
    case server(status: Int, code: String?)
    case transport(String)
}

public final class APIClient: @unchecked Sendable {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.token = token; self.session = session
    }

    public func tasks(filter: TaskFilter) async throws -> [TodoistTask] {
        struct R: Decodable { let tasks: [TodoistTask] }
        let r: R = try await send("GET", "/todoist/tasks", query: [URLQueryItem(name: "filter", value: filter.rawValue)])
        return r.tasks
    }

    public func syncProjects() async throws -> [Category] {
        struct R: Decodable { let categories: [Category] }
        return (try await send("GET", "/todoist/projects") as R).categories
    }

    public func categories() async throws -> [Category] {
        struct R: Decodable { let categories: [Category] }
        return (try await send("GET", "/categories") as R).categories
    }

    public func entries() async throws -> [Entry] {
        struct R: Decodable { let entries: [Entry] }
        return (try await send("GET", "/entries") as R).entries
    }

    public func createEntry(title: String, categoryId: String?) async throws -> Entry {
        struct R: Decodable { let entry: Entry }
        // 手写 JSON：Codable 默认会省略 nil，而后端要求 categoryId 字段存在（可为 null）。
        let payload: [String: Any] = ["title": title, "categoryId": categoryId as Any? ?? NSNull()]
        let body = try JSONSerialization.data(withJSONObject: payload)
        return (try await send("POST", "/entries", body: body) as R).entry
    }

    private func send<T: Decodable>(_ method: String, _ path: String,
                                    query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw APIError.transport(error.localizedDescription) }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct E: Decodable { let error: String? }
            throw APIError.server(status: status, code: (try? JSONDecoder().decode(E.self, from: data))?.error)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
```

**Step 5: 运行确认通过**

Run: `cd mac && swift test`
Expected: 全部通过。若 `createEntry` 里 `categoryId as Any? ?? NSNull()` 的类型推断报错，改写为：
```swift
var payload: [String: Any] = ["title": title]
payload["categoryId"] = categoryId ?? NSNull()
```

**Step 6: Commit**

```bash
git add mac
git commit -m "feat(mac): add API models and client"
```

---

### Task B4: AppModel（应用状态）

**Files:**
- Create: `mac/Sources/SessionApp/AppModel.swift`

AppModel 是 UI 与 Core 之间唯一的粘合层：持有 `TimerEngine`、任务/分类/条目缓存，每秒 tick 一次。它不含可单测的业务规则（规则都在 `TimerEngine`），所以这里不写单测，靠 B6 手动验证。

**Step 1: 实现** — `mac/Sources/SessionApp/AppModel.swift`

```swift
import Foundation
import SwiftUI
import SessionCore

@MainActor
final class AppModel: ObservableObject {
    @Published var tasks: [TodoistTask] = []
    @Published var categories: [Category] = []
    @Published var entries: [Entry] = []
    @Published var pendingCompletion: CompletedFocus?
    @Published var finishedToday: [CompletedFocus] = []
    @Published var errorMessage: String?

    let engine: TimerEngine
    private let api: APIClient?
    private var ticker: Timer?

    /// 默认 25 分钟；开发时可用环境变量 SESSION_FOCUS_SECONDS=10 快速走完整流程。
    private let focusSeconds = Int(ProcessInfo.processInfo.environment["SESSION_FOCUS_SECONDS"] ?? "") ?? 25 * 60

    init() {
        engine = TimerEngine(clock: SystemClock(), store: UserDefaultsStateStore())
        let env = ProcessInfo.processInfo.environment
        api = env["SESSION_API_TOKEN"].map {
            APIClient(baseURL: URL(string: env["SESSION_API_URL"] ?? "http://localhost:8787")!, token: $0)
        }
        if api == nil { errorMessage = "未配置 SESSION_API_TOKEN，无法加载 Todoist 任务（仍可使用自定义条目）" }

        if let recovered = engine.recovered { complete(recovered) }
        engine.onCompleted = { [weak self] in self?.complete($0) }

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await refresh() }
    }

    // MARK: 展示

    var menuTitle: String {
        switch engine.phase {
        case .idle: return pendingCompletion == nil ? "🍅" : "🍅 ✓"
        case .focusing: return "🍅 " + Self.format(engine.remainingSeconds)
        case .breaking: return "☕ " + Self.format(engine.remainingSeconds)
        }
    }

    var currentTitle: String? {
        if case .focusing(let run) = engine.phase { return run.title }
        return nil
    }

    static func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func category(for id: String?) -> Category? { categories.first { $0.id == id } }

    // MARK: 动作

    func startTask(_ task: TodoistTask) {
        let categoryId = categories.first { $0.todoistProjectId == task.projectId }?.id
        begin(FocusSpec(title: task.content, categoryId: categoryId, source: .todoist,
                        todoistTaskId: task.id, entryId: nil, plannedSeconds: focusSeconds))
    }

    func startEntry(_ entry: Entry) {
        begin(FocusSpec(title: entry.title, categoryId: entry.categoryId, source: .custom,
                        todoistTaskId: nil, entryId: entry.id, plannedSeconds: focusSeconds))
        remember(title: entry.title, categoryId: entry.categoryId)
    }

    func startCustom(title: String, categoryId: String?) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        begin(FocusSpec(title: title, categoryId: categoryId, source: .custom,
                        todoistTaskId: nil, entryId: nil, plannedSeconds: focusSeconds))
        remember(title: title, categoryId: categoryId)
    }

    func abandon() { engine.abandon(); objectWillChange.send() }

    func startBreak() {
        let kind = engine.suggestedBreak
        try? engine.startBreak(kind, seconds: kind == .long ? 15 * 60 : 5 * 60)
        pendingCompletion = nil
    }

    func dismissCompletion() { pendingCompletion = nil }
    func endBreak() { engine.endBreak(); objectWillChange.send() }

    func refresh() async {
        guard let api else { return }
        do {
            categories = try await api.syncProjects() + (try await api.categories()).filter { $0.todoistProjectId == nil }
            tasks = try await api.tasks(filter: .today)
            entries = try await api.entries()
            errorMessage = nil
        } catch APIError.server(_, "TODOIST_AUTH") {
            errorMessage = "Todoist token 已失效，请重新生成并运行 seed"
        } catch APIError.server(_, "TODOIST_NOT_CONFIGURED") {
            errorMessage = "后端未配置 Todoist token"
        } catch {
            errorMessage = "无法连接后端：\(error)"
        }
    }

    // MARK: 内部

    private func begin(_ spec: FocusSpec) {
        do { try engine.start(spec); pendingCompletion = nil; objectWillChange.send() }
        catch { errorMessage = "已有进行中的专注或休息" }
    }

    /// 尽力而为：后端不可用时不影响开始专注（本地优先）。
    private func remember(title: String, categoryId: String?) {
        guard let api else { return }
        Task {
            _ = try? await api.createEntry(title: title, categoryId: categoryId)
            entries = (try? await api.entries()) ?? entries
        }
    }

    private func complete(_ done: CompletedFocus) {
        finishedToday.append(done)
        pendingCompletion = done
    }

    private func tick() {
        engine.tick()
        objectWillChange.send()
    }
}
```

**Step 2: 验证编译**

Run: `cd mac && swift build`
Expected: 构建成功。

**Step 3: Commit**

```bash
git add mac/Sources/SessionApp/AppModel.swift
git commit -m "feat(mac): add AppModel gluing engine, API and UI state"
```

---

### Task B5: 菜单栏与今日页 UI

**Files:**
- Create: `mac/Sources/SessionApp/MenuPanel.swift`, `mac/Sources/SessionApp/TodayView.swift`
- Modify: `mac/Sources/SessionApp/SessionApp.swift`

**Step 1: 入口** — `mac/Sources/SessionApp/SessionApp.swift`

```swift
import SwiftUI

@main
struct SessionApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Text(model.menuTitle)
        }
        .menuBarExtraStyle(.window)

        Window("Session", id: "main") {
            TodayView().environmentObject(model).frame(minWidth: 720, minHeight: 480)
        }
    }
}
```

**Step 2: 菜单栏面板** — `mac/Sources/SessionApp/MenuPanel.swift`

```swift
import SwiftUI
import SessionCore

struct MenuPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            status
            Divider()
            if case .idle = model.engine.phase, model.pendingCompletion == nil {
                HStack {
                    TextField("快速开始：输入标题", text: $title)
                        .onSubmit(quickStart)
                    Button("开始", action: quickStart).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(model.tasks.prefix(5)) { task in
                    Button { model.startTask(task) } label: {
                        Label(task.content, systemImage: "play.fill").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Button("打开主窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder private var status: some View {
        switch model.engine.phase {
        case .focusing:
            VStack(alignment: .leading, spacing: 6) {
                Text(model.currentTitle ?? "").font(.headline).lineLimit(2)
                Text(AppModel.format(model.engine.remainingSeconds)).font(.system(size: 34, weight: .semibold, design: .monospaced))
                Button("放弃（不记录）", role: .destructive) { model.abandon() }
            }
        case .breaking:
            VStack(alignment: .leading, spacing: 6) {
                Text("休息中").font(.headline)
                Text(AppModel.format(model.engine.remainingSeconds)).font(.system(size: 34, weight: .semibold, design: .monospaced))
                Button("结束休息") { model.endBreak() }
            }
        case .idle:
            if let done = model.pendingCompletion {
                CompletionBanner(done: done)
            } else {
                Text("空闲").font(.headline)
            }
        }
        if let message = model.errorMessage {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private func quickStart() {
        model.startCustom(title: title, categoryId: nil)
        title = ""
    }
}

struct CompletionBanner: View {
    @EnvironmentObject var model: AppModel
    let done: CompletedFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("✓ 完成：\(done.run.title)").font(.headline).lineLimit(2)
            HStack {
                Button(model.engine.suggestedBreak == .long ? "开始长休 15 分钟" : "开始休息 5 分钟") { model.startBreak() }
                Button("结束") { model.dismissCompletion() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
```

**Step 3: 今日页** — `mac/Sources/SessionApp/TodayView.swift`

```swift
import SwiftUI
import SessionCore

struct TodayView: View {
    @EnvironmentObject var model: AppModel
    @State private var title = ""
    @State private var categoryId: String?

    private var idle: Bool { model.engine.phase == .idle }

    var body: some View {
        HSplitView {
            left.frame(minWidth: 340)
            right.frame(minWidth: 300)
        }
        .toolbar {
            ToolbarItem { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") } }
        }
    }

    private var left: some View {
        List {
            Section("自定义条目") {
                HStack {
                    TextField("标题", text: $title).onSubmit(start)
                    Picker("", selection: $categoryId) {
                        Text("无分类").tag(String?.none)
                        ForEach(model.categories) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden().frame(width: 120)
                    Button("开始", action: start).disabled(!idle || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !model.entries.isEmpty {
                    ForEach(model.entries) { entry in
                        row(entry.title, subtitle: model.category(for: entry.categoryId)?.name) { model.startEntry(entry) }
                    }
                }
            }
            Section("Todoist 今日 / 过期") {
                if model.tasks.isEmpty { Text("没有任务").foregroundStyle(.secondary) }
                ForEach(model.tasks) { task in
                    row(task.content, subtitle: model.categories.first { $0.todoistProjectId == task.projectId }?.name) {
                        model.startTask(task)
                    }
                }
            }
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .focusing = model.engine.phase {
                Text(model.currentTitle ?? "").font(.title2)
                Text(AppModel.format(model.engine.remainingSeconds))
                    .font(.system(size: 56, weight: .semibold, design: .monospaced))
                Button("放弃（不记录）", role: .destructive) { model.abandon() }
            }
            if let done = model.pendingCompletion { CompletionBanner(done: done) }
            Text("今日：\(model.finishedToday.count) 个番茄 · \(model.finishedToday.map(\.actualSeconds).reduce(0, +) / 60) 分钟")
                .foregroundStyle(.secondary)
            List(model.finishedToday.reversed(), id: \.run.id) { done in
                HStack {
                    Text(done.run.title)
                    Spacer()
                    Text(done.endedAt, style: .time).foregroundStyle(.secondary)
                }
            }
            Text("时间轴将在 M3 实现").font(.caption).foregroundStyle(.tertiary)
        }
        .padding()
    }

    private func row(_ text: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(text).lineLimit(2)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button(action: action) { Image(systemName: "play.fill") }.disabled(!idle)
        }
    }

    private func start() {
        model.startCustom(title: title, categoryId: categoryId)
        title = ""
    }
}
```

**Step 4: 验证编译与测试**

Run: `cd mac && swift build && swift test`
Expected: 构建成功；全部测试通过。

**Step 5: Commit**

```bash
git add mac/Sources
git commit -m "feat(mac): add menu bar panel and Today view"
```

---

### Task B6: 端到端手动验证

后端 + Mac 联调。没有自动化 UI 测试，逐项人工核对设计文档的行为约定。

**Step 1: 启动后端**

```bash
cd backend
export APP_SECRET=dev-secret
# 首次：npm run seed -- --name me --todoist-token <你的 Todoist token>，保存输出的 API token
npm start
```

**Step 2: 启动 Mac App（短时长便于验证）**

```bash
cd mac
SESSION_API_TOKEN=<API token> SESSION_FOCUS_SECONDS=20 swift run SessionApp
```

**Step 3: 逐项核对**（每项必须亲眼看到，才能声明完成）

| # | 操作 | 期望 |
|---|---|---|
| 1 | 打开后启动 | 菜单栏出现 🍅；主窗口左侧列出真实的 Todoist 今日/过期任务，分类名显示项目名 |
| 2 | 点某个任务的 ▶ | 菜单栏变 `🍅 00:20` 并倒计时；其它 ▶ 按钮变灰；**不会**有任何任务自动开始 |
| 3 | 专注中点"放弃" | 回到空闲；右侧今日统计**不增加**；没有任何记录 |
| 4 | 在输入框写标题、选分类、点开始 | 开始倒计时；该条目出现在"自定义条目"的最近列表里 |
| 5 | 等倒计时结束 | 显示 `✓ 完成` 与"开始休息 / 结束"；默认不进休息；今日统计 +1；**不会**自动开始下一个 |
| 6 | 点"开始休息" | 菜单栏变 `☕ 05:00` 倒计时（可点"结束休息"提前结束） |
| 7 | 专注中强制退出 App（`kill`）再启动 | 倒计时按真实时间继续；若已过点，则出现完成提示 |
| 8 | 关掉后端后点自定义条目开始 | 仍能开始专注（本地优先）；不弹出阻断式错误 |
| 9 | 把 `SESSION_API_TOKEN` 设成错误值再启动 | 页面上方出现红色错误提示，不崩溃 |

**Step 4: 记录结果**

把核对结果（哪些通过、哪些不通过及原因）写进 `docs/plans/2026-10-24-m1-verification.md`，不要只说"都通过"。

**Step 5: Commit**

```bash
git add docs/plans/2026-10-24-m1-verification.md
git commit -m "docs: record M1 manual verification results"
```

---

## 完成标准（M1 DoD）

- `cd backend && npx vitest run && npx tsc --noEmit` 全绿
- `cd mac && swift test` 全绿
- B6 表格 9 项全部亲测通过，结果写入 verification 文档
- 没有任何密钥进入 git（`git log -p | grep -i token` 抽查）

## 已知风险

- **Todoist SDK 类型**：A4 Step 6 的字段名（`color`、`cursor` 可空性）需以安装版本类型为准。
- **`nonisolated(unsafe)`**（B3 测试）需要 Swift 5.10+，本机 6.1 满足。
- **SwiftPM 可执行文件**不是标准 .app：菜单栏 App 能运行，但 Dock 图标、通知、开机启动都要等 M4 打包 .app 后才能做。
- **`swift run` 下 `MenuBarExtra` 的 `.window` 样式**偶发需要先点一次才显示，属已知行为，不影响功能。
