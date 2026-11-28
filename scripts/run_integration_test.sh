#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 IMFX TECH LTDA
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Runs the Android integration test with a hard time limit and collects
# logcat, the flutter test output, a screenshot and the activity/window
# state into $INTEGRATION_LOG_DIR, so a hang fails with evidence instead of
# blocking the CI job until it is cancelled.
set -u
OUT="${INTEGRATION_LOG_DIR:-integration_test_logs}"
LIMIT="${INTEGRATION_TEST_TIMEOUT:-22m}"
mkdir -p "$OUT"

adb logcat -c || true
adb logcat -v threadtime > "$OUT/logcat.txt" 2>&1 &
LOGCAT_PID=$!

timeout --kill-after=30s "$LIMIT" \
  flutter test integration_test/mobile_test.dart -v --reporter expanded 2>&1 | tee "$OUT/flutter_test.txt"
rc=${PIPESTATUS[0]}

adb exec-out screencap -p > "$OUT/screen.png" 2>/dev/null || true
adb shell dumpsys activity activities > "$OUT/activities.txt" 2>&1 || true
adb shell dumpsys window > "$OUT/window.txt" 2>&1 || true
kill "$LOGCAT_PID" 2>/dev/null || true

if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  echo "::error::flutter test passou de $LIMIT. Veja logcat.txt e flutter_test.txt no artefato integration-test-logs."
fi
exit "$rc"
