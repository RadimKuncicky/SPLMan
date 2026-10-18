import AppKit
import Darwin

if CommandLine.arguments.contains("--localization-probe") {
    LocalizationValidation.printRuntimeProbe()
} else if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run() ? EXIT_SUCCESS : EXIT_FAILURE)
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
