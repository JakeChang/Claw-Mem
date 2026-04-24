# Claw-Mem

Claude Code 工作記憶助手 — 自動監控 JSONL 工作紀錄，透過 AI 生成結構化摘要，讓你每天延續開發上下文。

## 功能

- **即時監控** — 背景偵測 `~/.claude/projects` 的 JSONL 紀錄，自動解析入庫
- **AI 摘要** — 透過 Google Gemini 串流生成每日工作摘要（完成事項、修改檔案、問題解法）
- **專案總摘要** — 從所有歷史摘要歸納專案全貌：技術棧、架構、里程碑
- **一鍵複製給 Claude** — 格式化摘要為 prompt，貼到新對話即可延續上下文
- **日期篩選** — 快捷 7/30/90 天或自訂範圍，聚焦特定時期
- **跨裝置同步** — 透過 Dropbox / iCloud 資料夾同步摘要與備註
- **Menu Bar** — 右上角常駐顯示今日專案數與紀錄數
- **自動更新** — Sparkle 框架，推 tag 即自動發版

## 安裝

從 [Releases](https://github.com/JakeChang/Claw-Mem/releases) 下載最新 DMG。

支援 macOS 15+ / Apple Silicon & Intel。

> 首次開啟需執行 `xattr -cr /Applications/Claw-Mem.app`（未經 Apple 公證）

## 設定

1. 取得 [Google AI Studio](https://aistudio.google.com/) 的 API Key
2. 開啟 Claw-Mem → 設定 → 貼上 API Key → 儲存
3. 選擇模型（預設 Gemini 3.1 Flash Lite）

## 技術

- SwiftUI + SwiftData
- Google Gemini API（SSE 串流）
- Sparkle 自動更新
- GitHub Actions CI/CD

## License

MIT
