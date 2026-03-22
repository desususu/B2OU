// Markdown.swift — Pure Markdown transformation functions.
//
// All functions take a string and return a string. No I/O, no config dependencies.

import Foundation

// MARK: - NSRegularExpression Helpers

extension NSRegularExpression {
    func allMatches(in string: String) -> [NSTextCheckingResult] {
        let range = NSRange(string.startIndex..., in: string)
        return matches(in: string, range: range)
    }

    func firstMatch(in string: String) -> NSTextCheckingResult? {
        let range = NSRange(string.startIndex..., in: string)
        return firstMatch(in: string, range: range)
    }

    func replaceAll(in string: String, with template: String) -> String {
        let range = NSRange(string.startIndex..., in: string)
        return stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }

    func replaceAll(in string: String, using block: (NSTextCheckingResult, String) -> String) -> String {
        let nsString = string as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let matches = self.matches(in: string, range: range)

        var result = string
        // Process matches in reverse order to preserve indices
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let replacement = block(match, result)
            result.replaceSubrange(matchRange, with: replacement)
        }
        return result
    }

    func captureGroups(in string: String, match: NSTextCheckingResult) -> [String?] {
        (0..<match.numberOfRanges).map { i in
            let range = match.range(at: i)
            guard range.location != NSNotFound else { return nil }
            return (string as NSString).substring(with: range)
        }
    }
}

// MARK: - Title Sanitization

public func cleanTitle(_ title: String) -> String {
    var result = String(title.prefix(225)).trimmingCharacters(in: .whitespaces)
    if result.isEmpty { result = "Untitled" }
    result = reCleanTitle.replaceAll(in: result, with: "-")
    result = reTrailingDash.replaceAll(in: result, with: "")
    result = result.trimmingCharacters(in: .whitespaces)

    // Ensure UTF-8 byte length fits in 240 bytes
    let maxBytes = 240
    let encoded = Array(result.utf8)
    if encoded.count > maxBytes {
        let truncated = Array(encoded.prefix(maxBytes))
        result = String(bytes: truncated, encoding: .utf8)
            ?? String(decoding: truncated, as: UTF8.self)
        result = result.trimmingCharacters(in: .whitespaces)
    }
    return result
}

// MARK: - Bear → Standard Markdown

public func bearHighlightToMd(_ text: String) -> String {
    reBearHighlight.replaceAll(in: text, with: "==$1==")
}

public func normaliseBearMarkdown(_ text: String) -> String {
    var result = bearHighlightToMd(text)
    result = htmlImgToMarkdown(result)
    result = reBearEmbed.replaceAll(in: result, with: "")
    return result
}

// MARK: - Tag Handling

public func hideTags(_ text: String) -> String {
    reHideTags.replaceAll(in: text, with: "$1")
}

public func extractTags(_ text: String) -> [String] {
    var tags: [String] = []
    for match in reTagPattern1.allMatches(in: text) {
        if let range = Range(match.range(at: 1), in: text) {
            tags.append(String(text[range]))
        }
    }
    for match in reTagPattern2.allMatches(in: text) {
        if let range = Range(match.range(at: 1), in: text) {
            tags.append(String(text[range]))
        }
    }
    return tags
}

public func subPathFromTag(
    basePath: String,
    filename: String,
    text: String,
    makeTagFolders: Bool,
    multiTagFolders: Bool,
    onlyExportTags: [String],
    excludeTags: [String]
) -> [String] {
    let fm = FileManager.default

    if !makeTagFolders {
        if !excludeTags.isEmpty {
            let noteTags = extractTags(text)
            let isExcluded = noteTags.contains { nt in
                excludeTags.contains { et in
                    nt.lowercased().hasPrefix(et.lowercased())
                }
            }
            if isExcluded { return [] }
        }
        return [(basePath as NSString).appendingPathComponent(filename)]
    }

    var tags: [String]
    if multiTagFolders {
        tags = extractTags(text)
        if tags.isEmpty {
            return [(basePath as NSString).appendingPathComponent(filename)]
        }
    } else {
        let t1 = reTagPattern1.firstMatch(in: text)
        let t2 = reTagPattern2.firstMatch(in: text)

        if let t1, let t2 {
            let tag: String
            if t1.range(at: 1).location < t2.range(at: 1).location {
                tag = (text as NSString).substring(with: t1.range(at: 1))
            } else {
                tag = (text as NSString).substring(with: t2.range(at: 1))
            }
            tags = [tag]
        } else if let t1 {
            tags = [(text as NSString).substring(with: t1.range(at: 1))]
        } else if let t2 {
            tags = [(text as NSString).substring(with: t2.range(at: 1))]
        } else {
            return [(basePath as NSString).appendingPathComponent(filename)]
        }
    }

    var paths = [(basePath as NSString).appendingPathComponent(filename)]
    for tag in tags {
        if tag == "/" { continue }
        if !onlyExportTags.isEmpty {
            let match = onlyExportTags.contains { et in
                tag.lowercased().hasPrefix(et.lowercased())
            }
            if !match { continue }
        }
        if excludeTags.contains(where: { tag.lowercased().hasPrefix($0.lowercased()) }) {
            return []
        }
        var sub = tag.hasPrefix(".") ? ("_" + tag.dropFirst()) : tag
        sub = sanitizeDirName(sub)
        if sub.isEmpty { continue }
        let tagPath = (basePath as NSString).appendingPathComponent(sub)
        try? fm.createDirectory(atPath: tagPath, withIntermediateDirectories: true)
        paths.append((tagPath as NSString).appendingPathComponent(filename))
    }
    return paths
}

