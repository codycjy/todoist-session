import { and, desc, eq, isNull } from 'drizzle-orm'
import { Hono } from 'hono'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { categories, entries, type Entry } from '../db/schema.js'

const body = z.object({ title: z.string().trim().min(1), categoryId: z.string().nullable() })

const toDto = (e: Entry) => ({ id: e.id, title: e.title, categoryId: e.categoryId })

export function entryRoutes(db: Db, now: () => number) {
  const r = new Hono<AppEnv>()

  r.get('/', async (c) => {
    const rows = await db
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
      const owned = await db
        .select()
        .from(categories)
        .where(and(eq(categories.id, categoryId), eq(categories.userId, userId)))
        .get()
      if (!owned) return c.json({ error: 'BAD_REQUEST' }, 400)
    }

    const lastUsedAt = new Date(now())
    const existing = await db
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
      await db.update(entries).set({ lastUsedAt }).where(eq(entries.id, existing.id)).run()
      return c.json({ entry: toDto(existing) })
    }
    const row = { id: crypto.randomUUID(), userId, title, categoryId, lastUsedAt }
    await db.insert(entries).values(row).run()
    return c.json({ entry: toDto(row) })
  })

  return r
}
