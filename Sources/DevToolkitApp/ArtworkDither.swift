import Foundation
import CoreGraphics
import ImageIO

/// Converts album art to a 1bpp bitmap for the OLED.
enum ArtworkDither {
    /// Decodes `data` (any format ImageIO understands), aspect-fills it into a
    /// `size` x `size` square, stretches the contrast, and dithers it with
    /// Atkinson error diffusion. Returns `size * size` pixels, row-major,
    /// `true` meaning lit. Nil if the data is not a decodable image.
    ///
    /// This is comparatively expensive, so callers cache the result and only
    /// call it when the artwork actually changes.
    static func bitmap(from data: Data, size: Int) -> [Bool]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let gray = grayscale(image, size: size) else { return nil }
        return atkinson(autoLevel(gray), size: size)
    }

    private static func grayscale(_ image: CGImage, size: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: size * size)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let scale = CGFloat(size) / min(width, height) // aspect fill
            context.draw(image, in: CGRect(x: (CGFloat(size) - width * scale) / 2,
                                           y: (CGFloat(size) - height * scale) / 2,
                                           width: width * scale, height: height * scale))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Stretches the 2nd..98th brightness percentile to the full range, so
    /// dark or washed-out covers still use both lit and unlit pixels.
    private static func autoLevel(_ pixels: [UInt8]) -> [Double] {
        let sorted = pixels.sorted()
        let low = Double(sorted[sorted.count * 2 / 100])
        let high = Double(sorted[sorted.count * 98 / 100])
        let span = max(high - low, 1)
        return pixels.map { min(255, max(0, (Double($0) - low) / span * 255)) }
    }

    /// Atkinson diffuses only 6/8 of the error, which keeps highlights and
    /// shadows clean and reads crisper than Floyd-Steinberg at small sizes.
    private static func atkinson(_ levels: [Double], size: Int) -> [Bool] {
        var work = levels
        var lit = [Bool](repeating: false, count: size * size)
        let spread = [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)]
        for y in 0..<size {
            for x in 0..<size {
                let old = work[y * size + x]
                let new: Double = old >= 128 ? 255 : 0
                lit[y * size + x] = new == 255
                let share = (old - new) / 8
                for (dx, dy) in spread {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < size, ny < size { work[ny * size + nx] += share }
                }
            }
        }
        return lit
    }
}
