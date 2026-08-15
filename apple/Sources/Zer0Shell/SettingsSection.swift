import SwiftUI

/// The sections of the settings window.
///
/// Public so a command can open Settings *at* something: ⇧⌘, means Extensions,
/// not "Settings, wherever you left it".
///
/// **There is no History section and no Downloads section.** Both are pages at
/// addresses of their own now, and a pane holding a second copy of either would
/// be two screens for one thing — with no way to tell, from either one, which
/// of them was stale (ADR-0063).
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case tabs
    case spaces
    case airTraffic
    case shortcuts
    case extensions
    case chat
    case connections
    case privacy
    case updates

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .tabs: "Tabs"
        case .spaces: "Spaces"
        case .airTraffic: "Air Traffic"
        case .shortcuts: "Shortcuts"
        case .extensions: "Extensions"
        case .chat: "Chat"
        // Not "MCP". The protocol's name says nothing to anyone who has not
        // already read its specification, and the pane is about what the
        // assistant can reach — which is a thing anybody can picture.
        case .connections: "Connections"
        case .privacy: "Privacy"
        case .updates: "Updates"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .tabs: "rectangle.stack"
        case .spaces: "square.on.square"
        case .airTraffic: "arrow.triangle.branch"
        case .shortcuts: "keyboard"
        case .extensions: "puzzlepiece.extension"
        case .chat: "sparkles"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .privacy: "hand.raised"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}
