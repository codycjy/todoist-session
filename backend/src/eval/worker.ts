import { and, asc, eq, lt } from 'drizzle-orm'
import type { Db } from '../db/client.js'
import { activitySpans, categories, evaluations, sessions } from '../db/schema.js'
import { EvalError, type EvalInput, type Evaluator } from './types.js'

export const MAX_ATTEMPTS = 3
export const BATCH_SIZE = 5

export interface EvalWorkerDeps {
  db: Db
  evaluator: Evaluator
  now: () => number
}

export interface EvalWorker {
  /** 领取并顺序处理一批 pending 评估，返回实际处理的数量 */
  runOnce(): Promise<number>
}

export function createEvalWorker({ db, evaluator, now }: EvalWorkerDeps): EvalWorker {
  // 正在处理的 session id；与处理前的状态复查一起避免重复领取
  const inFlight = new Set<string>()

  function loadInput(sessionId: string): EvalInput | null {
    const s = db.select().from(sessions).where(eq(sessions.id, sessionId)).get()
    if (!s) return null
    const category = s.categoryId
      ? db.select({ name: categories.name }).from(categories).where(eq(categories.id, s.categoryId)).get()
      : undefined
    const spans = db.select().from(activitySpans).where(eq(activitySpans.sessionId, sessionId))
      .orderBy(asc(activitySpans.startedAt)).all()
    return {
      title: s.titleSnapshot,
      categoryName: category?.name ?? null,
      plannedSeconds: s.plannedSeconds,
      actualSeconds: s.actualSeconds,
      startedAt: s.startedAt.getTime(),
      endedAt: s.endedAt.getTime(),
      spans: spans.map((p) => ({
        kind: p.kind, appBundleId: p.appBundleId, appName: p.appName, windowTitle: p.windowTitle,
        urlHost: p.urlHost, startedAt: p.startedAt.getTime(), endedAt: p.endedAt.getTime(), wasBlocked: p.wasBlocked,
      })),
    }
  }

  async function process(sessionId: string): Promise<boolean> {
    // 轮到它时再复查一次：期间可能已被重置/终结
    const row = db.select().from(evaluations).where(eq(evaluations.sessionId, sessionId)).get()
    if (!row || row.status !== 'pending' || row.attempts >= MAX_ATTEMPTS) return false
    const input = loadInput(sessionId)
    const attempt = row.attempts + 1
    const stillPending = and(eq(evaluations.sessionId, sessionId), eq(evaluations.status, 'pending'))

    let error: string | null = null
    let result
    if (!input) error = 'API_ERROR'
    else {
      try {
        result = await evaluator.evaluate(input)
      } catch (err) {
        error = err instanceof EvalError ? err.category : 'API_ERROR'
      }
    }

    if (result) {
      db.update(evaluations).set({
        status: 'done', attempts: attempt, focusScore: result.focusScore, summary: result.summary,
        distractions: result.distractions, lastError: null, updatedAt: new Date(now()),
      }).where(stillPending).run()
    } else {
      db.update(evaluations).set({
        status: attempt >= MAX_ATTEMPTS ? 'failed' : 'pending', attempts: attempt,
        lastError: error, updatedAt: new Date(now()),
      }).where(stillPending).run()
    }
    return true
  }

  return {
    async runOnce() {
      const candidates = db.select({ sessionId: evaluations.sessionId }).from(evaluations)
        .where(and(eq(evaluations.status, 'pending'), lt(evaluations.attempts, MAX_ATTEMPTS)))
        .orderBy(asc(evaluations.createdAt)).limit(BATCH_SIZE).all()
      let processed = 0
      for (const { sessionId } of candidates) {
        if (inFlight.has(sessionId)) continue
        inFlight.add(sessionId)
        try {
          if (await process(sessionId)) processed++
        } finally {
          inFlight.delete(sessionId)
        }
      }
      return processed
    },
  }
}
