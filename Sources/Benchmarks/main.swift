import CoreGraphics
import Darwin
import Foundation
import MacXeneonEdgeTouchDriverCore

// Deterministic benchmarks for the touch pipeline. Drives the production
// application object with fake side-effect sinks so results reflect driver
// code cost, not CoreGraphics or Accessibility.
//
// Usage:
//   swift run -c release Benchmarks [drag|backlog|parser|all]
//   swift run -c release Benchmarks replay <trace.jsonl> [--paced]

private let xeneonBounds = CGRect(x: 0, y: 1_440, width: 2_560, height: 720)

private func xeneonSnapshot() -> DisplaySnapshot {
    DisplaySnapshot(
        displayID: 42,
        vendorNumber: 3_672,
        modelNumber: 60_672,
        serialNumber: 16_843_009,
        bounds: xeneonBounds,
        pixelsWide: 2_560,
        pixelsHigh: 720
    )
}

private final class BenchInputSink: SyntheticInputSink {
    /// Artificial per-drag-event processing cost, simulating a busy system.
    let dragDelayMicroseconds: UInt32

    /// Called with the drag point and processing timestamp for each drag event.
    var onDragProcessed: ((CGPoint, DispatchTime) -> Void)?

    private(set) var downCount = 0
    private(set) var upCount = 0
    private(set) var dragCount = 0
    private(set) var lastPoint: CGPoint = .zero

    init(dragDelayMicroseconds: UInt32 = 0) {
        self.dragDelayMicroseconds = dragDelayMicroseconds
    }

    func postMouseDown(at point: CGPoint) {
        downCount += 1
        lastPoint = point
    }

    func postMouseUp(at point: CGPoint) {
        upCount += 1
        lastPoint = point
    }

    func postMouseDragged(to point: CGPoint) {
        if dragDelayMicroseconds > 0 {
            usleep(dragDelayMicroseconds)
        }
        dragCount += 1
        lastPoint = point
        onDragProcessed?(point, DispatchTime.now())
    }
}

private final class BenchCursorController: CursorController {
    private(set) var borrowCount = 0
    private(set) var updateCount = 0
    private(set) var returnCount = 0

    func borrow(warpingTo point: CGPoint) -> Bool {
        borrowCount += 1
        return true
    }

    func updatePosition(_ point: CGPoint) {
        updateCount += 1
    }

    func returnToOrigin() {
        returnCount += 1
    }

    func forceShow() {}
}

private struct Percentiles {
    let count: Int
    let p50: Double
    let p90: Double
    let p99: Double
    let max: Double

    init?(microseconds: [Double]) {
        guard !microseconds.isEmpty else {
            return nil
        }

        let sorted = microseconds.sorted()
        count = sorted.count
        p50 = sorted[Int(Double(sorted.count - 1) * 0.50)]
        p90 = sorted[Int(Double(sorted.count - 1) * 0.90)]
        p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        max = sorted[sorted.count - 1]
    }

    func printRows(label: String) {
        print(String(format: "  %@: n=%d p50=%.1fus p90=%.1fus p99=%.1fus max=%.1fus", label, count, p50, p90, p99, max))
    }
}

/// Pairs processed drag points with their enqueue timestamps to measure
/// staleness. Keyed by mapped point because coalescing legitimately drops
/// superseded moves, so indices no longer line up.
private final class StalenessTracker {
    private let lock = NSLock()
    private var enqueueTimes: [String: DispatchTime] = [:]
    private(set) var samples: [Double] = []

    private func key(_ point: CGPoint) -> String {
        String(format: "%.3f,%.3f", point.x, point.y)
    }

    func recordEnqueue(rawX: Int, rawY: Int, timestamp: DispatchTime, mapper: CoordinateMapper) {
        let point = mapper.map(rawX: rawX, rawY: rawY)
        lock.lock()
        enqueueTimes[key(point)] = timestamp
        lock.unlock()
    }

    func recordProcessed(point: CGPoint, at processedAt: DispatchTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let enqueued = enqueueTimes.removeValue(forKey: key(point)) else {
            return
        }
        samples.append(elapsedMicroseconds(from: enqueued, to: processedAt))
    }
}

private struct BenchHarness {
    let application: MacXeneonEdgeTouchDriverApplication
    let inputSink: BenchInputSink
    let cursorController: BenchCursorController

    init(dragDelayMicroseconds: UInt32 = 0) {
        let configuration = DriverConfiguration.defaults
        inputSink = BenchInputSink(dragDelayMicroseconds: dragDelayMicroseconds)
        cursorController = BenchCursorController()
        application = MacXeneonEdgeTouchDriverApplication(
            configuration: configuration,
            displayResolver: DisplayResolver(
                configuration: configuration.display,
                activeDisplayProvider: { [xeneonSnapshot()] }
            ),
            inputSink: inputSink,
            cursorController: cursorController,
            focusRestorer: NoOpFocusRestorer()
        )
    }
}

