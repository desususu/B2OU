// Constants.swift — Compiled regex patterns, file-extension sets, and constants.

import Foundation

// MARK: - Core Data Epoch

/// Bear stores timestamps as Core Data "seconds since 2001-01-01 UTC".
/// Adding this offset converts them to Unix timestamps.
public let coreDataEpoch: Double = 978_307_200.0

// MARK: - Image References

public let reMarkdownImage = try! NSRegularExpression(pattern: #"!\[(.*?)\]\(([^)]+)\)"#)
public let reMarkdownLink = try! NSRegularExpression(pattern: #"(?<!!)\[([^\]]+)\]\(([^)]+)\)"#)
public let reWikiImage = try! NSRegularExpression(pattern: #"!\[\[(.*?)\]\]"#)
public let reHtmlImgTag = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
public let reHtmlImgSrc = try! NSRegularExpression(pattern: #"\bsrc=(['"])(.*?)\1"#, options: .caseInsensitive)
public let reHtmlImgAlt = try! NSRegularExpression(pattern: #"\balt=(['"])(.*?)\1"#, options: .caseInsensitive)

/// Bear 1.x inline image syntax: [image:UUID/filename]
public let reBearImage = try! NSRegularExpression(pattern: #"\[image:(.+?)\]"#)
public let reBearImageSub = try! NSRegularExpression(pattern: #"\[image:(.+?)/(.+?)\]"#)

/// Bear file attachment syntax: [file:UUID/filename]
public let reBearFile = try! NSRegularExpression(pattern: #"\[file:(.+?)\]"#)
public let reBearFileSub = try! NSRegularExpression(pattern: #"\[file:(.+?)/(.+?)\]"#)

/// Bear embed metadata
public let reBearEmbed = try! NSRegularExpression(pattern: #"<!--\s*\{\s*"embed"\s*:\s*"?true"?\s*\}\s*-->"#)

// MARK: - Tags

/// #tag or #nested/tag
public let reTagPattern1 = try! NSRegularExpression(pattern: ##"(?<!\S)\#([.\w\/\-]+)[ \n]?(?!([\/ \w]+\w[#]))"##)
/// Multi-word tags: #multi word tag#
public let reTagPattern2 = try! NSRegularExpression(pattern: ##"(?<![\S])\#([^ \d][.\w\/ ]+?)\#([ \n]|$)"##)
/// Hide tags: strip tag lines
public let reHideTags = try! NSRegularExpression(pattern: ##"(\n)[ \t]*(\#[^\s#].*)"##)

// MARK: - Markdown Structure

public let reMarkdownHeading = try! NSRegularExpression(pattern: #"^#+\s*"#, options: .anchorsMatchLines)
public let reCleanTitle = try! NSRegularExpression(pattern: #"[\/\\:*?"<>|\x00-\x1f]+"#)
public let reTrailingDash = try! NSRegularExpression(pattern: #"-+$"#)
public let reBearHighlight = try! NSRegularExpression(pattern: #"(?<!\:)\:\:(?!\:)(.+?)(?<!\:)\:\:(?!\:)"#)
public let reInvalidDirChars = try! NSRegularExpression(pattern: #"[<>:"|?*\x00-\x1f]"#)
public let reMultipleUnderscores = try! NSRegularExpression(pattern: #"_+"#)
public let reNonAlnum = try! NSRegularExpression(pattern: #"[^a-z0-9]+"#)

// Reference-style links
public let reRefDef = try! NSRegularExpression(pattern: #"^\[(?!\/\/)([^\]]+)\]:\s*(\S+).*$"#, options: .anchorsMatchLines)
public let reRefImg = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\[([^\]]+)\]"#)
public let reRefImp = try! NSRegularExpression(pattern: #"!\[([^\[\]]+)\](?!\()"#)
public let reRefLink = try! NSRegularExpression(pattern: #"(?<!!)\[([^\]]+)\]\[([^\]]+)\]"#)
public let reRefLinkImp = try! NSRegularExpression(pattern: #"(?<!!)\[([^\[\]]+)\](?!\(|\[|:)"#)
public let reRefClean = try! NSRegularExpression(pattern: #"^\[(?!\/\/)[^\]]+\]:\s*\S+.*$\n?"#, options: .anchorsMatchLines)

// MARK: - File System Constants

public let imageExtensions: Set<String> = [
    ".png", ".jpg", ".jpeg", ".gif", ".webp",
    ".heic", ".bmp", ".tif", ".tiff",
]

public let noteExtensions: Set<String> = [".md", ".txt", ".markdown"]

public let sentinelFiles: Set<String> = [
    ".sync-time.log", ".export-time.log", ".b2ou-manifest",
]

public let exportSkipDirs: Set<String> = ["BearImages", ".obsidian", ".b2ou-backups", ".b2ou"]
public let exportSkipDirPrefixes: [String] = [".Ulysses"]
