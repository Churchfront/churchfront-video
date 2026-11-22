import SwiftUI
import CueATEM

struct SmallButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    init(_ title: LocalizedStringKey, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            LabelText(title, size: 11).frame(maxWidth: .infinity).frame(height: 30)
                .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: T.rSM).stroke(T.lineStrong))
        }
        .buttonStyle(PressStyle())
    }
}

/// Drag anywhere in the circle; the camera moves faster the farther from the middle.
struct Joystick: View {
    let onMove: (Double, Double) -> Void
    let onEnd: () -> Void
    @State private var offset: CGSize = .zero

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            let knob: CGFloat = 54
            ZStack {
                Circle().fill(T.surfaceSunken).overlay(Circle().stroke(T.line))
                Circle().stroke(T.line, style: StrokeStyle(lineWidth: 1, dash: [3, 4])).padding(r * 0.45)
                ForEach(0..<4) { i in
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold)).foregroundStyle(T.inkSubtle)
                        .offset(y: -r + 14).rotationEffect(.degrees(Double(i) * 90))
                }
                Circle().fill(offset == .zero ? T.surfaceRaised : T.accent)
                    .overlay(Circle().stroke(Color.white.opacity(0.15)))
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    .frame(width: knob, height: knob)
                    .offset(offset)
            }
            .frame(width: r * 2, height: r * 2)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                var dx = v.location.x - r, dy = v.location.y - r
                let limit = r - knob / 2
                let d = sqrt(dx * dx + dy * dy)
                if d > limit { dx *= limit / d; dy *= limit / d }
                offset = CGSize(width: dx, height: dy)
                onMove(Double(dx / limit), Double(-dy / limit))
            }.onEnded { _ in
                withAnimation(.spring(duration: 0.2)) { offset = .zero }
                onEnd()
            })
        }
    }
}

/// Spring-loaded zoom: push up to zoom in, down to zoom out, let go to stop.
struct ZoomRocker: View {
    let onZoom: (Double) -> Void
    @State private var y: CGFloat = 0
    @State private var last = 0.0

    var body: some View {
        GeometryReader { g in
            let half = g.size.height / 2 - 22
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(T.surfaceSunken).overlay(RoundedRectangle(cornerRadius: 22).stroke(T.line))
                VStack {
                    Image(systemName: "plus.magnifyingglass")
                    Spacer()
                    Image(systemName: "minus.magnifyingglass")
                }
                .font(.system(size: 12)).foregroundStyle(T.inkSubtle).padding(.vertical, 10)
                Capsule().fill(y == 0 ? T.surfaceRaised : T.accent).frame(width: 36, height: 30)
                    .overlay(Capsule().stroke(Color.white.opacity(0.15))).offset(y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                y = min(half, max(-half, v.location.y - g.size.height / 2))
                let z = Double(-y / half)
                let q = (z * 7).rounded() / 7
                if q != last { last = q; onZoom(q) }
            }.onEnded { _ in
                withAnimation(.spring(duration: 0.2)) { y = 0 }
                last = 0
                onZoom(0)
            })
        }
    }
}
