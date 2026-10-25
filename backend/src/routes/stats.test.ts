import { describe, expect, it } from 'vitest'
import { hashToken } from '../crypto.js'
import { activitySpans, categories, evaluations, sessions, users } from '../db/schema.js'
import { authHeader, makeTestApp } from '../testing.js'

type Ctx = ReturnType<typeof makeTestApp>
const DAY = 86_400_000
const HOUR = 3_600_000
const utc = (iso: string) => Date.parse(iso)

function addSession(db: Ctx['db'], id: string, startedAt: number, over: Partial<typeof sessions.$inferInsert> = {}) {
  db.insert(sessions).values({
    id, userId: 'u1', source: 'custom', titleSnapshot: id, plannedSeconds: 1500,
    actualSeconds: 1000, startedAt: new Date(startedAt), endedAt: new Date(startedAt + 1_000_000), ...over,
  }).run()
}
function addEval(db: Ctx['db'], sessionId: string, status: 'pending' | 'done' | 'failed', score: number | null, userId = 'u1') {
  db.insert(evaluations).values({
    sessionId, userId, status, focusScore: score, model: 'm', promptVersion: 'v1',
    createdAt: new Date(0), updatedAt: new Date(0),
  }).run()
}
function addSpan(db: Ctx['db'], id: string, sessionId: string, kind: 'active' | 'idle', ms: number) {
  db.insert(activitySpans).values({ id, sessionId, kind, startedAt: new Date(0), endedAt: new Date(ms) }).run()
}
const stats = async (app: Ctx['app'], qs: string) => {
  const res = await app.request(`/stats${qs}`, { headers: authHeader })
  return { res, body: await res.json() as any }
}

it('returns zeros, null average and zero-filled days for an empty range', async () => {
  const { app } = makeTestApp()
  const from = utc('2026-10-24T00:00:00Z')
  const { res, body } = await stats(app, `?from=${from}&to=${from + 3 * DAY}`)
  expect(res.status).toBe(200)
  expect(body).toEqual({
    totalFocusSeconds: 0, sessionCount: 0, avgFocusScore: null, activeSeconds: 0, idleSeconds: 0,
    days: [
      { date: '2026-10-24', focusSeconds: 0, sessionCount: 0, avgFocusScore: null },
      { date: '2026-10-25', focusSeconds: 0, sessionCount: 0, avgFocusScore: null },
      { date: '2026-10-26', focusSeconds: 0, sessionCount: 0, avgFocusScore: null },
    ],
    byCategory: [],
  })
})

it('aggregates totals and averages only done evaluations (rounded)', async () => {
  const { app, db } = makeTestApp()
  const t = utc('2026-10-25T10:00:00Z')
  addSession(db, 'a', t, { actualSeconds: 600 })
  addSession(db, 'b', t + HOUR, { actualSeconds: 900 })
  addSession(db, 'c', t + 2 * HOUR, { actualSeconds: 300 })
  addSession(db, 'd', t + 3 * HOUR, { actualSeconds: 300 })
  addEval(db, 'a', 'done', 80); addEval(db, 'b', 'done', 71)
  addEval(db, 'c', 'failed', 10); addEval(db, 'd', 'pending', null)
  const { body } = await stats(app, `?from=${t - HOUR}&to=${t + DAY}`)
  expect(body.totalFocusSeconds).toBe(2100)
  expect(body.sessionCount).toBe(4)
  expect(body.avgFocusScore).toBe(76) // (80+71)/2 = 75.5 -> 76
  expect(body.days).toEqual([
    { date: '2026-10-25', focusSeconds: 2100, sessionCount: 4, avgFocusScore: 76 },
    { date: '2026-10-26', focusSeconds: 0, sessionCount: 0, avgFocusScore: null },
  ])
})

