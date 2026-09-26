# 验证记录

验证日期：2026-09-27（Asia/Shanghai）。所有构建和执行均在远端仓库完成，未读取或启动已安装的 Chrome、Cherry Studio。

## 环境与构建

- macOS 14.4，arm64；Apple Swift 5.9；仓库 Python 3.12.11。
- 此机仅配置 Command Line Tools。SwiftPM 的 `xcrun --show-sdk-platform-path` 查询失败，未安装 Xcode、依赖或修改开发工具设置。
- 通过现有 `swiftc` 编译相同源码，debug 与 release 均成功。保留 Package.swift 供具备完整 SwiftPM 环境的机器使用；本机未执行 Apple XCTest runner。
- 发布应用：`build/TZBox.app`。Info.plist 检查及本地 ad-hoc 签名验证通过；不包含 App Sandbox entitlement，未进行 Developer ID 公证。

## 已执行的验证

| 项目 | 结果 | 范围 |
|---|---|---|
| Swift 自有测试运行器 | 34/34 通过 | 执行原测试方法的真实断言，覆盖配置、时区、验证报告、会话持久化、CDP 协议、时区探针及控制进程状态 |
| Python HTTP fixture | 4/4 通过 | 请求捕获、鉴权头不入日志、流式响应、页面/Worker资源、非法请求 |
| NSWorkspace 自有 App 探针 | 8/8 检查通过 | 父子进程 TZ、POSIX/Foundation 默认时区、真实时间戳、宿主时区 |
| 发布包窗口冒烟 | 通过 | 独立临时配置启动，渲染自身窗口后正常退出，无第三方应用启动 |
| 窗口视觉检查 | 通过 | 默认窗口布局、中文文字、时区/时钟、Chrome入口、普通应用空状态与兼容说明无截断 |
| Python 与 shell 检查 | 通过 | 任务脚本、HTTP fixture 的 Ruff 检查及 shell 语法检查 |
| 独立静态审核 | 已修复并复核 | 页面覆写失败仍执行、检查成功覆盖并发失败、普通应用启动/保存期间退出丢会话 |

自有 App 探针的具体结果：宿主为 `Asia/Shanghai`，目标与子进程为 `America/New_York`；POSIX 偏移均为 -14400 秒，Foundation 均返回纽约时区；父子进程 Unix 时间戳在宿主前后采样区间内。仅对这个自有样本成立，不能外推所有 Cocoa/Electron 应用。

测试还发现并修复了 macOS 14 的时区别名问题：系统列表可能只有 `Asia/Calcutta`，但 Foundation 可以解析 `Asia/Kolkata`；现支持有效 IANA 别名和手工输入，并继续拒绝 `UTC+9` 等非 IANA 固定偏移写法。

## 尚未验证

依据用户本轮约束，以下项目保留为待实机验证：

- 真实 Chrome 的网页、跨域 iframe、Dedicated/Service Worker 覆盖，以及当前安装版本的协议行为。
- Shared Worker、扩展、浏览器原生界面；这些也不在一次基础页面检查的承诺范围内。
- 真实登录资料跨重启保持、系统睡眠唤醒、真实页面阻止关闭、真实浏览器断连恢复。
- Cherry Studio 或其他第三方应用实际发给模型的日期、时间、时区字段；聊天、Agent、MCP、远程工具需分别检查。
- 完整 Xcode 环境下的 SwiftPM/XCTest 路径、Intel 和其他 macOS 版本。

相关自有诊断入口和人工流程已提供于 [集成验证说明](INTEGRATION.md)。模拟协议或自有 App 测试通过不等于上述项目通过。
