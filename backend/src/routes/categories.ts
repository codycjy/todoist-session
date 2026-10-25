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
