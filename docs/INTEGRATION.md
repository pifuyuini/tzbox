# 集成验证说明

本轮用户指定只运行代码和自有测试，以下真实应用流程尚未执行。它们是后续验收入口，不能当作兼容性结论。

## 自有启动探针

`./scripts/test.sh --native-probe` 创建临时 App bundle，用真实 NSWorkspace 启动，检查 TZ 传递、子进程继承、POSIX 时间转换、真实 Unix 时间戳位于宿主采样区间、宿主时区未改变。Foundation 使用的默认时区单独记录，不能据此推断所有第三方 Cocoa 应用。

## 真实 Chrome（需要单独授权）

1. 明确选定安装的 Chrome 路径与版本。
2. 在仓库 `tmp/` 下创建本次专用目录及 `.codex-tmp`，该目录只存放本次测试资料。
3. 用 `.venv/bin/python Tests/fixtures/server.py --test-root <绝对路径>` 启动本机 fixture。它打印随机端口，同时写出 `fixture-server.json`。
4. 运行开发诊断程序（不是公开产品 CLI）：

```text
build/swift/debug/TZBoxDiagnostics chrome <Chrome.app绝对路径> <测试目录>/chrome-profile http://127.0.0.1:<端口> America/New_York <测试目录>/chrome-report.json
```

用 `./scripts/compile.sh debug` 构建并获取确切二进制目录；Command Line Tools fallback 位于 `build/native/debug`。

5. 分别验证基础页、新标签、弹窗、跨域 iframe、Dedicated Worker、Service Worker；Shared Worker、扩展与浏览器原生界面仍需额外验证。
6. 独立验证：重新启动资料保留、断连恢复、睡眠唤醒、正常退出被网页取消、错误应用路径和 Chrome 升级后的行为。这些不能由一次探针结果替代。
7. 结束时正常关闭测试 Chrome 和本次 fixture 服务。包含浏览器资料的临时目录应检查后按仓库临时文件规则清理；通用自测清理脚本不会擅自删除这些资料。

## Cherry Studio 作为普通应用样本（需要单独授权）

先核实所安装版本能否可靠使用隔离资料；不能确认时，不修改或复用已有个人配置。本轮没有解包或修改 Cherry Studio。

- 启动上述本机 fixture，提供 `/v1/models`、`/v1/chat/completions` 和流式响应。
- 在明确授权的测试配置中使用本机地址和虚构密钥；只使用合成消息。
- 在测试系统提示中使用该版本支持的日期时间变量，例如 `{{date}}`、`{{time}}`、`{{datetime}}`。如果该功能原本不附带时区字段，记录“无此字段”，不能假定其存在。
- 从 TZBox 用与宿主不同的时区启动应用；比较 `fixture-requests.jsonl` 中实际收到的提示内容、存在的时区字段及采样时间。
- 核对跨午夜、夏令时前后、重启后的同类请求。Agent、MCP 和远程工具单独列范围，不能把普通聊天结果外推。
- fixture 的回答固定且不代表验证成功。请求日志不保存鉴权头，但会保存合成消息，因此不要接入真实个人聊天。

任何失败项目记录为未兼容；不能仅凭环境变量、程序成功启动或模型口头回答就标记接管成功。
