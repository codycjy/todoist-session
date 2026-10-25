import { and, eq, gte, lt, sql } from 'drizzle-orm'
import { Hono } from 'hono'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { activitySpans, evaluations, sessions } from '../db/schema.js'
import { DAY_MS, rangeQuery } from './range.js'

const tzQuery = z.string().regex(/^-?\d+$/).transform(Number).pipe(z.number().int().min(-840).max(840))

/** 毫秒时间戳在客户端时区下的日期 YYYY-MM-DD */
const localDate = (ms: number, tzMinutes: number) => new Date(ms + tzMinutes * 60_000).toISOString().slice(0, 10)

const avg = (scores: number[]) => (scores.length ? Math.round(scores.reduce((a, b) => a + b, 0) / scores.length) : null)

export function statsRoutes(db: Db) {
  const r = new Hono<AppEnv>()

  r.get('/', (c) => {
    const q = rangeQuery.safeParse({ from: c.req.query('from'), to: c.req.query('to') })
    const tzRaw = c.req.query('tzOffsetMinutes')
    const tz = tzRaw === undefined ? ({ success: true, data: 0 } as const) : tzQuery.safeParse(tzRaw)
    if (!q.success || !tz.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const { from, to } = q.data
    const userId = c.get('user').id
    const inRange = and(eq(sessions.userId, userId), gte(sessions.startedAt, new Date(from)), lt(sessions.startedAt, new Date(to)))

    const rows = db.select({
      startedAt: sessions.startedAt, actualSeconds: sessions.actualSeconds, categoryId: sessions.categoryId,
      status: evaluations.status, focusScore: evaluations.focusScore,
    }).from(sessions).leftJoin(evaluations, eq(evaluations.sessionId, sessions.id)).where(inRange).all()

    // 按客户端时区逐日补齐
    const days = new Map<string, { focusSeconds: number; sessionCount: number; scores: number[] }>()
    for (let t = from; ; t += DAY_MS) {
      days.set(localDate(t, tz.data), { focusSeconds: 0, sessionCount: 0, scores: [] })
      if (localDate(t + DAY_MS, tz.data) > localDate(to - 1, tz.data)) break
    }
    const byCategory = new Map<string | null, number>()
    const allScores: number[] = []
    let total = 0
    for (const row of rows) {
      const day = days.get(localDate(row.startedAt.getTime(), tz.data))
      const done = row.status === 'done' && row.focusScore !== null
      total += row.actualSeconds
      byCategory.set(row.categoryId, (byCategory.get(row.categoryId) ?? 0) + row.actualSeconds)
      if (done) allScores.push(row.focusScore!)
      if (day) {
        day.focusSeconds += row.actualSeconds
        day.sessionCount++
        if (done) day.scores.push(row.focusScore!)
      }
    }

    const spanMs = db.select({
      kind: activitySpans.kind,
      ms: sql<number>`coalesce(sum(${activitySpans.endedAt} - ${activitySpans.startedAt}), 0)`,
    }).from(activitySpans).innerJoin(sessions, eq(sessions.id, activitySpans.sessionId))
      .where(inRange).groupBy(activitySpans.kind).all()
    const seconds = (kind: 'active' | 'idle') => Math.round((spanMs.find((s) => s.kind === kind)?.ms ?? 0) / 1000)

    return c.json({
      totalFocusSeconds: total,
      sessionCount: rows.length,
      avgFocusScore: avg(allScores),
      activeSeconds: seconds('active'),
      idleSeconds: seconds('idle'),
      days: [...days].map(([date, d]) => ({
        date, focusSeconds: d.focusSeconds, sessionCount: d.sessionCount, avgFocusScore: avg(d.scores),
      })),
      byCategory: [...byCategory]
        .map(([categoryId, focusSeconds]) => ({ categoryId, focusSeconds }))
        .sort((a, b) => b.focusSeconds - a.focusSeconds),
    })
  })

  return r
}
