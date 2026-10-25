# Session (macOS)

## 运行与测试

```sh
swift test
swift run SessionApp      # 开发形态：无 bundle，不支持系统通知
```

## 打包 .app

```sh
scripts/build-app.sh                          # 产物：build/Session.app（ad-hoc 签名）
SIGN_IDENTITY="Session Dev" scripts/build-app.sh   # 使用自签证书
```

脚本会执行 `swift build -c release`、组装 bundle、签名，并以 `plutil -lint` 与 `codesign --verify` 收尾。`build/` 已被忽略。

**签名与权限**：ad-hoc 签名（默认）的代码身份随二进制内容变化，因此每次重新编译后，macOS 可能重新询问「辅助功能」/「自动化」权限，甚至需要在系统设置里先移除旧条目再重新授权。想要稳定，请在「钥匙串访问 → 证书助理 → 创建证书」中创建一个类型为「代码签名」的自签证书，并通过 `SIGN_IDENTITY` 指定其名称。

## 配置

在 App 的「设置」页配置后端地址与 API Token（Token 存入 Keychain）。开发时也可用环境变量覆盖（优先级高于设置页）：

| 变量 | 说明 |
|---|---|
| `SESSION_API_URL` / `SESSION_API_TOKEN` | 后端地址 / Token |
| `SESSION_FOCUS_SECONDS` / `SESSION_IDLE_SECONDS` | 专注时长 / 闲置阈值（秒，开发覆盖） |
| `SESSION_BLOCK_APPS` / `SESSION_BLOCK_DOMAINS` | 逗号分隔的黑名单覆盖 |
| `SESSION_DEBUG=1` | 打开调试日志 |

后端需要运行并可访问；统计页与 LLM 评估依赖后端（评估还需要后端配置 `ANTHROPIC_API_KEY`，见 backend 的 `.env.example`）。

## 需要的系统权限

辅助功能（读取前台窗口）、自动化（控制浏览器，首次使用时系统弹窗）、通知（专注结束提醒，仅 .app 形态）。首次启动会弹出权限引导，之后可在「设置」页查看。
