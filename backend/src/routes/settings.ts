import { eq } from 'drizzle-orm'
import { Hono } from 'hono'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { users } from '../db/schema.js'

const listItem = z.string().trim().min(1).max(200)
const dedupe = (xs: string[]) => [...new Set(xs)]

const fields = {
  focusSeconds: z.number().int().min(60).max(7200),
  idleThresholdSeconds: z.number().int().min(30).max(1800),
  blockApps: z.array(listItem).max(200).transform(dedupe),
  blockDomains: z.array(listItem.transform((d) => d.toLowerCase())).max(200).transform(dedupe),
}
/** PUT 接受部分字段；未知字段被 zod 丢弃 */
const patchSchema = z.object(fields).partial()

export type Settings = { [K in keyof typeof fields]: z.output<(typeof fields)[K]> }
export const DEFAULT_SETTINGS: Settings = { focusSeconds: 1500, idleThresholdSeconds: 120, blockApps: [], blockDomains: [] }

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
    // 读-改-写放在同一事务里，避免并发 PUT 互相覆盖
    const merged = db.transaction((tx) => {
      const row = tx.select({ settings: users.settings }).from(users).where(eq(users.id, userId)).get()
      const next = { ...(row?.settings ?? {}), ...patch.data }
      tx.update(users).set({ settings: next }).where(eq(users.id, userId)).run()
      return next
    })
    return c.json(resolve(merged))
  })

  return r
}
