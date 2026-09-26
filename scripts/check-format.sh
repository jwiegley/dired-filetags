#!/usr/bin/env bash
# Check that Emacs Lisp files are formatted as format-all formats them.
# Usage: check-format.sh FILE...
#
# Each FILE is copied into a private temporary directory and formatted
# there; the original is never written.  A relative FILE is read from
# the current directory, which may be any directory.  Every file is
# checked, even after one fails.  The exit status is 1 if a file is not
# formatted or could not be formatted, 2 if the temporary directory
# cannot be made, and 0 otherwise.
set -euo pipefail

here=$(dirname -- "${BASH_SOURCE[0]}")
SETUP=$(cd -- "$here" && pwd -P)/format-setup.el

# The X's end the template, which GNU and BSD mktemp both accept.
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/elfmt.XXXXXX") || exit 2
trap 'rm -rf -- "$tmpdir"' EXIT

status=0
n=0
for file in "$@"; do
  # Each copy keeps its file's name, so the formatter picks the same
  # mode for it, in a directory of its own, so two files with one name
  # cannot collide.  It is made writable, since cp keeps a read-only
  # file's mode, and saving it would then ask for confirmation.
  n=$((n + 1))
  copy=$tmpdir/$n/${file##*/}
  if ! mkdir -- "$tmpdir/$n" || ! cp -- "$file" "$copy" ||
    ! chmod u+w "$copy"; then
    echo "check-format.sh: cannot copy ${file}" >&2
    status=1
    continue
  fi
  # A formatter that cannot run leaves the copy unchanged, which would
  # otherwise pass as "formatted".  Emacs reads no answers from stdin.
  if ! out=$(emacs -Q --batch -l format-all -l "$SETUP" \
    --eval "(progn
              (find-file (car command-line-args-left))
              (format-all-ensure-formatter)
              (format-all-buffer)
              (save-buffer))" \
    "$copy" 2>&1 </dev/null); then
    echo "Formatter failed: ${file}"
    printf '%s\n' "$out" | tail -20
    status=1
    continue
  fi
  if ! diff -q -- "$file" "$copy" >/dev/null 2>&1; then
    echo "Format check failed: ${file}"
    diff -u -- "$file" "$copy" | head -40 || true
    status=1
  fi
done
exit "$status"
