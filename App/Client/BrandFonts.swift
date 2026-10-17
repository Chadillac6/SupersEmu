import CoreText
import Foundation

enum BrandFonts {
    static func register() {
        guard let url = Bundle.main.url(forResource: "Silkscreen-Bold", withExtension: "ttf") else { return }
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
