import CoreGraphics
import Darwin
import Foundation

struct AudioStallBackoff {
    private(set) var attemptCount = 0
    private var nextAttemptAt: TimeInterval = 0
    private var interval: TimeInterval = 5

    mutating func reset() {
        attemptCount = 0
        nextAttemptAt = 0
        interval = 5
    }

    mutating func attempt(at now: TimeInterval) -> Int? {
        guard now >= nextAttemptAt else { return nil }
        attemptCount += 1
        nextAttemptAt = now + interval
        interval = min(interval * 2, 60)
        return attemptCount
    }
}

enum EmulationLoopError: Error, Equatable {
    case stopped
}

final class EmulationLoop: @unchecked Sendable {
    typealias FrameRunner = (SELibretroHost?) -> Void

    private final class ImageSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?
        func publish(_ image: CGImage?) { lock.lock(); self.image = image; lock.unlock() }
        func take() -> CGImage? { lock.lock(); defer { lock.unlock() }; defer { image = nil }; return image }
    }

    private final class Box<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private let condition = NSCondition()
    private var commands: [() -> Void] = []
    private var stopped = false
    private var running = false
    private var host: SELibretroHost?
    private var thread: Thread!
    private var pacer: FramePacer
    private let maxCatchUpFrames: Int
    private let runFrame: FrameRunner
    private let imageSlot = ImageSlot()
    private let performanceStats: PerformanceStats?
    private let diagnosticsLog: DiagnosticsLog?
    private let logsFrameTime: Bool
    private let requestAudioRestart: ((SELibretroHost) -> Void)?
    private var hasRecordedRenderPath = false
    private var lastSummaryAt: TimeInterval?
    private var lastAudioCheckAt: TimeInterval = 0
    private var lastAudioProgressAt: TimeInterval = 0
    private var audioStallBackoff = AudioStallBackoff()
    private var lastAudioCallbackCount: UInt64 = 0
    private var audioWasEnabled = false

    init(
        framesPerSecond: Double = 60,
        maxCatchUpFrames: Int = 3,
        runFrame: @escaping FrameRunner = { $0?.runFrame() },
        performanceStats: PerformanceStats? = nil,
        diagnosticsLog: DiagnosticsLog? = nil,
        logsFrameTime: Bool = false,
        requestAudioRestart: ((SELibretroHost) -> Void)? = nil
    ) {
        pacer = FramePacer(framesPerSecond: framesPerSecond, maxCatchUpFrames: maxCatchUpFrames)
        self.maxCatchUpFrames = maxCatchUpFrames
        self.runFrame = runFrame
        self.performanceStats = performanceStats
        self.diagnosticsLog = diagnosticsLog
        self.logsFrameTime = logsFrameTime
        self.requestAudioRestart = requestAudioRestart
        thread = Thread { [weak self] in self?.threadMain() }
        thread.name = "SupersEmu.emulation"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func createHost(_ makeHost: @escaping () throws -> SELibretroHost) async throws -> SELibretroHost {
        try await performAsync { [weak self] _ in
            let host = try makeHost()
            self?.host = host
            return host
        }
    }

    func setFramesPerSecond(_ framesPerSecond: Double) {
        let semaphore = DispatchSemaphore(value: 0)
        guard enqueue({ [self] in
            pacer = FramePacer(framesPerSecond: framesPerSecond, maxCatchUpFrames: maxCatchUpFrames)
            pacer.reset(now: ProcessInfo.processInfo.systemUptime)
            semaphore.signal()
        }) else { return }
        semaphore.wait()
    }

    func perform<T>(_ work: @escaping (SELibretroHost?) throws -> T) throws -> T {
        if Thread.current === thread { return try work(host) }
        let box = Box<T>()
        let semaphore = DispatchSemaphore(value: 0)
        guard enqueue({ [self] in
            do { box.result = .success(try work(host)) }
            catch { box.result = .failure(error) }
            semaphore.signal()
        }) else { throw EmulationLoopError.stopped }
        semaphore.wait()
        return try box.result!.get()
    }

    func perform<T>(_ work: @escaping (SELibretroHost?) -> T) -> T? {
        if Thread.current === thread { return work(host) }
        let box = Box<T>()
        let semaphore = DispatchSemaphore(value: 0)
        guard enqueue({ [self] in
            box.result = .success(work(host))
            semaphore.signal()
        }) else { return nil }
        semaphore.wait()
        return try! box.result!.get()
    }

    func performAsync<T>(_ work: @escaping (SELibretroHost?) throws -> T) async throws -> T {
        let result: Result<T, Error> = await withCheckedContinuation { continuation in
            guard enqueue({ [self] in
                do { continuation.resume(returning: .success(try work(host))) }
                catch { continuation.resume(returning: .failure(error)) }
            }) else {
                continuation.resume(returning: .failure(EmulationLoopError.stopped))
                return
            }
        }
        return try result.get()
    }

    func start(running: Bool) { setRunning(running) }

    func setRunning(_ running: Bool) {
        if Thread.current === thread {
            self.running = running
            if running {
                pacer.reset(now: ProcessInfo.processInfo.systemUptime)
                lastSummaryAt = nil
            }
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        guard enqueue({ [self] in
            self.running = running
            if running {
                pacer.reset(now: ProcessInfo.processInfo.systemUptime)
                lastSummaryAt = nil
            }
            semaphore.signal()
        }) else { return }
        semaphore.wait()
    }

    func takeFrameImage() -> CGImage? { imageSlot.take() }

    func pacingMetrics() -> (catchUpFrames: Int, droppedFrames: Int)? {
        perform { [self] _ in (pacer.catchUpFrames, pacer.droppedFrames) }
    }

    func stop() {
        let semaphore = DispatchSemaphore(value: 0)
        condition.lock()
        guard !stopped else { condition.unlock(); return }
        commands.append { [self] in
            host?.shutdown()
            host = nil
            running = false
            condition.lock()
            stopped = true
            condition.broadcast()
            condition.unlock()
            semaphore.signal()
        }
        condition.signal()
        condition.unlock()
        semaphore.wait()
    }

    @discardableResult
    private func enqueue(_ command: @escaping () -> Void) -> Bool {
        condition.lock()
        guard !stopped else { condition.unlock(); return false }
        commands.append(command)
        condition.signal()
        condition.unlock()
        return true
    }

    private func threadMain() {
        while true {
            condition.lock()
            while commands.isEmpty && !stopped && !running { condition.wait() }
            let pending = commands
            commands.removeAll(keepingCapacity: true)
            let shouldStop = stopped
            condition.unlock()
            pending.forEach { $0() }
            if shouldStop { return }
            guard running else { continue }

            let now = ProcessInfo.processInfo.systemUptime
            checkAudioWatchdog(now: now)
            let step = pacer.step(now: now, rate: currentRate())
            if step.framesToRun == 0 {
                waitUntil(step.wakeAt)
                continue
            }

            var frames: [(TimeInterval, TimeInterval)] = []
            for _ in 0..<step.framesToRun {
                let start = ProcessInfo.processInfo.systemUptime
                runFrame(host)
                frames.append((start, ProcessInfo.processInfo.systemUptime - start))
            }
            for frame in frames where frame.1 > 0.05 {
                diagnosticsLog?.appendEvent(String(format: "long-frame ms=%.0f during=none", frame.1 * 1_000))
            }
            let imageStart = ProcessInfo.processInfo.systemUptime
            imageSlot.publish(host?.copyFrameImage())
            if let host, !hasRecordedRenderPath, host.frameWidth > 0 {
                hasRecordedRenderPath = true
                diagnosticsLog?.appendEvent("renderPath=\(host.renderPath) graphicsRenderer=\(host.graphicsRenderer ?? "nil")")
            }
            let present = ProcessInfo.processInfo.systemUptime - imageStart
            let nowFinished = ProcessInfo.processInfo.systemUptime
            if let host, let performanceStats {
                for (index, frame) in frames.enumerated() {
                    performanceStats.record(
                        runDuration: frame.1,
                        presentDuration: index == frames.count - 1 ? present : 0,
                        timestamp: frame.0,
                        framesPerSecond: host.framesPerSecond,
                        sampleRate: host.sampleRate,
                        audioUnderrunFrames: host.audioUnderrunFrames,
                        audioOverflowFrames: host.audioOverflowFrames,
                        bufferedAudioFrames: host.audioBufferedFrames,
                        catchUpFrames: pacer.catchUpFrames,
                        droppedFrames: pacer.droppedFrames,
                        rate: currentRate(),
                        audioRunning: host.audioEngineRunning)
                }
                if let lastSummaryAt, nowFinished - lastSummaryAt >= 5 {
                    let summary = performanceStats.summary(framesPerSecond: host.framesPerSecond, sampleRate: host.sampleRate)
                    let thermalState = Self.thermalStateName
                    diagnosticsLog?.appendPerformance(summary, thermalState: thermalState)
                    if logsFrameTime {
                        print(summary.performanceLine(thermalState: thermalState))
                        fflush(stdout)
                    }
                    self.lastSummaryAt = nowFinished
                } else if self.lastSummaryAt == nil {
                    self.lastSummaryAt = nowFinished
                }
            }
        }
    }

    private func currentRate() -> Double {
        guard let host else { return 1 }
        return AudioRateControl.rate(
            bufferedFrames: host.audioBufferedFrames,
            capacityFrames: host.audioCapacityFrames,
            engineRunning: host.audioEnabled && host.audioEngineRunning)
    }

    private func checkAudioWatchdog(now: TimeInterval) {
        guard now - lastAudioCheckAt >= 1 else { return }
        lastAudioCheckAt = now
        guard let host, host.audioEnabled else {
            audioWasEnabled = false
            lastAudioCallbackCount = 0
            lastAudioProgressAt = now
            audioStallBackoff.reset()
            return
        }
        let callbackCount = host.audioRenderCallbackCount
        guard audioWasEnabled else {
            audioWasEnabled = true
            lastAudioCallbackCount = callbackCount
            lastAudioProgressAt = now
            audioStallBackoff.reset()
            return
        }
        if callbackCount != lastAudioCallbackCount {
            lastAudioCallbackCount = callbackCount
            lastAudioProgressAt = now
            audioStallBackoff.reset()
            return
        }
        guard now - lastAudioProgressAt >= 1, let attempt = audioStallBackoff.attempt(at: now) else { return }
        diagnosticsLog?.appendEvent("audio stalled engineRunning=\(host.audioEngineRunning) attempt=\(attempt)")
        requestAudioRestart?(host)
    }

    private func waitUntil(_ uptime: TimeInterval) {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let now = ProcessInfo.processInfo.systemUptime
        let delta = max(uptime - now, 0)
        let ticks = UInt64(delta * 1_000_000_000 * Double(info.denom) / Double(info.numer))
        mach_wait_until(mach_absolute_time() + ticks)
    }

    private static var thermalStateName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
