import { Hono } from 'hono'
import { auth, type AppEnv } from './auth.js'
import type { Db } from './db/client.js'
import { categoryRoutes } from './routes/categories.js'
import { entryRoutes } from './routes/entries.js'
import { evaluationRoutes, sessionRoutes } from './routes/sessions.js'
import { settingsRoutes } from './routes/settings.js'
import { statsRoutes } from './routes/stats.js'
import { syncRoutes } from './routes/sync.js'
import { todoistRoutes } from './routes/todoist.js'
import type { TodoistGateway } from './todoist/gateway.js'

export interface AppDeps {
  db: Db
  makeGateway: (token: string) => TodoistGateway
  secret: string
  now?: () => number
  /** 新 session 的 pending 评估记录的模型名 / prompt 版本 */
  evalModel?: string
  evalPromptVersion?: string
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
  api.route('/sync', syncRoutes(deps.db, {
    now,
    model: deps.evalModel ?? 'claude-haiku-5-5',
    promptVersion: deps.evalPromptVersion ?? 'v1',
  }))
  api.route('/sessions', sessionRoutes(deps.db))
  api.route('/evaluations', evaluationRoutes(deps.db, now))
  api.route('/stats', statsRoutes(deps.db))
  api.route('/settings', settingsRoutes(deps.db))
  app.route('/', api)
  return app
}
