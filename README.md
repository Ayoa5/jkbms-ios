# 极空（JK）BMS 监控 App — iOS

> project_24（2026-11-08 新建）。iPhone 主力端的极空 BMS 监控 App。

## 定位
- Android 端直接使用开源项目 `mazemingw/JKBMS-Android`（v1.2.8，已满足）。
- **本仓库只做 iOS**：SwiftUI 界面 + CoreBluetooth 直连 JK BMS（JK02 协议）。

## 技术栈
- SwiftUI（iOS 17+）
- CoreBluetooth（BLE 扫描/连接/notify）
- JK02 协议：Service `0xFFE0` / Char `0xFFE1`，请求 `0x97`+`0x96`，响应 `55 AA EB 90 + type + len + data + crc`（小端字段）
- 构建：GitHub Actions（macos-latest）→ unsigned ipa → Sideloadly/AltStore 侧载

## 目录
- `iosApp/` — Xcode 工程（project.yml 由 xcodegen 生成）
- `iosApp/JkBms/` — SwiftUI 源码 + CoreBluetooth
- `.github/workflows/build_ipa.yml`

## 状态
2026-11-08：初始化，搭建构建链路。
