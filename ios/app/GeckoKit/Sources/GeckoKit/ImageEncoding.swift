import Foundation

#if canImport(UIKit)
import UIKit

/// gdk-pixbuf on iOS ships only the built-in PNG loader, so re-encode any picked
/// image (JPEG/HEIC/…) to a PNG temp file before handing its path to the bridge
/// for avatar publishing. Returns nil if the image can't be read or written.
///
/// Decodes straight to `maxPixel` rather than at full resolution: the core
/// publishes avatars at 192px, so a 48MP photo would otherwise cost ~200MB
/// decoded plus a huge PNG for nothing.
///
/// UIKit-only, so it's excluded from the host `swift test` build; the iOS
/// Simulator test run (`xcodebuild test`) exercises it.
func avatarPNG(from path: String, maxPixel: Int = 512) -> String? {
    guard let image = ThumbnailLoader.downsample(path: path, maxPixel: maxPixel),
          let data = image.pngData() else { return nil }
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    do {
        try data.write(to: dest)
        return dest.path
    } catch {
        return nil
    }
}
#endif
