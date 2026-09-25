#!/usr/bin/env bash
# Compare Emacs Lisp files with format-all output.
# Usage: check-format.sh [file ...]
set -uo pipefail

SETUP="$(dirname "$0")/format-setup.el"
EXIT=0
TMPS=()
cleanup() { rm -f "${TMPS[@]}"; }
trap cleanup EXIT

for file in "$@"; do
  tmp=$(mktemp "${TMPDIR:-/tmp}/elfmt-XXXXXX.el")
  TMPS+=("$tmp")
  cp "$file" "$tmp"
  # A formatter that cannot run leaves the copy unchanged, which would
  # otherwise pass as "formatted".
  if ! out=$(emacs --batch -L . -l format-all -l "$SETUP" \
    --eval "(progn
              (find-file (car command-line-args-left))
              (format-all-ensure-formatter)
              (format-all-buffer)
              (save-buffer))" \
    "$tmp" 2>&1); then
    echo "Formatter failed: $file"
    echo "$out" | tail -20
    EXIT=1
    continue
  fi
  if ! diff -q "$file" "$tmp" >/dev/null 2>&1; then
    echo "Format check failed: $file"
    diff -u "$file" "$tmp" | head -40 || true
    EXIT=1
  fi
done
exit "$EXIT"
