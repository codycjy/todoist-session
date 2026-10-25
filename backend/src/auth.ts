import { eq } from 'drizzle-orm'
import type { MiddlewareHandler } from 'hono'
import { hashToken } from './crypto.js'
import type { Db } from './db/client.js'
import { users, type User } from './db/schema.js'

export type AppEnv = { Variables: { user: User } }

export function auth(db: Db): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const match = /^Bearer (.+)$/.exec(c.req.header('Authorization') ?? '')
    const user = match?.[1]
      ? db.select().from(users).where(eq(users.apiTokenHash, hashToken(match[1]))).get()
      : undefined
    if (!user) return c.json({ error: 'UNAUTHORIZED' }, 401)
    c.set('user', user)
    await next()
  }
}
