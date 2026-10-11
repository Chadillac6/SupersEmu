import Foundation

public enum TitleNormalizer {
    private static let hashPrefix = #"^[0-9a-fA-F]{16,64}--"#

    /// "Super_Game (USA) [!].sfc" -> "Super Game", "HelloWorld.sfc" -> "Hello World"
    public static func title(fromFilename filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        let hasHashPrefix = Self.hasHashPrefix(stem)
        var title = Self.strippingHashPrefix(stem)
        title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "_", with: " ")
        title = title.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? (hasHashPrefix ? "" : filename) : title
    }

    public static func strippingHashPrefix(_ s: String) -> String {
        s.replacingOccurrences(of: hashPrefix, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func hasHashPrefix(_ title: String) -> Bool {
        title.range(of: hashPrefix, options: .regularExpression) != nil
    }
}
