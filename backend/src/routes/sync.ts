import { and, eq } from 'drizzle-orm'
import { Hono } from 'hono'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { activitySpans, categories, entries, evaluations, sessions } from '../db/schema.js'

const id = z.string().min(1).max(64)
const ms = z.number().int().nonnegative()
const spanSchema = z.object({
  id,
  kind: z.enum(['active', 'idle']),
  appBundleId: z.string().nullable(),
  appName: z.string().nullable(),
  windowTitle: z.string().nullable(),
  urlHost: z.string().nullable(),
  urlPath: z.string().nullable(),
  startedAt: ms,
  endedAt: ms,
  wasBlocked: z.boolean(),
})
const sessionSchema = z.object({
  id,
  categoryId: z.string().nullable(),
  source: z.enum(['todoist', 'custom']),
  todoistTaskId: z.string().nullable(),
  entryId: z.string().nullable(),
  title: z.string().min(1),
  plannedSeconds: z.number().int().positive(),
  actualSeconds: z.number().int().nonnegative(),
  startedAt: ms,
  endedAt: ms,
  spans: z.array(spanSchema).max(5000),
})
const bodySchema = z.object({ sessions: z.array(sessionSchema).min(1).max(50) })

type Rejection = { id: string; reason: 'CONFLICT' | 'INVALID_TIME' }
const SPAN_CHUNK = 200 // 11 列 × 200 = 2200 个绑定参数，低于 SQLite 上限

export interface SyncOptions {
  now: () => number
  model: string
  promptVersion: string
}

export function syncRoutes(db: Db, opts: SyncOptions) {
  const r = new Hono<AppEnv>()

  r.post('/sessions', async (c) => {
    const parsed = bodySchema.safeParse(await c.req.json().catch(() => null))
    if (!parsed.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const userId = c.get('user').id
    const accepted: string[] = []
    const rejected: Rejection[] = []

    for (const s of parsed.data.sessions) {
      const timesOk = s.endedAt >= s.startedAt && s.spans.every((p) => p.endedAt >= p.startedAt)
      if (!timesOk) { rejected.push({ id: s.id, reason: 'INVALID_TIME' }); continue }

      const outcome = db.transaction((tx) => {
        const existing = tx.select({ userId: sessions.userId }).from(sessions).where(eq(sessions.id, s.id)).get()
        if (existing) return existing.userId === userId ? 'ok' : 'conflict'

        const categoryId = s.categoryId &&
          tx.select({ id: categories.id }).from(categories)
            .where(and(eq(categories.id, s.categoryId), eq(categories.userId, userId))).get()
          ? s.categoryId : null
        const entryId = s.entryId &&
          tx.select({ id: entries.id }).from(entries)
            .where(and(eq(entries.id, s.entryId), eq(entries.userId, userId))).get()
          ? s.entryId : null

        tx.insert(sessions).values({
          id: s.id, userId, categoryId, source: s.source, todoistTaskId: s.todoistTaskId, entryId,
          titleSnapshot: s.title, plannedSeconds: s.plannedSeconds, actualSeconds: s.actualSeconds,
          startedAt: new Date(s.startedAt), endedAt: new Date(s.endedAt),
        }).run()

        const at = new Date(opts.now())
        tx.insert(evaluations).values({
          sessionId: s.id, userId, model: opts.model, promptVersion: opts.promptVersion,
          createdAt: at, updatedAt: at,
        }).run()

        for (let i = 0; i < s.spans.length; i += SPAN_CHUNK) {
          tx.insert(activitySpans).values(
            s.spans.slice(i, i + SPAN_CHUNK).map((p) => ({
              ...p, sessionId: s.id, startedAt: new Date(p.startedAt), endedAt: new Date(p.endedAt),
            })),
          ).onConflictDoNothing().run()
        }
        return 'ok'
      })

      if (outcome === 'ok') accepted.push(s.id)
      else rejected.push({ id: s.id, reason: 'CONFLICT' })
    }
    return c.json({ accepted, rejected })
  })

  return r
}
