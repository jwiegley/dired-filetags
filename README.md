# dired-filetags.el — Tag files in Dired with filetags

I've been naming files with Karl Voit's
[filetags](https://github.com/novoid/filetags) convention for a while now.
`Report -- work urgent.pdf` is a report tagged `work` and `urgent`, and
since the tags live in the name, every tool that can list a directory can
see them. What I was missing was a way to add and remove those tags, see
them, select files by them, and browse them, all without leaving Dired.

`dired-filetags.el` is a buffer-local minor mode for Dired that does this.
Its commands live under `;` (or whatever `dired-filetags-prefix-key` says).
`; a` adds tags, or removes a tag the files already have, and I also bind
it to `:` on its own. Tags show up as coloured labels, and `; v` builds
filetags' TagTrees. The thing it never does is decide on a new file name
by itself: that's always filetags' job.

## How it works

### filetags picks the names, Dired does the renaming

filetags has a lot of rules about names: where the tags end and the
extension begins, what a `.filetags` vocabulary allows, and which tags form
exclusive groups that push each other out. I didn't want to reimplement
those rules in Elisp and then chase every difference, so the package asks
the real CLI instead.

For each file being retagged, it creates an empty stand-in with the same
name in a scratch directory of its own (below `temporary-file-directory`),
next to a `.filetags` that `#include`s the vocabulary governing the real
file. It runs `filetags -q --tags=...` on the stand-ins, reads back what
they became, and deletes the scratch directory. filetags never sees a
user file.

The real renames go through `dired-create-files` and `dired-rename-file`,
the same path `R` takes, so version control (when `dired-vc-rename-file`
says so), visiting buffers and marks all follow the files.

Every predicted name is checked before anything is renamed. A file is
skipped if filetags would change more than its tags, would lose a tag you
added or keep one you removed, or would leave an empty or `--` tag behind.
It's also skipped if the new name already exists, is visited by a buffer,
or is what another selected file would become (compared case- and
Unicode-insensitively, the way APFS compares names). Tags that disappear
because an exclusive group replaced them are fine. Each skipped file is
logged with its reason, and `?` in Dired shows the log.

The CLI does have some surprising corners, which is why none of this is
optional. Adding `NEW` to a file called `v1.2 notes` gives
`v1 -- NEW.2 notes`, because filetags reads `.2 notes` as the extension.
I'd rather the package skip that file and tell me than rename it.

### Adding and removing tags

`; a` (`dired-filetags-add-remove`) is the only tagging key. It works on
the marked files, or the file at point, and you name one or more tags.
Each tag is decided separately, across the whole selection:

- A tag that every selected file already has is removed from all of them.
- Any other tag is added to the files that lack it. Files that already
  have it are left alone.

On a single file, that means naming a tag it has removes it, and naming
one it lacks adds it. On `Report -- work urgent.pdf`, `; a urgent RET`
gives `Report -- work.pdf`, and doing it again gives back
`Report -- work urgent.pdf`, since filetags appends new tags. One prompt
can do both: `; a urgent draft RET` on the original removes `urgent` and
adds `draft`, giving `Report -- work draft.pdf`.

A mixed selection is one where some files have a tag and others don't.
There, the first `; a` adds the tag to the files that lack it, so that
they all have it. A second `; a` with the same tag then removes it from
all of them. Apart from exclusive groups (below), a single `; a` never
adds a tag to some files and removes it from others, so this pair doesn't
restore a mixed selection: after two presses, none of the files has the
tag.

Exclusive groups in the governing `.filetags` apply here as they do
everywhere in filetags: adding a tag from a group replaces its group
mates. With the line `draft final` in `.filetags`, `; a final RET` on
`doc -- draft.txt` gives `doc -- final.txt`, and a second `; a final RET`
gives `doc.txt`. The displaced `draft` doesn't come back, even on a
single file. Naming two mates on a mixed selection can swap them: with
`a -- draft.txt` and `b -- final.txt` marked, `; a draft final RET`
gives `a -- final.txt` and `b -- draft.txt`.

The prompt names the file (`Add or remove tags on Report.pdf:`) or counts
them (`Add or remove tags on 3 files:`). The selected files' own tags are
offered first, each noted `on K/N` for how many of the N files have it.
Then come the other tags in the buffer, with their counts, and then the
words of the governing `.filetags`.

For a command that only adds or only removes, there are
`M-x dired-filetags-add` and `M-x dired-filetags-remove`, which have no
key. `dired-filetags-add` never removes anything, and
`dired-filetags-remove` only accepts tags the files have.

### Seeing the tags

`dired-filetags-display-style` picks one of four styles:

| Style             | What you see                                                                              |
| ----------------- | ----------------------------------------------------------------------------------------- |
| `right` (default) | `Report.pdf`, with `work` and `urgent` as labels ending two columns from the right edge   |
| `aligned`         | `Report.pdf`, with the labels in a column `dired-filetags-align-width` (32) columns along |
| `inline`          | The name as it is, with each tag coloured in place                                        |
| `nil`             | No decoration                                                                             |

In `right` style the padding before the labels is a display spec,
`(space :align-to (- right (PIXELS) 2))`, so redisplay recomputes it when
the window changes width, and two windows showing the same buffer each lay
it out for their own width. A label's colour comes from hashing its tag
into `dired-filetags-tag-colors`; `dired-filetags-tag-faces` overrides
particular tags.

All of this is overlays, applied through jit-lock. The buffer text never
changes, which means `C-x C-q` (wdired) still shows the raw names -- and
that's where I go to repair a garbled name by hand.

Most of my directories have no tagged files at all, so the mode has to
cost nothing there. Each stretch of lines that jit-lock hands it is
searched once for " -- ", and if that isn't found, no line is examined.
With the default prefix, turning the mode on doesn't change any key Dired
already binds; it only adds keys that were free.

### Marking by tag

`; m` marks the files that have any of the tags you type, `; n` marks the
files that have none of them, and `; u` marks the files with no tags at
all. `C-u` in front of any of them unmarks instead. Since marks
accumulate, these forms combine:

| Selection       | Keys                              |
| --------------- | --------------------------------- |
| a or b          | `; m a b RET`                     |
| a and b         | `; m a RET`, then `C-u ; n b RET` |
| a and not b     | `; m a RET`, then `C-u ; m b RET` |
| neither a nor b | `; n a b RET`                     |
| untagged        | `; u`                             |

Empty input to `; m` means "any tag", and to `; n` it means "untagged",
the same as `; u`. Only files are marked, never directories or filetags'
own `.filetags` and `.filetags_tagtrees`, and the lines of inserted
subdirectories count too.

Tag prompts use `completing-read-multiple` with spaces or commas as the
separator, so a space always ends a tag, even under orderless. Candidates
come from the tags in the buffer (with counts), the tags on the selected
files, and the words of the governing `.filetags`. In vertico, `RET`
takes the highlighted candidate and `C-j` submits exactly what you typed,
which is how you add a new tag that happens to be a prefix of an existing
one.

### TagTrees

`; v` runs `filetags --tagtrees` in the background for the current
directory (`C-u ; v` includes subdirectories) and visits the result when
it's ready. A TagTree is a directory of symbolic links with one folder per
tag, and folders for combinations of tags inside those, down to
`dired-filetags-tagtrees-depth` (2 by default). Each source directory gets
its own tree below `dired-filetags-tagtrees-directory`, which is
`~/.cache/dired-filetags/tagtrees/` unless `XDG_CACHE_HOME` says
otherwise. The package always passes `--tagtrees-dir` and never
`--overwrite`, so filetags' default of `~/.filetags_tagfilter` is left
alone.

filetags wipes a tree before it builds it, so all the checking happens
first. The target has to be absent, empty, or a tree filetags made, and
anything inside it that isn't one of filetags' links stops the build.
Files that would make filetags give up halfway, such as a name with a
repeated tag or two files that would share a name in one tag folder, are
logged before any process starts. A first build that would make more
than `dired-filetags-tagtrees-link-limit` (50,000) links, by estimate,
asks before it runs.

In a tree this package built, the header line names the source directory
and the tag path you're in, and `; v` rebuilds the tree with the
parameters it was built with. Retagging a link there retags its original
and then rebuilds the tree. In any tree, `; o` jumps to the original file
behind the link at point.

In a remote Dired buffer, filetags still runs locally on the stand-ins,
with no vocabulary. TagTrees need a local directory.

## Getting started

You'll need Emacs 29.1 or later, and the `filetags` program somewhere on
`exec-path` (or `dired-filetags-program` set to it). The flake here
builds filetags from source as `packages.filetags`, if you'd like it from
Nix. Then:

```elisp
(use-package dired-filetags
  :load-path "lisp/dired-filetags"
  :hook (dired-mode . dired-filetags-mode))
```

Here `lisp/dired-filetags` is this checkout, relative to
`user-emacs-directory`. The rest of the options are in
`M-x customize-group RET dired-filetags`.

The default prefix is `;` because Dired leaves it unbound. Tagging is
what I do most, though, so I want `; a` on a single key. This is my
setup, and the one I'd recommend:

```elisp
(use-package dired-filetags
  :load-path "lisp/dired-filetags"
  :hook (dired-mode . dired-filetags-mode)
  :bind (:map dired-mode-map
              (":" . dired-filetags-add-remove)))
```

Now `:` runs `dired-filetags-add-remove` directly, and everything else
stays under `;`. In Dired, `:` is normally EasyPG's prefix map (`: d`
decrypts, `: e` encrypts, `: s` signs and `: v` verifies), and this
binding displaces that map. I don't use those keys, and their commands
(`epa-dired-do-decrypt`, `epa-dired-do-encrypt`, `epa-dired-do-sign` and
`epa-dired-do-verify`) are still there with `M-x`. wdired (`C-x C-q`)
has its own keymap, which doesn't inherit `dired-mode-map`, so `:` still
inserts itself while you're editing names.

