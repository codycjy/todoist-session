import { integer, sqliteTable, text, uniqueIndex } from 'drizzle-orm/sqlite-core'

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

export type User = typeof users.$inferSelect
export type Category = typeof categories.$inferSelect
export type Entry = typeof entries.$inferSelect
