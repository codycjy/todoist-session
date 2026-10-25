import { Hono } from 'hono'
import { randomUUID } from 'node:crypto'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { categories } from '../db/schema.js'
import { listCategories, toCategoryDto } from './todoist.js'

const body = z.object({ name: z.string().trim().min(1), color: z.string().min(1) })

export function categoryRoutes(db: Db) {
  const r = new Hono<AppEnv>()

  r.get('/', (c) => {
    const all = c.req.query('all') === '1'
    return c.json({ categories: listCategories(db, c.get('user').id, all).map((row) => toCategoryDto(row, all)) })
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
