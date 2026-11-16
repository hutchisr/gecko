import CoreGraphics

/// The geometry of framing a profile picture: an image that always fills a
/// square viewport, zoomed and shifted by the user. Offsets are in viewport
/// sides, so the same numbers describe the on-screen view and the pixels.
enum AvatarCrop {
    static let maxZoom: CGFloat = 5

    /// The side, in image pixels, of the square showing through the viewport.
    private static func side(image: CGSize, zoom: CGFloat) -> CGFloat {
        min(image.width, image.height) / min(max(zoom, 1), maxZoom)
    }

    /// `offset` held to where the image still covers the whole viewport.
    static func clamp(_ offset: CGSize, image: CGSize, zoom: CGFloat) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let side = side(image: image, zoom: zoom)
        let limit = CGSize(width: (image.width / side - 1) / 2, height: (image.height / side - 1) / 2)
        return CGSize(width: min(max(offset.width, -limit.width), limit.width),
                      height: min(max(offset.height, -limit.height), limit.height))
    }

    /// The square of the image, in its pixels, that the viewport shows.
    /// Shifting the image right (a positive offset) reveals more of its left.
    static func rect(image: CGSize, zoom: CGFloat, offset: CGSize) -> CGRect {
        let side = side(image: image, zoom: zoom)
        let offset = clamp(offset, image: image, zoom: zoom)
        // Clamped again in pixels: the offset limit can round a hair outside.
        return CGRect(x: min(max((image.width - side) / 2 - offset.width * side, 0), image.width - side),
                      y: min(max((image.height - side) / 2 - offset.height * side, 0), image.height - side),
                      width: side, height: side)
    }
}
