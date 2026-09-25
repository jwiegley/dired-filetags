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

```
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
development environment and the checks. `flake.nix` builds filetags from
source (`packages.filetags`, pinned to novoid/filetags `811c97b8`), and
`nix develop` gives Emacs (`emacs-nox` from the locked nixpkgs) with
`package-lint`, `format-all`, `relint` and `dired-subtree`, that `filetags`,
and `lefthook` (its `shellHook` runs `lefthook install`). ERT and
byte-compilation also run outside Nix with a local Emacs and `filetags` on
`PATH`; the lint and format commands need the Nix Emacs's packages.

**ERT** (the suite drives the real `filetags`):

```bash
emacs -Q -batch -L . --eval '(setq load-prefer-newer t)' \
  -l ert -l ./dired-filetags-test.el -f ert-run-tests-batch-and-exit
```

A single test or group, by regexp:

```bash
emacs -Q -batch -L . --eval '(setq load-prefer-newer t)' \
  -l ert -l ./dired-filetags-test.el \
  --eval '(ert-run-tests-batch-and-exit "dired-filetags-oracle")'
```

Tests that need the CLI use `(skip-unless (executable-find "filetags"))`; a
few also need `git`, and two need `dired-subtree`. A run without them
passes with skips, so read the `skipped` count in the summary before
trusting a green result. The flake's `ert` check puts `filetags` and
`gitMinimal` on `PATH` for this reason.

**Byte-compile** (warnings are errors; the flake compiles both files):

```bash
emacs --batch -L . \
  --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
  -f batch-byte-compile dired-filetags.el dired-filetags-test.el
```

This leaves `.elc` files next to the sources (git ignores them); delete
them afterwards, so a stale one is never loaded instead of a newer edit.
The lefthook hook compiles into a scratch directory instead.

**package-lint** (the package file only):

```bash
emacs --batch -L . -l package-lint -f package-lint-batch-and-exit dired-filetags.el
```

**checkdoc:**

```bash
emacs --batch -L . -l scripts/run-checkdoc.el dired-filetags.el dired-filetags-test.el
```

**relint:**

```bash
emacs --batch -L . -l relint -f relint-batch dired-filetags.el dired-filetags-test.el
```

**Formatting** (`format-all`):

```bash
scripts/format.sh dired-filetags.el dired-filetags-test.el        # in place
scripts/check-format.sh dired-filetags.el dired-filetags-test.el  # report only
```

Both scripts load `scripts/format-setup.el`, which sets `indent-tabs-mode`
to nil, turns off backup files (so `format.sh` leaves no `FILE.el~`), and
evaluates the project's `defmacro` forms so their `indent` declarations
apply in batch.

**All checks** (`ert`, `byte-compile`, `package-lint`, `checkdoc`,
`relint`, `format`; each runs with fresh `HOME` and `TMPDIR`):

```bash
nix flake check
```

A plain `nix flake check` in a git repository sees only tracked and staged
files. While the working tree has untracked files,
`nix flake check path:$PWD` evaluates the directory as it is.

**Pre-commit:** `lefthook.yml` runs byte-compile, format-check, checkdoc,
relint and ERT in parallel when `.el` files are staged, package-lint when
`dired-filetags.el` is, and `nix flake check` when `flake.nix` or
`flake.lock` is. Commit from inside `nix develop` so the hooks find the same
tools as the flake. Run them all by hand with
`lefthook run pre-commit --all-files`.

**CI:** `.github/workflows/ci.yml` runs `nix flake check --print-build-logs`
on `ubuntu-latest` for pushes and pull requests to `main`.

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
` -- ` at index 1 or later, extension of Python `\w` characters, trailing
`.lnk` stripped) and returns offsets. `dired-filetags-parse` returns
`(BASE TAGS EXT)` exactly as filetags reads it, keeping empty and `--`
tags; `dired-filetags--clean-tags` drops those. `dired-filetags--check-tags`
rejects tags filetags cannot apply (spaces, control characters, `/`, a
leading `-`, and the reserved `.`, `..`, `--`, `cuttimes`).
`dired-filetags--verify` compares an old and a predicted new name and
returns a reason string if the prediction is not a faithful retag; tags lost
to an exclusive group are allowed.

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
`dired-filetags--fold` (downcase plus NFC, as APFS compares).
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

```
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
` -- ` over the region: without a match, no line is examined, so untagged
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
it is touched. It also puts the tag commands under the default prefix `;`
with `setopt` (`dired-filetags-test--with-prefix`) and restores the user's
prefix afterwards, so key tests pass in a session that uses another one.
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
