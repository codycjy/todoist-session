import { eq, sql } from 'drizzle-orm'
import { Hono } from 'hono'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { users } from '../db/schema.js'

const listItem = z.string().trim().min(1).max(200)
const dedupe = (xs: string[]) => [...new Set(xs)]

const focusSeconds = z.number().int().min(60).max(7200)
const blockApps = z.array(listItem).max(200).transform(dedupe)
const blockDomains = z.array(listItem.transform((d) => d.toLowerCase())).max(200).transform(dedupe)

/** 快捷指令名；空串视为未设置 */
const shortcutName = z.string().trim().max(200).optional().transform((s) => s || undefined)

/** 分类 profile：该分类专注时用的时长、休息时长、黑名单（可选继承全局名单再追加）和开始 / 结束快捷指令 */
const profile = z.object({
  focusSeconds,
  breakSeconds: z.number().int().min(60).max(3600),
  inheritBlocklist: z.boolean(),
  blockApps,
  blockDomains,
  startShortcut: shortcutName,
  endShortcut: shortcutName,
})

const fields = {
  focusSeconds,
  idleThresholdSeconds: z.number().int().min(30).max(1800),
  blockApps,
  blockDomains,
  /** categoryId → profile；整体替换 */
  profiles: z.record(z.string().min(1).max(64), profile)
    .refine((r) => Object.keys(r).length <= 100, 'too many profiles'),
}
/** PUT 接受部分字段；未知字段被 zod 丢弃 */
const patchSchema = z.object(fields).partial()

export type Settings = { [K in keyof typeof fields]: z.output<(typeof fields)[K]> }
export const DEFAULT_SETTINGS: Settings = { focusSeconds: 1500, idleThresholdSeconds: 120, blockApps: [], blockDomains: [], profiles: {} }

/** 逐字段读取已存值，缺失或不合法的字段回退默认值 */
function resolve(stored: Record<string, unknown>): Settings {
  const out: Record<string, unknown> = { ...DEFAULT_SETTINGS }
  for (const key of Object.keys(fields) as (keyof Settings)[]) {
    const parsed = fields[key].safeParse(stored[key])
    if (parsed.success) out[key] = parsed.data
  }
  return out as Settings
}

export function settingsRoutes(db: Db) {
  const r = new Hono<AppEnv>()

  r.get('/', (c) => c.json(resolve(c.get('user').settings)))

  r.put('/', async (c) => {
    const patch = patchSchema.safeParse(await c.req.json().catch(() => null))
    if (!patch.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const userId = c.get('user').id
    // 一条 UPDATE 里按顶层字段合并（json_set 整体替换每个字段），并发 PUT 不会互相覆盖
    const keys = Object.keys(patch.data) as (keyof Settings)[]
    if (keys.length === 0) return c.json(resolve(c.get('user').settings))
    const pairs = sql.join(keys.map((k) => sql`${'$.' + k}, json(${JSON.stringify(patch.data[k])})`), sql`, `)
    const row = await db.update(users)
      .set({ settings: sql`json_set(${users.settings}, ${pairs})` })
      .where(eq(users.id, userId)).returning({ settings: users.settings }).get()
    return c.json(resolve(row?.settings ?? {}))
  })

  return r
}