The prefix itself can move too, through `dired-filetags-prefix-key`. Set
it with use-package's `:custom`, which works before the package is
loaded, or with `setopt` or Customize, which move the keys at once, even
in Dired buffers that are already open. A plain `setq` only takes effect
if it runs before the package loads. The prefix can't start with `*`,
where the mode adds `* #` and `* ~`. It can be `:`, whose EasyPG keys
then keep working except `: v`, which becomes TagTrees, because prefix
maps merge. Don't combine that with the `:` binding above, though: the
mode's prefix wins over a binding in `dired-mode-map`, so `:` would stay
a prefix.

For working on the package itself, Nix gives you a shell with everything:

```bash
nix develop
```

That's Emacs 30.2 from the locked nixpkgs, with `package-lint`,
`format-all`, `relint`, `undercover` and `dired-subtree`; the `filetags`
CLI the tests drive, and a Python that can load filetags' own source for
the fuzzer; bash 5, git and lcov; and every formatter and linter the
targets below call. Entering the shell also installs the lefthook
`pre-commit` hooks.

### Keys

With the default prefix:

| Key          | Command                         | What it does                                                   |
| ------------ | ------------------------------- | -------------------------------------------------------------- |
| `; a`        | `dired-filetags-add-remove`     | Add tags, or remove a tag that every selected file has         |
| `; m`, `* #` | `dired-filetags-mark`           | Mark files with any of the tags (`C-u`: unmark)                |
| `; n`, `* ~` | `dired-filetags-mark-not`       | Mark files with none of the tags (`C-u`: unmark)               |
| `; u`        | `dired-filetags-mark-untagged`  | Mark the files that have no tags (`C-u`: unmark)               |
| `; v`        | `dired-filetags-tagtrees`       | Build TagTrees (`C-u`: recursive), or rebuild the current tree |
| `; o`        | `dired-filetags-visit-original` | Visit the original of the link at point                        |
| none         | `dired-filetags-add`            | Only add tags (`M-x`)                                          |
| none         | `dired-filetags-remove`         | Only remove tags (`M-x`)                                       |

