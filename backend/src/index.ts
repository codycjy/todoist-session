import { serve } from '@hono/node-server'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { createApp } from './app.js'
import { createDb } from './db/client.js'
import { createTodoistGateway } from './todoist/sdk.js'

const secret = process.env.APP_SECRET
if (!secret) throw new Error('APP_SECRET is required')

const dbPath = process.env.DB_PATH ?? './data/session.db'
mkdirSync(dirname(dbPath), { recursive: true })

const app = createApp({ db: createDb(dbPath), makeGateway: createTodoistGateway, secret })
const port = Number(process.env.PORT ?? 8787)
serve({ fetch: app.fetch, port }, () => console.log(`session-backend listening on :${port}`))
