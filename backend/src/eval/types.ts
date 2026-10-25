import type { Distraction } from '../db/schema.js'

/** 错误类别：只有这些字符串会写入 evaluations.last_error */
export type EvalErrorCategory = 'API_ERROR' | 'BAD_OUTPUT' | 'TIMEOUT'

/** 评估失败；message 即类别，不携带响应体或用户数据 */
export class EvalError extends Error {
  constructor(readonly category: EvalErrorCategory) {
    super(category)
    this.name = 'EvalError'
  }
}

export interface EvalSpan {
  kind: 'active' | 'idle'
  appBundleId: string | null
  appName: string | null
  windowTitle: string | null
  urlHost: string | null
  /** 毫秒时间戳 */
  startedAt: number
  endedAt: number
  wasBlocked: boolean
}

export interface EvalInput {
  title: string
  categoryName: string | null
  plannedSeconds: number
  actualSeconds: number
  /** 毫秒时间戳 */
  startedAt: number
  endedAt: number
  spans: EvalSpan[]
}

/** distractions 的 start/end 为绝对毫秒时间戳 */
export interface EvalResult {
  focusScore: number
  summary: string
  distractions: Distraction[]
}

export interface Evaluator {
  evaluate(input: EvalInput): Promise<EvalResult>
}
