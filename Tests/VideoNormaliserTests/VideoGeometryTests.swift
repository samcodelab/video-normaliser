import XCTest
import CoreGraphics
@testable import VideoNormaliser
final class VideoGeometryTests: XCTestCase {
    func testQuarterTurnMatchesVideoDisplayCoordinates() {
        let track=CGAffineTransform(a:0,b:1,c:-1,d:0,tx:2160,ty:0)
        let converted=VideoGeometry.coreImageTransform(preferred:track,naturalSize:CGSize(width:3840,height:2160))
        let upperLeft=CGPoint(x:0,y:2160).applying(converted)
        XCTAssertEqual(upperLeft.x,2160,accuracy:0.00001)
        XCTAssertEqual(upperLeft.y,3840,accuracy:0.00001)
        let lowerLeft=CGPoint.zero.applying(converted)
        XCTAssertEqual(lowerLeft.x,0,accuracy:0.00001)
        XCTAssertEqual(lowerLeft.y,3840,accuracy:0.00001)
        let restored=upperLeft.applying(converted.inverted())
        XCTAssertEqual(restored.x,0,accuracy:0.00001)
        XCTAssertEqual(restored.y,2160,accuracy:0.00001)
    }
    func testIdentityOrientationRemainsIdentity() {
        XCTAssertEqual(VideoGeometry.coreImageTransform(preferred:.identity,naturalSize:CGSize(width:1920,height:1080)),.identity)
    }
}
