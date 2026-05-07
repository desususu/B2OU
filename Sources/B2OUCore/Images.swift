// Images.swift — Image copy and path-resolution helpers for the export pipeline.

import Foundation

// MARK: - Low-Level File Helpers

public func findAttachment(
    fileUUID: String,
    filename: String,
    bearImagePath: URL,
    bearFilePath: URL? = nil
) -> URL? {
    let fm = FileManager.default
    let candidate = bearImagePath.appendingPathComponent(fileUUID).appendingPathComponent(filename)
    if fm.fileExists(atPath: candidate.path) { return candidate }
    if let bearFilePath {
        let candidate2 = bearFilePath.appendingPathComponent(fileUUID).appendingPathComponent(filename)
        if fm.fileExists(atPath: candidate2.path) { return candidate2 }
    }
    return nil
}

public func isImageFile(_ filename: String) -> Bool {
    let ext = (filename as NSString).pathExtension.lowercased()
    return imageExtensions.contains(".\(ext)")
}

public func makeLink(filename: String, relPath: String) -> String {
    let encoded = relPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relPath
    if isImageFile(filename) {
        return "![\(filename)](\(encoded))"
    }
    return "[\(filename)](\(encoded))"
}

public func copyIncremental(source: URL, dest: URL) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: source.path) else { return }

    if fm.fileExists(atPath: dest.path) {
        if let srcAttrs = try? fm.attributesOfItem(atPath: source.path),
           let dstAttrs = try? fm.attributesOfItem(atPath: dest.path),
           let srcMod = srcAttrs[.modificationDate] as? Date,
           let dstMod = dstAttrs[.modificationDate] as? Date,
           let srcSize = srcAttrs[.size] as? NSNumber,
           let dstSize = dstAttrs[.size] as? NSNumber,
           dstMod >= srcMod,
           dstSize.int64Value == srcSize.int64Value {
            return
        }
    }

    let tmp = dest.deletingLastPathComponent()
        .appendingPathComponent(".\(dest.lastPathComponent).tmp-\(UUID().uuidString)")
    do {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: tmp)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
    } catch {
        try? fm.removeItem(at: tmp)
        // Log warning but continue
    }
}

// MARK: - Referenced Image Collection

public func collectReferencedLocalImages(rootPath: URL, skipDirs: Set<String>) -> Set<URL> {
    var refs = Set<URL>()
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: rootPath,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return refs }

    while let fileURL = enumerator.nextObject() as? URL {
        let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            let name = fileURL.lastPathComponent
            if skipDirs.contains(name) || name == ".git" || name == "__pycache__" {
                enumerator.skipDescendants()
            }
            continue
        }

        let ext = fileURL.pathExtension.lowercased()
        guard ext == "md" || ext == "txt" || ext == "markdown" else { continue }

        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        let converted = htmlImgToMarkdown(text)

        for match in reMarkdownImage.allMatches(in: converted) {
            if match.numberOfRanges >= 3 {
                let raw = normalizeLocalImageRef((converted as NSString).substring(with: match.range(at: 2)))
                guard !raw.isEmpty, !raw.hasPrefix("http://"), !raw.hasPrefix("https://") else { continue }
                let absImg = (raw as NSString).isAbsolutePath
                    ? URL(fileURLWithPath: raw)
                    : fileURL.deletingLastPathComponent().appendingPathComponent(raw).standardized
                refs.insert(absImg)
            }
        }

        for match in reWikiImage.allMatches(in: converted) {
            if match.numberOfRanges >= 2 {
                let raw = normalizeLocalImageRef((converted as NSString).substring(with: match.range(at: 1)))
                guard !raw.isEmpty, !raw.hasPrefix("http://"), !raw.hasPrefix("https://") else { continue }
                let absImg = (raw as NSString).isAbsolutePath
                    ? URL(fileURLWithPath: raw)
                    : fileURL.deletingLastPathComponent().appendingPathComponent(raw).standardized
                refs.insert(absImg)
            }
        }
    }
    return refs
}

// MARK: - Export-Side Image Processing (Markdown format)

