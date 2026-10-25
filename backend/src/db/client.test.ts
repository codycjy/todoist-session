import { expect, it } from 'vitest'
import { createDb } from './client.js'
import { categories, users } from './schema.js'

it('createDb applies migrations and supports inserts', () => {
  const db = createDb(':memory:')
  db.insert(users).values({ id: 'u1', name: 'me', apiTokenHash: 'h', createdAt: new Date() }).run()
  const row = db.select().from(users).get()
  expect(row?.name).toBe('me')
  expect(row?.settings).toEqual({})
})

it('allows multiple categories with NULL todoist_project_id but not duplicate project ids', () => {
  const db = createDb(':memory:')
  db.insert(users).values({ id: 'u1', name: 'me', apiTokenHash: 'h', createdAt: new Date() }).run()
  const base = { userId: 'u1', color: 'red' }
  db.insert(categories).values({ ...base, id: 'c1', name: 'A' }).run()
  db.insert(categories).values({ ...base, id: 'c2', name: 'B' }).run()
  db.insert(categories).values({ ...base, id: 'c3', name: 'C', todoistProjectId: 'p1' }).run()
  expect(() =>
    db.insert(categories).values({ ...base, id: 'c4', name: 'D', todoistProjectId: 'p1' }).run(),
  ).toThrow()
})

it('creates sessions and activity_spans tables via migrations', () => {
  const db = createDb(':memory:')
  const names = db.$client
    .prepare("select name from sqlite_master where type = 'table'")
    .all()
    .map((r) => (r as { name: string }).name)
  expect(names).toEqual(expect.arrayContaining(['sessions', 'activity_spans']))
})
