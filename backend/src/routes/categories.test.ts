import { expect, it } from 'vitest'
import { hashToken } from '../crypto.js'
import { categories, users } from '../db/schema.js'
import { authHeader, makeTestApp } from '../testing.js'

const json = { ...authHeader, 'Content-Type': 'application/json' }
type App = ReturnType<typeof makeTestApp>['app']
const create = async (app: App, name: string, color = 'blue') =>
  (await (await app.request('/categories', { method: 'POST', headers: json, body: JSON.stringify({ name, color }) })).json()).category
const list = async (app: App, all = false) =>
  (await (await app.request(`/categories${all ? '?all=1' : ''}`, { headers: authHeader })).json()).categories

it('creates, renames, recolours and lists categories', async () => {
  const { app } = makeTestApp()
  const c = await create(app, ' 阅读 ', 'green')
  expect(c).toMatchObject({ name: '阅读', color: 'green', todoistProjectId: null })
  const res = await app.request(`/categories/${c.id}`, { method: 'PATCH', headers: json, body: JSON.stringify({ name: '读书' }) })
  expect(res.status).toBe(200)
  expect((await res.json()).category).toMatchObject({ id: c.id, name: '读书', color: 'green' })
  await app.request(`/categories/${c.id}`, { method: 'PATCH', headers: json, body: JSON.stringify({ color: 'red' }) })
  expect(await list(app)).toEqual([{ id: c.id, name: '读书', color: 'red', todoistProjectId: null }])
})

it('delete archives: gone from the list, kept for history', async () => {
  const { app } = makeTestApp()
  const c = await create(app, '写作')
  const res = await app.request(`/categories/${c.id}`, { method: 'DELETE', headers: authHeader })
  expect(await res.json()).toEqual({ ok: true })
  expect(await list(app)).toEqual([])
  expect(await list(app, true)).toEqual([expect.objectContaining({ id: c.id, archived: true })])
  // 删除后不能再改
  const patch = await app.request(`/categories/${c.id}`, { method: 'PATCH', headers: json, body: JSON.stringify({ name: 'x' }) })
  expect(patch.status).toBe(404)
})

it('rejects bad bodies and other users\' categories', async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'o', apiTokenHash: hashToken('x'), createdAt: new Date() }).run()
  db.insert(categories).values({ id: 'theirs', userId: 'u2', name: 'T', color: 'red' }).run()
  for (const body of [{}, { name: '' }, { name: 'x'.repeat(61) }]) {
    const res = await app.request('/categories/theirs', { method: 'PATCH', headers: json, body: JSON.stringify(body) })
    expect(res.status).toBe(400)
  }
  expect((await app.request('/categories/theirs', { method: 'PATCH', headers: json, body: JSON.stringify({ name: 'mine' }) })).status).toBe(404)
  expect((await app.request('/categories/theirs', { method: 'DELETE', headers: authHeader })).status).toBe(404)
  expect(db.select().from(categories).all()).toEqual([expect.objectContaining({ id: 'theirs', name: 'T', archived: false })])
  expect((await app.request('/categories', { method: 'POST', headers: json, body: JSON.stringify({ name: ' ' }) })).status).toBe(400)
})
