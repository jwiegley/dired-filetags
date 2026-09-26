#!/usr/bin/env bash
# Format Emacs Lisp files in place with format-all.
# Usage: format.sh [FILE...]
#
# With no FILE, every *.el file in the project root is formatted.  A
# relative FILE is read from the current directory, which may be any
# directory.  Every file is formatted, even after one fails; a failure
# names the file and shows the end of Emacs's output on stderr.  The
# exit status is 1 if any file could not be formatted, and 0 otherwise.
set -euo pipefail

here=$(dirname -- "${BASH_SOURCE[0]}")
scripts=$(cd -- "$here" && pwd -P)
SETUP=$scripts/format-setup.el
files=("$@")
if ((${#files[@]} == 0)); then
  shopt -s nullglob
  files=("${scripts%/*}"/*.el)
  shopt -u nullglob
fi

# Emacs reads no answers from stdin: a question, such as whether to
# save a write-protected file, fails the file instead of waiting.
status=0
for file in "${files[@]}"; do
  if out=$(emacs -Q --batch -l format-all -l "$SETUP" \
    --eval "(progn
              (find-file (car command-line-args-left))
              (format-all-ensure-formatter)
              (format-all-buffer)
              (save-buffer))" \
    "$file" 2>&1 </dev/null); then
    echo "Formatted: ${file}"
  else
    echo "format.sh: formatter failed: ${file}" >&2
    printf '%s\n' "$out" | tail -20 >&2
    status=1
  fi
done
exit "$status"
