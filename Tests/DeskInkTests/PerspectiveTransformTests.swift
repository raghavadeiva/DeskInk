import Testing
@testable import DeskInk

@Suite("Perspective transform")
struct PerspectiveTransformTests {
    @Test("Identity transform maps an interior point")
    func identityTransformMapsInteriorPoint() throws {
        let square = [
            NormalizedPoint(x: 0, y: 0),
            NormalizedPoint(x: 1, y: 0),
            NormalizedPoint(x: 1, y: 1),
            NormalizedPoint(x: 0, y: 1)
        ]
        let transform = try #require(PerspectiveTransform(source: square, destination: square))
        let mapped = try #require(transform.applying(to: NormalizedPoint(x: 0.31, y: 0.74)))
        #expect(abs(mapped.x - 0.31) < 1e-9)
        #expect(abs(mapped.y - 0.74) < 1e-9)
    }

    @Test("Perspective transform maps all corners and the center")
    func perspectiveTransformMapsAllCornersAndCenter() throws {
        let source = [
            NormalizedPoint(x: 0.18, y: 0.12),
            NormalizedPoint(x: 0.82, y: 0.19),
            NormalizedPoint(x: 0.91, y: 0.86),
            NormalizedPoint(x: 0.09, y: 0.79)
        ]
        let destination = [
            NormalizedPoint(x: 0, y: 0),
            NormalizedPoint(x: 1, y: 0),
            NormalizedPoint(x: 1, y: 1),
            NormalizedPoint(x: 0, y: 1)
        ]
        let transform = try #require(PerspectiveTransform(source: source, destination: destination))

        for index in 0..<4 {
            let mapped = try #require(transform.applying(to: source[index]))
            #expect(abs(mapped.x - destination[index].x) < 1e-8)
            #expect(abs(mapped.y - destination[index].y) < 1e-8)
        }

        let center = try #require(transform.applying(to: NormalizedPoint(x: 0.5, y: 0.5)))
        #expect((0...1).contains(center.x))
        #expect((0...1).contains(center.y))
    }

    @Test("Repeated and collinear corners are rejected")
    func rejectsRepeatedOrCollinearCorners() {
        let destination = [
            NormalizedPoint(x: 0, y: 0),
            NormalizedPoint(x: 1, y: 0),
            NormalizedPoint(x: 1, y: 1),
            NormalizedPoint(x: 0, y: 1)
        ]
        let repeated = [
            NormalizedPoint(x: 0, y: 0),
            NormalizedPoint(x: 1, y: 0),
            NormalizedPoint(x: 1, y: 0),
            NormalizedPoint(x: 0, y: 1)
        ]
        let collinear = [
            NormalizedPoint(x: 0, y: 0),
            NormalizedPoint(x: 0.3, y: 0.3),
            NormalizedPoint(x: 0.6, y: 0.6),
            NormalizedPoint(x: 1, y: 1)
        ]

        #expect(PerspectiveTransform(source: repeated, destination: destination) == nil)
        #expect(PerspectiveTransform(source: collinear, destination: destination) == nil)
    }

    @Test("A self-crossing corner order is rejected")
    func rejectsSelfCrossingCornerOrder() {
        let bowTie = [
            NormalizedPoint(x: 0, y: 0),
            NormalizedPoint(x: 1, y: 1),
            NormalizedPoint(x: 1, y: 0),
            NormalizedPoint(x: 0, y: 1)
        ]
        #expect(PerspectiveTransform.paperTransform(sourceCorners: bowTie) == nil)
    }
}
