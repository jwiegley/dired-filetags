#!/usr/bin/env bash
# Run the project's linters, with every warning an error.
# Usage: lint.sh [--staged] [CHECK...] [-- FILE...]
#
# With no CHECK, every check runs, in this order:
#
#   byte-compile    every *.el, warnings as errors (scripts/compile.el)
#   native-compile  dired-filetags.el, warnings as errors (scripts/compile.el)
#   package-lint    dired-filetags.el
#   checkdoc        every *.el (scripts/run-checkdoc.el)
#   relint          every *.el, with all of xr's checks
#   check-declare   the declare-function forms in every *.el
#   nix             statix and deadnix on every *.nix
#   shell           shellcheck on every *.sh (it reads .shellcheckrc)
#   yaml            yamllint -s on every *.yml and *.yaml, then lefthook validate
#   actions         actionlint and zizmor on the GitHub workflows
#   markdown        rumdl on every *.md except LICENSE.md
#
# With no FILE, the files are those git lists as tracked, or untracked
# and not ignored, so this runs in a git work tree; the flake's checks
# run `git init' in their copy of the source first.  A check with no
# files then fails, so that a mistake in finding them never passes as a
# clean run.
#
# With FILEs, each check looks only at the ones of its kind, and a check
# with none is skipped; native-compile and package-lint run only if
# dired-filetags.el is one of them.  A relative FILE is read from the
# current directory, which may be any directory of the checkout.
#
# --staged says that the FILEs are the files staged for a commit, as the
# pre-commit hook passes them.  If one of them is part of the linting
# machinery (this script, scripts/compile.el, scripts/run-checkdoc.el,
# .shellcheckrc, .yamllint.yaml, flake.nix or flake.lock, which pins
# the linters), every file in git's index is taken instead.  And since
# every *.el file requires or declares functions of the others,
# byte-compile and check-declare take every *.el file in the index if
# any *.el file is staged.
#
# EMACS names the Emacs to use (default emacs).  A tool missing from
# PATH fails its check.  Every requested check runs, even after one
# fails.  The exit status is 1 if any check failed, 2 for a usage
# error, and 0 otherwise.
set -euo pipefail
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  echo "lint.sh: needs bash 4.4 or later; this is ${BASH_VERSION}" >&2
  exit 2
fi
shopt -s lastpipe inherit_errexit

CHECKS=(byte-compile native-compile package-lint checkdoc relint
  check-declare nix shell yaml actions markdown)
# Files that decide what every check reports.
MACHINERY=(scripts/lint.sh scripts/compile.el scripts/run-checkdoc.el
  .shellcheckrc .yamllint.yaml flake.nix flake.lock)
EMACS=${EMACS:-emacs}
EMACS_BATCH=("$EMACS" -Q --batch -L .)

usage() {
  echo "Usage: $0 [--staged] [CHECK...] [-- FILE...]"
  echo "CHECK is one of: ${CHECKS[*]}"
}

staged=false
given=false
requested=()
args=()
while (($# > 0)); do
  case $1 in
    --staged) staged=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      given=true
      args=("$@")
      break
      ;;
    -*)
      echo "lint.sh: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ " ${CHECKS[*]} " != *" $1 "* ]]; then
        echo "lint.sh: unknown check: $1" >&2
        usage >&2
        exit 2
      fi
      requested+=("$1")
      ;;
  esac
  shift
