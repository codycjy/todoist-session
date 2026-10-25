# M1 手动验证记录

- 日期：2026-10-25
- 方式：用户在本机用真实 Todoist 账号运行后端（`npm start`）和 Mac 客户端（`swift run SessionApp`），按 M1 计划 Task B6 的清单走查。
- 结果：基础功能（Todoist 任务列表、点任务开始、计时、放弃、完成与结束、自定义条目）用户确认均无问题。
- 走查中发现并修复：`swift run` 启动的裸可执行文件不显示界面，已在 `AppDelegate` 中设置 regular 激活策略（`bccc5bc`）。
- 已知范围外：Today 页时间轴为占位（M2 做专注块简化版，M3 叠加评估）；Docker 镜像与 compose 未验证（本机 docker 守护进程未启动）。
