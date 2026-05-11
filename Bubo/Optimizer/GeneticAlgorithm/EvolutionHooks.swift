import Foundation

// MARK: - Evolution Hooks
//
// Generic extension points the GA invokes during evolution. The engine
// never reaches into schedule-specific types; everything that needs
// `ScheduleChromosome` semantics (Quality-Diversity archive feeding,
// finite-difference gradient refinement, surrogate screening
// telemetry) plugs in via these closures. Construction lives in the
// caller — for the 13-objective scheduler, that's `BuboOptimizer`.
//
// Three hook points cover the extension features this project needs:
//
//   • `onOffspringEvaluated` runs once per generation after every
//     offspring has been evaluated. QD archive feeding lives here.
//   • `onGenerationComplete` runs once per generation after survivor
//     selection. Gradient refinement and archive-emitter injection
//     live here. Mutation of the population is allowed (and that's
//     how emitter injection works).
//   • `onPostEvolution` runs once after the main loop exits, before
//     the final hill-climb. Final-state telemetry lives here.
//
// Intervals and per-hook gating are the caller's responsibility — keep
// the GA's view minimal so adding new hook clients doesn't require
// engine changes.

/// Bundle of optional closures the GA fires at well-defined moments.
/// Closures are `@Sendable` so the engine can run inside `Task.detached`
/// without the compiler relaxing concurrency checks.
struct EvolutionHooks<C: Chromosome>: @unchecked Sendable {
    /// Called once per generation after offspring have been evaluated
    /// but before survivor selection. The `offspring` array is a
    /// snapshot — mutating the closure's local copy has no effect on
    /// evolution. Use this for read-only consumers (QD archive,
    /// telemetry).
    let onOffspringEvaluated: (@Sendable (_ generation: Int, _ offspring: [C], _ context: OptimizerContext) -> Void)?

    /// Called once per generation after survivor selection. The
    /// population is `inout` so hooks can replace individuals (e.g.
    /// inject archive emitters, write back gradient-refined elites).
    /// Hooks are responsible for re-evaluating any chromosomes whose
    /// fitness they invalidate.
    let onGenerationComplete: (@Sendable (_ generation: Int, _ population: inout Population<C>, _ context: OptimizerContext) -> Void)?

    /// Called once after the main evolution loop exits, before the
    /// final hill-climb. Use for end-of-run telemetry — population
    /// mutation is *not* respected here because the next stage is the
    /// returning sort.
    let onPostEvolution: (@Sendable (_ population: [C], _ context: OptimizerContext) -> Void)?

    init(
        onOffspringEvaluated: (@Sendable (Int, [C], OptimizerContext) -> Void)? = nil,
        onGenerationComplete: (@Sendable (Int, inout Population<C>, OptimizerContext) -> Void)? = nil,
        onPostEvolution: (@Sendable ([C], OptimizerContext) -> Void)? = nil
    ) {
        self.onOffspringEvaluated = onOffspringEvaluated
        self.onGenerationComplete = onGenerationComplete
        self.onPostEvolution = onPostEvolution
    }

    /// No-op hooks. Used as the default so callers that don't need any
    /// extension point can construct a GA without ceremony.
    static var noop: EvolutionHooks<C> {
        EvolutionHooks(onOffspringEvaluated: nil, onGenerationComplete: nil, onPostEvolution: nil)
    }

    /// Compose two hook bundles. Each phase fires both bundles' hooks
    /// in order — useful for stacking schedule-specific QD feeding on
    /// top of, say, a generic telemetry hook without either knowing
    /// about the other.
    static func combine(_ a: EvolutionHooks<C>, _ b: EvolutionHooks<C>) -> EvolutionHooks<C> {
        EvolutionHooks(
            onOffspringEvaluated: composeOffspring(a.onOffspringEvaluated, b.onOffspringEvaluated),
            onGenerationComplete: composeGeneration(a.onGenerationComplete, b.onGenerationComplete),
            onPostEvolution: composePost(a.onPostEvolution, b.onPostEvolution)
        )
    }

    private static func composeOffspring(
        _ a: (@Sendable (Int, [C], OptimizerContext) -> Void)?,
        _ b: (@Sendable (Int, [C], OptimizerContext) -> Void)?
    ) -> (@Sendable (Int, [C], OptimizerContext) -> Void)? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil), (nil, let x?): return x
        case (let x?, let y?): return { gen, off, ctx in x(gen, off, ctx); y(gen, off, ctx) }
        }
    }

    private static func composeGeneration(
        _ a: (@Sendable (Int, inout Population<C>, OptimizerContext) -> Void)?,
        _ b: (@Sendable (Int, inout Population<C>, OptimizerContext) -> Void)?
    ) -> (@Sendable (Int, inout Population<C>, OptimizerContext) -> Void)? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil), (nil, let x?): return x
        case (let x?, let y?): return { gen, pop, ctx in x(gen, &pop, ctx); y(gen, &pop, ctx) }
        }
    }

    private static func composePost(
        _ a: (@Sendable ([C], OptimizerContext) -> Void)?,
        _ b: (@Sendable ([C], OptimizerContext) -> Void)?
    ) -> (@Sendable ([C], OptimizerContext) -> Void)? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil), (nil, let x?): return x
        case (let x?, let y?): return { pop, ctx in x(pop, ctx); y(pop, ctx) }
        }
    }
}
