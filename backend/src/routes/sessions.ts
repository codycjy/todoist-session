import { and, asc, eq, gte, lt } from 'drizzle-orm'
import { Hono } from 'hono'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { evaluations, sessions } from '../db/schema.js'
import { rangeQuery } from './range.js'

export function sessionRoutes(db: Db) {
  const r = new Hono<AppEnv>()

  r.get('/', (c) => {
    const q = rangeQuery.safeParse({ from: c.req.query('from'), to: c.req.query('to') })
    if (!q.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const rows = db.select({ s: sessions, e: evaluations }).from(sessions)
      .leftJoin(evaluations, eq(evaluations.sessionId, sessions.id))
      .where(and(eq(sessions.userId, c.get('user').id), gte(sessions.startedAt, new Date(q.data.from)), lt(sessions.startedAt, new Date(q.data.to))))
      .orderBy(asc(sessions.startedAt)).all()
    return c.json({
      sessions: rows.map(({ s, e }) => ({
        id: s.id, categoryId: s.categoryId, source: s.source, todoistTaskId: s.todoistTaskId, entryId: s.entryId,
        title: s.titleSnapshot, plannedSeconds: s.plannedSeconds, actualSeconds: s.actualSeconds,
        startedAt: s.startedAt.getTime(), endedAt: s.endedAt.getTime(),
        evaluation: e && {
          status: e.status,
          // 只有 done 才对外给出结果，其余状态不泄露旧值
          focusScore: e.status === 'done' ? e.focusScore : null,
          summary: e.status === 'done' ? e.summary : null,
          distractions: e.status === 'done' ? e.distractions : [],
          attempts: e.attempts,
        },
      })),
    })
  })

  return r
}

export function evaluationRoutes(db: Db, now: () => number) {
  const r = new Hono<AppEnv>()

  r.post('/:sessionId/retry', (c) => {
    const where = and(eq(evaluations.sessionId, c.req.param('sessionId')), eq(evaluations.userId, c.get('user').id))
    const updated = db.update(evaluations)
      .set({ status: 'pending', attempts: 0, lastError: null, updatedAt: new Date(now()) })
      .where(where).returning({ id: evaluations.sessionId }).all()
    if (updated.length === 0) return c.json({ error: 'NOT_FOUND' }, 404)
    return c.json({ status: 'pending' }, 202)
  })

  return r
}
