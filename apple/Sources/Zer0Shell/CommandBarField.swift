import AppKit
import SwiftUI

/// The command bar's text field.
///
/// SwiftUI's `@FocusState` loses this fight: the `WKWebView` underneath is
/// already first responder, and asking politely in `onAppear` does not take it
/// away. So this drops to AppKit and takes the focus, which is the only
/// behaviour worth having. A text field you have to click into first is not a
/// text field, it is a chore.
///
/// The AppKit work sits in `buildField` and `sync` rather than directly in the
/// representable methods, because `Context` cannot be constructed in a test and
/// focus behaviour is exactly the kind of thing that needs one.
struct CommandBarField: NSViewRepresentable {
    @Binding var text: String
    /// The field is reused at different sizes: the command bar is a headline,
    /// the find bar is a 20pt strip. One fixed size cropped the smaller one.
    ///
    /// A point size rather than a `Design.Text` token because `NSTextField`
    /// takes an `NSFont`, so the whole of `Design.Text.FieldSize` exists for
    /// this one component. Both callers name their size there.
    var fontSize: CGFloat = Design.Text.FieldSize.command
    var placeholder: String = "Search or enter address"
    var onSubmit: () -> Void
    var onCancel: () -> Void
    /// +1 for down, -1 for up.
    var onMove: (Int) -> Void

    func makeNSView(context: Context) -> NSTextField {
        buildField(delegate: context.coordinator)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        sync(field, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onChange: { text = $0 },
            onSubmit: onSubmit,
            onCancel: onCancel,
            onMove: onMove
        )
    }

    // MARK: - The parts worth testing

    func buildField(delegate: NSTextFieldDelegate) -> NSTextField {
        let field = NSTextField()
        field.delegate = delegate
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.stringValue = text

        // The chrome comes from the surrounding SwiftUI material, not from
        // AppKit's default bezel.
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        return field
    }

    func sync(_ field: NSTextField, coordinator: Coordinator) {
        if field.stringValue != text {
            field.stringValue = text
        }
        guard !coordinator.hasTakenFocus else { return }
        coordinator.hasTakenFocus = true

        // A cycle later: at this point the view is in a window but not yet
        // able to become first responder.
        DispatchQueue.main.async {
            CommandBarField.takeFocus(of: field)
        }
    }

    /// Make `field` first responder and select everything in it.
    ///
    /// Selecting matters: ⌘L opens with the current URL already there, and
    /// typing should replace it the way every address bar behaves.
    static func takeFocus(of field: NSTextField) {
        guard let window = field.window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let onChange: (String) -> Void
        private let onSubmit: () -> Void
        private let onCancel: () -> Void
        private let onMove: (Int) -> Void
        var hasTakenFocus = false

        init(
            onChange: @escaping (String) -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onMove: @escaping (Int) -> Void
        ) {
            self.onChange = onChange
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onMove = onMove
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }

        func control(
            _: NSControl,
            textView _: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
            case #selector(NSResponder.moveDown(_:)):
                onMove(1)
            case #selector(NSResponder.moveUp(_:)):
                onMove(-1)
            default:
                // Everything else is ordinary typing and editing.
                return false
            }
            return true
        }
    }
}
