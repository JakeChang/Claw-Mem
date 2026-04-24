import Foundation
import SwiftData

enum ClawMemSchemaV1: VersionedSchema {
    nonisolated(unsafe) static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [SourceFile.self, RawEvent.self, Message.self,
         ToolEvent.self, Summary.self, IngestError.self]
    }
}

enum ClawMemSchemaV2: VersionedSchema {
    nonisolated(unsafe) static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [SourceFile.self, RawEvent.self, Message.self,
         ToolEvent.self, Summary.self, IngestError.self,
         UserNote.self]
    }
}

enum ClawMemSchemaV3: VersionedSchema {
    nonisolated(unsafe) static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [SourceFile.self, RawEvent.self, Message.self,
         ToolEvent.self, Summary.self, IngestError.self,
         UserNote.self, DeletedRecord.self]
    }
}

enum ClawMemMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ClawMemSchemaV1.self, ClawMemSchemaV2.self, ClawMemSchemaV3.self]
    }
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: ClawMemSchemaV1.self, toVersion: ClawMemSchemaV2.self),
            .lightweight(fromVersion: ClawMemSchemaV2.self, toVersion: ClawMemSchemaV3.self),
        ]
    }
}

@MainActor
func makeModelContainer() throws -> ModelContainer {
    let schema = Schema([
        SourceFile.self,
        RawEvent.self,
        Message.self,
        ToolEvent.self,
        Summary.self,
        IngestError.self,
        UserNote.self,
        DeletedRecord.self,
    ])

    let storeDir = URL.homeDirectory.appending(path: ".clawmem")
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: storeDir.path(percentEncoded: false)) {
        try fileManager.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    let config = ModelConfiguration(
        schema: schema,
        url: storeDir.appending(path: "memory.store"),
        allowsSave: true
    )
    return try ModelContainer(
        for: schema,
        migrationPlan: ClawMemMigrationPlan.self,
        configurations: config
    )
}
