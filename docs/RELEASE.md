# 构建与发布说明

## 版本

| 项目 | 值 |
|---|---|
| 应用版本 | 0.3.0 |
| Build | 3 |
| Bundle ID | `dev.tzbox.app` |
| 最低系统 | macOS 14 |
| 验证架构 | Apple Silicon / arm64 |
| 签名 | 本地 ad-hoc；未公证 |

0.3.0 更新应用图标、原生界面视觉和发布文档。统一 NSWorkspace + TZ 的应用生命周期保持不变；兼容性与真实应用测试范围见 [VALIDATION.md](VALIDATION.md)。

## 可重复打包

在已配置 Swift 与 macOS SDK 的 Mac 上执行：

```sh
./scripts/build.sh release
```

脚本依次生成图标、编译程序、组装 `build/TZBox.app`，检查 Info.plist 并执行本地签名验证。完整 SwiftPM 环境与 Command Line Tools 的 `swiftc` 路径使用相同源码和资源。程序构建不依赖本工作区的 Rust/Python 环境配置。

图标源为 `Assets/AppIcon/AppIcon.png`，应为带透明通道、至少 1024×1024 的正方形 PNG。可单独生成 ICNS：

```sh
./scripts/build-icon.sh
```

输出为 `build/AppIcon.icns`。标准 iconset 在本次带标记的 `tmp/` 目录生成，完成后仅清理该目录中已知的本次产物。源 PNG 保持不变；应用包的 Resources 包含 PNG 与 ICNS，Info.plist 的 `CFBundleIconFile` 指向后者。

## 发布前检查

- 执行相应自有测试和窗口验收；改动代理机制时按 [集成验证说明](INTEGRATION.md) 补真实应用验证。
- 确认应用版本、图标资源、Info.plist 和本地签名检查通过。
- 只提交本次明确归属的源码、图标源、脚本、文档和无个人信息的截图；检查暂存内容及最终提交路径。
- 本地 `.venv/`、`build/`、`tmp/`、应用运行资料与当前工作区原有 Rust/Python 环境配置不作为源码发布内容。
- 在确认 GitHub 仓库身份及既有引用后推送，保留原有提交历史；不使用强制推送。

源码发布与面向公众分发的安装包是两项独立工作。当前构建尚未配置 Developer ID、公证、自动更新或 Intel 版本；本次脚本不会自动创建 GitHub Release、上传应用包或选择许可证。

## 本轮包装验收

2026-09-28 在 macOS 14.4 / Apple Silicon 上通过 release 构建、Info.plist 检查和本地签名验证。ICNS 反向解包后，全部 10 个标准图像的尺寸与透明通道通过核对；包内 PNG 与源图逐字节一致。图标中间目录验证后已清理。

界面使用自有窗口和合成配置检查浅色/深色列表、空状态、时区选择器、筛选及高对比度；公开预览位于 [images/](images/)。这轮没有改动代理核心，第三方应用兼容性结论沿用已记录的真实应用验收。

本轮回归执行 `scripts/test.sh`：41/41 Swift 自有断言与 4/4 HTTP fixture 通过。8 次自有窗口验收运行正常退出，独立 UI 静态复核未发现确定性操作回归；完整 GUI 点击流程与第三方应用重启未在这次视觉改造中重复执行。
