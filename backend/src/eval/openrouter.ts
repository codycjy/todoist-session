import { buildUserPrompt, SYSTEM_PROMPT } from './prompt.js'
import { parseEvalOutput } from './parse.js'
import { EvalError, type EvalInput, type EvalResult, type Evaluator } from './types.js'

export const EVAL_TOOL_NAME = 'record_evaluation'
export const DEFAULT_BASE_URL = 'https://openrouter.ai/api/v1'
const MAX_TOKENS = 1024
const REQUEST_TIMEOUT_MS = 60_000

const EVAL_TOOL = {
  type: 'function' as const,
  function: {
    name: EVAL_TOOL_NAME,
    description: 'Record the focus evaluation for this session.',
    parameters: {
      type: 'object',
      properties: {
        focus_score: { type: 'integer', minimum: 0, maximum: 100, description: '0 = entirely off-task, 100 = fully focused on the stated task' },
        summary: { type: 'string', maxLength: 200, description: '一句简短中文（不超过 40 字）：是否专注在任务上，被什么打断' },
        distractions: {
          type: 'array',
          description: 'Off-task stretches; times are seconds relative to session start',
          items: {
            type: 'object',
            properties: {
              start_sec: { type: 'number' },
              end_sec: { type: 'number' },
              reason: { type: 'string', description: '简短中文，如「刷 B 站」' },
            },
            required: ['start_sec', 'end_sec', 'reason'],
          },
        },
      },
      required: ['focus_score', 'summary', 'distractions'],
    },
  },
}

/** OpenAI 兼容 chat completions 请求体（只含本模块用到的字段） */
export interface ChatRequest {
  model: string
  max_tokens: number
  messages: { role: 'system' | 'user'; content: string }[]
  tools: (typeof EVAL_TOOL)[]
  tool_choice: { type: 'function'; function: { name: string } }
}
export interface ChatCompletion {
  choices: { message?: { content?: string | null; tool_calls?: { function?: { name?: string; arguments?: string } }[] } }[]
}
/** 注入点：测试传入 fake，生产默认走 fetch */
export type PostChat = (body: ChatRequest) => Promise<ChatCompletion>

export interface OpenRouterEvaluatorOptions {
  model: string
  apiKey?: string
  /** 默认 OpenRouter；任何 OpenAI 兼容端点都可以 */
  baseUrl?: string
  post?: PostChat
  fetchFn?: (url: string, init: RequestInit) => Promise<Response>
}

function fetchPost(opts: OpenRouterEvaluatorOptions): PostChat {
  const url = `${(opts.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, '')}/chat/completions`
  const fetchFn = opts.fetchFn ?? fetch
  return async (body) => {
    const res = await fetchFn(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${opts.apiKey ?? ''}` },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    })
    // 不读取错误响应体：它可能回显请求内容
    if (!res.ok) throw new Error('HTTP')
    return (await res.json()) as ChatCompletion
  }
}

/** 优先取强制调用的 function 参数；模型不支持 tool calling 时退回到 content 里的 JSON（允许 ``` 围栏） */
function extractOutput(res: ChatCompletion): unknown {
  const message = res.choices[0]?.message
  const call = message?.tool_calls?.find((c) => c.function?.name === EVAL_TOOL_NAME)
  const text = call?.function?.arguments ?? message?.content
  if (typeof text !== 'string') throw new EvalError('BAD_OUTPUT')
  const body = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '')
  try {
    return JSON.parse(body)
  } catch {
    throw new EvalError('BAD_OUTPUT')
  }
}

export function createOpenRouterEvaluator(opts: OpenRouterEvaluatorOptions): Evaluator {
  const post = opts.post ?? fetchPost(opts)
  return {
    async evaluate(input: EvalInput): Promise<EvalResult> {
      let res: ChatCompletion
      try {
        res = await post({
          model: opts.model,
          max_tokens: MAX_TOKENS,
          messages: [{ role: 'system', content: SYSTEM_PROMPT }, { role: 'user', content: buildUserPrompt(input) }],
          tools: [EVAL_TOOL],
          tool_choice: { type: 'function', function: { name: EVAL_TOOL_NAME } },
        })
      } catch (err) {
        // 只透出类别：底层错误可能带有响应体
        const name = err instanceof Error ? err.name : ''
        throw new EvalError(name === 'TimeoutError' || name === 'AbortError' ? 'TIMEOUT' : 'API_ERROR')
      }
      return parseEvalOutput(extractOutput(res), { startedAt: input.startedAt, endedAt: input.endedAt })
    },
  }
}
