import Foundation
import Observation

/// Gradients made with the + after the built-in ones, while Overlap is open. Each shows as a swatch to go back to;
/// they aren't kept once Overlap quits, though a project keeps the one it uses as its background.
@MainActor
@Observable
final class GradientLibrary {
    static let shared = GradientLibrary()

    private(set) var gradients: [MeshGradientFill] = []

    /// Adds a new gradient, last.
    func add(_ gradient: MeshGradientFill) {
        guard gradient.id != nil, !gradients.contains(where: { $0.id == gradient.id }) else { return }
        gradients.append(gradient)
    }

    /// Keeps a gradient's latest shape in its swatch.
    func update(_ gradient: MeshGradientFill) {
        guard let index = gradients.firstIndex(where: { $0.id != nil && $0.id == gradient.id }) else { return }
        gradients[index] = gradient
    }

    func remove(_ id: UUID) {
        gradients.removeAll { $0.id == id }
    }
}
