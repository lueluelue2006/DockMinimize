# DockMinimize

DockMinimize is an enhancement tool for macOS that fills a long-standing gap in Dock interaction: the ability to hide or restore windows by clicking their Dock icons.
Website：https://ivean.com/dockminimize/

## Features

### Window Visibility Toggle
Simply click an application icon in the Dock to immediately hide all windows of that app. Click again to unhide and activate the app, while keeping previously minimized windows minimized.

The toggle script logic has been updated to replace the previous "restore all minimized windows" behavior, so window states stay more predictable after a hide/show cycle.

### Hover Preview
When hovering over a Dock icon, DockMinimize displays real-time thumbnails of all open windows for that app. You can click a specific thumbnail in the preview bar to bring a window to the front or minimize it, significantly improving multi-window management efficiency.

### Intelligent Multi-Window Management
DockMinimize features smart logic for applications with multiple windows. It preserves per-window minimized state during hide/show toggles and switches to a high-performance "Hide" mode when needed.

### Application Blacklist
You can add specific applications to a blacklist. DockMinimize will completely bypass blacklisted apps, leaving their original interaction logic untouched.

### Pure & Performant
- Built with native Swift and SwiftUI for a lightweight and efficient experience.
- Supports Universal Binary (compatible with both Apple Silicon and Intel chips).
- UI design follows native macOS aesthetics, blending seamlessly into the system.

## Installation

1. Download the latest DMG installer from the GitHub Releases page.
2. Drag DockMinimize to your Applications folder.
3. Upon first launch, please follow the prompts to grant the following permissions:
    - **Accessibility**: Used to monitor Dock click events and control windows.
    - **Screen Recording**: Used to display window thumbnails in Hover Preview (this app does not store or upload any visual data).

## System Requirements

- macOS 12.0 or higher.
- Supports all major Mac devices.

## License

This project is licensed under the MIT License.

---

# DockMinimize (中文版)

DockMinimize 是一款为 macOS 打造的增强工具，它弥补了 macOS 在 Dock 交互上的一个长期空缺：通过点击 Dock 图标来隐藏或恢复窗口。
官方网站：https://ivean.com/dockminimize/

## 功能特性

### 窗口显隐切换
只需点击 Dock 栏中的应用程序图标，即可立即隐藏该应用的所有窗口。再次点击时，会取消隐藏并激活应用，同时保留原本已最小化窗口的最小化状态。

当前版本已将这部分切换脚本逻辑替换为新的实现：不再使用“恢复全部最小化窗口”的旧逻辑，从而让隐藏/恢复后的窗口状态更可预期。

### 悬停预览 (Hover Preview)
当鼠标悬停在 Dock 图标上时，DockMinimize 会显示该应用所有打开窗口的实时缩略图。您可以直接在预览条中点击特定窗口进行置顶显示或最小化操作，提升多窗口管理的效率。

### 智能多窗口管理
对于拥有多个窗口的应用，DockMinimize 提供了智能化的处理逻辑：在隐藏/恢复切换时保留各窗口自身的最小化状态，并在需要时自动切换为高效的隐藏模式，确保系统运行的稳定性。

### 应用黑名单
您可以根据需要将特定的应用程序加入黑名单。对于黑名单中的应用，DockMinimize 将完全避让，不干预其原有的交互逻辑。

### 纯净与性能
- 采用原生 Swift 和 SwiftUI 开发，轻量且高效。
- 支持 Universal Binary（兼容 Apple Silicon 和 Intel 芯片）。
- 界面设计遵循 macOS 原生质感，完美融入系统美学。

## 安装指南

1. 在 GitHub 的 Releases 页面下载最新的 DMG 安装包。
2. 将 DockMinimize 拖动至应用程序文件夹。
3. 首次启动时，请按照指引授予以下权限：
    - **辅助功能权限**：用于监听 Dock 点击事件并控制窗口。
    - **屏幕录制权限**：用于在悬停预览中显示窗口缩略图（本应用不会存储或上传任何画面数据）。

## 系统要求

- macOS 12.0 或更高版本。
- 支持所有主流 Mac 设备。

## 开源协议

本项目采用 MIT 协议开源。
