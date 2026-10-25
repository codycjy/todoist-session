import { expect, it } from 'vitest'
import { Hono } from 'hono'
import { createApp } from './app.js'

it('GET /health returns ok without auth', async () => {
  const app: Hono = createApp()
  const res = await app.request('/health')
  expect(res.status).toBe(200)
  expect(await res.json()).toEqual({ ok: true })
})
