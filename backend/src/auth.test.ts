import { expect, it } from 'vitest'
import { authHeader, makeTestApp } from './testing.js'

it('rejects requests without a bearer token', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/categories')
  expect(res.status).toBe(401)
  expect(await res.json()).toEqual({ error: 'UNAUTHORIZED' })
})

it('rejects an unknown token', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/categories', { headers: { Authorization: 'Bearer nope' } })
  expect(res.status).toBe(401)
})

it('accepts a valid token', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/categories', { headers: authHeader })
  expect(res.status).toBe(200)
})

it('health stays public', async () => {
  const { app } = makeTestApp()
  expect((await app.request('/health')).status).toBe(200)
})