With the recommended setup above, `:` is `; a` as well. As with other
Dired commands, a numeric prefix to `; a` (or `:`) means the next N files
instead of the marked ones. `; C-h` lists the bindings. Messages and the
TagTree header line name keys with whatever prefix you've set.

### Prior art

If you'd rather not depend on the CLI,
[filetags.el](https://github.com/DerBeutlin/filetags.el) on MELPA
reimplements the naming convention in Elisp and updates tags from Dired
with `filetags-dired-update-tags`. Protesilaos Stavrou's
[denote](https://protesilaos.com/emacs/denote) has its own naming scheme,
with keywords after `__`, and its own Dired fontification. This package
exists because I already had a lot of files named by filetags, and I
wanted the program itself to stay the authority on what those names mean.

## Development

After modifying `dired-filetags.el`, reload it in your running Emacs:

```elisp
(unload-feature 'dired-filetags t)
(load-file "dired-filetags.el")
```

Unloading turns the mode off in every buffer and also takes it off
`dired-mode-hook`, so afterwards run
`(add-hook 'dired-mode-hook #'dired-filetags-mode)`, and
`M-x dired-filetags-mode` in the Dired buffers that are already open.
Custom forgets a use-package `:custom` value across the reload too, so a
prefix set that way comes back as `;`; `setopt` it again, as in
`(setopt dired-filetags-prefix-key "C-c t")`.

### Targets

| Command                                    | What it does                                                           |
| ------------------------------------------ | ---------------------------------------------------------------------- |
| `nix build`                                | Builds the package, autoloads included, with every warning an error    |
| `nix flake check`                          | Builds and runs the fourteen checks below                              |
| `nix run .#test [-- REGEXP]`               | Runs the ERT suite, or just the tests matching REGEXP                  |
| `nix run .#format`, `nix fmt [-- PATH...]` | Formats every file, or the PATHs                                       |
| `nix run .#lint [-- CHECK...]`             | Runs all eleven linters, or the ones named                             |
| `nix run .#coverage`                       | Writes `reports/coverage/` and checks it against the baseline          |
| `nix run .#perf`                           | Measures this machine: writes `reports/perf/` and runs both perf gates |
| `nix run .#fuzz [-- --seconds N]`          | Fuzzes with fresh seeds for ten minutes, or N seconds                  |
| `nix run .#fuzz -- --seed S`               | Replays one seed                                                       |
| `nix run .#update-baselines`               | Records this machine's coverage and performance numbers                |
| `nix build .#coverage`                     | The coverage report, as lcov data, a summary and HTML                  |
| `nix build .#perf-report`                  | A reference profile, measured in a Nix build sandbox                   |

`nix build` makes the package the way nixpkgs makes the ones it takes
from MELPA, with `dired-filetags-autoloads.el`, byte- and
native-compiled by a bare Emacs, so that a stray `require` of one of the
dev tools can't sneak through. That also means `packages.default` works
as it is in `emacsWithPackages`.

The apps run from any directory of the checkout, and the PATHs and
FILEs you give `format` and `lint` are relative to the one you're in.
Formatting means format-all for Emacs Lisp, nixfmt, shfmt, and prettier
for YAML and Markdown. `LICENSE.md` is left alone, because prettier
would collapse the two spaces in its copyright line.

`nix build .#perf-report` isn't a measurement of the machine you run it
on. The first time I built it on my laptop, Nix handed me a profile that
one of my build servers had measured. It's measured once,
in whichever build sandbox gets to it, and cached by input hash from
then on. Its allocation counts hold for every machine of the system,
which is what the `perf` check gates, but its timings belong to that one
build, and `PROVENANCE.txt` and the top of `perf.txt` say where and when
that was. For numbers from the machine in front of you, run
`nix run .#perf`. CI uploads both reports.

The flake offers aarch64-darwin, aarch64-linux and x86_64-linux, the
systems that have baselines. There's no x86_64-darwin: nixpkgs warns
that its support is ending, and the `--option abort-on-warn true` that
the hooks and CI pass turns that warning into an error.

### Checks

`nix flake check` runs each of these in a fresh sandbox that gets only
the files and tools it uses, so a README edit rebuilds three of them,
not all fourteen:

- `build`: the package, as above
- `ert`: the ERT suite, driving the real `filetags` (and `git`) in
  throwaway directories
- `leak`: the suite again, failing on anything a test leaves behind
- `fuzz`: the property tests, with the fixed seed and 1000 inputs each
- `coverage`: line coverage against its baseline
- `perf`: allocations against their baseline, with timings reported only
- `format`: every file is formatted
- `lint`: check-declare, statix, deadnix, shellcheck, yamllint,
  `lefthook validate`, actionlint, zizmor and rumdl
- `byte-compile`: every `.el` file, with every warning an error
- `native-compile`: the package, failing on any native-compiler warning
- `package-lint`: package headers and conventions
- `checkdoc`: docstring style
- `relint`: the regexps
- `apps`: every app, the formatter and the dev shell build, and the
  apps run from a subdirectory with nothing but `/usr/bin` and `/bin` on
  `PATH`, without changing or leaving a file

ERT counts a skipped test as a pass, and without `filetags`, `git` or
`dired-subtree` the suite skips dozens of them. So everything that runs
the suite (the `ert` and `leak` checks, `nix run .#test`, the pre-commit
jobs and coverage) fails when more than one test skips. One always
does: of the two case-sensitivity tests, only one fits the file system.
If you run plain ERT outside Nix, read the `skipped` count before
trusting a green result.

### Pre-commit

lefthook calls the same scripts. Everything goes into one parallel group
(the formatter, the linters, ERT, the leak check, the fuzzer, coverage,
and `nix build` and `nix flake check` when Nix files change), and then
the timing gate runs by itself. It has to: timings taken while four
copies of the suite load every core measure the load, not the code.

The formatter and the linters look only at the files being committed,
so a stray draft can't block a commit, unless one of them is a script or
setting behind those tools; then they check everything in the index. The
hook works from any git client: inside `nix develop` it runs lefthook
directly, and anywhere else, Magit included, it reruns itself through
`nix develop`, so the jobs always see the same tools and baselines. Run
them all by hand with `lefthook run pre-commit --all-files`.

CI runs the same hooks on Linux and macOS, except the two Nix jobs,
which it runs as steps of their own. Alongside those come `nix build`,
the report builds, and an evaluation of every system the flake offers,
so a new Nix warning on any of them fails the run, even one for a
system CI doesn't build.

### Baselines

`baselines/` holds the numbers the gates compare against:

- **Coverage** (`coverage.txt`) is keyed by system and Emacs version.
  It fails only when more lines go unrun _and_ the covered fraction
  drops, so deleting covered code, or adding well-tested code, passes.
- **Allocations** (`perf.eld`) are keyed by system, Emacs version and
  native compilation. `memory-use-counts` is deterministic, so they're
  checked on any machine, and fail at 5% over. Every counter counts,
  including the string characters of the workloads that build file
  names: their files live in a directory in `/tmp`, so those names are
  the same length in the dev shell, the Nix sandbox and CI.
- **Timings** (`perf.eld` too) are keyed by system and host name. Each
  workload's fastest sample is divided by the lower quartile of the
  samples of a calibration loop interleaved with it in the same run, so
  the power source and Low Power Mode mostly cancel out, and samples
  taken while the machine was busy don't count. One that comes in over
  1.05 times its baseline (1.08 when the power mode isn't the one the
  baseline was recorded in) is re-measured; if it's still over, two
  fresh Emacs processes measure it too, and it fails only if the median
  of the three is over. Anywhere without an entry, CI and Nix builders
  included, timings are only reported, and the output says so; so does
  a run that lands on an efficiency core, where the ratios don't hold.

A gate with nothing to compare against fails rather than passing: a
missing baseline file, no entry for the system, or one recorded with
another Emacs. After a deliberate change, run
`nix run .#update-baselines` and commit the diff on its own. A
`flake.lock` bump that changes Emacs fails the gates until you do. It
records the median of three Emacs processes' timings, so the entry sits
in the middle of what a gate run sees. It won't record timings from a
run with too few clean samples, or one whose calibration is much slower
than the entry it would replace; it says why and stops, with the
allocations already written. The other systems'
numbers come from their `.#packages.SYS.coverage` and
`.#packages.SYS.perf-report` builds; CLAUDE.md has the commands.

The timing gate was the hardest part to get right. Its first version
failed about half its runs on unchanged code while my MacBook was on
battery, and it took a pile of raw samples to see that Low Power Mode
wasn't the cause. The failing runs were the ones where Emacs had landed
on an efficiency core, which is two and a half times slower, and where
the ratios don't hold. Three smaller effects took longer to find. The
benchmark's files lived in `$TMPDIR`, whose name has a different length
in each kind of shell, and two workloads take longer the longer their
file names are, so the same code measured 5% apart depending on where I
ran it; the files live in `/tmp` now. Every ratio was divided by the
single fastest calibration sample, so one lucky sample could push all
of them up by a few percent; it's the lower quartile now. And a ratio
wobbles by a percent or two from one Emacs process to the next, which
no number of samples in one process can average away, hence the median
of three processes, both for the baseline and before a failure counts.

### Fuzzing

`dired-filetags-fuzz-test.el` checks nine properties on generated names
and tags. The main one compares the parser with filetags' own
`FILE_WITH_TAGS_REGEX`, run by Python from the pinned source; the others
cover round trips, tag checking, verification, and the real CLI on
batches of stand-ins. `DIRED_FILETAGS_FUZZ_SEED` and
`DIRED_FILETAGS_FUZZ_ITERATIONS` pick the inputs, and each property
reseeds from `SEED:PROPERTY`, so a seed gives the same inputs on every
system. A failure prints the seed, the input, a shrunk input, and the
command that replays it, `scripts/fuzz.sh --seed S --iterations N`.
The inputs depend only on the seed, never on the package's code, and a
test checks that the replay command regenerates exactly the failing
input.

There's one intended difference from filetags. Its regexp ends in `$`,
which also matches before a final newline, so filetags reads
`"a -- b\n"` as tagged; this package treats every name with a newline as
untagged.

### The leak check

AddressSanitizer and MemorySanitizer don't apply here: they'd be testing
Emacs's C core, not this package. What a Lisp package can get wrong is
the state a test leaves behind, so the `leak` check runs the suite under
`scripts/leak-check.el`, which compares snapshots before and after every
test and fails on new buffers, processes, timers, hook entries (the
package's functions and any closure, global or buffer-local), overlays,
temporary files, key bindings or advice, and on changes to the
package's variables (hash tables compared by contents), the minibuffer
histories and the kill ring. It also looks just before the test fixture
cleans up, since the fixture deletes its directory and kills the
buffers made in it: a buffer the package leaked while a Dired buffer
there was current would otherwise vanish unseen, along with its
process. The
first time it ran, it caught four tests that, run inside my Emacs, would
have added to my histories and kill ring.

### Documentation

There's nothing to build. This README is the documentation, GitHub
renders it, and rumdl and prettier keep it tidy along with the rest of
the Markdown.

## License

BSD 3-Clause. See [LICENSE.md](LICENSE.md). filetags itself is Karl
Voit's work, under the GPL (version 3 or later), and it does all of the
hard thinking about names here.