private func makeDragStream(moveCount: Int) -> [TouchEvent] {
    var events: [TouchEvent] = []
    events.reserveCapacity(moveCount + 2)
    events.append(TouchEvent(kind: .down, contactID: 0, rawX: 100, rawY: 100, timestamp: .now()))

    for index in 0..<moveCount {
        let progress = Double(index) / Double(max(moveCount - 1, 1))
        events.append(
            TouchEvent(
                kind: .move,
                contactID: 0,
                rawX: 100 + Int(progress * 15_000),
                rawY: 100 + Int(progress * 9_000),
                timestamp: .now()
            )
        )
    }

    events.append(TouchEvent(kind: .up, contactID: 0, rawX: 15_100, rawY: 9_100, timestamp: .now()))
    return events
}

private func elapsedMicroseconds(from start: DispatchTime, to end: DispatchTime) -> Double {
    Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000
}

/// Full-pipeline throughput: bursts a drag stream through the production
/// application path (queue hop, mapper lookup, gesture state machine, and the
/// per-event stuck-gesture timer scheduling).
private func runDragThroughput(moveCount: Int) {
    print("== drag throughput (\(moveCount) moves, burst) ==")
    let harness = BenchHarness()

    // Warm up queue and mapper resolution outside the measured window.
    harness.application.enqueueTouchEvent(TouchEvent(kind: .down, contactID: 0, rawX: 0, rawY: 0, timestamp: .now()))
    harness.application.enqueueTouchEvent(TouchEvent(kind: .up, contactID: 0, rawX: 0, rawY: 0, timestamp: .now()))
    harness.application.drainGestureQueue()
    usleep(100_000)

    let tracker = StalenessTracker()
    let mapper = CoordinateMapper(displayBounds: xeneonBounds)
    harness.inputSink.onDragProcessed = { point, processedAt in
        tracker.recordProcessed(point: point, at: processedAt)
    }

    let start = DispatchTime.now()
    for event in makeDragStream(moveCount: moveCount) {
        if event.kind == .move {
            tracker.recordEnqueue(rawX: event.rawX, rawY: event.rawY, timestamp: event.timestamp, mapper: mapper)
        }
        harness.application.enqueueTouchEvent(event)
    }
    harness.application.drainGestureQueue()
    let totalUs = elapsedMicroseconds(from: start, to: .now())

    let eventCount = moveCount + 2
    print(String(format: "  total=%.1fms events=%d mean=%.2fus/event throughput=%.0f events/s", totalUs / 1_000, eventCount, totalUs / Double(eventCount), Double(eventCount) / (totalUs / 1_000_000)))
    Percentiles(microseconds: tracker.samples)?.printRows(label: "processed-move staleness")
    print("  posted: down=\(harness.inputSink.downCount - 1) drags=\(harness.inputSink.dragCount) up=\(harness.inputSink.upCount - 1) (coalescing drops superseded moves)")
    print("")
}

/// Backlog behavior: the sink simulates a busy system (fixed cost per drag
/// event) while a burst of moves arrives. Without move coalescing, staleness
/// grows linearly with queue depth; with it, staleness stays bounded.
private func runBacklogStaleness(moveCount: Int, sinkDelayMicroseconds: UInt32) {
    print("== backlog staleness (\(moveCount) moves, \(sinkDelayMicroseconds)us sink delay) ==")
    let harness = BenchHarness(dragDelayMicroseconds: sinkDelayMicroseconds)

    harness.application.enqueueTouchEvent(TouchEvent(kind: .down, contactID: 0, rawX: 0, rawY: 0, timestamp: .now()))
    harness.application.enqueueTouchEvent(TouchEvent(kind: .up, contactID: 0, rawX: 0, rawY: 0, timestamp: .now()))
    harness.application.drainGestureQueue()
    usleep(100_000)

    let tracker = StalenessTracker()
    let mapper = CoordinateMapper(displayBounds: xeneonBounds)
    harness.inputSink.onDragProcessed = { point, processedAt in
        tracker.recordProcessed(point: point, at: processedAt)
    }

    for event in makeDragStream(moveCount: moveCount) {
        if event.kind == .move {
            tracker.recordEnqueue(rawX: event.rawX, rawY: event.rawY, timestamp: event.timestamp, mapper: mapper)
        }
        harness.application.enqueueTouchEvent(event)
    }
    harness.application.drainGestureQueue()

    Percentiles(microseconds: tracker.samples)?.printRows(label: "processed-move staleness")
    let expectedFinal = CoordinateMapper(displayBounds: xeneonBounds).map(rawX: 15_100, rawY: 9_100)
    print("  final point ok: \(harness.inputSink.lastPoint == expectedFinal) (moves processed: \(harness.inputSink.dragCount)/\(moveCount); coalescing drops superseded moves)")
    print("")
}

