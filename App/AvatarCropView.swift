import SwiftUI

/// Frames a picked image as a square profile picture: drag to move, pinch or
/// use the slider to resize. `onUse` gets the cropped PNG; the staged original
/// is deleted when the view goes away, whichever way it goes.
///
/// Pushed onto the presenting sheet's own navigation stack, never shown as a
/// sheet of its own: on Catalyst a second sheet presented while the picker's
/// is still animating away comes up blank.
struct AvatarCropView: View {
    let url: URL
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize.zero
    /// Where the gesture in progress started from.
    @State private var gestureStart: (zoom: CGFloat, offset: CGSize)?

    var body: some View {
        VStack(spacing: 20) {
            if let image {
                cropArea(image)
                Slider(value: zoomBinding(image), in: 1...AvatarCrop.maxZoom) {
                    Text("Zoom")
                } minimumValueLabel: {
                    Image(systemName: "minus.magnifyingglass")
                } maximumValueLabel: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .padding(.horizontal)
            } else if failed {
                ContentUnavailableView("Could not load image", systemImage: "photo")
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .padding(.vertical)
        .navigationTitle("Move and Scale")
        .navigationBarTitleDisplayMode(.inline)
        // Cancel replaces Back, which also stops the edge swipe from fighting
        // the drag that moves the image.
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use Photo") {
                    if let image, let path = Self.write(image, zoom: zoom, offset: offset) {
                        onUse(path)
                    }
                    dismiss()
                }
                .disabled(image == nil)
            }
        }
        .task {
            // Plenty for a 512px avatar even at full zoom, without decoding a
            // 48MP photo at full size.
            let path = url.path
            image = await Task.detached(priority: .userInitiated) {
                ThumbnailLoader.downsample(path: path, maxPixel: 2560)
            }.value
            failed = image == nil
        }
        .onDisappear { AttachmentStaging.removeTemporaryCopy(at: url) }
    }

    private func cropArea(_ image: UIImage) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .scaleEffect(zoom)
                .offset(x: offset.width * side, y: offset.height * side)
                .frame(width: side, height: side)
                .clipped()
                .overlay {
                    // Avatars are shown round: dim what the circle will hide.
                    Rectangle()
                        .fill(.black.opacity(0.5))
                        .mask {
                            Rectangle()
                                .overlay(Circle().blendMode(.destinationOut))
                                .compositingGroup()
                        }
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { drag in
                            let start = gestureStart ?? (zoom, offset)
                            gestureStart = start
                            offset = AvatarCrop.clamp(
                                CGSize(width: start.offset.width + drag.translation.width / side,
                                       height: start.offset.height + drag.translation.height / side),
                                image: image.size, zoom: zoom)
                        }
                        .onEnded { _ in gestureStart = nil }
                        .simultaneously(with: MagnifyGesture()
                            .onChanged { pinch in
                                let start = gestureStart ?? (zoom, offset)
                                gestureStart = start
                                zoomBinding(image).wrappedValue = start.zoom * pinch.magnification
                            }
                            .onEnded { _ in gestureStart = nil })
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Profile picture framing")
                .accessibilityIdentifier("avatar.crop")
        }
    }

    /// Zooming out can leave the image short of an edge; pull it back in.
    private func zoomBinding(_ image: UIImage) -> Binding<CGFloat> {
        Binding {
            zoom
        } set: { value in
            zoom = min(max(value, 1), AvatarCrop.maxZoom)
            offset = AvatarCrop.clamp(offset, image: image.size, zoom: zoom)
        }
    }

    /// The framed square as a PNG of at most 512px, in the temporary directory.
    private static func write(_ image: UIImage, zoom: CGFloat, offset: CGSize) -> String? {
        guard let source = image.cgImage else { return nil }
        let pixels = CGSize(width: source.width, height: source.height)
        let rect = AvatarCrop.rect(image: pixels, zoom: zoom, offset: offset).integral
        guard let cropped = source.cropping(to: rect) else { return nil }
        let side = min(512, CGFloat(cropped.width))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        return (try? data.write(to: destination)) == nil ? nil : destination.path
    }
}
