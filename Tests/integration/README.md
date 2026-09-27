# 真实应用集成测试

仅在 macOS 上显式运行；使用仓库已有 `.venv/bin/python`，无需安装依赖。先按构建说明生成 `TZBoxDiagnostics` 与同目录 `libTZBoxCore.dylib`。

```sh
.venv/bin/python Tests/integration/native_real_apps.py --driver build/native/debug/TZBoxDiagnostics
# 也可只测试其中一个应用：
.venv/bin/python Tests/integration/native_real_apps.py --driver build/native/debug/TZBoxDiagnostics --app cherry
```

测试 `/Applications/Google Chrome.app` 和 `/Applications/Cherry Studio.app`。如果任一应用有测试前已运行的实例，driver 拒绝接管或关闭；需用户自行正常退出后再测。对于明确识别出的个人 Chrome 进程，可由开发者显式传 `--exclude-existing-chrome-pid <PID>`：仅在诊断 adapter 中将这个 PID 排除出测试发现范围，新建隔离 Chrome 仍走同一 production 引擎；测试记录原 PID 前后持续运行，绝不关闭它。此参数不是产品功能，默认无排除。

每次创建带 `.codex-tmp` 的 `tmp/<时间>-native-real-apps/`，先复制固定的诊断二进制与库，再由 production `NativeLauncher` 完成纽约→加尔各答→恢复系统时区→正常退出。使用同一份本次新建资料，检查 Chrome 的 Cookie/localStorage、Cherry 的合成助手配置在重启后保持。Chrome 检查页面、新标签页、弹窗、跨域 iframe 与三类 Worker；所有场景对比真实时间戳、IANA 规则、历史夏令时转换。

Cherry 的时间来自真实安装版本的正式 AiService 请求管线，调用其自己的 IPC API 并捕获发至 loopback fixture 的 HTTP 请求；不以模型回复作证。使用合成消息和明确的假测试 key，不触碰个人资料、真实密钥、账号或远程模型。不会接受首次使用 GUI 协议，也不修改 Date/Intl 或调用 CDP 时区覆盖。

`summary.json` 是完整结果；`manifest.json` 记录任务目录与测试资源，`*-control/driver-history.json` 记录引擎动作和实际 PID，`fixture-requests.jsonl` 保存合成实际请求。失败会保留部分证据并尝试仅正常关闭自己启动的应用。证据目录保留用于复核，不纳入 Git。
