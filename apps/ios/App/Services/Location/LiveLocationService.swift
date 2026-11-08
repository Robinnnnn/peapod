@preconcurrency import CoreLocation
import Combine
import Foundation

@MainActor
protocol LiveLocationManaging: AnyObject {
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var activityType: CLActivityType { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var authorizationStatus: CLAuthorizationStatus { get }

    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

extension CLLocationManager: LiveLocationManaging {}

enum LiveLocationStartError: LocalizedError, Equatable {
    case authorizationDenied
    case firstLocationTimedOut
    case stoppedBeforeFirstLocation
    case publishFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Location access is off. Enable it in Settings to share your location."
        case .firstLocationTimedOut:
            "Your location could not be found. Try again in a moment."
        case .stoppedBeforeFirstLocation:
            "Location sharing stopped before your location was available."
        case let .publishFailed(message):
            "Your location could not be shared. \(message)"
        }
    }
}

struct PreparedLiveLocation: Equatable, Sendable {
    let session: LiveLocationSession
    let point: LiveLocationPoint
}

struct LiveLocationSessionPersistence {
    private struct Descriptor: Codable {
        let id: UUID
        let messageID: UUID?
        let startedAt: Date
        let duration: LiveLocationDuration

        init?(_ session: LiveLocationSession) {
            id = session.id
            messageID = session.messageID
            startedAt = session.startedAt

            guard let expiresAt = session.expiresAt else {
                duration = .untilStopped
                return
            }
            let interval = expiresAt.timeIntervalSince(session.startedAt)
            guard
                let matchingDuration = LiveLocationDuration.allCases.first(
                    where: {
                        guard let expected = $0.timeInterval else {
                            return false
                        }
                        return abs(expected - interval) < 0.001
                    }
                )
            else {
                return nil
            }
            duration = matchingDuration
        }

        var session: LiveLocationSession {
            LiveLocationSession(
                id: id,
                messageID: messageID,
                startedAt: startedAt,
                duration: duration
            )
        }
    }

    private static let defaultKey = "live-location.active-session.v1"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = Self.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> LiveLocationSession? {
        guard
            let data = defaults.data(forKey: key),
            let descriptor = try? JSONDecoder().decode(
                Descriptor.self,
                from: data
            )
        else {
            return nil
        }
        return descriptor.session
    }

    func save(_ session: LiveLocationSession) {
        guard
            let descriptor = Descriptor(session),
            let data = try? JSONEncoder().encode(descriptor)
        else {
            clear()
            return
        }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

@MainActor
final class LiveLocationService: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case awaitingAuthorization
        case preparing(LiveLocationSession)
        case sharing(LiveLocationSession)
        case ended(LiveLocationSession, LiveLocationStopReason)

        var activeSession: LiveLocationSession? {
            guard case let .sharing(session) = self else {
                return nil
            }
            return session
        }
    }

    @Published private(set) var state: State = .idle {
        didSet {
            stateDidChange?(state)
        }
    }
    @Published private(set) var latestPublishedPoint: LiveLocationPoint?
    @Published private(set) var lastPublishError: String?
    var stateDidChange: ((State) -> Void)?

    private let manager: any LiveLocationManaging
    private var publisher: any LiveLocationPublishing
    private let policy: LiveLocationUpdatePolicy
    private let persistence: LiveLocationSessionPersistence
    private let now: @Sendable () -> Date

    private var pendingSession: LiveLocationSession?
    private var pendingRemoteFinish:
        (session: LiveLocationSession, reason: LiveLocationStopReason)?
    private var expiryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var activationUploadTask: Task<Void, any Error>?
    private var publisherIsConfigured: Bool
    private var firstLocationWaiter:
        (
            sessionID: UUID,
            continuation:
                CheckedContinuation<PreparedLiveLocation, any Error>
        )?
    private var firstLocationTimeoutTask: Task<Void, Never>?
    private var activationWaiter:
        (
            sessionID: UUID,
            continuation: CheckedContinuation<Void, any Error>
        )?

    init(
        manager: any LiveLocationManaging = CLLocationManager(),
        publisher: any LiveLocationPublishing = NoopLiveLocationPublisher(),
        policy: LiveLocationUpdatePolicy = .batteryBalanced,
        persistence: LiveLocationSessionPersistence =
            LiveLocationSessionPersistence(),
        restorePersistedSessionOnInit: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.manager = manager
        self.publisher = publisher
        self.policy = policy
        self.persistence = persistence
        self.now = now
        publisherIsConfigured = !(publisher is NoopLiveLocationPublisher)
        super.init()

        manager.delegate = self
        manager.activityType = .other
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = policy.minimumDistance
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = true
        // Encrypted composition defers location intent until explicit, scoped user action.
        // Skipping restoration leaves existing persistence untouched.
        if restorePersistedSessionOnInit { restorePersistedSessionIfNeeded() }
    }

