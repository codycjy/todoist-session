import { randomBytes, randomUUID } from 'node:crypto'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { encrypt, hashToken } from '../crypto.js'
import { createDb } from '../db/client.js'
import { users } from '../db/schema.js'

function arg(name: string) {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 ? process.argv[i + 1] : undefined
}

const secret = process.env.APP_SECRET
const todoistToken = arg('todoist-token')
if (!secret || !todoistToken) {
  console.error('usage: APP_SECRET=... npm run seed -- --name <name> --todoist-token <token>')
  process.exit(1)
}

const dbPath = process.env.DB_PATH ?? './data/session.db'
mkdirSync(dirname(dbPath), { recursive: true })

const apiToken = randomBytes(24).toString('hex')
createDb(dbPath)
  .insert(users)
  .values({
    id: randomUUID(),
    name: arg('name') ?? 'me',
    apiTokenHash: hashToken(apiToken),
    todoistTokenEnc: encrypt(todoistToken, secret),
    createdAt: new Date(),
  })
  .run()

console.log(`API token (save it, it is shown only once):\n${apiToken}`)
