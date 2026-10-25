import { expect, it, vi } from 'vitest'
import { TodoistAuthError, type TodoistGateway } from '../todoist/gateway.js'
import { authHeader, makeTestApp } from '../testing.js'
import { categories, users } from '../db/schema.js'

const task = { id: 't1', content: '写周报', projectId: 'p1', priority: 4, dueDate: '2026-10-24', isRecurring: false }

function gatewayWith(overrides: Partial<TodoistGateway> = {}): TodoistGateway {
  return {
    tasks: vi.fn(async () => [task]),
    projects: vi.fn(async () => [{ id: 'p1', name: 'Work', color: 'blue' }]),
    ...overrides,
  }
}

it('returns tasks; filter=today also includes overdue', async () => {
  const gateway = gatewayWith()
  const { app } = makeTestApp({ gateway })
  const res = await app.request('/todoist/tasks?filter=today', { headers: authHeader })
  expect(res.status).toBe(200)
  expect(await res.json()).toEqual({ tasks: [task] })
  expect(gateway.tasks).toHaveBeenCalledWith('today | overdue')
})

it('filter=overdue queries overdue only', async () => {
  const gateway = gatewayWith()
  const { app } = makeTestApp({ gateway })
  await app.request('/todoist/tasks?filter=overdue', { headers: authHeader })
  expect(gateway.tasks).toHaveBeenCalledWith('overdue')
})

it('rejects an unknown filter', async () => {
  const { app } = makeTestApp({ gateway: gatewayWith() })
  const res = await app.request('/todoist/tasks?filter=weird', { headers: authHeader })
  expect(res.status).toBe(400)
  expect(await res.json()).toEqual({ error: 'BAD_REQUEST' })
})

it('caches task lookups for 60 seconds', async () => {
  let t = 0
  const gateway = gatewayWith()
  const { app } = makeTestApp({ gateway, now: () => t })
  await app.request('/todoist/tasks', { headers: authHeader })
  t = 30_000
  await app.request('/todoist/tasks', { headers: authHeader })
  expect(gateway.tasks).toHaveBeenCalledTimes(1)
  t = 61_000
  await app.request('/todoist/tasks', { headers: authHeader })
  expect(gateway.tasks).toHaveBeenCalledTimes(2)
})

it('returns 409 when no Todoist token is configured', async () => {
  const { app } = makeTestApp({ todoistConfigured: false })
  const res = await app.request('/todoist/tasks', { headers: authHeader })
  expect(res.status).toBe(409)
  expect(await res.json()).toEqual({ error: 'TODOIST_NOT_CONFIGURED' })
})

it('maps a Todoist auth failure to 401 TODOIST_AUTH', async () => {
  const gateway = gatewayWith({
    tasks: async () => {
      throw new TodoistAuthError()
    },
  })
  const { app } = makeTestApp({ gateway })
  const res = await app.request('/todoist/tasks', { headers: authHeader })
  expect(res.status).toBe(401)
  expect(await res.json()).toEqual({ error: 'TODOIST_AUTH' })
})

it('projects upserts categories idempotently and picks up renames', async () => {
  let name = 'Work'
  const gateway = gatewayWith({ projects: async () => [{ id: 'p1', name, color: 'blue' }] })
  const { app, db } = makeTestApp({ gateway })

  const first = await app.request('/todoist/projects', { headers: authHeader })
  expect((await first.json()).categories).toHaveLength(1)

  name = 'Work 2'
  const second = await app.request('/todoist/projects', { headers: authHeader })
  const body = await second.json()
  expect(body.categories).toHaveLength(1)
  expect(body.categories[0]).toMatchObject({ name: 'Work 2', color: 'blue', todoistProjectId: 'p1' })
  expect(db.select().from(categories).all()).toHaveLength(1)
})

it('returns 409 TODOIST_TOKEN_UNREADABLE when the stored token cannot be decrypted', async () => {
  const { app, db } = makeTestApp({ gateway: gatewayWith() })
  db.update(users).set({ todoistTokenEnc: 'garbage' }).run()
  for (const path of ['/todoist/tasks', '/todoist/projects']) {
    const res = await app.request(path, { headers: authHeader })
    expect(res.status).toBe(409)
    expect(await res.json()).toEqual({ error: 'TODOIST_TOKEN_UNREADABLE' })
  }
})

it('maps unexpected errors to a JSON 500 INTERNAL', async () => {
  const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
  const gateway = gatewayWith({ tasks: vi.fn(async () => { throw new Error('boom') }) })
  const { app } = makeTestApp({ gateway })
  const res = await app.request('/todoist/tasks', { headers: authHeader })
  expect(res.status).toBe(500)
  expect(await res.json()).toEqual({ error: 'INTERNAL' })
  spy.mockRestore()
})
