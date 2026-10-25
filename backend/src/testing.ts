import { createApp } from './app.js'
import { encrypt, hashToken } from './crypto.js'
import { createDb } from './db/client.js'
import { users } from './db/schema.js'
import type { TodoistGateway } from './todoist/gateway.js'

export const TEST_SECRET = 'test-secret'
export const TEST_TOKEN = 'test-token'
export const authHeader = { Authorization: `Bearer ${TEST_TOKEN}` }

export function makeTestApp(opts: { gateway?: TodoistGateway; todoistConfigured?: boolean; now?: () => number } = {}) {
  const db = createDb(':memory:')
  db.insert(users)
    .values({
      id: 'u1',
      name: 'me',
      apiTokenHash: hashToken(TEST_TOKEN),
      todoistTokenEnc: opts.todoistConfigured === false ? null : encrypt('todoist-token', TEST_SECRET),
      createdAt: new Date(),
    })
    .run()
  const gateway = opts.gateway ?? { tasks: async () => [], projects: async () => [] }
  const app = createApp({ db, makeGateway: () => gateway, secret: TEST_SECRET, now: opts.now })
  return { app, db, gateway }
}
