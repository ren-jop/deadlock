import Foundation
import CoreMotion
import DeadlockShared

struct BedGuardSensorSnapshot: Equatable {
    var monitoring = false
    var connected = false
    var authorizationDenied = false
    var lastAngleDegrees: Double?
    var heldSeconds: Double = 0
    var calibrating = false
    var calibrationProgress: Double = 0
    var message = "Bed Guard idle"
}

private enum BedGuardSensorError: LocalizedError {
    case noMotion
    case calibrationTimedOut
    case movedTooMuch

    var errorDescription: String? {
        switch self {
        case .noMotion:
            return "Connect and wear motion-capable AirPods, then try again."
        case .calibrationTimedOut:
            return "No usable AirPods motion arrived during calibration."
        case .movedTooMuch:
            return "Your head moved too much during calibration. Hold your normal bed position steadily and try again."
        }
    }
}

final class AirPodsBedGuard: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "deadlock.airpods-motion"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var settings = BedGuardSettings.defaultSettings
    private var snapshot = BedGuardSensorSnapshot()
    private var matchedSince: Date?
    private var lastTriggerAt: Date?
    private var lastMotionDeliveryAt: Date?

    private var calibrationStartedAt: Date?
    private var calibrationSamples: [BedGuardVector] = []
    private var calibrationToken = UUID()
    private var calibrationCompletion: ((Result<BedGuardVector, Error>) -> Void)?

    private let onSnapshot: (BedGuardSensorSnapshot) -> Void
    private let onTrigger: () -> Void

    init(
        onSnapshot: @escaping (BedGuardSensorSnapshot) -> Void,
        onTrigger: @escaping () -> Void
    ) {
        self.onSnapshot = onSnapshot
        self.onTrigger = onTrigger
        super.init()
        manager.delegate = self
    }

    deinit {
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
    }

    func update(settings: BedGuardSettings) {
        self.settings = settings
        matchedSince = nil
        snapshot.heldSeconds = 0

        if settings.enabled || calibrationStartedAt != nil {
            ensureMonitoring()
        } else {
            stopMonitoring()
            snapshot.message = settings.poses.isEmpty
                ? "Record a bed posture to set up Bed Guard."
                : "Bed Guard calibrated but off."
            publish()
        }
    }

    func captureCurrentPose(
        completion: @escaping (Result<BedGuardVector, Error>) -> Void
    ) {
        if calibrationStartedAt != nil {
            completion(.failure(BedGuardSensorError.calibrationTimedOut))
            return
        }

        calibrationStartedAt = Date()
        calibrationSamples = []
        calibrationCompletion = completion
        calibrationToken = UUID()
        let token = calibrationToken

        snapshot.calibrating = true
        snapshot.calibrationProgress = 0
        snapshot.message = "Calibrating bed posture…"
        publish()
        ensureMonitoring()

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self,
                  self.calibrationToken == token,
                  self.calibrationStartedAt != nil
            else { return }
            self.finishCalibration(.failure(BedGuardSensorError.calibrationTimedOut))
        }
    }

    func headphoneMotionManagerDidConnect(
        _ manager: CMHeadphoneMotionManager
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot.connected = true
            self.startMotionIfAvailable()
        }
    }

    func headphoneMotionManagerDidDisconnect(
        _ manager: CMHeadphoneMotionManager
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.matchedSince = nil
            self.snapshot.connected = false
            self.snapshot.monitoring = false
            self.snapshot.heldSeconds = 0
            self.snapshot.lastAngleDegrees = nil
            self.snapshot.message = "Waiting for motion-capable AirPods…"
            self.publish()
        }
    }

    private func ensureMonitoring() {
        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        if authorization == .denied || authorization == .restricted {
            snapshot.authorizationDenied = true
            snapshot.monitoring = false
            snapshot.message = "AirPods motion permission is denied."
            publish()
            return
        }

        snapshot.authorizationDenied = false
        if !manager.isConnectionStatusActive {
            manager.startConnectionStatusUpdates()
        }
        startMotionIfAvailable()
    }

    private func startMotionIfAvailable() {
        guard manager.isDeviceMotionAvailable else {
            snapshot.connected = false
            snapshot.monitoring = false
            snapshot.message = "Waiting for motion-capable AirPods…"
            publish()
            return
        }

        snapshot.connected = true
        guard !manager.isDeviceMotionActive else {
            snapshot.monitoring = true
            publish()
            return
        }

        manager.startDeviceMotionUpdates(to: motionQueue) {
            [weak self] motion, error in
            guard let self else { return }

            if let error {
                DispatchQueue.main.async {
                    self.handleMotionError(error)
                }
                return
            }
            guard let motion else { return }

            // Headphone motion can arrive at a high rate. Five-ish samples per
            // second are enough for posture detection and keep SwiftUI quiet.
            let now = Date()
            if let last = self.lastMotionDeliveryAt,
               now.timeIntervalSince(last) < 0.18 {
                return
            }
            self.lastMotionDeliveryAt = now

            guard let vector = self.normalized(
                BedGuardVector(
                    x: motion.gravity.x,
                    y: motion.gravity.y,
                    z: motion.gravity.z
                )
            ) else { return }

            DispatchQueue.main.async {
                self.consume(vector, at: now)
            }
        }

        snapshot.monitoring = true
        snapshot.message = "AirPods connected — Bed Guard monitoring."
        publish()
    }

    private func stopMonitoring() {
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
        snapshot.monitoring = false
        snapshot.connected = false
        snapshot.lastAngleDegrees = nil
        matchedSince = nil
    }

    private func handleMotionError(_ error: Error) {
        manager.stopDeviceMotionUpdates()
        snapshot.monitoring = false
        snapshot.message = "AirPods motion paused: \(error.localizedDescription)"
        publish()

        guard settings.enabled || calibrationStartedAt != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.ensureMonitoring()
        }
    }

    private func consume(_ vector: BedGuardVector, at now: Date) {
        snapshot.monitoring = true
        snapshot.connected = true

        if let started = calibrationStartedAt {
            calibrationSamples.append(vector)
            let elapsed = now.timeIntervalSince(started)
            snapshot.calibrationProgress = min(1, elapsed / 5)
            snapshot.message = "Calibrating bed posture…"

            if elapsed >= 5 {
                completeCalibrationFromSamples()
                return
            }
            publish()
        }

        guard settings.enabled, !settings.poses.isEmpty else {
            if calibrationStartedAt == nil {
                snapshot.message = settings.poses.isEmpty
                    ? "Record a bed posture to set up Bed Guard."
                    : "Bed Guard calibrated but off."
                publish()
            }
            return
        }

        let angle = settings.poses
            .compactMap { normalized($0) }
            .map { angleDegrees(vector, $0) }
            .min()

        snapshot.lastAngleDegrees = angle
        guard let angle, angle <= settings.matchAngleDegrees else {
            matchedSince = nil
            snapshot.heldSeconds = 0
            snapshot.message = "AirPods connected — not in a saved bed posture."
            publish()
            return
        }

        if matchedSince == nil {
            matchedSince = now
        }
        let held = now.timeIntervalSince(matchedSince ?? now)
        snapshot.heldSeconds = held
        snapshot.message = "Bed posture detected — get up."

        if held >= settings.sustainSeconds {
            let canTrigger = lastTriggerAt.map {
                now.timeIntervalSince($0) >= max(12, settings.sustainSeconds / 2)
            } ?? true

            if canTrigger {
                lastTriggerAt = now
                matchedSince = nil
                snapshot.heldSeconds = 0
                snapshot.message = "Bed Guard triggered sleep."
                publish()
                onTrigger()
                return
            }
        }

        publish()
    }

    private func completeCalibrationFromSamples() {
        guard calibrationSamples.count >= 20 else {
            finishCalibration(.failure(BedGuardSensorError.noMotion))
            return
        }

        let x = calibrationSamples.reduce(0) { $0 + $1.x }
        let y = calibrationSamples.reduce(0) { $0 + $1.y }
        let z = calibrationSamples.reduce(0) { $0 + $1.z }
        guard let average = normalized(BedGuardVector(x: x, y: y, z: z)) else {
            finishCalibration(.failure(BedGuardSensorError.noMotion))
            return
        }

        let meanDeviation =
            calibrationSamples
                .map { angleDegrees($0, average) }
                .reduce(0, +)
                / Double(calibrationSamples.count)

        guard meanDeviation <= 12 else {
            finishCalibration(.failure(BedGuardSensorError.movedTooMuch))
            return
        }

        finishCalibration(.success(average))
    }

    private func finishCalibration(
        _ result: Result<BedGuardVector, Error>
    ) {
        let completion = calibrationCompletion
        calibrationStartedAt = nil
        calibrationSamples = []
        calibrationCompletion = nil
        calibrationToken = UUID()
        snapshot.calibrating = false
        snapshot.calibrationProgress = 0

        switch result {
        case .success:
            snapshot.message = "Bed posture recorded."
        case .failure(let error):
            snapshot.message = error.localizedDescription
        }
        publish()

        completion?(result)

        if !settings.enabled {
            stopMonitoring()
            publish()
        }
    }

    private func normalized(
        _ vector: BedGuardVector
    ) -> BedGuardVector? {
        guard vector.x.isFinite,
              vector.y.isFinite,
              vector.z.isFinite
        else { return nil }

        let magnitude = sqrt(
            vector.x * vector.x
                + vector.y * vector.y
                + vector.z * vector.z
        )
        guard magnitude > 0.5 else { return nil }

        return BedGuardVector(
            x: vector.x / magnitude,
            y: vector.y / magnitude,
            z: vector.z / magnitude
        )
    }

    private func angleDegrees(
        _ lhs: BedGuardVector,
        _ rhs: BedGuardVector
    ) -> Double {
        let dot = min(
            1,
            max(
                -1,
                lhs.x * rhs.x
                    + lhs.y * rhs.y
                    + lhs.z * rhs.z
            )
        )
        return acos(dot) * 180 / .pi
    }

    private func publish() {
        onSnapshot(snapshot)
    }
}
