# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claw-Mem is a macOS native menu bar app that monitors Claude Code's JSONL conversation logs (`~/.claude/projects/`), parses them into structured data, and generates AI-powered daily/project summaries via the Google Gemini API. Built with SwiftUI + SwiftData, targeting macOS 15+.

## Build & Run

Open `Claw-Mem.xcodeproj` in Xcode 16+, select the **Claw-Mem** scheme, and press Cmd+R. There are no SPM or CocoaPods dependencies to resolve — Sparkle is the only external framework (bundled).

CLI build (used by CI):
```
xcodebuild -project Claw-Mem.xcodeproj -scheme Claw-Mem -configuration Release -derivedDataPath /tmp/build
```

## Architecture

### Concurrency Model

The app uses a strict actor-isolation pattern to keep the UI responsive:

- **`IngestCoordinator`** (`@Observable @MainActor`) — the central hub. Owns the file watcher, drives ingest, and exposes all read/write APIs that views consume. Injected into SwiftUI via `.environment()`.
- **`IngestActor`** — a `ModelActor` that performs all SwiftData writes (ingest, save summary, delete) off the main thread.
- **`ReadActor`** — a separate `ModelActor` for read-only queries so UI fetches never block behind an ongoing ingest pass.
- Views never touch `ModelContext` directly; they go through `IngestCoordinator` which delegates to the appropriate actor.

### Data Pipeline

1. **`FileWatcher`** monitors `~/.claude/projects/` via FSEvents and triggers `IngestCoordinator.runIngest()`.
2. **`RescanCoordinator`** discovers JSONL files on disk.
3. **`IngestActor.ingestFile()`** reads new bytes (offset-based incremental), parses via `Parser`, and writes `SourceFile`, `RawEvent`, `Message`, `ToolEvent` to SwiftData.
4. **`Summarizer`** builds a prompt from parsed events and calls the Gemini streaming SSE API to produce structured JSON summaries (`SummaryContent` / `ProjectSummaryContent`).
5. **`SyncService`** exports/imports summaries, notes, and message logs to a shared folder (Dropbox/iCloud) for cross-device sync. Uses last-write-wins for summaries and per-device append-only logs for messages.

### SwiftData Schema

Versioned migration through `ClawMemSchemaV1` → `V2` → `V3` (lightweight migrations). Store lives at `~/.clawmem/memory.store`. Models: `SourceFile`, `RawEvent`, `Message`, `ToolEvent`, `Summary`, `IngestError`, `UserNote`, `DeletedRecord`.

### Key Patterns

- `dataVersion` vs `localDataVersion` on `IngestCoordinator`: `dataVersion` bumps on any change (including sync imports) to refresh UI; `localDataVersion` bumps only on local changes to trigger sync export without feedback loops.
- Ingest sorts files newest-first and does an early UI refresh after the first 100 files so today's data appears quickly.
- Gemini API calls use SSE streaming with 150ms UI throttling and exponential retry on 429/5xx.
- The app uses `@Observable` (Observation framework), not `ObservableObject`/`@Published`.

## Release Process

Tagging `v*.*.*` triggers `.github/workflows/release.yml` which builds a universal binary (arm64 + x86_64), creates a DMG, signs it with Sparkle EdDSA, publishes a GitHub Release, and deploys `appcast.xml` + `index.html` to GitHub Pages.

## Language

UI strings and AI prompts are in Traditional Chinese (繁體中文). The Gemini prompt language is configurable via `AppSettings`.
