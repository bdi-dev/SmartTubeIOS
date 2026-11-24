import Foundation

// MARK: - FriendlyFileName

/// Turns a video title into a safe, readable file name for exporting a download
/// ("Open Ocean: 10 Hours | BBC Earth" -> "Open Ocean 10 Hours BBC Earth.mp4").
public enum FriendlyFileName {
    /// Characters that are illegal or troublesome in file names on iOS, macOS, Windows or in URLs.
    private static let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\0"]
    public static let maxBaseLength = 100

    /// - Parameters:
    ///   - title: the video title.
    ///   - videoId: used as a fallback when the title has no usable characters.
    ///   - fileExtension: without the dot, e.g. `"mp4"` or `"m4a"`.
    public static func make(title: String, videoId: String, fileExtension: String) -> String {
        let cleaned = title.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !forbidden.contains(Character($0)) }
            .map(Character.init)
        var base = String(cleaned)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if base.count > maxBaseLength {
            base = String(base.prefix(maxBaseLength)).trimmingCharacters(in: .whitespaces)
        }
        if base.isEmpty { base = videoId }
        return "\(base).\(fileExtension)"
    }
}
