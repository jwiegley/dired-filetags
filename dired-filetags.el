;;; dired-filetags.el --- Tag files in Dired with filetags -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <johnw@newartisans.com>
;; Maintainer: John Wiegley <johnw@newartisans.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: files
;; URL: https://github.com/jwiegley/dired-filetags

;;; Commentary:

;; `dired-filetags-mode' shows the tags of filetags names such as
;; "Report -- work urgent.pdf" as coloured labels, and binds tag commands
;; under `dired-filetags-prefix-key', ";" by default.  Dired leaves ";"
;; unbound, so the mode changes none of Dired's own keys.  Enable it with:
;;
;;   (use-package dired-filetags
;;     :hook (dired-mode . dired-filetags-mode))
;;
;;   ; a   add or remove tags       ; m, * #   mark files with any of the tags
;;   ; v   build TagTrees           ; n, * ~   mark files with none of them
;;   ; o   visit a link's original  ; u        mark the untagged files
;;
;; ; a adds each tag you name, except that a tag every selected file
;; already has is removed from all of them.  On one file, naming a tag it
;; has removes it.  C-u before ; v includes subdirectories, and C-u
;; before ; m, ; n or ; u unmarks instead.  Empty input to ; m means
;; "any tag", and to ; n it means "untagged".
;;
;; `dired-filetags-add' only adds and `dired-filetags-remove' only
;; removes; they have no key.  To run ; a on a single key, bind
;; `dired-filetags-add-remove' in `dired-mode-map', for example with
;;
;;     :bind (:map dired-mode-map (":" . dired-filetags-add-remove))
;;
;; in the form above.  That replaces Dired's EasyPG prefix ":", whose
;; commands stay available with M-x.
;;
;; The filetags program chooses every new name: it renames empty stand-in
;; files in a scratch directory, under the real .filetags vocabulary.
;; Dired then renames the real files, as R would, so version control,
;; visiting buffers and marks follow.  Each predicted name is checked
;; before anything is renamed.  Files that filetags would garble, or that
;; would collide with another name, are skipped, and ? shows why.
;;
;; Tags are separated by spaces or commas, under any completion UI, so a
;; space always ends a tag, even for orderless.  In vertico, RET takes
;; the highlighted candidate.  C-j submits the typed input as is: a new
;; tag that is a prefix of an existing one, or the empty input of ; m
;; and ; n.  RET after a trailing space or comma also submits only what
;; was typed, rather than adding the highlighted candidate, unless you
;; moved to that candidate with C-n or C-p.
;;
;; C-x C-q (wdired) shows the raw names, for free-form repair.
;;
;; TagTrees are built per source directory below
;; `dired-filetags-tagtrees-directory', ~/.cache/dired-filetags/tagtrees/
;; by default.  ; v inside a tree rebuilds it.  Each build replaces the
;; whole tree, so a tree that holds anything but filetags' own links is
;; not rebuilt, and files inside a tree cannot be tagged there.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'dired)
(require 'dired-aux)
(require 'crm)
(require 'ansi-color)
(require 'ucs-normalize)
(require 'jit-lock)

;;;; Options

(defgroup dired-filetags nil
  "Tag files in Dired with the filetags naming convention."
  :group 'dired
  :prefix "dired-filetags-")

(defcustom dired-filetags-program "filetags"
  "The filetags executable.
Resolved against the variable `exec-path' if unqualified."
  :type 'string
  :group 'dired-filetags)

(defvar dired-filetags-mode-map)        ; `defvar-keymap' below

(defun dired-filetags--set-prefix-key (symbol key)
  "Set SYMBOL, `dired-filetags-prefix-key', to KEY, and rebind the prefix.
If the keymap of `dired-filetags-mode' exists, the tag commands move
to KEY in it at once, in every buffer.  Before the package is loaded
only the value is set, and the keymap binds it when it is defined."
  (when (boundp 'dired-filetags-mode-map)
    (dired-filetags--bind-prefix key))
  (set-default symbol key))

(defcustom dired-filetags-prefix-key ";"
  "Prefix key of the tag commands in `dired-filetags-mode'.
The default, \";\", is unbound in Dired, so the mode changes none of
Dired's own keys.

\":\" is Dired's EasyPG prefix.  Prefix maps merge, so with \":\" the
EasyPG keys still work except \": v\", `epa-dired-do-verify', which
becomes the TagTrees command.  To keep it, move EasyPG's map to
another key of `dired-mode-map'.  The prefix may not start with \"*\",
which holds the mode's additions to Dired's marking keys.

To run PREFIX a, `dired-filetags-add-remove', on a single key, bind the
command to that key in `dired-mode-map' and leave this option alone.

Setting this with `setopt' or Customize moves the commands at once,
also in open Dired buffers.  A plain `setq' works only before the
package is loaded."
  :type 'key
  :initialize #'custom-initialize-default
  :set #'dired-filetags--set-prefix-key
  :group 'dired-filetags)

(defcustom dired-filetags-display-style 'right
  "How `dired-filetags-mode' shows tags.
`right' shows the name without its tags and the tags as labels two
columns from the right edge of the window, wherever its edge currently
is, mirroring the two columns before each name;
`aligned' shows the extension right after the name and the labels in a
column; `inline' colours the tags in place; nil leaves names
undecorated.  A change takes effect when a buffer is next reverted or
the mode is re-enabled.  It may be set buffer-locally."
  :type '(choice (const :tag "Name without tags, tags at the right edge" right)
                 (const :tag "Extension after the name, tags in a column" aligned)
                 (const :tag "Coloured tags in place" inline)
                 (const :tag "No decoration" nil))
  :group 'dired-filetags)

(defcustom dired-filetags-align-width 32
  "Columns from the start of a file name to its first tag in `aligned' style.
There are always at least 2 columns of padding."
  :type 'natnum
  :group 'dired-filetags)

(defcustom dired-filetags-tag-colors
  '("#4D0000" "#4D2600" "#4D4D00" "#264D00" "#004D00" "#004D26"
    "#004D4D" "#00264D" "#00004D" "#26004D" "#4D004D" "#4D0026")
  "Background colours of tag labels; each tag hashes to one of them.
The defaults are the palette-*-darker colours that
`org-agenda-overlay-by-filetag' uses."
  :type '(repeat color)
  :group 'dired-filetags)

(defcustom dired-filetags-tag-faces nil
  "Alist of (TAG . FACE) overriding the hashed colour of TAG.
FACE is a face name or a plist of face attributes, for example
\((\"urgent\" . error))."
  :type '(alist :key-type (string :tag "Tag")
                :value-type (choice face (plist :tag "Face attributes")))
  :group 'dired-filetags)

(defcustom dired-filetags-tagtrees-directory
  (expand-file-name "dired-filetags/tagtrees/"
                    (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Parent directory of the per-source TagTrees.
Each source directory gets its own tree below it.  This directory must
be dedicated to this package, and it must never be ~/.filetags_tagfilter."
  :type 'directory
  :group 'dired-filetags)

(defcustom dired-filetags-tagtrees-depth 2
  "Value of filetags' --tagtrees-depth.
Link counts grow as k!/(k-d)! for a file with k tags at depth d: a
file with 5 tags gets 25 links at depth 2 and 85 at depth 3."
  :type '(natnum :tag "Depth")
  :group 'dired-filetags)

(defcustom dired-filetags-tagtrees-untagged "no-tags"
  "Value of filetags' --tagtrees-handle-no-tag.
A folder name such as \"no-tags\" (Karl Voit's own choice) collects the
untagged files; \"treeroot\" links them at the tree root and \"ignore\"
leaves them out.  \"treeroot\" fails when the source directory contains
a .filetags file.  A folder name is a single file name component:
filetags wipes the folder it names, so it may not contain \"/\"."
  :type '(choice (const :tag "At the tree root" "treeroot")
                 (const :tag "Leave out" "ignore")
                 (string :tag "In this folder"
                         :match (lambda (_widget value)
                                  (dired-filetags--untagged-valid-p value))))
  :group 'dired-filetags)

(defcustom dired-filetags-tagtrees-link-limit 50000
  "Ask before building TagTrees with more estimated links than this."
  :type 'natnum
  :group 'dired-filetags)

;;;; Faces

(defface dired-filetags-tag '((t :foreground "#eeeeee"))
  "Base face of tag labels.
The background and box come from the tag's colour; see
`dired-filetags-tag-colors'."
  :group 'dired-filetags)

