// Prints the CGWindowID of the frontmost normal window owned by a PID, for
// `screencapture -l`. Usage: swift scripts/window-id.swift <pid>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-id.swift <pid>\n".utf8))
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
guard let window = windows.first(where: {
    $0[kCGWindowOwnerPID as String] as? Int == pid && $0[kCGWindowLayer as String] as? Int == 0
}), let id = window[kCGWindowNumber as String] as? Int else {
    FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8))
    exit(1)
}
print(id)
