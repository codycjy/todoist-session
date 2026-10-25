import { expect, it, vi } from 'vitest'
import { createAnthropicEvaluator, EVAL_TOOL_NAME, type CreateMessage } from './anthropic.js'
import { EvalError, type EvalInput } from './types.js'

const input: EvalInput = {
  title: 't', categoryName: null, plannedSeconds: 60, actualSeconds: 60,
  startedAt: 0, endedAt: 60_000, spans: [],
}
const toolUse = (inp: unknown) => ({ content: [{ type: 'text', text: 'hi' }, { type: 'tool_use', name: EVAL_TOOL_NAME, input: inp }] })

it('forces the evaluation tool and parses the tool_use input', async () => {
  const create = vi.fn<CreateMessage>().mockResolvedValue(toolUse({
    focus_score: 90, summary: 'good', distractions: [{ start_sec: 1, end_sec: 2, reason: 'x' }],
  }))
  const ev = createAnthropicEvaluator({ create, model: 'fake-model' })
  const r = await ev.evaluate(input)
  expect(r).toEqual({ focusScore: 90, summary: 'good', distractions: [{ start: 1000, end: 2000, reason: 'x' }] })
  const params = create.mock.calls[0]![0]
  expect(params.model).toBe('fake-model')
  expect(params.tool_choice).toEqual({ type: 'tool', name: EVAL_TOOL_NAME })
  expect(params.tools).toHaveLength(1)
  expect(params.tools[0]!.name).toBe(EVAL_TOOL_NAME)
  expect(params.messages[0]!.role).toBe('user')
  expect(params.max_tokens).toBeGreaterThan(0)
})

it('throws BAD_OUTPUT when there is no tool_use block or the output is invalid', async () => {
  const noTool = createAnthropicEvaluator({ create: async () => ({ content: [{ type: 'text', text: 'x' }] }), model: 'm' })
  await expect(noTool.evaluate(input)).rejects.toMatchObject({ category: 'BAD_OUTPUT' })
  const bad = createAnthropicEvaluator({ create: async () => toolUse({ nope: 1 }), model: 'm' })
  await expect(bad.evaluate(input)).rejects.toMatchObject({ category: 'BAD_OUTPUT' })
})

it('maps SDK failures to category-only EvalErrors without leaking the message', async () => {
  const boom = createAnthropicEvaluator({ create: async () => { throw new Error('secret body sk-fake') }, model: 'm' })
  const err = await boom.evaluate(input).catch((e) => e)
  expect(err).toBeInstanceOf(EvalError)
  expect(err).toMatchObject({ category: 'API_ERROR', message: 'API_ERROR' })

  const timeout = Object.assign(new Error('x'), { name: 'APIConnectionTimeoutError' })
  const t = createAnthropicEvaluator({ create: async () => { throw timeout }, model: 'm' })
  await expect(t.evaluate(input)).rejects.toMatchObject({ category: 'TIMEOUT' })
})

it('does not construct a client (or need a key) until create is used', () => {
  expect(() => createAnthropicEvaluator({ apiKey: undefined, model: 'm' })).not.toThrow()
})
