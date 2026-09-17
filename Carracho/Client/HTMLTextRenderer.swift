import AppKit
import Foundation

/// Renders the small, presentation-oriented HTML subset used by Carracho chat,
/// news and user messages. MacRoman stays byte-for-byte Classic compatible while
/// tagged UTF-8 extends modern messages with emoji/Unicode. HTML is detected from
/// the decoded source and rendered locally without a WebView.
enum CarrachoHTMLText {
    private static let allowedTags: Set<String> = [
        "a", "b", "big", "blockquote", "br", "center", "code", "del", "div", "em",
        "font", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "ins", "li", "ol",
        "p", "pre", "s", "small", "span", "strike", "strong", "sub", "sup", "tt", "u", "ul"
    ]
    private static let voidTags: Set<String> = ["br", "hr"]
    private static let strippedBlockTags = [
        "script", "style", "iframe", "object", "embed", "svg", "math", "video", "audio",
        "canvas", "form", "template", "noscript"
    ]
    private static let strippedStandaloneTags = ["img", "input", "button", "select", "textarea", "meta", "link", "base", "source", "track"]

    static let editorHint = "Emoji + HTML supported: <b>, <i>, <u>, <a>, lists, blockquotes and code."

    static func string(fromWire data: Data) -> String {
        CarrachoTextWire.string(from: data)
    }

    static func attributedString(fromWire data: Data,
                                 baseFont: NSFont = .systemFont(ofSize: 13),
                                 textColor: NSColor = .labelColor) -> NSAttributedString {
        attributedString(from: string(fromWire: data), baseFont: baseFont, textColor: textColor)
    }

