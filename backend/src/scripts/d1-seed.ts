import { randomBytes } from 'node:crypto'
import { writeFileSync } from 'node:fs'
import { encrypt, hashToken } from '../crypto.js'

/**
 * D1 版的 `npm run seed`：生成一条建用户的 SQL 文件，并打印 API token（只显示这一次）。
 * APP_SECRET 必须和 `wrangler secret put APP_SECRET` 设的一样，否则 Workers 解不开 Todoist token。
 *
 *   APP_SECRET=... TODOIST_TOKEN=... npm run d1:seed -- --name me --out ./d1-seed.sql
 *   npx wrangler d1 execute now --remote --file ./d1-seed.sql && rm ./d1-seed.sql
 */
function arg(name: string) {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 ? process.argv[i + 1] : undefined
}

const secret = process.env.APP_SECRET
const todoistToken = process.env.TODOIST_TOKEN
if (!secret || !todoistToken) {
  console.error('usage: APP_SECRET=... TODOIST_TOKEN=... npm run d1:seed -- [--name me] [--out ./d1-seed.sql]')
  process.exit(1)
}

const q = (s: string) => `'${s.replace(/'/g, "''")}'`
const apiToken = randomBytes(24).toString('hex')
const out = arg('out') ?? './d1-seed.sql'
const sql = `INSERT INTO users (id, name, api_token_hash, todoist_token_enc, settings, created_at) VALUES (${[
  q(crypto.randomUUID()), q(arg('name') ?? 'me'), q(hashToken(apiToken)), q(encrypt(todoistToken, secret)), q('{}'),
  String(Math.floor(Date.now() / 1000)),
].join(', ')});\n`
writeFileSync(out, sql, { mode: 0o600 })

console.log(`written ${out} — import it with wrangler, then delete it`)
console.log(`API token (save it, it is shown only once):\n${apiToken}`)
