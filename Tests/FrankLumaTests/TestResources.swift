import Foundation

private final class TestBundleMarker {}
enum TestResources {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: TestBundleMarker.self)
        #endif
    }
}
