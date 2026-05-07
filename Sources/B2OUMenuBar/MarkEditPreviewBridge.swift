// MarkEditPreviewBridge.swift - lightweight native Markdown preview bridge.
//
// MarkEdit's reusable packages use a WKWebView-backed editor bridge. The
// upstream MarkEditKit package currently targets macOS 15+, so this file keeps
// the same narrow SwiftUI/AppKit boundary while preserving B2OU's macOS 13
// deployment target.

import SwiftUI
import WebKit
import Down

struct MarkEditMarkdownPreview: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    var showsPlaceholder = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = renderHTML()
        guard context.coordinator.lastHTML != html || context.coordinator.lastBaseURL != baseURL else {
            return
        }
        context.coordinator.lastHTML = html
        context.coordinator.lastBaseURL = baseURL
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    private func renderHTML() -> String {
        let body: String
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && showsPlaceholder {
            body = #"<p class="empty">No preview text available.</p>"#
        } else {
            body = (try? Down(markdownString: markdown).toHTML()) ?? "<pre>\(escapeHTML(markdown))</pre>"
        }

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            color-scheme: light dark;
            --background: Canvas;
            --text: CanvasText;
            --muted: color-mix(in srgb, CanvasText 55%, transparent);
            --border: color-mix(in srgb, CanvasText 14%, transparent);
            --code: color-mix(in srgb, CanvasText 7%, transparent);
            --link: LinkText;
        }
        * { box-sizing: border-box; }
        html, body {
            background: var(--background);
            color: var(--text);
            margin: 0;
            min-height: 100%;
        }
        body {
            font: 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            line-height: 1.55;
            padding: 18px 20px 24px;
            -webkit-font-smoothing: antialiased;
            overflow-wrap: anywhere;
        }
        h1, h2, h3, h4, h5, h6 {
            letter-spacing: 0;
            line-height: 1.22;
            margin: 1.1em 0 .45em;
        }
        h1 { font-size: 1.55em; }
        h2 { font-size: 1.28em; border-bottom: 1px solid var(--border); padding-bottom: .25em; }
        h3 { font-size: 1.12em; }
        p { margin: .65em 0; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        blockquote {
            border-left: 3px solid var(--border);
            color: var(--muted);
            margin: .8em 0;
            padding: .1em 0 .1em .9em;
        }
        code {
            background: var(--code);
            border-radius: 4px;
            font-family: "SF Mono", Menlo, monospace;
            font-size: .9em;
            padding: 2px 5px;
        }
        pre {
            background: var(--code);
            border-radius: 6px;
            overflow-x: auto;
            padding: 12px;
        }
        pre code { background: transparent; padding: 0; }
        img { max-width: 100%; border-radius: 6px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid var(--border); padding: 5px 7px; }
        .empty { color: var(--muted); }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    final class Coordinator {
        var lastHTML: String?
        var lastBaseURL: URL?
    }
}
