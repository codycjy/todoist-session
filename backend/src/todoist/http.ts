import { TodoistAuthError, type TodoistGateway, type TodoistProject, type TodoistTask } from './gateway.js'

/**
 * 直接用 fetch 调 Todoist API v1。官方 SDK 走 undici，在 Cloudflare Workers 上跑不起来；
 * 我们只用到两个列表接口，自己写更省事，Node 和 Workers 共用。
 */
const API_BASE = 'https://api.todoist.com/api/v1'
const WEB_BASE = 'https://app.todoist.com/app'
const PAGE_LIMIT = 200
const REQUEST_TIMEOUT_MS = 30_000

type Fetch = typeof fetch

interface Page<T> { results: T[]; next_cursor: string | null }

interface RawTask {
  id: string
  content: string
  project_id: string
  priority: number
  due?: { date: string; is_recurring?: boolean } | null
  duration?: { amount: number; unit: 'minute' | 'day' } | null
  description?: string
  labels?: string[]
  parent_id?: string | null
}

interface RawProject { id: string; name: string; color: string }

/** 和 SDK 的 getTaskUrl 一致：标题转成 ASCII slug，拼在 id 前面。 */
function slugify(value: string): string {
  return value.normalize('NFKD').replace(/[̀-ͯ]/g, '')
    .replace(/[^\x20-\x7E]/g, '')
    .toLowerCase().replace(/[^\w\s-]/g, '')
    .replace(/[-\s]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

export function taskUrl(id: string, content: string): string {
  const slug = slugify(content)
  return `${WEB_BASE}/task/${slug ? `${slug}-${id}` : id}`
}

export function toTask(t: RawTask): TodoistTask {
  return {
    id: t.id,
    content: t.content,
    projectId: t.project_id,
    priority: t.priority,
    dueDate: t.due?.date ?? null,
    isRecurring: t.due?.is_recurring ?? false,
    durationMinutes: t.duration?.unit === 'minute' ? t.duration.amount : null,
    description: t.description ?? '',
    labels: t.labels ?? [],
    parentId: t.parent_id ?? null,
    url: taskUrl(t.id, t.content),
  }
}

export function createTodoistGateway(token: string, fetchImpl: Fetch = fetch): TodoistGateway {
  async function get<T>(path: string, params: Record<string, string>): Promise<Page<T>> {
    const url = `${API_BASE}${path}?${new URLSearchParams(params)}`
    const send = () => fetchImpl(url, {
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    })
    // 网络错误重试一次（SDK 原来也这么做）；HTTP 错误不重试
    const res = await send().catch(() => send())
    if (res.status === 401 || res.status === 403) throw new TodoistAuthError()
    if (!res.ok) throw new Error(`Todoist HTTP ${res.status}`)
    return res.json() as Promise<Page<T>>
  }

  async function all<T>(path: string, params: Record<string, string> = {}): Promise<T[]> {
    const out: T[] = []
    let cursor: string | null = null
    do {
      const page: Page<T> = await get<T>(path, { ...params, limit: String(PAGE_LIMIT), ...(cursor ? { cursor } : {}) })
      out.push(...page.results)
      cursor = page.next_cursor
    } while (cursor)
    return out
  }

  return {
    async tasks(query) {
      return (await all<RawTask>('/tasks/filter', { query })).map(toTask)
    },
    async projects(): Promise<TodoistProject[]> {
      return (await all<RawProject>('/projects')).map((p) => ({ id: p.id, name: p.name, color: p.color }))
    },
  }
}
