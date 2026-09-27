# 集成验证说明

产品使用统一 NSWorkspace + TZ 生命周期。Chrome 和 Cherry Studio 都通过同一个 NativeLauncher 启动、正常退出和重启；产品不使用 CDP 覆写网页，也不创建专用 Chrome profile。测试为了不接触个人资料，可使用明确授权的隔离参数，它们不是产品默认行为。

兼容性结论见 [验证记录](VALIDATION.md)。测试须限定应用路径、版本、可关闭进程和测试资料；不得关闭原有个人 Chrome 或其他非测试实例。

## 自有启动与生命周期探针

`./scripts/test.sh --native-probe` 创建本次专用 App bundle，使用真实 NSWorkspace 验证：

- 纽约、加尔各答的父子进程 TZ、POSIX/Foundation 时间转换与真实时间戳。
- 正常退出旧进程后以新时区启动，重建控制器后恢复活跃会话。
- 恢复系统环境时不残留 TZ，状态变为运行中但未受管。
- 正常退出后不残留受管状态，宿主时区不变。

它不验证第三方应用的个人资料、页面保存提示或所有时间 API。

## 真实应用复验

1. 明确应用路径、版本和现有个人进程；建立带 `.codex-tmp` 的本次测试目录。
2. 确认该应用支持隔离测试资料。使用合成资料和消息，不读取个人配置、登录资料或历史对话。
3. 通过统一 NativeLauncher 依次测试 `America/New_York → Asia/Kolkata → 恢复系统环境`。每次核对旧进程正常退出、新进程身份、启动环境和实际应用行为。
4. 核对测试资料在正常重启后仍保留；这不等于已经验证个人登录状态或所有应用数据。
5. 退出时仅关闭本次拥有的实例和 fixture。保留必要证据，按仓库规则清理本次目录。

开发诊断程序不是产品 CLI。用 `./scripts/compile.sh debug` 获取确切二进制目录；本机 Command Line Tools 路径为 `build/native/debug`。旧 `TZBoxDiagnostics chrome ...` 命令已移除。

开发 `session APP CONTROL_ROOT` 驱动从测试目录读取 `launch-options.json`，接受标准输入 JSON 的 apply、restore、quit、status、exit 操作。测试参数与进程排除列表必须事先按授权范围确定；不要以任意个人 App 直接运行诊断。生产启动默认不设置这些测试参数。

## Chrome 检查范围

使用真实 Chrome 154，检查网页 Date/Intl、跨域 iframe、Dedicated Worker、Shared Worker、Service Worker 的结果，并与宿主前后采样的真实时间戳比较。若诊断使用调试协议，它仅用于读取测试证据，不代表产品仍依赖 CDP。

不能用无窗口后台启动模式代替正常 UI 生命周期验收。正常退出、资料保留、时区切换和恢复系统环境都应由统一启动器实际完成。扩展、浏览器原生界面、睡眠唤醒和真实页面阻止关闭需要独立验证。

## Cherry Studio 检查范围

使用真实 Cherry Studio 2.0.8 和本机 HTTP fixture：

- fixture 提供模型列表、聊天与流式响应；使用虚构密钥与合成提示。
- 从实际请求核对 `{{date}}`、`{{time}}`、`{{datetime}}` 及存在的时区字段，不能用模型回答作为证据。
- 本轮普通聊天的 `{{datetime}}` 随纽约、加尔各答、系统上海正确变化；`{{timezone}}` 未解析，请求没有独立 timezone 字段。
- Agent、MCP、远程工具、跨午夜及夏令时边界分别列为未验证，不从普通聊天外推。

fixture 请求日志不保存鉴权头，但保存合成消息；不得接入个人聊天。任何未覆盖行为都应保持未验证。
