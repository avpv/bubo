import Foundation
import Network

@MainActor
class NetworkMonitor: ObservableObject {
    @Published var isConnected = true
    @Published var connectionType: ConnectionType = .unknown

    enum ConnectionType {
        case wifi, cellular, wiredEthernet, unknown
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    init() {
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied

                if path.usesInterfaceType(.wifi) {
                    self?.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self?.connectionType = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self?.connectionType = .wiredEthernet
                } else {
                    self?.connectionType = .unknown
                }
            }
        }
        monitor.start(queue: queue)
    }
}

/// Retry helper with exponential backoff
enum RetryHelper {
    static func withRetry<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 2,
        maxDelay: TimeInterval = 30,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var delay = initialDelay

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Don't retry on auth errors
                if let calDavError = error as? CalDAVError,
                   case .httpError(let code) = calDavError,
                   code == 401 || code == 403 {
                    throw error
                }
                if let googleError = error as? GoogleCalendarError,
                   case .httpError(let code) = googleError,
                   code == 401 || code == 403 {
                    throw error
                }
                if error is GoogleAuthError || error is OAuthError {
                    throw error
                }

                if attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay = min(delay * 2, maxDelay)
                }
            }
        }

        throw lastError ?? CalDAVError.invalidResponse
    }
}
