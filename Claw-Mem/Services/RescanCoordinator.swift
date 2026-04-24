import Foundation
import SwiftData

nonisolated struct DiscoveredFile: Sendable {
    let path: String
    let sessionId: String
    let project: String
    let fileSize: Int64
    let modifiedAt: Date?
}

nonisolated struct RescanCoordinator: Sendable {
    let watchPath: String

    init(watchPath: String = NSHomeDirectory() + "/.claude/projects") {
        self.watchPath = watchPath
    }

    func discoverJSONLFiles() -> [DiscoveredFile] {
        let fm = FileManager.default
        let basePath = watchPath

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: basePath) else {
            return []
        }

        var files: [DiscoveredFile] = []

        for projectDir in projectDirs {
            let projectPath = (basePath as NSString).appendingPathComponent(projectDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // Derive project name: "-Users-jake-Desktop-MyProject" → "MyProject"
            let project = deriveProjectName(from: projectDir)

            // Find JSONL files (direct children and in subagents/)
            if let sessionFiles = try? fm.contentsOfDirectory(atPath: projectPath) {
                for file in sessionFiles {
                    if file.hasSuffix(".jsonl") {
                        let filePath = (projectPath as NSString).appendingPathComponent(file)
                        let sessionId = String(file.dropLast(6)) // remove .jsonl
                        if let info = fileInfo(at: filePath) {
                            files.append(DiscoveredFile(
                                path: filePath,
                                sessionId: sessionId,
                                project: project,
                                fileSize: info.size,
                                modifiedAt: info.modified
                            ))
                        }
                    }

                    // Check session subdirectories
                    let sessionPath = (projectPath as NSString).appendingPathComponent(file)
                    var sessionIsDir: ObjCBool = false
                    if fm.fileExists(atPath: sessionPath, isDirectory: &sessionIsDir), sessionIsDir.boolValue {
                        // Direct JSONL in session dir
                        if let innerFiles = try? fm.contentsOfDirectory(atPath: sessionPath) {
                            for inner in innerFiles where inner.hasSuffix(".jsonl") {
                                let innerPath = (sessionPath as NSString).appendingPathComponent(inner)
                                let sid = String(inner.dropLast(6))
                                if let info = fileInfo(at: innerPath) {
                                    files.append(DiscoveredFile(
                                        path: innerPath,
                                        sessionId: sid,
                                        project: project,
                                        fileSize: info.size,
                                        modifiedAt: info.modified
                                    ))
                                }
                            }
                        }

                        // subagents/ subdirectory
                        let subagentsPath = (sessionPath as NSString).appendingPathComponent("subagents")
                        if fm.fileExists(atPath: subagentsPath, isDirectory: &sessionIsDir), sessionIsDir.boolValue {
                            if let subFiles = try? fm.contentsOfDirectory(atPath: subagentsPath) {
                                for sub in subFiles where sub.hasSuffix(".jsonl") {
                                    let subPath = (subagentsPath as NSString).appendingPathComponent(sub)
                                    let sid = String(sub.dropLast(6))
                                    if let info = fileInfo(at: subPath) {
                                        files.append(DiscoveredFile(
                                            path: subPath,
                                            sessionId: sid,
                                            project: project,
                                            fileSize: info.size,
                                            modifiedAt: info.modified
                                        ))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return files
    }

    private func deriveProjectName(from dirName: String) -> String {
        // "-Users-jake-Desktop-MyProject" → split by "-" and take last meaningful component
        let parts = dirName.split(separator: "-")
        // Find the last part that isn't a common path component
        let skipParts: Set<String> = ["Users", "Library", "CloudStorage", "Dropbox",
                                       "Application", "Support", "Desktop", "Documents", "Mobile"]
        // Take from the end, skipping common path parts
        var projectParts: [String] = []
        for part in parts.reversed() {
            let s = String(part)
            if skipParts.contains(s) { break }
            projectParts.insert(s, at: 0)
        }
        return projectParts.isEmpty ? dirName : projectParts.joined(separator: "-")
    }

    private func fileInfo(at path: String) -> (size: Int64, modified: Date?)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? Int64) ?? 0
        let modified = attrs[.modificationDate] as? Date
        return (size, modified)
    }
}
