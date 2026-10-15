import AppKit
import SwiftUI

// MARK: - Button

enum ShadVariant {
    case primary, secondary, outline, ghost, destructive, link
}

enum ShadSize {
    case sm, md, lg, icon, iconSm

    var height: CGFloat {
        switch self {
        case .sm: 28
        case .md: 32
        case .lg: 38
        case .icon: 32
        case .iconSm: 26
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .sm: 10
        case .md: 12
        case .lg: 16
        case .icon, .iconSm: 0
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .sm, .iconSm: 12
        case .md, .icon: 13
        case .lg: 14
        }
    }

    var isIcon: Bool { self == .icon || self == .iconSm }
}

struct ShadButtonStyle: ButtonStyle {
    var variant: ShadVariant = .primary
    var size: ShadSize = .md
    var fullWidth = false
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        ShadButtonBody(configuration: configuration, variant: variant, size: size, fullWidth: fullWidth, isActive: isActive)
    }
}

private struct ShadButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: ShadVariant
    let size: ShadSize
    let fullWidth: Bool
    let isActive: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.jakarta(size.fontSize, .medium))
            .labelStyle(ShadLabelStyle())
            .lineLimit(1)
            .padding(.horizontal, size.horizontalPadding)
            .frame(width: size.isIcon ? size.height : nil, height: size.height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(variant == .outline ? Theme.input : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && variant != .link ? 0.97 : 1)
            .onHover { hovering = $0 && isEnabled }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .primary: Theme.primaryForeground
        case .secondary: Theme.secondaryForeground
        case .outline, .ghost: isActive ? Theme.foreground : (hovering ? Theme.accentForeground : Theme.foreground)
        case .destructive: .white
        case .link: hovering ? Theme.foreground : Theme.mutedForeground
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch variant {
        case .primary: return Theme.primary.opacity(pressed ? 0.82 : hovering ? 0.9 : 1)
        case .secondary: return pressed ? Theme.accent : hovering ? Theme.accent.opacity(0.85) : Theme.secondary
        case .outline: return isActive || hovering || pressed ? Theme.accent : Theme.background.opacity(0.001)
        case .ghost: return isActive ? Theme.accent : (hovering || pressed ? Theme.accent : .clear)
        case .destructive: return Theme.destructive.opacity(pressed ? 0.82 : hovering ? 0.9 : 1)
        case .link: return .clear
        }
    }
}

private struct ShadLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == ShadButtonStyle {
    static func shad(_ variant: ShadVariant = .primary, size: ShadSize = .md, fullWidth: Bool = false, active: Bool = false) -> ShadButtonStyle {
        ShadButtonStyle(variant: variant, size: size, fullWidth: fullWidth, isActive: active)
    }
}

/// Icon-only ghost button with a tooltip.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: ShadSize = .icon
    var variant: ShadVariant = .ghost
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size == .iconSm ? 12 : 14, weight: .medium))
        }
        .buttonStyle(.shad(variant, size: size, active: active))
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Switch

struct ShadSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShadSwitchBody(configuration: configuration)
    }
}

private struct ShadSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: Space.md) {
            configuration.label
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.primary : Theme.input)
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(Theme.background)
                    .frame(width: 14, height: 14)
                    .shadowSm()
                    .padding(2)
            }
            .onTapGesture { configuration.isOn.toggle() }
            .animation(Motion.quick, value: configuration.isOn)
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

extension ToggleStyle where Self == ShadSwitchStyle {
    static var shad: ShadSwitchStyle { ShadSwitchStyle() }
}

/// Checkbox in shadcn style.
struct ShadCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: Space.sm) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isOn ? Theme.primary : Theme.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(configuration.isOn ? Theme.primary : Theme.input, lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.primaryForeground)
                            .opacity(configuration.isOn ? 1 : 0)
                    )
                    .frame(width: 16, height: 16)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.quick, value: configuration.isOn)
    }
}

extension ToggleStyle where Self == ShadCheckboxStyle {
    static var shadCheckbox: ShadCheckboxStyle { ShadCheckboxStyle() }
}

// MARK: - Input

struct ShadTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String?
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.mutedForeground)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.jakarta(13))
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Theme.background))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(focused ? Theme.brand : Theme.input, lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: Radius.md + 3, style: .continuous)
                .stroke(Theme.ring, lineWidth: 3)
                .padding(-1.5)
                .opacity(focused ? 1 : 0)
        )
        .animation(Motion.quick, value: focused)
    }
}

// MARK: - Card, Badge, Kbd, Separator

struct ShadCard<Content: View>: View {
    var padding: CGFloat = Space.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .shadowSm()
    }
}

struct ShadBadge: View {
    enum Variant { case secondary, outline, brand }
    let text: String
    var variant: Variant = .secondary

    var body: some View {
        Text(text)
            .font(.jakarta(11, .semibold))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .foregroundStyle(variant == .brand ? Color.white : Theme.foreground)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(variant == .outline ? Theme.border : .clear, lineWidth: 1))
    }

    private var fill: Color {
        switch variant {
        case .secondary: Theme.secondary
        case .outline: .clear
        case .brand: Theme.brand
        }
    }
}

struct Kbd: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.jakarta(11, .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.mutedForeground)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.muted))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

struct ShadSeparator: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

// MARK: - Tabs (segmented)

struct ShadTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var fullWidth = false

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(Motion.snappy) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.jakarta(12, .medium))
                        .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .frame(maxWidth: fullWidth ? .infinity : nil)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                    .fill(Theme.background)
                                    .shadowSm()
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Theme.muted))
    }
}

// MARK: - Select (shadcn trigger + native menu)

struct ShadSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var width: CGFloat = 180

    @State private var anchor = MenuAnchor()

    var body: some View {
        Button(action: showMenu) {
            HStack {
                Text(options.first { $0.value == selection }?.label ?? "")
                    .font(.jakarta(13))
                    .foregroundStyle(Theme.foreground)
                Spacer(minLength: Space.sm)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.mutedForeground)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Theme.input, lineWidth: 1))
            .shadowSm()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        var selectedItem: NSMenuItem?
        for option in options {
            let item = ClosureMenuItem(title: option.label) { selection = option.value }
            item.state = option.value == selection ? .on : .off
            if option.value == selection { selectedItem = item }
            menu.addItem(item)
        }
        menu.font = Jakarta.nsFont(13)
        menu.minimumWidth = width
        menu.popUp(positioning: selectedItem, at: NSPoint(x: 0, y: view.bounds.height - 4), in: view)
    }
}

@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}

// MARK: - Slider

struct ShadSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1

    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = CGFloat(fraction) * (width - 16) + 8
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.muted).frame(height: 6)
                Capsule().fill(Theme.primary).frame(width: x, height: 6)
                Circle()
                    .fill(Theme.background)
                    .overlay(Circle().strokeBorder(Theme.primary, lineWidth: 1.5))
                    .frame(width: 16, height: 16)
                    .shadowSm()
                    .scaleEffect(dragging ? 1.12 : 1)
                    .offset(x: x - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        let f = min(max((gesture.location.x - 8) / (width - 16), 0), 1)
                        let raw = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        value = (raw / step).rounded() * step
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(Motion.quick, value: dragging)
        }
        .frame(height: 20)
    }
}

// MARK: - Field row helpers

/// Settings row: label + description on the left, control on the right.
struct FieldRow<Control: View>: View {
    let title: String
    var description: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.label)
                    .foregroundStyle(Theme.foreground)
                if let description {
                    Text(description)
                        .textStyle(.footnote)
                        .foregroundStyle(Theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control.fixedSize()
        }
        .padding(.vertical, Space.md)
    }
}
