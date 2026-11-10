import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CueATEM

/// Still pictures from the Canon cameras, measured for color, so Claude can compare them.
enum Snapshots {
    struct Result {
        var info: [String: Any]
        var image: [String: Any]?
    }

    static func take(_ cams: [PTZCamera], pictures: Bool, done: @escaping ([Result]) -> Void) {
        var results = [Result?](repeating: nil, count: cams.count)
        let group = DispatchGroup()
        for (i, c) in cams.enumerated() {
            group.enter()
            let port = c.port == 80 ? "" : ":\(c.port)"
            guard let url = URL(string: "http://\(c.host)\(port)/-wvhttp-01-/image.cgi") else { group.leave(); continue }
            var r = URLRequest(url: url, timeoutInterval: 5)
            r.cachePolicy = .reloadIgnoringLocalCacheData
            URLSession.shared.dataTask(with: r) { data, _, _ in
                defer { group.leave() }
                guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    results[i] = Result(info: ["camera": c.name, "error": "No picture from \(c.name)."]); return
                }
                var info = measure(img)
                info["camera"] = c.name
                var image: [String: Any]?
                if pictures, let small = jpeg(img, width: 640) {
                    image = ["label": c.name, "mimeType": "image/jpeg", "data": small.base64EncodedString()]
                }
                results[i] = Result(info: info, image: image)
            }.resume()
        }
        group.notify(queue: .main) { done(results.compactMap { $0 }) }
    }

    /// Averages over a 160×90 copy: color, cast, brightness, clipping.
    static func measure(_ img: CGImage) -> [String: Any] {
        let w = 160, h = 90
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [:] }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0, clipped = 0, crushed = 0
        var nr = 0.0, ng = 0.0, nb = 0.0, nn = 0.0  // mid-tones only, for the color cast
        for i in stride(from: 0, to: px.count, by: 4) {
            let R = Double(px[i]), G = Double(px[i + 1]), B = Double(px[i + 2])
            r += R; g += G; b += B
            let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
            if y > 250 { clipped += 1 } else if y < 8 { crushed += 1 }
            if y > 40, y < 220 { nr += R; ng += G; nb += B; nn += 1 }
        }
        let n = Double(w * h)
        func r2(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", v)) }
        var d: [String: Any] = [
            "average_rgb": [Int(r / n), Int(g / n), Int(b / n)],
            "brightness": Int((0.2126 * r + 0.7152 * g + 0.0722 * b) / n),
            "clipped_percent": r2(Double(clipped) / n * 100),
            "crushed_percent": r2(Double(crushed) / n * 100),
        ]
        if nn > 50, ng > 0 {
            let rg = nr / ng, bg = nb / ng
            d["red_over_green"] = r2(rg)
            d["blue_over_green"] = r2(bg)
            d["cast"] = rg - bg > 0.06 ? "warm (orange)" : (bg - rg > 0.06 ? "cool (blue)" : "neutral")
        }
        return d
    }

    static func jpeg(_ img: CGImage, width: Int) -> Data? {
        let h = Int(Double(width) * Double(img.height) / Double(max(1, img.width)))
        guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
