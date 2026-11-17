import Foundation

private final class BundleToken {}

/// Looks a user-facing string up in the framework's own String Catalog.
func coreString(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: Bundle(for: BundleToken.self))
}
