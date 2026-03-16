import Foundation

extension Bundle {
    /// Safe alternative to Bundle.module that returns nil instead of fatalError
    /// when the SPM resource bundle is not found at runtime.
    static var safeModule: Bundle? {
        let bundleName = "CalendarReminder_CalendarReminder"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
        ]
        for candidate in candidates {
            if let bundleURL = candidate?.appendingPathComponent(bundleName + ".bundle"),
               let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }
        return nil
    }
}
