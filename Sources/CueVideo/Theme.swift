import SwiftUI
import AppKit
import CoreText

/// Churchfront Signal tokens, dark (Midnight) theme, as in the other Cue apps.
enum T {
    static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: 1)
    }
    static let bg = hex(0x121212)
    static let surface = hex(0x1C1C1C)
    static let surfaceRaised = hex(0x2E2E2E)
    static let surfaceSunken = hex(0x0A0A0A)
    static let line = hex(0x333333)
    static let lineStrong = hex(0x6B6B6B)
    static let ink = hex(0xE6E7E8)
    static let inkMuted = hex(0xABABAB)
    static let inkSubtle = hex(0x8A8A8A)
    static let accent = hex(0xCAE7F9)
    static let accentStrong = hex(0x7CC2EE)
    static let onAction = hex(0x121212)
    static let success = hex(0x4FD8C4)
    static let warning = hex(0xF2B84B)
    static let danger = hex(0xFF6B5E)
    /// Tally: program red, preview green, as on every switcher panel.
    static let program = hex(0xEF4136)
    static let preview = hex(0x6CCB6A)

    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s5: CGFloat = 20, s6: CGFloat = 24
    static let rSM: CGFloat = 4, rMD: CGFloat = 6, rLG: CGFloat = 10
}

enum Fonts {
    static var figtreeLoaded = false
    static func register() {
        guard let url = Bundle.main.url(forResource: "Figtree-VariableFont_wght", withExtension: "ttf") else { return }
        var err: Unmanaged<CFError>?
        figtreeLoaded = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) || NSFont(name: "Figtree", size: 12) != nil
    }
}

extension Font {
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.figtreeLoaded ? .custom("Figtree", size: size).weight(weight) : .system(size: size, weight: weight)
    }
}

extension View {
    /// ALL CAPS panel label, tracked out.
    func panelLabel(_ color: Color = T.inkSubtle) -> some View {
        self.font(.sans(11, .bold)).tracking(1.4).textCase(.uppercase).foregroundStyle(color).lineLimit(1).fixedSize()
    }
}

/// A backlit panel button, like the keys on an ATEM control surface.
struct PanelButton: View {
    let title: String
    var subtitle: String? = nil
    var lit: Color? = nil
    var width: CGFloat = 76
    var height: CGFloat = 56
    var titleSize: CGFloat = 14
    var blink = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                let on = lit != nil && (!blink || Int(ctx.date.timeIntervalSinceReferenceDate / 0.4) % 2 == 0)
                VStack(spacing: 2) {
                    Text(title).font(.sans(titleSize, .bold)).lineLimit(1).minimumScaleFactor(0.6)
                    if let subtitle { Text(subtitle).font(.sans(9, .medium)).lineLimit(1).opacity(0.8) }
                }
                .padding(.horizontal, 4)
                .frame(width: width, height: height)
                .foregroundStyle(on ? T.onAction : T.inkMuted)
                .background(
                    RoundedRectangle(cornerRadius: T.rMD)
                        .fill(on ? (lit ?? T.surfaceRaised) : T.surfaceRaised)
                        .shadow(color: on ? (lit ?? .clear).opacity(0.55) : .clear, radius: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(on ? Color.white.opacity(0.25) : T.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).brightness(configuration.isPressed ? 0.08 : 0)
    }
}
