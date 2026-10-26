export interface TodoistTask {
  id: string
  content: string
  projectId: string
  priority: number
  dueDate: string | null
  isRecurring: boolean
  /** 仅当 Todoist 任务设置了以分钟计的时长时才有值 */
  durationMinutes: number | null
  /** 详情面板用：Todoist 描述（可为空串）、标签名、父任务 ID、网页链接 */
  description: string
  labels: string[]
  parentId: string | null
  url: string
}

export interface TodoistProject {
  id: string
  name: string
  color: string
}

export interface TodoistGateway {
  tasks(query: string): Promise<TodoistTask[]>
  projects(): Promise<TodoistProject[]>
}

export class TodoistAuthError extends Error {
  constructor() {
    super('Todoist rejected the token')
  }
}
