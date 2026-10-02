# Changelog / 版本记录

## 1.1.0 — 2026-10-02

- Public source release with English / Chinese documentation and MIT license.
- Offline, explicitly labeled demo scenes for privacy-safe screenshots.
- Treat every HTTP 5xx response as a service issue, including 501 / 505.
- Unknown custom remote host IDs no longer set or clear the core-client failure state.
- Expired or unreadable disconnect evidence is gray and inconclusive, preserving the need for explicit recovery.
- Cleaner history-range layout; monitoring timer remains active while menus are open.
- Portable Swift 6 build scripts, architecture-specific archives, macOS CI, and publication privacy checks.

公开源码、中英文文档与 MIT 许可证；新增离线演示截图；修复 5xx、自定义远端和过期断线证据误判；整理界面与构建路径，增加双架构 CI 和隐私检查。

## 1.0.0 — Local prototype / 本地原型

Menu bar status, proxy / TUN checks, client log summaries, local history, and account quota.
