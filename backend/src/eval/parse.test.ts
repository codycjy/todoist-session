import { describe, expect, it } from 'vitest'
import { parseEvalOutput } from './parse.js'
import { EvalError } from './types.js'

const ctx = { startedAt: 10_000, endedAt: 10_000 + 600_000 } // 600s session

const ok = (over: Record<string, unknown> = {}) => ({
  focus_score: 82, summary: 'steady work', distractions: [], ...over,
})

describe('parseEvalOutput', () => {
  it('converts relative seconds into absolute milliseconds', () => {
    const r = parseEvalOutput(ok({ distractions: [{ start_sec: 60, end_sec: 120, reason: 'youtube' }] }), ctx)
    expect(r).toEqual({
      focusScore: 82, summary: 'steady work',
      distractions: [{ start: 70_000, end: 130_000, reason: 'youtube' }],
    })
  })

  it('rounds and clamps the score into 0..100', () => {
    expect(parseEvalOutput(ok({ focus_score: 81.6 }), ctx).focusScore).toBe(82)
    expect(parseEvalOutput(ok({ focus_score: 150 }), ctx).focusScore).toBe(100)
    expect(parseEvalOutput(ok({ focus_score: -4 }), ctx).focusScore).toBe(0)
  })

  it('drops out-of-range or malformed distractions but keeps the valid ones', () => {
    const r = parseEvalOutput(ok({ distractions: [
      { start_sec: -1, end_sec: 10, reason: 'before start' },
      { start_sec: 590, end_sec: 601, reason: 'after end' },
      { start_sec: 50, end_sec: 50, reason: 'empty' },
      { start_sec: 80, end_sec: 70, reason: 'inverted' },
      { start_sec: 'a', end_sec: 70, reason: 'nan' },
      { start_sec: 10, end_sec: 20, reason: '' },
      null,
      { start_sec: 0, end_sec: 600, reason: 'whole session' },
    ] }), ctx)
    expect(r.distractions).toEqual([{ start: 10_000, end: 610_000, reason: 'whole session' }])
  })

  it('treats a missing distractions field as empty and truncates long text', () => {
    const r = parseEvalOutput({ focus_score: 50, summary: 's'.repeat(500) }, ctx)
    expect(r.distractions).toEqual([])
    expect(r.summary).toHaveLength(200)
    const d = parseEvalOutput(ok({ distractions: [{ start_sec: 1, end_sec: 2, reason: 'r'.repeat(500) }] }), ctx)
    expect(d.distractions[0]!.reason).toHaveLength(200)
  })

  it.each([
    ['null', null],
    ['string', 'nope'],
    ['missing score', { summary: 'x' }],
    ['non-numeric score', ok({ focus_score: 'high' })],
    ['NaN score', ok({ focus_score: Number.NaN })],
    ['missing summary', { focus_score: 5 }],
    ['empty summary', ok({ summary: '  ' })],
    ['distractions not an array', ok({ distractions: 'x' })],
  ])('throws BAD_OUTPUT for %s', (_n, raw) => {
    expect(() => parseEvalOutput(raw, ctx)).toThrowError(EvalError)
    try { parseEvalOutput(raw, ctx) } catch (e) { expect((e as EvalError).category).toBe('BAD_OUTPUT') }
  })
})
