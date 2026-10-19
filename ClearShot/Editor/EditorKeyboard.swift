import AppKit

/// Routed at the window boundary so a toolbar button or scroll view cannot swallow tools.
@MainActor
enum EditorKeyboard {
    static func handle(_ event: NSEvent, model: EditorModel, actions: EditorActions, isEditingText: Bool) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.control), !modifiers.contains(.option) else { return false }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if modifiers.contains(.command) {
            // Save commits an inline text edit. Other editing commands belong to the field editor.
            if key == "s" { actions.save(); return true }
            guard !isEditingText else { return false }
            switch key {
            case "c": actions.copy()
            case "z": modifiers.contains(.shift) ? model.redo() : model.undo()
            case "0": model.fitsWindow = true
            case "1": setZoom(1 / model.pointScale, model: model)
            case "=", "+": setZoom(model.zoom * 1.25, model: model)
            case "-": setZoom(model.zoom / 1.25, model: model)
            default: return false
            }
            return true
        }
        guard !isEditingText else { return false }
        switch event.keyCode {
        case 51, 117: model.deleteSelection()
        case 53:
            if model.tool == .crop { model.cancelCrop() } else { model.selection = nil }
        case 36, 76:
            if model.tool == .crop { model.applyCrop() }
            else if let selected = model.selectedAnnotation, selected.kind == .text { model.editingTextID = selected.id }
            else { return false }
        default:
            if key.count == 1, let tool = EditorTool.allCases.first(where: { String($0.key) == key }) {
                model.select(tool: tool)
            } else if let digit = Int(key), (1...8).contains(digit) {
                model.applyColor(RGBA.palette[digit - 1].color)
            } else { return false }
        }
        return true
    }

    private static func setZoom(_ value: CGFloat, model: EditorModel) {
        model.fitsWindow = false
        model.zoom = min(max(value, 0.05), 8)
    }
}
