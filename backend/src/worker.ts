import { drizzle } from 'drizzle-orm/d1'
import { createApp } from './app.js'
import { assertSecret } from './config.js'
import type { Db } from './db/client.js'
import * as schema from './db/schema.js'
import { createOpenRouterEvaluator } from './eval/openrouter.js'
import { createEvalWorker, type EvalWorker } from './eval/worker.js'
import { createTodoistGateway } from './todoist/http.js'

/**
 * Cloudflare Workers 入口（Node 入口见 index.ts）。数据库是 D1；评估没有常驻轮询，改为：
 * - 上传 session 后用 waitUntil 在响应之后顺手跑一轮；
 * - Cron Trigger 每分钟兜底一次（失败重试、waitUntil 没跑完的）。
 */
export interface Env {
  DB: Parameters<typeof drizzle>[0]
  APP_SECRET: string
  OPENAI_API_KEY?: string
  OPENAI_API_BASE?: string
  EVAL_MODEL?: string
  EVAL_PROMPT_VERSION?: string
}

interface Ctx { waitUntil(promise: Promise<unknown>): void }

const DEFAULT_MODEL = 'deepseek/deepseek-v4.1-flash-1017'
/** 响应之后 waitUntil 最多约 30 秒；一次评估是一个 LLM 请求，跑一轮（最多 5 个）就交给 cron。 */
const ROUNDS_AFTER_SYNC = 1
const ROUNDS_PER_CRON = 10

function setup(env: Env) {
  const db = drizzle(env.DB, { schema }) as unknown as Db
  const evalModel = env.EVAL_MODEL || DEFAULT_MODEL
  const app = createApp({
    db, makeGateway: createTodoistGateway, secret: assertSecret(env.APP_SECRET),
    evalModel, evalPromptVersion: env.EVAL_PROMPT_VERSION || 'v1',
  })
  const worker = env.OPENAI_API_KEY
    ? createEvalWorker({
      db, now: Date.now,
      evaluator: createOpenRouterEvaluator({ apiKey: env.OPENAI_API_KEY, model: evalModel, baseUrl: env.OPENAI_API_BASE || undefined }),
    })
    : null
  return { app, worker }
}

async function drain(worker: EvalWorker, rounds: number) {
  try {
    for (let i = 0; i < rounds; i++) {
      if (await worker.runOnce() === 0) return
    }
  } catch {
    console.error('eval worker run failed')
  }
}

export default {
  async fetch(request: Request, env: Env, ctx: Ctx) {
    const { app, worker } = setup(env)
    const res = await app.fetch(request)
    if (worker && res.ok && request.method === 'POST' && new URL(request.url).pathname === '/sync/sessions') {
      ctx.waitUntil(drain(worker, ROUNDS_AFTER_SYNC))
    }
    return res
  },

  async scheduled(_controller: unknown, env: Env, ctx: Ctx) {
    const { worker } = setup(env)
    if (worker) ctx.waitUntil(drain(worker, ROUNDS_PER_CRON))
  },
}
