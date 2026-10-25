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
