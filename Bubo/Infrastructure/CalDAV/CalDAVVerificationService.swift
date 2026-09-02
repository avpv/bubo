import Foundation
import os

private let calDAVLogger = Logger(subsystem: "com.avpv.Bubo", category: "CalDAVVerification")

// MARK: - External Event Sync Key

/// The minimum EventKit facts needed to check one external occurrence
/// against a CalDAV server: Bubo's occurrence/series ids (same scheme
/// as `AppleCalendarService.fetchEvents`), where the event lives
/// (calendar title + account title), and the iCalendar UID EventKit
/// stores as `calendarItemExternalIdentifier`.
struct ExternalEventSyncKey: Equatable, Sendable {
    let occurrenceId: String
    /// Present for recurring events — hiding by this key suppresses
    /// every occurrence, including ones EventKit hasn't expanded yet.
    let seriesKey: String?
    let calendarTitle: String
    let accountName: String
    let uid: String?
}

// MARK: - CalDAV Verification Service

/// Detects «ghost» external events — events macOS still serves through
/// EventKit although the calendar server deleted them long ago. Happens
/// when an account's CalDAV sync wedges (Yandex Calendar's incremental
/// sync is known to drop deletions); the ghosts pass every liveness
/// check `AppleCalendarService.fetchEvents` can run, so the only way to
/// spot them is to ask the server directly.
///
/// Opt-in (Settings → Calendars → Server Verification). When enabled,
/// every 30 minutes (and on demand) the service:
///  1. discovers the account's calendars over CalDAV,
///  2. collects the UIDs of server events overlapping Bubo's fetch
///     window (padded a day on both sides against timezone edges),
///  3. compares them with what EventKit returns for the same account,
///  4. publishes the resulting ghost keys — `ReminderService` filters
///     them out of every emission exactly like manual hides.
///
/// Conservative by construction: an event is only declared a ghost when
/// its calendar was successfully fetched from the server and its UID is
/// missing there. Discovery errors keep the previous ghost set; a
/// per-calendar fetch error skips that calendar (its events stay
/// visible). Nothing is ever written to the server or to EventKit.
@MainActor
@Observable
final class CalDAVVerificationService {

    // MARK: - Persistence keys

    private static let enabledKey = "BuboCalDAVVerificationEnabled"
    private static let serverURLKey = "BuboCalDAVServerURL"
    private static let usernameKey = "BuboCalDAVUsername"
    private static let accountNameKey = "BuboCalDAVAccountName"
    private static let ghostKeysKey = "BuboCalDAVGhostKeys"
    private static let keychainPasswordKey = "caldav-app-password"

    static let defaultServerURL = "https://caldav.yandex.ru"

    /// Verification cadence while enabled. Deliberately slower than the
    /// EventKit sync loop — server truth doesn't change often, and every
    /// run is one PROPFIND chain plus one REPORT per calendar.
    private static let verifyInterval: TimeInterval = 30 * 60

