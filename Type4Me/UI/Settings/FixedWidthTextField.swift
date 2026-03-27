import SwiftUI
import AppKit

// Shared styling constants matching TF design system.
private enum SettingsFieldStyle {
    static let bgColor = NSColor(red: 0.95, green: 0.92, blue: 0.88, alpha: 1)
    static let textColor = NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    static let placeholderColor = NSColor(red: 0.42, green: 0.42, blue: 0.42, alpha: 1)
    static let cursorColor = NSColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1)
    static let borderColor = NSColor(red: 0.42, green: 0.42, blue: 0.42, alpha: 0.2)
    static let padding = NSSize(width: 8, height: 0)

    static func applyCommon(to field: NSTextField, placeholder: String) {
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = bgColor
        field.textColor = textColor
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.layer?.borderWidth = 1
        field.layer?.borderColor = borderColor.cgColor

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: placeholderColor,
                .font: NSFont.systemFont(ofSize: 12),
                .paragraphStyle: style,
            ]
        )

        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Cell-level settings
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byTruncatingTail
    }
}

// MARK: - Padded Cell Subclasses

/// Adds horizontal padding and vertically centers text.
private class PaddedTextFieldCell: NSTextFieldCell {
    private func paddedRect(_ rect: NSRect) -> NSRect {
        let textHeight = super.drawingRect(forBounds: rect).height
        let y = max(0, (rect.height - textHeight) / 2 + 7)
        return NSRect(x: rect.origin.x + 8, y: rect.origin.y + y,
                      width: rect.width - 16, height: textHeight)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { paddedRect(rect) }
    override func titleRect(forBounds rect: NSRect) -> NSRect { paddedRect(rect) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: paddedRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: paddedRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// Same padding for secure text fields.
private class PaddedSecureTextFieldCell: NSSecureTextFieldCell {
    private func paddedRect(_ rect: NSRect) -> NSRect {
        let textHeight = super.drawingRect(forBounds: rect).height
        let y = max(0, (rect.height - textHeight) / 2 + 7)
        return NSRect(x: rect.origin.x + 8, y: rect.origin.y + y,
                      width: rect.width - 16, height: textHeight)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { paddedRect(rect) }
    override func titleRect(forBounds rect: NSRect) -> NSRect { paddedRect(rect) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: paddedRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: paddedRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

// MARK: - NSTextField Subclasses

/// NSTextField that uses PaddedTextFieldCell and custom cursor color.
/// Overrides intrinsicContentSize so SwiftUI respects the desired height.
private class SettingsNSTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { PaddedTextFieldCell.self }
        set { }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = SettingsFieldStyle.cursorColor
        }
        return result
    }
}

/// NSSecureTextField that uses PaddedSecureTextFieldCell and custom cursor color.
private class SettingsNSSecureTextField: NSSecureTextField {
    override class var cellClass: AnyClass? {
        get { PaddedSecureTextFieldCell.self }
        set { }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = SettingsFieldStyle.cursorColor
        }
        return result
    }
}

// MARK: - SwiftUI Wrappers

/// A single-line NSTextField wrapper that never expands its parent layout.
struct FixedWidthTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let field = SettingsNSTextField()
        SettingsFieldStyle.applyCommon(to: field, placeholder: placeholder)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// A single-line NSSecureTextField wrapper that never expands its parent layout.
struct FixedWidthSecureField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = SettingsNSSecureTextField()
        SettingsFieldStyle.applyCommon(to: field, placeholder: placeholder)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
