import Foundation

enum L10n {
    static let supportedLocalizations = ["cs", "en", "de", "fr", "es", "it", "pl", "sk", "pt-BR"]

    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: arguments)
    }
}
