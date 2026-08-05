<p align="center">
  <img src="Sources/Holeberry/Resources/AppIcon.icon/Assets/logo_transparent.png" alt="Holeberry" width="128" />
</p>

<h1 align="center">Holeberry</h1>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="https://holeberryapp.com">Website</a>
</p>

<p align="center">
  <b>Pi-hole 就在你的菜单栏里。</b><br />
  一款原生、现代的 macOS 菜单栏应用，用于监控和控制你的 Pi-hole 实例——无需打开浏览器标签页。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white&style=flat-square" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?logo=swift&logoColor=white&style=flat-square" alt="Swift 6.0" />
  <img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="MIT License" />
  <img src="https://img.shields.io/github/v/release/pedrovieira/Holeberry?style=flat-square" alt="Latest release" />
  <img src="https://img.shields.io/badge/Pi--hole-v5%20%26%20v6-96C93C.svg?style=flat-square" alt="Pi-hole v5 & v6" />
</p>

<!-- TODO: 替换为菜单栏图标 + 展开弹出菜单的实景截图。这是 README 中最重要的视觉元素——展示带有状态圆点、统计行和"禁用屏蔽"子菜单的状态菜单。 -->

## Holeberry 是什么？

Holeberry 是一款轻量级 macOS 菜单栏应用，让你的 Pi-hole 触手可及。查看屏蔽状态与查询统计、按秒或自定义时长禁用屏蔽、解除当前浏览器标签页中域名的屏蔽，以及将最近被屏蔽的域名加入白名单或解除屏蔽——全程无需打开 Pi-hole 网页管理界面。

它支持 Pi-hole **v5 与 v6**、多实例以及全局键盘快捷键。

## 安装

### GitHub Releases（推荐）

