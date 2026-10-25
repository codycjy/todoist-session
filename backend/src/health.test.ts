import { expect, it } from 'vitest'
import { makeTestApp } from './testing.js'

it('GET /health returns ok without auth', async () => {
  const { app } = makeTestApp()
  const res = await app.request('/health')
  expect(res.status).toBe(200)
  expect(await res.json()).toEqual({ ok: true })
})