(defface dired-filetags-separator '((t :foreground "grey40"))
  "Face of \" -- \" in `inline' style and of literal \"--\" tags."
  :group 'dired-filetags)

(defface dired-filetags-added '((t :inherit success))
  "Face of +TAG in retagging messages."
  :group 'dired-filetags)

(defface dired-filetags-removed '((t :inherit error))
  "Face of -TAG in retagging messages."
  :group 'dired-filetags)

;;;; Internal variables

(defvar dired-filetags-history nil
  "Minibuffer history of tag prompts.")

(defvar-local dired-filetags--tagtree nil
  "TagTree state of this buffer.
It is nil outside TagTrees, t in a foreign tree, and the sidecar plist
plus :root in a tree built by this package.")

(defconst dired-filetags--crm-separator
  (propertize "[ \t]*[ ,][ \t]*" 'separator " " 'description "space-separated tags")
  "The `crm-separator' of tag prompts: spaces or commas.")

(defconst dired-filetags--reserved-tags '("." ".." "--" "cuttimes")
  "Tags that filetags gives a special meaning, so they cannot be added.")

(defconst dired-filetags--control-files '(".filetags" ".filetags_tagtrees")
  "Basenames of filetags' own files, which are never tagged or marked.")

(defconst dired-filetags--chunk-size 500
  "Maximum number of stand-ins per filetags call, for ARG_MAX safety.")

(defvar dired-filetags--cache nil
  "Hash table memoizing file checks during one command, or nil.
Only `dired-filetags--with-cache' binds it; it is never set.")

(defmacro dired-filetags--with-cache (&rest body)
  "Run BODY with memoized file lookups, unless a caller already does so."
  (declare (indent 0) (debug t))
  `(let ((dired-filetags--cache (or dired-filetags--cache (make-hash-table :test #'equal))))
     ,@body))

(defun dired-filetags--memo (key fn)
  "Return (funcall FN), memoized under KEY.
The value is remembered only while `dired-filetags--cache' is bound."
  (if (not dired-filetags--cache)
      (funcall fn)
    (let ((hit (gethash key dired-filetags--cache :none)))
      (if (eq hit :none) (puthash key (funcall fn) dired-filetags--cache) hit))))

(defun dired-filetags--pretty-dir (dir)
  "Return directory DIR as messages show it: abbreviated, without a slash."
  (abbreviate-file-name (directory-file-name dir)))

(defvar dired-filetags--bound-prefix nil
  "The key under which `dired-filetags-mode-map' binds the tag commands.")

(defun dired-filetags--key (key)
  "Return the tag command KEY after its prefix key, as messages show it.
The prefix is the one bound, which is `dired-filetags-prefix-key'."
  (key-description (vconcat (key-parse (or dired-filetags--bound-prefix
                                           dired-filetags-prefix-key))
                            (key-parse key))))

;;;; Name model

(defun dired-filetags--word-char-p (char)
  "Return non-nil if CHAR matches Python 3 `\\w', the filetags extension alphabet."
  (or (eq char ?_)
      (memq (get-char-code-property char 'general-category)
            '(Lu Ll Lt Lm Lo Nd Nl No))))

(defun dired-filetags--lnk-p (name)
  "Return non-nil if NAME ends in \".lnk\" in any letter case."
  (let ((case-fold-search nil))
    (string-match-p "\\.[lL][nN][kK]\\'" name)))

(defun dired-filetags--split (name)
  "Return (SEP TAGS-END STEM-END) for basename NAME, or nil if untagged.
This mirrors filetags' FILE_WITH_TAGS_REGEX (.+?) -- (.+?)(\\.(\\w+))??$
after stripping a trailing .lnk.  SEP is the index of the first \" -- \"
at index 1 or later, the tags run from SEP+4 to TAGS-END, the extension
\(if any) runs from TAGS-END+1 to STEM-END, and STEM-END excludes .lnk."
  (let* ((stem-end (if (dired-filetags--lnk-p name) (- (length name) 4) (length name)))
         (sep (and (not (string-search "\n" name))
                   (string-search " -- " name 1))))
    (when (and sep (< (+ sep 4) stem-end))
      (let* ((beg (+ sep 4))
             ;; Last dot at index >= 1 of the tag string.
             (dot (cl-loop for i downfrom (1- stem-end) above beg
                           thereis (and (eq (aref name i) ?.) i))))
        (list sep
              (if (and dot (< (1+ dot) stem-end)
                       (cl-loop for i from (1+ dot) below stem-end
                                always (dired-filetags--word-char-p (aref name i))))
                  dot
                stem-end)
              stem-end)))))

(defun dired-filetags-parse (name)
  "Return (BASE TAGS EXT) as filetags sees basename NAME, or nil if untagged.
TAGS keeps empty strings, duplicates and \"--\".  EXT has no dot, or is
nil.  A trailing .lnk in any letter case is ignored."
  (pcase (dired-filetags--split name)
    (`(,sep ,tags-end ,stem-end)
     (list (substring name 0 sep)
           (split-string (substring name (+ sep 4) tags-end) " ")
           (and (< tags-end stem-end) (substring name (1+ tags-end) stem-end))))))

(defun dired-filetags-tags (file)
  "Return the tags of FILE, exactly as filetags sees them."
  (nth 1 (dired-filetags-parse (file-name-nondirectory file))))

(defun dired-filetags--clean-tags (file)
  "Return the tags of FILE without empty and \"--\" tags."
  (seq-remove (lambda (tag) (member tag '("" "--"))) (dired-filetags-tags file)))

(defun dired-filetags--untagged-name (name)
  "Return basename NAME without its tag segment; a trailing .lnk is downcased.
That is the .lnk that ends the result, even one that ends the base:
filetags reads \"x.LNK -- a\" less its tag, \"x.LNK\", as a .lnk file."
  (let ((lnk (and (dired-filetags--lnk-p name) ".lnk")))
    (pcase (dired-filetags--split name)
      (`(,sep ,tags-end ,stem-end)
       (let ((base (substring name 0 sep)))
         ;; Without a .lnk of NAME's own or an extension, the result is
         ;; the base, and only the base's own .lnk can end it.
         (if (and (not lnk) (= tags-end stem-end) (dired-filetags--lnk-p base))
             (concat (substring base 0 -4) ".lnk")
           (concat base (substring name tags-end stem-end) lnk))))
      (_ (if lnk (concat (substring name 0 -4) lnk) name)))))

(defun dired-filetags--unsafe-char-p (char)
  "Return non-nil if CHAR is Unicode whitespace, a control character or \"/\".
Unlike [:space:] and [:cntrl:], this does not depend on the syntax
table, and it covers DEL, the C1 controls, U+1680 and the line and
paragraph separators; filetags skips a tag made only of whitespace."
  (or (eq char ?/)
      (memq (get-char-code-property char 'general-category) '(Cc Zs Zl Zp))))

(defun dired-filetags--control-file-p (name &optional control)
  "Return non-nil if basename NAME is a filetags control file, in any letter case.
With CONTROL, a member of `dired-filetags--control-files', it must be
that one.  APFS folds with Unicode's full case folding, which also
turns the ligature fi (U+FB01) into \"fi\" and long s (U+017F) into
\"s\": the only letters besides ASCII that fold into these names."
  ;; Only these lengths can fold to .filetags or .filetags_tagtrees (the
  ;; ligature is one letter), and only a ligature or long s needs a
  ;; copy of NAME: the others compare in place.
  (and (memq (length name) '(8 9 17 18))
       (let ((name (if (string-match-p "[\uFB01\u017F]" name)
                       (string-replace "\u017F" "s" (string-replace "\uFB01" "fi" name))
                     name)))
         (if control
             (eq t (compare-strings name nil nil control nil nil t))
           (member-ignore-case name dired-filetags--control-files)))))

(defun dired-filetags--check-tags (tags &optional removing)
  "Return TAGS if filetags can apply them, else signal `user-error'.
With REMOVING, check TAGS for removal, which allows a leading \"-\" and
every reserved tag except \"cuttimes\"."
  (unless tags (user-error "No tags given"))
  (dolist (tag tags)
    (when (or (equal tag "")
              ;; One scan passes the usual tag: printable ASCII, no "/".
              (and (string-match-p "[[:space:][:cntrl:]/\x7f[:nonascii:]]" tag)
                   (or (string-match-p "[[:space:][:cntrl:]/\x7f]" tag)
                       (and (string-match-p "[[:nonascii:]]" tag)
                            (cl-loop for char across tag
                                     thereis (dired-filetags--unsafe-char-p char))))))
      (user-error "Tags cannot contain spaces, control characters or \"/\": %S" tag)))
  (unless removing
    (dolist (tag tags)
      (when (string-prefix-p "-" tag)
        (user-error "Filetags reads a leading \"-\" as removal: %S" tag))))
  (dolist (tag tags)
    ;; A tag named like a control file collides with it in TagTrees.
    (when (or (member tag dired-filetags--reserved-tags)
              (and (not removing) (dired-filetags--control-file-p tag)))
      (cond ((not removing) (user-error "Filetags reserves the tag %S" tag))
            ((equal tag "cuttimes")
             (user-error
              "Filetags cannot remove a literal \"cuttimes\" tag; rename the file with R")))))
  tags)

(defun dired-filetags--tokens (adds removes)
  "Return the --tags value of a retagging, with the removals first.
ADDS are the tags to add and REMOVES the tags to remove."
  (string-join (append (mapcar (lambda (tag) (concat "-" tag)) removes) adds) " "))

(defun dired-filetags--verify (old new adds removes)
  "Return nil if basename NEW is a faithful retagging of OLD, else a reason.
ADDS and REMOVES are the tags requested for this file.  Tags that
disappear without being requested are allowed: those are exclusive-group
removals."
  (let* ((old-parse (dired-filetags-parse old))
         (new-parse (dired-filetags-parse new))
         (old-tags (nth 1 old-parse))
         (new-tags (nth 1 new-parse))
         (lost (seq-find (lambda (tag) (not (member tag new-tags))) adds))
         (kept (seq-find (lambda (tag) (member tag new-tags)) removes)))
    (cond
     ((or (not (equal (dired-filetags--untagged-name old)
                      (dired-filetags--untagged-name new)))
          ;; Equal untagged names can still hide a moved extension:
          ;; "a -- x.b" and "a.b -- x" are both "a.b" untagged.
          (and old-parse new-parse
               (not (and (equal (car old-parse) (car new-parse))
                         (equal (nth 2 old-parse) (nth 2 new-parse))))))
      (format "filetags would change more than the tags: %S" new))
     ((or (member "" new-tags) (member "--" new-tags))
      "the name has an empty or \"--\" tag; repair it first with C-x C-q")
     (lost (format "filetags would not keep tag %S (exclusive group?): %S" lost new))
     (kept (format "filetags would not remove %S: %S" kept new))
     ((seq-find (lambda (tag) (not (or (member tag adds)
                                       (and (member tag old-tags)
                                            (not (member tag removes))))))
                new-tags)
      (format "filetags would add unexpected tags: %S" new)))))

;;;; Running filetags

(defun dired-filetags--program ()
  "Return the absolute file name of the filetags executable.
The search is always local, even in remote Dired buffers."
  (or (executable-find dired-filetags-program)
      (user-error "Cannot find filetags executable: %s" dired-filetags-program)))

(defun dired-filetags--failed-p (status output)
  "Return non-nil if filetags failed.
That is, its exit STATUS is not 0, or its OUTPUT reports an error."
  (or (not (eql status 0)) (string-match-p "^\\(ERROR\\|Traceback\\)" output)))

(defun dired-filetags--first-line (output)
  "Return the first non-empty line of filetags OUTPUT, or \"no output\"."
  (or (car (split-string output "\n" t)) "no output"))

(defun dired-filetags--call (dir &rest args)
  "Run filetags with ARGS in local directory DIR and return its output.
Signal `user-error' if it exits non-zero or reports an ERROR or a traceback."
  (let* ((program (dired-filetags--program))
         (default-directory (file-name-as-directory dir))
         (coding-system-for-read 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         status output)
    (with-temp-buffer
      ;; INFILE nil is /dev/null, so filetags can never wait for input.
      ;; stdout and stderr are merged; -q leaves stdout empty.
      (setq status (apply #'call-process program nil t nil args)
            output (ansi-color-filter-apply (buffer-string))))
    (when (dired-filetags--failed-p status output)
      (dired-log "filetags %s\nfailed (exit %s):\n%s\n" (string-join args " ") status output)
      (dired-log t)
      (user-error "Filetags failed (exit %s): %s" status (dired-filetags--first-line output)))
    output))

(defun dired-filetags--vocabulary-file (file)
  "Return the .filetags governing FILE (its directory, then ancestors), or nil.
Remote files have no vocabulary: the CLI runs locally."
  (unless (file-remote-p file)
    (when-let* ((dir (locate-dominating-file
                      file (lambda (d) (file-regular-p (expand-file-name ".filetags" d))))))
      (expand-file-name ".filetags" dir))))

(defun dired-filetags--vocabulary-words (dir)
  "Return the words of the .filetags governing directory DIR, for completion.
Comments, #include and #donotsuggest lines are dropped, and includes are
not followed.  Remote directories have no vocabulary."
  (when-let* ((file (dired-filetags--vocabulary-file (file-name-as-directory dir))))
    (with-temp-buffer
      (insert-file-contents file)
      (split-string (replace-regexp-in-string "#.*" "" (buffer-string))))))

(defun dired-filetags--new-names (names tokens vocabulary)
  "Return the basenames filetags gives basenames NAMES for \"--tags=TOKENS\".
VOCABULARY is the governing .filetags or nil.  Each name becomes an empty
stand-in in its own scratch directory, so results pair with NAMES by
construction and no user file is touched."
  ;; Any letter case: on APFS a .FILETAGS stand-in would overwrite the
  ;; scratch vocabulary.
  (when (seq-some (lambda (name) (dired-filetags--control-file-p name ".filetags")) names)
    (error "Cannot name the vocabulary file itself"))
  (let* ((file-name-handler-alist nil)   ; no jka-compr, EasyPG, Tramp (V6)
         (create-lockfiles nil)
         (coding-system-for-write 'utf-8-unix)
         (scratch (make-temp-file "dired-filetags-" t))
         (vocab (if vocabulary (format "#include %s\n" vocabulary) ""))
         (dirs (cl-loop for i below (length names)
                        collect (file-name-as-directory
                                 (expand-file-name (number-to-string i) scratch)))))
    (unwind-protect
        (progn
          (cl-loop for name in names for dir in dirs
                   do (make-directory dir)
                   ;; Always written, even empty: it stops the CLI's upward
                   ;; search, so no ancestor vocabulary can leak in (V5).
                   (write-region vocab nil (concat dir ".filetags") nil 0)
                   ;; `concat', not `expand-file-name': a basename "~"
                   ;; or "~USER" would expand to a home directory.
                   (write-region "" nil (concat dir name) nil 0))
          (apply #'dired-filetags--call (car dirs) "-q" (concat "--tags=" tokens)
                 (cl-mapcar #'concat dirs names))
          (cl-loop for dir in dirs
                   collect (let ((left (delete ".filetags"
                                               (directory-files
                                                dir nil directory-files-no-dot-files-regexp t))))
                             (if (length= left 1) (car left)
                               (error "Filetags left %S in %s" left dir)))))
      (delete-directory scratch t))))

;;;; Targets and planning

(defun dired-filetags--check-dired ()
  "Signal `user-error' unless the current buffer is a Dired buffer.
A wdired buffer does not count: its names are being edited."
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not in a Dired buffer")))

(defun dired-filetags--classify (file)
  "Return nil if FILE can be tagged, else a reason string.
Control files are recognised in any letter case, because on a
case-insensitive filesystem filetags reads .FILETAGS as the vocabulary.
A file inside a TagTree that is not one of its links is refused: the
next build of the tree would delete it."
  (dired-filetags--memo
   (cons 'classify file)
   (lambda ()
     (cond ((dired-filetags--control-file-p (file-name-nondirectory file))
            "is a filetags control file")
           ((file-directory-p file) "is a directory (filetags only tags files)")
           ((not (file-exists-p file))
            (if (file-symlink-p file)
                "is a dangling symbolic link"
              (format "no longer exists (revert with g, or rebuild the TagTree with %s)"
                      (dired-filetags--key "v"))))
           ((not (file-regular-p file)) "is not a regular file")
           ((let ((dir (file-name-directory file)))
              (dired-filetags--memo (cons 'tree dir)
                                    (lambda () (dired-filetags--inside-tagtree-p dir))))
            (concat "is inside a TagTree but is not one of its links;"
                    " move it to its source directory first"))))))

(defun dired-filetags--link-original (link &optional source)
  "Return the file that symbolic LINK points to, resolving one level only.
filetags links each tree entry to the source entry itself, which may be
a symbolic link as well; that entry, not its final target, is the
original.  If SOURCE, the source directory of LINK's tree, contains the
original, the result is spelled below SOURCE, so that the buffers
visiting it and Dired buffers on SOURCE are found by name."
  (let* ((target (file-symlink-p link))
         ;; Not `expand-file-name' on TARGET alone: "~" would mean home.
         (orig (expand-file-name (if (string-prefix-p "/" target) target
                                   (concat (file-name-directory link) target)))))
    (or (and source
             (let ((rel (file-relative-name
                         (concat (file-truename (file-name-directory orig))
                                 (file-name-nondirectory orig))
                         (file-truename source))))
               (and (not (string-prefix-p "../" rel)) (not (equal rel ".."))
                    (not (file-name-absolute-p rel))
                    (concat (file-name-as-directory source) rel))))
        orig)))

(defun dired-filetags--tagtree-source (dir)
  "Return the source directory of the TagTree that DIR is in, or nil.
Only trees built by this package record their source."
  (when-let* ((root (dired-filetags--tagtree-root dir))
              (source (plist-get (dired-filetags--read-sidecar root) :source)))
    (and (stringp source) (file-directory-p source) source)))

(defun dired-filetags--targets (&optional arg)
  "Return the files to retag: the marked files, or the next ARG files.
Inside a TagTree, symbolic links are replaced by the files they point to,
as `dired-filetags--link-original' finds them.  Signal `user-error'
unless at least one of them can be tagged."
  (dired-filetags--check-dired)
  (let* ((files (dired-get-marked-files nil arg nil nil t))  ; "No files specified"
         (files (if (dired-filetags--inside-tagtree-p default-directory)
                    (let ((source (dired-filetags--tagtree-source default-directory)))
                      ;; filetags links a broken link to itself; that stays
                      ;; and is refused as dangling.
                      (delete-dups (mapcar (lambda (f)
                                             (if (file-symlink-p f)
                                                 (dired-filetags--link-original f source)
                                               f))
                                           files)))
                  files)))
    (unless (seq-some (lambda (f) (not (dired-filetags--classify f))) files)
      (user-error "No taggable files selected (filetags only tags regular files)"))
    files))

(defun dired-filetags--fold (file)
  "Return FILE as APFS compares it: case- and normalization-insensitive.
Names that fold alike are treated as one file on every filesystem.  On
a case-sensitive one that refuses a few safe renames, never an unsafe
one."
  (if (string-match-p "\\`[[:ascii:]]*\\'" file)
      (downcase file)
    ;; NFC again after `downcase': the dot that downcasing a dotted
    ;; capital I adds must be reordered after marks of a lower class.
    (ucs-normalize-NFC-string (downcase (ucs-normalize-NFC-string file)))))

(defun dired-filetags--preflight (pairs)
  "Return (GOOD . REFUSED) from PAIRS without touching the disk.
PAIRS are (OLD . NEW) absolute names.  GOOD keeps the pairs whose NEW
does not exist, is not the NEW of another pair after case and Unicode
folding, and is not visited by a buffer.  REFUSED is a list of
\(OLD . REASON) for the others."
  (let ((counts (make-hash-table :test #'equal))
        good refused)
    (pcase-dolist (`(,_ . ,new) pairs)
      (cl-incf (gethash (dired-filetags--fold new) counts 0)))
    (pcase-dolist (`(,old . ,new) pairs)
      (let* ((base (file-name-nondirectory new))
             (reason
              (cond ((or (file-exists-p new) (file-symlink-p new))
                     (format "%s already exists" base))
                    ((> (gethash (dired-filetags--fold new) counts) 1)
                     (format "another selected file would also become %s" base))
                    ((get-file-buffer new)
                     (format "a buffer already visits %s" base)))))
        (if reason
            (push (cons old reason) refused)
          (push (cons old new) good))))
    (cons (nreverse good) (nreverse refused))))

(defun dired-filetags--plan (files fn)
  "Return (PAIRS UNCHANGED REFUSED) for retagging FILES.
FN maps (FILE TAGS) to (ADDS . REMOVES).  PAIRS are (OLD . NEW) absolute
names that passed verification and preflight, UNCHANGED is a count, and
REFUSED is a list of (FILE . REASON).  Nothing on disk is touched.

Files are grouped by (vocabulary . tokens), because filetags applies the
first file's vocabulary to every file in a call, and each group is sent
to `dired-filetags--new-names' in chunks."
  (let ((groups (make-hash-table :test #'equal))
        (keys nil)
        (unchanged 0)
        pairs refused)
    (dolist (file files)
      (if-let* ((reason (dired-filetags--classify file)))
          (push (cons file reason) refused)
        (let* ((tags (dired-filetags-tags file))
               (change (funcall fn file tags))
               ;; Never send a tag the file has: a group tag would move (V7).
               (adds (seq-difference (seq-uniq (car change)) tags))
               (removes (seq-intersection (seq-uniq (cdr change)) tags)))
          (if (not (or adds removes))
              (cl-incf unchanged)
            (let ((key (cons (dired-filetags--vocabulary-file file)
                             (dired-filetags--tokens adds removes))))
              (unless (gethash key groups) (push key keys))
              (push (list file adds removes) (gethash key groups)))))))
    (dolist (key (nreverse keys))
      (let ((ops (nreverse (gethash key groups))))
        (while ops
          (let* ((chunk (seq-take ops dired-filetags--chunk-size))
                 (names (dired-filetags--new-names
                         (mapcar (lambda (op) (file-name-nondirectory (car op))) chunk)
                         (cdr key) (car key))))
            (setq ops (nthcdr dired-filetags--chunk-size ops))
            (cl-loop for (file adds removes) in chunk
                     for new in names
                     for reason = (dired-filetags--verify (file-name-nondirectory file)
                                                          new adds removes)
                     do (if reason
                            (push (cons file reason) refused)
                          (push (cons file (concat (file-name-directory file) new))
                                pairs)))))))
    (pcase-let ((`(,good . ,clashes) (dired-filetags--preflight (nreverse pairs))))
      (list good unchanged (append (nreverse refused) clashes)))))

(defun dired-filetags--retag (files fn)
  "Retag FILES as FN directs, and return the (OLD . NEW) pairs renamed.
FN maps (FILE TAGS) to (ADDS . REMOVES).  Refused files are logged to
`dired-log-buffer'; if every file is refused, signal `user-error'.
This must run in Dired, and never runs in wdired."
  (dired-filetags--check-dired)
  (pcase-let ((`(,pairs ,unchanged ,refused)
               (dired-filetags--with-cache
                 (dired-filetags--plan (mapcar #'expand-file-name files) fn))))
    (when refused
      (pcase-dolist (`(,file . ,reason) refused)
        (dired-log "Retag: skipped %s: %s\n" (file-name-nondirectory file) reason))
      (dired-log t))
    (cond
     ((and (null pairs) refused)
      (if (cdr refused)
          (user-error "Cannot retag any of the %d files; type ? for details" (length refused))
        (user-error "Cannot retag %s: %s"
                    (file-name-nondirectory (caar refused)) (cdar refused))))
     ((null pairs) (message "No file names change") nil)
     (t (let* ((done (dired-filetags--execute pairs))
               (rebuilding (and done (dired-filetags--maybe-rebuild-tagtree))))
          (dired-filetags--report done unchanged (length refused)
                                  (- (length pairs) (length done)) rebuilding)
          done)))))

;;;; Execution and reporting

(defun dired-filetags--rename (from to ok-if-already-exists)
  "Rename FROM to TO with `dired-rename-file', reporting failures as `file-error'.
OK-IF-ALREADY-EXISTS is passed on.  `dired-create-files' only catches
`file-error', but `vc-rename-file' signals plain errors such as \"Please
save files before moving them\", which would otherwise abort the batch."
  (condition-case err
      (dired-rename-file from to ok-if-already-exists)
    (file-error (signal (car err) (cdr err)))
    (error (signal 'file-error (list "Renaming" (error-message-string err) from)))))

(defun dired-filetags--execute (pairs)
  "Rename PAIRS of (OLD . NEW) through Dired and return the pairs that succeeded.
Dired renames through VC when `dired-vc-rename-file' says so, renames
visiting buffers, carries marks and updates every Dired buffer."
  (let ((here (dired-get-filename nil t))
        (table (make-hash-table :test #'equal)))
    (pcase-dolist (`(,old . ,new) pairs) (puthash old new table))
    (dired-create-files #'dired-filetags--rename "Retag" (mapcar #'car pairs)
                        (lambda (old) (gethash old table))
                        dired-keep-marker-rename)
    (let ((done (seq-filter (lambda (p) (and (file-exists-p (cdr p))
                                             (not (or (file-exists-p (car p))
                                                      (file-symlink-p (car p))))))
                            pairs)))
      ;; `dired-create-files' leaves point on the last file it processed.
      (when here (dired-goto-file (or (cdr (assoc here done)) here)))
      ;; Dired renames only the buffers visiting OLD under exactly that
      ;; name; one visiting it through a symbolic link would otherwise
      ;; recreate OLD when saved.
      (pcase-dolist (`(,old . ,new) done)
        (unless (file-remote-p old)
          (when-let* ((buf (find-buffer-visiting old)))
            (with-current-buffer buf (set-visited-file-name new nil t)))))
      (dired-filetags--refresh-stale-buffers (mapcar #'car done))
      done)))

(defun dired-filetags--refresh-stale-buffers (olds)
  "Revert each Dired buffer that still lists one of the files OLDS.
Dired updates its own lines, but not those of dired-subtree, nor those
of buffers showing a directory under another name, such as a symbolic
link to it.  Local directories are therefore compared by truename; the
last component of each file is kept, so a renamed link is found as a
link.  Buffers on other hosts are never examined, so no remote
connection is made."
  (let* ((truenames (make-hash-table :test #'equal))
         (canon (lambda (file)
                  (let* ((file (expand-file-name file))
                         (dir (file-name-directory file)))
                    (concat (with-memoization (gethash dir truenames)
                              (if (file-remote-p dir) dir
                                (file-name-as-directory (file-truename dir))))
                            (file-name-nondirectory file)))))
         (hosts (delete-dups (mapcar #'file-remote-p olds)))
         (table (make-hash-table :test #'equal))
         dirs)
    (dolist (old olds)
      (let ((name (funcall canon old)))
        (puthash name t table)
        (cl-pushnew (file-name-directory name) dirs :test #'equal)))
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (derived-mode-p 'dired-mode)
                   ;; Expanding another host's "~" could connect to it.
                   (member (file-remote-p default-directory) hosts)
                   (let ((dir (funcall canon default-directory)))
                     (seq-some (lambda (d) (string-prefix-p dir d)) dirs))
                   (save-excursion
                     (goto-char (point-min))
                     (cl-loop until (eobp)
                              thereis (when-let* ((file (dired-get-filename nil t)))
                                        (gethash (funcall canon file) table))
                              do (forward-line 1))))
          (revert-buffer))))))

(defun dired-filetags--maybe-rebuild-tagtree ()
  "Rebuild the TagTree that this buffer's directory is in, if it is ours.
Return t if a rebuild started, nil outside such a tree, and a message
saying why if the rebuild could not start.  Trees built by other tools
are left stale."
  (when-let* ((root (dired-filetags--tagtree-root default-directory)))
    (condition-case err
        (progn (dired-filetags--tagtrees-rebuild root) t)
      (error (format "%s; TagTrees not rebuilt" (error-message-string err))))))

(defun dired-filetags--report (done unchanged skipped failed rebuilding)
  "Show a one-line summary of a retagging and return it.
DONE are the renamed (OLD . NEW) pairs; UNCHANGED, SKIPPED and FAILED
are counts.  REBUILDING is t if a TagTree rebuild started, or a string
saying why it could not start, which is appended.  The +TAG and -TAG
changes come from the real old and new names, so a tag that an
exclusive group removed is shown too."
  (let ((trouble (> (+ skipped failed) 0))
        (total (+ (length done) skipped failed))
        added removed)
    (pcase-dolist (`(,old . ,new) done)
      (let ((old-tags (dired-filetags--clean-tags old))
            (new-tags (dired-filetags--clean-tags new)))
        (dolist (tag (seq-difference new-tags old-tags)) (cl-pushnew tag added :test #'equal))
        (dolist (tag (seq-difference old-tags new-tags)) (cl-pushnew tag removed :test #'equal))))
    (let* ((changes (append (mapcar (lambda (tag) (propertize (concat "+" tag)
                                                              'face 'dired-filetags-added))
                                    (reverse added))
                            (mapcar (lambda (tag) (propertize (concat "-" tag)
                                                              'face 'dired-filetags-removed))
                                    (reverse removed))))
           (counts (delq nil (list (and (> unchanged 0) (format "%d unchanged" unchanged))
                                   (and (> skipped 0) (format "%d skipped" skipped))
                                   (and (> failed 0) (format "%d failed" failed)))))
           (text (concat (if trouble
                             (format "Retagged %d of %d file%s"
                                     (length done) total (dired-plural-s total))
                           (format "Retagged %d file%s"
                                   (length done) (dired-plural-s (length done))))
                         (and changes (concat ": " (string-join changes " ")))
                         (and counts (concat "; " (string-join counts ", ")))
                         (and trouble " (type ? for details)")
                         (cond ((stringp rebuilding) (concat "; " rebuilding))
                               (rebuilding "; rebuilding TagTrees...")))))
      (message "%s" text)
      text)))

;;;; Reading tags

(defun dired-filetags--read-tags (prompt candidates &optional require-match)
  "Read tags with PROMPT, completing from CANDIDATES, an alist (TAG . NOTE).
The candidate order is kept.  Tags are separated by spaces or commas.
REQUIRE-MATCH is passed to `completing-read-multiple'."
  (let* ((crm-separator dired-filetags--crm-separator)  ; special after (require 'crm)
         (tags (mapcar #'car candidates))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      `(metadata (category . dired-filetags-tag)
                                 (annotation-function
                                  . ,(lambda (tag)
                                       (when-let* ((note (cdr (assoc tag candidates))))
                                         (propertize (concat "  " note)
                                                     'face 'completions-annotations))))
                                 (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action tags string pred)))))
    (delete-dups
     (mapcan (lambda (s) (split-string s crm-separator t))
             (minibuffer-with-setup-hook
                 ;; Appended, so it runs after vertico has set up its map.
                 (:append (lambda ()
                            (use-local-map (dired-filetags--minibuffer-map tags require-match))))
               (completing-read-multiple prompt table nil require-match nil
                                         'dired-filetags-history))))))

(defun dired-filetags--minibuffer-map (tags require-match)
  "Return the local map of a tag prompt, over the current local map.
SPC inserts a space: default completion would complete a word instead.
RET after a trailing separator submits the typed tags alone, because
the empty tag after the separator would otherwise be filled in with
the highlighted candidate, as vertico does, and a tag nobody asked for
would be added or removed.  A candidate chosen explicitly with
vertico's motion commands is still taken.  With REQUIRE-MATCH, each
typed tag must then be one of TAGS."
  (let* ((parent (current-local-map))
         (ret (keymap-lookup parent "RET"))
         (separator crm-separator)
         (map (make-sparse-keymap)))
    (set-keymap-parent map parent)
    (keymap-set map "SPC" #'self-insert-command)
    (keymap-set map "RET"
                (lambda ()
                  (interactive)
                  (if (or (not (string-match (concat "\\(?:" separator "\\)\\'")
                                             (minibuffer-contents-no-properties)))
                          ;; vertico sets this when the user moves to a candidate.
                          (bound-and-true-p vertico--lock-candidate))
                      (call-interactively (or ret #'exit-minibuffer))
                    (delete-region (+ (minibuffer-prompt-end) (match-beginning 0)) (point-max))
                    (if-let* ((missing (and require-match
                                            (seq-find (lambda (tag) (not (member tag tags)))
                                                      (split-string (minibuffer-contents-no-properties)
                                                                    separator t)))))
                        (minibuffer-message "No tag %s" missing)
                      (exit-minibuffer)))))
    map))

(defun dired-filetags--prompt (verb files)
  "Return a prompt for VERB on FILES, counting only the taggable ones.
It is \"VERB NAME: \", with the untagged name of a single file, or
\"VERB N files: \"."
  (let ((taggable (seq-remove #'dired-filetags--classify files)))
    (if (length= taggable 1)
        (format "%s %s: " verb
                (dired-filetags--untagged-name (file-name-nondirectory (car taggable))))
      (format "%s %d files: " verb (length taggable)))))

(defun dired-filetags--tally (tag-lists)
  "Return ((TAG . COUNT) ...), where COUNT is the number of TAG-LISTS with TAG.
The most frequent tags come first; ties keep their first-seen order."
  (let ((counts (make-hash-table :test #'equal))
        order)
    (dolist (tags tag-lists)
      (dolist (tag (seq-uniq tags))
        (unless (gethash tag counts) (push tag order))
        (cl-incf (gethash tag counts 0))))
    (sort (mapcar (lambda (tag) (cons tag (gethash tag counts))) (nreverse order))
          (lambda (a b) (> (cdr a) (cdr b))))))

(defun dired-filetags--buffer-tags ()
  "Return ((TAG . COUNT) ...) for the file names listed in this Dired buffer.
Every line counts, including inserted subdirectories and subtree lines.
COUNT is the number of names with TAG; the most used tags come first."
  (save-excursion
    (goto-char (point-min))
    (let (names)
      (while (not (eobp))
        (when-let* ((beg (dired-move-to-filename))
                    (end (dired-move-to-end-of-filename t)))
          (push (dired-filetags--clean-tags (buffer-substring-no-properties beg end)) names))
        (forward-line 1))
      (dired-filetags--tally (nreverse names)))))

(defun dired-filetags--counted (tally)
  "Return TALLY, a list of (TAG . COUNT), as completion candidates (TAG . \"N×\")."
  (mapcar (lambda (cell) (cons (car cell) (format "%d×" (cdr cell)))) tally))

(defun dired-filetags--vocabulary-candidates (listed)
  "Return (WORD . \"vocab\") for the vocabulary words at point not in LISTED."
  (mapcar (lambda (word) (cons word "vocab"))
          (seq-difference (seq-uniq (dired-filetags--vocabulary-words (dired-current-directory)))
                          listed)))

(defun dired-filetags--target-tally (files)
  "Return (N . TALLY) for the N taggable FILES, TALLY as `dired-filetags--tally'."
  (let ((taggable (seq-remove #'dired-filetags--classify files)))
    (cons (length taggable)
          (dired-filetags--tally (mapcar #'dired-filetags--clean-tags taggable)))))

(defun dired-filetags--target-candidates (files)
  "Return (TAG . \"on K/N\") for the tags of the N taggable FILES.
Tags carried by more of them come first; ties keep their first-seen order."
  (pcase-let ((`(,n . ,tally) (dired-filetags--target-tally files)))
    (mapcar (lambda (cell) (cons (car cell) (format "on %d/%d" (cdr cell) n))) tally)))

(defun dired-filetags--add-candidates (files)
  "Return the tags to offer for adding to FILES, as an alist (TAG . NOTE).
Buffer tags come first, most used first, then vocabulary words.  Tags
that every taggable file in FILES already has are left out."
  (let* ((everywhere (pcase-let ((`(,n . ,tally) (dired-filetags--target-tally files)))
                       (mapcar #'car (seq-filter (lambda (cell) (= (cdr cell) n)) tally))))
         (buffer (seq-remove (lambda (cell) (member (car cell) everywhere))
                             (dired-filetags--buffer-tags))))
    (append (dired-filetags--counted buffer)
            (dired-filetags--vocabulary-candidates (append everywhere (mapcar #'car buffer))))))

(defun dired-filetags--remove-candidates (files)
  "Return the tags of FILES as an alist (TAG . NOTE) for removal.
Signal `user-error' if the taggable files have no tags."
  (or (dired-filetags--target-candidates files)
      (user-error "The selected files have no tags")))

(defun dired-filetags--add-remove-candidates (files)
  "Return the tags to offer for adding to or removing from FILES.
The result is an alist (TAG . NOTE).  The tags of FILES come first,
noted \"on K/N\", then the other buffer tags, then vocabulary words."
  (let* ((targets (dired-filetags--target-candidates files))
         (buffer (seq-remove (lambda (cell) (assoc (car cell) targets))
                             (dired-filetags--buffer-tags))))
    (append targets
            (dired-filetags--counted buffer)
            (dired-filetags--vocabulary-candidates (mapcar #'car (append targets buffer))))))

(defun dired-filetags--mark-candidates ()
  "Return the tags to offer for marking, as an alist (TAG . NOTE).
The tags of the file at point come first, then the other buffer tags."
  (let* ((buffer (dired-filetags--buffer-tags))
         (here (seq-uniq (when-let* ((file (dired-get-filename nil t)))
                           (dired-filetags--clean-tags file)))))
    (dired-filetags--counted
     (append (mapcar (lambda (tag) (or (assoc tag buffer) (cons tag 1))) here)
             (seq-remove (lambda (cell) (member (car cell) here)) buffer)))))

(defun dired-filetags--read-arguments (verb candidates &optional require-match)
  "Return the interactive arguments (TAGS FILES) of a tagging command.
FILES are the targets, read first so that an empty selection fails
before the prompt.  TAGS are read with a prompt for VERB, completing
from (funcall CANDIDATES FILES); REQUIRE-MATCH is passed on."
  (dired-filetags--with-cache
    (let ((files (dired-filetags--targets current-prefix-arg)))
      (list (dired-filetags--read-tags (dired-filetags--prompt verb files)
                                       (funcall candidates files) require-match)
            files))))

(defun dired-filetags--read-mark-arguments (which empty)
  "Return the interactive arguments (TAGS UNMARK) of a marking command.
WHICH is \"any\" or \"none\", and EMPTY says what empty input means."
  (list (dired-filetags--read-tags
         (format "%s files with %s of these tags (empty: %s): "
                 (if current-prefix-arg "Unmark" "Mark") which empty)
         (dired-filetags--mark-candidates) t)
        current-prefix-arg))

;;;; Commands

;;;###autoload
(defun dired-filetags-add (tags &optional files)
  "Add TAGS to FILES, the marked files or the file at point.
FILES defaults to the marked files, or else the next prefix-argument
files, as for other Dired commands.  Each file gets the tags it lacks,
appended in the order typed.  A tag in an exclusive group of the
governing .filetags replaces its group mates, as filetags does.

This command has no key.  PREFIX a, where PREFIX is
`dired-filetags-prefix-key', runs `dired-filetags-add-remove', which
adds in the same way but removes a tag that every file already has.

Files that cannot be retagged cleanly are skipped, and the reason goes
to *Dired log*; type ? to see it.  Return the (OLD . NEW) pairs that
were renamed."
  (interactive (dired-filetags--read-arguments "Add tags to" #'dired-filetags--add-candidates)
               dired-mode)
  (dired-filetags--check-tags tags)
  (dired-filetags--retag (or files (dired-filetags--targets nil))
                         (lambda (_file _tags) (cons tags nil))))

;;;###autoload
(defun dired-filetags-remove (tags &optional files)
  "Remove TAGS from FILES, the marked files or the file at point.
FILES defaults to the marked files, or else the next prefix-argument
files, as for other Dired commands.  Each file loses the listed tags it
has; removing its last tag also drops the \" -- \" separator.

This command has no key.  PREFIX a, where PREFIX is
`dired-filetags-prefix-key', runs `dired-filetags-add-remove', which
removes a tag that every file already has and adds any other.

Files that cannot be retagged cleanly are skipped, and the reason goes
to *Dired log*; type ? to see it.  Return the (OLD . NEW) pairs that
were renamed."
  (interactive (dired-filetags--read-arguments
                "Remove tags from" #'dired-filetags--remove-candidates t)
               dired-mode)
  (dired-filetags--check-tags tags t)
  (dired-filetags--retag (or files (dired-filetags--targets nil))
                         (lambda (_file _tags) (cons nil tags))))

;;;###autoload
(defun dired-filetags-add-remove (tags &optional files)
  "Add each of TAGS to FILES, or remove it if they all have it already.
FILES defaults to the marked files, or else the next prefix-argument
files, as for other Dired commands.  Each tag is decided across the
whole selection: a tag that every taggable file already has is removed
from all of them, and any other tag is added to the files that lack it.
One call may add some of TAGS and remove others.  On a single file, a
tag it has is removed and a tag it lacks is added.  On a mixed
selection, where only some files have a tag, the first call adds it to
the others, and the next one removes it from all of them.

Adding a tag from an exclusive group of the governing .filetags
replaces its group mates, as filetags does, and removing the tag again
does not bring a displaced mate back, even on a single file.  Naming
two mates at once on a mixed selection can swap them.

This is PREFIX a, where PREFIX is `dired-filetags-prefix-key'.
`dired-filetags-add' and `dired-filetags-remove' only add or only
remove, and have no key.

Files that cannot be retagged cleanly are skipped, and the reason goes
to *Dired log*; type ? to see it.  Return the (OLD . NEW) pairs that
were renamed."
  (interactive (dired-filetags--read-arguments
                "Add or remove tags on" #'dired-filetags--add-remove-candidates)
               dired-mode)
  (unless tags (user-error "No tags given"))
  (dired-filetags--with-cache
    (let* ((files (or files (dired-filetags--targets nil)))
           (taggable (seq-remove #'dired-filetags--classify files))
           (all (seq-filter (lambda (tag)
                              (seq-every-p (lambda (f) (member tag (dired-filetags-tags f)))
                                           taggable))
                            tags))
           (adds (seq-difference tags all)))
      ;; Check each tag as what it will be: a tag every file has is a
      ;; removal, which may start with "-" or be named like a control file.
      (when adds (dired-filetags--check-tags adds))
      (when all (dired-filetags--check-tags all t))
      (dired-filetags--retag files (lambda (_file _tags) (cons adds all))))))

;;;; Marking

(defun dired-filetags--match-p (file-tags tags match)
  "Return non-nil if FILE-TAGS satisfy MATCH (`any' or `none') against TAGS.
Empty TAGS means \"has any tag\"."
  (let ((hit (if tags (seq-some (lambda (tag) (member tag file-tags)) tags) file-tags)))
    (if (eq match 'none) (not hit) (and hit t))))

(defun dired-filetags--mark (tags match unmark)
  "Mark the files whose tags satisfy MATCH against TAGS, or UNMARK them.
MATCH is `any' or `none', as for `dired-filetags--match-p'.  Only
regular files and links to non-directories count, never `.', `..',
directories, links to directories or filetags' control files.  Return
the number of lines whose mark changed, or nil if there were none."
  (dired-filetags--check-dired)
  (let ((dired-marker-char (if unmark ?\s dired-marker-char)))
    (dired-mark-if
     (and (not (looking-at-p dired-re-dot))
          (not (looking-at-p dired-re-dir))           ; from the listing, no stat
          (when-let* ((file (dired-get-filename nil t)))
            (and (not (dired-filetags--control-file-p (file-name-nondirectory file)))
                 (not (and (looking-at-p dired-re-sym) (file-directory-p file)))
                 (dired-filetags--match-p (dired-filetags--clean-tags file) tags match))))
     ;; `dired-mark-if' pluralizes this noun phrase by appending "s".
     (cond ((eq match 'any) "tagged file")
           (tags "non-matching file")
           (t "untagged file")))))

;;;###autoload
(defun dired-filetags-mark (tags &optional unmark)
  "Mark files tagged with any of TAGS.  With prefix UNMARK, unmark them instead.
Empty TAGS (empty input) means files with any tag.  Tags match whole
and case-sensitively.  Only files are marked, never directories or
filetags' control files, and every line of the buffer counts, including
inserted subdirectories.

Marks accumulate, so this command, `dired-filetags-mark-not' and their
prefix forms combine.  PREFIX is `dired-filetags-prefix-key':

  a or b            PREFIX m a b RET
  a and b           PREFIX m a RET, then \\`C-u' PREFIX n b RET
  a and not b       PREFIX m a RET, then \\`C-u' PREFIX m b RET
  neither a nor b   PREFIX n a b RET
  untagged          PREFIX u, or PREFIX n \\`C-j' (empty input)"
  (interactive (dired-filetags--read-mark-arguments "any" "any tag") dired-mode)
  (dired-filetags--mark tags 'any unmark))

;;;###autoload
(defun dired-filetags-mark-not (tags &optional unmark)
  "Mark files tagged with none of TAGS.  With prefix UNMARK, unmark them instead.
Empty TAGS (empty input) means untagged files.  This is the exact
complement of `dired-filetags-mark' over the files of the buffer:
directories and filetags' control files are never marked.

Marks accumulate, so this command, `dired-filetags-mark' and their
prefix forms combine.  PREFIX is `dired-filetags-prefix-key':

  a or b            PREFIX m a b RET
  a and b           PREFIX m a RET, then \\`C-u' PREFIX n b RET
  a and not b       PREFIX m a RET, then \\`C-u' PREFIX m b RET
  neither a nor b   PREFIX n a b RET
  untagged          PREFIX u, or PREFIX n \\`C-j' (empty input)"
  (interactive (dired-filetags--read-mark-arguments "none" "untagged") dired-mode)
  (dired-filetags--mark tags 'none unmark))

;;;###autoload
(defun dired-filetags-mark-untagged (&optional unmark)
  "Mark the files that have no tags.  With prefix UNMARK, unmark them instead.
This is `dired-filetags-mark-not' with empty input, without a prompt.
Only files are marked, never `.', `..', directories, links to
directories or filetags' control files.  Return the number of lines
whose mark changed, or nil if there were none."
  (interactive "P" dired-mode)
  (dired-filetags--mark nil 'none unmark))

;;;; TagTrees

(defun dired-filetags--sidecar (target)
  "Return the sidecar file of TagTree TARGET, which sits next to the tree."
  (concat (directory-file-name (expand-file-name target)) ".eld"))

(defun dired-filetags--write-sidecar (target plist)
  "Record PLIST, plus the current :time, in the sidecar of TagTree TARGET."
  (let ((print-length nil)
        (print-level nil)
        (coding-system-for-write 'utf-8-unix))
    (write-region (prin1-to-string
                   (plist-put (copy-sequence plist) :time (format-time-string "%FT%T%z")))
                  nil (dired-filetags--sidecar target) nil 0)))

(defun dired-filetags--read-sidecar (root)
  "Return the plist in the sidecar of TagTree ROOT, or nil if it is unreadable."
  (ignore-errors
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents (dired-filetags--sidecar root)))
      (let ((plist (read (current-buffer))))
        (and (plistp plist) plist)))))

(defun dired-filetags--inside-tagtree-p (dir)
  "Return the nearest directory at or above DIR with a TagTree marker, or nil.
This matches any tree, including ones this package did not build.
Remote directories are never TagTrees, and are not contacted."
  (unless (file-remote-p dir)
    (when-let* ((found (locate-dominating-file dir ".filetags_tagtrees")))
      (file-name-as-directory (expand-file-name found)))))

(defun dired-filetags--tagtree-root (dir)
  "Return the root of the TagTree built by this package that DIR is in.
The root is the nearest directory at or above DIR that has both a
.filetags_tagtrees marker and a sidecar; the untagged folder has a
marker but no sidecar.  Return nil if there is none, or if DIR is remote."
  (unless (file-remote-p dir)
    (when-let* ((found (locate-dominating-file
                        dir (lambda (d)
                              (and (file-exists-p (expand-file-name ".filetags_tagtrees" d))
                                   (file-exists-p (dired-filetags--sidecar d)))))))
      (file-name-as-directory (expand-file-name found)))))

(defun dired-filetags--tagtrees-target (source)
  "Return the TagTree directory of SOURCE.
It lies below `dired-filetags-tagtrees-directory', named after SOURCE's
truename plus a hash of it, so each source directory has one tree
however it is spelled."
  (when (file-remote-p source)
    (user-error "TagTrees need a local directory"))
  (let* ((true (directory-file-name (file-truename source)))
         (name (replace-regexp-in-string "[^[:alnum:]._-]+" "_" (file-name-nondirectory true))))
    (file-name-as-directory
     (expand-file-name (format "%s-%s" (if (string-empty-p name) "root" name)
                               (substring (md5 true nil nil 'utf-8) 0 8))
                       dired-filetags-tagtrees-directory))))

(defun dired-filetags--tagtrees-check (source target recursive)
  "Signal `user-error' unless filetags may build TagTrees of SOURCE in TARGET.
RECURSIVE means a -R build.  filetags wipes TARGET before it builds, so
every check runs before any process starts, and TARGET must be absent,
empty, or an existing TagTree that is not inside another tree."
  (let ((name (dired-filetags--pretty-dir source))
        (tree (directory-file-name target))
        (tree-name (dired-filetags--pretty-dir target))
        stranger)
    (cond
     ((or (file-remote-p source) (file-remote-p target))
      (user-error "TagTrees need a local directory"))
     ((dired-filetags--inside-tagtree-p source)
      (user-error "%s is inside a TagTree; run %s in the directory you want to browse"
                  name (dired-filetags--key "v")))
     ((dired-filetags--inside-tagtree-p (file-name-directory tree))
      (user-error "Refusing to use %s: it is inside another TagTree" tree-name))
     ((or (file-symlink-p tree) (and (file-exists-p tree) (not (file-directory-p tree))))
      (user-error "%s is not a directory" tree-name))
     ((and (file-directory-p tree)
           (directory-files tree nil directory-files-no-dot-files-regexp t 1)
           (not (file-exists-p (expand-file-name ".filetags_tagtrees" tree))))
      (user-error "Refusing to use %s: it is not empty and not a TagTree" tree-name))
     ;; filetags wipes the whole tree, including anything moved into it.
     ((and (file-directory-p tree)
           (setq stranger (dired-filetags--tagtree-stranger tree)))
      (user-error "Refusing to rebuild %s: %s is not a link filetags made; move it out first"
                  tree-name (file-relative-name stranger tree)))
     ;; filetags would run inside the tree it wipes (its exit code 11).
     ((file-in-directory-p source tree)
      (user-error "%s is inside the TagTree directory" name))
     ((and recursive (file-in-directory-p tree source))
      (user-error "The TagTree directory is inside %s; a recursive build would include it"
                  name))
     ((let ((true (file-truename tree)))
        (seq-some (lambda (proc)
                    (when-let* ((other (and (process-live-p proc)
                                            (process-get proc 'dired-filetags-target))))
                      (equal (file-truename (directory-file-name other)) true)))
                  (process-list)))
      (user-error "TagTrees of %s are already being built" name)))))

(defun dired-filetags--tagtree-stranger (tree)
  "Return the first entry of TagTree TREE that filetags did not make, or nil.
filetags makes only symbolic links, directories and .filetags_tagtrees
markers; anything else, such as a file moved into the tree, would be
deleted by the next build.  Finder's .DS_Store and AppleDouble ._*
files are disposable, so they do not count."
  (catch 'found
    (let ((dirs (list tree)))
      (while dirs
        (dolist (entry (directory-files-and-attributes
                        (pop dirs) t directory-files-no-dot-files-regexp t))
          (let ((type (file-attribute-type (cdr entry))))
            (cond ((stringp type))                  ; a symbolic link
                  (type (push (car entry) dirs))
                  ((not (string-match-p
                         "\\`\\(?:\\.filetags_tagtrees\\|\\.DS_Store\\|\\._.*\\)\\'"
                         (file-name-nondirectory (car entry))))
                   (throw 'found (car entry))))))))
    nil))

(defun dired-filetags--untagged-valid-p (value)
  "Return non-nil if VALUE is valid for filetags' --tagtrees-handle-no-tag.
That is \"treeroot\", \"ignore\", or a single file name component that
is not \".\", \"..\" or a control file name and does not start with \"-\"."
  (and (stringp value)
       (or (member value '("treeroot" "ignore"))
           (and (string-match-p "\\`[^/[:cntrl:]-][^/[:cntrl:]]*\\'" value)
                (not (member value '("." "..")))
                (not (dired-filetags--control-file-p value))))))

(defun dired-filetags--check-untagged (untagged)
  "Signal `user-error' unless UNTAGGED is a valid untagged-files setting.
filetags joins a folder name to the tree directory and wipes the result,
so an absolute name, \"..\" or \"a/b\" would reach outside the tree."
  (unless (dired-filetags--untagged-valid-p untagged)
    (user-error "Invalid dired-filetags-tagtrees-untagged %S: use a folder name" untagged)))

(defun dired-filetags--tagtrees-inputs (source recursive)
  "Return the absolute names of the files filetags links for TagTrees of SOURCE.
They are what Python's os.walk lists: hidden files and broken links
included, directories and links to directories excluded.  With
RECURSIVE, subdirectories are walked, without following links, and
unreadable ones are skipped."
  (if recursive
      (directory-files-recursively source "" nil t)
    (seq-remove #'file-directory-p
                (directory-files source t directory-files-no-dot-files-regexp t))))

(defun dired-filetags--permutations (k depth)
  "Return the number of TagTree links of a file with K distinct tags at DEPTH.
That is the sum of k!/(k-d)! for d from 1 to DEPTH."
  (cl-loop for d from 1 to (min k depth)
           for p = k then (* p (- k d -1))
           sum p))

(defun dired-filetags--tagtrees-prescan (source params)
  "Return the estimated link count of TagTrees of SOURCE with PARAMS.
PARAMS has :recursive, :depth and :untagged.  Signal `user-error' if
SOURCE has no files, or if a file would make filetags abort after it
has wiped the tree; each such file is logged to `dired-log-buffer'."
  (let* ((depth (plist-get params :depth))
         (untagged (plist-get params :untagged))
         (ignore (equal untagged "ignore"))
         (treeroot (equal untagged "treeroot"))
         (folder (and (not ignore) (not treeroot) (dired-filetags--fold untagged)))
         (inputs (dired-filetags--tagtrees-inputs source (plist-get params :recursive)))
         (seen (make-hash-table :test #'equal))
         ;; Folded tag folders at the root, and inside the untagged
         ;; folder when a tag of that name makes it a tag folder too.
         (root-dirs (make-hash-table :test #'equal))
         (folder-dirs (make-hash-table :test #'equal))
         (links 0)
         problems)
    (unless inputs
      (user-error "No files in %s" (dired-filetags--pretty-dir source)))
    ;; Two linked files with one name collide in a tag folder, even if
    ;; their names differ only in case on a case-insensitive filesystem.
    (dolist (file inputs)
      (let ((tags (mapcar #'dired-filetags--fold (dired-filetags-tags file))))
        (when (or (not ignore) tags)
          (cl-incf (gethash (dired-filetags--fold (file-name-nondirectory file)) seen 0)))
        (dolist (tag tags) (puthash tag t root-dirs))
        (when (and folder (>= depth 2) (member folder tags))
          (dolist (tag tags) (unless (equal tag folder) (puthash tag t folder-dirs))))))
    (dolist (file inputs)
      (let* ((name (file-name-nondirectory file))
             (tags (dired-filetags-tags name))
             (k (length (seq-uniq tags)))
             (reason
              (cond ((and (> depth 0) (/= k (length tags))) "repeats a tag")
                    ((and (>= depth 2) (member "" tags)) "has an empty tag")
                    ((or (member "." tags) (member ".." tags)) "has a \".\" or \"..\" tag")
                    ((and (> depth 0)
                          (seq-some #'dired-filetags--control-file-p tags))
                     "has a tag named like a filetags control file")
                    ((> (gethash (dired-filetags--fold name) seen 0) 1)
                     "shares its name with another file")
                    (tags nil)
                    ((and treeroot (dired-filetags--control-file-p name ".filetags"))
                     (concat "cannot be linked at the tree root;"
                             " set dired-filetags-tagtrees-untagged"))
                    ((and (not ignore) (dired-filetags--control-file-p name ".filetags_tagtrees"))
                     "is the marker of another TagTree")
                    ((and treeroot (> depth 0) (gethash (dired-filetags--fold name) root-dirs))
                     (concat "collides with the tag folder of that name at the tree root;"
                             " set dired-filetags-tagtrees-untagged"))
                    ((gethash (dired-filetags--fold name) folder-dirs)
                     (format "collides with the tag folder %s/%s; rename the file or set %s"
                             untagged name "dired-filetags-tagtrees-untagged")))))
        (if reason
            (push (cons (file-relative-name file source) reason) problems)
          (cl-incf links (cond (tags (dired-filetags--permutations k depth))
                               (ignore 0)
                               (t 1))))))
    (when problems
      (setq problems (nreverse problems))
      (pcase-dolist (`(,name . ,reason) problems)
        (dired-log "TagTrees: %s: %s\n" name reason))
      (dired-log t)
      (user-error "Cannot build TagTrees: %d problem file(s), e.g. %S %s; type ? for details"
                  (length problems) (caar problems) (cdar problems)))
    links))

(defun dired-filetags--tagtrees-start (source target params)
  "Start filetags building TagTrees of SOURCE in TARGET; return the process.
PARAMS has :recursive, :depth and :untagged.  The tree directory is
always passed explicitly and --overwrite never is.  The build runs
asynchronously, and `dired-filetags--tagtrees-sentinel' finishes it."
  (dired-filetags--check-untagged (plist-get params :untagged))
  (let* ((program (dired-filetags--program))
         (default-directory (file-name-as-directory source)) ; filetags reads the cwd
         (proc (make-process
                :name "filetags-tagtrees"
                :buffer (generate-new-buffer " *dired-filetags-tagtrees*")
                :connection-type 'pipe
                :coding 'utf-8-unix
                :noquery t
                :command `(,program "-q" "--tagtrees"
                                    "--tagtrees-dir" ,(directory-file-name target)
                                    "--filebrowser" "none"
                                    "--tagtrees-depth" ,(number-to-string (plist-get params :depth))
                                    "--tagtrees-handle-no-tag" ,(plist-get params :untagged)
                                    ,@(and (plist-get params :recursive) '("-R")))
                :sentinel #'dired-filetags--tagtrees-sentinel)))
    ;; stderr is merged into the buffer: under -q any output is an error.
    (ignore-errors (process-send-eof proc))
    (process-put proc 'dired-filetags-target target)
    (process-put proc 'dired-filetags-params (append (list :source source) params))
    (process-put proc 'dired-filetags-origin (cons (selected-window) (current-buffer)))
    proc))

(defun dired-filetags--tagtrees-sentinel (proc _event)
  "Finish the TagTrees build PROC once it has exited.
On success, record the sidecar and visit the tree, if the window that
started the build still shows the buffer it showed then; on failure,
log the output.  Either way, refresh the Dired buffers inside the tree."
  (unless (process-live-p proc)
    (unwind-protect
        (let* ((target (process-get proc 'dired-filetags-target))
               (params (process-get proc 'dired-filetags-params))
               (source (plist-get params :source))
               (name (dired-filetags--pretty-dir source))
               (origin (process-get proc 'dired-filetags-origin))
               (buf (process-buffer proc))
               (output (if (buffer-live-p buf)
                           (with-current-buffer buf (ansi-color-filter-apply (buffer-string)))
                         ""))
               (code (process-exit-status proc))
               (ok (and (eq (process-status proc) 'exit)
                        (not (dired-filetags--failed-p code output))
                        (file-exists-p (expand-file-name ".filetags_tagtrees" target)))))
          (when (buffer-live-p buf) (kill-buffer buf))
          (when ok (dired-filetags--write-sidecar target params))
          (dired-filetags--refresh-tree-buffers target source)
          (if (not ok)
              (with-current-buffer (if (buffer-live-p (cdr origin)) (cdr origin) (current-buffer))
                (dired-log "TagTrees of %s failed (exit %s):\n%s\n" source code output)
                (dired-log t)
                (message "TagTrees of %s failed (exit %s): %s; type ? for details" name code
                         (dired-filetags--first-line output)))
            (pcase-let ((`(,win . ,obuf) origin))
              ;; Never take over a window the user has moved on in, nor
              ;; leave a wdired edit, and leave a tree buffer that was
              ;; just rebuilt in place.
              (when (and (window-live-p win)
                         (eq (window-buffer win) obuf)
                         (with-current-buffer obuf (derived-mode-p 'dired-mode))
                         (not (string-prefix-p target (expand-file-name
                                                       (buffer-local-value 'default-directory
                                                                           obuf)))))
                (with-selected-window win (dired target))))
            (message "TagTrees of %s ready" name)))
      (process-put proc 'dired-filetags-done t))))

(defun dired-filetags--refresh-tree-buffers (target source)
  "Revert every Dired buffer inside TagTree TARGET after a build of SOURCE.
A buffer whose directory is gone is replaced in each of its windows by
Dired on TARGET, or on SOURCE if the tree is gone too, and killed."
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (with-current-buffer buf
                 (and (derived-mode-p 'dired-mode)
                      ;; Trees are local; expanding a remote "~" could connect.
                      (not (file-remote-p default-directory))
                      (string-prefix-p target (expand-file-name default-directory)))))
      (if (file-directory-p (buffer-local-value 'default-directory buf))
          (with-current-buffer buf (revert-buffer))
        (let ((new (dired-noselect (if (file-directory-p target) target source))))
          (dolist (win (get-buffer-window-list buf nil t))
            (set-window-buffer win new))
          (kill-buffer buf))))))

(defun dired-filetags--tagtrees-build (source target params &optional confirm)
  "Check, prescan and start TagTrees of SOURCE in TARGET; return the process.
PARAMS has :recursive, :depth and :untagged.  With CONFIRM, ask before
building more than `dired-filetags-tagtrees-link-limit' links."
  (dired-filetags--check-untagged (plist-get params :untagged))
  (dired-filetags--tagtrees-check source target (plist-get params :recursive))
  (let ((links (dired-filetags--tagtrees-prescan source params)))
    (when (and confirm (> links dired-filetags-tagtrees-link-limit)
               (not (y-or-n-p (format "TagTrees of %s need about %d links; build them? "
                                      (dired-filetags--pretty-dir source) links))))
      (user-error "TagTrees not built")))
  (dired-filetags--tagtrees-start source target params))

(defun dired-filetags--tagtrees-rebuild (root)
  "Rebuild the TagTree at ROOT with the parameters in its sidecar.
The checks and the prescan of a first build run, but there is no
question about the size.  Return the process."
  (let* ((sidecar (dired-filetags--read-sidecar root))
         (source (plist-get sidecar :source))
         (params (list :recursive (plist-get sidecar :recursive)
                       :depth (plist-get sidecar :depth)
                       :untagged (plist-get sidecar :untagged))))
    (unless (and (stringp source) (natnump (plist-get params :depth))
                 (stringp (plist-get params :untagged)))
      (user-error "Cannot read the parameters of the TagTree %s"
                  (dired-filetags--pretty-dir root)))
    (unless (file-directory-p source)
      (user-error "The source of this TagTree, %s, no longer exists"
                  (dired-filetags--pretty-dir source)))
    (dired-filetags--tagtrees-build source root params)))

;;;###autoload
(defun dired-filetags-tagtrees (&optional recursive)
  "Build TagTrees for this directory and visit them.
A TagTree is a directory of symbolic links with one folder per tag, and
folders for tag combinations inside those, as deep as
`dired-filetags-tagtrees-depth'.  Each source directory gets its own
tree below `dired-filetags-tagtrees-directory'.  With prefix argument
RECURSIVE, files in subdirectories are included.

Inside a tree built by this command, rebuild that tree with its own
parameters instead; the prefix argument is then ignored.  The build runs
in the background, and Dired visits the tree when it is ready, unless
you have moved on in that window.  Return the process."
  (interactive "P" dired-mode)
  (dired-filetags--check-dired)
  (let ((dir (dired-current-directory)))
    (if-let* ((root (dired-filetags--tagtree-root dir)))
        (let ((proc (dired-filetags--tagtrees-rebuild root)))
          (message "Rebuilding TagTrees of %s..."
                   (dired-filetags--pretty-dir
                    (plist-get (process-get proc 'dired-filetags-params) :source)))
          proc)
      (let* ((source (file-name-as-directory (expand-file-name dir)))
             (proc (dired-filetags--tagtrees-build
                    source (dired-filetags--tagtrees-target source)
                    (list :recursive (and recursive t)
                          :depth dired-filetags-tagtrees-depth
                          :untagged dired-filetags-tagtrees-untagged)
                    t)))
        (message "Building TagTrees of %s (depth %d)..."
                 (dired-filetags--pretty-dir source) dired-filetags-tagtrees-depth)
        proc))))

;;;###autoload
(defun dired-filetags-visit-original ()
  "Visit, in Dired, the file that the symbolic link at point points to.
In a TagTree, that is the tagged entry in its source directory, even if
that entry is itself a symbolic link."
  (interactive nil dired-mode)
  (dired-filetags--check-dired)
  (let ((link (dired-get-filename nil t)))
    (unless (and link (file-symlink-p link))
      (user-error "Not a symbolic link"))
    ;; A link to itself, as filetags makes for broken links, does not exist.
    (let ((original (dired-filetags--link-original
                     link (dired-filetags--tagtree-source (file-name-directory link)))))
      (unless (file-exists-p original)
        (user-error "Stale link: %s does not exist; rebuild with %s"
                    (abbreviate-file-name original) (dired-filetags--key "v")))
      (dired-jump nil original))))

(defun dired-filetags--setup-tagtree-buffer ()
  "Set up the current Dired buffer if its directory is inside a TagTree.
Link targets are hidden along with the details, and in a tree built by
this package a header line names the source and the tag path."
  (when (dired-filetags--inside-tagtree-p default-directory)
    (setq-local dired-hide-details-hide-symlink-targets t)
    (dired-hide-details-update-invisibility-spec)
    (setq dired-filetags--tagtree t)
    (when-let* ((root (dired-filetags--tagtree-root default-directory)))
      (setq dired-filetags--tagtree
            (append (dired-filetags--read-sidecar root) (list :root root)))
      (setq-local header-line-format '(:eval (dired-filetags--tagtree-header))))))

(defun dired-filetags--tagtree-header ()
  "Return the header line of a TagTree buffer: its source and tag path.
The result is a mode-line construct, so \"%\" is doubled."
  (let* ((root (plist-get dired-filetags--tagtree :root))
         (source (or (plist-get dired-filetags--tagtree :source) root))
         (tags (split-string (file-relative-name (expand-file-name default-directory) root)
                             "/" t)))
    (string-replace
     "%" "%%"
     (concat " TagTrees of " (dired-filetags--pretty-dir source)
             (mapconcat (lambda (tag) (concat " › " tag)) (delete "." tags) "")
             (format "   (%s rebuild, %s original)"
                     (dired-filetags--key "v") (dired-filetags--key "o"))))))

;;;; Rendering

(defvar dired-filetags-mode)            ; `define-minor-mode' below

(defun dired-filetags--overlay (beg end &rest props)
  "Make an overlay of this package from BEG to END with PROPS; return it."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'dired-filetags t)
    (overlay-put ov 'evaporate t)
    ;; Above dired-subtree's backgrounds (no priority) and hl-line (-50).
    (overlay-put ov 'priority 50)
    (while props (overlay-put ov (pop props) (pop props)))
    ov))

(defun dired-filetags--tag-face (tag)
  "Return the face of TAG's label: its override, or its hashed colour.
Without any `dired-filetags-tag-colors', it is plain `dired-filetags-tag'."
  (cond
   ((alist-get tag dired-filetags-tag-faces nil nil #'equal)
    (list (alist-get tag dired-filetags-tag-faces nil nil #'equal) 'dired-filetags-tag))
   ((null dired-filetags-tag-colors) 'dired-filetags-tag)
   ;; md5 is stable across sessions and machines, unlike `sxhash'.
   (t (let ((bg (nth (mod (string-to-number (substring (md5 tag nil nil 'utf-8) 0 8) 16)
                          (length dired-filetags-tag-colors))
                     dired-filetags-tag-colors)))
        `((:background ,bg :box (:line-width (2 . -1) :color ,bg)) dired-filetags-tag)))))

(defun dired-filetags--label-face (tag)
  "Return the face of the label of TAG, which may be the token \"--\"."
  (if (equal tag "--") 'dired-filetags-separator (dired-filetags--tag-face tag)))

(defun dired-filetags--right-labels (tags)
  "Show TAGS as labels ending two columns from the right window edge.
They go at the end of this line, after any symbolic link target.  The
padding aligns to the right edge when the line is displayed, so a
change of window width needs no refresh, and each window showing the
buffer lays it out for its own width."
  (let* ((labels (mapconcat (lambda (tag)
                              (propertize tag 'face (dired-filetags--label-face tag)))
                            (seq-remove #'string-empty-p tags) " "))
         (eol (line-end-position))
         (last-line (= eol (point-max)))
         ;; Continue the line's own background, such as dired-subtree's.
         (face (get-char-property (if last-line (max (point-min) (1- eol)) eol) 'face))
         (width (if (< emacs-major-version 31)
                    (string-pixel-width labels)
                  ;; Emacs 31 applies the buffer's face remapping.  Older
                  ;; compilers would reject the second argument.
                  (with-suppressed-warnings ((callargs string-pixel-width))
                    (string-pixel-width labels (current-buffer)))))
         ;; Two columns short of the edge, as Dired indents names by two.
         ;; On a terminal, one of them is the column it reserves.
         (pad `(space :align-to (- right (,width) 2)))
         ;; The plain space keeps the labels apart from a name too long
         ;; to leave room for them.
         (string (concat (propertize " " 'face face)
                         (propertize " " 'face face 'display pad)
                         labels)))
    (unless (string-empty-p labels)
      (if last-line
          (dired-filetags--overlay (1- eol) eol 'after-string string)
        (dired-filetags--overlay eol (1+ eol) 'before-string string)))))

(defun dired-filetags--decorate (beg end)
  "Decorate the file name from BEG to END, if it has tags.
In `right' style the tags are hidden in the name and shown as labels at
the right edge of the window.  Otherwise each tag gets a label in place,
and in `aligned' style the extension is also shown right after the base
name, and padding moves the labels to a column.  Only the basename is
parsed: in explicit file-list buffers, such as `find-dired' makes, a
name can be a relative path."
  (let* ((whole (buffer-substring-no-properties beg end))
         (dir-end (let ((slash (cl-position ?/ whole :from-end t))) (if slash (1+ slash) 0)))
         (lead (string-width (substring whole 0 dir-end)))
         (prefix (get-char-property beg 'line-prefix))
         (beg (+ beg dir-end))
         (name (substring whole dir-end)))
    (pcase (dired-filetags--split name)
      ((and `(,sep ,tags-end ,_) (guard (eq dired-filetags-display-style 'right)))
       (dired-filetags--overlay (+ beg sep) (+ beg tags-end) 'display "")
       (dired-filetags--right-labels (split-string (substring name (+ sep 4) tags-end) " ")))
      (`(,sep ,tags-end ,_)
       (let ((pos (+ sep 4)))
         (dolist (tag (split-string (substring name pos tags-end) " "))
           (unless (equal tag "")
             (dired-filetags--overlay (+ beg pos) (+ beg pos (length tag))
                                      'face (dired-filetags--label-face tag)))
           (setq pos (+ pos (length tag) 1))))
       (if (eq dired-filetags-display-style 'inline)
           (dired-filetags--overlay (+ beg sep) (+ beg sep 4) 'face 'dired-filetags-separator)
         (let* ((tail (and (< tags-end (length name))
                           (propertize (substring name tags-end)
                                       'face (get-text-property (+ beg tags-end) 'face))))
                (used (+ lead (string-width (substring name 0 sep))
                         (if tail (string-width tail) 0)
                         (if (stringp prefix) (string-width prefix) 0)))
                ;; A fresh object per line: `eq' identity decides where a
                ;; replaced unit ends.
                (pad (list 'space :width (max 2 (- dired-filetags-align-width used)))))
           ;; A display string cannot hold display specs, so the padding
           ;; replaces the rest of the separator on its own.
           (if (not tail)
               (dired-filetags--overlay (+ beg sep) (+ beg sep 4) 'display pad)
             (dired-filetags--overlay (+ beg sep) (+ beg sep 1) 'display tail)
             (dired-filetags--overlay (+ beg sep 1) (+ beg sep 4) 'display pad)
             (dired-filetags--overlay (+ beg tags-end) end 'display ""))))))))

(defun dired-filetags--fontify (start end)
  "Rebuild this package's overlays on the whole lines from START to END.
This is a `jit-lock-functions' member that runs after font-lock.  Only
file names are decorated, never in wdired, -b listings, or names that
`dired-filename-display-length' shortens.  Lines are only examined one
by one if the region contains \" -- \", which every tagged name has."
  (save-excursion
    (save-match-data
      (let ((s (progn (goto-char start) (line-beginning-position)))
            (e (progn (goto-char end) (line-beginning-position 2))))
        (remove-overlays s e 'dired-filetags t)
        (when (and dired-filetags-mode
                   dired-filetags-display-style
                   (derived-mode-p 'dired-mode)            ; nil in wdired
                   (not (and (stringp dired-actual-switches)
                             (dired-switches-escape-p dired-actual-switches)))
                   ;; Only a name with " -- " has tags, so a stretch of
                   ;; untagged lines costs this one search.
                   (progn (goto-char s) (search-forward " -- " e t)))
          (goto-char s)
          (while (< (point) e)
            (let ((bol (point)))
              (ignore-errors                          ; never signal in redisplay
                (when-let* ((beg (dired-move-to-filename))
                            (fend (dired-move-to-end-of-filename t)))
                  (unless (seq-some (lambda (ov) (eq (overlay-get ov 'invisible)
                                                     'dired-filename-hide))
                                    (overlays-in beg fend))
                    (dired-filetags--decorate beg fend))))
              (goto-char bol)
              (forward-line 1))))
        `(jit-lock-bounds ,s . ,e)))))

(defun dired-filetags--remove-overlays ()
  "Remove this package's overlays from the whole buffer."
  (save-restriction
    (widen)
    (remove-overlays (point-min) (point-max) 'dired-filetags t)))

;;;; Keymaps and mode

(defvar-keymap dired-filetags-command-map
  :doc "Commands under `dired-filetags-prefix-key' in `dired-filetags-mode'."
  "a" #'dired-filetags-add-remove
  "m" #'dired-filetags-mark
  "n" #'dired-filetags-mark-not
  "u" #'dired-filetags-mark-untagged
  "v" #'dired-filetags-tagtrees
  "o" #'dired-filetags-visit-original)

(defvar-keymap dired-filetags-mark-map
  :doc "Additions to Dired's \"*\" prefix in `dired-filetags-mode'."
  "#" #'dired-filetags-mark
  "~" #'dired-filetags-mark-not)

(defun dired-filetags--unless-wdired (binding)
  "Return BINDING, or nil in wdired, where keys must self-insert.
The mode only runs in Dired, and stays on across wdired's in-place
major-mode switch.  Help commands such as PREFIX \\`C-h' evaluate this
filter in their own buffer, which must see BINDING too."
  (unless (derived-mode-p 'wdired-mode) binding))

(defvar-keymap dired-filetags-mode-map
  :doc "Keymap of `dired-filetags-mode'.
The minor mode stays on across wdired's in-place major-mode switch, so
plain prefixes would swallow `dired-filetags-prefix-key' and \"*\" while
editing names."
  "*" `(menu-item "" ,dired-filetags-mark-map :filter dired-filetags--unless-wdired))

(defun dired-filetags--bind-prefix (key)
  "Bind the tag commands under KEY in `dired-filetags-mode-map'.
The key they were bound under before is unbound, so no other key
changes.  Signal `user-error' if KEY is not a valid key, or if it starts
with \"*\", which holds the mode's additions to Dired's marking keys."
  (unless (key-valid-p key)
    (user-error "Not a valid key for `dired-filetags-prefix-key': %S" key))
  (when (eq (aref (key-parse key) 0) ?*)
    (user-error "`dired-filetags-prefix-key' cannot start with \"*\": %S" key))
  (when dired-filetags--bound-prefix
    (keymap-unset dired-filetags-mode-map dired-filetags--bound-prefix t))
  (keymap-set dired-filetags-mode-map key
              `(menu-item "" ,dired-filetags-command-map :filter dired-filetags--unless-wdired))
  (setq dired-filetags--bound-prefix key))

(dired-filetags--bind-prefix dired-filetags-prefix-key)

;;;###autoload
(define-minor-mode dired-filetags-mode
  "Show filetags tags as coloured labels and bind tag commands.
In the default `right' style (see `dired-filetags-display-style'), a
name such as \"Report -- work urgent.pdf\" shows as \"Report.pdf\", with
the labels work and urgent ending two columns from the right edge of the
window, as names start two columns from the left.  The
buffer text is not changed, and wdired (\\<dired-mode-map>\\[dired-toggle-read-only]) shows the raw names.

The commands are under PREFIX, the key `dired-filetags-prefix-key'
\(\";\" by default, which Dired leaves unbound).  PREFIX a adds tags
to the marked files or the file at point, except that a tag every one
of them already has is removed from all of them; on a single file, a
tag it has is removed.  `dired-filetags-add' and `dired-filetags-remove'
only add or only remove, and have no key.  PREFIX m marks the files
that have any of the tags you type, PREFIX n the files that have none
of them, and PREFIX u the untagged files; after \\`C-u' they unmark
instead.  * # and * ~ are the same as PREFIX m and PREFIX n.  PREFIX v
builds TagTrees of the directory, or rebuilds the tree you are in, and
PREFIX o visits the original of a link.

\\{dired-filetags-mode-map}"
  :lighter nil
  :keymap dired-filetags-mode-map
  :group 'dired-filetags
  (if dired-filetags-mode
      (if (not (derived-mode-p 'dired-mode))
          (progn
            (setq dired-filetags-mode nil)
            (user-error "Dired-Filetags mode only works in Dired buffers"))
        (add-hook 'jit-lock-functions #'dired-filetags--fontify 90 t)
        (jit-lock-mode t)
        (add-hook 'wdired-mode-hook #'dired-filetags--remove-overlays nil t)
        ;; Right-edge labels are measured in pixels at the buffer's text scale.
        (add-hook 'text-scale-mode-hook #'jit-lock-refontify nil t)
        (dired-filetags--setup-tagtree-buffer)
        (jit-lock-refontify))
    ;; Unlike `remove-hook', this also turns jit-lock off if nothing else uses it.
    (jit-lock-unregister #'dired-filetags--fontify)
    (remove-hook 'wdired-mode-hook #'dired-filetags--remove-overlays t)
    (remove-hook 'text-scale-mode-hook #'jit-lock-refontify t)
    (dired-filetags--remove-overlays)
    (when dired-filetags--tagtree
      (kill-local-variable 'dired-hide-details-hide-symlink-targets)
      (when (consp dired-filetags--tagtree)
        (kill-local-variable 'header-line-format))
      (dired-hide-details-update-invisibility-spec))
    (kill-local-variable 'dired-filetags--tagtree)))

(defun dired-filetags-unload-function ()
  "Turn `dired-filetags-mode' off in every buffer, for `unload-feature'.
`unload-feature' only cleans global hooks, and the mode's jit-lock
function would stay in each buffer's local list.  Return nil, so that
the definitions are removed as usual."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when dired-filetags-mode
        (dired-filetags-mode -1))))
  nil)

(provide 'dired-filetags)
;;; dired-filetags.el ends here
