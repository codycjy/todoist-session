export interface TodoistTask {
  id: string
  content: string
  projectId: string
  priority: number
  dueDate: string | null
  isRecurring: boolean
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
