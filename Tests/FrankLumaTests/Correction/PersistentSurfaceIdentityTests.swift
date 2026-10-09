import XCTest
@testable import FrankLuma

final class PersistentSurfaceIdentityTests: XCTestCase {
    private func image(illumination: Bool = false, shift: Double = 0, textured: Bool = true) -> SpatialThumbnail {
        var rgb = [Float]()
        for y in 0..<24 { for x in 0..<24 { for c in 0..<3 {
            let xx = Double(x)+shift, yy = Double(y)
            let detail = textured ? 0.12*sin(xx*0.9+Double(c))*cos(yy*0.7)+0.05*cos(xx*1.7+yy*0.4) : 0
            let light = illumination ? 0.03*Double(x)-0.02*yy+0.1*Double(c) : 0
            rgb.append(Float(pow(2,-3+detail+light)))
        } } }
        return SpatialThumbnail(width: 24, height: 24, rgb: rgb)
    }

    func testSpatialIlluminationDoesNotBreakSourceIdentity() throws {
        let a = try XCTUnwrap(PersistentSurfaceIdentity.descriptor(image(), x: 12, y: 12))
        let b = try XCTUnwrap(PersistentSurfaceIdentity.descriptor(image(illumination: true), x: 12, y: 12))
        XCTAssertTrue(PersistentSurfaceIdentity.agrees(a,b))
        let changed = try XCTUnwrap(PersistentSurfaceIdentity.descriptor(image(shift: 3), x: 12, y: 12))
        XCTAssertFalse(PersistentSurfaceIdentity.agrees(a,changed))
    }

    func testLightingPlaneAloneHasNoIdentity() {
        XCTAssertNil(PersistentSurfaceIdentity.descriptor(image(illumination: true, textured: false), x: 12, y: 12))
        XCTAssertNil(PersistentSurfaceIdentity.descriptor(image(), x: 2, y: 12))
        XCTAssertFalse(PersistentSurfaceIdentity.agrees([],[]))
    }
}