    // MARK: - Configuration (persisted)

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                start()
                Task { await self.verifyNow() }
            } else {
                stop()
                // Dropping the ghost set un-hides everything the
                // verifier hid — the user turned the feature off, so
                // Bubo goes back to trusting EventKit.
                publishGhostKeys([])
                lastError = nil
            }
        }
    }

    var serverURLString: String {
        didSet {
            guard oldValue != serverURLString else { return }
            UserDefaults.standard.set(serverURLString, forKey: Self.serverURLKey)
        }
    }

    var username: String {
        didSet {
            guard oldValue != username else { return }
            UserDefaults.standard.set(username, forKey: Self.usernameKey)
        }
    }

    /// The account's title as shown in Calendar/Bubo (e.g. «Яндекс»).
    /// Scopes verification to that account's events so calendars from
    /// other accounts that happen to share a title (an iCloud «Work» vs
    /// the server's «Work») are never touched. Required.
    var accountName: String {
        didSet {
            guard oldValue != accountName else { return }
            UserDefaults.standard.set(accountName, forKey: Self.accountNameKey)
        }
    }

    /// App password, stored in the Keychain — never in UserDefaults.
    /// Computed (Keychain-backed) like `AgentService.ownAPIKey`.
    var appPassword: String {
        get { Keychain.load(key: Self.keychainPasswordKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                Keychain.delete(key: Self.keychainPasswordKey)
            } else {
                Keychain.save(key: Self.keychainPasswordKey, value: trimmed)
            }
        }
    }

    // MARK: - Observable state

    /// Ghost keys from the last successful verification — occurrence or
    /// series ids in Bubo's `apple_…` scheme. Persisted so a cold start
    /// filters before the first verification completes.
    private(set) var ghostKeys: Set<String>
    private(set) var lastVerification: Date?
    private(set) var lastError: String?
    private(set) var isVerifying = false

    // MARK: - Wiring

    /// EventKit facts for the window, injected by the composition root
    /// (`AppleCalendarService.externalEventSyncKeys` in production).
    var externalEventKeysProvider: (Date, Date) -> [ExternalEventSyncKey] = { _, _ in [] }

    /// Fired whenever `ghostKeys` changes — `ReminderService` applies
    /// the new set to its visible slice.
    var onGhostKeysChanged: ((Set<String>) -> Void)?

    private let client: any CalDAVFetching
    private nonisolated(unsafe) var verifyTimer: Timer?

    // MARK: - Lifecycle

    init(client: any CalDAVFetching = CalDAVClient()) {
        self.client = client
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.serverURLString = defaults.string(forKey: Self.serverURLKey) ?? Self.defaultServerURL
        self.username = defaults.string(forKey: Self.usernameKey) ?? ""
        self.accountName = defaults.string(forKey: Self.accountNameKey) ?? ""
        self.ghostKeys = Set(defaults.stringArray(forKey: Self.ghostKeysKey) ?? [])
    }

    deinit {
        verifyTimer?.invalidate()
    }

    /// Arm the periodic verification. Safe to call when disabled — the
    /// guard keeps the timer off until the user opts in.
    func start() {
        verifyTimer?.invalidate()
        verifyTimer = nil
        guard isEnabled else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.verifyInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.verifyNow()
            }
        }
        timer.tolerance = 60
        verifyTimer = timer
        // First pass shortly after launch — give the EventKit sync a
        // moment to land so the comparison sees current local state.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            await self?.verifyNow()
        }
    }

    func stop() {
        verifyTimer?.invalidate()
        verifyTimer = nil
    }

    // MARK: - Verification

    func verifyNow() async {
        guard isEnabled, !isVerifying else { return }
        guard let baseURL = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)),
              baseURL.scheme?.hasPrefix("http") == true else {
            lastError = "Invalid server URL"
            return
        }
        let user = username.trimmingCharacters(in: .whitespaces)
        let password = appPassword
        guard !user.isEmpty, !password.isEmpty else {
            lastError = "Enter the username and app password"
            return
        }
        let account = accountName.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty else {
            lastError = "Select the Calendar account to verify"
            return
        }

        isVerifying = true
        defer { isVerifying = false }
        calDAVLogger.info("verification_started")

        let now = Date()
        let windowEnd = Calendar.current.date(
            byAdding: .day, value: ReminderService.fetchWindowDays, to: now
        ) ?? now
        // Pad the server query a day on both sides so timezone edges and
        // slightly-shifted events don't read as deletions.
        let serverFrom = now.addingTimeInterval(-86_400)
        let serverTo = windowEnd.addingTimeInterval(86_400)

        do {
            let calendars = try await client.discoverCalendars(
                baseURL: baseURL, username: user, password: password
            )
            var serverUIDs: [String: Set<String>] = [:]
            for calendar in calendars {
                do {
                    let uids = try await client.fetchEventUIDs(
                        calendar: calendar, baseURL: baseURL,
                        username: user, password: password,
                        from: serverFrom, to: serverTo
                    )
                    // Merge same-named collections — matching below is
                    // by display name, the only key EventKit shares.
                    serverUIDs[calendar.displayName, default: []].formUnion(uids)
                } catch {
                    // A calendar that failed to fetch is left out of the
                    // comparison entirely — its events stay visible.
                    calDAVLogger.warning("calendar_fetch_failed name=\(calendar.displayName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }

            let eventKeys = externalEventKeysProvider(now, windowEnd)
            let ghosts = Self.computeGhostKeys(
                events: eventKeys,
                serverUIDsByCalendarTitle: serverUIDs,
                accountName: account
            )
            lastError = nil
            lastVerification = Date()
            publishGhostKeys(ghosts)
            calDAVLogger.info("verification_completed calendars=\(serverUIDs.count) ghosts=\(ghosts.count)")
        } catch {
            // Discovery failed — keep the previous ghost set rather than
            // un-hiding known ghosts on a transient network error.
            lastError = error.localizedDescription
            calDAVLogger.error("verification_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pure comparison step, extracted for tests. An event is a ghost
    /// when: it belongs to the verified account, it carries a UID, its
    /// calendar was successfully fetched from the server, and the UID is
    /// absent there. The emitted key is the series key when present so a
    /// deleted recurring event disappears with all its occurrences.
    static func computeGhostKeys(
        events: [ExternalEventSyncKey],
        serverUIDsByCalendarTitle: [String: Set<String>],
        accountName: String
    ) -> Set<String> {
        var ghosts: Set<String> = []
        for event in events {
            guard event.accountName == accountName else { continue }
            guard let uid = event.uid else { continue }
            guard let serverUIDs = serverUIDsByCalendarTitle[event.calendarTitle] else { continue }
            if !serverUIDs.contains(uid) {
                ghosts.insert(event.seriesKey ?? event.occurrenceId)
            }
        }
        return ghosts
    }

    // MARK: - Publishing

    private func publishGhostKeys(_ keys: Set<String>) {
        guard keys != ghostKeys else { return }
        ghostKeys = keys
        UserDefaults.standard.set(Array(keys).sorted(), forKey: Self.ghostKeysKey)
        onGhostKeysChanged?(keys)
    }
}
