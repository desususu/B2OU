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
        if let srcMod = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date,
           let dstMod = (try? fm.attributesOfItem(atPath: dest.path))?[.modificationDate] as? Date,
           dstMod >= srcMod {
            return
        }
    }

    do {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
    } catch {
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
        let urlPart = parts[0]
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
    for match in reBearImage.allMatches(in: result) {
        let imageName = (result as NSString).substring(with: match.range(at: 1))
        let parts = imageName.split(separator: "/", maxSplits: 1).map(String.init)
        let newName = imageName.replacingOccurrences(of: "/", with: "_")
        if parts.count == 2 {
            let source = findAttachment(fileUUID: parts[0], filename: parts[1],
                                        bearImagePath: bearImagePath, bearFilePath: bearFilePath)
            exportedFilenames.insert(parts[1])
            copyTBAsset(source: source, dest: bundleAssets.appendingPathComponent(newName))
        } else {
            let source = bearImagePath.appendingPathComponent(imageName)
            copyTBAsset(source: source, dest: bundleAssets.appendingPathComponent(newName))
        }
    }
    result = reBearImageSub.replaceAll(in: result, with: "![](assets/$1_$2)")

    // Bear 1.x: [file:UUID/filename]
    result = reBearFile.replaceAll(in: result) { match, str in
        let ref = (str as NSString).substring(with: match.range(at: 1))
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (str as NSString).substring(with: match.range) }
        let (fileUUID, fileName) = (parts[0], parts[1])
        exportedFilenames.insert(fileName)
        let source = findAttachment(fileUUID: fileUUID, filename: fileName,
                                    bearImagePath: bearImagePath, bearFilePath: bearFilePath)
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
        let source = findAttachment(fileUUID: fileUUID, filename: basename,
                                    bearImagePath: bearImagePath, bearFilePath: bearFilePath)
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
        let urlPart = parts[0]
        let tail = raw.count > urlPart.count ? String(raw.dropFirst(urlPart.count)) : ""
        let urlClean = urlPart.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        if urlClean.hasPrefix("assets/") {
            exportedFilenames.insert(((urlClean.removingPercentEncoding ?? urlClean) as NSString).lastPathComponent)
            return fullMatch
        }
        let basename = ((urlClean.removingPercentEncoding ?? urlClean) as NSString).lastPathComponent
        guard let fileUUID = fMap[basename] else { return fullMatch }
        exportedFilenames.insert(basename)
        let source = findAttachment(fileUUID: fileUUID, filename: basename,
                                    bearImagePath: bearImagePath, bearFilePath: bearFilePath)
        let newName = "\(fileUUID)_\(basename)"
        copyTBAsset(source: source, dest: bundleAssets.appendingPathComponent(newName))
        let assetRef = "assets/\(newName)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "assets/\(newName)"
        return "[\(label)](\(assetRef)\(tail))"
    }

    // Unreferenced attachments
    var unreferencedLinks: [String] = []
    for (filename, fileUUID) in fMap where !exportedFilenames.contains(filename) {
        let source = findAttachment(fileUUID: fileUUID, filename: filename,
                                    bearImagePath: bearImagePath, bearFilePath: bearFilePath)
        guard source != nil else { continue }
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
