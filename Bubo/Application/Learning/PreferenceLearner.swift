import Foundation
@preconcurrency import BuboOptimizer

// MARK: - PreferenceLearner cloud-sync bridge
//
// The core `PreferenceLearner` lives in `BuboOptimizer` so the optimizer
// target stands alone in tests that don't link Bubo. This extension wires
// CloudSync push on every save and a NotificationCenter observer that
// reloads when a remote change arrives — the two integration points that
// require the Bubo-target `CloudSyncService`.

private enum PreferenceLearnerCloudSync {

    /// Holder for the live observer so its lifetime tracks the learner.
    /// Static map keeps us from adding stored properties to a public
    /// type in another module via extension.
    @MainActor
    static var observersByLearner: [ObjectIdentifier: NSObjectProtocol] = [:]
}

extension PreferenceLearner {

    /// Attach the cloud-sync observers. Idempotent — calling twice with
    /// the same learner instance is a no-op after the first wire-up.
    @MainActor
    func setupCloudSync() {
        let key = ObjectIdentifier(self)
        guard PreferenceLearnerCloudSync.observersByLearner[key] == nil else { return }

        let persistenceKey = self.persistenceKey
        let feedbackKey = self.feedbackKey
        let observer = NotificationCenter.default.addObserver(
            forName: CloudSyncService.didReceiveRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let token = notification.object as? String,
                  token == persistenceKey || token == feedbackKey
            else { return }
            self?.load()
        }
        PreferenceLearnerCloudSync.observersByLearner[key] = observer
    }

    /// Push the on-disk snapshot through CloudSync after a local save.
    /// Call this from Bubo-side feedback handlers right after the core
    /// `save()` runs — the optimizer doesn't know about CloudSync, so
    /// pushing has to happen at the app layer.
    func pushToCloudSync() {
        CloudSyncService.shared.push(persistenceKey)
        CloudSyncService.shared.push(feedbackKey)
    }
}
