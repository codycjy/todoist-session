import { Hono } from 'hono'
import { auth, type AppEnv } from './auth.js'
import type { Db } from './db/client.js'
import { categoryRoutes } from './routes/categories.js'
import { entryRoutes } from './routes/entries.js'
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
  app.onError((err, c) => {
    console.error('unhandled error:', err instanceof Error ? err.message : 'unknown')
    return c.json({ error: 'INTERNAL' }, 500)
  })
  app.get('/health', (c) => c.json({ ok: true }))

  const api = new Hono<AppEnv>()
  api.use('*', auth(deps.db))
  api.route('/todoist', todoistRoutes({ ...deps, now }))
  api.route('/categories', categoryRoutes(deps.db))
  api.route('/entries', entryRoutes(deps.db, now))
  app.route('/', api)
  return app
}
