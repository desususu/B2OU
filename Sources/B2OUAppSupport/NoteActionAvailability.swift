import Foundation

public struct NoteActionAvailability: Equatable, Sendable {
    public let exportedFileExists: Bool
    public let canOpenInBear: Bool

    public init(exportedFileExists: Bool, canOpenInBear: Bool) {
        self.exportedFileExists = exportedFileExists
        self.canOpenInBear = canOpenInBear
    }

    public var canOpenExportedFile: Bool {
        exportedFileExists
    }

    public var canRevealExportedFile: Bool {
        exportedFileExists
    }
}

public func noteActionAvailability(
    for note: NoteMetadata,
    fileExists: Bool? = nil
) -> NoteActionAvailability {
    let exportedFileExists = fileExists ?? FileManager.default.fileExists(atPath: note.filePath.path)
    return NoteActionAvailability(
        exportedFileExists: exportedFileExists,
        canOpenInBear: !note.bearId.isEmpty
    )
}

public func notesContainMissingSourceLinks(_ notes: [NoteMetadata]) -> Bool {
    notes.contains { $0.bearId.isEmpty }
}
