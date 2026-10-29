import { eq } from 'drizzle-orm'
import { describe, expect, it, vi } from 'vitest'
import { activitySpans, categories, evaluations, sessions } from '../db/schema.js'
import { makeTestApp } from '../testing.js'
import { createEvalWorker } from './worker.js'
import { EvalError, type EvalInput, type Evaluator } from './types.js'

function setup(count = 1) {
  const { db } = makeTestApp()
  db.insert(categories).values({ id: 'c1', userId: 'u1', name: '工作', color: 'red' }).run()
  for (let i = 1; i <= count; i++) {
    db.insert(sessions).values({
      id: `s${i}`, userId: 'u1', categoryId: 'c1', source: 'custom', titleSnapshot: `task ${i}`,
      plannedSeconds: 1500, actualSeconds: 600, startedAt: new Date(10_000), endedAt: new Date(610_000),
    }).run()
    db.insert(activitySpans).values({
      id: `p${i}`, sessionId: `s${i}`, kind: 'active', appName: 'Xcode', appBundleId: 'x', windowTitle: 'a.swift',
      startedAt: new Date(10_000), endedAt: new Date(70_000),
    }).run()
    db.insert(evaluations).values({
      sessionId: `s${i}`, userId: 'u1', model: 'm', promptVersion: 'v1',
      createdAt: new Date(i), updatedAt: new Date(i),
    }).run()
  }
  return db
}
const row = (db: ReturnType<typeof setup>, id: string) =>
  db.select().from(evaluations).where(eq(evaluations.sessionId, id)).get()!

const good: Evaluator = {
  evaluate: async () => ({ focusScore: 77, summary: 'fine', distractions: [{ start: 1, end: 2, reason: 'r' }] }),
}

describe('eval worker', () => {
  it('evaluates pending rows and stores the result', async () => {
    const db = setup()
    const seen: EvalInput[] = []
    const w = createEvalWorker({ db, now: () => 99_000, evaluator: { evaluate: async (i) => { seen.push(i); return good.evaluate(i) } } })
    expect(await w.runOnce()).toBe(1)
    expect(row(db, 's1')).toMatchObject({
      status: 'done', focusScore: 77, summary: 'fine', attempts: 1, lastError: null,
      distractions: [{ start: 1, end: 2, reason: 'r' }],
    })
    expect(row(db, 's1').updatedAt.getTime()).toBe(99_000)
    expect(seen[0]).toMatchObject({
      title: 'task 1', categoryName: '工作', plannedSeconds: 1500, actualSeconds: 600,
      startedAt: 10_000, endedAt: 610_000, allowIdle: false,
    })
    expect(seen[0]!.spans).toEqual([expect.objectContaining({ appName: 'Xcode', startedAt: 10_000, endedAt: 70_000 })])
    expect(await w.runOnce()).toBe(0)
  })

  it('records only the error category and retries until 3 attempts, then fails', async () => {
    const db = setup()
    const evaluate = vi.fn().mockRejectedValue(new EvalError('BAD_OUTPUT'))
    const w = createEvalWorker({ db, now: () => 1, evaluator: { evaluate } })
    await w.runOnce()
    expect(row(db, 's1')).toMatchObject({ status: 'pending', attempts: 1, lastError: 'BAD_OUTPUT' })
    await w.runOnce()
    expect(row(db, 's1')).toMatchObject({ status: 'pending', attempts: 2 })
    await w.runOnce()
    expect(row(db, 's1')).toMatchObject({ status: 'failed', attempts: 3, lastError: 'BAD_OUTPUT' })
    expect(await w.runOnce()).toBe(0)
    expect(evaluate).toHaveBeenCalledTimes(3)
  })

  it('maps unknown errors to API_ERROR without storing the message', async () => {
    const db = setup()
    const w = createEvalWorker({ db, now: () => 1, evaluator: { evaluate: async () => { throw new Error('leaky sk-fake body') } } })
    await w.runOnce()
    expect(row(db, 's1').lastError).toBe('API_ERROR')
  })

  it('takes at most 5 per run, oldest first, one at a time', async () => {
    const db = setup(7)
    let active = 0, maxActive = 0
    const order: string[] = []
    const w = createEvalWorker({ db, now: () => 1, evaluator: { evaluate: async (i) => {
      active++; maxActive = Math.max(maxActive, active)
      order.push(i.title)
      await new Promise((r) => setTimeout(r, 1))
      active--
      return good.evaluate(i)
    } } })
    expect(await w.runOnce()).toBe(5)
    expect(maxActive).toBe(1)
    expect(order).toEqual(['task 1', 'task 2', 'task 3', 'task 4', 'task 5'])
    expect(await w.runOnce()).toBe(2)
  })

  it('never evaluates the same row twice when runs overlap', async () => {
    const db = setup(2)
    let release!: () => void
    const gate = new Promise<void>((r) => { release = r })
    const evaluate = vi.fn(async (i: EvalInput) => { await gate; return good.evaluate(i) })
    const w = createEvalWorker({ db, now: () => 1, evaluator: { evaluate } })
    const first = w.runOnce()
    const second = w.runOnce() // first is blocked on s1; s1 is in-flight
    await new Promise((r) => setTimeout(r, 5))
    release()
    const [a, b] = await Promise.all([first, second])
    expect(evaluate).toHaveBeenCalledTimes(2)
    expect(a + b).toBe(2)
    expect(row(db, 's1').attempts).toBe(1)
    expect(row(db, 's2').attempts).toBe(1)
  })

  it('skips rows that are no longer pending when their turn comes (e.g. reset elsewhere)', async () => {
    const db = setup(2)
    const evaluate = vi.fn(async (i: EvalInput) => {
      db.update(evaluations).set({ status: 'failed', attempts: 3 }).where(eq(evaluations.sessionId, 's2')).run()
      return good.evaluate(i)
    })
    const w = createEvalWorker({ db, now: () => 1, evaluator: { evaluate } })
    expect(await w.runOnce()).toBe(1)
    expect(evaluate).toHaveBeenCalledTimes(1)
    expect(row(db, 's2').status).toBe('failed')
  })

  it('picks a retried (reset) evaluation up again', async () => {
    const db = setup()
    const w = createEvalWorker({ db, now: () => 1, evaluator: good })
    await w.runOnce()
    db.update(evaluations).set({ status: 'pending', attempts: 0, lastError: null }).run()
    expect(await w.runOnce()).toBe(1)
  })
  describe('superseded in-flight evaluations', () => {
    const reset = (db: ReturnType<typeof setup>) =>
      db.update(evaluations).set({ status: 'pending', attempts: 0, lastError: null, focusScore: null, summary: null, updatedAt: new Date(5000) }).run()

    it('a stale failure does not touch a row that was retried mid-flight', async () => {
      const db = setup()
      const w = createEvalWorker({ db, now: () => 9000, evaluator: { evaluate: async () => { reset(db); throw new EvalError('BAD_OUTPUT') } } })
      await w.runOnce()
      expect(row(db, 's1')).toMatchObject({ status: 'pending', attempts: 0, lastError: null })
      expect(row(db, 's1').updatedAt.getTime()).toBe(5000)
    })

    it('a stale success does not overwrite a row that was retried mid-flight', async () => {
      const db = setup()
      const w = createEvalWorker({ db, now: () => 9000, evaluator: { evaluate: async (i) => { reset(db); return good.evaluate(i) } } })
      await w.runOnce()
      expect(row(db, 's1')).toMatchObject({ status: 'pending', attempts: 0, focusScore: null, summary: null })
    })
  })
})
