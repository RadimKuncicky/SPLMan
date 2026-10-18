import Foundation

enum LocalizationValidation {
    static func run() -> [String] {
        var failures: [String] = []
        let expected = Set(L10n.supportedLocalizations)
        let available = Set(Bundle.module.localizations)
        let missing = expected.subtracting(available)
        if !missing.isEmpty {
            failures.append("Missing localizations: \(missing.sorted().joined(separator: ", "))")
        }
        for localization in L10n.supportedLocalizations {
            let preferred = Bundle.preferredLocalizations(
                from: L10n.supportedLocalizations,
                forPreferences: [localization]
            ).first
            if preferred != localization {
                failures.append("System preference \(localization) selected \(preferred ?? "none")")
            }
        }
        let unsupported = Bundle.preferredLocalizations(
            from: L10n.supportedLocalizations,
            forPreferences: ["ja"]
        ).first
        if unsupported != "en" {
            failures.append("Unsupported language did not fall back to English")
        }
        if !L10n.format("VÝPADKY OD SPUŠTĚNÍ ×%d", Int32(12)).contains("12") {
            failures.append("Localized integer formatting failed")
        }

        guard let english = strings(for: "en") else {
            failures.append("English Localizable.strings could not be loaded")
            return failures
        }

        for localization in L10n.supportedLocalizations {
            guard let localized = strings(for: localization) else {
                failures.append("\(localization) Localizable.strings could not be loaded")
                continue
            }
            guard let info = stringsFile(named: "InfoPlist", for: localization),
                  !(info["NSMicrophoneUsageDescription"] ?? "").isEmpty else {
                failures.append("\(localization) microphone permission text could not be loaded")
                continue
            }
            let missingKeys = Set(english.keys).subtracting(localized.keys)
            let extraKeys = Set(localized.keys).subtracting(english.keys)
            if !missingKeys.isEmpty {
                failures.append("\(localization) is missing \(missingKeys.count) localization keys")
            }
            if !extraKeys.isEmpty {
                failures.append("\(localization) has \(extraKeys.count) unexpected localization keys")
            }
            for key in Set(english.keys).intersection(localized.keys)
            where formatTokens(in: english[key] ?? "") != formatTokens(in: localized[key] ?? "") {
                failures.append("\(localization) has incompatible format arguments for key: \(key)")
            }
        }
        return failures
    }

    private static func strings(for localization: String) -> [String: String]? {
        stringsFile(named: "Localizable", for: localization)
    }

    private static func stringsFile(named name: String, for localization: String) -> [String: String]? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "strings",
            subdirectory: nil,
            localization: localization
        ), let data = try? Data(contentsOf: url),
        let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let strings = object as? [String: String] else { return nil }
        return strings
    }

    private static func formatTokens(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?[+\-0-9.]*[a-zA-Z@]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    static func printRuntimeProbe() {
        print("main=\(Bundle.main.preferredLocalizations.first ?? "none")")
        print("module=\(Bundle.module.preferredLocalizations.first ?? "none")")
        print("settings=\(L10n.text("Nastavení"))")
        let microphone = Bundle.main.object(
            forInfoDictionaryKey: "NSMicrophoneUsageDescription"
        ) as? String ?? "none"
        print("microphone=\(microphone)")
    }
}
