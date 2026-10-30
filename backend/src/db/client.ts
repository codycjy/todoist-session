import Database from 'better-sqlite3'
import type { BatchItem } from 'drizzle-orm/batch'
import { drizzle, type BetterSQLite3Database } from 'drizzle-orm/better-sqlite3'
import { migrate } from 'drizzle-orm/better-sqlite3/migrator'
import type { DrizzleD1Database } from 'drizzle-orm/d1'
import type { BaseSQLiteDatabase } from 'drizzle-orm/sqlite-core'
import * as schema from './schema.js'

/**
 * 同一套路由同时跑在 Node（better-sqlite3，同步）和 Cloudflare Workers（D1，异步）上：
 * 查询一律 `await`，多条写入用 `atomic()`，不用交互式事务（D1 不支持）。
 */
export type Db = BaseSQLiteDatabase<'sync' | 'async', unknown, typeof schema>
export type NodeDb = ReturnType<typeof createDb>

export function createDb(path: string) {
  const sqlite = new Database(path)
  sqlite.pragma('journal_mode = WAL')
  sqlite.pragma('foreign_keys = ON')
  const db = drizzle(sqlite, { schema })
  migrate(db, { migrationsFolder: new URL('../../drizzle', import.meta.url).pathname })
  return db
}

type Step = () => unknown

/**
 * 原子地执行一组写入。每一步返回一条尚未执行的查询（insert/update/delete 构造器或 `db.run(sql)`）：
 * D1 上整组作为一个 batch 提交；better-sqlite3 上在同一个同步事务里依次执行。
 * 用函数包一层，是因为同步驱动的 `db.run(sql)` 一调用就执行，必须轮到它时才构造。
 */
export async function atomic(db: Db, steps: Step[]): Promise<void> {
  if (steps.length === 0) return
  if ('batch' in db) {
    const items = steps.map((f) => f()) as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]]
    await (db as unknown as DrizzleD1Database<typeof schema>).batch(items)
    return
  }
  ;(db as unknown as BetterSQLite3Database<typeof schema>).transaction(() => {
    for (const f of steps) {
      const q = f()
      if (q && typeof (q as { run?: unknown }).run === 'function') (q as { run(): unknown }).run()
    }
  })
}
