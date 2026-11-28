import SwiftUI

/// An on/off switch that stays `Status.running` green when on in every window state. The system switch greys out in a
/// window that is not key (as a prominent button does, see `ControlButtonStyle`), which would break Start-is-green.
struct TintedSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let size = Control.switchSize
        let knob = size.height - Space.xxs
        Capsule()
            .fill(configuration.isOn ? AnyShapeStyle(Status.running) : AnyShapeStyle(Color.secondary.opacity(0.3)))
            .overlay(Capsule().strokeBorder(.primary.opacity(scheme.controlLine), lineWidth: Control.hairline))
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(Space.xxs / 2)
            }
            .frame(width: size.width, height: size.height)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            .motion(Motion.snappy, value: configuration.isOn)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == TintedSwitchStyle {
    static var tintedSwitch: TintedSwitchStyle { TintedSwitchStyle() }
}
