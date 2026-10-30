import { and, eq } from 'drizzle-orm'
import { Hono } from 'hono'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { categories } from '../db/schema.js'

const name = z.string().trim().min(1).max(60)
const color = z.string().trim().min(1).max(40)
const body = z.object({ name, color })
const patch = z.object({ name, color }).partial().refine((p) => p.name !== undefined || p.color !== undefined)

export function listCategories(db: Db, userId: string, includeArchived: boolean) {
  const where = includeArchived
    ? eq(categories.userId, userId)
    : and(eq(categories.userId, userId), eq(categories.archived, false))
  return db.select().from(categories).where(where).all()
}

export const toCategoryDto = (c: typeof categories.$inferSelect, withArchived = false) => ({
  id: c.id,
  name: c.name,
  color: c.color,
  todoistProjectId: c.todoistProjectId,
  ...(withArchived ? { archived: c.archived } : {}),
})

/** 分类由用户自己维护，和 Todoist 项目无关（旧数据里的 todoistProjectId 只读保留）。 */
export function categoryRoutes(db: Db) {
  const r = new Hono<AppEnv>()

  r.get('/', async (c) => {
    const all = c.req.query('all') === '1'
    const rows = await listCategories(db, c.get('user').id, all)
    return c.json({ categories: rows.map((row) => toCategoryDto(row, all)) })
  })

  r.post('/', async (c) => {
    const parsed = body.safeParse(await c.req.json().catch(() => null))
    if (!parsed.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const row = { id: crypto.randomUUID(), userId: c.get('user').id, todoistProjectId: null, ...parsed.data }
    await db.insert(categories).values(row).run()
    return c.json({ category: toCategoryDto({ ...row, archived: false }) })
  })

  r.patch('/:id', async (c) => {
    const parsed = patch.safeParse(await c.req.json().catch(() => null))
    if (!parsed.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const mine = and(eq(categories.id, c.req.param('id')), eq(categories.userId, c.get('user').id), eq(categories.archived, false))
    const row = await db.update(categories).set(parsed.data).where(mine).returning().get()
    if (!row) return c.json({ error: 'NOT_FOUND' }, 404)
    return c.json({ category: toCategoryDto(row) })
  })

  /** 删除只是归档：历史专注仍能显示分类名，但不再出现在可选列表里。 */
  r.delete('/:id', async (c) => {
    const mine = and(eq(categories.id, c.req.param('id')), eq(categories.userId, c.get('user').id))
    const row = await db.update(categories).set({ archived: true }).where(mine).returning().get()
    if (!row) return c.json({ error: 'NOT_FOUND' }, 404)
    return c.json({ ok: true })
  })

  return r
}