done
if ((${#requested[@]} == 0)); then
  requested=("${CHECKS[@]}")
fi
if $staged && ! $given; then
  echo "lint.sh: --staged needs the staged files, after --" >&2
  usage >&2
  exit 2
fi

caller=$PWD
here=$(dirname -- "${BASH_SOURCE[0]}")
root=$(cd -- "${here}/.." && pwd -P)
cd -- "$root"

if ! command -v git >/dev/null; then
  echo "lint.sh: git is not on PATH, and it lists the files to check" >&2
  exit 2
fi
inside=$(git rev-parse --is-inside-work-tree 2>/dev/null || echo false)
if [[ $inside != true ]]; then
  echo "lint.sh: ${PWD} is not a git work tree, and git lists the files" >&2
  echo "to check; run \`git init' in it first, as the flake's checks do" >&2
  exit 2
fi

# Print FILE, relative to the caller's directory, as a path relative to
# the project root.  Exit 2 if it is not a file of the project.  It runs
# in a command substitution, where exit leaves only the subshell.
relative() {
  local path=$1 dir
  if [[ $path != /* ]]; then
    path=${caller}/${path}
  fi
  if [[ ! -f $path ]]; then
    echo "lint.sh: no such file: $1" >&2
    exit 2
  fi
  dir=$(dirname -- "$path")
  dir=$(cd -- "$dir" && pwd -P)
  path=${dir}/${path##*/}
  if [[ $path != "$root"/* ]]; then
    echo "lint.sh: $1 is outside the project, ${root}" >&2
    exit 2
  fi
  echo "${path#"$root"/}"
}

# Set the array named NAME to the files git lists with OPTIONS that
# exist: a file deleted from the work tree is still in the index.
git_files() {
  local -n list=$1
  local file
  shift
  list=()
  git ls-files -z "$@" |
    LC_ALL=C sort -z |
    while IFS= read -r -d '' file; do
      if [[ -f $file ]]; then
        list+=("$file")
      fi
    done
}

FILES=()
INDEX=()
if $given; then
  for file in "${args[@]}"; do
    FILES+=("$(relative "$file")")
  done
  if $staged; then
    git_files INDEX --cached
    for file in "${FILES[@]}"; do
      if [[ " ${MACHINERY[*]} " == *" ${file} "* ]]; then
        echo "lint.sh: ${file} is part of the linting machinery," \
          "so every file in the index is checked"
        FILES=("${INDEX[@]}")
        break
      fi
    done
  fi
else
  git_files FILES --cached --others --exclude-standard
fi

# Set the array named NAME to the files of the array named FROM that
# match a glob PATTERN.
collect() {
  local -n into=$1 from=$2
  local file pattern
  shift 2
  into=()
  for file in "${from[@]}"; do
    for pattern in "$@"; do
      # shellcheck disable=SC2254  # PATTERN is a glob
      case $file in
        $pattern)
          into+=("$file")
          break
          ;;
        *) ;;
      esac
    done
  done
}

EL=() NIX=() SH=() YAML=() WORKFLOWS=() MD=()
collect EL FILES '*.el'
collect NIX FILES '*.nix'
collect SH FILES '*.sh'
collect YAML FILES '*.yml' '*.yaml'
collect WORKFLOWS FILES '.github/workflows/*.yml' '.github/workflows/*.yaml'
collect MD FILES '*.md'
for i in "${!MD[@]}"; do
  if [[ ${MD[i]##*/} == LICENSE.md ]]; then
    unset 'MD[i]'
  fi
done
# The files byte-compile and check-declare read together.
EL_ALL=("${EL[@]}")
if $staged && ((${#EL[@]} > 0)); then
  collect EL_ALL INDEX '*.el'
fi
# Whether native-compile and package-lint, which read only
# dired-filetags.el, have a file to look at.
MAIN=()
if ! $given || [[ " ${FILES[*]} " == *" dired-filetags.el "* ]]; then
  MAIN=(dired-filetags.el)
fi

# Each check_NAME function below returns non-zero if its check failed.
# One with no files to look at calls this and returns its status: it
# is skipped if the files were given, and fails if they were looked for.
skipped=false
no_files() {
  if $given; then
    echo "lint.sh: none of the files is of this check's kind; skipped"
    skipped=true
    return 0
  fi
  echo "lint.sh: no files for this check" >&2
  return 1
}

check_byte_compile() {
  # One Emacs per file, so that what one file loads cannot hide a
  # missing `require' in the next.
  local file status=0
  if ((${#EL_ALL[@]} == 0)); then
    no_files
    return
  fi
  for file in "${EL_ALL[@]}"; do
    "${EMACS_BATCH[@]}" -l scripts/compile.el \
      -f dired-filetags-compile-batch byte "$file" || status=1
  done
  return "$status"
}

check_native_compile() {
  if ((${#MAIN[@]} == 0)); then
    no_files
    return
  fi
  "${EMACS_BATCH[@]}" -l scripts/compile.el \
    -f dired-filetags-compile-batch native "${MAIN[@]}"
}

check_package_lint() {
  if ((${#MAIN[@]} == 0)); then
    no_files
    return
  fi
  "${EMACS_BATCH[@]}" -l package-lint \
    -f package-lint-batch-and-exit "${MAIN[@]}"
}

check_checkdoc() {
  # `checkdoc-package-keywords-flag' also checks the Keywords header
  # against `finder-known-keywords'; files without one pass it.
  if ((${#EL[@]} == 0)); then
    no_files
    return
  fi
  "${EMACS_BATCH[@]}" --eval '(setq checkdoc-package-keywords-flag t)' \
    -l scripts/run-checkdoc.el "${EL[@]}"
}

check_relint() {
  if ((${#EL[@]} == 0)); then
    no_files
    return
  fi
  "${EMACS_BATCH[@]}" -l relint --eval '(setq relint-xr-checks (quote all))' \
    -f relint-batch "${EL[@]}"
}

check_check_declare() {
  # `check-declare-files' only reports, so the exit status comes from
  # whether it found an error.  Every declared file must be on
  # `load-path', dired-subtree's included.
  if ((${#EL_ALL[@]} == 0)); then
    no_files
    return
  fi
  "${EMACS_BATCH[@]}" -l check-declare \
    --eval '(kill-emacs (if (apply (function check-declare-files)
                                   command-line-args-left)
                            1 0))' \
    "${EL_ALL[@]}"
}

check_nix() {
  local file status=0
  if ((${#NIX[@]} == 0)); then
    no_files
    return
  fi
  for file in "${NIX[@]}"; do
    statix check -- "$file" || status=1
  done
  deadnix --fail -- "${NIX[@]}" || status=1
  return "$status"
}

check_shell() {
  if ((${#SH[@]} == 0)); then
    no_files
    return
  fi
  shellcheck -- "${SH[@]}"
}

check_yaml() {
  local status=0
  if ((${#YAML[@]} == 0)); then
    no_files
    return
  fi
  yamllint -s -- "${YAML[@]}" || status=1
  lefthook validate || status=1
  return "$status"
}

check_actions() {
  local status=0
  if ((${#WORKFLOWS[@]} == 0)); then
    no_files
    return
  fi
  # actionlint also runs shellcheck on every `run:' script.  zizmor's
  # auditor persona reports everything it can find, including what its
  # default persona leaves out as pedantic.
  actionlint -- "${WORKFLOWS[@]}" || status=1
  zizmor --offline --no-progress --persona auditor -- "${WORKFLOWS[@]}" || status=1
  return "$status"
}

check_markdown() {
  if ((${#MD[@]} == 0)); then
    no_files
    return
  fi
  # Every rule, including the ones rumdl leaves off by default, except
  # MD063: it wants title-case headings, and these are in sentence case.
  # Without --no-cache, rumdl leaves a .rumdl_cache directory behind.
  rumdl check --no-cache --extend-enable MD060,MD072,MD073 -- "${MD[@]}"
}

# Microseconds since the epoch, or whole seconds scaled up where the
# shell has no EPOCHREALTIME.
now() {
  if [[ -n ${EPOCHREALTIME:-} ]]; then
    echo "${EPOCHREALTIME//[!0-9]/}"
  else
    echo "$((SECONDS * 1000000))"
  fi
}

failed=()
passed=0
for check in "${requested[@]}"; do
  echo "==> ${check}"
  start=$(now)
  skipped=false
  if "check_${check//-/_}"; then
    if $skipped; then
      result=skipped
    else
      result=ok
      passed=$((passed + 1))
    fi
  else
    result=FAILED
    failed+=("$check")
  fi
  end=$(now)
  ms=$(((end - start) / 1000))
  printf '<== %s: %s (%d.%03d s)\n' "$check" "$result" $((ms / 1000)) $((ms % 1000))
done

if ((${#failed[@]} > 0)); then
  echo "lint.sh: ${#failed[@]} of ${#requested[@]} checks failed: ${failed[*]}"
  exit 1
fi
if ((passed == ${#requested[@]})); then
  echo "lint.sh: all ${passed} checks passed"
else
  echo "lint.sh: ${passed} of ${#requested[@]} checks passed, and the" \
    "rest were skipped: none of the files is of their kind"
fi
