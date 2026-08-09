#!/bin/sh
# Captures live driver performance metrics and prints per-metric percentiles.
# Run it, interact with the touchscreen (taps, drags, with different apps
# focused), then wait for the duration or press Ctrl+C to stop early.
#
# Metrics are read from the driver's file log (driver.log) rather than
# Unified Logging, which requires admin rights to read on managed machines.
#
# Usage: ./Scripts/benchmark.sh [duration-seconds]   (default 60)
set -eu

duration="${1:-60}"
log_file="${HOME}/Library/Logs/MacXeneonEdgeTouchDriver/driver.log"
capture_file="$(mktemp -t xeneon-benchmark)"
label="com.ajvwhite.MacXeneonEdgeTouchDriver"

if [ ! -f "$log_file" ]; then
  echo "Driver log not found: ${log_file}" >&2
  exit 1
fi

if ! launchctl print "gui/$(id -u)/${label}" 2>/dev/null | grep -q "state = running"; then
  echo "Warning: driver LaunchAgent is not currently running; metrics will be empty." >&2
fi

echo "Capturing metrics from ${log_file} for ${duration}s."
echo "Interact with the touchscreen now: taps, drags, light apps and heavy apps focused."
echo "(Ctrl+C to stop early; captured samples are still summarized.)"
echo ""

summarize() {
  if [ ! -s "$capture_file" ]; then
    echo "No metric samples captured. Is the driver running and emitting metrics?"
    echo "Check: tail -5 '${log_file}'"
    rm -f "$capture_file"
    exit 0
  fi

  echo ""
  echo "=== Metric summary ==="
  awk '
    match($0, /metric=[a-z-]+/) {
      metric = substr($0, RSTART + 7, RLENGTH - 7)
      if (match($0, /duration_us=[0-9]+/)) {
        us = substr($0, RSTART + 12, RLENGTH - 12) + 0
        counts[metric]++
        values[metric, counts[metric]] = us
      }
      if (match($0, /verified=[01]/)) {
        verified[metric] += substr($0, RSTART + 9, 1) + 0
      }
    }
    END {
      for (metric in counts) {
        n = counts[metric]
        for (i = 1; i <= n; i++) sorted[i] = values[metric, i]
        # insertion sort; sample counts are small
        for (i = 2; i <= n; i++) {
          v = sorted[i]
          for (j = i - 1; j >= 1 && sorted[j] > v; j--) sorted[j + 1] = sorted[j]
          sorted[j + 1] = v
        }
        p50 = sorted[int((n - 1) * 0.50) + 1]
        p90 = sorted[int((n - 1) * 0.90) + 1]
        p99 = sorted[int((n - 1) * 0.99) + 1]
        line = sprintf("%-16s n=%-5d p50=%.1fms p90=%.1fms p99=%.1fms max=%.1fms", metric, n, p50 / 1000, p90 / 1000, p99 / 1000, sorted[n] / 1000)
        if (metric in verified) {
          line = line sprintf("  verified=%d/%d", verified[metric], n)
        }
        print line
      }
    }
  ' "$capture_file"

  echo ""
  echo "Raw capture kept at: ${capture_file}"
}

trap 'summarize; exit 0' INT

# Capture only lines written during the benchmark window; -n 0 skips history.
tail -n 0 -f "$log_file" > "$capture_file" &
tail_pid=$!
sleep "$duration"
kill "$tail_pid" 2>/dev/null || true

trap - INT
summarize
