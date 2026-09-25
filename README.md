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
|-------------------|-------------------------------------------------------------------------------------------|
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
searched once for ` -- `, and if that isn't found, no line is examined.
With the default prefix, turning the mode on doesn't change any key Dired
already binds; it only adds keys that were free.

### Marking by tag

`; m` marks the files that have any of the tags you type, `; n` marks the
files that have none of them, and `; u` marks the files with no tags at
all. `C-u` in front of any of them unmarks instead. Since marks
accumulate, these forms combine:

| Selection       | Keys                              |
|-----------------|-----------------------------------|
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

This provides Emacs with `package-lint`, `format-all`, `relint` and
`dired-subtree` (for the two tests that use it), the `filetags` CLI the
tests drive, and `lefthook`, whose `pre-commit` hooks are installed on
entry.

### Keys

With the default prefix:

| Key          | Command                         | What it does                                                   |
|--------------|---------------------------------|----------------------------------------------------------------|
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

### Checks

The checks run via `nix flake check`, which covers:

- **ERT** for the name parser, the stand-in oracle, planning, renaming,
  marking, TagTrees and rendering, driving the real `filetags` (and `git`,
  for the version-control cases) in throwaway directories
- **Byte-compilation** of the package and its tests, with warnings
  treated as errors
- **package-lint** for package header and dependency conventions
- **checkdoc** for docstring style
- **relint** for regexp correctness
- **format** to confirm both files match `format-all`

A few tests need more than Emacs: `filetags` on `PATH`, `git` for the
version-control cases, and `dired-subtree` for two rendering and refresh
cases. Without them those tests skip rather than fail, so it's worth
reading the `skipped` count. The flake provides all three. The ERT suite
also runs outside Nix, from this directory:

```bash
emacs -Q -batch -L . --eval '(setq load-prefer-newer t)' \
  -l ert -l ./dired-filetags-test.el -f ert-run-tests-batch-and-exit
```

Pre-commit hooks (via lefthook) run the same checks in parallel on staged
files, and `nix flake check` when `flake.nix` or `flake.lock` changes.
Commit from inside `nix develop`, so the hooks see the same tools. To run
them all by hand:

```bash
lefthook run pre-commit --all-files
```

### Formatting

The formatting scripts need `format-all`, so run them inside
`nix develop`. To format both files in place:

```bash
scripts/format.sh dired-filetags.el dired-filetags-test.el
```

To check formatting without modifying:

```bash
scripts/check-format.sh dired-filetags.el dired-filetags-test.el
```

## License

BSD 3-Clause. See [LICENSE.md](LICENSE.md). filetags itself is Karl
Voit's work, under the GPL (version 3 or later), and it does all of the
hard thinking about names here.
