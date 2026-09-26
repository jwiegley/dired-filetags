#!/usr/bin/env bash
# Run the property tests of dired-filetags-fuzz-test.el.
#
#   fuzz.sh --check                     one round: seed "dired-filetags",
#                                       1000 iterations (pre-commit, flake)
#   fuzz.sh [--seconds N] [--iterations N]
#                                       rounds with fresh seeds until N
#                                       seconds (600) have passed, of N
#                                       iterations (20000) each
#   fuzz.sh --seed S [--iterations N]   one round with seed S
#
# DIRED_FILETAGS_FUZZ_SEED and DIRED_FILETAGS_FUZZ_ITERATIONS override
# the defaults of --check.  The oracle needs DIRED_FILETAGS_PYTHON and
# DIRED_FILETAGS_PY, and the CLI property needs filetags on PATH; `nix
# develop' provides all three.  A round that finds a failure stops the
# run, and the command that reproduces it is printed.
set -euo pipefail

usage() {
  sed -n '2,16s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

die() {
  echo "fuzz.sh: $*" >&2
  exit 2
}

number() {
  [[ $2 =~ ^[1-9][0-9]*$ ]] || die "$1 needs a positive integer, not '$2'"
}

mode=long
seconds=600
iterations=
seed=
while (($# > 0)); do
  case $1 in
    --check) mode=check ;;
    --seed)
      (($# > 1)) || die "--seed needs a value"
      [[ -n $2 ]] || die "--seed needs a non-empty value"
      mode=seed seed=$2
      shift
      ;;
    --seconds)
      (($# > 1)) || die "--seconds needs a value"
      number "$1" "$2"
      seconds=$2
      shift
      ;;
    --iterations)
      (($# > 1)) || die "--iterations needs a value"
      number "$1" "$2"
      iterations=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
  shift
done

here=$(dirname -- "${BASH_SOURCE[0]}")
cd -- "$here/.."

if [[ -z ${DIRED_FILETAGS_PYTHON:-} || -z ${DIRED_FILETAGS_PY:-} ]]; then
  die "DIRED_FILETAGS_PYTHON and DIRED_FILETAGS_PY must name the Python" \
    "oracle and filetags/__init__.py; run inside 'nix develop'"
fi

run=("${EMACS:-emacs}" --batch -Q -L . --eval '(setq load-prefer-newer t)'
  -l dired-filetags-fuzz-test.el -f dired-filetags-fuzz-batch-and-exit)

case $mode in
  check)
    export DIRED_FILETAGS_FUZZ_SEED="${DIRED_FILETAGS_FUZZ_SEED:-dired-filetags}"
    export DIRED_FILETAGS_FUZZ_ITERATIONS="${iterations:-${DIRED_FILETAGS_FUZZ_ITERATIONS:-1000}}"
    exec "${run[@]}"
    ;;
  seed)
    export DIRED_FILETAGS_FUZZ_SEED="$seed"
    export DIRED_FILETAGS_FUZZ_ITERATIONS="${iterations:-20000}"
    exec "${run[@]}"
    ;;
  *)
    export DIRED_FILETAGS_FUZZ_ITERATIONS="${iterations:-20000}"
    round=0
    while ((SECONDS < seconds)); do
      round=$((round + 1))
      stamp=$(date +%Y%m%d%H%M%S)
      export DIRED_FILETAGS_FUZZ_SEED="$stamp-$RANDOM"
      echo "fuzz.sh: round $round, seed $DIRED_FILETAGS_FUZZ_SEED," \
        "$DIRED_FILETAGS_FUZZ_ITERATIONS iterations, ${SECONDS}s elapsed"
      if ! "${run[@]}"; then
        echo "fuzz.sh: round $round failed; reproduce it with:" >&2
        echo "  scripts/fuzz.sh --seed $DIRED_FILETAGS_FUZZ_SEED" \
          "--iterations $DIRED_FILETAGS_FUZZ_ITERATIONS" >&2
        exit 1
      fi
    done
    echo "fuzz.sh: $round rounds of $DIRED_FILETAGS_FUZZ_ITERATIONS iterations" \
      "passed in ${SECONDS}s"
    ;;
esac