/// Raw HID report parsing cost, isolated from the gesture pipeline.
private func runParserThroughput(iterations: Int) {
    print("== parser throughput (\(iterations) reports) ==")
    let parser = HIDValueParser()
    var report: [UInt8] = [0x07, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
    var parsedCount = 0

    let start = DispatchTime.now()
    for index in 0..<iterations {
        let x = index % 16_384
        let y = index % 9_600
        report[1] = index % 50 == 49 ? 0 : 1
        report[2] = UInt8(x & 0xFF)
        report[3] = UInt8((x >> 8) & 0xFF)
        report[4] = UInt8(y & 0xFF)
        report[5] = UInt8((y >> 8) & 0xFF)

        if parser.parseReport(reportID: 7, bytes: report, timestamp: .now()) != nil {
            parsedCount += 1
        }
    }
    let totalUs = elapsedMicroseconds(from: start, to: .now())

    print(String(format: "  total=%.1fms mean=%.0fns/report events=%d", totalUs / 1_000, totalUs * 1_000 / Double(iterations), parsedCount))
    print("")
}

private struct TraceRecord {
    let elapsedMicroseconds: UInt64
    let reportID: Int
    let bytes: [UInt8]
}

private func loadTrace(path: String) throws -> [TraceRecord] {
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    var records: [TraceRecord] = []

    for line in contents.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elapsed = object["elapsed_us"] as? NSNumber,
              let reportID = object["report_id"] as? NSNumber,
              let hexBytes = object["bytes"] as? String else {
            continue
        }

        let bytes = hexBytes.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        records.append(
            TraceRecord(
                elapsedMicroseconds: elapsed.uint64Value,
                reportID: reportID.intValue,
                bytes: bytes
            )
        )
    }

    return records
}

/// Replays a HID trace recorded with `swift run HIDDump --record <path>`
/// through the parser and the production application path.
private func runTraceReplay(path: String, paced: Bool) throws {
    let records = try loadTrace(path: path)
    guard !records.isEmpty else {
        print("Trace contains no parseable records: \(path)")
        return
    }

    print("== trace replay (\(records.count) reports, \(paced ? "paced" : "burst")) ==")
    let harness = BenchHarness()
    let parser = HIDValueParser()

    let tracker = StalenessTracker()
    let mapper = CoordinateMapper(displayBounds: xeneonBounds)
    harness.inputSink.onDragProcessed = { point, processedAt in
        tracker.recordProcessed(point: point, at: processedAt)
    }

    var eventCounts: [TouchEvent.Kind: Int] = [:]
    let replayStart = DispatchTime.now()
    var previousElapsed: UInt64 = records[0].elapsedMicroseconds

    for record in records {
        if paced, record.elapsedMicroseconds > previousElapsed {
            usleep(UInt32(min(record.elapsedMicroseconds - previousElapsed, 1_000_000)))
        }
        previousElapsed = record.elapsedMicroseconds

        guard let event = parser.parseReport(reportID: record.reportID, bytes: record.bytes, timestamp: .now()) else {
            continue
        }

        eventCounts[event.kind, default: 0] += 1
        if event.kind == .move {
            tracker.recordEnqueue(rawX: event.rawX, rawY: event.rawY, timestamp: event.timestamp, mapper: mapper)
        }
        harness.application.enqueueTouchEvent(event)
    }
    harness.application.drainGestureQueue()
    let totalUs = elapsedMicroseconds(from: replayStart, to: .now())

    print(String(format: "  total=%.1fms downs=%d moves=%d ups=%d", totalUs / 1_000, eventCounts[.down] ?? 0, eventCounts[.move] ?? 0, eventCounts[.up] ?? 0))
    Percentiles(microseconds: tracker.samples)?.printRows(label: "processed-move staleness")
    print("  posted: downs=\(harness.inputSink.downCount) drags=\(harness.inputSink.dragCount) ups=\(harness.inputSink.upCount) (coalescing drops superseded moves)")
    print("")
}

// Keep benchmark runs of the pipeline out of Unified Logging.
DriverMetrics.isEnabled = false
setbuf(stdout, nil)

let arguments = Array(CommandLine.arguments.dropFirst())
let scenario = arguments.first ?? "all"

switch scenario {
case "drag":
    runDragThroughput(moveCount: 10_000)

case "backlog":
    runBacklogStaleness(moveCount: 500, sinkDelayMicroseconds: 2_000)

case "parser":
    runParserThroughput(iterations: 1_000_000)

case "replay":
    guard arguments.count >= 2 else {
        fputs("Usage: Benchmarks replay <trace.jsonl> [--paced]\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try runTraceReplay(path: arguments[1], paced: arguments.contains("--paced"))
    } catch {
        fputs("Could not replay trace: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }

case "all":
    runDragThroughput(moveCount: 10_000)
    runBacklogStaleness(moveCount: 500, sinkDelayMicroseconds: 2_000)
    runParserThroughput(iterations: 1_000_000)

default:
    fputs("Unknown scenario: \(scenario)\nUsage: Benchmarks [drag|backlog|parser|all] | replay <trace.jsonl> [--paced]\n", stderr)
    exit(EXIT_FAILURE)
}
