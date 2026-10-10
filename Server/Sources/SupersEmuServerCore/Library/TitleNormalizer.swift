import Foundation

/// Server copy of the app's `TitleNormalizer` (App/GameLibrary.swift). Keep the rules in sync.
public enum TitleNormalizer {
    /// "Super_Game (USA) [!].sfc" -> "Super Game", "HelloWorld.sfc" -> "Hello World"
    public static func title(fromFilename filename: String) -> String {
        var title = (filename as NSString).deletingPathExtension
        title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "_", with: " ")
        title = title.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? filename : title
    }
}
