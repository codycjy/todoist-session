# 部署后端到 Cloudflare Workers + D1

Node / Docker 部署照旧可用（`npm start`），Workers 是另一个入口（`src/worker.ts`），两者共用同一套路由和迁移。

| | Node | Workers |
|---|---|---|
| 入口 | `src/index.ts` | `src/worker.ts` |
| 数据库 | 本地 SQLite 文件 | D1 |
| 评估 | 每 10 秒轮询 | 上传后立即跑一轮 + 每分钟 cron 兜底 |
| 密钥 | 环境变量 | `wrangler secret` |

以下命令都在 `backend/` 下执行。

## 1. 登录并建库

```sh
npx wrangler login
npx wrangler d1 create now
```

把输出里的 `database_id` 填进 `wrangler.jsonc`，替换 `REPLACE_WITH_D1_DATABASE_ID`。

```sh
npm run cf:migrate          # 在 D1 上建表（drizzle/ 下的迁移）
```

## 2. 设置密钥

```sh
npx wrangler secret put APP_SECRET        # 至少 32 个字符；要迁移旧数据就用和本地一样的值
npx wrangler secret put OPENAI_API_KEY    # OpenRouter key；不设则不评估
```

可选：`EVAL_MODEL`、`EVAL_PROMPT_VERSION`、`OPENAI_API_BASE`，同样用 `wrangler secret put`，或写到 `wrangler.jsonc` 的 `vars` 里。

## 3. 数据：迁移旧数据，或新建用户

**迁移本地已有数据**（APP_SECRET 必须和本地一致，否则 Todoist token 解不开）：

```sh
npm run d1:export -- --db ./data/session.db --out ./d1-import.sql
npx wrangler d1 execute now --remote --file ./d1-import.sql
rm ./d1-import.sql
```

原来的 API token 继续有效，Mac 端只需要换地址。

**或者新建用户**：

```sh
APP_SECRET=... TODOIST_TOKEN=... npm run d1:seed -- --name me --out ./d1-seed.sql
npx wrangler d1 execute now --remote --file ./d1-seed.sql
rm ./d1-seed.sql
```

会打印新的 API token，只显示这一次。

两个 SQL 文件里有加密后的 Todoist token 和 API token 哈希，导入后删掉，不要提交。

## 4. 部署

```sh
npm run cf:deploy
```

输出的 `https://now-backend.<子域>.workers.dev` 填进 Mac 端「设置 › 后端」。

## 本地调试

```sh
printf 'APP_SECRET=%s\n' "$(openssl rand -hex 24)" > .dev.vars   # .dev.vars 已在 .gitignore 里
npx wrangler d1 migrations apply now --local
npm run cf:dev -- --test-scheduled     # curl 'localhost:8787/__scheduled?cron=*+*+*+*+*' 手动触发评估
```

## 额度（个人使用基本在免费额度内）

- Workers 免费版：每天 10 万请求，每次请求 10ms CPU。上传很长的专注时如果出现 CPU 超限（Error 1102），改用 Workers Paid（$5/月）。
- D1 免费版：每天 10 万行写入、500 万行读取。活动记录一条算一行，每个 span 都是一行。
