#!/usr/bin/env bash
# Line coverage of dired-filetags.el, measured with undercover.el while
# the ERT suite runs, and a gate against baselines/coverage.txt.
#
# Usage:
#   coverage.sh [--out DIR] [--no-gate] [--system SYS]
#       Run the suite under undercover, write the report to DIR (default
#       reports/coverage), then gate it unless --no-gate is given.
#   coverage.sh --gate DIR [--system SYS]
#       Gate the report already in DIR (its summary.txt); run nothing.
#   coverage.sh --update [DIR] [--system SYS] [--out DIR]
#       Rewrite SYS's line of baselines/coverage.txt from DIR/summary.txt,
#       or from a fresh run written to --out DIR (default reports/coverage).
#
# A report DIR holds lcov.info (its SF: line is dired-filetags.el),
# summary.txt (the lines system, emacs, covered, total, missed, percent
# and lines, the last listing the missed line numbers) and html/, made by
# genhtml when it is on PATH.
#
# The suite runs with scripts/ert-skip-budget.el, so a run in which more
# than one test skips (filetags, git or dired-subtree missing) fails.
#
# SYS is --system, else $DIRED_FILETAGS_SYSTEM, else derived from uname.
# The Emacs binary is ${EMACS:-emacs}.  The gate fails if more lines are
# missed than in the baseline and the covered fraction is lower too; see
# baselines/coverage.txt.  It also fails, rather than compare nothing, if
# baselines/coverage.txt has no line for SYS, or a line for another Emacs
# version: record one deliberately with --update.
#
# Exit status: 0 on success, 1 if a test or the gate failed, 2 on a usage
# or environment error.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASELINE="${ROOT}/baselines/coverage.txt"
EMACS=${EMACS:-emacs}
STAGE=""

usage() {
  sed -n '5,14s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

die() {
  echo "coverage: $*" >&2
  exit 2
}

cleanup() {
  if [[ -n ${STAGE} ]]; then
    rm -rf "${STAGE}"
  fi
}
trap cleanup EXIT

# Print the absolute form of the directory name $1, which need not exist.
absolute() {
  case $1 in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "${PWD}" "$1" ;;
  esac
}

detect_system() {
  local machine kernel
  machine=$(uname -m)
  kernel=$(uname -s)
  case ${machine} in
    arm64 | aarch64) machine=aarch64 ;;
    amd64 | x86_64) machine=x86_64 ;;
    *) ;;
  esac
  case ${kernel} in
    Darwin) kernel=darwin ;;
    Linux) kernel=linux ;;
    *) kernel=$(printf '%s' "${kernel}" | tr '[:upper:]' '[:lower:]') ;;
  esac
  printf '%s-%s\n' "${machine}" "${kernel}"
}

# Print the value of KEY ($2) in the summary file $1, or nothing.
field() {
  awk -v key="$2" '$1 == key { sub(/^[^ ]+ ?/, ""); print; exit }' "$1"
}

# Print COVERED/TOTAL as a percentage with two decimals.
percent() {
  awk -v c="$1" -v t="$2" 'BEGIN { printf "%.2f\n", t ? 100 * c / t : 0 }'
}

