import { eq } from 'drizzle-orm'
import { expect, it } from 'vitest'
import { hashToken } from '../crypto.js'
import { activitySpans, categories, sessions, users } from '../db/schema.js'
import { authHeader, makeTestApp } from '../testing.js'

const post = (body: unknown) => ({
  method: 'POST',
  headers: { ...authHeader, 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
})

const span = (id: string, over: Record<string, unknown> = {}) => ({
  id, kind: 'active', appBundleId: 'com.apple.dt.Xcode', appName: 'Xcode',
  windowTitle: 'a.swift', urlHost: null, urlPath: null,
  startedAt: 1_000, endedAt: 2_000, wasBlocked: false, ...over,
})

const session = (id: string, over: Record<string, unknown> = {}) => ({
  id, categoryId: null, source: 'custom', todoistTaskId: null, entryId: null,
  title: '写周报', plannedSeconds: 1500, actualSeconds: 1500,
  startedAt: 1_000, endedAt: 2_000, spans: [span(`${id}-s1`)], ...over,
})

it('stores sessions with their spans', async () => {
  const { app, db } = makeTestApp()
  const res = await app.request('/sync/sessions', post({ sessions: [session('s1')] }))
  expect(res.status).toBe(200)
  expect(await res.json()).toEqual({ accepted: ['s1'], rejected: [] })
  const row = db.select().from(sessions).where(eq(sessions.id, 's1')).get()
  expect(row).toMatchObject({ userId: 'u1', titleSnapshot: '写周报', actualSeconds: 1500 })
  expect(db.select().from(activitySpans).all()).toHaveLength(1)
})

it('is idempotent: re-posting the same session accepts it without duplicating', async () => {
  const { app, db } = makeTestApp()
  await app.request('/sync/sessions', post({ sessions: [session('s1')] }))
  const res = await app.request('/sync/sessions', post({ sessions: [session('s1')] }))
  expect(await res.json()).toEqual({ accepted: ['s1'], rejected: [] })
  expect(db.select().from(sessions).all()).toHaveLength(1)
  expect(db.select().from(activitySpans).all()).toHaveLength(1)
})

it('nulls out a category that does not exist or belongs to someone else', async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'other', apiTokenHash: hashToken('x'), createdAt: new Date() }).run()
  db.insert(categories).values({ id: 'c-other', userId: 'u2', name: 'n', color: 'red' }).run()
  await app.request('/sync/sessions', post({ sessions: [
    session('a', { categoryId: 'c-other' }), session('b', { categoryId: 'missing' }),
  ] }))
  const rows = db.select().from(sessions).all()
  expect(rows.map((r) => r.categoryId)).toEqual([null, null])
})

it("rejects a session id owned by another user", async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'other', apiTokenHash: hashToken('x'), createdAt: new Date() }).run()
  db.insert(sessions).values({
    id: 'taken', userId: 'u2', source: 'custom', titleSnapshot: 't', plannedSeconds: 1,
    actualSeconds: 1, startedAt: new Date(1), endedAt: new Date(2),
  }).run()
  const res = await app.request('/sync/sessions', post({ sessions: [session('taken'), session('ok')] }))
  expect(await res.json()).toEqual({ accepted: ['ok'], rejected: [{ id: 'taken', reason: 'CONFLICT' }] })
})

it('rejects a session whose end is before its start', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/sync/sessions', post({ sessions: [session('bad', { startedAt: 5, endedAt: 1 })] }))
  expect(await res.json()).toEqual({ accepted: [], rejected: [{ id: 'bad', reason: 'INVALID_TIME' }] })
})

it('returns 400 for a malformed body and 401 without a token', async () => {
  const { app } = makeTestApp()
  expect((await app.request('/sync/sessions', post({ sessions: [] }))).status).toBe(400)
  expect((await app.request('/sync/sessions', post({ nope: 1 }))).status).toBe(400)
  const res = await app.request('/sync/sessions', { method: 'POST', body: '{}' })
  expect(res.status).toBe(401)
})

it('keeps the category on a session even if that category is archived', async () => {
  const { app, db } = makeTestApp()
  db.insert(categories).values({ id: 'c-old', userId: 'u1', name: 'Old', color: 'red', archived: true }).run()
  await app.request('/sync/sessions', post({ sessions: [session('s1', { categoryId: 'c-old' })] }))
  expect(db.select().from(sessions).get()?.categoryId).toBe('c-old')
})
