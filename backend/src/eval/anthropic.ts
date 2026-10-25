import Anthropic from '@anthropic-ai/sdk'
import { buildUserPrompt, SYSTEM_PROMPT } from './prompt.js'
import { parseEvalOutput } from './parse.js'
import { EvalError, type EvalInput, type EvalResult, type Evaluator } from './types.js'

export const EVAL_TOOL_NAME = 'record_evaluation'
const MAX_TOKENS = 1024
const REQUEST_TIMEOUT_MS = 60_000

const EVAL_TOOL = {
  name: EVAL_TOOL_NAME,
  description: 'Record the focus evaluation for this session.',
  input_schema: {
    type: 'object' as const,
    properties: {
      focus_score: { type: 'integer', minimum: 0, maximum: 100, description: '0 = entirely off-task, 100 = fully focused on the stated task' },
      summary: { type: 'string', maxLength: 200, description: 'One or two sentences on how the session went' },
      distractions: {
        type: 'array',
        description: 'Off-task stretches; times are seconds relative to session start',
        items: {
          type: 'object',
          properties: {
            start_sec: { type: 'number' },
            end_sec: { type: 'number' },
            reason: { type: 'string' },
          },
          required: ['start_sec', 'end_sec', 'reason'],
        },
      },
    },
    required: ['focus_score', 'summary', 'distractions'],
  },
}

/** 发给 Messages API 的请求体（只含本模块用到的字段） */
export interface CreateMessageParams {
  model: string
  max_tokens: number
  system: string
  messages: { role: 'user'; content: string }[]
  tools: (typeof EVAL_TOOL)[]
  tool_choice: { type: 'tool'; name: string }
}
export interface CreateMessageResult {
  content: { type: string; name?: string; input?: unknown }[]
}
/** 注入点：测试传入 fake，生产默认走 SDK */
export type CreateMessage = (params: CreateMessageParams) => Promise<CreateMessageResult>

export interface AnthropicEvaluatorOptions {
  model: string
  apiKey?: string
  create?: CreateMessage
}

/** 客户端在第一次评估时才构造，因此没有 key 的场景（测试）不会出错 */
function lazySdkCreate(apiKey: string | undefined): CreateMessage {
  let client: Anthropic | undefined
  return (params) => {
    client ??= new Anthropic({ apiKey, timeout: REQUEST_TIMEOUT_MS, maxRetries: 1 })
    return client.messages.create(params) as Promise<CreateMessageResult>
  }
}

export function createAnthropicEvaluator(opts: AnthropicEvaluatorOptions): Evaluator {
  const create = opts.create ?? lazySdkCreate(opts.apiKey)
  return {
    async evaluate(input: EvalInput): Promise<EvalResult> {
      let res: CreateMessageResult
      try {
        res = await create({
          model: opts.model,
          max_tokens: MAX_TOKENS,
          system: SYSTEM_PROMPT,
          messages: [{ role: 'user', content: buildUserPrompt(input) }],
          tools: [EVAL_TOOL],
          tool_choice: { type: 'tool', name: EVAL_TOOL_NAME },
        })
      } catch (err) {
        // 只透出类别：SDK 错误可能带有响应体
        const name = err instanceof Error ? err.name : ''
        throw new EvalError(name === 'APIConnectionTimeoutError' ? 'TIMEOUT' : 'API_ERROR')
      }
      const block = res.content.find((b) => b.type === 'tool_use' && b.name === EVAL_TOOL_NAME)
      if (!block) throw new EvalError('BAD_OUTPUT')
      return parseEvalOutput(block.input, { startedAt: input.startedAt, endedAt: input.endedAt })
    },
  }
}
