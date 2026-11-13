import CoreGraphics
import Foundation
import Testing
@testable import RegistaCore
@testable import RegistaEngines

// Frame backdrops of the styled screen layout (issue #44): gradients computed per pixel, dithered.

/// The RGB bytes of pixel (x, y) (top-left origin) of a CGImage.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    let data = image.dataProvider!.data! as Data
    let i = y * image.bytesPerRow + x * 4
    return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
}

@Test func linearGradientsFollowTheirCSSAngle() throws {
    // 180°: top to bottom, black → white.
    let down = try #require(BackdropStore.gradient(Backdrop(kind: .linear, colors: ["#000000", "#FFFFFF"], angle: 180), width: 64, height: 100))
    #expect(pixel(down, 32, 0).0 <= 3 && pixel(down, 32, 99).0 >= 252)
    #expect(abs(pixel(down, 10, 50).0 - 128) <= 3 && abs(pixel(down, 50, 50).0 - 128) <= 3)
    // 90°: left to right, three stops.
    let right = try #require(BackdropStore.gradient(Backdrop(kind: .linear, colors: ["#FF0000", "#00FF00", "#0000FF"], angle: 90), width: 101, height: 10))
    #expect(pixel(right, 0, 5).0 >= 250 && pixel(right, 50, 5).1 >= 250 && pixel(right, 100, 5).2 >= 250)
}

@Test func radialGradientsStartAtTheirCentreAndDitherWithoutBanding() throws {
    let b = Backdrop(kind: .radial, colors: ["#808080", "#000000"], center: [0.25, 0.25])
    let img = try #require(BackdropStore.gradient(b, width: 200, height: 200))
    #expect(abs(pixel(img, 50, 50).0 - 128) <= 2)
    #expect(pixel(img, 199, 199).0 <= 2)
    // ±1 LSB dither: neighbours along a flat line differ by at most 2, and the ramp is not one flat step.
    let row = (0..<200).map { pixel(img, $0, 50).0 }
    #expect(zip(row, row.dropFirst()).allSatisfy { abs($0 - $1) <= 3 })
    #expect(Set(row).count > 20)
}

@Test func everyBuiltInBackgroundRenders() {
    let store = BackdropStore(), graphics = GraphicsStore()
    for (name, b, _) in Backdrop.presets {
        let img = store.image(b, width: 320, height: 180, graphics: graphics)
        #expect(img?.extent == CGRect(x: 0, y: 0, width: 320, height: 180), "\(name)")
    }
    #expect(store.image(Backdrop(kind: .solid, colors: ["#102030"]), width: 32, height: 18, graphics: graphics) != nil)
    #expect(store.image(Backdrop(kind: .image, path: "/nonexistent.png"), width: 32, height: 18, graphics: graphics) == nil)
}
