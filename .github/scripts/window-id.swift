// Prints the window number of the largest on-screen, normal-level window owned by a process, for
// `screencapture -l`. Usage: window-id <pid>. Exits 1 if that process has no such window yet.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: window-id <pid>\n".data(using: .utf8)!)
    exit(2)
}
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]) ?? []

func number(_ window: [String: Any], _ key: CFString) -> NSNumber? { window[key as String] as? NSNumber }
func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    return ((bounds["Width"] as? NSNumber)?.doubleValue ?? 0) * ((bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
}

let owned = windows.filter { number($0, kCGWindowOwnerPID)?.int32Value == pid && number($0, kCGWindowLayer)?.intValue == 0 }
guard let best = owned.max(by: { area($0) < area($1) }), area(best) > 10_000,
      let id = number(best, kCGWindowNumber) else { exit(1) }
print(id.intValue)
