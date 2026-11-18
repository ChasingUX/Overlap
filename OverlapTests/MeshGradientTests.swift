import AppKit
import CoreImage
import Foundation
import Testing
@testable import Overlap

/// Mesh gradients drawn with SwiftUI: the built-in ones, shaping one by its points, and drawing it for the picture.
@MainActor
struct MeshGradientTests {
    @Test func theBuiltInGradientsAreMeshes() {
        #expect(BackgroundFill.gradients.count == MeshGradientFill.presets.count)
        for fill in BackgroundFill.gradients {
            guard case let .meshGradient(mesh) = fill else {
                Issue.record("Not a mesh gradient: \(fill)")
                continue
            }
            #expect(mesh.points.count == mesh.columns * mesh.rows)
            #expect(mesh.grain == MeshGradientFill.standardGrain)
        }
    }

    @Test func cornersStayEdgesSlideAndTheMiddleGoesAnywhere() throws {
        let mesh = try #require(MeshGradientFill.presets.first)
        let corner = mesh.moving(0, to: 0.3, 0.3)
        #expect(corner.points[0] == mesh.points[0])
        // The top middle slides along the top.
        let top = mesh.moving(1, to: 0.7, 0.4)
        #expect(top.points[1].x == 0.7)
        #expect(top.points[1].y == 0)
        // The left middle slides down the left side.
        let left = mesh.moving(3, to: 0.4, 0.8)
        #expect(left.points[3].x == 0)
        #expect(left.points[3].y == 0.8)
        // The middle goes anywhere on the canvas, but not off it.
        let middle = mesh.moving(4, to: 1.4, -0.2)
        #expect(middle.points[4].x == 1)
        #expect(middle.points[4].y == 0)
    }

    @Test func aGradientSavesAndOpensAsItWas() throws {
        var mesh = try #require(MeshGradientFill.presets.last)
        mesh.grain = 0.45
        let fill = BackgroundFill.meshGradient(mesh.moving(4, to: 0.3, 0.7))
        let read = try JSONDecoder().decode(BackgroundFill.self, from: JSONEncoder().encode(fill))
        #expect(read == fill)
    }

    @Test func itsDrawnOnceAndStretchedToTheCanvas() throws {
        let mesh = try #require(MeshGradientFill.presets.first)
        let drawn = try #require(MeshGradientRenderer.prepare(mesh))
        #expect(drawn.width == MeshGradientRenderer.side)
        // Grain doesn't need a drawing of its own.
        var grained = mesh
        grained.grain = 0.8
        #expect(MeshGradientRenderer.prepare(grained) === drawn)
        let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(MeshGradientRenderer.ciImage(grained, in: canvas).extent == canvas)
        // The corners take their points' colors: the top left of Aurora is a deep purple, the bottom right a mint.
        let context = CIContext()
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(MeshGradientRenderer.ciImage(mesh, in: canvas), toBitmap: &bytes, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return bytes
        }
        // Core Image's y runs up: y 1075 is near the top.
        let topLeft = pixel(4, 1075), bottomRight = pixel(1915, 4)
        #expect(topLeft[2] > topLeft[1])
        #expect(bottomRight[1] > bottomRight[0])
    }

    @Test func shapingTheGradientKeepsTheFrame() throws {
        let store = ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let mesh = try #require(MeshGradientFill.presets.first)
        store.setBackground(.meshGradient(mesh))
        let frame = store.project.frame
        #expect(frame != nil)
        store.previewGradient(mesh.moving(4, to: 0.2, 0.2))
        #expect(store.project.background == .meshGradient(mesh))
        store.setGradient(mesh.moving(4, to: 0.2, 0.2), name: "Move Gradient Color")
        #expect(store.project.background == .meshGradient(mesh.moving(4, to: 0.2, 0.2)))
        #expect(store.project.frame == frame)
    }
}

/// A gradient's dot picks its color in the color panel straight away: changes show as they come, and the color is
/// kept once they stop.
@MainActor
struct ColorPanelSessionTests {
    @Test func changesShowAndTheLastOneIsKept() async throws {
        let session = ColorPanelSession()
        var shown: [RGBA] = []
        var kept: [RGBA] = []
        var ended = false
        session.start(color: .white, beside: nil, onChange: { shown.append($0) }, onCommit: { kept.append($0) }, onEnd: { ended = true })
        #expect(ColorPanelSession.active === session)
        // Setting the panel's color sends its change, as dragging in it does.
        let panel = NSColorPanel.shared
        panel.color = .red
        panel.color = .blue
        #expect((shown.last?.blue ?? 0) > 0.9)
        #expect(kept.isEmpty)
        for _ in 0..<40 where kept.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        // Only the color it settled on.
        #expect(kept.count == 1)
        #expect((kept.first?.blue ?? 0) > 0.9)
        session.stop()
        #expect(ended)
        #expect(ColorPanelSession.active == nil)
        panel.close()
    }
}

/// Making gradients of your own: the + makes a fresh one each time, which shows as a swatch while Overlap is open.
@MainActor
struct GradientLibraryTests {
    @Test func sevenBuiltInGradients() {
        #expect(MeshGradientFill.presets.count == 7)
        #expect(MeshGradientFill.presets.allSatisfy { $0.id == nil })
    }

    @Test func aNewGradientIsFreshEachTimeAndFillsTheCanvas() {
        let one = MeshGradientFill.surprise(), two = MeshGradientFill.surprise()
        #expect(one.id != nil && one.id != two.id)
        #expect(one.points.map(\.color) != two.points.map(\.color))
        #expect(one.points.count == 9)
        // Corners at the corners, edges on their edges.
        #expect(one.points[0].x == 0 && one.points[0].y == 0)
        #expect(one.points[8].x == 1 && one.points[8].y == 1)
        #expect(one.points[1].y == 0 && one.points[3].x == 0 && one.points[5].x == 1 && one.points[7].y == 1)
    }

    @Test func eachPlusAddsASwatchThatFollowsItsShaping() throws {
        let library = GradientLibrary()
        let first = MeshGradientFill.surprise(), second = MeshGradientFill.surprise()
        library.add(first)
        library.add(second)
        library.add(first)
        library.add(MeshGradientFill.presets[0])
        #expect(library.gradients == [first, second])
        let shaped = first.moving(4, to: 0.2, 0.8)
        library.update(shaped)
        #expect(library.gradients == [shaped, second])
        library.remove(try #require(first.id))
        #expect(library.gradients == [second])
    }
}
