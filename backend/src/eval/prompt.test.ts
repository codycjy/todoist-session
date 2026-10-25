import { describe, expect, it } from 'vitest'
import { buildTimeline, buildUserPrompt, MAX_SPANS, MAX_TITLE_CHARS } from './prompt.js'
import type { EvalInput, EvalSpan } from './types.js'

const T0 = 1_000_000
const span = (fromSec: number, toSec: number, over: Partial<EvalSpan> = {}): EvalSpan => ({
  kind: 'active', appBundleId: 'com.microsoft.VSCode', appName: 'VS Code', windowTitle: null, urlHost: null,
  startedAt: T0 + fromSec * 1000, endedAt: T0 + toSec * 1000, wasBlocked: false, ...over,
})

describe('buildTimeline', () => {
  it('formats relative mm:ss ranges, titles, hosts, BLOCKED and IDLE', () => {
    const out = buildTimeline([
      span(0, 492, { windowTitle: 'weekly-report.md' }),
      span(492, 580, { appName: 'Chrome', appBundleId: 'c', urlHost: 'github.com' }),
      span(580, 662, { appName: 'Chrome', appBundleId: 'c', urlHost: 'youtube.com', wasBlocked: true }),
      span(662, 870, { kind: 'idle', appBundleId: null, appName: null }),
    ], T0)
    expect(out).toBe([
      '[00:00-08:12] VS Code — "weekly-report.md"',
      '[08:12-09:40] Chrome — github.com',
      '[09:40-11:02] Chrome — youtube.com (BLOCKED)',
      '[11:02-14:30] IDLE',
    ].join('\n'))
  })

  it('falls back to bundle id, then "Unknown", when the app name is missing', () => {
    expect(buildTimeline([span(0, 5, { appName: null })], T0)).toBe('[00:00-00:05] com.microsoft.VSCode')
    expect(buildTimeline([span(0, 5, { appName: null, appBundleId: null })], T0)).toBe('[00:00-00:05] Unknown')
  })

  it('truncates window titles to 120 characters', () => {
    const exact = 'a'.repeat(MAX_TITLE_CHARS)
    expect(buildTimeline([span(0, 1, { windowTitle: exact })], T0)).toContain(`"${exact}"`)
    const out = buildTimeline([span(0, 1, { windowTitle: 'b'.repeat(MAX_TITLE_CHARS + 50) })], T0)
    expect(out).toContain(`"${'b'.repeat(MAX_TITLE_CHARS)}"`)
    expect(out).not.toContain('b'.repeat(MAX_TITLE_CHARS + 1))
  })

  it('flattens newlines in titles and clamps times before the session start to 00:00', () => {
    const out = buildTimeline([span(-5, 3, { windowTitle: 'a\nb' })], T0)
    expect(out).toBe('[00:00-00:03] VS Code — "a b"')
  })

  it('keeps up to 200 spans untouched', () => {
    const spans = Array.from({ length: MAX_SPANS }, (_, i) =>
      span(i * 2, i * 2 + 1, { appBundleId: `app${i % 2}`, appName: `App${i % 2}` }))
    expect(buildTimeline(spans, T0).split('\n')).toHaveLength(MAX_SPANS)
  })

  it('merges adjacent same-app spans only when there are more than 200', () => {
    const spans = Array.from({ length: MAX_SPANS + 1 }, (_, i) => span(i, i + 1, { windowTitle: `w${i}` }))
    const out = buildTimeline(spans, T0)
    expect(out.split('\n')).toHaveLength(1)
    expect(out).toBe(`[00:00-03:21] VS Code — "w0"`)
  })

  it('does not merge across different apps, kinds or blocked state', () => {
    const spans: EvalSpan[] = []
    for (let i = 0; i < 150; i++) {
      spans.push(span(i * 4, i * 4 + 1))
      spans.push(span(i * 4 + 1, i * 4 + 2, { kind: 'idle', appBundleId: null, appName: null }))
      spans.push(span(i * 4 + 2, i * 4 + 3, { appBundleId: 'b', appName: 'B', wasBlocked: true }))
    }
    // 450 spans, none adjacent-equal -> merge is a no-op, then truncated to 200 + note
    const lines = buildTimeline(spans, T0).split('\n')
    expect(lines).toHaveLength(MAX_SPANS + 1)
    expect(lines.at(-1)).toBe('... (250 more spans omitted)')
  })
})

describe('buildUserPrompt', () => {
  const input: EvalInput = {
    title: '写周报', categoryName: '工作', plannedSeconds: 1500, actualSeconds: 1470,
    startedAt: T0, endedAt: T0 + 1_470_000, spans: [span(0, 60, { windowTitle: 'x' })],
  }

  it('includes title, category, durations and the timeline', () => {
    const p = buildUserPrompt(input)
    expect(p).toContain('写周报')
    expect(p).toContain('工作')
    expect(p).toContain('25:00')
    expect(p).toContain('24:30')
    expect(p).toContain('[00:00-01:00] VS Code — "x"')
  })

  it('shows a placeholder when there is no category or no spans', () => {
    const p = buildUserPrompt({ ...input, categoryName: null, spans: [] })
    expect(p).toContain('未分类')
    expect(p).toContain('(no activity recorded)')
  })
})