public func processExportImages(
    text: String,
    filepath: URL,
    conn: SQLiteConnection,
    notePK: Int64,
    bearImagePath: URL,
    assetsPath: URL,
    exportPath: URL,
    bearFilePath: URL? = nil,
    fileMap: [String: String]? = nil
) -> String {
    // Build filename → UUID map
    let fMap: [String: String]
    if let fileMap {
        fMap = fileMap
    } else {
        var m: [String: String] = [:]
        for row in conn.query(
            "SELECT ZFILENAME, ZUNIQUEIDENTIFIER FROM ZSFNOTEFILE WHERE ZNOTE = ?",
            params: [notePK]
        ) {
            if let fn = row["ZFILENAME"] as? String, let uuid = row["ZUNIQUEIDENTIFIER"] as? String {
                m[fn] = uuid
            }
        }
        fMap = m
    }

    let relAssets: String
    if let relPath = relativePath(from: exportPath, to: assetsPath) {
        relAssets = relPath
    } else {
        relAssets = "BearImages"
    }
    let relAssetsPrefix = relAssets + "/"

    var result = text
    var exportedFilenames = Set<String>()

    // Bear 1.x: [image:UUID/filename]
    result = reBearImage.replaceAll(in: result) { match, str in
        let ref = (str as NSString).substring(with: match.range(at: 1))
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (str as NSString).substring(with: match.range) }
        let (imgUUID, imgFilename) = (parts[0], parts[1])
        exportedFilenames.insert(imgFilename)
        guard let source = findAttachment(fileUUID: imgUUID, filename: imgFilename,
                                          bearImagePath: bearImagePath, bearFilePath: bearFilePath) else {
            return (str as NSString).substring(with: match.range)
        }
        let dest = assetsPath.appendingPathComponent(imgUUID).appendingPathComponent(imgFilename)
        copyIncremental(source: source, dest: dest)
        let rel = "\(relAssets)/\(imgUUID)/\(imgFilename)"
        return "![](\(rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel))"
    }

    // Bear 1.x: [file:UUID/filename]
    result = reBearFile.replaceAll(in: result) { match, str in
        let ref = (str as NSString).substring(with: match.range(at: 1))
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (str as NSString).substring(with: match.range) }
        let (fileUUID, fileName) = (parts[0], parts[1])
        exportedFilenames.insert(fileName)
        guard let source = findAttachment(fileUUID: fileUUID, filename: fileName,
                                          bearImagePath: bearImagePath, bearFilePath: bearFilePath) else {
            return (str as NSString).substring(with: match.range)
        }
        let dest = assetsPath.appendingPathComponent(fileUUID).appendingPathComponent(fileName)
        copyIncremental(source: source, dest: dest)
        let rel = "\(relAssets)/\(fileUUID)/\(fileName)"
        return makeLink(filename: fileName, relPath: rel)
    }

    // Bear 2.x: ![alt](filename)
    result = reMarkdownImage.replaceAll(in: result) { match, str in
        let fullMatch = (str as NSString).substring(with: match.range)
        let imgURL = (str as NSString).substring(with: match.range(at: 2))
        if imgURL.hasPrefix("http") { return fullMatch }

        let imgFilename = imgURL.removingPercentEncoding ?? imgURL
        if imgFilename.hasPrefix(relAssetsPrefix) { return fullMatch }

        let basename = (imgFilename as NSString).lastPathComponent
        guard let fileUUID = fMap[basename] else { return fullMatch }
        exportedFilenames.insert(basename)
        guard let source = findAttachment(fileUUID: fileUUID, filename: basename,
                                          bearImagePath: bearImagePath, bearFilePath: bearFilePath) else {
            return fullMatch
        }
        let dest = assetsPath.appendingPathComponent(fileUUID).appendingPathComponent(basename)
        copyIncremental(source: source, dest: dest)
        let alt = (str as NSString).substring(with: match.range(at: 1))
        let rel = "\(relAssets)/\(fileUUID)/\(basename)"
        return "![\(alt)](\(rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel))"
    }

    // Bear 2.x: [label](filename) for non-image attachments
    result = reMarkdownLink.replaceAll(in: result) { match, str in
        let fullMatch = (str as NSString).substring(with: match.range)
        let label = (str as NSString).substring(with: match.range(at: 1))
        let raw = (str as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("mailto:") { return fullMatch }

        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard let urlPart = parts.first else { return fullMatch }
        let tail = raw.count > urlPart.count ? String(raw.dropFirst(urlPart.count)) : ""
        let urlClean = urlPart.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))

        if urlClean.hasPrefix(relAssetsPrefix) {
            let decoded = (urlClean.removingPercentEncoding ?? urlClean) as NSString
            exportedFilenames.insert(decoded.lastPathComponent)
            return fullMatch
        }

        let basename = ((urlClean.removingPercentEncoding ?? urlClean) as NSString).lastPathComponent
        guard let fileUUID = fMap[basename] else { return fullMatch }
        exportedFilenames.insert(basename)
        guard let source = findAttachment(fileUUID: fileUUID, filename: basename,
                                          bearImagePath: bearImagePath, bearFilePath: bearFilePath) else {
            return fullMatch
        }
        let dest = assetsPath.appendingPathComponent(fileUUID).appendingPathComponent(basename)
        copyIncremental(source: source, dest: dest)
        let rel = "\(relAssets)/\(fileUUID)/\(basename)"
        return "[\(label)](\(rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel)\(tail))"
    }

    // Unreferenced attachments
    var unreferencedLinks: [String] = []
    for (filename, fileUUID) in fMap where !exportedFilenames.contains(filename) {
        guard let source = findAttachment(fileUUID: fileUUID, filename: filename,
                                          bearImagePath: bearImagePath, bearFilePath: bearFilePath) else {
            continue
        }
        let dest = assetsPath.appendingPathComponent(fileUUID).appendingPathComponent(filename)
        copyIncremental(source: source, dest: dest)
        let rel = "\(relAssets)/\(fileUUID)/\(filename)"
        unreferencedLinks.append(makeLink(filename: filename, relPath: rel))
    }

    if !unreferencedLinks.isEmpty {
        result = result.trimmingTrailingWhitespace() + "\n\n" + unreferencedLinks.joined(separator: "\n") + "\n"
    }

    return result
}

