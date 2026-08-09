import Foundation
import os

/// Emits structured performance metrics through the driver's logging pipeline
/// (Unified Logging plus `driver.log`).
///
/// Each metric is one log line in a stable `metric=<name> key=value` format so
/// `Scripts/benchmark.sh` can capture and summarize them by tailing
/// `driver.log`. The file path is used because reading Unified Logging
/// requires admin rights on managed machines.
public enum DriverMetrics {
    /// Disable to keep benchmark runs of the core pipeline out of the logs.
    public static var isEnabled = true

    /// Records time from the HID down report arriving to the synthetic mouse-down being posted.
    public static func recordHIDToDown(durationUs: UInt64) {
        guard isEnabled else {
            return
        }

        DriverLoggers.log(.notice, category: .metrics, "metric=hid-to-down duration_us=\(durationUs)")
    }

    /// Records time from the HID up report arriving to the synthetic mouse-up being posted.
    public static func recordTapComplete(durationUs: UInt64) {
        guard isEnabled else {
            return
        }

        DriverLoggers.log(.notice, category: .metrics, "metric=tap-complete duration_us=\(durationUs)")
    }

    /// Records one focused-window restore: duration, whether the restore
    /// verified, and the deepest escalation stage reached.
    public static func recordFocusRestore(durationUs: UInt64, verified: Bool, stage: String) {
        guard isEnabled else {
            return
        }

        DriverLoggers.log(.notice, category: .metrics, "metric=focus-restore duration_us=\(durationUs) verified=\(verified ? 1 : 0) stage=\(stage)")
    }

    /// Records one target-window preparation before a mouse-down: duration,
    /// whether the target verified as focused, and which path ran.
    public static func recordPrepareTarget(durationUs: UInt64, verified: Bool, stage: String) {
        guard isEnabled else {
            return
        }

        DriverLoggers.log(.notice, category: .metrics, "metric=prepare-target duration_us=\(durationUs) verified=\(verified ? 1 : 0) stage=\(stage)")
    }

    /// Records one display mapping refresh and the reason it ran.
    public static func recordDisplayRefresh(durationUs: UInt64, reason: String) {
        guard isEnabled else {
            return
        }

        DriverLoggers.log(.notice, category: .metrics, "metric=display-refresh duration_us=\(durationUs) reason=\(reason)")
    }

    /// Returns whole microseconds elapsed since `start`, or zero if the clock has not advanced.
    public static func microseconds(since start: DispatchTime) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let startNanoseconds = start.uptimeNanoseconds
        guard now > startNanoseconds else {
            return 0
        }
        return (now - startNanoseconds) / 1_000
    }
}
