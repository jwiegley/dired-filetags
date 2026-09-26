# CLAUDE.md — dired-filetags.el

## Package Overview

`dired-filetags.el` is a single-file package (Emacs 29.1+, no dependencies
outside Emacs) providing `dired-filetags-mode`, a buffer-local minor mode for
Dired that integrates Karl Voit's
[filetags](https://github.com/novoid/filetags) CLI. filetags keeps tags in
file names: `Report -- work urgent.pdf` has the tags `work` and `urgent`.

The mode adds and removes tags on the marked files, marks files by tag,
builds and browses TagTrees, and shows tags as coloured labels. Its
commands sit under `dired-filetags-prefix-key` (`;` by default, a key Dired
leaves unbound). The only tagging key is `; a`, `dired-filetags-add-remove`;
`dired-filetags-add` and `dired-filetags-remove` are commands with no key.
The filetags program decides every new name; Emacs never computes one
itself:

```text
; a (add-remove), M-x dired-filetags-add / -remove
    │
    ├─► dired-filetags--plan       classify, group by (vocabulary . tokens)
    │     ├─ dired-filetags--new-names   filetags renames empty stand-ins
    │     │                              in a scratch directory
    │     ├─ dired-filetags--verify      is the prediction a faithful retag?
    │     └─ dired-filetags--preflight   collisions, existing names, buffers
    │
    └─► dired-filetags--execute    dired-create-files + dired-rename-file
                                   on the real files (VC, buffers, marks)
```

The user's own init (`~/org/init.org`, not part of this project) enables
it, and puts add-remove on `:` directly, as the README recommends:

```elisp
(use-package dired-filetags
  :load-path "lisp/dired-filetags"
  :hook (dired-mode . dired-filetags-mode)
  :bind (:map dired-mode-map
              (":" . dired-filetags-add-remove)))
```

That binding lives in `dired-mode-map` and replaces Dired's EasyPG `:`
prefix map; with the default prefix, the package itself never binds `:`
(it does only if `dired-filetags-prefix-key` is set to `:`, which would
then shadow this binding). wdired's keymap does not
inherit `dired-mode-map`, so `:` self-inserts there. The prefix stays `;`;
it can move with `:custom`, `setopt`, or Customize (see Keymaps and mode
below).

## Development Commands

No traditional build system (no Makefile, Eask, or Cask). Nix provides the
development environment, every target and every check. `flake.nix` builds
filetags from source (`packages.filetags`, pinned to novoid/filetags
`811c97b8`, version 2026.06.06.1-unstable-2026-09-01, GPL-3.0-or-later),
and `nix develop` gives Emacs 30.2 (`emacs-nox` from the
locked nixpkgs, with native compilation) with `package-lint`, `format-all`,
`relint`, `undercover` and `dired-subtree`, that `filetags`, a Python with
filetags' dependencies for the fuzz oracle, bash 5, git, lcov, lefthook
(its `shellHook` runs `lefthook install`), nixfmt, statix, deadnix,
shellcheck, shfmt, prettier, yamllint, actionlint, zizmor and rumdl. It
also sets `DIRED_FILETAGS_SYSTEM` (the baseline key), and
`DIRED_FILETAGS_PYTHON` and `DIRED_FILETAGS_PY` (the fuzz oracle's Python
and the pinned `filetags/__init__.py`). ERT and byte-compilation also run
outside Nix with a local Emacs and `filetags` on `PATH`; everything else
needs the dev shell. `scripts/lint.sh` and `scripts/format-all.sh` need
bash 4.4 or later, and refuse macOS's `/bin/bash` 3.2.

The flake offers aarch64-darwin, aarch64-linux and x86_64-linux, the
systems with baselines (`flake-utils.lib.eachSystem`). x86_64-darwin is
left out because nixpkgs' deprecation warning aborts its evaluation
under `--option abort-on-warn true`. On aarch64-linux, rumdl is rebuilt
with `JEMALLOC_SYS_WITH_LG_PAGE=16`: nixpkgs' binary, built on 4 KiB-page
kernels, aborts with "Unsupported system page size" on 16 KiB-page ones
such as vulcan's, and one built for 64 KiB pages runs on all three.

### Targets

| Command                                       | What it does                                                                                                                                                                                                                                                                                                                                                                                                              |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nix build`                                   | `packages.default`: the package as nixpkgs builds MELPA packages (`melpaBuild`): `share/emacs/site-lisp/elpa/dired-filetags-0.1.0/` with `dired-filetags-autoloads.el` and `-pkg.el`, byte- and native-compiled by the bare `emacs-nox` with warnings as errors, after a `preBuild` compile with `byte-compile-warnings` `all`                                                                                            |
| `nix flake check`                             | builds and runs the 14 checks below                                                                                                                                                                                                                                                                                                                                                                                       |
| `nix run .#test [-- REGEXP]`                  | the ERT suite, or the tests matching REGEXP                                                                                                                                                                                                                                                                                                                                                                               |
| `nix run .#format` / `nix fmt [-- PATH...]`   | `scripts/format-all.sh`: formats every file, or PATHs                                                                                                                                                                                                                                                                                                                                                                     |
| `nix run .#lint [-- [CHECK...] [-- FILE...]]` | `scripts/lint.sh`: all 11 linters, or the ones named, over every file or the FILEs                                                                                                                                                                                                                                                                                                                                        |
| `nix run .#coverage [-- ARGS]`                | `scripts/coverage.sh`: report in `reports/coverage/`, then the gate                                                                                                                                                                                                                                                                                                                                                       |
| `nix run .#perf [-- ARGS]`                    | `scripts/bench.el --report reports/perf --gate all`: measures this machine now                                                                                                                                                                                                                                                                                                                                            |
| `nix run .#fuzz [-- ARGS]`                    | `scripts/fuzz.sh`: long runs with fresh seeds (default 600 s)                                                                                                                                                                                                                                                                                                                                                             |
| `nix run .#update-baselines`                  | `coverage.sh --update`, `bench.el --update`, then the diff stat; stops (exit 1) if `bench.el` refuses the timing entry                                                                                                                                                                                                                                                                                                    |
| `nix build .#coverage`                        | `packages.coverage`: `lcov.info`, `summary.txt`, `html/`                                                                                                                                                                                                                                                                                                                                                                  |
| `nix build .#perf-report`                     | `packages.perf-report`: a reference profile, measured once in a Nix build sandbox (`--samples 3`) and cached by input hash (perhaps built on, or substituted from, another machine); `PROVENANCE.txt` and the head of `perf.txt` name its build host and time. Its allocation counts hold for the system; its timings are not this machine's. It also has `perf.eld`, `elp.txt`, `profile.txt`, `cpu.prof` and `mem.prof` |

An app runs in the checkout's root: `PRJ_ROOT` (which `nix fmt` sets),
else the nearest directory at or above the current one that holds
`dired-filetags.el` and `flake.nix`; outside a checkout it exits 2. The
format and lint apps then go back to the current directory (`cd
"$OLDPWD"`), so `nix fmt` and `nix run .#lint` read relative PATHs and
FILEs from there. The apps put GNU coreutils, findutils, diffutils, sed,
gawk and grep ahead of the dev tools on `PATH`, so the scripts never
meet macOS's BSD userland. `reports/` is git-ignored.

### Checks (`nix flake check`)

Each runs in a copy of only the files it reads (`lib.fileset`), with
only the tools it calls, the dev shell's environment variables, and a
fresh `HOME` and `TMPDIR`. The package gets `dired-filetags.el`. The
suite, leak, fuzz, the reports and the five Emacs Lisp linters get every
`*.el` file and `scripts/*.sh`; the two gates also get `baselines/`.
format, lint and apps get the whole tree. Only format, lint, apps and
the Emacs Lisp linters are made a git work tree (`git init -q`, so the
scripts list files the same way everywhere and `lefthook validate`
works). A README, CI or lefthook edit therefore rebuilds only format,
lint and apps, and a baseline edit also rebuilds the two gates.

- `build`: `packages.default`.
- `ert`: the ERT suite; the run fails (exit 2) when more than one test
  skips.
- `leak`: the suite under `scripts/leak-check.el`; the run fails
  (exit 2) when more than one test skips.
- `fuzz`: `scripts/fuzz.sh --check`.
- `coverage`: `scripts/coverage.sh --gate` on `packages.coverage`.
- `perf`: `bench.el --results PERF-REPORT/perf.eld --gate alloc`; timings
  are only reported, since no builder has a timing baseline.
- `format`: `scripts/format-all.sh --check`.
- `lint`: `scripts/lint.sh check-declare nix shell yaml actions markdown`.
- `byte-compile`, `native-compile`, `package-lint`, `checkdoc`, `relint`:
  `scripts/lint.sh CHECK`.
- `apps`: every app, the formatter and the dev shell build (`$out` links
  to each), and the apps run from `scripts/` with only `/usr/bin:/bin` on
  `PATH` (`env -i`): format `--check` on two Emacs Lisp files (a
  scratch-file bug in `check-format.sh` shows only from the second, as
  NIX-1's did) and one file per other formatter; lint's `nix`, `shell`
  and `yaml` checks; the oracle tests; and coverage and fuzz `--help`.
  On macOS, `check-format.sh` also runs by itself on two files with
  only `/usr/bin`, `/bin` and Emacs on `PATH`, so its BSD `mktemp`,
  `cp` and `diff` are exercised, which the apps never meet (they put GNU
  coreutils first). The check fails if an app changed, deleted or left
  a file, ignored ones included. perf and update-baselines are only
  built.

The reports never fail on a regression; the `coverage` and `perf` checks
are separate, cheap derivations that read them, so a failed gate still
leaves a report, and each report builds once. A plain `nix flake check` in
a git repository sees only tracked and staged files: `git add` new files
first, or use `nix flake check path:$PWD`. The pre-commit hook and CI pass
`--option abort-on-warn true`.

### Raw commands

**ERT** (the suite drives the real `filetags`):

```bash
emacs -Q -batch -L . --eval '(setq load-prefer-newer t)' \
  -l ert -l ./dired-filetags-test.el -f ert-run-tests-batch-and-exit
```

A single test or group, by regexp (or `nix run .#test -- dired-filetags-oracle`):

```bash
emacs -Q -batch -L . --eval '(setq load-prefer-newer t)' \
  -l ert -l ./dired-filetags-test.el \
  --eval '(ert-run-tests-batch-and-exit "dired-filetags-oracle")'
```

Tests that need the CLI use `(skip-unless (executable-find "filetags"))`; a
few also need `git`, and two need `dired-subtree`. A run of the commands
above without them passes with skips, so read the `skipped` count in the
summary before trusting a green result. One case-sensitivity test skips
on each platform by design (a different one on macOS and on Linux).
`checks.ert`, `checks.leak`, `nix run .#test`, the lefthook `ert` and
`leak` jobs and `scripts/coverage.sh` fail instead (exit 2) when more
than one test skips: they load `scripts/ert-skip-budget.el` after the
suite, as `-l scripts/ert-skip-budget.el` does for the commands above.

**Leak check** (optional SELECTOR: a regexp, or a Lisp selector starting
with `(`; exit 1 on a failed test or any leak, 2 if the run itself failed,
for instance with undercover loaded or over the skip budget):

```bash
emacs --batch -Q -L . --eval '(setq load-prefer-newer t)' \
  -l ert -l dired-filetags-test.el -l scripts/leak-check.el \
  -f dired-filetags-leak-check-batch-and-exit
```

**Fuzz:** `scripts/fuzz.sh --check` (seed `dired-filetags`, 1000
iterations, the pre-commit and flake run), `scripts/fuzz.sh [--seconds N]
[--iterations N]` (rounds of fresh seeds, default 600 s of 20000), and
`scripts/fuzz.sh --seed S [--iterations N]` to replay a failure; it prints
the exact command. `DIRED_FILETAGS_FUZZ_SEED` and
`DIRED_FILETAGS_FUZZ_ITERATIONS` override `--check`'s defaults.

**Coverage:** `scripts/coverage.sh [--out DIR] [--no-gate] [--system SYS]`
runs the suite under undercover and gates; `--gate DIR` gates an existing
report; `--update [DIR] [--system SYS]` rewrites SYS's baseline line from
a fresh run or from DIR. Exit 0 pass, 1 test failure or failed gate, 2
usage or environment error (including an `.elc` next to a source). A
missing or stale baseline line fails the gate (exit 1); a missing
`baselines/coverage.txt` is exit 2.

**Performance:** `emacs -Q --batch -L . -l scripts/bench.el -f
dired-filetags-bench-batch [--report DIR] [--gate none|alloc|time|all]
[--results FILE] [--update] [--samples N] [--system SYS]
[--results-out FILE] [--single-process]`. `--results FILE --update
--system SYS` records only SYS's allocation baseline from a `perf.eld` a
report wrote (for Linux, from `nix build .#packages.SYS.perf-report`).
`--update` and a failed timing gate start two more Emacs processes of
their own (with `--results-out` and `--single-process`); see Baselines.

**Byte-compile** (every warning is an error; `scripts/lint.sh byte-compile`
does this for every `.el` file, one Emacs per file, into a temporary
directory):

```bash
emacs --batch -L . \
  --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
  --eval '(setq byte-compile-warnings (quote all))' \
  -f batch-byte-compile dired-filetags.el dired-filetags-test.el
```

This leaves `.elc` files next to the sources (git ignores them); delete
them afterwards, so a stale one is never loaded instead of a newer edit,
and because `coverage.sh` refuses to run while one exists.

**package-lint** (the package file only):

```bash
emacs --batch -L . -l package-lint -f package-lint-batch-and-exit dired-filetags.el
```

**checkdoc** (`lint.sh` also sets `checkdoc-package-keywords-flag`):

```bash
emacs --batch -L . -l scripts/run-checkdoc.el dired-filetags.el dired-filetags-test.el
```

**relint** (`lint.sh` also sets `relint-xr-checks` to `all`):

```bash
emacs --batch -L . -l relint -f relint-batch dired-filetags.el dired-filetags-test.el
```

**Emacs Lisp formatting** (`format-all`; `format-all.sh` calls these for
`*.el`):

```bash
scripts/format.sh dired-filetags.el dired-filetags-test.el        # in place
scripts/check-format.sh dired-filetags.el dired-filetags-test.el  # report only
```

Both scripts load `scripts/format-setup.el`, which sets `indent-tabs-mode`
to nil, turns off backup files (so `format.sh` leaves no `FILE.el~`), and
evaluates the root-level files' `defmacro` forms so their `indent`
declarations apply in batch. It finds the root from its own location,
reads only regular files whose names start with neither `.` nor `#`, so
Emacs lock files are left out, and skips, with a message, a file it
cannot read. Both scripts run `emacs -Q` with stdin from `/dev/null`,
keep going after a file fails (naming it, with the end of Emacs's
output), and take relative FILEs from the current directory;
`check-format.sh` formats copies in a private `mktemp -d` directory.

### Tooling

| File                                                                      | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/lint.sh [--staged] [CHECK...] [-- FILE...]`                      | runs byte-compile, native-compile, package-lint, checkdoc, relint, check-declare, nix, shell, yaml, actions, markdown (all by default) over every file git lists, or only the FILEs (a check with none of its kind is skipped; native-compile and package-lint run only if `dired-filetags.el` is among them); `--staged` widens to every file in the index when a linter script or setting (`lint.sh`, `compile.el`, `run-checkdoc.el`, `.shellcheckrc`, `.yamllint.yaml`, `flake.nix`, `flake.lock`) is among them, and byte-compile and check-declare to every indexed `.el` file when any is; prints a summary; exit 1 on any failure, 2 on a usage error |
| `scripts/compile.el`                                                      | byte and native compilation driver for `lint.sh`: `'all` warnings as errors, output in temporary directories; native mode also fails on `*Native-compile-Log*` warnings                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `scripts/format-all.sh [--check] [--staged] [PATH...]`                    | formats, or checks, every tracked or untracked-but-not-ignored file, or the PATHs (relative to the current directory): format-all for `*.el`, nixfmt, `shfmt -i 2 -ci`, prettier for YAML and Markdown; skips `LICENSE.md`; `--staged` widens to the whole index when a formatter script, `.prettierignore`, `flake.nix` or `flake.lock` is among them                                                                                                                                                                                                                                                                                                        |
| `scripts/format.sh`, `scripts/check-format.sh`, `scripts/format-setup.el` | format-all for Emacs Lisp files                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `scripts/run-checkdoc.el`                                                 | batch checkdoc; exit 1 on any warning or checkdoc error                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `scripts/coverage.sh`                                                     | undercover run, lcov/HTML report, coverage gate and update                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `scripts/ert-skip-budget.el`                                              | advice on `ert-run-tests-batch` that fails a run (exit 2) in which more than one test skips; loaded after the suite by every runner of it                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `scripts/leak-check.el`                                                   | the R17 memory-sanitizer analogue: per-test leak snapshots around the ERT suite                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `scripts/bench.el`                                                        | benchmark workloads, profiling report (elp, profiler), allocation and timing gates, update                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `scripts/fuzz.sh`                                                         | fuzz runner: `--check`, long runs, `--seed`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `dired-filetags-fuzz-test.el`                                             | the nine seeded properties, `dired-filetags-fuzz-rerun-regenerates-inputs` (every failure's rerun command regenerates its input) and `dired-filetags-fuzz-batch-and-exit` (fails on any failure or skip); in the root so `format-setup.el`, the lefthook `*.el` globs and MELPA's `*-test.el` exclusion all cover it                                                                                                                                                                                                                                                                                                                                          |
| `baselines/coverage.txt`                                                  | `SYSTEM EMACS COVERED TOTAL`, one line per system                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `baselines/perf.eld`                                                      | `(alloc (SYSTEM :emacs :native :root-length :counts))` and `(time (SYSTEM/HOST :emacs :native :root-length :power :calibration :ratios))`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `.shellcheckrc`                                                           | `enable=all`, minus SC2250                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `.yamllint.yaml`                                                          | yamllint's default rules, adjusted for prettier and workflows                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `.prettierignore`                                                         | `LICENSE.md`, `flake.lock`, `reports/`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |

### Baselines

- **Coverage** (`baselines/coverage.txt`, key: system and Emacs version).
  The gate fails iff `missed_now > missed_base` and
  `covered_now * total_base < covered_base * total_now` (exact integers):
  deleting covered code or adding covered code passes; adding uncovered
  code that lowers the fraction fails. No line for the system, or a line
  for another Emacs, fails the gate (exit 1), and a missing file is exit
  2: a gate that compared nothing never passes. On an improvement it
  suggests `--update`. The current numbers are the ones in
  `baselines/coverage.txt`; `coverage.sh` prints the run's missed lines.
- **Allocations** (`baselines/perf.eld` `alloc`, key: system, Emacs
  version, native compilation). The `memory-use-counts` deltas, weighed
  by object size, may not exceed 1.05 times the baseline. A missing
  `perf.eld`, no entry for the system, an entry for another Emacs or
  native-compilation setting, or a gated workload without a baseline
  fails the gate. Every counter is gated, including the string-chars of
  the four `:paths` workloads, whose files are in `/tmp` so that the
  counts match in the dev shell, the Nix sandbox and CI; only a run
  whose directory could not be made in `/tmp`, and so has a name of
  another length than the entry's `:root-length`, reports those
  string-chars instead, with a NOTE.
- **Timings** (`baselines/perf.eld` `time`, key: `SYSTEM/HOST` such as
  `aarch64-darwin/clio`, plus Emacs version and native compilation; the
  entry also records macOS's power mode as `:power`). Raw seconds are
  never compared. Ratio = a workload's fastest clean sample over the
  run's calibration, the lower quartile of the samples of a calibration
  loop interleaved with the workloads in the same process (not the
  fastest sample: one lucky sample 2-4% faster than the rest raised
  every ratio, and more samples only lower a minimum); a sample is clean
  when the calibration samples on either side of it ran within 10% of
  that quartile. A workload with fewer than 3 clean samples, or over
  the threshold times its baseline, is measured again with twice the
  samples, up to three times (chosen anew after each extra
  measurement). If it is still over, two new Emacs processes run the
  timing gate, since a ratio moves by 1-2% from one process to the
  next with the memory layout, and it fails only if the median of its
  three ratios is over. The threshold is 1.05, or 1.08 when the run's
  power mode and the entry's differ: the ratio cancels most of a change
  of clock speed, not all of it. The `:paths` workloads (mark and tally)
  are not gated when the entry's `:root-length` differs. Without an
  entry for SYSTEM/HOST (CI, Nix builders), timings are report-only and
  the output says so (`perf: NOTE: timings are NOT gated`); a missing
  `perf.eld` or an entry for another Emacs fails. On an efficiency core
  the ratios do not hold, so the timing gate is skipped with a NOTE when
  the calibration is outside 1/1.35 to 1.35 times the recorded one in
  the same power mode (up to 2.2 times in Low Power Mode when recorded
  out of it, down to 1/2.2 the other way round, 1/1.8 to 1.8 when
  either mode is unknown). `--update` records the median of three Emacs
  processes' ratios and calibrations, each run with the gate's 5
  samples, so the entry sits in the middle of what a gate run measures.
  It refuses to record the timing entry (exit 1, allocations still
  recorded) if a gated workload has fewer than 3 clean samples in one of
  them, if they differ in power mode, Emacs or directory length, or if
  the calibration is slower than that range allows against the entry it
  replaces, and records nothing from a directory outside `/tmp`. clio's
  entry was recorded on AC power (`:power "normal"`).

To update: `nix run .#update-baselines` (this system's coverage and
allocations, this machine's timings; it stops before the diff stat if
`bench.el` refuses the timing entry). For the other systems, build
`.#packages.SYS.coverage` and `.#packages.SYS.perf-report`, then run
`scripts/coverage.sh --update RESULT --system SYS` and `bench.el --results
RESULT/perf.eld --update --system SYS`. x86_64-linux builds from clio
need `--eval-store auto --store 'ssh-ng://jwiegley@andoria-08?ssh-key=...'`,
because the andoria builders reject each other's unsigned paths.

**Pre-commit:** `lefthook.yml` runs one parallel group (format, lint,
byte-compile, native-compile, package-lint, checkdoc, relint, ERT, leak,
fuzz, coverage, and the `nix`-tagged `nix build` and `nix flake check`),
each job filtered by its glob, which also names the scripts that
implement it, and then the timing gate (`bench.el --gate all`) alone,
because timings taken while the suite runs on every core measure the
load. format and lint get `{staged_files}` (which `--all-files` turns
into every tracked file) with `--staged`, so an untracked or unstaged
file cannot fail a commit. The hook works from any git client: the
`lefthook:` command in lefthook.yml runs lefthook directly when
`DIRED_FILETAGS_SYSTEM` is set (the dev shell) and through
`nix develop --command` otherwise, so it needs only `nix` on `PATH`. The
`ert` and `leak` jobs load `scripts/ert-skip-budget.el`, as the flake's
checks do. Run them all by hand with `lefthook run pre-commit --all-files`;
`LEFTHOOK_EXCLUDE=nix` skips the two Nix jobs.

**CI:** `.github/workflows/ci.yml` runs on `ubuntu-latest` and
`macos-latest` for pushes and pull requests to `main`: `nix build`, the
coverage and performance report builds (copied into `reports/ci/`, made
writable, and uploaded as the `reports-<os>` artifact, even when a later
step fails; `reports/coverage` is left to the pre-commit coverage job),
`nix flake check --all-systems --no-build` (evaluation of every offered
system, so a new warning on any of them fails), `nix flake check`, and
`LEFTHOOK_EXCLUDE=nix nix develop --command lefthook run pre-commit
--all-files`. Every Nix command passes `--option abort-on-warn true`.
Actions are pinned by SHA, the token is read-only, and newer pushes
cancel older runs.

**Docs:** there is no documentation build. README.md is the only
documentation; rumdl lints it and prettier formats it.

**Interactive development:**

```elisp
(unload-feature 'dired-filetags t)
(load-file "dired-filetags.el")
(add-hook 'dired-mode-hook #'dired-filetags-mode)
```

`unload-feature` runs `dired-filetags-unload-function`, which turns the
mode off in every buffer, and removes `dired-filetags-mode` from
`dired-mode-hook`, hence the `add-hook`; re-enable the mode by hand in
Dired buffers that were already open. A prefix set with use-package's
`:custom` reverts to `;` across the reload (Custom drops its stashed value
after the first load); `setopt` it again.

## Architecture

The file is divided by `;;;;` headings, in this order.

### Options, Faces, Internal variables

`defcustom`s: `dired-filetags-program` (`"filetags"`),
`dired-filetags-prefix-key` (`";"`, see Keymaps and mode),
`dired-filetags-display-style` (`right`), `dired-filetags-align-width` (32),
`dired-filetags-tag-colors`, `dired-filetags-tag-faces`,
`dired-filetags-tagtrees-directory`
(`$XDG_CACHE_HOME` or `~/.cache`, plus `dired-filetags/tagtrees/`),
`dired-filetags-tagtrees-depth` (2), `dired-filetags-tagtrees-untagged`
(`"no-tags"`), `dired-filetags-tagtrees-link-limit` (50000). Faces:
`dired-filetags-tag`, `-separator`, `-added`, `-removed`.

`dired-filetags--with-cache` binds `dired-filetags--cache`, a per-command
memo table used by `dired-filetags--memo`; it is only ever let-bound, never
set.

### Name model

`dired-filetags--split` mirrors filetags' `FILE_WITH_TAGS_REGEX` (first
" -- " at index 1 or later, extension of Python `\w` characters, trailing
`.lnk` stripped) and returns offsets. `dired-filetags-parse` returns
`(BASE TAGS EXT)` exactly as filetags reads it, keeping empty and `--`
tags; `dired-filetags--clean-tags` drops those.
`dired-filetags--untagged-name` downcases the `.lnk` that ends its result,
even one that ends the base (`"x.LNK -- a"` becomes `"x.lnk"`), so it is
idempotent. `dired-filetags--check-tags` rejects tags filetags cannot apply
(whitespace and control characters by Unicode general category, `Cc`,
`Zs`, `Zl` and `Zp`, through `dired-filetags--unsafe-char-p`, as well as
by `[:space:]`/`[:cntrl:]`; `/`; a leading `-`; the reserved `.`, `..`,
`--`, `cuttimes`; and control-file names). A single regexp scan passes the
usual printable-ASCII tag, so the Unicode check costs nothing there.
`dired-filetags--control-file-p` matches `.filetags` and
`.filetags_tagtrees` in any letter case, as APFS folds them, including the
ligature fi (U+FB01) and long s (U+017F); every control-file test goes
through it. `dired-filetags--verify` compares an old and a predicted new
name and returns a reason string if the prediction is not a faithful
retag: the untagged names must match and, when both names are tagged, so
must the base and the extension (`"a -- x.b"` and `"a.b -- x"` share an
untagged name); tags lost to an exclusive group are allowed.

### Running filetags and the stand-in oracle

`dired-filetags--call` runs the CLI synchronously with stdin from
`/dev/null`, stdout and stderr merged, and treats a non-zero exit or an
`ERROR`/`Traceback` line as failure (logged to `*Dired log*`).
`dired-filetags--program` resolves the executable locally, even in remote
buffers.

`dired-filetags--new-names` is the oracle: for each basename it makes a
numbered directory in a `make-temp-file` scratch directory, writes a
`.filetags` there (`#include` of the governing vocabulary, or empty to stop
filetags' upward search), writes an empty stand-in, runs
`filetags -q --tags=TOKENS` on all of them, reads back the single entry
left in each directory, and deletes the scratch directory.
`file-name-handler-alist` is bound to nil throughout.
`dired-filetags--vocabulary-file` finds the
governing `.filetags` with `locate-dominating-file` (none for remote files);
`dired-filetags--vocabulary-words` reads its words for completion, without
following includes.

### Targets and planning

`dired-filetags--targets` takes the marked files or the next ARG files; in a
TagTree it replaces links with their originals
(`dired-filetags--link-original`, one level only).
`dired-filetags--classify` returns a refusal reason (control file in any
letter case, directory, missing or dangling, not regular, or inside a
TagTree without being one of its links).

`dired-filetags--plan` groups files by `(vocabulary . tokens)`, because
filetags applies the first file's vocabulary to every file in one call, and
sends each group to the oracle in chunks of `dired-filetags--chunk-size`
(500). It never sends a tag the file already has, nor removes one it
lacks. `dired-filetags--preflight` then refuses pairs whose new name exists,
is visited by a buffer, or collides with another pair after
`dired-filetags--fold` (NFC, downcase, NFC again, as APFS compares; the
second NFC reorders the combining dot that downcasing U+0130 adds; an
ASCII name is only downcased).
`dired-filetags--retag` logs every refusal, signals if nothing is left, and
otherwise executes and reports.

### Execution and reporting

`dired-filetags--execute` renames through `dired-create-files` with
`dired-filetags--rename` (a wrapper over `dired-rename-file` that turns
plain errors from `vc-rename-file` into `file-error`, so one failure does
not abort the batch) and `dired-keep-marker-rename`. It then fixes buffers
that visit a file through a symbolic link, reverts Dired buffers that still
list an old name (`dired-filetags--refresh-stale-buffers`, comparing local
directories by truename and never touching another host), and, inside a
tree this package built, rebuilds it (`dired-filetags--maybe-rebuild-tagtree`).
`dired-filetags--report` prints one line with `+tag`/`-tag` changes derived
from the real old and new names.

### Reading tags

`dired-filetags--read-tags` wraps `completing-read-multiple` with
`dired-filetags--crm-separator` (spaces or commas), completion category
`dired-filetags-tag`, annotations, and unsorted candidates.
`dired-filetags--minibuffer-map` makes `SPC` self-insert and makes `RET`
after a trailing separator submit only the typed tags, unless vertico's
`vertico--lock-candidate` says a candidate was chosen explicitly. The
`*-candidates` functions build the alists for add (buffer tags by count,
then vocabulary), remove (tags of the targets, "on K/N"), add-remove
(`dired-filetags--add-remove-candidates`: the targets' tags "on K/N", then
the other buffer tags, then vocabulary), and mark. Prompts come from
`dired-filetags--prompt`, "VERB NAME: " or "VERB N files: " ("Add or
remove tags on", "Add tags to", "Remove tags from"), counting only
taggable targets.

### Commands

`dired-filetags-add-remove` (`PREFIX a`) decides each tag across the
selection: a tag every taggable target already has is removed from all of
them, any other tag is added to the targets that lack it. On one file
that is an exact add-or-remove; on a mixed selection the first call adds
the tag where missing and the next removes it from all, so two calls do
not restore a mixed selection. Adding a tag from an exclusive
`.filetags` group replaces its group mates, as filetags does, so a
second call does not bring a displaced mate back, even on one file, and
naming two mates on a mixed selection can swap them. Each tag is
checked with `dired-filetags--check-tags` as what it will be: the
additions as additions, and the tags every target has as removals, so a
tag starting with `-` or named like a control file can be removed.
`dired-filetags-add` (only adds) and
`dired-filetags-remove` (only removes, `require-match`) have no key and
run from `M-x` or Lisp. All three are `(interactive ... dired-mode)` and
return the renamed `(OLD . NEW)` pairs. The package is unreleased, so the
old name `dired-filetags-toggle` has no obsolete alias.

### Marking

`dired-filetags-mark` (any of the tags), `dired-filetags-mark-not` (none
of them) and `dired-filetags-mark-untagged` (no tags, without a prompt) call
`dired-filetags--mark`, which uses `dired-mark-if` and binds
`dired-marker-char` to a space for the `C-u` unmark forms. Empty input means
"any tag" or "untagged". Directories, links to directories, `.`/`..` and
control files are never marked.

### TagTrees

`dired-filetags-tagtrees` builds a tree of the current directory, or
rebuilds the one it is in. `dired-filetags--tagtrees-target` names each
source's tree after its truename plus an md5 prefix, below
`dired-filetags-tagtrees-directory`. A sidecar `TREE.eld` next to the tree
records `:source`, `:recursive`, `:depth`, `:untagged` and `:time`;
`dired-filetags--tagtree-root` requires both the `.filetags_tagtrees`
marker and the sidecar, while `dired-filetags--inside-tagtree-p` matches any
tree.

Because filetags wipes the target before building, everything is checked
before a process starts: `dired-filetags--tagtrees-check` (local, not inside
a tree, target absent/empty/a tree, no "stranger" entries, no overlap with
the source, no concurrent build) and `dired-filetags--tagtrees-prescan`
(files that would make filetags abort after wiping, plus the link estimate
from `dired-filetags--permutations`). `dired-filetags--tagtrees-start` then
runs, asynchronously with `make-process` in the source directory:

```text
filetags -q --tagtrees --tagtrees-dir TARGET --filebrowser none \
  --tagtrees-depth N --tagtrees-handle-no-tag X [-R]
```

`dired-filetags--tagtrees-sentinel` writes the sidecar,
refreshes tree buffers, and visits the tree only if the originating window
still shows the originating buffer. `dired-filetags-visit-original` jumps to
a link's original; `dired-filetags--setup-tagtree-buffer` hides link
targets along with the details and, in trees this package built, installs
the header line.

### Rendering

`dired-filetags--fontify` is a `jit-lock-functions` member (depth 90, after
font-lock). It removes and recreates overlays tagged with the
`dired-filetags` property (priority 50, `evaporate`) on whole lines, and
skips wdired, `-b` listings and names hidden by
`dired-filename-display-length`. Its fast path is one `search-forward` for
" -- " over the region: without a match, no line is examined, so untagged
directories cost that search and nothing else. Errors are swallowed: it
must never signal in redisplay. `dired-filetags--decorate` handles the
styles: `right` hides the tag segment with `display ""` and
`dired-filetags--right-labels` adds labels at end of line after
`(space :align-to (- right (WIDTH) 2))`, with WIDTH from
`string-pixel-width`; `aligned` pads to `dired-filetags-align-width`;
`inline` colours in place. Tag colours hash
the tag with md5 into `dired-filetags-tag-colors`.

### Keymaps and mode

`dired-filetags-command-map` holds the tag commands (`a m n u v o`; there
is no `r` or `t`), and `dired-filetags-mark-map` adds `* #` and `* ~` to
Dired's `*` prefix.
`dired-filetags-mode-map` binds the prefix and `*` as
`(menu-item "" MAP :filter dired-filetags--unless-wdired)`, because the
minor mode stays on across wdired's major-mode switch and the filter
returns nil there so the keys self-insert. The filter tests for wdired
rather than for Dired: help commands evaluate it in their own buffer, and
`PREFIX C-h` (`describe-prefix-bindings`) must still see the tag map.

The prefix is `dired-filetags-prefix-key`, default `;`, which Dired leaves
unbound, so with the default the mode only adds bindings; `#` stays
`dired-flag-auto-save-files`. The option uses `custom-initialize-default`,
which keeps a value set before loading: a `setq`, or the theme value that
use-package's `:custom` stashes (as `saved-value`) while the option does
not exist yet. The keymap binds that value when it is defined, through
`dired-filetags--bind-prefix`. After loading, `setopt`, Customize and
themes call the `:set` function, `dired-filetags--set-prefix-key`, which
rebinds only if `dired-filetags-mode-map` is bound, and so moves the
binding in the shared map, in every open buffer at once.
`dired-filetags--bind-prefix` refuses invalid keys and keys starting with
`*`, unbinds the old prefix, and records the new one in
`dired-filetags--bound-prefix`. User-facing text never hard-codes a key:
messages, errors and the TagTree header line format keys with
`dired-filetags--key`, and docstrings say PREFIX and name the option,
because a docstring is written once and the prefix is the user's. The mode
function refuses non-Dired buffers, registers the jit-lock function, removes
overlays on `wdired-mode-hook`, refontifies on `text-scale-mode-hook`, and
undoes all of it when disabled. `dired-filetags-unload-function` turns the
mode off in every buffer first, because `unload-feature` only cleans global
hooks and would leave the jit-lock function in each buffer's local list.

## Critical Constraints

### filetags never renames a user file

Only empty stand-ins in scratch directories are passed to filetags for
retagging. Real renames go through `dired-create-files`/`dired-rename-file`
so VC, visiting buffers and marks follow. Keep the verify and preflight
steps between the oracle and the rename; never skip them for speed.

### Never run --tagtrees without --tagtrees-dir

Always pass `--tagtrees-dir` (a directory below
`dired-filetags-tagtrees-directory`, never `~/.filetags_tagfilter`) and
never `--overwrite`. All safety checks run before `make-process`, since
filetags deletes the target first. When testing by hand, run
`filetags --tagtrees` only inside a temporary directory, with
`--tagtrees-dir` inside it too.

### Buffer text is never modified

All decoration is overlays with the `dired-filetags` property. wdired
(`C-x C-q`) must keep showing the raw names, and the prefix key and `*`
must stay self-inserting there.

### The default prefix changes no Dired key

With the default `dired-filetags-prefix-key`, turning the mode on may only
add bindings on sequences Dired leaves unbound; a test compares every key
sequence of `dired-mode-map` and the mode's maps with the mode off and on,
and expects exactly `* #`, `* ~`, `;` and `; a m n o u v` to be added. The
README's `:` binding is the user's own change to `dired-mode-map`, not the
mode's.
In an untagged directory the fontifier's fast path must keep per-line work
at zero; a test counts calls to `dired-move-to-filename` and
`dired-filetags--decorate`.

### Remote directories stay unconnected where possible

The CLI and scratch directories are always local. Remote files have no
vocabulary, TagTrees are local only, and refresh code never expands another
host's paths. Several tests fail if a remote handler is contacted.

### Every supported Emacs compiles cleanly

`Package-Requires` says Emacs 29.1, and the flake checks with the locked
nixpkgs' `emacs-nox`, which can be older than the Emacs you develop in.
A call whose arity changed between versions, such as the two-argument
`string-pixel-width` of Emacs 31, still draws an arity warning from an
older byte compiler even inside a runtime `emacs-major-version` test, so
the `byte-compile` check fails there. `dired-filetags--right-labels` wraps
that call in `with-suppressed-warnings ((callargs string-pixel-width))`;
do the same for similar calls (`static-if` is Emacs 30+, newer than the
stated minimum).

### Tests use the real filetags in temporary directories

`dired-filetags-test--with-dir` creates a fresh directory and rebinds
`temporary-file-directory`, `dired-filetags-tagtrees-directory`,
`dired-log-buffer`, `dired-mode-hook` and the options, so nothing outside
it is touched. It also rebinds `dired-filetags-history`,
`extended-command-history`, `command-history`, `kill-ring`,
`kill-ring-yank-pointer` and `interprogram-cut-function`, so tests that
type into the minibuffer leave the user's histories, kill ring and
clipboard alone; `scripts/leak-check.el` enforces this. It also puts the
tag commands under the default prefix `;` with `setopt`
(`dired-filetags-test--with-prefix`) and restores the user's prefix
afterwards, so key tests pass in a session that uses another one.
It binds `dired-mode-map` to `dired-filetags-test--stock-dired-map`, which
is `dired-mode-map` itself unless the session has rebound `:` (as the
README's setup does), and then a child map with Dired's four EasyPG `:`
keys put back, so the EasyPG-merge assertions hold in that session too.
`dired-mode-map` itself is never modified.
`dired-filetags-test--vectors` records how filetags parses and renames
fifty-one awkward names; the parser tests check against them, and
`dired-filetags-oracle-matches-cli-vectors` checks that the real CLI still
produces them. When filetags changes behaviour, update the vectors from
the CLI, not from the parser.

Load-time behaviour is tested in a separate `emacs -Q -batch`, the same
executable as the running suite (`invocation-name`), so the session's own
definitions are never unloaded: `dired-filetags-prefix-key-set-before-loading`
(use-package `:custom` with a deferred load, and `setq`) and
`dired-filetags-unload-feature-turns-the-mode-off`.

### The leak check is the memory-sanitizer analogue

ASan and MSan would test Emacs's C core, not this package, so they do not
apply. The `leak` check runs the suite under `scripts/leak-check.el`,
which snapshots around every test and fails on anything new that is still
alive: buffers, processes, timers; `dired-filetags*` functions and
anonymous functions (closures, lambdas, compiled or not) gained or lost
on the default value of any `*-hook`, `*-hooks` or `*-functions`
variable (aliases skipped), or on its buffer-local value in a buffer
that existed before the test; entries gained or lost in
`file-name-handler-alist`; `dired-filetags` overlays in buffers that
existed before the test; files left in its private temporary directory;
bindings in `global-map`, `dired-mode-map` and every package keymap; the
values of every `dired-filetags-*` variable, every `*-history` (except
`load-history`), `kill-ring`, `process-environment` (names only) and
`exec-path` (values compared by contents, hash tables included);
`dired-filetags*` functions defined, redefined or undefined; and advice
added with `advice-add`. It also looks just before
`dired-filetags-test--with-dir` cleans up (`:before` advice on
`dired-filetags-test--cleanup`), since the fixture deletes its directory
and kills the buffers it made there, with their processes: a file left
in the fixture's temporary directory is a leak, and so is a buffer the
fixture would kill (a package buffer made while a Dired buffer below
the root is current inherits its directory), and a process that would
die with it, unless it is a Dired or wdired buffer on a directory below
the root, a buffer visiting a file there, the fixture's log buffer, the
buffer of a TagTrees build the fixture stops, or the fixture's own
temporary buffer. Its allowlist (each entry with its reason in the code)
is the buffers Emacs makes on first use and keeps (`*string-pixel-width*`,
`*code-conversion-work*` and the `*work*` buffers that Emacs 31's
`with-work-buffer` keeps for reuse, whose names start with a space, the
minibuffers, and VC's `*vc*`), `undo-auto--boundary-timer` and
Emacs 31's minibuffer idle timer `completions--background-update`
(which a batch Emacs never runs), five Tramp
file-name handlers (the two tramp-archive ones appear only with D-Bus,
on Linux), and edebug, `tramp-sh` and `tramp-cache`, preloaded because
loading edebug binds `C-x X` and advises `eval-defun`, and loading
tramp's ssh method and cache (which the remote-name tests do) adds
closures to tramp's own hooks.
Fix a leak in the test or the package; do not allowlist it. Never run the
leak check under undercover (it exits 2).

### Baselines change only deliberately

`baselines/coverage.txt` and `baselines/perf.eld` change only on purpose,
in a commit of their own, with the reason in the message. The Emacs
version and the system are part of every baseline key, so do not update
`flake.lock` casually: a bump that changes Emacs makes the coverage,
allocation and timing gates fail until `nix run .#update-baselines`
(and the Linux updates described under Baselines) are run. After changing `dired-filetags.el`,
check `nix run .#perf` and `nix run .#coverage`: line numbers and
allocations move. `coverage.sh` refuses to run while an `.elc` sits next
to a source, because undercover would instrument nothing.

### Bench allocations stay machine-independent

The allocation gate compares counts from any machine of a system, so a
workload may only gate counters that are identical in the dev shell, the
Nix sandbox and CI's checkout: no dependence on the time zone, the
locale, `HOME` or `TMPDIR`. bench.el's inputs are synthetic for this
reason; keep them so. Its files live in a directory it makes in `/tmp`,
never in `temporary-file-directory`, because the workloads that build
absolute file names (`:paths t`) allocate string characters, and take
time, in proportion to that directory's name: TMPDIR differs between
`nix develop` (`/tmp/nix-shell.XXXXXX`), a shell that sources
`nix print-dev-env` (under `/var/folders`), the Nix sandbox and CI,
while a directory in `/tmp` has a truename of one length per system
(41 characters on macOS, 33 on Linux). Every baseline records that
length (`:root-length`); mark a new workload that builds absolute names
`:paths t`, so that a run whose directory could not be in `/tmp` reports
those numbers instead of gating them.

### Fuzz divergences are fixed, not hidden

When a property finds a divergence, fix it in the package and add a
regression vector or test to `dired-filetags-test.el` (as the `.LNK`
base, the moved extension, the Unicode whitespace, the APFS ligature
and the `fold` idempotence fixes did), or document it as intended in
`dired-filetags-fuzz-test.el`'s Commentary (the only one today: filetags'
`$` matches before a final newline, and the package treats every name
with a newline as untagged). Never narrow the generator to make a
property pass.

The generators never call the package: they implement the documented
rules themselves and read names through the Python oracle, so a seed
makes the same inputs across package edits.
`dired-filetags-fuzz-rerun-regenerates-inputs` checks that input I is
the same in a run of I+1 iterations; register a new property's generator
in `dired-filetags-fuzz--generator` (and `--properties`) so the test
covers it.

### Never format LICENSE.md

Its copyright line has two spaces after `Wiegley.`, which prettier would
collapse; `.prettierignore` lists it and `format-all.sh` skips it by name.
The line is `Copyright (c) 2026, John Wiegley.  All rights reserved.`;
widen the years to the earliest and latest commit years when they differ.

### scripts/\*.el files define no indenting macros

`scripts/format-setup.el` evaluates only the root-level files' `defmacro`
forms, so a macro with `(declare (indent ...))` in `scripts/` would be
formatted differently in batch than in an editor. Keep such macros in a
root-level file.
