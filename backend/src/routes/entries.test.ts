import { expect, it } from 'vitest'
import { categories, users } from '../db/schema.js'
import { authHeader, makeTestApp } from '../testing.js'

const json = (body: unknown) => ({
  method: 'POST',
  headers: { ...authHeader, 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
})

it('creates a custom category', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/categories', json({ name: '阅读', color: 'green' }))
  expect(res.status).toBe(200)
  const { category } = await res.json()
  expect(category).toMatchObject({ name: '阅读', color: 'green', todoistProjectId: null })

  const list = await (await app.request('/categories', { headers: authHeader })).json()
  expect(list.categories).toHaveLength(1)
})

it('rejects an invalid category body', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/categories', json({ name: '' }))
  expect(res.status).toBe(400)
})

it('creates an entry and lists it', async () => {
  const { app } = makeTestApp()
  const { category } = await (await app.request('/categories', json({ name: 'c', color: 'red' }))).json()
  const res = await app.request('/entries', json({ title: '读论文', categoryId: category.id }))
  const { entry } = await res.json()
  expect(entry).toMatchObject({ title: '读论文', categoryId: category.id })

  const list = await (await app.request('/entries', { headers: authHeader })).json()
  expect(list.entries).toEqual([entry])
})

it('reuses an entry with the same title and category and moves it to the top', async () => {
  let t = 1_000
  const { app } = makeTestApp({ now: () => t })
  const a = (await (await app.request('/entries', json({ title: 'A', categoryId: null }))).json()).entry
  t = 2_000
  await app.request('/entries', json({ title: 'B', categoryId: null }))
  t = 3_000
  const again = (await (await app.request('/entries', json({ title: 'A', categoryId: null }))).json()).entry
  expect(again.id).toBe(a.id)

  const list = await (await app.request('/entries', { headers: authHeader })).json()
  expect(list.entries.map((e: { title: string }) => e.title)).toEqual(['A', 'B'])
})

it('rejects an entry referencing a category that does not exist', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/entries', json({ title: 'x', categoryId: 'missing' }))
  expect(res.status).toBe(400)
})

it("rejects an entry referencing another user's category", async () => {
  const { app, db } = makeTestApp()
  db.insert(users).values({ id: 'u2', name: 'other', apiTokenHash: 'h2', todoistTokenEnc: null, createdAt: new Date() }).run()
  db.insert(categories).values({ id: 'c-other', userId: 'u2', name: 'x', color: 'red' }).run()
  const res = await app.request('/entries', json({ title: 'x', categoryId: 'c-other' }))
  expect(res.status).toBe(400)
})