it('buckets days by the client time zone (UTC+8 session crossing UTC midnight)', async () => {
  const { app, db } = makeTestApp()
  // 2026-10-25 23:30 UTC == 2026-10-26 07:30 in UTC+8; 2026-10-25 15:59 UTC == 23:59 on the 25th in UTC+8
  addSession(db, 'next-day', utc('2026-10-25T23:30:00Z'), { actualSeconds: 100 })
  addSession(db, 'same-day', utc('2026-10-25T15:59:00Z'), { actualSeconds: 50 })
  const from = utc('2026-10-24T16:00:00Z') // local midnight of the 25th in UTC+8
  const { body } = await stats(app, `?from=${from}&to=${from + 2 * DAY}&tzOffsetMinutes=480`)
  expect(body.days).toEqual([
    { date: '2026-10-25', focusSeconds: 50, sessionCount: 1, avgFocusScore: null },
    { date: '2026-10-26', focusSeconds: 100, sessionCount: 1, avgFocusScore: null },
  ])
  // Without the offset the same instant falls on the UTC date.
  const utcRes = await stats(app, `?from=${utc('2026-10-25T00:00:00Z')}&to=${utc('2026-10-27T00:00:00Z')}`)
  expect(utcRes.body.days.map((d: any) => [d.date, d.sessionCount])).toEqual([['2026-10-25', 2], ['2026-10-26', 0]])
})

it('supports negative offsets', async () => {
  const { app, db } = makeTestApp()
  addSession(db, 'a', utc('2026-10-26T02:00:00Z')) // 2026-10-25 19:00 in UTC-7
  const from = utc('2026-10-25T07:00:00Z')
  const { body } = await stats(app, `?from=${from}&to=${from + DAY}&tzOffsetMinutes=-420`)
  expect(body.days).toEqual([{ date: '2026-10-25', focusSeconds: 1000, sessionCount: 1, avgFocusScore: null }])
})

it('sums active and idle span time (own sessions in range only)', async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'o', apiTokenHash: hashToken('x'), createdAt: new Date() }).run()
  const t = utc('2026-10-25T10:00:00Z')
  addSession(db, 'a', t); addSession(db, 'b', t + HOUR)
  addSession(db, 'out', t + 5 * DAY); addSession(db, 'theirs', t, { userId: 'u2' })
  addSpan(db, 'p1', 'a', 'active', 120_000); addSpan(db, 'p2', 'a', 'idle', 30_000)
  addSpan(db, 'p3', 'b', 'active', 60_000)
  addSpan(db, 'p4', 'out', 'active', 999_000); addSpan(db, 'p5', 'theirs', 'idle', 999_000)
  const { body } = await stats(app, `?from=${t - HOUR}&to=${t + DAY}`)
  expect(body.activeSeconds).toBe(180)
  expect(body.idleSeconds).toBe(30)
})

it('groups by category, descending by seconds, with null for uncategorised', async () => {
  const { app, db } = makeTestApp()
  db.insert(categories).values([
    { id: 'c1', userId: 'u1', name: 'a', color: 'red' }, { id: 'c2', userId: 'u1', name: 'b', color: 'blue' },
  ]).run()
  const t = utc('2026-10-25T10:00:00Z')
  addSession(db, 's1', t, { categoryId: 'c1', actualSeconds: 100 })
  addSession(db, 's2', t + HOUR, { categoryId: 'c2', actualSeconds: 300 })
  addSession(db, 's3', t + 2 * HOUR, { categoryId: 'c1', actualSeconds: 150 })
  addSession(db, 's4', t + 3 * HOUR, { categoryId: null, actualSeconds: 500 })
  const { body } = await stats(app, `?from=${t - HOUR}&to=${t + DAY}`)
  expect(body.byCategory).toEqual([
    { categoryId: null, focusSeconds: 500 },
    { categoryId: 'c2', focusSeconds: 300 },
    { categoryId: 'c1', focusSeconds: 250 },
  ])
})

it('isolates users', async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'o', apiTokenHash: hashToken('x'), createdAt: new Date() }).run()
  const t = utc('2026-10-25T10:00:00Z')
  addSession(db, 'theirs', t, { userId: 'u2', actualSeconds: 777 })
  addEval(db, 'theirs', 'done', 99, 'u2')
  const { body } = await stats(app, `?from=${t - HOUR}&to=${t + DAY}`)
  expect(body).toMatchObject({ totalFocusSeconds: 0, sessionCount: 0, avgFocusScore: null, byCategory: [] })
})

