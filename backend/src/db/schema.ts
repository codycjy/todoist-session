import { index, integer, sqliteTable, text, uniqueIndex } from 'drizzle-orm/sqlite-core'

export const users = sqliteTable('users', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  apiTokenHash: text('api_token_hash').notNull().unique(),
  todoistTokenEnc: text('todoist_token_enc'),
  settings: text('settings', { mode: 'json' })
    .$type<Record<string, unknown>>()
    .notNull()
    .$defaultFn(() => ({})),
  createdAt: integer('created_at', { mode: 'timestamp' }).notNull(),
})

export const categories = sqliteTable(
  'categories',
  {
    id: text('id').primaryKey(),
    userId: text('user_id').notNull().references(() => users.id),
    todoistProjectId: text('todoist_project_id'),
    name: text('name').notNull(),
    color: text('color').notNull(),
    archived: integer('archived', { mode: 'boolean' }).notNull().default(false),
  },
  (t) => [uniqueIndex('categories_user_project').on(t.userId, t.todoistProjectId)],
)

export const entries = sqliteTable('entries', {
  id: text('id').primaryKey(),
  userId: text('user_id').notNull().references(() => users.id),
  title: text('title').notNull(),
  categoryId: text('category_id').references(() => categories.id),
  lastUsedAt: integer('last_used_at', { mode: 'timestamp' }).notNull(),
})

export const sessions = sqliteTable(
  'sessions',
  {
    id: text('id').primaryKey(),
    userId: text('user_id').notNull().references(() => users.id),
    categoryId: text('category_id').references(() => categories.id),
    source: text('source', { enum: ['todoist', 'custom'] }).notNull(),
    todoistTaskId: text('todoist_task_id'),
    entryId: text('entry_id').references(() => entries.id),
    titleSnapshot: text('title_snapshot').notNull(),
    plannedSeconds: integer('planned_seconds').notNull(),
    actualSeconds: integer('actual_seconds').notNull(),
    startedAt: integer('started_at', { mode: 'timestamp_ms' }).notNull(),
    endedAt: integer('ended_at', { mode: 'timestamp_ms' }).notNull(),
    status: text('status', { enum: ['completed'] }).notNull().default('completed'),
    // 用户标记「可闲置」：任务有一部分离开电脑做，评估时闲置不算分心
    allowIdle: integer('allow_idle', { mode: 'boolean' }).notNull().default(false),
  },
  (t) => [index('sessions_user_started').on(t.userId, t.startedAt)],
)

export const activitySpans = sqliteTable(
  'activity_spans',
  {
    id: text('id').primaryKey(),
    sessionId: text('session_id').notNull().references(() => sessions.id),
    kind: text('kind', { enum: ['active', 'idle'] }).notNull(),
    appBundleId: text('app_bundle_id'),
    appName: text('app_name'),
    windowTitle: text('window_title'),
    urlHost: text('url_host'),
    urlPath: text('url_path'),
    startedAt: integer('started_at', { mode: 'timestamp_ms' }).notNull(),
    endedAt: integer('ended_at', { mode: 'timestamp_ms' }).notNull(),
    wasBlocked: integer('was_blocked', { mode: 'boolean' }).notNull().default(false),
  },
  (t) => [index('spans_session').on(t.sessionId)],
)

export interface Distraction {
  start: number
  end: number
  reason: string
}

export const evaluations = sqliteTable(
  'evaluations',
  {
    sessionId: text('session_id').primaryKey().references(() => sessions.id),
    userId: text('user_id').notNull().references(() => users.id),
    status: text('status', { enum: ['pending', 'done', 'failed'] }).notNull().default('pending'),
    attempts: integer('attempts').notNull().default(0),
    focusScore: integer('focus_score'),
    summary: text('summary'),
    distractions: text('distractions', { mode: 'json' })
      .$type<Distraction[]>()
      .notNull()
      .$defaultFn(() => []),
    model: text('model').notNull(),
    promptVersion: text('prompt_version').notNull(),
    // 只存错误类别（API_ERROR / BAD_OUTPUT / TIMEOUT），不存响应体或 Key
    lastError: text('last_error'),
    createdAt: integer('created_at', { mode: 'timestamp_ms' }).notNull(),
    updatedAt: integer('updated_at', { mode: 'timestamp_ms' }).notNull(),
  },
  (t) => [index('evaluations_status').on(t.status, t.attempts)],
)

export type User = typeof users.$inferSelect
export type Category = typeof categories.$inferSelect
export type Entry = typeof entries.$inferSelect
export type SessionRow = typeof sessions.$inferSelect
export type ActivitySpanRow = typeof activitySpans.$inferSelect
export type EvaluationRow = typeof evaluations.$inferSelect
