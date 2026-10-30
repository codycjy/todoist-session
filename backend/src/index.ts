import { serve } from '@hono/node-server'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { createApp } from './app.js'
import { assertSecret } from './config.js'
import { createDb } from './db/client.js'
import { createOpenRouterEvaluator } from './eval/openrouter.js'
import { createEvalWorker } from './eval/worker.js'
import { createTodoistGateway } from './todoist/http.js'

const secret = assertSecret(process.env.APP_SECRET)

const dbPath = process.env.DB_PATH ?? './data/session.db'
mkdirSync(dirname(dbPath), { recursive: true })

const evalModel = process.env.EVAL_MODEL || 'deepseek/deepseek-v4.1-flash-1017'
const evalPromptVersion = process.env.EVAL_PROMPT_VERSION || 'v1'
const EVAL_INTERVAL_MS = 10_000

const db = createDb(dbPath)
const app = createApp({ db, makeGateway: createTodoistGateway, secret, evalModel, evalPromptVersion })
const port = Number(process.env.PORT ?? 8787)
const server = serve({ fetch: app.fetch, port }, () => console.log(`session-backend listening on :${port}`))

// 评估 worker：没有 OPENAI_API_KEY（OpenRouter key）时不启动，评估保持 pending
let evalTimer: NodeJS.Timeout | undefined
const evalKey = process.env.OPENAI_API_KEY
if (evalKey) {
  const worker = createEvalWorker({
    db, now: Date.now, evaluator: createOpenRouterEvaluator({ apiKey: evalKey, model: evalModel, baseUrl: process.env.OPENAI_API_BASE || process.env.OPENAI_BASE_URL || undefined }),
  })
  let running = false
  evalTimer = setInterval(() => {
    if (running) return
    running = true
    worker.runOnce()
      .catch(() => console.error('eval worker run failed'))
      .finally(() => { running = false })
  }, EVAL_INTERVAL_MS)
} else {
  console.log('OPENAI_API_KEY is not set: session evaluation is disabled (evaluations stay pending)')
}

function shutdown() {
  if (evalTimer) clearInterval(evalTimer)
  server.close()
  process.exit(0)
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
