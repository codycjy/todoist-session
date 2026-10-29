import { expect, it, vi } from 'vitest'
import { TodoistAuthError, type TodoistGateway } from '../todoist/gateway.js'
import { authHeader, makeTestApp } from '../testing.js'
import { users } from '../db/schema.js'

const task = { id: 't1', content: '写周报', projectId: 'p1', priority: 4, dueDate: '2026-10-24', isRecurring: false, durationMinutes: null, description: '', labels: [], parentId: null, url: 'https://app.todoist.com/app/task/t1' }

function gatewayWith(overrides: Partial<TodoistGateway> = {}): TodoistGateway {
  return {
    tasks: vi.fn(async () => [task]),
    projects: vi.fn(async () => [{ id: 'p1', name: 'Work', color: 'blue' }]),
    ...overrides,
  }
}

it('returns tasks; filter=today queries today only', async () => {
  const gateway = gatewayWith()
  const { app } = makeTestApp({ gateway })
  const res = await app.request('/todoist/tasks?filter=today', { headers: authHeader })
  expect(res.status).toBe(200)
  expect(await res.json()).toEqual({ tasks: [task] })
  expect(gateway.tasks).toHaveBeenCalledWith('today')
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

it('returns 409 TODOIST_TOKEN_UNREADABLE when the stored token cannot be decrypted', async () => {
  const { app, db } = makeTestApp({ gateway: gatewayWith() })
  db.update(users).set({ todoistTokenEnc: 'garbage' }).run()
  for (const path of ['/todoist/tasks']) {
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
