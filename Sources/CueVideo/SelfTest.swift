import AppKit
import CueATEM

/// CUEVIDEO_SELFTEST=1 with CUEVIDEO_HOST pointed at a switcher (or Tools/fake_atem.py):
/// waits for the switcher, runs every command, prints the state after each,
/// writes window snapshots to CUEVIDEO_SNAPSHOT (a folder), and quits.
/// Never point it at a switcher that is live on a service.
enum SelfTest {
    static func run() {
        let booth = Booth.shared
        let atem = booth.atem
        let ptz = booth.ptz
        let out = ProcessInfo.processInfo.environment["CUEVIDEO_SNAPSHOT"]
        func log(_ s: String) { print("SELFTEST", s); fflush(stdout) }
        func summary() -> String {
            let s = atem.state
            return "pgm=\(s.name(s.program[0])) pvw=\(s.name(s.preview[0])) trans=\(s.inTransition[0] ?? false) style=\(s.style[0] ?? -1) next=\(s.nextSelection[0] ?? -1) key1=\(s.keyOnAir[0]?[0] ?? false) dsk1=\(s.dskOnAir[0] ?? false) tie1=\(s.dskTie[0] ?? false) ftb=\(s.ftbBlack[0] ?? false) aux1=\(s.name(s.aux[0])) macro=\(s.macroRunning.map(String.init) ?? "-") stream=\(s.streamStatus) rec=\(s.recordStatus) rate=\(s.mixRate[0] ?? -1) tbarTop=\(atem.tbarAtTop[0] ?? false)"
        }
        func snap(_ name: String) {
            guard let out, let v = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent(name + ".png"))
            log("snapshot \(name).png")
        }
        let steps: [(String, Double, () -> Void)] = [
            ("connected", 0, {}),
            ("preview 3", 0.5, { atem.setPreview(3) }),
            ("cut", 0.5, { atem.cut() }),
            ("preview 4", 0.5, { atem.setPreview(4) }),
            ("auto", 1.6, { atem.auto() }),
            ("style dip", 0.4, { atem.setStyle(1) }),
            ("next bkgd+key1", 0.4, { atem.setNextSelection(3) }),
            ("mix rate 45", 0.4, { atem.setMixRate(45) }),
            ("key 1 on", 0.4, { atem.setKeyOnAir(0, true) }),
            ("dsk 1 tie", 0.4, { atem.setDSKTie(0, true) }),
            ("dsk 1 auto", 1.2, { atem.dskAuto(0) }),
            ("aux 1 cam 1", 0.4, { atem.setAux(0, 1) }),
            ("macro 1", 0.3, { atem.runMacro(0) }),
            ("stream on", 1.5, { atem.setStreaming(true) }),
            ("record on", 0.4, { atem.setRecording(true) }),
            ("tbar half", 0.4, { atem.setPosition(0.5) }),
            ("tbar full", 0.6, { atem.setPosition(1.0) }),
            ("ptz drive", 0.3, { ptz.drive(x: 0.5, y: 0.5) }),
            ("ptz stop", 0.3, { ptz.stopDrive() }),
            ("ptz zoom in", 0.3, { ptz.zoom(1) }),
            ("ptz zoom stop", 0.3, { ptz.zoom(0) }),
            ("ptz recall 2", 0.3, { ptz.recall(2) }),
            ("ptz store 3", 0.3, { ptz.store(3) }),
            ("follow preview cam 2", 0.5, { atem.setPreview(2) }),
        ]
        func wait() {
            if atem.link == .online && !atem.state.inputs.isEmpty {
                log("online: \(atem.state.product), \(atem.state.inputs.count) inputs, \(atem.state.macros.count) macros")
                snap("full")
                step(0)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: wait)
            }
        }
        func step(_ i: Int) {
            guard i < steps.count else {
                log("selected camera: \(ptz.current?.name ?? "none")")
                snap("full-after")
                booth.simple = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    snap("simple")
                    booth.simple = false
                    log("done")
                    exit(0)
                }
                return
            }
            let (name, delay, action) = steps[i]
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, delay)) {
                log("\(name): \(summary())")
                step(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: wait)
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { log("timed out: \(atem.link)"); exit(1) }
    }
}
