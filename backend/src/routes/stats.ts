import { and, desc, eq, gte, isNotNull, lt, sql } from 'drizzle-orm'
import { Hono } from 'hono'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import type { Db } from '../db/client.js'
import { activitySpans, evaluations, sessions } from '../db/schema.js'
import { DAY_MS, rangeQuery } from './range.js'

const tzQuery = z.string().regex(/^-?\d+$/).transform(Number).pipe(z.number().int().min(-840).max(840))

const HOUR_MS = 3_600_000
const TOP_APPS = 8

/** 毫秒时间戳在客户端时区下的日期 YYYY-MM-DD、小时，以及距下一个整点的毫秒数 */
type LocalParts = { date: string; hour: number; toNextHour: number }
const partsByOffset = (ms: number, tzMinutes: number): LocalParts => {
  const local = ms + tzMinutes * 60_000
  const iso = new Date(local).toISOString()
  return { date: iso.slice(0, 10), hour: Number(iso.slice(11, 13)), toNextHour: HOUR_MS - (((local % HOUR_MS) + HOUR_MS) % HOUR_MS) }
}

const formatters = new Map<string, Intl.DateTimeFormat>()
/** 校验 IANA 时区名；无效返回 null */
function formatterFor(tz: string): Intl.DateTimeFormat | null {
  const hit = formatters.get(tz)
  if (hit) return hit
  try {
    const f = new Intl.DateTimeFormat('en-CA', {
      timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
    })
    formatters.set(tz, f)
    return f
  } catch {
    return null
  }
}
const zonedParts = (f: Intl.DateTimeFormat, ms: number): LocalParts => {
  const p = Object.fromEntries(f.formatToParts(ms).map((x) => [x.type, x.value]))
  const intoHour = (Number(p.minute) * 60 + Number(p.second)) * 1000 + (((ms % 1000) + 1000) % 1000)
  return { date: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour), toNextHour: HOUR_MS - intoHour }
}
const addDays = (date: string, n: number) => new Date(Date.parse(`${date}T00:00:00Z`) + n * DAY_MS).toISOString().slice(0, 10)

const avg = (scores: number[]) => (scores.length ? Math.round(scores.reduce((a, b) => a + b, 0) / scores.length) : null)

export function statsRoutes(db: Db) {
  const r = new Hono<AppEnv>()

  r.get('/', (c) => {
    const q = rangeQuery.safeParse({ from: c.req.query('from'), to: c.req.query('to') })
    const tzRaw = c.req.query('tzOffsetMinutes')
    const tz = tzRaw === undefined ? ({ success: true, data: 0 } as const) : tzQuery.safeParse(tzRaw)
    const tzName = c.req.query('tz')
    const fmt = tzName === undefined ? null : formatterFor(tzName)
    if (!q.success || !tz.success || (tzName !== undefined && !fmt)) return c.json({ error: 'BAD_REQUEST' }, 400)
    const localParts = (ms: number) => (fmt ? zonedParts(fmt, ms) : partsByOffset(ms, tz.data))
    const localDate = (ms: number) => localParts(ms).date
    const { from, to } = q.data
    const userId = c.get('user').id
    const inRange = and(eq(sessions.userId, userId), gte(sessions.startedAt, new Date(from)), lt(sessions.startedAt, new Date(to)))

    const rows = db.select({
      startedAt: sessions.startedAt, actualSeconds: sessions.actualSeconds, plannedSeconds: sessions.plannedSeconds,
      categoryId: sessions.categoryId,
      status: evaluations.status, focusScore: evaluations.focusScore,
    }).from(sessions).leftJoin(evaluations, eq(evaluations.sessionId, sessions.id)).where(inRange).all()

    // 按客户端时区逐日补齐
    const days = new Map<string, { focusSeconds: number; sessionCount: number; scores: number[] }>()
    const last = localDate(to - 1)
    for (let d = localDate(from); d <= last; d = addDays(d, 1)) {
      days.set(d, { focusSeconds: 0, sessionCount: 0, scores: [] })
    }
    const byCategory = new Map<string | null, number>()
    const allScores: number[] = []
    // 专注时长按本地整点切开：从开始时刻起铺 actualSeconds（暂停不计，近似）
    const byHour = new Map<string, { date: string; hour: number; ms: number }>()
    let total = 0
    let planned = 0
    for (const row of rows) {
      planned += row.plannedSeconds
      for (let t = row.startedAt.getTime(), left = row.actualSeconds * 1000; left > 0;) {
        const p = localParts(t)
        const step = Math.min(left, p.toNextHour)
        const key = `${p.date}T${p.hour}`
        const cell = byHour.get(key) ?? { date: p.date, hour: p.hour, ms: 0 }
        cell.ms += step
        byHour.set(key, cell)
        t += step
        left -= step
      }
      const key = localDate(row.startedAt.getTime())
      let day = days.get(key)
      if (!day) {
        day = { focusSeconds: 0, sessionCount: 0, scores: [] }
        days.set(key, day)
      }
      const done = row.status === 'done' && row.focusScore !== null
      total += row.actualSeconds
      byCategory.set(row.categoryId, (byCategory.get(row.categoryId) ?? 0) + row.actualSeconds)
      if (done) allScores.push(row.focusScore!)
      day.focusSeconds += row.actualSeconds
      day.sessionCount++
      if (done) day.scores.push(row.focusScore!)
    }

    const spanMs = db.select({
      kind: activitySpans.kind,
      ms: sql<number>`coalesce(sum(${activitySpans.endedAt} - ${activitySpans.startedAt}), 0)`,
    }).from(activitySpans).innerJoin(sessions, eq(sessions.id, activitySpans.sessionId))
      .where(inRange).groupBy(activitySpans.kind).all()
    const seconds = (kind: 'active' | 'idle') => Math.round((spanMs.find((s) => s.kind === kind)?.ms ?? 0) / 1000)

    // 活跃时间按网站（有域名时）或 App 归类
    const appName = sql<string>`coalesce(${activitySpans.urlHost}, ${activitySpans.appName})`
    const appMs = sql<number>`sum(${activitySpans.endedAt} - ${activitySpans.startedAt})`
    const topApps = db.select({ name: appName, ms: appMs })
      .from(activitySpans).innerJoin(sessions, eq(sessions.id, activitySpans.sessionId))
      .where(and(inRange, eq(activitySpans.kind, 'active'), isNotNull(appName)))
      .groupBy(appName).orderBy(desc(appMs)).limit(TOP_APPS).all()

    return c.json({
      totalFocusSeconds: total,
      plannedSeconds: planned,
      sessionCount: rows.length,
      avgFocusScore: avg(allScores),
      activeSeconds: seconds('active'),
      idleSeconds: seconds('idle'),
      days: [...days].sort(([a], [b]) => (a < b ? -1 : 1)).map(([date, d]) => ({
        date, focusSeconds: d.focusSeconds, sessionCount: d.sessionCount, avgFocusScore: avg(d.scores),
      })),
      byCategory: [...byCategory]
        .map(([categoryId, focusSeconds]) => ({ categoryId, focusSeconds }))
        .sort((a, b) => b.focusSeconds - a.focusSeconds),
      byHour: [...byHour.values()]
        .sort((a, b) => (a.date === b.date ? a.hour - b.hour : a.date < b.date ? -1 : 1))
        .map(({ date, hour, ms }) => ({ date, hour, focusSeconds: Math.round(ms / 1000) })),
      topApps: topApps.map(({ name, ms }) => ({ name, seconds: Math.round(ms / 1000) })),
    })
  })

  return r
}
