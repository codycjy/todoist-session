import { and, eq, inArray, sql } from 'drizzle-orm'
import { Hono } from 'hono'
import { z } from 'zod'
import type { AppEnv } from '../auth.js'
import { atomic, type Db } from '../db/client.js'
import { activitySpans, categories, entries, evaluations, sessions } from '../db/schema.js'

const id = z.string().min(1).max(64)
const ms = z.number().int().nonnegative()
const spanSchema = z.object({
  id,
  kind: z.enum(['active', 'idle']),
  appBundleId: z.string().nullable(),
  appName: z.string().nullable(),
  windowTitle: z.string().nullable(),
  urlHost: z.string().nullable(),
  urlPath: z.string().nullable(),
  startedAt: ms,
  endedAt: ms,
  wasBlocked: z.boolean(),
})
const sessionSchema = z.object({
  id,
  categoryId: z.string().nullable(),
  source: z.enum(['todoist', 'custom']),
  todoistTaskId: z.string().nullable(),
  entryId: z.string().nullable(),
  title: z.string().min(1),
  plannedSeconds: z.number().int().positive(),
  actualSeconds: z.number().int().nonnegative(),
  startedAt: ms,
  endedAt: ms,
  allowIdle: z.boolean().default(false), // 旧客户端不传
  spans: z.array(spanSchema).max(5000),
})
const bodySchema = z.object({ sessions: z.array(sessionSchema).min(1).max(50) })
const deletionSchema = z.object({ ids: z.array(id).min(1).max(100) })

const ID_CHUNK = 50

type Rejection = { id: string; reason: 'CONFLICT' | 'INVALID_TIME' }

export interface SyncOptions {
  now: () => number
  model: string
  promptVersion: string
}

/**
 * 一条语句插入一个 session 的全部 span：span 以 JSON 作为单个参数传入，由 json_each 展开。
 * D1 每条语句最多 100 个绑定参数，逐行绑定的话 5000 条 span 要拆成几百条语句。
 */
function insertSpans(db: Db, s: z.infer<typeof sessionSchema>) {
  const rows = JSON.stringify(s.spans)
  // 列顺序须与 activitySpans 的定义一致。用 insert().select() 而不是 db.run(sql)：drizzle 的 D1 batch 不支持带参数的 raw 查询。
  return db.insert(activitySpans).select(sql`
    SELECT json_extract(value, '$.id'), ${s.id}, json_extract(value, '$.kind'), json_extract(value, '$.appBundleId'),
      json_extract(value, '$.appName'), json_extract(value, '$.windowTitle'), json_extract(value, '$.urlHost'),
      json_extract(value, '$.urlPath'), json_extract(value, '$.startedAt'), json_extract(value, '$.endedAt'),
      json_extract(value, '$.wasBlocked')
    FROM json_each(${rows}) WHERE true`).onConflictDoNothing() // WHERE 是 SQLite 语法要求：否则 ON CONFLICT 有歧义
}

export function syncRoutes(db: Db, opts: SyncOptions) {
  const r = new Hono<AppEnv>()

  r.post('/sessions', async (c) => {
    const parsed = bodySchema.safeParse(await c.req.json().catch(() => null))
    if (!parsed.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const userId = c.get('user').id
    const accepted: string[] = []
    const rejected: Rejection[] = []

    for (const s of parsed.data.sessions) {
      const timesOk = s.endedAt >= s.startedAt && s.spans.every((p) => p.endedAt >= p.startedAt)
      if (!timesOk) { rejected.push({ id: s.id, reason: 'INVALID_TIME' }); continue }

      const existing = await db.select({ userId: sessions.userId, allowIdle: sessions.allowIdle })
        .from(sessions).where(eq(sessions.id, s.id)).get()
      if (existing && existing.userId !== userId) { rejected.push({ id: s.id, reason: 'CONFLICT' }); continue }

      const ownCategory = s.categoryId && await db.select({ id: categories.id }).from(categories)
        .where(and(eq(categories.id, s.categoryId), eq(categories.userId, userId))).get()
      const categoryId = ownCategory ? s.categoryId : null

      if (existing) {
        // 重传 = 客户端编辑过（标题、分类、时长、可闲置）：覆盖可编辑字段并替换 span。
        // 评估一般保留；只有「可闲置」变了才重评，因为它改变了闲置该怎么算。
        const requeue = existing.allowIdle !== s.allowIdle
        await atomic(db, [
          () => db.update(sessions).set({
            titleSnapshot: s.title, categoryId, actualSeconds: s.actualSeconds, endedAt: new Date(s.endedAt),
            allowIdle: s.allowIdle,
          }).where(eq(sessions.id, s.id)),
          ...(requeue ? [() => db.update(evaluations)
            .set({ status: 'pending' as const, attempts: 0, lastError: null, updatedAt: new Date(opts.now()) })
            .where(eq(evaluations.sessionId, s.id))] : []),
          () => db.delete(activitySpans).where(eq(activitySpans.sessionId, s.id)),
          () => insertSpans(db, s),
        ])
        accepted.push(s.id)
        continue
      }

      const ownEntry = s.entryId && await db.select({ id: entries.id }).from(entries)
        .where(and(eq(entries.id, s.entryId), eq(entries.userId, userId))).get()
      const entryId = ownEntry ? s.entryId : null
      const at = new Date(opts.now())
      await atomic(db, [
        () => db.insert(sessions).values({
          id: s.id, userId, categoryId, source: s.source, todoistTaskId: s.todoistTaskId, entryId,
          titleSnapshot: s.title, plannedSeconds: s.plannedSeconds, actualSeconds: s.actualSeconds,
          startedAt: new Date(s.startedAt), endedAt: new Date(s.endedAt), allowIdle: s.allowIdle,
        }).onConflictDoNothing(),
        () => db.insert(evaluations).values({
          sessionId: s.id, userId, model: opts.model, promptVersion: opts.promptVersion,
          createdAt: at, updatedAt: at,
        }).onConflictDoNothing(),
        () => insertSpans(db, s),
      ])
      accepted.push(s.id)
    }
    return c.json({ accepted, rejected })
  })

  // 客户端删除的 session：连同 span 与评估一起删。不存在或属于别人的 id 也算处理完（幂等），
  // 客户端据此清掉本地的删除记录。
  r.post('/deletions', async (c) => {
    const parsed = deletionSchema.safeParse(await c.req.json().catch(() => null))
    if (!parsed.success) return c.json({ error: 'BAD_REQUEST' }, 400)
    const userId = c.get('user').id
    // 分块：D1 每条语句最多 100 个绑定参数
    for (let i = 0; i < parsed.data.ids.length; i += ID_CHUNK) {
      const ids = parsed.data.ids.slice(i, i + ID_CHUNK)
      const own = (await db.select({ id: sessions.id }).from(sessions)
        .where(and(eq(sessions.userId, userId), inArray(sessions.id, ids))).all()).map((r) => r.id)
      if (own.length === 0) continue
      await atomic(db, [
        () => db.delete(activitySpans).where(inArray(activitySpans.sessionId, own)),
        () => db.delete(evaluations).where(inArray(evaluations.sessionId, own)),
        () => db.delete(sessions).where(and(eq(sessions.userId, userId), inArray(sessions.id, own))),
      ])
    }
    return c.json({ deleted: parsed.data.ids })
  })

  return r
}
