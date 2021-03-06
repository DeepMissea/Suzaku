//
//  HashedWheelTimer.swift
//  Suzaku
//
//  Created by elijah.
//

import Foundation
import Darwin

/// Timeout class can be inherited and customized by external module
open class Timeout {
    
    /// Empty constant
    public static let omit = Timeout(timeInterval: -1, workItem: DispatchWorkItem(block: {}))
    
    fileprivate var remainingRounds: Int64 = 0
    fileprivate var solt: Int64 = 0
    fileprivate let timeInterval: Int64
    fileprivate private(set) var workItem: DispatchWorkItem
    
    /// Owning node
    fileprivate weak var node: LinkedListNode<Timeout>?
    
    /// Bucket to which node belongs
    fileprivate weak var bucket: HashedWheelBucket?
    
    /// Repative task whether it is
    fileprivate let reapting: Bool
    
    required public init(timeInterval: Int64, reapting: Bool = false, workItem: DispatchWorkItem) {
        self.timeInterval = timeInterval
        self.reapting = reapting
        self.workItem = workItem
    }
    
    public func performWork() {
        guard !workItem.isCancelled else { return }
        workItem.perform()
    }
    
    public func cancelWork() {
        guard !workItem.isCancelled else { return }
        workItem.cancel()
    }
    
    public func remove() {
        cancelWork()
        bucket?.remove(timeout: self)
    }
}

/// Timer error
public enum TimerError: Error {
    case invalideWheelNum(desc: String)
    case internalError(desc: String)
    case invalideTimeout(originTime: DispatchTimeInterval)
}

/// Timer, remember to call `stop` when you do not use timer anymore
open class HashedWheelTimer {
    private enum TimerState {
        case pause
        case resume
    }
    
