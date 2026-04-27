import SwiftUI
import Sparkle

struct SettingsView: View {
    let updater: SPUUpdater

    @Environment(AppSettings.self) private var settings
    @Environment(SyncService.self) private var syncService

    @State private var apiKeyInput = ""
    @State private var isTestingConnection = false
    @State private var connectionResult: (Bool, String)?
    @State private var showAPIKey = false
    @State private var showSyncSheet = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                LabeledContent("API Key") {
                    HStack(spacing: 8) {
                        Group {
                            if showAPIKey {
                                TextField("輸入 API Key", text: $apiKeyInput)
                            } else {
                                SecureField("輸入 API Key", text: $apiKeyInput)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button(showAPIKey ? "隱藏" : "顯示") {
                            showAPIKey.toggle()
                        }
                        .controlSize(.small)

                        Button("儲存") {
                            settings.geminiAPIKey = apiKeyInput
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }

                HStack {
                    Button("測試連線") {
                        testConnection()
                    }
                    .disabled(apiKeyInput.isEmpty || isTestingConnection)

                    if isTestingConnection {
                        ProgressView().controlSize(.small)
                    } else if let (success, message) = connectionResult {
                        Label(message, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(success ? .green : .red)
                    }
                }

                Picker("模型", selection: $settings.geminiModel) {
                    Text("Gemini 3.1 Flash Lite").tag("gemini-3.1-flash-lite-preview")
                    Text("Gemini 2.5 Flash").tag("gemini-2.5-flash")
                    Text("Gemini 2.0 Flash").tag("gemini-2.0-flash")
                    Text("Gemini 2.0 Flash Lite").tag("gemini-2.0-flash-lite")
                    Text("Gemini 1.5 Flash").tag("gemini-1.5-flash")
                    Text("Gemini 1.5 Pro").tag("gemini-1.5-pro")
                    Text("Gemma 4 31B").tag("gemma-4-31b-it")
                }
            } header: {
                Label("Gemini API", systemImage: "brain")
            }

            Section {
                Picker("摘要語言", selection: $settings.summaryLanguage) {
                    ForEach(SummaryLanguage.allCases) { lang in
                        Text(lang.rawValue).tag(lang)
                    }
                }
            } header: {
                Label("摘要", systemImage: "sparkles")
            }

            Section {
                LabeledContent("監控路徑") {
                    HStack {
                        Text(settings.watchPath)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button("變更…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                settings.watchPath = url.path(percentEncoded: false)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Label("Claude Code", systemImage: "terminal")
            }

            Section {
                LabeledContent("同步資料夾") {
                    HStack {
                        if settings.syncFolderPath.isEmpty {
                            Text("（尚未設定）")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(settings.syncFolderPath)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Button("選擇…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.message = "選擇 Dropbox / iCloud 內的同步資料夾"
                            if panel.runModal() == .OK, let url = panel.url {
                                settings.syncFolderPath = url.path(percentEncoded: false)
                            }
                        }
                        .controlSize(.small)

                        if !settings.syncFolderPath.isEmpty {
                            Button("清除") {
                                settings.syncFolderPath = ""
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if syncService.isEnabled {
                    HStack {
                        Text("狀態")
                        Spacer()
                        if syncService.isSyncing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("同步中…").font(.callout).foregroundStyle(.secondary)
                            }
                        } else if let err = syncService.lastError {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        } else if let t = syncService.lastSyncTime {
                            Text("上次同步：\(t.formatted(date: .omitted, time: .shortened))")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("尚未同步").font(.callout).foregroundStyle(.tertiary)
                        }
                        Button("立刻同步") {
                            showSyncSheet = true
                            Task { await syncService.syncNow() }
                        }
                        .controlSize(.small)
                        .disabled(syncService.isSyncing)
                    }
                }

                LabeledContent("裝置 ID") {
                    Text(settings.deviceID.prefix(8) + "…")
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            } header: {
                Label("跨裝置同步", systemImage: "arrow.triangle.2.circlepath")
            } footer: {
                Text("只同步 AI 摘要、手動備註、對話/工具事件；原始 JSONL 與 ingest 進度不同步。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                LabeledContent("版本") {
                    HStack {
                        Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                        Button("檢查更新") {
                            updater.checkForUpdates()
                        }
                        .controlSize(.small)
                    }
                }
                LabeledContent("資料庫") {
                    HStack {
                        Text("~/.clawmem/memory.store")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                        Button("在 Finder 中顯示") {
                            NSWorkspace.shared.open(URL.homeDirectory.appending(path: ".clawmem"))
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Label("關於", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 460)
        .onAppear {
            apiKeyInput = settings.geminiAPIKey
        }
        .sheet(isPresented: $showSyncSheet) {
            SyncProgressSheet()
        }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionResult = nil
        let key = apiKeyInput
        let model = settings.geminiModel
        Task {
            let result = await Summarizer.testConnection(apiKey: key, model: model)
            connectionResult = result
            isTestingConnection = false
        }
    }
}
