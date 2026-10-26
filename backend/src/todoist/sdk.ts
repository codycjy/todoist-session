import { TodoistApi, TodoistRequestError } from '@doist/todoist-sdk'
import { TodoistAuthError, type TodoistGateway, type TodoistProject, type TodoistTask } from './gateway.js'

function mapError(e: unknown): never {
  if (e instanceof TodoistRequestError && (e.httpStatusCode === 401 || e.httpStatusCode === 403)) {
    throw new TodoistAuthError()
  }
  throw e
}

export function createTodoistGateway(token: string): TodoistGateway {
  const api = new TodoistApi(token)
  return {
    async tasks(query) {
      try {
        const out: TodoistTask[] = []
        let cursor: string | null = null
        do {
          const page = await api.getTasksByFilter({ query, cursor, limit: 200 })
          for (const t of page.results) {
            out.push({
              id: t.id,
              content: t.content,
              projectId: t.projectId,
              priority: t.priority,
              dueDate: t.due?.date ?? null,
              isRecurring: t.due?.isRecurring ?? false,
              durationMinutes: t.duration?.unit === 'minute' ? t.duration.amount : null,
              description: t.description ?? '',
              labels: t.labels ?? [],
              parentId: t.parentId ?? null,
              url: t.url,
            })
          }
          cursor = page.nextCursor
        } while (cursor)
        return out
      } catch (e) {
        return mapError(e)
      }
    },
    async projects() {
      try {
        const out: TodoistProject[] = []
        let cursor: string | null = null
        do {
          const page = await api.getProjects({ cursor, limit: 200 })
          for (const p of page.results) out.push({ id: p.id, name: p.name, color: p.color })
          cursor = page.nextCursor
        } while (cursor)
        return out
      } catch (e) {
        return mapError(e)
      }
    },
  }
}
