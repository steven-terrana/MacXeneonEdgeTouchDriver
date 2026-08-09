# Mac Xeneon Edge Touch Driver

A from-scratch macOS user-space touch driver for the Corsair Xeneon Edge 14.5 inch 32:9 touchscreen panel so you can make it genuinely useful when using it with a Mac.

## How To Install

To install for the current user, just run the following from the root of the checked out repository on the relevant mac:

```sh
./Scripts/install.sh
```

This builds the release binary, installs it under:

```text
~/Library/Application Support/MacXeneonEdgeTouchDriver/bin/MacXeneonEdgeTouchDriver
```

and installs the LaunchAgent at:

```text
~/Library/LaunchAgents/com.ajvwhite.MacXeneonEdgeTouchDriver.plist
```

No script uses `sudo`. Driver logs are written to:

```text
~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log
```

The LaunchAgent also creates `stdout.log` and `stderr.log` in the same directory for process-level output. The driver itself uses Unified Logging plus `driver.log`, so stdout and stderr are normally empty unless launchd or a lower-level runtime writes there.

The installer creates a default config file if one does not already exist:

```text
~/Library/Application Support/MacXeneonEdgeTouchDriver/config.json
```

Uninstall:

```sh
./Scripts/uninstall.sh
```

Uninstall removes the LaunchAgent and Application Support files but keeps logs.

Build a signed release binary:

```sh
./Scripts/build-release.sh
```

By default this uses ad-hoc signing. Set `CODESIGN_IDENTITY` for Developer ID signing and `NOTARIZATION_PROFILE` to submit the release archive with `xcrun notarytool`.

## Configuration

Optional config file:

```text
~/Library/Application Support/MacXeneonEdgeTouchDriver/config.json
```

All fields are optional. Missing or malformed config falls back to defaults and logs a warning.
`logLevel` only controls the minimum level written to `driver.log`; Unified Logging remains controlled by macOS logging configuration.

```json
{
  "logLevel": "info",
  "timing": {
    "warpToClickDelayMs": 10,
    "downToUpDelayMs": 20,
    "clickToWarpBackDelayMs": 10,
    "tapDebounceMs": 50,
    "stuckGestureTimeoutMs": 2000
  },
  "display": {
    "vendorNumber": 3672,
    "modelNumber": 60672,
    "serialNumber": null,
    "expectedWidth": 2560,
    "expectedHeight": 720
  },
  "gesture": {
    "multiTouchEnabled": false
  },
  "diagnostics": {
    "fileLogPath": "/Users/ajvwhite/Library/Logs/MacXeneonEdgeTouchDriver/driver.log",
    "fileLogMaxBytes": 5242880
  }
}
```

`gesture.multiTouchEnabled` is always forced to `false` as the hardware only exposes single touch information, if this ever changes we will look to see how to support multi-touch gestures.

## Benchmarking

Two layers of performance measurement are available.

Deterministic benchmarks drive the production pipeline with fake input/cursor
sinks, so results reflect driver code cost only and are comparable across
commits:

```sh
swift run -c release Benchmarks            # all scenarios
swift run -c release Benchmarks drag       # full-pipeline drag throughput
swift run -c release Benchmarks backlog    # move staleness under a slow sink
swift run -c release Benchmarks parser     # raw HID report parsing cost
```

To benchmark against real recorded touches, capture a HID trace and replay it
(`--paced` preserves the recorded inter-report timing):

```sh
swift run HIDDump --record trace.jsonl     # then tap/drag on the panel
swift run -c release Benchmarks replay trace.jsonl [--paced]
```

Live driver latency is measured through Unified Logging metrics that the
driver emits under the `metrics` category (`hid-to-down`, `tap-complete`,
`focus-restore`, `display-refresh`). With the driver installed and running:

```sh
./Scripts/benchmark.sh [duration-seconds]
```

then interact with the touchscreen. The script prints per-metric p50/p90/p99
percentiles when the capture window ends.

## Inactive Window Click-Through

On macOS, a click in an inactive window is not guaranteed to reach the clicked control:
AppKit consumes the initial mouse-down to activate the window unless the view opts into
`acceptsFirstMouse(for:)`. Before posting a synthetic mouse-down, the driver therefore
resolves the accessibility element at the mapped Xeneon coordinate and — only if its owning
window is not already focused — makes that application/window frontmost, focused, main, and
raised, waiting up to 50 ms for Accessibility to confirm. When the target is already focused
(the common case for repeated kiosk taps) this is a single read-only check. After the
gesture, the driver restores the exact window that was focused beforehand.

If a first tap is still activation-only, inspect `driver.log` for `Target window preparation
was incomplete`. The existing Accessibility permission covers both synthetic input and
target-window preparation.

## Known Caveats

- If the physical mouse is moved during a touch gesture, the cursor will return to the position captured when the touch began.
- Multi-contact gestures are not supported as the hardware doesn't report this information back.
- If the process is killed with `SIGKILL`, normal shutdown cleanup cannot run. Relaunching the driver or moving the physical mouse after cursor association is restored may be needed.

## Troubleshooting

- If the driver exits immediately, check Accessibility permission for the exact binary location as provided by the install script.
- If HID open fails, check Input Monitoring permission and confirm no other process has seized the same VID/PID device.
- If taps land on the wrong display, run `swift run DisplayInfo` and adjust the optional display config override.
- For HID investigation, use `swift run HIDDump`; it intentionally runs in non-seize mode and is separate from the production daemon.