private func sanitizeDirName(_ name: String) -> String {
    var result = reInvalidDirChars.replaceAll(in: name, with: "_")
    result = reMultipleUnderscores.replaceAll(in: result, with: "_")
    result = result.trimmingCharacters(in: .whitespaces)
    result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    // Prevent path traversal: strip ".." components
    let components = result.components(separatedBy: "/").filter { $0 != ".." && $0 != "." }
    result = components.joined(separator: "/")
    return result
}

// MARK: - HTML → Markdown Image Conversion

public func htmlImgToMarkdown(_ text: String) -> String {
    reHtmlImgTag.replaceAll(in: text) { match, str in
        let tag = (str as NSString).substring(with: match.range)
        guard let srcMatch = reHtmlImgSrc.firstMatch(in: tag) else { return tag }
        let src = (tag as NSString).substring(with: srcMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
        if src.isEmpty { return tag }

        var alt = "image"
        if let altMatch = reHtmlImgAlt.firstMatch(in: tag) {
            let altVal = (tag as NSString).substring(with: altMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if !altVal.isEmpty { alt = altVal }
        }
        alt = alt.replacingOccurrences(of: "]", with: "\\]")
        return "![\(alt)](\(src))"
    }
}

// MARK: - Reference-Style Link Resolution

public func refLinksToInline(_ text: String) -> String {
    // Build reference map
    var refs: [String: String] = [:]
    for match in reRefDef.allMatches(in: text) {
        if match.numberOfRanges >= 3 {
            let key = (text as NSString).substring(with: match.range(at: 1))
            let url = (text as NSString).substring(with: match.range(at: 2))
            refs[key] = url
        }
    }
    guard !refs.isEmpty else { return text }

    var result = text

    // Reference images
    result = reRefImg.replaceAll(in: result) { match, str in
        let alt = (str as NSString).substring(with: match.range(at: 1))
        let ref = (str as NSString).substring(with: match.range(at: 2))
        return "![\(alt)](\(refs[ref] ?? ref))"
    }
    result = reRefImp.replaceAll(in: result) { match, str in
        let alt = (str as NSString).substring(with: match.range(at: 1))
        return "![\(alt)](\(refs[alt] ?? alt))"
    }
    // Reference links
    result = reRefLink.replaceAll(in: result) { match, str in
        let label = (str as NSString).substring(with: match.range(at: 1))
        let ref = (str as NSString).substring(with: match.range(at: 2))
        return "[\(label)](\(refs[ref] ?? ref))"
    }
    result = reRefLinkImp.replaceAll(in: result) { match, str in
        let label = (str as NSString).substring(with: match.range(at: 1))
        if let url = refs[label] {
            return "[\(label)](\(url))"
        }
        return (str as NSString).substring(with: match.range)
    }
    // Remove reference definitions
    result = reRefClean.replaceAll(in: result, with: "")
    return result
}

// MARK: - Image Link Normalization

public func normalizeLocalImageRef(_ rawURL: String?) -> String {
    guard var url = rawURL?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return "" }
    url = url.removingPercentEncoding ?? url

    // Strip optional inline title
    for q in ["\"", "'"] {
        if let idx = url.firstIndex(of: Character(q)) {
            let head = url[url.startIndex..<idx].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty {
                url = head
                break
            }
        }
    }

    if url.hasPrefix("<") && url.hasSuffix(">") {
        url = String(url.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    if url.lowercased().hasPrefix("file://") {
        if let comp = URLComponents(string: url), let path = comp.path.removingPercentEncoding, !path.isEmpty {
            return path
        }
        // Fallback
        let stripped = String(url.dropFirst(7))
        return stripped.removingPercentEncoding ?? stripped
    }

    return url
}

// MARK: - Misc Helpers

public func firstHeading(_ text: String) -> String {
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return reMarkdownHeading.replaceAll(in: trimmed, with: "")
                .trimmingCharacters(in: .whitespaces)
        }
    }
    return ""
}