1. 从 [Releases](https://github.com/pedrovieira/Holeberry/releases) 页面下载最新的 `Holeberry-<版本号>.dmg`。
2. 打开 DMG，将 **Holeberry** 拖入你的「应用程序」文件夹。
3. 启动 Holeberry——它会常驻在菜单栏中。

**关于 macOS Gatekeeper 的说明：** Holeberry 使用免费的 Apple ID 构建，未通过付费的 Apple Developer 账号进行公证（notarization）。因此 macOS 可能会将其标记为「来自身份不明的开发者」，或在首次启动时将其隔离。如果看到该提示，请移除隔离标记后重新启动：

```bash
xattr -dr com.apple.quarantine /Applications/Holeberry.app
```

Holeberry 会通过 [Sparkle](https://sparkle-project.org/) 自动检查更新。

### Homebrew

Homebrew cask 正在计划中。在此之前，请使用上面的 release DMG。

## 系统要求

- **macOS 14（Sonoma）或更高版本** —— Holeberry 基于 Swift 6 构建，充分利用了现代 macOS API。
- 一台可从 Mac 访问的 Pi-hole 实例（v5 或 v6），位于本地网络或其他位置均可。

## 功能特性

### 状态一目了然

菜单栏图标会实时反映你的 Pi-hole 健康状况，多服务器场景下还支持按实例显示状态：

- 🟢 **屏蔽已启用** —— 一切按预期屏蔽中
- ⚪ **屏蔽已禁用** —— 屏蔽已关闭（或处于定时关闭状态）
- 🟠 **部分屏蔽中** —— 各实例之间的屏蔽状态不一致
- 🔴 **实例无法访问** —— 有一个或多个实例无法连接

菜单还会显示所有实例的**总查询量与屏蔽域名数**。

### 定时关闭屏蔽

将屏蔽关闭 **10 秒、30 秒、5 分钟、自定义时长**，或**无限期**关闭——计时结束会自动重新启用屏蔽。再也不怕忘记把广告屏蔽开回来。

### 解除当前标签页的屏蔽

Holeberry 能检测 **Safari、Chrome/Chromium、Firefox 和 Zen Browser** 中的当前标签页，并让你解除该域名的屏蔽——可选 10 秒、30 秒、5 分钟或自定义时长——或直接加入白名单。最适合那些死活加载不出来的链接或视频。

### 最近被屏蔽的域名

浏览 Pi-hole 最近屏蔽的域名（来自你的 Mac 或所有客户端），并直接在菜单中解除屏蔽或加入白名单。

### 多实例支持

在一个菜单中管理多个 Pi-hole 实例：每个服务器独立的状态圆点、聚合的查询/屏蔽统计，以及当实例离线或各实例屏蔽状态不一致时的清晰警告。

### Pi-hole v5 与 v6

Holeberry 会自动检测 Pi-hole 版本，并以正确的方式与每个实例通信——v5 Web API 或带会话认证的 v6 REST API。凭据安全地存储在 macOS **钥匙串（Keychain）** 中，绝不以明文保存。

### 全局键盘快捷键

为禁用屏蔽（10 秒 / 30 秒 / 5 分钟 / 自定义 / 无限期）、重新启用屏蔽和解除当前标签页屏蔽分配全局快捷键——即使 Holeberry 在后台也能生效。

### 自动发现

Holeberry 会自动发现本地网络中的 Pi-hole 实例，设置过程常常就是「点击即连接」。

## 为什么做 Holeberry？

Pi-hole 的网页界面很棒——前提是你已经在浏览器里。但每一次快捷操作都要跑一趟 `pi.hole/admin`：切换屏蔽、等页面加载、再点一次，然后还要记得重新启用。而我试过的 macOS 客户端都缺少我真正需要的工作流：解除当前正在看的标签页里那个域名的屏蔽、按域名设置计时器，以及在多个实例之间给出真实可靠的一眼状态。

所以我做了 Holeberry：一款原生、仅菜单栏的应用，把 Pi-hole 控制当作 macOS 的一等公民——快速、键盘驱动，并且如实反映你的网络状况。

名字从哪来？Pi-hole 跑在 Raspberry Pi 上，而——*berry*（浆果）听起来刚刚好。

它在工程上也是一份心血之作：Swift 6 严格并发、抽取到本地 Swift 包（`HoleberryCore`）的协议驱动核心，以及经过大量测试的服务层——这正是我作为开源贡献者愿意去读的那种代码库。

## 未来计划

Holeberry 目前是一款面向 Pi-hole 的应用，但菜单栏的工作流不必止步于此。如果有足够的社区需求，未来的版本可能会加入：

- **对其他 DNS 提供商的支持** —— AdGuard Home 和 Technitium 是自然而然的选择，适合不使用 Pi-hole 的用户。
- **混合部署** —— 同时连接 Pi-hole 与 AdGuard Home（或任意组合），按实例显示状态、汇总统计，并在不同提供商之间提供一致的一键操作。

这些都不是承诺——这是一份愿望清单，优先级由社区需求决定。如果你想看到其中任何一项，请开一个 [issue](https://github.com/pedrovieira/Holeberry/issues) 告诉我们；支持的声音越多，优先级就越高。

## 快速上手

1. **添加你的 Pi-hole** —— 通过自动发现，或手动添加（URL、API Token / 密码，以及可选的名称和图标）。
2. **按提示授予权限**：
   - **本地网络（Local Network）** —— 用于连接你的 Pi-hole 实例。
   - **自动化（Automation）** —— 仅当你启用浏览器标签页解除屏蔽时使用；Holeberry 需要读取浏览器当前标签页的 URL 来解除屏蔽。
3. **设置快捷键** —— 在「设置 → 快捷键」中配置，或保持默认。

就这样。其余的一切都在菜单栏里。

## 截图

<!-- TODO: 在此添加截图——菜单栏弹出菜单（状态 + 控制）、浏览器标签页解除屏蔽区域、设置窗口（服务器 / 快捷键标签页）。 -->

## 常见问题

### Holeberry 支持 Pi-hole v5 和 v6 吗？
支持。版本会自动检测，每个实例都会配置正确的 API。v6 会话的凭据会自动刷新，并存储在 macOS 钥匙串中。

### 我的 Pi-hole 凭据存储在哪里？
在 macOS **钥匙串（Keychain）** 中——与邮件、Safari 和系统使用的安全存储相同。Holeberry 绝不会将密码写入磁盘。

### Holeberry 需要哪些权限？为什么？
- **本地网络**：连接 Pi-hole 实例所必需。
- **自动化（浏览器访问）**：可选，仅在启用浏览器标签页解除屏蔽时使用。可随时在「设置 → 高级」中关闭。

### Holeberry 会取代 Pi-hole 网页管理界面吗？
不会——也不打算取代。Holeberry 是你日常操作的遥控器：查看状态、开关屏蔽、定向解除屏蔽。深度配置（广告列表、DHCP、gravity 更新等）仍然使用网页管理界面。

### Holeberry 免费吗？
免费——它采用 [MIT 许可证](LICENSE) 开源，可以自由使用、派生和学习。

### 为什么我的浏览器标签页没有出现？
需要在「设置 → 高级」中启用浏览器标签页解除屏蔽，并且 Holeberry 需要获得浏览器的自动化权限（首次使用时在系统设置中授予）。

## 从源码构建

```bash
git clone https://github.com/pedrovieira/Holeberry.git
cd Holeberry
open Holeberry.xcodeproj
```

选择 **Holeberry** scheme，然后点击运行（⌘R）。

给贡献者的注意事项：

- 项目使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) —— 如果修改了 `project.yml`，请用 `xcodegen generate` 重新生成。
- 应用 target 带有预构建脚本，以严格模式运行 [SwiftLint](https://github.com/realm/SwiftLint) 和 `swift-format`；请先安装它们，否则构建会发出警告。
- 核心逻辑位于 `HoleberryCore` Swift 包中，自带测试套件 —— `cd Packages/HoleberryCore && swift test`。

## 参与贡献

欢迎通过 [issues](https://github.com/pedrovieira/Holeberry/issues) 提交 bug 报告和功能请求。PR 请以 `main` 分支为目标，并确保现有测试套件通过。欢迎 AI 辅助的贡献——如果你的 PR 由 AI 辅助完成，请在 PR 描述中注明这一点，并说明所使用的工具。如果你计划较大的改动，请先开一个 issue 沟通——这对我们双方都省时间。

## AI 辅助开发

这个项目主要由 AI 编写。我想坦诚地说明这一点——但它在每一步都受到了人类的重度指导：我。AI 生成并优化了大部分代码，但架构、功能、范围和设计决策都由我主导并审查。请把 AI 当作加速器，而不是作者：让这个代码库成为现在这样的选择——协议驱动的设计、抽取到 `HoleberryCore` 的可测试核心、Swift 6 严格并发——都是人的选择。AI 只是让这一切更快实现。

## 致谢

- [Sparkle](https://github.com/sparkle-project/Sparkle) —— 更新框架
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) —— 全局快捷键录制
- [Defaults](https://github.com/sindresorhus/Defaults) —— 类型化用户默认设置
- [SymbolPicker](https://github.com/SzpakKamil/SymbolPicker) —— 实例图标选择器
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) —— 项目生成
- [SwiftLint](https://github.com/realm/SwiftLint) 与 `swift-format` —— 让代码保持诚实

## 许可证

[MIT](LICENSE) © 2026 Pedro Vieira

---

*Pi-hole® 是 Pi-hole LLC 的注册商标。Holeberry 是独立项目，与 Pi-hole LLC 没有任何关联。*