// MARK: - Bear CLI Attachment Processing (Markdown format)

public func processExportImagesUsingBearCLI(
    text: String,
    filepath: URL,
    noteID: String,
    attachments: [BearCLIAttachment],
    bearCLI: BearCLIClient,
    assetsPath: URL,
    exportPath: URL
) -> String {
    let relAssets: String
    if let relPath = relativePath(from: exportPath, to: assetsPath) {
        relAssets = relPath
    } else {
        relAssets = "BearImages"
    }
    let relAssetsPrefix = relAssets + "/"
    let noteFolder = safeBearCLIAssetFolderName(noteID: noteID)

    let lookup = makeAttachmentLookup(attachments)
    var result = text
    var exportedFilenames = Set<String>()

    func exportAttachment(named rawName: String) -> (filename: String, relativePath: String)? {
        let basename = (((rawName.removingPercentEncoding ?? rawName) as NSString).lastPathComponent)
        guard let attachment = lookup[basename] ?? lookup[rawName] else { return nil }
        let filename = (attachment.filename as NSString).lastPathComponent
        let dest = assetsPath.appendingPathComponent(noteFolder).appendingPathComponent(filename)
        guard saveBearCLIAttachmentIfNeeded(
            attachment: attachment, noteID: noteID, bearCLI: bearCLI, destination: dest
        ) else {
            return nil
        }
        exportedFilenames.insert(filename)
        return (filename, "\(relAssets)/\(noteFolder)/\(filename)")
    }

    // Bear 1.x: [image:UUID/filename]
    result = reBearImage.replaceAll(in: result) { match, str in
        let ref = (str as NSString).substring(with: match.range(at: 1))
        let filename = (ref as NSString).lastPathComponent
        guard let exported = exportAttachment(named: filename) else {
            return (str as NSString).substring(with: match.range)
        }
        let encoded = exported.relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? exported.relativePath
        return "![](\(encoded))"
    }

    // Bear 1.x: [file:UUID/filename]
    result = reBearFile.replaceAll(in: result) { match, str in
        let ref = (str as NSString).substring(with: match.range(at: 1))
        let filename = (ref as NSString).lastPathComponent
        guard let exported = exportAttachment(named: filename) else {
            return (str as NSString).substring(with: match.range)
        }
        return makeLink(filename: exported.filename, relPath: exported.relativePath)
    }

    // Bear 2.x: ![alt](filename)
    result = reMarkdownImage.replaceAll(in: result) { match, str in
        let fullMatch = (str as NSString).substring(with: match.range)
        let imgURL = (str as NSString).substring(with: match.range(at: 2))
        if imgURL.hasPrefix("http") { return fullMatch }

        let decoded = imgURL.removingPercentEncoding ?? imgURL
        if decoded.hasPrefix(relAssetsPrefix) { return fullMatch }
        guard let exported = exportAttachment(named: decoded) else { return fullMatch }
        let alt = (str as NSString).substring(with: match.range(at: 1))
        let encoded = exported.relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? exported.relativePath
        return "![\(alt)](\(encoded))"
    }

    // Bear 2.x: [label](filename) for non-image attachments
    result = reMarkdownLink.replaceAll(in: result) { match, str in
        let fullMatch = (str as NSString).substring(with: match.range)
        let label = (str as NSString).substring(with: match.range(at: 1))
        let raw = (str as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("mailto:") { return fullMatch }

        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard let urlPart = parts.first else { return fullMatch }
        let tail = raw.count > urlPart.count ? String(raw.dropFirst(urlPart.count)) : ""
        let urlClean = urlPart.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let decoded = urlClean.removingPercentEncoding ?? urlClean

        if decoded.hasPrefix(relAssetsPrefix) {
            exportedFilenames.insert((decoded as NSString).lastPathComponent)
            return fullMatch
        }

        guard let exported = exportAttachment(named: decoded) else { return fullMatch }
        let encoded = exported.relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? exported.relativePath
        return "[\(label)](\(encoded)\(tail))"
    }

    var unreferencedLinks: [String] = []
    for attachment in attachments {
        let filename = (attachment.filename as NSString).lastPathComponent
        guard !exportedFilenames.contains(filename) else { continue }
        let dest = assetsPath.appendingPathComponent(noteFolder).appendingPathComponent(filename)
        guard saveBearCLIAttachmentIfNeeded(
            attachment: attachment, noteID: noteID, bearCLI: bearCLI, destination: dest
        ) else {
            continue
        }
        let rel = "\(relAssets)/\(noteFolder)/\(filename)"
        unreferencedLinks.append(makeLink(filename: filename, relPath: rel))
    }

    if !unreferencedLinks.isEmpty {
        result = result.trimmingTrailingWhitespace() + "\n\n" + unreferencedLinks.joined(separator: "\n") + "\n"
    }

    return result
}

// MARK: - Export-Side Image Processing (TextBundle format)

public func processExportImagesTextbundle(
    text: String,
    bundleAssets: URL,
    conn: SQLiteConnection,
    notePK: Int64,
    bearImagePath: URL,
    bearFilePath: URL? = nil,
    existingAssets: URL? = nil,
    fileMap: [String: String]? = nil
) -> String {
    let fMap: [String: String]
    if let fileMap {
        fMap = fileMap
    } else {
        var m: [String: String] = [:]
        for row in conn.query(
            "SELECT ZFILENAME, ZUNIQUEIDENTIFIER FROM ZSFNOTEFILE WHERE ZNOTE = ?",
            params: [notePK]
        ) {
            if let fn = row["ZFILENAME"] as? String, let uuid = row["ZUNIQUEIDENTIFIER"] as? String {
                m[fn] = uuid
            }
        }
        fMap = m
    }

    var result = text
    var exportedFilenames = Set<String>()
    let fm = FileManager.default

    func linkOrCopy(src: URL, dest: URL) {
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.linkItem(at: src, to: dest)
        } catch {
            // Hard link failed (e.g. cross-device); fall back to copy
            try? fm.copyItem(at: src, to: dest)
        }
    }

    func copyTBAsset(source: URL?, dest: URL) {
        guard let source, fm.fileExists(atPath: source.path) else { return }
        if let existingAssets {
            let existing = existingAssets.appendingPathComponent(dest.lastPathComponent)
            if fm.fileExists(atPath: existing.path) {
                if let srcAttrs = try? fm.attributesOfItem(atPath: source.path),
                   let exAttrs = try? fm.attributesOfItem(atPath: existing.path),
                   let srcSize = srcAttrs[.size] as? Int,
                   let exSize = exAttrs[.size] as? Int,
                   let srcMod = srcAttrs[.modificationDate] as? Date,
                   let exMod = exAttrs[.modificationDate] as? Date,
                   exSize == srcSize && exMod >= srcMod {
                    linkOrCopy(src: existing, dest: dest)
                    return
                }
            }
        }
        copyIncremental(source: source, dest: dest)
    }

    // Bear 1.x: [image:UUID/filename]
    result = reBearImage.replaceAll(in: result) { match, str in
        let fullMatch = (str as NSString).substring(with: match.range)
        let imageName = (str as NSString).substring(with: match.range(at: 1))
        let parts = imageName.split(separator: "/", maxSplits: 1).map(String.init)
        let newName = imageName.replacingOccurrences(of: "/", with: "_")
        if parts.count == 2 {
            let source = findAttachment(fileUUID: parts[0], filename: parts[1],
                                        bearImagePath: bearImagePath, bearFilePath: bearFilePath)
            guard source != nil else { return fullMatch }
            exportedFilenames.insert(parts[1])
            copyTBAsset(source: source, dest: bundleAssets.appendingPathComponent(newName))
            let assetRef = "assets/\(newName)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "assets/\(newName)"
            return "![](\(assetRef))"
        } else {
            let source = bearImagePath.appendingPathComponent(imageName)
            guard fm.fileExists(atPath: source.path) else { return fullMatch }
            copyTBAsset(source: source, dest: bundleAssets.appendingPathComponent(newName))
            let assetRef = "assets/\(newName)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "assets/\(newName)"
            return "![](\(assetRef))"
        }
    }

    // Bear 1.x: [file:UUID/filename]
    result = reBearFile.replaceAll(in: result) { match, str in
        let ref = (str as NSString).substring(with: match.range(at: 1))
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (str as NSString).substring(with: match.range) }
        let (fileUUID, fileName) = (parts[0], parts[1])
        exportedFilenames.insert(fileName)
        guard let source = findAttachment(fileUUID: fileUUID, filename: fileName,
                                          bearImagePath: bearImagePath, bearFilePath: bearFilePath) else {
            return (str as NSString).substring(with: match.range)
        }
        let newName = "\(fileUUID)_\(fileName)"
        copyTBAsset(source: source, dest: bundleAssets.appendingPathComponent(newName))
        return makeLink(filename: fileName, relPath: "assets/\(newName)")
    }

    // Bear 2.x: ![alt](filename)
    result = reMarkdownImage.replaceAll(in: result) { match, str in
        let fullMatch = (str as NSString).substring(with: match.range)
        let altText = (str as NSString).substring(with: match.range(at: 1))
        let imageURL = (str as NSString).substring(with: match.range(at: 2))
        if imageURL.hasPrefix("http") || imageURL.hasPrefix("assets/") { return fullMatch }
        let imageFilename = imageURL.removingPercentEncoding ?? imageURL
        let basename = (imageFilename as NSString).lastPathComponent
        guard let fileUUID = fMap[basename] else { return fullMatch }
        exportedFilenames.insert(basename)
        guard let source = findAttachment(fileUUID: fileUUID, filename: basename,
                                          bearImagePath: bearImagePath, bearFilePath: bearFilePath) else {
            return fullMatch
        }
        let newName = "\(fileUUID)_\(basename)"
        copyTBAsset(source: source, dest: bundleAssets.appendingPathComponent(newName))
        let assetRef = "assets/\(newName)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "assets/\(newName)"
        return "![\(altText)](\(assetRef))"
    }

    // Bear 2.x: [label](filename) for non-image attachments
    result = reMarkdownLink.replaceAll(in: result) { match, str in
        let fullMatch = (str as NSString).substring(with: match.range)
        let label = (str as NSString).substring(with: match.range(at: 1))
        let raw = (str as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("mailto:") { return fullMatch }
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard let urlPart = parts.first else { return fullMatch }
        let tail = raw.count > urlPart.count ? String(raw.dropFirst(urlPart.count)) : ""
        let urlClean = urlPart.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        if urlClean.hasPrefix("assets/") {
            exportedFilenames.insert(((urlClean.removingPercentEncoding ?? urlClean) as NSString).lastPathComponent)
            return fullMatch
        }
        let basename = ((urlClean.removingPercentEncoding ?? urlClean) as NSString).lastPathComponent
        guard let fileUUID = fMap[basename] else { return fullMatch }
        exportedFilenames.insert(basename)
        guard let source = findAttachment(fileUUID: fileUUID, filename: basename,
                                          bearImagePath: bearImagePath, bearFilePath: bearFilePath) else {
            return fullMatch
        }
        let newName = "\(fileUUID)_\(basename)"
        copyTBAsset(source: source, dest: bundleAssets.appendingPathComponent(newName))
        let assetRef = "assets/\(newName)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "assets/\(newName)"
        return "[\(label)](\(assetRef)\(tail))"
    }

    // Unreferenced attachments
    var unreferencedLinks: [String] = []
    for (filename, fileUUID) in fMap where !exportedFilenames.contains(filename) {
        guard let source = findAttachment(fileUUID: fileUUID, filename: filename,
                                          bearImagePath: bearImagePath, bearFilePath: bearFilePath) else {
            continue
        }
        let newName = "\(fileUUID)_\(filename)"
        let target = bundleAssets.appendingPathComponent(newName)
        if !fm.fileExists(atPath: target.path) {
            copyTBAsset(source: source, dest: target)
        }
        unreferencedLinks.append(makeLink(filename: filename, relPath: "assets/\(newName)"))
    }

    if !unreferencedLinks.isEmpty {
        result = result.trimmingTrailingWhitespace() + "\n\n" + unreferencedLinks.joined(separator: "\n") + "\n"
    }

    return result
}

