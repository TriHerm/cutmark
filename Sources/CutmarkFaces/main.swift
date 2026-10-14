// cutmark-faces (2026-10-11): the faces in still images, for check_edit's framing check
// (mcp/cutmark_mcp.py). Apple Vision on this Mac, no model to download.
// Usage: cutmark-faces <image>... → one JSON line per image:
// {"path": ..., "faces": [[x, y, w, h], ...]} in 0...1 of the image, y from the top.
import Foundation
import Vision

for path in CommandLine.arguments.dropFirst() {
    var faces: [[Double]] = []
    var error: String?
    let request = VNDetectFaceRectanglesRequest()
    do {
        try VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])
        for f in request.results ?? [] {
            let b = f.boundingBox  // Vision: y from the bottom
            faces.append([b.minX, 1 - b.maxY, b.width, b.height].map { (Double($0) * 1000).rounded() / 1000 })
        }
    } catch let e {
        error = e.localizedDescription
    }
    var line: [String: Any] = ["path": path, "faces": faces]
    if let error { line["error"] = error }
    let data = try JSONSerialization.data(withJSONObject: line)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
