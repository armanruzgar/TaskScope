#!/usr/bin/env bash
set -euo pipefail

IMAGES=(main-window-light.png main-window-dark.png menu-bar-presets-light.png menu-bar-presets-dark.png)

usage() {
  cat <<EOF
usage: $0 [--output DIR]
Renders the README screenshots from synthetic data: ${IMAGES[*]}.
It runs one test, ReadmeScreenshotTests/testRenderReadmeScreenshots, with
TASKSCOPE_RENDER_SCREENSHOTS=1. The test draws the app's real views into
off-screen windows from fixed fake processes: nothing is launched, no window
is shown, and the screen is never captured, so no real process list can
appear in the images.
Default output: docs/images. --output DIR writes the images to DIR instead
(created if missing), for example to look at them before replacing the README's.
Needs Xcode 26 or later and a Retina main display (the images are 2x).
EOF
}

OUTPUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --output)
      if [[ $# -lt 2 || -z "$2" || -n "$OUTPUT_DIR" ]]; then
        usage >&2
        exit 2
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/docs/images}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/taskscope-screenshots.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
STAMP="$WORK_DIR/stamp"
LOG="$WORK_DIR/test.log"
touch "$STAMP"
# Modification times have one-second resolution in the check below.
sleep 1

cd "$ROOT_DIR"
test_status=0
TASKSCOPE_RENDER_SCREENSHOTS=1 TASKSCOPE_SCREENSHOT_DIR="$OUTPUT_DIR" \
  swift test --filter 'ReadmeScreenshotTests/testRenderReadmeScreenshots' 2>&1 | tee "$LOG" \
  || test_status="$?"
if [[ "$test_status" -ne 0 ]]; then
  echo "Rendering failed (swift test exited with $test_status); the images were not all replaced." >&2
  exit 1
fi
# A filter that matches nothing, or a skipped test ("Executed 1 test, with
# 1 test skipped and 0 failures"), also exits 0.
if ! grep -q 'Executed 1 test, with 0 failures' "$LOG"; then
  echo "The rendering test did not run; no image was rendered." >&2
  exit 1
fi
for image in "${IMAGES[@]}"; do
  if [[ ! -s "$OUTPUT_DIR/$image" || ! "$OUTPUT_DIR/$image" -nt "$STAMP" ]]; then
    echo "The test did not write $OUTPUT_DIR/$image." >&2
    exit 1
  fi
done

echo "Rendered into $OUTPUT_DIR:"
printf '  %s\n' "${IMAGES[@]}"
echo "Review all four in light and dark before committing them."