    private var state: TimerState = .pause
    private let workerQueue: DispatchQueue
    private lazy var timer: DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource(flags: [], queue: workerQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(tickDuration)))
        timer.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        timer.setCancelHandler { [weak self] in
            self?.handleCancel()
        }
        return timer
    }()
    
    private var tickDuration: Int64 = 0
    private var ticksPerWheel: Int64 = 0
    
    /// Tick counter
    private var tick: Int64 = 0
    private var buckets: [HashedWheelBucket] = []
    /// self instance keeper
    private var keeper: Any?
    
    /// Timer constructor
    /// - Parameters:
    ///   - tickDuration: the duration between tick
    ///   - ticksPerWheel: solt num of wheel
    ///   - queue: callback queue
    public required init(tickDuration: DispatchTimeInterval, ticksPerWheel: Int64, dispatchQueue: DispatchQueue?) throws {
        workerQueue = dispatchQueue ?? DispatchQueue(label: "com.sazaku.timer")
        let duration = try normalize(timeInterval: tickDuration)
        self.tickDuration = duration
        buckets = try makeWheel(ticksPerWheel: ticksPerWheel)
        self.ticksPerWheel = ticksPerWheel
        keeper = self
        assert(buckets.count == ticksPerWheel)
    }
    
    deinit {
        if !buckets.isEmpty {
            removeAll()
        }
    }
    
    /// Add timeout task
    /// - Parameters:
    ///   - timeInterval: time interval
    ///   - reapting: Is it a repetitive task
    ///   - block: task
    /// - Throws: invalide time interval, throws TimerError.invalideTimeout
    /// - Returns: timeout object, if timeInterval == 0, do it instancly and return Timeout.omit
    @discardableResult public func addTimeout(timeInterval: DispatchTimeInterval, reapting: Bool = false, block: @escaping @convention(block) () -> Void) throws -> Timeout {
        let normalized = try normalize(timeInterval: timeInterval)
        if normalized == 0 { // normalized == 0, do it
            block()
            return Timeout.omit
        }
        guard normalized > 0 else {
            throw TimerError.invalideTimeout(originTime: timeInterval)
        }
        let timeout = Timeout(timeInterval: normalized, reapting: reapting, workItem: DispatchWorkItem(block: block))
        add(timeout: timeout)
        return timeout
    }
    
    /// remove the given `Timeout`
    /// - Parameter timeout: timeout
    public func remove(timeout: Timeout) {
        timeout.remove()
    }
    
    public func removeAll() {
        forEach { $0.remove() }
    }
    
    /// Iterate all timeout in HashedWheelTimer
    /// - Parameter body: A closure that takes an timeout of the HashedWheelTimer as a parameter.
    /// - Throws: rethrow body throw
    public func forEach(_ body: (Timeout) throws -> Void) rethrows {
        for bucket in buckets {
            guard !bucket.isEmpty else { continue }
            try bucket.forEach { try body($0.value) }
        }
    }
    
    // MARK: - timer operation
    public func resume() {
        if state == .pause {
            state = .resume
            timer.resume()
        }
    }
    
    public func pause() {
        if state == .resume {
            state = .pause
            timer.suspend()
        }
    }
    
    public func stop() {
        if 0 == __dispatch_source_testcancel(timer as! DispatchSource) {
            if state == .pause {
               resume()
            }
            timer.cancel()
            removeAll()
        }
    }
    
    // MARK: -
    private func handleEvent() {
        tick &+= 1
        let idx = tick & (ticksPerWheel - 1)
        let bucket = buckets[Int(idx)]
        try? bucket.excuteTimeouts(tick: tick)
    }
    
    private func handleCancel() {
        keeper = nil
    }
    
    // MARK: -
    private func makeWheel(ticksPerWheel: Int64) throws -> [HashedWheelBucket] {
        guard ticksPerWheel > 0 else {
            throw TimerError.invalideWheelNum(desc: "invalide num")
        }
        guard ticksPerWheel < (1 << 30) else {
            throw TimerError.invalideWheelNum(desc: "too big")
        }
        let num = normalize(ticksPerWheel: ticksPerWheel)
        return (0..<num).map { _ in
            let bucket = HashedWheelBucket()
            bucket.timer = self
            return bucket
        }
    }
    
    private func normalize(ticksPerWheel: Int64) -> Int {
        var normalized = 1
        while normalized < ticksPerWheel {
            normalized <<= 1
        }
        return normalized
    }
    
    private func normalize(timeInterval: DispatchTimeInterval) throws -> Int64 {
        var normalized = 0
        switch timeInterval {
        case .seconds(let time):
            normalized = time * Int(1e9)
        case .milliseconds(let time):
            normalized = time * Int(1e6)
        case .microseconds(let time):
            normalized = time * Int(1e3)
        case .nanoseconds(let time):
            normalized = time
        case .never:
            throw TimerError.invalideTimeout(originTime: timeInterval)
        @unknown default:
            throw TimerError.invalideTimeout(originTime: timeInterval)
        }
        return Int64(normalized)
    }
    
    private func hash(timeInterval: Int64) -> (Int64, Int64) {
        let total = timeInterval / tickDuration
        let rounds = total / ticksPerWheel
        let untilTicks = tick + total
        let solt = untilTicks & (ticksPerWheel - 1)
        return (rounds, solt)
    }
    
    fileprivate func add(timeout: Timeout) {
        let position = hash(timeInterval: timeout.timeInterval)
        guard (0..<ticksPerWheel).contains(position.1) else {
            assertionFailure()
            return
        }
        timeout.remainingRounds = position.0
        timeout.solt = position.1
        buckets[Int(timeout.solt)].add(timeout: timeout)
    }
}


private final class HashedWheelBucket {
    private let linkedList = LinkedList<Timeout>()
    fileprivate weak var timer: HashedWheelTimer?
    
    public var isEmpty: Bool {
        return linkedList.isEmpty
    }
    
    public func add(timeout: Timeout) {
        timeout.node = linkedList.append(timeout)
        timeout.bucket = self
    }
    
    public func remove(timeout: Timeout) {
        guard let node = timeout.node else {
            return
        }
        linkedList.remove(node: node)
    }
    
    public func removeAll() {
        linkedList.removeAll()
    }
    
    public func forEach(_ body: (LinkedListNode<Timeout>) throws -> Void) rethrows {
        try linkedList.forEach(body)
    }
    
    public func excuteTimeouts(tick: Int64) throws {
        guard !linkedList.isEmpty else { return }
        try linkedList.forEach {
            var remove = false
            let timeout = $0.value
            if timeout.remainingRounds <= 0 {
                if timeout.solt <= tick {
                    timeout.workItem.perform()
                } else {
                    throw TimerError.internalError(desc: "shoud never happen")
                }
                remove = true
            } else if timeout.workItem.isCancelled {
                remove = true
            } else {
                timeout.remainingRounds -= 1
            }
            if remove && !linkedList.isEmpty { // !linkedList.isEmpty dobule check
                linkedList.drop(node: $0)
                guard let timer = timer, timeout.reapting else { return }
                timer.add(timeout: timeout)
            }
        }
    }
}
