import { describe, expect, it } from 'vitest'
import { TodoistAuthError } from './gateway.js'
import { createTodoistGateway, taskUrl } from './http.js'

type Call = { url: string; auth: string | null }

/** 假 fetch：按调用顺序返回预设响应，不走网络。 */
function fakeFetch(responses: Array<{ status?: number; body?: unknown } | Error>) {
  const calls: Call[] = []
  const impl = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), auth: new Headers(init?.headers).get('Authorization') })
    const next = responses.shift()
    if (!next) throw new Error('unexpected call')
    if (next instanceof Error) throw next
    return new Response(JSON.stringify(next.body ?? {}), { status: next.status ?? 200 })
  }) as typeof fetch
  return { impl, calls }
}

const raw = {
  id: '123', content: 'Write the report', project_id: 'p1', priority: 4,
  due: { date: '2026-10-29T08:15:00', is_recurring: true }, duration: { amount: 45, unit: 'minute' },
  description: 'd', labels: ['可闲置'], parent_id: null,
}

describe('createTodoistGateway', () => {
  it('maps tasks and follows the cursor across pages', async () => {
    const { impl, calls } = fakeFetch([
      { body: { results: [raw], next_cursor: 'c2' } },
      { body: { results: [{ id: '9', content: '中文', project_id: 'p2', priority: 1 }], next_cursor: null } },
    ])
    const tasks = await createTodoistGateway('fake-token', impl).tasks('today | overdue')
    expect(tasks).toEqual([
      {
        id: '123', content: 'Write the report', projectId: 'p1', priority: 4, dueDate: '2026-10-29T08:15:00',
        isRecurring: true, durationMinutes: 45, description: 'd', labels: ['可闲置'], parentId: null,
        url: 'https://app.todoist.com/app/task/write-the-report-123',
      },
      {
        id: '9', content: '中文', projectId: 'p2', priority: 1, dueDate: null, isRecurring: false,
        durationMinutes: null, description: '', labels: [], parentId: null, url: 'https://app.todoist.com/app/task/9',
      },
    ])
    expect(calls[0]!.url).toBe('https://api.todoist.com/api/v1/tasks/filter?query=today+%7C+overdue&limit=200')
    expect(calls[1]!.url).toContain('cursor=c2')
    expect(calls[0]!.auth).toBe('Bearer fake-token')
  })

  it('ignores day-based durations', async () => {
    const { impl } = fakeFetch([{ body: { results: [{ ...raw, duration: { amount: 2, unit: 'day' } }], next_cursor: null } }])
    expect((await createTodoistGateway('t', impl).tasks('q'))[0]!.durationMinutes).toBeNull()
  })

  it('throws TodoistAuthError on 401 and 403', async () => {
    for (const status of [401, 403]) {
      const { impl } = fakeFetch([{ status }])
      await expect(createTodoistGateway('t', impl).tasks('q')).rejects.toBeInstanceOf(TodoistAuthError)
    }
  })

  it('throws a plain error on other HTTP failures, without retrying', async () => {
    const { impl, calls } = fakeFetch([{ status: 500 }])
    await expect(createTodoistGateway('t', impl).projects()).rejects.toThrow('Todoist HTTP 500')
    expect(calls).toHaveLength(1)
  })

  it('retries a network error once', async () => {
    const { impl, calls } = fakeFetch([new TypeError('fetch failed'), { body: { results: [{ id: 'p', name: 'n', color: 'red' }], next_cursor: null } }])
    expect(await createTodoistGateway('t', impl).projects()).toEqual([{ id: 'p', name: 'n', color: 'red' }])
    expect(calls).toHaveLength(2)
  })
})

it('builds task urls like the official SDK', () => {
  expect(taskUrl('42', 'Café — plan Q4!')).toBe('https://app.todoist.com/app/task/cafe-plan-q4-42')
})
