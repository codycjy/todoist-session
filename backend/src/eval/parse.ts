import type { Distraction } from '../db/schema.js'
import { EvalError, type EvalResult } from './types.js'

const MAX_TEXT = 200

export interface ParseContext {
  /** 毫秒时间戳 */
  startedAt: number
  endedAt: number
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null
const clip = (v: string) => v.trim().slice(0, MAX_TEXT)

/**
 * 解析 tool use 的 input：分数四舍五入并 clamp 到 0..100，
 * 丢弃越界 / 畸形的 distraction，并把相对秒换算成绝对毫秒。
 * 无法解析时抛 BAD_OUTPUT。
 */
export function parseEvalOutput(raw: unknown, ctx: ParseContext): EvalResult {
  if (!isObject(raw)) throw new EvalError('BAD_OUTPUT')
  const { focus_score: score, summary, distractions } = raw
  if (typeof score !== 'number' || !Number.isFinite(score)) throw new EvalError('BAD_OUTPUT')
  if (typeof summary !== 'string' || summary.trim() === '') throw new EvalError('BAD_OUTPUT')
  if (distractions !== undefined && !Array.isArray(distractions)) throw new EvalError('BAD_OUTPUT')

  const durationSec = (ctx.endedAt - ctx.startedAt) / 1000
  const kept: Distraction[] = []
  for (const d of distractions ?? []) {
    if (!isObject(d)) continue
    const { start_sec: s, end_sec: e, reason } = d
    if (typeof s !== 'number' || typeof e !== 'number' || !Number.isFinite(s) || !Number.isFinite(e)) continue
    if (typeof reason !== 'string' || reason.trim() === '') continue
    if (s < 0 || e > durationSec || e <= s) continue
    kept.push({ start: Math.round(ctx.startedAt + s * 1000), end: Math.round(ctx.startedAt + e * 1000), reason: clip(reason) })
  }
  return { focusScore: Math.min(100, Math.max(0, Math.round(score))), summary: clip(summary), distractions: kept }
}
