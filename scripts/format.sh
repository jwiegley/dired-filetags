#!/usr/bin/env bash
# Format Emacs Lisp files in place with format-all.
# Usage: format.sh [file ...]
set -euo pipefail

SETUP="$(dirname "$0")/format-setup.el"
files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  shopt -s nullglob
  files=(*.el)
  shopt -u nullglob
fi

for file in "${files[@]}"; do
  emacs --batch -L . -l format-all -l "$SETUP" \
    --eval "(progn
              (find-file (car command-line-args-left))
              (format-all-ensure-formatter)
              (format-all-buffer)
              (save-buffer))" \
    "$file" 2>/dev/null
  echo "Formatted: $file"
done
