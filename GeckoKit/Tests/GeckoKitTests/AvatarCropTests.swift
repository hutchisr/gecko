import CoreGraphics
import XCTest
@testable import GeckoKit

final class AvatarCropTests: XCTestCase {
    private let landscape = CGSize(width: 400, height: 200)

    func testUntouchedCropIsTheCentredSquare() {
        XCTAssertEqual(AvatarCrop.rect(image: landscape, zoom: 1, offset: .zero),
                       CGRect(x: 100, y: 0, width: 200, height: 200))
    }

    func testDraggingRightRevealsTheLeftAndStopsAtTheEdge() {
        XCTAssertEqual(AvatarCrop.rect(image: landscape, zoom: 1, offset: CGSize(width: 0.25, height: 0)).minX, 50)
        // Far past the edge, and vertically where there is no room at all.
        XCTAssertEqual(AvatarCrop.rect(image: landscape, zoom: 1, offset: CGSize(width: 9, height: 9)),
                       CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    func testZoomShrinksTheSquareAndNeverLeavesTheImage() {
        XCTAssertEqual(AvatarCrop.rect(image: landscape, zoom: 2, offset: .zero),
                       CGRect(x: 150, y: 50, width: 100, height: 100))
        let bounds = CGRect(origin: .zero, size: landscape)
        for zoom in [0.2, 1, 3, 99] as [CGFloat] {
            for shift in [-9, -0.3, 0, 0.3, 9] as [CGFloat] {
                let rect = AvatarCrop.rect(image: landscape, zoom: zoom, offset: CGSize(width: shift, height: -shift))
                XCTAssertTrue(bounds.contains(rect), "zoom \(zoom) shift \(shift): \(rect)")
                XCTAssertGreaterThanOrEqual(rect.width, 200 / AvatarCrop.maxZoom)
            }
        }
    }
}
