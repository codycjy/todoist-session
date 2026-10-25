import { eq } from 'drizzle-orm'
import { expect, it } from 'vitest'
import { hashToken } from '../crypto.js'
import { evaluations, sessions, users } from '../db/schema.js'
import { authHeader, makeTestApp } from '../testing.js'

type Ctx = ReturnType<typeof makeTestApp>

function addSession(db: Ctx['db'], id: string, startedAt: number, over: Partial<typeof sessions.$inferInsert> = {}) {
  db.insert(sessions).values({
    id, userId: 'u1', source: 'custom', titleSnapshot: `t-${id}`, plannedSeconds: 1500,
    actualSeconds: 1200, startedAt: new Date(startedAt), endedAt: new Date(startedAt + 1_200_000), ...over,
  }).run()
}
function addEval(db: Ctx['db'], sessionId: string, over: Partial<typeof evaluations.$inferInsert> = {}) {
  db.insert(evaluations).values({
    sessionId, userId: 'u1', model: 'm', promptVersion: 'v1', createdAt: new Date(0), updatedAt: new Date(0), ...over,
  }).run()
}
const get = (app: Ctx['app'], qs: string) => app.request(`/sessions${qs}`, { headers: authHeader })
const DAY = 86_400_000

it('lists the current user sessions in range, ascending, with evaluation state', async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'o', apiTokenHash: hashToken('x'), createdAt: new Date() }).run()
  addSession(db, 'late', 5_000, { source: 'todoist', todoistTaskId: 'tt' })
  addSession(db, 'early', 1_000)
  addSession(db, 'pending', 2_000)
  addSession(db, 'noeval', 3_000)
  addSession(db, 'outside', 99_000_000)
  addSession(db, 'theirs', 2_500, { userId: 'u2' })
  addEval(db, 'early', { status: 'done', attempts: 1, focusScore: 82, summary: 'good', distractions: [{ start: 1, end: 2, reason: 'r' }] })
  addEval(db, 'pending', { status: 'failed', attempts: 3, lastError: 'API_ERROR', focusScore: 40, summary: 'stale' })
  addEval(db, 'late')
  addEval(db, 'theirs', { userId: 'u2' })

  const res = await get(app, '?from=0&to=10000')
  expect(res.status).toBe(200)
  const { sessions: list } = await res.json() as { sessions: Record<string, unknown>[] }
  expect(list.map((s) => s.id)).toEqual(['early', 'pending', 'noeval', 'late'])
  expect(list[0]).toEqual({
    id: 'early', categoryId: null, source: 'custom', todoistTaskId: null, entryId: null, title: 't-early',
    plannedSeconds: 1500, actualSeconds: 1200, startedAt: 1_000, endedAt: 1_201_000,
    evaluation: { status: 'done', focusScore: 82, summary: 'good', distractions: [{ start: 1, end: 2, reason: 'r' }], attempts: 1 },
  })
  expect(list[1]!.evaluation).toEqual({ status: 'failed', focusScore: null, summary: null, distractions: [], attempts: 3 })
  expect(list[2]!.evaluation).toBeNull()
  expect(list[3]).toMatchObject({ source: 'todoist', todoistTaskId: 'tt' })
  expect(list[3]!.evaluation).toEqual({ status: 'pending', focusScore: null, summary: null, distractions: [], attempts: 0 })
})

it('treats the range as [from, to)', async () => {
  const { app, db } = makeTestApp()
  addSession(db, 'a', 1000); addSession(db, 'b', 2000)
  const { sessions: list } = await (await get(app, '?from=1000&to=2000')).json() as { sessions: { id: string }[] }
  expect(list.map((s) => s.id)).toEqual(['a'])
})

it.each([
  ['', 'missing params'],
  ['?from=1', 'missing to'],
  ['?from=a&to=5', 'non-numeric'],
  ['?from=1.5&to=5', 'non-integer'],
  ['?from=5&to=5', 'to == from'],
  ['?from=9&to=5', 'to < from'],
  [`?from=0&to=${92 * DAY + 1}`, 'over 92 days'],
])('rejects bad range %s (%s)', async (qs) => {
  const { app } = makeTestApp()
  const res = await get(app, qs)
  expect(res.status).toBe(400)
  expect(await res.json()).toEqual({ error: 'BAD_REQUEST' })
})

it('accepts exactly 92 days and requires auth', async () => {
  const { app } = makeTestApp()
  expect((await get(app, `?from=0&to=${92 * DAY}`)).status).toBe(200)
  expect((await app.request('/sessions?from=0&to=10')).status).toBe(401)
})

const retry = (app: Ctx['app'], id: string) =>
  app.request(`/evaluations/${id}/retry`, { method: 'POST', headers: authHeader })

it('retry resets a failed evaluation to pending', async () => {
  const { app, db } = makeTestApp({ now: () => 777 })
  addSession(db, 's1', 1000)
  addEval(db, 's1', { status: 'failed', attempts: 3, lastError: 'BAD_OUTPUT' })
  const res = await retry(app, 's1')
  expect(res.status).toBe(202)
  expect(await res.json()).toEqual({ status: 'pending' })
  const row = db.select().from(evaluations).where(eq(evaluations.sessionId, 's1')).get()!
  expect(row).toMatchObject({ status: 'pending', attempts: 0, lastError: null })
  expect(row.updatedAt.getTime()).toBe(777)
})

it('retry returns 404 for missing or other users evaluations and leaves them untouched', async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'o', apiTokenHash: hashToken('x'), createdAt: new Date() }).run()
  addSession(db, 'theirs', 1000, { userId: 'u2' })
  addEval(db, 'theirs', { userId: 'u2', status: 'failed', attempts: 3 })
  expect((await retry(app, 'theirs')).status).toBe(404)
  expect((await retry(app, 'nope')).status).toBe(404)
  expect(db.select().from(evaluations).get()).toMatchObject({ status: 'failed', attempts: 3 })
  expect((await app.request('/evaluations/theirs/retry', { method: 'POST' })).status).toBe(401)
})

it('retry on an already pending evaluation returns 202 without resetting attempts', async () => {
  const { app, db } = makeTestApp({ now: () => 777 })
  addSession(db, 's1', 1000)
  addEval(db, 's1', { status: 'pending', attempts: 2, lastError: 'BAD_OUTPUT', updatedAt: new Date(5) })
  const res = await retry(app, 's1')
  expect(res.status).toBe(202)
  expect(await res.json()).toEqual({ status: 'pending' })
  const row = db.select().from(evaluations).get()!
  expect(row).toMatchObject({ status: 'pending', attempts: 2, lastError: 'BAD_OUTPUT' })
  expect(row.updatedAt.getTime()).toBe(5)
})

it('retry of a done evaluation is limited to once per 60s', async () => {
  let t = 100_000
  const { app, db } = makeTestApp({ now: () => t })
  addSession(db, 's1', 1000)
  addEval(db, 's1', { status: 'done', attempts: 1, focusScore: 80, updatedAt: new Date(100_000 - 59_999) })
  const limited = await retry(app, 's1')
  expect(limited.status).toBe(429)
  expect(await limited.json()).toEqual({ error: 'TOO_MANY' })
  expect(db.select().from(evaluations).get()).toMatchObject({ status: 'done', attempts: 1 })
  t = 100_001
  expect((await retry(app, 's1')).status).toBe(202)
  expect(db.select().from(evaluations).get()).toMatchObject({ status: 'pending', attempts: 0 })
})