    /// Starts a session only after a direct user action.
    func start(duration: LiveLocationDuration) {
        let sessionID = UUID()
        start(
            LiveLocationSession(
                id: sessionID,
                messageID: sessionID,
                startedAt: now(),
                duration: duration
            )
        )
    }

    /// Obtains a usable coordinate without persisting a session or publishing
    /// precise location. The caller establishes explicit sharing intent before
    /// activation so an interrupted preparation never resumes invisibly.
    func prepare(
        duration: LiveLocationDuration,
        timeout: TimeInterval = 20
    ) async throws -> PreparedLiveLocation {
        try Task.checkCancellation()

        let sessionID = UUID()
        let session = LiveLocationSession(
            id: sessionID,
            messageID: sessionID,
            startedAt: now(),
            duration: duration
        )

        if state.activeSession != nil || pendingSession != nil {
            stop(reason: .stoppedByUser)
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                firstLocationWaiter = (session.id, continuation)
                scheduleFirstLocationTimeout(
                    for: session,
                    timeout: timeout
                )
                startPreparing(session)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingStart(for: session)
            }
        }
    }

    /// Publishes the prepared point before making the session durable. If the
    /// app is interrupted earlier, relaunch has nothing to restore.
    func activate(_ preparation: PreparedLiveLocation) async throws {
        try Task.checkCancellation()

        let session = preparation.session
        guard
            pendingSession?.id == session.id,
            case let .preparing(preparingSession) = state,
            preparingSession.id == session.id,
            activationWaiter == nil
        else {
            throw LiveLocationStartError.stoppedBeforeFirstLocation
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                activationWaiter = (session.id, continuation)
                beginActivation(preparation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActivation(for: session)
            }
        }
    }

    private func beginActivation(_ preparation: PreparedLiveLocation) {
        let session = preparation.session
        let publisher = publisher
        let precedingUpload = uploadTask
        let firstUpload = Task {
            _ = await precedingUpload?.result
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            try await publisher.publishLatest(
                preparation.point,
                for: session
            )
        }
        activationUploadTask = firstUpload
        uploadTask = Task {
            _ = await firstUpload.result
        }
        Task { [weak self] in
            do {
                try await firstUpload.value
                self?.completeActivation(preparation)
            } catch {
                guard
                    self?.activationWaiter?.sessionID == session.id,
                    self?.pendingSession?.id == session.id
                else {
                    return
                }
                self?.failActivation(
                    for: session,
                    with: LiveLocationStartError.publishFailed(
                        error.localizedDescription
                    )
                )
                self?.lastPublishError = error.localizedDescription
                self?.end(session, reason: .locationUnavailable)
            }
        }
    }

    private func completeActivation(
        _ preparation: PreparedLiveLocation
    ) {
        let session = preparation.session
        guard
            let waiter = activationWaiter,
            waiter.sessionID == session.id,
            pendingSession?.id == session.id,
            case let .preparing(preparingSession) = state,
            preparingSession.id == session.id
        else {
            return
        }

        activationWaiter = nil
        activationUploadTask = nil
        pendingSession = nil
        latestPublishedPoint = preparation.point
        persistence.save(session)
        state = .sharing(session)
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        scheduleExpiry(for: session)
        scheduleHeartbeat(for: session)
        waiter.continuation.resume()
    }

    private func start(_ session: LiveLocationSession) {
        if state.activeSession != nil || pendingSession != nil {
            stop(reason: .stoppedByUser)
        }

        pendingSession = session
        latestPublishedPoint = nil
        lastPublishError = nil

        switch manager.authorizationStatus {
        case .notDetermined:
            state = .awaitingAuthorization
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            begin(session)
        case .denied, .restricted:
            end(session, reason: .authorizationDenied)
        @unknown default:
            end(session, reason: .authorizationDenied)
        }
    }

    private func startPreparing(_ session: LiveLocationSession) {
        pendingSession = session
        latestPublishedPoint = nil
        lastPublishError = nil

        switch manager.authorizationStatus {
        case .notDetermined:
            state = .awaitingAuthorization
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginPreparing(session)
        case .denied, .restricted:
            end(session, reason: .authorizationDenied)
        @unknown default:
            end(session, reason: .authorizationDenied)
        }
    }

    private func beginPreparing(_ session: LiveLocationSession) {
        guard
            pendingSession?.id == session.id,
            isWaitingForFirstLocation(of: session)
        else {
            return
        }
        state = .preparing(session)
        manager.startUpdatingLocation()
    }

    func configure(publisher: any LiveLocationPublishing) {
        self.publisher = publisher
        publisherIsConfigured = true

        // A restored session may have received a point while the app was
        // still resolving its conversation-specific publisher. Do not let
        // that in-memory point throttle the first real publication.
        if state.activeSession != nil {
            latestPublishedPoint = nil
        }

        if let pendingRemoteFinish {
            self.pendingRemoteFinish = nil
            finishRemotely(
                pendingRemoteFinish.session,
                reason: pendingRemoteFinish.reason,
                using: publisher
            )
        }
    }

    /// Call from a clear, separate UI action if uninterrupted background
    /// sharing proves important. Normal sharing works with When In Use access.
    func requestBackgroundAuthorization() {
        guard manager.authorizationStatus == .authorizedWhenInUse else {
            return
        }
        manager.requestAlwaysAuthorization()
    }

    func stop() {
        stop(reason: .stoppedByUser)
    }

    /// Idempotent so startup and lifecycle integration may safely call it
    /// more than once without adding another location update or expiry task.
    func restorePersistedSessionIfNeeded() {
        guard state.activeSession == nil, pendingSession == nil else {
            return
        }
        guard let session = persistence.load() else {
            return
        }
        guard session.isActive(at: now()) else {
            persistence.clear()
            state = .ended(session, .expired)
            finishRemotelyWhenConfigured(session, reason: .expired)
            return
        }
        guard session.messageID != nil else {
            // Builds before stable session linkage persisted an unrelated UUID.
            // Without a provable owner, fail closed instead of resuming precise
            // publishing after an update.
            persistence.clear()
            state = .ended(session, .stoppedByUser)
            finishRemotelyWhenConfigured(session, reason: .stoppedByUser)
            return
        }

        pendingSession = session
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .awaitingAuthorization
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            begin(session)
        case .denied, .restricted:
            end(session, reason: .authorizationDenied)
        @unknown default:
            end(session, reason: .authorizationDenied)
        }
    }

    private func begin(_ session: LiveLocationSession) {
        guard state.activeSession?.id != session.id else {
            return
        }
        guard session.isActive(at: now()) else {
            end(session, reason: .expired)
            return
        }

        pendingSession = nil
        persistence.save(session)
        state = .sharing(session)
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        scheduleExpiry(for: session)
        scheduleHeartbeat(for: session)
    }

    private func scheduleExpiry(for session: LiveLocationSession) {
        expiryTask?.cancel()
        guard let expiresAt = session.expiresAt else {
            expiryTask = nil
            return
        }
        let delay = max(0, expiresAt.timeIntervalSince(now()))

        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }
            self?.stop(reason: .expired)
        }
    }

    private func scheduleHeartbeat(for session: LiveLocationSession) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(
                            max(0.01, self?.policy.maximumTimeInterval ?? 120)
                        )
                    )
                } catch {
                    return
                }

                guard
                    !Task.isCancelled,
                    self?.state.activeSession?.id == session.id,
                    let point = self?.latestPublishedPoint
                else {
                    return
                }
                self?.enqueuePublish(point, for: session)
            }
        }
    }

    private func receive(_ point: LiveLocationPoint) {
        if
            let pendingSession,
            isWaitingForFirstLocation(of: pendingSession),
            policy.shouldPublish(point, after: nil)
        {
            completeFirstLocation(point, for: pendingSession)
        } else {
            accept(point)
        }
    }

    private func accept(_ point: LiveLocationPoint) {
        guard let session = state.activeSession else {
            return
        }
        guard session.isActive(at: now()) else {
            stop(reason: .expired)
            return
        }
        guard policy.shouldPublish(point, after: latestPublishedPoint) else {
            return
        }

        enqueuePublish(point, for: session)
    }

    private func enqueuePublish(
        _ point: LiveLocationPoint,
        for session: LiveLocationSession
    ) {
        let precedingUpload = uploadTask
        latestPublishedPoint = point
        lastPublishError = nil

        uploadTask = Task { [weak self, publisher] in
            _ = await precedingUpload?.result
            guard !Task.isCancelled else {
                return
            }

            do {
                try await publisher.publishLatest(point, for: session)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.lastPublishError = error.localizedDescription
            }
        }
    }

    private func stop(reason: LiveLocationStopReason) {
        guard let session = state.activeSession ?? pendingSession else {
            return
        }
        end(session, reason: reason)
    }

    private func end(
        _ session: LiveLocationSession,
        reason: LiveLocationStopReason
    ) {
        failFirstLocation(
            for: session,
            with: startError(for: reason)
        )
        failActivation(
            for: session,
            with: startError(for: reason)
        )
        pendingSession = nil
        persistence.clear()
        expiryTask?.cancel()
        expiryTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        activationUploadTask?.cancel()
        activationUploadTask = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        state = .ended(session, reason)

        finishRemotelyWhenConfigured(session, reason: reason)
    }

    private func finishRemotelyWhenConfigured(
        _ session: LiveLocationSession,
        reason: LiveLocationStopReason
    ) {
        guard publisherIsConfigured else {
            pendingRemoteFinish = (session, reason)
            return
        }
        finishRemotely(session, reason: reason, using: publisher)
    }

    private func finishRemotely(
        _ session: LiveLocationSession,
        reason: LiveLocationStopReason,
        using publisher: any LiveLocationPublishing
    ) {
        let precedingUpload = uploadTask
        uploadTask = Task {
            _ = await precedingUpload?.result
            guard !Task.isCancelled else {
                return
            }
            await publisher.finish(session, reason: reason)
        }
    }

    private func scheduleFirstLocationTimeout(
        for session: LiveLocationSession,
        timeout: TimeInterval
    ) {
        firstLocationTimeoutTask?.cancel()
        firstLocationTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(max(0, timeout))
                )
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                self?.isWaitingForFirstLocation(of: session) == true
            else {
                return
            }

            self?.failFirstLocation(
                for: session,
                with: LiveLocationStartError.firstLocationTimedOut
            )
            self?.end(session, reason: .locationUnavailable)
        }
    }

    private func isWaitingForFirstLocation(
        of session: LiveLocationSession
    ) -> Bool {
        firstLocationWaiter?.sessionID == session.id
    }

    private func completeFirstLocation(
        _ point: LiveLocationPoint,
        for session: LiveLocationSession
    ) {
        guard
            let waiter = firstLocationWaiter,
            waiter.sessionID == session.id
        else {
            return
        }
        firstLocationWaiter = nil
        firstLocationTimeoutTask?.cancel()
        firstLocationTimeoutTask = nil
        manager.stopUpdatingLocation()
        waiter.continuation.resume(
            returning: PreparedLiveLocation(
                session: session,
                point: point
            )
        )
    }

    private func failFirstLocation(
        for session: LiveLocationSession,
        with error: any Error
    ) {
        guard
            let waiter = firstLocationWaiter,
            waiter.sessionID == session.id
        else {
            return
        }
        firstLocationWaiter = nil
        firstLocationTimeoutTask?.cancel()
        firstLocationTimeoutTask = nil
        waiter.continuation.resume(throwing: error)
    }

    private func cancelPendingStart(for session: LiveLocationSession) {
        guard isWaitingForFirstLocation(of: session) else {
            return
        }
        failFirstLocation(
            for: session,
            with: CancellationError()
        )
        if state.activeSession?.id == session.id
            || pendingSession?.id == session.id {
            end(session, reason: .stoppedByUser)
        }
    }

    private func failActivation(
        for session: LiveLocationSession,
        with error: any Error
    ) {
        guard
            let waiter = activationWaiter,
            waiter.sessionID == session.id
        else {
            return
        }
        activationWaiter = nil
        waiter.continuation.resume(throwing: error)
    }

    private func cancelActivation(for session: LiveLocationSession) {
        guard activationWaiter?.sessionID == session.id else {
            return
        }
        failActivation(
            for: session,
            with: CancellationError()
        )
        if state.activeSession?.id == session.id
            || pendingSession?.id == session.id {
            end(session, reason: .stoppedByUser)
        }
    }

    private func startError(
        for reason: LiveLocationStopReason
    ) -> LiveLocationStartError {
        switch reason {
        case .authorizationDenied:
            .authorizationDenied
        case .stoppedByUser, .expired, .locationUnavailable:
            .stoppedBeforeFirstLocation
        }
    }
}

extension LiveLocationService: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch self.manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if let pendingSession {
                if isWaitingForFirstLocation(of: pendingSession) {
                    beginPreparing(pendingSession)
                } else {
                    begin(pendingSession)
                }
            }
        case .denied, .restricted:
            if state.activeSession != nil || pendingSession != nil {
                stop(reason: .authorizationDenied)
            }
        case .notDetermined:
            break
        @unknown default:
            if state.activeSession != nil || pendingSession != nil {
                stop(reason: .authorizationDenied)
            }
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let newest = locations.max(by: { $0.timestamp < $1.timestamp }) else {
            return
        }
        let point = LiveLocationPoint(location: newest)
        receive(point)
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        guard let locationError = error as? CLError else {
            lastPublishError = error.localizedDescription
            return
        }

        switch locationError.code {
        case .denied:
            stop(reason: .authorizationDenied)
        case .locationUnknown:
            // Transient; Core Location will keep trying.
            break
        default:
            lastPublishError = locationError.localizedDescription
        }
    }
}
