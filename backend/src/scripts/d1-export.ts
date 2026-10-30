import Database from 'better-sqlite3'
import { writeFileSync } from 'node:fs'

/**
 * 把 Node 版的本地 SQLite 数据导出成 D1 能执行的 INSERT 语句（不含建表，建表由 D1 迁移完成）。
 * D1 不接受 sqlite3 .dump 里的 BEGIN TRANSACTION / PRAGMA / drizzle 迁移表，所以自己生成。
 *
 *   npm run d1:export -- --db ./data/session.db --out ./d1-import.sql
 *   npx wrangler d1 execute now --remote --file ./d1-import.sql
 *
 * 输出文件里有加密后的 Todoist token 和 API token 的哈希：导入后删掉，不要提交。
 */
const TABLES = ['users', 'categories', 'entries', 'sessions', 'activity_spans', 'evaluations'] // 外键顺序
const ROWS_PER_INSERT = 50

function arg(name: string) {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 ? process.argv[i + 1] : undefined
}

function literal(v: unknown): string {
  if (v === null || v === undefined) return 'NULL'
  if (typeof v === 'number' || typeof v === 'bigint') return String(v)
  if (typeof v === 'boolean') return v ? '1' : '0'
  if (Buffer.isBuffer(v)) return `X'${v.toString('hex')}'`
  return `'${String(v).replace(/'/g, "''")}'`
}

const dbPath = arg('db') ?? process.env.DB_PATH ?? './data/session.db'
const out = arg('out') ?? './d1-import.sql'
const sqlite = new Database(dbPath, { readonly: true, fileMustExist: true })

const lines: string[] = []
for (const table of TABLES) {
  const rows = sqlite.prepare(`SELECT * FROM "${table}"`).all() as Record<string, unknown>[]
  if (rows.length === 0) continue
  const cols = Object.keys(rows[0]!)
  for (let i = 0; i < rows.length; i += ROWS_PER_INSERT) {
    const values = rows.slice(i, i + ROWS_PER_INSERT).map((r) => `(${cols.map((c) => literal(r[c])).join(', ')})`)
    lines.push(`INSERT OR IGNORE INTO "${table}" (${cols.map((c) => `"${c}"`).join(', ')}) VALUES\n${values.join(',\n')};`)
  }
  console.log(`${table}: ${rows.length} rows`)
}
writeFileSync(out, lines.join('\n') + '\n', { mode: 0o600 })
console.log(`written ${out} — import it with wrangler, then delete it`)
