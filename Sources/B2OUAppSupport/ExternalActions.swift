import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum B2OUExternalActionKind: String, Equatable, Sendable {
    case open
    case reveal
}

public struct B2OUExternalActionRecord: Equatable, Sendable {
    public let kind: B2OUExternalActionKind
    public let targets: [String]

    public init(kind: B2OUExternalActionKind, targets: [String]) {
        self.kind = kind
        self.targets = targets
    }
}

private final class B2OUExternalActionCenter {
    static let shared = B2OUExternalActionCenter()

    private let lock = NSLock()
    private var records: [B2OUExternalActionRecord] = []
    private var openHandler: ((URL) -> Void)?
    private var revealHandler: (([URL]) -> Void)?

    func install(
        openHandler: ((URL) -> Void)?,
        revealHandler: (([URL]) -> Void)?
    ) {
        lock.lock()
        self.records = []
        self.openHandler = openHandler
        self.revealHandler = revealHandler
        lock.unlock()
    }

    func reset() {
        lock.lock()
        records = []
        openHandler = nil
        revealHandler = nil
        lock.unlock()
    }

    func snapshot() -> [B2OUExternalActionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func open(_ url: URL) {
        lock.lock()
        records.append(B2OUExternalActionRecord(kind: .open, targets: [url.absoluteString]))
        let handler = openHandler
        lock.unlock()

        if let handler {
            handler(url)
            return
        }
#if canImport(AppKit)
        NSWorkspace.shared.open(url)
#endif
    }

    func reveal(_ urls: [URL]) {
        let targets = urls.map(\.absoluteString)
        lock.lock()
        records.append(B2OUExternalActionRecord(kind: .reveal, targets: targets))
        let handler = revealHandler
        lock.unlock()

        if let handler {
            handler(urls)
            return
        }
#if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
#endif
    }
}

public let b2ouReleasesURL = URL(string: "https://github.com/desususu/B2OU/releases")!
public let b2ouProjectPageURL = URL(string: "https://github.com/desususu/B2OU")!

public func b2ouOpen(_ url: URL) {
    B2OUExternalActionCenter.shared.open(url)
}

public func b2ouReveal(_ urls: [URL]) {
    B2OUExternalActionCenter.shared.reveal(urls)
}

public func installB2OUExternalActionRecorder(
    openHandler: ((URL) -> Void)? = nil,
    revealHandler: (([URL]) -> Void)? = nil
) {
    B2OUExternalActionCenter.shared.install(
        openHandler: openHandler,
        revealHandler: revealHandler
    )
}

public func resetB2OUExternalActionRecorder() {
    B2OUExternalActionCenter.shared.reset()
}

public func currentB2OUExternalActionRecords() -> [B2OUExternalActionRecord] {
    B2OUExternalActionCenter.shared.snapshot()
}

public func b2ouBearNoteURL(noteID: String) -> URL? {
    guard !noteID.isEmpty,
          let encoded = noteID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
        return nil
    }
    return URL(string: "bear://x-callback-url/open-note?id=\(encoded)")
}