# Run the suite under undercover and write the report to $1.
run_suite() {
  local out=$1 src status=0 version entries="" records
  for src in "${ROOT}"/*.el "${ROOT}"/scripts/*.el; do
    if [[ -e "${src}c" ]]; then
      die "${src}c exists; Emacs would load it and nothing would be" \
        "instrumented.  Delete the .elc files and run again."
    fi
  done
  if [[ -e ${out} && ! -d ${out} ]]; then
    die "${out} exists and is not a directory"
  fi
  if [[ -d ${out} && ! -e ${out}/summary.txt ]]; then
    entries=$(ls -A "${out}")
  fi
  if [[ -n ${entries} ]]; then
    die "${out} is not empty and holds no coverage report; not overwriting it"
  fi

  version=$("${EMACS}" -Q --batch -l undercover --eval '(princ emacs-version)' \
    2>/dev/null) ||
    die "${EMACS} cannot load undercover; run this inside nix develop"
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/coverage.XXXXXX")

  echo "coverage: running the ERT suite under undercover (Emacs ${version})"
  (
    cd "${ROOT}"
    unset UNDERCOVER_CONFIG UNDERCOVER_FORCE
    DIRED_FILETAGS_COVERAGE_LCOV="${STAGE}/raw.info" "${EMACS}" --batch -Q -L . \
      --eval '(setq load-prefer-newer t)' \
      -l undercover \
      --eval '(setq undercover-force-coverage t)' \
      --eval '(undercover "dired-filetags.el"
                (:report-format (quote lcov))
                (:report-file (getenv "DIRED_FILETAGS_COVERAGE_LCOV"))
                (:send-report nil)
                (:merge-report nil))' \
      -l ert -l dired-filetags-test.el -l scripts/ert-skip-budget.el \
      -f ert-run-tests-batch-and-exit
  ) || status=$?
  if [[ ${status} -ne 0 ]]; then
    echo "coverage: the ERT suite failed (exit ${status}); no report written" >&2
    exit 1
  fi
  if [[ ! -s ${STAGE}/raw.info ]]; then
    echo "coverage: undercover wrote no report; was dired-filetags.el instrumented?" >&2
    exit 1
  fi
  records=$(grep -c '^SF:' "${STAGE}/raw.info" || true)
  if [[ ${records} -ne 1 ]] || ! grep -q '^SF:.*/dired-filetags\.el$' "${STAGE}/raw.info"; then
    echo "coverage: expected one record, for dired-filetags.el, in the report:" >&2
    grep '^SF:' "${STAGE}/raw.info" >&2 || true
    exit 1
  fi

  mkdir -p "${STAGE}/report"
  sed 's|^SF:.*|SF:dired-filetags.el|' "${STAGE}/raw.info" >"${STAGE}/report/lcov.info"
  awk -v sys="${SYS}" -v ver="${version}" -F'[:,]' '
    /^DA:/ { total++; if ($3 > 0) covered++; else lines = lines " " $2 }
    END {
      if (!total) exit 1
      printf "system %s\nemacs %s\ncovered %d\ntotal %d\nmissed %d\n",
        sys, ver, covered, total, total - covered
      printf "percent %.2f\nlines%s\n", 100 * covered / total, lines
    }' "${STAGE}/report/lcov.info" >"${STAGE}/report/summary.txt" ||
    {
      echo "coverage: the report has no DA: lines" >&2
      exit 1
    }

  if command -v genhtml >/dev/null 2>&1; then
    # SF: is relative, so genhtml runs where dired-filetags.el resolves.
    (cd "${ROOT}" && genhtml --quiet --flat --legend \
      --title dired-filetags \
      --output-directory "${STAGE}/report/html" \
      "${STAGE}/report/lcov.info" >/dev/null)
  else
    echo "coverage: genhtml is not on PATH; skipping the HTML report"
  fi

  mkdir -p "${out}"
  # A report copied out of the Nix store is read-only; make it writable
  # before replacing it.
  chmod -R u+w "${out}"
  rm -rf "${out}/lcov.info" "${out}/summary.txt" "${out}/html"
  mv "${STAGE}/report/"* "${out}/"
  echo "coverage: report written to ${out}"
}

# Read the summary in directory $1 into the NOW_* variables.
read_summary() {
  local summary="$1/summary.txt" system
  [[ -f ${summary} ]] || die "no summary.txt in $1"
  system=$(field "${summary}" system)
  NOW_EMACS=$(field "${summary}" emacs)
  NOW_COVERED=$(field "${summary}" covered)
  NOW_TOTAL=$(field "${summary}" total)
  NOW_LINES=$(field "${summary}" lines)
  if [[ ! ${NOW_COVERED} =~ ^[0-9]+$ || ! ${NOW_TOTAL} =~ ^[0-9]+$ ]] ||
    [[ ${NOW_TOTAL} -eq 0 || ${NOW_COVERED} -gt ${NOW_TOTAL} || -z ${NOW_EMACS} ]]; then
    die "malformed ${summary}"
  fi
  if [[ ${system} != "${SYS}" ]]; then
    die "$1 is a report for ${system}, not ${SYS}; pass --system ${system}"
  fi
  NOW_MISSED=$((NOW_TOTAL - NOW_COVERED))
}

# Explain on stderr how to record the missing or stale baseline of SYS.
record_hint() {
  echo "coverage: the gate compared nothing, so it fails.  Record the" \
    "baseline deliberately, in a commit of its own: on ${SYS} itself," \
    "scripts/coverage.sh --update (or nix run .#update-baselines); for" \
    "another system, scripts/coverage.sh --update DIR --system ${SYS}," \
    "DIR being nix build .#packages.${SYS}.coverage" >&2
}