    static func attributedString(from source: String,
                                 baseFont: NSFont = .systemFont(ofSize: 13),
                                 textColor: NSColor = .labelColor) -> NSAttributedString {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard looksLikeHTML(normalized) else {
            return NSAttributedString(string: normalized, attributes: [
                .font: baseFont,
                .foregroundColor: textColor,
            ])
        }

        let safeBody = sanitize(normalized)
        let foreground = cssColor(textColor)
        let link = cssColor(NSColor.linkColor)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body { margin:0; padding:0; font-family:-apple-system,BlinkMacSystemFont,sans-serif; font-size:\(baseFont.pointSize)px; color:\(foreground); white-space:pre-wrap; }
        p { margin:0 0 0.55em 0; } blockquote { margin:0.35em 0 0.35em 1.2em; }
        pre,code,tt { font-family:Menlo,monospace; } a { color:\(link); }
        </style></head><body>\(safeBody)</body></html>
        """
        guard let data = html.data(using: .utf8),
              let value = try? NSAttributedString(data: data,
                                                  options: [
                                                    .documentType: NSAttributedString.DocumentType.html,
                                                    .characterEncoding: String.Encoding.utf8.rawValue,
                                                  ],
                                                  documentAttributes: nil) else {
            return NSAttributedString(string: normalized, attributes: [
                .font: baseFont,
                .foregroundColor: textColor,
            ])
        }
        return value
    }

    static func plainText(fromWire data: Data) -> String {
        attributedString(fromWire: data).string
    }

    static func looksLikeHTML(_ source: String) -> Bool {
        let tagPattern = #"(?is)<\s*/?\s*(a|b|big|blockquote|br|center|code|del|div|em|font|h[1-6]|hr|i|ins|li|ol|p|pre|s|small|span|strike|strong|sub|sup|tt|u|ul)\b[^>]*>"#
        if source.range(of: tagPattern, options: .regularExpression) != nil { return true }
        let entityPattern = #"(?i)&(?:amp|lt|gt|quot|apos|nbsp|#\d{1,7}|#x[0-9a-f]{1,6});"#
        return source.range(of: entityPattern, options: .regularExpression) != nil
    }

    private static func sanitize(_ input: String) -> String {
        var value = input
        value = replaceRegex(#"(?is)<!--.*?-->"#, in: value, with: "")
        value = replaceRegex(#"(?is)<!DOCTYPE\b[^>]*>"#, in: value, with: "")

        for tag in strippedBlockTags {
            let escaped = NSRegularExpression.escapedPattern(for: tag)
            value = replaceRegex("(?is)<\\s*\(escaped)\\b[^>]*>.*?<\\s*/\\s*\(escaped)\\s*>", in: value, with: "")
        }
        let standalone = strippedStandaloneTags.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        value = replaceRegex("(?is)<\\s*/?\\s*(?:\(standalone))\\b[^>]*>", in: value, with: "")

        guard let tagRegex = try? NSRegularExpression(pattern: #"(?is)<\s*(/?)\s*([a-z][a-z0-9]*)\b([^>]*)>"#) else { return value }
        let ns = value as NSString
        let matches = tagRegex.matches(in: value, range: NSRange(location: 0, length: ns.length))
        var result = value
        for match in matches.reversed() {
            guard match.numberOfRanges == 4,
                  let whole = Range(match.range(at: 0), in: value),
                  let closingRange = Range(match.range(at: 1), in: value),
                  let nameRange = Range(match.range(at: 2), in: value),
                  let attrsRange = Range(match.range(at: 3), in: value) else { continue }
            let closing = !value[closingRange].isEmpty
            let name = value[nameRange].lowercased()
            let attrs = String(value[attrsRange])
            let replacement: String
            if !allowedTags.contains(name) {
                replacement = ""
            } else if closing {
                replacement = voidTags.contains(name) ? "" : "</\(name)>"
            } else if name == "a" {
                if let href = attribute("href", in: attrs), isAllowedLink(href) {
                    replacement = "<a href=\"\(escapeAttribute(href))\">"
                } else {
                    replacement = "<a>"
                }
            } else if name == "font" {
                replacement = sanitizedFontTag(attrs)
            } else if let style = sanitizedStyle(in: attrs) {
                replacement = "<\(name) style=\"\(escapeAttribute(style))\">"
            } else {
                replacement = "<\(name)>"
            }
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }

    private static func sanitizedStyle(in attrs: String) -> String? {
        guard let raw = attribute("style", in: attrs) else { return nil }
        var declarations: [String] = []
        for component in raw.split(separator: ";") {
            let pair = component.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2 else { continue }
            let property = pair[0].lowercased()
            let value = pair[1]
            let accepted: Bool
            switch property {
            case "color", "background-color":
                accepted = value.range(of: #"^(?:#[0-9a-fA-F]{3,8}|[a-zA-Z]{1,24}|rgb\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*\))$"#, options: .regularExpression) != nil
            case "font-weight":
                accepted = value.range(of: #"^(?:normal|bold|[1-9]00)$"#, options: [.regularExpression, .caseInsensitive]) != nil
            case "font-style":
                accepted = value.range(of: #"^(?:normal|italic|oblique)$"#, options: [.regularExpression, .caseInsensitive]) != nil
            case "text-decoration":
                accepted = value.range(of: #"^(?:none|underline|line-through|underline\s+line-through|line-through\s+underline)$"#, options: [.regularExpression, .caseInsensitive]) != nil
            case "text-align":
                accepted = value.range(of: #"^(?:left|right|center|justify)$"#, options: [.regularExpression, .caseInsensitive]) != nil
            case "font-size":
                accepted = value.range(of: #"^(?:\d{1,3}(?:px|pt|%)|\d(?:\.\d{1,2})?em)$"#, options: [.regularExpression, .caseInsensitive]) != nil
            case "font-family":
                accepted = value.range(of: #"^[a-zA-Z0-9 ,._+\-]{1,100}$"#, options: .regularExpression) != nil
            default:
                accepted = false
            }
            if accepted { declarations.append("\(property):\(value)") }
        }
        return declarations.isEmpty ? nil : declarations.joined(separator: ";")
    }

    private static func sanitizedFontTag(_ attrs: String) -> String {
        var output: [String] = []
        if let color = attribute("color", in: attrs),
           color.range(of: #"^(?:#[0-9a-fA-F]{3,8}|[a-zA-Z]{1,24})$"#, options: .regularExpression) != nil {
            output.append("color=\"\(escapeAttribute(color))\"")
        }
        if let face = attribute("face", in: attrs),
           face.range(of: #"^[a-zA-Z0-9 ._+\-]{1,80}$"#, options: .regularExpression) != nil {
            output.append("face=\"\(escapeAttribute(face))\"")
        }
        if let size = attribute("size", in: attrs),
           size.range(of: #"^(?:[1-7]|[+-][1-7])$"#, options: .regularExpression) != nil {
            output.append("size=\"\(escapeAttribute(size))\"")
        }
        return output.isEmpty ? "<font>" : "<font \(output.joined(separator: " "))>"
    }

    private static func attribute(_ name: String, in source: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?is)\\b\(escaped)\\s*=\\s*(?:\\\"([^\\\"]*)\\\"|'([^']*)'|([^\\s\\\"'=<>`]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = source as NSString
        guard let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return ns.substring(with: match.range(at: index))
        }
        return nil
    }

    private static func isAllowedLink(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func replaceRegex(_ pattern: String, in source: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(location: 0, length: (source as NSString).length)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: replacement)
    }

    private static func cssColor(_ color: NSColor) -> String {
        let converted = color.usingColorSpace(.deviceRGB) ?? NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .black
        let r = max(0, min(255, Int((converted.redComponent * 255).rounded())))
        let g = max(0, min(255, Int((converted.greenComponent * 255).rounded())))
        let b = max(0, min(255, Int((converted.blueComponent * 255).rounded())))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
