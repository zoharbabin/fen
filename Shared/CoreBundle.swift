import Foundation

/// The resource bundle for the FenCore target.
///
/// SPM generates a Bundle.module accessor that resolves against
/// Bundle.main.bundleURL (the .app root). For signed .app bundles,
/// nested resource bundles must live in Contents/Resources/, which is
/// Bundle.main.resourceURL. This resolver checks resourceURL first so
/// distributed builds find Fen_FenCore.bundle correctly, then
/// falls back to Bundle.module (which covers local .build/ dev builds
/// via its hardcoded path fallback).
let coreBundle: Bundle = {
    let name = "Fen_FenCore.bundle"
    let resourceBase = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    if let resolved = Bundle(url: resourceBase.appendingPathComponent(name)) {
        return resolved
    }
    return Bundle.module
}()
