// rapp-rewind context shim — what was on screen, so search can be scoped.
// usage: context   -> {"app":…,"bundle":…,"title":…,"display_w":…,"display_h":…}
// Frontmost app needs no permission; window titles come from the same Screen
// Recording grant the capture already requires.
import Foundation
import AppKit
import CoreGraphics

var out: [String: Any] = [:]
if let app = NSWorkspace.shared.frontmostApplication {
    out["app"] = app.localizedName ?? ""
    out["bundle"] = app.bundleIdentifier ?? ""
    out["pid"] = app.processIdentifier
}
// title of the frontmost window belonging to that pid
if let pid = out["pid"] as? Int32,
   let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] {
    for w in infos {
        guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
        if let t = w[kCGWindowName as String] as? String, !t.isEmpty { out["title"] = t; break }
    }
}
out["pid"] = nil
if let s = NSScreen.main {
    out["display_w"] = Int(s.frame.width)
    out["display_h"] = Int(s.frame.height)
}
let clean = out.compactMapValues { $0 }
if let d = try? JSONSerialization.data(withJSONObject: clean),
   let s = String(data: d, encoding: .utf8) { print(s) }
