import Foundation

/// Adjust energy cost based on story points.
/// Higher SP → higher cognitive load → schedule at peak energy.
///
/// Lives in `BuboDomain` (alongside `OptimizableEvent` / `BacklogTask`)
/// so `BacklogTask.toOptimizableEvent()` can call it without forming an
/// upward dependency on `BuboOptimizer`.
public func adjustedEnergy(base: Double, storyPoints: Int?) -> Double {
    guard let sp = storyPoints, sp > 0 else { return base }
    let normalized = min(1.0, log(Double(sp)) / log(13.0))
    let spEnergy = 0.3 + normalized * 0.65
    return min(1.0, spEnergy * 0.6 + base * 0.4)
}
