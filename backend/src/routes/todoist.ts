import { Hono } from 'hono'
import type { AppEnv } from '../auth.js'
import { decrypt } from '../crypto.js'
import type { Db } from '../db/client.js'
import { TtlCache } from '../todoist/cache.js'
import { TodoistAuthError, type TodoistGateway, type TodoistTask } from '../todoist/gateway.js'

export interface TodoistRouteDeps {
  db: Db
  makeGateway: (token: string) => TodoistGateway
  secret: string
  now: () => number
}

const QUERIES: Record<string, string> = { today: 'today', overdue: 'overdue' }

export function todoistRoutes({ db, makeGateway, secret, now }: TodoistRouteDeps) {
  const r = new Hono<AppEnv>()
  const taskCache = new TtlCache<TodoistTask[]>(60_000, now)

  const UNREADABLE = Symbol('unreadable')
  const gatewayFor = (enc: string | null): TodoistGateway | null | typeof UNREADABLE => {
    if (!enc) return null
    let token: string
    try {
      token = decrypt(enc, secret)
    } catch {
      return UNREADABLE
    }
    return makeGateway(token)
  }

  r.get('/tasks', async (c) => {
    const query = QUERIES[c.req.query('filter') ?? 'today']
    if (!query) return c.json({ error: 'BAD_REQUEST' }, 400)
    const user = c.get('user')
    const gateway = gatewayFor(user.todoistTokenEnc)
    if (gateway === UNREADABLE) return c.json({ error: 'TODOIST_TOKEN_UNREADABLE' }, 409)
    if (!gateway) return c.json({ error: 'TODOIST_NOT_CONFIGURED' }, 409)
    try {
      const tasks = await taskCache.get(`${user.id}:${query}`, () => gateway.tasks(query))
      return c.json({ tasks })
    } catch (e) {
      if (e instanceof TodoistAuthError) return c.json({ error: 'TODOIST_AUTH' }, 401)
      throw e
    }
  })

  return r
}
