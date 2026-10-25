import { eq } from 'drizzle-orm'
import { expect, it } from 'vitest'
import { hashToken } from '../crypto.js'
import { users } from '../db/schema.js'
import { authHeader, makeTestApp } from '../testing.js'

const DEFAULTS = { focusSeconds: 1500, idleThresholdSeconds: 120, blockApps: [], blockDomains: [] }
const get = (app: ReturnType<typeof makeTestApp>['app']) => app.request('/settings', { headers: authHeader })
const put = (app: ReturnType<typeof makeTestApp>['app'], body: unknown) =>
  app.request('/settings', { method: 'PUT', headers: { ...authHeader, 'Content-Type': 'application/json' }, body: JSON.stringify(body) })

it('returns defaults when nothing is stored', async () => {
  const { app } = makeTestApp()
  const res = await get(app)
  expect(res.status).toBe(200)
  expect(await res.json()).toEqual(DEFAULTS)
})

it('merges partial updates and persists them', async () => {
  const { app, db } = makeTestApp()
  expect(await (await put(app, { focusSeconds: 1800 })).json()).toEqual({ ...DEFAULTS, focusSeconds: 1800 })
  expect(await (await put(app, { blockApps: ['com.tencent.xinWeChat'] })).json()).toEqual({
    ...DEFAULTS, focusSeconds: 1800, blockApps: ['com.tencent.xinWeChat'],
  })
  expect(await (await get(app)).json()).toEqual({ ...DEFAULTS, focusSeconds: 1800, blockApps: ['com.tencent.xinWeChat'] })
  expect(db.select().from(users).where(eq(users.id, 'u1')).get()!.settings).toMatchObject({ focusSeconds: 1800 })
})

it('ignores unknown fields and does not store them', async () => {
  const { app, db } = makeTestApp()
  const res = await put(app, { focusSeconds: 600, evil: 'x', todoistTokenEnc: 'y' })
  expect(await res.json()).toEqual({ ...DEFAULTS, focusSeconds: 600 })
  expect(db.select().from(users).get()!.settings).toEqual({ focusSeconds: 600 })
})

it('keeps unrelated keys already stored in users.settings untouched', async () => {
  const { app, db } = makeTestApp()
  db.update(users).set({ settings: { other: 1, focusSeconds: 900 } }).run()
  await put(app, { idleThresholdSeconds: 60 })
  expect(db.select().from(users).get()!.settings).toEqual({ other: 1, focusSeconds: 900, idleThresholdSeconds: 60 })
})

it('normalises domains: trim, lowercase, dedupe (apps are only trimmed and deduped)', async () => {
  const { app } = makeTestApp()
  const res = await put(app, {
    blockDomains: [' YouTube.com ', 'youtube.com', 'Bilibili.COM'],
    blockApps: [' com.A ', 'com.A', 'com.a'],
  })
  const body = await res.json() as typeof DEFAULTS
  expect(body.blockDomains).toEqual(['youtube.com', 'bilibili.com'])
  expect(body.blockApps).toEqual(['com.A', 'com.a'])
})

it('accepts boundary values', async () => {
  const { app } = makeTestApp()
  const ok = await put(app, {
    focusSeconds: 60, idleThresholdSeconds: 1800, blockApps: Array.from({ length: 200 }, (_, i) => `a${i}`),
    blockDomains: ['x'.repeat(200)],
  })
  expect(ok.status).toBe(200)
  expect((await put(app, { focusSeconds: 7200, idleThresholdSeconds: 30 })).status).toBe(200)
})

it.each([
  [{ focusSeconds: 59 }], [{ focusSeconds: 7201 }], [{ focusSeconds: 1500.5 }], [{ focusSeconds: '1500' }],
  [{ idleThresholdSeconds: 29 }], [{ idleThresholdSeconds: 1801 }],
  [{ blockApps: 'a' }], [{ blockApps: [''] }], [{ blockApps: ['  '] }], [{ blockApps: [1] }],
  [{ blockApps: ['x'.repeat(201)] }],
  [{ blockApps: Array.from({ length: 201 }, (_, i) => `a${i}`) }],
  [{ blockDomains: [''] }], [{ blockDomains: ['x'.repeat(201)] }],
  [null], [[]], ['str'],
])('rejects invalid body %j with 400 and stores nothing', async (body) => {
  const { app, db } = makeTestApp()
  const res = await put(app, body)
  expect(res.status).toBe(400)
  expect(await res.json()).toEqual({ error: 'BAD_REQUEST' })
  expect(db.select().from(users).get()!.settings).toEqual({})
})

it('rejects malformed JSON', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/settings', { method: 'PUT', headers: authHeader, body: '{nope' })
  expect(res.status).toBe(400)
})

it('isolates users and requires auth', async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'o', apiTokenHash: hashToken('other'), settings: { focusSeconds: 111 }, createdAt: new Date() }).run()
  await put(app, { focusSeconds: 2000 })
  expect(db.select().from(users).where(eq(users.id, 'u2')).get()!.settings).toEqual({ focusSeconds: 111 })
  const other = await app.request('/settings', { headers: { Authorization: 'Bearer other' } })
  expect(await other.json()).toEqual({ ...DEFAULTS, focusSeconds: 111 })
  expect((await app.request('/settings')).status).toBe(401)
  expect((await app.request('/settings', { method: 'PUT', body: '{}' })).status).toBe(401)
})

it('falls back to defaults for stored values that no longer validate', async () => {
  const { app, db } = makeTestApp()
  db.update(users).set({ settings: { focusSeconds: 'bad', blockApps: 7 } }).run()
  expect(await (await get(app)).json()).toEqual(DEFAULTS)
})
