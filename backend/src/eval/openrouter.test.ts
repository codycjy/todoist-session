import { expect, it, vi } from 'vitest'
import { createOpenRouterEvaluator, EVAL_TOOL_NAME, type ChatCompletion, type PostChat } from './openrouter.js'
import { EvalError, type EvalInput } from './types.js'

const input: EvalInput = {
  title: 't', categoryName: null, plannedSeconds: 60, actualSeconds: 60,
  startedAt: 0, endedAt: 60_000, spans: [],
}
const good = { focus_score: 90, summary: 'good', distractions: [{ start_sec: 1, end_sec: 2, reason: 'x' }] }
const expected = { focusScore: 90, summary: 'good', distractions: [{ start: 1000, end: 2000, reason: 'x' }] }
const viaTool = (args: unknown): ChatCompletion => ({
  choices: [{ message: { content: null, tool_calls: [{ function: { name: EVAL_TOOL_NAME, arguments: JSON.stringify(args) } }] } }],
})
const viaContent = (content: string): ChatCompletion => ({ choices: [{ message: { content } }] })

it('forces the evaluation function and parses tool_calls arguments', async () => {
  const post = vi.fn<PostChat>().mockResolvedValue(viaTool(good))
  const r = await createOpenRouterEvaluator({ post, model: 'fake/model' }).evaluate(input)
  expect(r).toEqual(expected)
  const body = post.mock.calls[0]![0]
  expect(body.model).toBe('fake/model')
  expect(body.tool_choice).toEqual({ type: 'function', function: { name: EVAL_TOOL_NAME } })
  expect(body.tools).toHaveLength(1)
  expect(body.tools[0]!.function.name).toBe(EVAL_TOOL_NAME)
  expect(body.messages.map((m) => m.role)).toEqual(['system', 'user'])
  expect(body.max_tokens).toBeGreaterThan(0)
})

it('falls back to JSON in message content (also inside a code fence)', async () => {
  const plain = createOpenRouterEvaluator({ post: async () => viaContent(JSON.stringify(good)), model: 'm' })
  expect(await plain.evaluate(input)).toEqual(expected)
  const fenced = createOpenRouterEvaluator({ post: async () => viaContent('```json\n' + JSON.stringify(good) + '\n```'), model: 'm' })
  expect(await fenced.evaluate(input)).toEqual(expected)
})

it('throws BAD_OUTPUT for missing, unparsable or invalid output', async () => {
  for (const res of [{ choices: [] }, viaContent('no json here'), viaContent('{not json'), viaTool({ nope: 1 }),
    { choices: [{ message: { content: null, tool_calls: [{ function: { name: EVAL_TOOL_NAME, arguments: '{broken' } }] } }] }]) {
    const ev = createOpenRouterEvaluator({ post: async () => res, model: 'm' })
    await expect(ev.evaluate(input)).rejects.toMatchObject({ category: 'BAD_OUTPUT' })
  }
})

it('maps transport failures to category-only EvalErrors without leaking the message', async () => {
  const boom = createOpenRouterEvaluator({ post: async () => { throw new Error('secret body sk-fake') }, model: 'm' })
  const err = await boom.evaluate(input).catch((e) => e)
  expect(err).toBeInstanceOf(EvalError)
  expect(err).toMatchObject({ category: 'API_ERROR', message: 'API_ERROR' })
  const timeout = Object.assign(new Error('x'), { name: 'TimeoutError' })
  const t = createOpenRouterEvaluator({ post: async () => { throw timeout }, model: 'm' })
  await expect(t.evaluate(input)).rejects.toMatchObject({ category: 'TIMEOUT' })
})

it('default transport posts to the chat completions endpoint with a bearer key and never needs one at construction', async () => {
  expect(() => createOpenRouterEvaluator({ apiKey: undefined, model: 'm' })).not.toThrow()
  const fetchFn = vi.fn(async (_url: string, _init: RequestInit) => new Response(JSON.stringify(viaTool(good)), { status: 200 }))
  const ev = createOpenRouterEvaluator({ apiKey: 'fake-key', baseUrl: 'https://example.test/api/v1/', model: 'm', fetchFn })
  expect(await ev.evaluate(input)).toEqual(expected)
  const [url, init] = fetchFn.mock.calls[0]!
  expect(url).toBe('https://example.test/api/v1/chat/completions')
  expect((init.headers as Record<string, string>).Authorization).toBe('Bearer fake-key')
})

it('treats a non-2xx response as API_ERROR', async () => {
  const fetchFn = async () => new Response('{"error":"secret"}', { status: 401 })
  const ev = createOpenRouterEvaluator({ apiKey: 'fake-key', model: 'm', fetchFn })
  const err = await ev.evaluate(input).catch((e) => e)
  expect(err).toMatchObject({ category: 'API_ERROR', message: 'API_ERROR' })
})
