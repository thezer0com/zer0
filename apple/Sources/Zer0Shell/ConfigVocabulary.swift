import Foundation
import Zer0Core

/// The spellings the config file uses, read from the core rather than repeated
/// here.
///
/// A uniffi enum arrives in Swift without its methods, so `as_wire` does not
/// cross the FFI on the type. These put the method spelling back without
/// putting the *mapping* back: every one of them is one call into the core, so
/// the settings picker and the file parser cannot drift apart over what
/// `openai-compatible` is called.
extension ProviderKind {
    func asWire() -> String { providerKindWire(kind: self) }

    /// Whether an entry of this kind is unusable without a `base_url`, so the
    /// field can be marked required rather than letting somebody save something
    /// the parser will drop.
    var needsBaseUrl: Bool { providerKindNeedsBaseUrl(kind: self) }

    /// In the order a picker should offer them.
    static var allKinds: [ProviderKind] { providerKinds() }
}

extension TransportKind {
    func asWire() -> String { transportKindWire(transport: self) }

    static var allTransports: [TransportKind] { transportKinds() }
}
