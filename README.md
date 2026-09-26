# TZBox

macOS 应用级时区启动器。保持系统时区和真实时刻不变，为通过 TZBox 启动的应用设置一个目标时区。

## 首版范围

- 原生 SwiftUI 主窗口与菜单栏，支持 macOS 14+、Apple Silicon。
- Chrome 使用专用持久资料和网页时区覆盖；首次登录一次后保留资料。
- 任意 `.app` 可尝试通过 `TZ` 环境启动；启动成功不代表应用所有时间行为兼容。
- 单一目标时区，修改前退出受控实例；不同时管理多个浏览器时区。
- 不改系统时区、不改真实时钟、不注入第三方代码、不改写网络请求。

**实机兼容性以 [验证记录](docs/VALIDATION.md) 为准。** 模拟协议通过不能证明已安装 Chrome 或 Cherry Studio 的实际效果。

## 构建

使用已安装的 Swift 5.9+ 和 macOS SDK，无第三方运行时依赖：

```sh
./scripts/build.sh
```

输出为仓库的 `build/TZBox.app`。构建脚本进行本地 ad-hoc 签名并检查应用包。它没有 Developer ID 公证，不是面向公众分发的安装包。

标准环境使用 Swift Package Manager。仅装 Command Line Tools 且 SwiftPM 报 PlatformPath 错误时，脚本自动使用现有 swiftc 直接编译相同源码；不修改系统工具配置。

已有 Rust、Python 环境配置不参与应用构建；测试辅助使用本仓库 `.venv/bin/python`，不安装 Python 依赖。

## 使用

1. 打开 `build/TZBox.app`，搜索并选定目标时区，例如 `Asia/Tokyo`。
2. 在 Chrome 专用入口选择 Chrome 的 `.app`，或添加其他应用。
3. 从 TZBox 启动。普通应用若已经运行，请先正常退出。
4. Chrome 可运行“检查时区”，查看检查项目与范围。普通应用默认显示效果未验证。
5. 关闭主窗口后，TZBox 留在菜单栏。退出 TZBox 时，如果专用 Chrome 仍运行，将提示正常关闭该实例。

从桌面、Dock 或其他启动器直接打开应用，不属于 TZBox 启动流程。普通应用可在 TZBox 退出后继续运行；TZBox 重开时尝试恢复自己记录的仍存活会话。

应用设置和浏览器资料位于 `~/Library/Application Support/TZBox`。`TZBOX_DATA_DIR` 可为开发测试指定单独的数据目录。程序不扫描系统应用目录；应用由用户在文件选择器中指定。

## 如何理解效果

- **启动状态**：进程是否启动、仍运行或控制中断。
- **验证结果**：哪个版本、哪个目标时区、哪些具体执行环境和 API 被实际检查。
- 浏览器诊断中的“未验证”项目不是通过。一次页面检查不能证明 Worker、扩展、网站服务器、浏览器自身界面都已覆盖。
- 账号设置、写死的时间文本、服务器响应、远程工具及模型自行生成的时间可能不遵循本机时区。
- 如果关心发给模型的时间，检查实际请求内容，不能只看模型回答。TZBox 不会自动为原本没有时区字段的请求添加字段。

## 自有测试

```sh
./scripts/test.sh
./scripts/test.sh --native-probe
```

XCTest 可用时执行 SwiftPM 测试；上述 Command Line Tools 环境执行相同测试方法的自有断言运行器，结果不会标作 Apple XCTest。

第二条还会构建并启动仓库内自有的 `TZBoxProbe.app`，检查 AppKit 环境传递、子进程继承、POSIX/Foundation 时区及真实时间戳。不会启动已安装的第三方应用。

测试目录在仓库 `tmp/` 下创建并标记；清理仅限本次目录。存在未知内容时保留并报告。Swift 构建产物统一存放在已有忽略规则覆盖的 `build/`。

后续真实 Chrome / Cherry Studio 验证流程见 [集成验证说明](docs/INTEGRATION.md)；这些步骤会启动第三方应用，须在明确授权后执行。