it.each([
  ['', 'missing'],
  ['?from=0&to=0', 'empty range'],
  [`?from=0&to=${92 * DAY + 1}`, 'over 92 days'],
  [`?from=0&to=${DAY}&tzOffsetMinutes=841`, 'offset too large'],
  [`?from=0&to=${DAY}&tzOffsetMinutes=-841`, 'offset too small'],
  [`?from=0&to=${DAY}&tzOffsetMinutes=abc`, 'offset NaN'],
  [`?from=0&to=${DAY}&tzOffsetMinutes=1.5`, 'offset fractional'],
])('rejects invalid query %s (%s)', async (qs) => {
  const { app } = makeTestApp()
  const { res, body } = await stats(app, qs)
  expect(res.status).toBe(400)
  expect(body).toEqual({ error: 'BAD_REQUEST' })
})

it('accepts the +-840 offset limits and requires auth', async () => {
  const { app } = makeTestApp()
  expect((await stats(app, `?from=0&to=${DAY}&tzOffsetMinutes=840`)).res.status).toBe(200)
  expect((await stats(app, `?from=0&to=${DAY}&tzOffsetMinutes=-840`)).res.status).toBe(200)
  expect((await app.request(`/stats?from=0&to=${DAY}`)).status).toBe(401)
})

describe('IANA tz bucketing', () => {
  it('Europe/London DST-change day is a single 25h day', async () => {
    const { app, db } = makeTestApp()
    addSession(db, 'a', utc('2026-10-24T23:30Z'), { actualSeconds: 100 }) // 00:30 BST 10-25
    addSession(db, 'b', utc('2026-10-25T23:30Z'), { actualSeconds: 50 }) // 23:30 GMT 10-25
    const { body } = await stats(app, `?from=${utc('2026-10-24T23:00Z')}&to=${utc('2026-10-26T00:00Z')}&tz=Europe/London`)
    expect(body.days).toEqual([{ date: '2026-10-25', focusSeconds: 150, sessionCount: 2, avgFocusScore: null }])
    expect(body.totalFocusSeconds).toBe(150)
  })

  it('US/Pacific range spanning the 2026-11-01 change buckets by local date', async () => {
    const { app, db } = makeTestApp()
    // PDT until 09:00Z on 11-01; local midnight 10-31 = 07:00Z, 11-02 = 08:00Z
    addSession(db, 'a', utc('2026-11-01T06:59Z'), { actualSeconds: 10 }) // 10-31 23:59 PDT
    addSession(db, 'b', utc('2026-11-01T07:00Z'), { actualSeconds: 20 }) // 11-01 00:00 PDT
    addSession(db, 'c', utc('2026-11-02T07:59Z'), { actualSeconds: 40 }) // 11-01 23:59 PST
    addSession(db, 'd', utc('2026-11-02T08:00Z'), { actualSeconds: 80 }) // 11-02 00:00 PST
    const { body } = await stats(app, `?from=${utc('2026-10-31T07:00Z')}&to=${utc('2026-11-03T08:00Z')}&tz=America/Los_Angeles`)
    expect(body.days.map((d: any) => [d.date, d.focusSeconds])).toEqual([
      ['2026-10-31', 10], ['2026-11-01', 60], ['2026-11-02', 80],
    ])
  })

  it('rejects an invalid tz', async () => {
    const { app } = makeTestApp()
    const { res, body } = await stats(app, `?from=0&to=${DAY}&tz=Not/AZone`)
    expect(res.status).toBe(400)
    expect(body).toEqual({ error: 'BAD_REQUEST' })
  })

  it('totals always equal the sum of days, even for rows outside the generated days', async () => {
    const { app, db } = makeTestApp()
    // range starts mid-day so every row is in range, but use a coarse fallback offset to stress bucketing
    addSession(db, 'a', utc('2026-10-25T00:30Z'), { actualSeconds: 7 })
    addSession(db, 'b', utc('2026-10-25T20:00Z'), { actualSeconds: 9 })
    const { body } = await stats(app, `?from=${utc('2026-10-25T00:00Z')}&to=${utc('2026-10-26T00:00Z')}&tz=Pacific/Kiritimati`)
    const sum = body.days.reduce((a: number, d: any) => a + d.focusSeconds, 0)
    const cnt = body.days.reduce((a: number, d: any) => a + d.sessionCount, 0)
    expect(sum).toBe(body.totalFocusSeconds)
    expect(cnt).toBe(body.sessionCount)
  })
})