public func processExportImagesTextbundleUsingBearCLI(
    text: String,
    bundleAssets: URL,
    noteID: String,
    attachments: [BearCLIAttachment],
    bearCLI: BearCLIClient,
    existingAssets: URL? = nil
) -> String {
    let noteFolder = safeBearCLIAssetFolderName(noteID: noteID)
    let lookup = makeAttachmentLookup(attachments)
    var result = text
    var exportedFilenames = Set<String>()
    let fm = FileManager.default

    func exportAttachment(named rawName: String) -> (filename: String, assetRef: String)? {
        let basename = (((rawName.removingPercentEncoding ?? rawName) as NSString).lastPathComponent)
        guard let attachment = lookup[basename] ?? lookup[rawName] else { return nil }
        let filename = (attachment.filename as NSString).lastPathComponent
        let newName = "\(noteFolder)_\(filename)"
        let dest = bundleAssets.appendingPathComponent(newName)

        if let existingAssets {
            let existing = existingAssets.appendingPathComponent(newName)
            if fm.fileExists(atPath: existing.path),
               let existingSize = (try? fm.attributesOfItem(atPath: existing.path)[.size]) as? NSNumber,
               attachment.size == nil || existingSize.int64Value == attachment.size {
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try fm.linkItem(at: existing, to: dest)
                } catch {
                    try? fm.copyItem(at: existing, to: dest)
                }
                exportedFilenames.insert(filename)
                return (filename, "assets/\(newName)")
            }
        }

        guard saveBearCLIAttachmentIfNeeded(
            attachment: attachment, noteID: noteID, bearCLI: bearCLI, destination: dest
        ) else {
            return nil
        }
        exportedFilenames.insert(filename)
        return (filename, "assets/\(newName)")
    }

    // Bear 1.x: [image:UUID/filename]
    result = reBearImage.replaceAll(in: result) { match, str in
        let ref = (str as NSString).substring(with: match.range(at: 1))
        let filename = (ref as NSString).lastPathComponent
        guard let exported = exportAttachment(named: filename) else {
            return (str as NSString).substring(with: match.range)
        }
        let encoded = exported.assetRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? exported.assetRef
        return "![](\(encoded))"
    }

    // Bear 1.x: [file:UUID/filename]
    result = reBearFile.replaceAll(in: result) { match, str in
        let ref = (str as NSString).substring(with: match.range(at: 1))
        let filename = (ref as NSString).lastPathComponent
        guard let exported = exportAttachment(named: filename) else {
            return (str as NSString).substring(with: match.range)
        }
        return makeLink(filename: exported.filename, relPath: exported.assetRef)
    }

    // Bear 2.x: ![alt](filename)
    result = reMarkdownImage.replaceAll(in: result) { match, str in
        let fullMatch = (str as NSString).substring(with: match.range)
        let altText = (str as NSString).substring(with: match.range(at: 1))
        let imageURL = (str as NSString).substring(with: match.range(at: 2))
        if imageURL.hasPrefix("http") || imageURL.hasPrefix("assets/") { return fullMatch }
        guard let exported = exportAttachment(named: imageURL) else { return fullMatch }
        let encoded = exported.assetRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? exported.assetRef
        return "![\(altText)](\(encoded))"
    }

    // Bear 2.x: [label](filename) for non-image attachments
    result = reMarkdownLink.replaceAll(in: result) { match, str in
        let fullMatch = (str as NSString).substring(with: match.range)
        let label = (str as NSString).substring(with: match.range(at: 1))
        let raw = (str as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("mailto:") { return fullMatch }

        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard let urlPart = parts.first else { return fullMatch }
        let tail = raw.count > urlPart.count ? String(raw.dropFirst(urlPart.count)) : ""
        let urlClean = urlPart.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        if urlClean.hasPrefix("assets/") {
            exportedFilenames.insert(((urlClean.removingPercentEncoding ?? urlClean) as NSString).lastPathComponent)
            return fullMatch
        }
        guard let exported = exportAttachment(named: urlClean) else { return fullMatch }
        let encoded = exported.assetRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? exported.assetRef
        return "[\(label)](\(encoded)\(tail))"
    }

    var unreferencedLinks: [String] = []
    for attachment in attachments {
        let filename = (attachment.filename as NSString).lastPathComponent
        guard !exportedFilenames.contains(filename) else { continue }
        guard let exported = exportAttachment(named: filename) else { continue }
        unreferencedLinks.append(makeLink(filename: exported.filename, relPath: exported.assetRef))
    }

    if !unreferencedLinks.isEmpty {
        result = result.trimmingTrailingWhitespace() + "\n\n" + unreferencedLinks.joined(separator: "\n") + "\n"
    }

    return result
}