gate() {
  local line emacs covered total missed now base
  read_summary "$1"
  now="${NOW_COVERED}/${NOW_TOTAL} ($(percent "${NOW_COVERED}" "${NOW_TOTAL}")%)"
  echo "coverage: ${SYS}, Emacs ${NOW_EMACS}: ${now} lines covered"
  echo "coverage: missed lines: ${NOW_LINES:-none}"

  [[ -f ${BASELINE} ]] || die "${BASELINE} is missing"
  line=$(awk -v sys="${SYS}" '!/^#/ && $1 == sys { print; exit }' "${BASELINE}")
  if [[ -z ${line} ]]; then
    echo "coverage: FAILED: baselines/coverage.txt has no line for ${SYS}" >&2
    record_hint
    return 1
  fi
  read -r _ emacs covered total <<<"${line}"
  if [[ ! ${covered} =~ ^[0-9]+$ || ! ${total} =~ ^[0-9]+$ ]] ||
    [[ ${total} -eq 0 || ${covered} -gt ${total} ]]; then
    die "malformed baseline line: ${line}"
  fi
  if [[ ${emacs} != "${NOW_EMACS}" ]]; then
    echo "coverage: FAILED: the ${SYS} baseline is for Emacs ${emacs}," \
      "and this report for Emacs ${NOW_EMACS}" >&2
    record_hint
    return 1
  fi
  missed=$((total - covered))
  base="${covered}/${total} ($(percent "${covered}" "${total}")%)"
  echo "coverage: baseline ${base}, ${missed} missed; now ${NOW_MISSED} missed"

  # Exact integer comparison of NOW_COVERED/NOW_TOTAL with covered/total.
  if [[ ${NOW_MISSED} -gt ${missed} ]] &&
    [[ $((NOW_COVERED * total)) -lt $((covered * NOW_TOTAL)) ]]; then
    echo "coverage: FAILED: more lines missed and a lower covered fraction" \
      "than the baseline; cover the new lines, or record a new baseline" \
      "deliberately with scripts/coverage.sh --update" >&2
    return 1
  fi
  if [[ ${NOW_MISSED} -lt ${missed} ]] ||
    [[ $((NOW_COVERED * total)) -gt $((covered * NOW_TOTAL)) ]]; then
    echo "coverage: better than the baseline; record it with" \
      "scripts/coverage.sh --update"
  fi
  echo "coverage: passed"
}

update() {
  local line old tmp
  read_summary "$1"
  [[ -f ${BASELINE} ]] || die "${BASELINE} is missing"
  line="${SYS} ${NOW_EMACS} ${NOW_COVERED} ${NOW_TOTAL}"
  old=$(awk -v sys="${SYS}" '!/^#/ && $1 == sys { print; exit }' "${BASELINE}")
  tmp=$(mktemp "${BASELINE}.XXXXXX")
  # Replace SYS's line where it is, or insert it before the first data
  # line that sorts after it; comments and other lines stay as they are.
  awk -v sys="${SYS}" -v line="${line}" '
    /^#/ || NF == 0 { print; next }
    !done && $1 == sys { print line; done = 1; next }
    $1 == sys { next }
    !done && $1 > sys { print line; done = 1 }
    { print }
    END { if (!done) print line }' "${BASELINE}" >"${tmp}"
  mv "${tmp}" "${BASELINE}"
  echo "coverage: baselines/coverage.txt: ${line} (was: ${old:-none})"
}

MODE=run
OUT=""
DIR=""
GATE=1
SYS=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --out | --gate | --system)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      case $1 in
        --out) OUT=$2 ;;
        --system) SYS=$2 ;;
        *)
          MODE=gate
          DIR=$2
          ;;
      esac
      shift 2
      ;;
    --update)
      MODE=update
      if [[ $# -ge 2 && $2 != -* ]]; then
        DIR=$2
        shift
      fi
      shift
      ;;
    --no-gate)
      GATE=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

SYS=${SYS:-${DIRED_FILETAGS_SYSTEM:-$(detect_system)}}
if [[ ${MODE} == gate && (-n ${OUT} || ${GATE} -eq 0) ]]; then
  die "--gate takes neither --out nor --no-gate"
fi
if [[ ${MODE} == update && (${GATE} -eq 0 || (-n ${DIR} && -n ${OUT})) ]]; then
  die "--update takes a report DIR or --out DIR, and never --no-gate"
fi
if [[ -n ${OUT} ]]; then
  OUT=$(absolute "${OUT}")
else
  OUT="${ROOT}/reports/coverage"
fi
if [[ -n ${DIR} ]]; then
  DIR=$(absolute "${DIR}")
fi

case ${MODE} in
  gate) gate "${DIR}" ;;
  update)
    if [[ -z ${DIR} ]]; then
      run_suite "${OUT}"
      DIR=${OUT}
    fi
    update "${DIR}"
    ;;
  *)
    run_suite "${OUT}"
    if [[ ${GATE} -eq 1 ]]; then
      gate "${OUT}"
    fi
    ;;
esac
