import Foundation
import ImageIO

/// The animation is sampled on the editor's 30 fps clock. Each GIF image is decoded once.
struct GIFTiming {
    let source: CGImageSource
    let frameEnds: [Int]
    var frames: Int { frameEnds.last ?? 0 }
    var duration: Double { Double(frames) / 30 }

    init(url: URL) throws {
        let failure = MediaEditProject.Failure.invalid("Couldn’t read \(url.lastPathComponent) as a GIF.")
        guard let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes <= 32 * 1024 * 1024 else {
            throw MediaEditProject.Failure.invalid("Use a GIF smaller than 32 MB.")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) == "com.compuserve.gif" as CFString? else { throw failure }
        let count = CGImageSourceGetCount(source)
        guard (1...3600).contains(count) else { throw failure }
        var elapsed = 0.0
        var ends: [Int] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let raw = (gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]) as? Double
            let delay = raw.flatMap { $0.isFinite && $0 >= 0.02 ? $0 : nil } ?? 0.1
            elapsed += delay
            guard elapsed <= 120 else {
                throw MediaEditProject.Failure.invalid("Use a GIF with an animation shorter than two minutes.")
            }
            ends.append(max(1, Int((elapsed * 30).rounded())))
        }
        self.source = source
        self.frameEnds = ends
    }
}