private func makeAttachmentLookup(_ attachments: [BearCLIAttachment]) -> [String: BearCLIAttachment] {
    var lookup: [String: BearCLIAttachment] = [:]
    for attachment in attachments {
        let decoded = attachment.filename.removingPercentEncoding ?? attachment.filename
        let basename = (decoded as NSString).lastPathComponent
        if lookup[attachment.filename] == nil { lookup[attachment.filename] = attachment }
        if lookup[decoded] == nil { lookup[decoded] = attachment }
        if lookup[basename] == nil { lookup[basename] = attachment }
    }
    return lookup
}

private func saveBearCLIAttachmentIfNeeded(
    attachment: BearCLIAttachment,
    noteID: String,
    bearCLI: BearCLIClient,
    destination: URL
) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: destination.path),
       let expectedSize = attachment.size,
       let existingSize = (try? fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber,
       existingSize.int64Value == expectedSize {
        return true
    }
    do {
        try bearCLI.saveAttachment(noteID: noteID, filename: attachment.filename, to: destination)
    } catch {
        return false
    }
    guard fm.fileExists(atPath: destination.path) else { return false }
    if let expectedSize = attachment.size,
       let existingSize = (try? fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber {
        return existingSize.int64Value == expectedSize
    }
    return true
}

// MARK: - Path Helpers

private func relativePath(from base: URL, to target: URL) -> String? {
    let baseParts = base.standardized.pathComponents
    let targetParts = target.standardized.pathComponents

    var common = 0
    while common < baseParts.count && common < targetParts.count
            && baseParts[common] == targetParts[common] {
        common += 1
    }

    let ups = baseParts.count - common
    let parts = Array(repeating: "..", count: ups) + Array(targetParts[common...])
    if parts.isEmpty { return "." }
    return parts.joined(separator: "/")
}
