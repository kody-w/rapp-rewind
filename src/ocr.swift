// rapp-rewind OCR shim — Apple Vision text recognition, on-device, no network.
// usage: ocr <image> [more images...]
// prints one JSON object per line: {"path":…,"text":…,"lines":n,"confidence":…}
import Foundation
import Vision
import AppKit

func recognize(_ path: String) -> [String: Any] {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return ["path": path, "error": "cannot read image"]
    }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([req]) } catch {
        return ["path": path, "error": "\(error)"]
    }
    let obs = req.results ?? []
    var lines: [String] = []
    var conf: Float = 0
    for o in obs {
        if let top = o.topCandidates(1).first {
            lines.append(top.string)
            conf += top.confidence
        }
    }
    return ["path": path,
            "text": lines.joined(separator: "\n"),
            "lines": lines.count,
            "confidence": obs.isEmpty ? 0 : Double(conf / Float(obs.count))]
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    FileHandle.standardError.write("usage: ocr <image>...\n".data(using: .utf8)!)
    exit(2)
}
for p in args {
    let r = recognize(p)
    if let d = try? JSONSerialization.data(withJSONObject: r),
       let s = String(data: d, encoding: .utf8) {
        print(s)
    }
}
