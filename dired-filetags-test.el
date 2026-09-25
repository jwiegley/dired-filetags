;;; dired-filetags-test.el --- Tests for dired-filetags -*- lexical-binding: t; -*-

;;; Commentary:

;; Run the whole suite in batch Emacs from the project directory with:
;;
;;   ${EMACS:-emacs} -Q -batch -L . --eval '(setq load-prefer-newer t)' \
;;     -l ert -l ./dired-filetags-test.el -f ert-run-tests-batch-and-exit
;;
;; or with `nix flake check', whose ert check provides filetags and git.
;; Tests that need the filetags CLI skip themselves when it is missing.
;; Every test works in a fresh temporary directory; scratch directories
;; and TagTrees are redirected below it, so nothing else is touched.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'wdired)
(require 'dired-filetags)

(declare-function dired-subtree-insert "dired-subtree" ())
(defvar vertico--lock-candidate)
(defvar text-scale-mode-hook)

;;;; Fixtures

(defconst dired-filetags-test--vectors
  '(
    ("foo.txt" nil nil nil "foo -- NEW.txt" nil nil)
    ("foo" nil nil nil "foo -- NEW" nil nil)
    ("foo -- a.txt" "foo" ("a") "txt" "foo -- a NEW.txt" "a" "foo.txt")
    ("foo -- a b.txt" "foo" ("a" "b") "txt" "foo -- a b NEW.txt" "a" "foo -- b.txt")
    ("foo -- a b" "foo" ("a" "b") nil "foo -- a b NEW" "a" "foo -- b")
    (".hidden" nil nil nil " -- NEW.hidden" nil nil)
    (".hidden -- a" ".hidden" ("a") nil " NEW.hidden -- a" "a" ".hidden")
    (" -- h.hidden" nil nil nil " -- h -- NEW.hidden" nil nil)
    ("a.b.c.tar.gz" nil nil nil "a.b.c.tar -- NEW.gz" nil nil)
    ("a.b.c -- x.tar.gz" "a.b.c" ("x.tar") "gz" "a.b.c -- x.tar NEW.gz" "x.tar" "a.b.c.gz")
    ("archive.tar -- x.gz" "archive.tar" ("x") "gz" "archive.tar -- x NEW.gz" "x" "archive.tar.gz")
    ("multi -- x -- y.txt" "multi" ("x" "--" "y") "txt" "multi -- x -- y NEW.txt" "x" "multi -- -- y.txt")
    ("foo -- .txt" "foo" (".txt") nil "foo --  NEW.txt" ".txt" "foo")
    ("foo -- a  b.txt" "foo" ("a" "" "b") "txt" "foo -- a  b NEW.txt" "a" "foo --  b.txt")
    ("foo -- a .txt" "foo" ("a" "") "txt" "foo -- a  NEW.txt" "a" "foo -- .txt")
    ("foo -- a.txt " "foo" ("a.txt" "") nil "foo -- a NEW.txt " "a.txt" "foo -- ")
    ("foo -- a a.txt" "foo" ("a" "a") "txt" "foo -- a a NEW.txt" "a" "foo -- .txt")
    ("Foo -- A a.txt" "Foo" ("A" "a") "txt" "Foo -- A a NEW.txt" "A" "Foo -- a.txt")
    ("café -- naïve 日本語.pdf" "café" ("naïve" "日本語") "pdf" "café -- naïve 日本語 NEW.pdf" "naïve" "café -- 日本語.pdf")
    ("foo -- c++ c# node.js.txt" "foo" ("c++" "c#" "node.js") "txt" "foo -- c++ c# node.js NEW.txt" "c++" "foo -- c# node.js.txt")
    ("foo -- a.b.c" "foo" ("a.b") "c" "foo -- a.b NEW.c" "a.b" "foo.c")
    ("foo -- a.tar-gz" "foo" ("a.tar-gz") nil "foo -- a NEW.tar-gz" "a.tar-gz" "foo")
    ("foo -- a.日本" "foo" ("a") "日本" "foo -- a NEW.日本" "a" "foo.日本")
    ("foo -- a.½" "foo" ("a") "½" "foo -- a NEW.½" "a" "foo.½")
    ("foo -- a.pdf.lnk" "foo" ("a") "pdf" "foo -- a NEW.pdf.lnk" "a" "foo.pdf.lnk")
    ("foo --a.txt" nil nil nil "foo --a -- NEW.txt" nil nil)
    ("foo--a.txt" nil nil nil "foo--a -- NEW.txt" nil nil)
    ("foo -- " nil nil nil "foo --  -- NEW" nil nil)
    ("foo -- -x.txt" "foo" ("-x") "txt" "foo -- -x NEW.txt" "x" "foo -- -x.txt")
    ("x --  a.txt" "x" ("" "a") "txt" "x --  a NEW.txt" "a" "x -- .txt")
    ("2024-01-01 Meeting -- work.org" "2024-01-01 Meeting" ("work") "org" "2024-01-01 Meeting -- work NEW.org" "work" "2024-01-01 Meeting.org")
    ("foo -- a_b-c.txt" "foo" ("a_b-c") "txt" "foo -- a_b-c NEW.txt" "a_b-c" "foo.txt")
    ("foo.TXT" nil nil nil "foo -- NEW.TXT" nil nil)
    ("foo -- a." "foo" ("a.") nil "foo -- a NEW." "a." "foo")
    ("foo -- a.b c.txt" "foo" ("a.b" "c") "txt" "foo -- a.b c NEW.txt" "a.b" "foo -- c.txt")
    ("foo -- a b.tar.gz" "foo" ("a" "b.tar") "gz" "foo -- a b.tar NEW.gz" "a" "foo -- b.tar.gz")
    ("foo -- a\11b.txt" "foo" ("a\11b") "txt" "foo -- a\11b NEW.txt" "a\11b" "foo.txt")
    (" leading -- a.txt" " leading" ("a") "txt" " leading -- a NEW.txt" "a" " leading.txt")
    ("a -- b -- c" "a" ("b" "--" "c") nil "a -- b -- c NEW" "b" "a -- -- c")
    ("x -- y.z -- w.txt" "x" ("y.z" "--" "w") "txt" "x -- y.z -- w NEW.txt" "y.z" "x -- -- w.txt")
    ("foo -- a.PDF.LNK" "foo" ("a") "PDF" "foo -- a NEW.PDF.lnk" "a" "foo.PDF.lnk")
    ("foo.lnk" nil nil nil "foo -- NEW.lnk" nil nil)
    ("v1.2 notes -- foo" "v1.2 notes" ("foo") nil "v1 NEW.2 notes -- foo" "foo" "v1.2 notes")
    ("v1.2 notes" nil nil nil "v1 -- NEW.2 notes" nil nil)
    ("foo -- bar.tar-gz" "foo" ("bar.tar-gz") nil "foo -- bar NEW.tar-gz" "bar.tar-gz" "foo")
    ("README" nil nil nil "README -- NEW" nil nil)
    ("Makefile.am" nil nil nil "Makefile -- NEW.am" nil nil)
    ("foo -- a.txt~" "foo" ("a.txt~") nil "foo -- a NEW.txt~" "a.txt~" "foo")
    ("foo -- a.txt.bak" "foo" ("a.txt") "bak" "foo -- a.txt NEW.bak" "a.txt" "foo.bak")
    ("foo -- a.c++" "foo" ("a.c++") nil "foo -- a NEW.c++" "a.c++" "foo")
    ("foo -- a b." "foo" ("a" "b.") nil "foo -- a b NEW." "a" "foo -- b.")
    )
  "CLI vectors recorded from filetags 2026-03-01.
Each entry is (NAME BASE TAGS EXT AFTER-ADD-\"NEW\" REMOVED-TAG AFTER-REMOVE).")

(defconst dired-filetags-test--refused-adds
  '(".hidden" ".hidden -- a" "multi -- x -- y.txt" "foo -- .txt" "foo -- a  b.txt"
    "foo -- a .txt" "foo -- a.txt " "foo -- a.tar-gz" "foo -- " "x --  a.txt" "foo -- a."
    "a -- b -- c" "x -- y.z -- w.txt" "v1.2 notes -- foo" "v1.2 notes" "foo -- bar.tar-gz"
    "foo -- a.txt~" "foo -- a.c++" "foo -- a b.")
  "Vector names whose CLI result for adding NEW must be refused (19).")

(defconst dired-filetags-test--refused-removes
  '("multi -- x -- y.txt" "foo -- a  b.txt" "foo -- a .txt" "foo -- a.txt " "foo -- a a.txt"
    "x --  a.txt" "a -- b -- c" "x -- y.z -- w.txt")
  "Vector names whose CLI result for removing their tag must be refused (8 of 38).")

;;;; Helpers

(defun dired-filetags-test--populate (root spec)
  "Create SPEC below ROOT.
Entries: \"NAME\" (empty file), \"DIR/\" (directory), (NAME . CONTENTS),
or (NAME :symlink TARGET).  NAME may contain subdirectories."
  (dolist (entry spec)
    (let* ((name (if (consp entry) (car entry) entry))
           (path (expand-file-name name root)))
      (make-directory (file-name-directory path) t)
      (cond ((and (consp entry) (consp (cdr entry)) (eq (cadr entry) :symlink))
             (make-symbolic-link (caddr entry) path))
            ((string-suffix-p "/" name) (make-directory path t))
            (t (let ((file-name-handler-alist nil))
                 (write-region (if (consp entry) (cdr entry) "") nil path nil 0)))))))

(defun dired-filetags-test--in-root-p (root file)
  "Return non-nil if FILE, a string or nil, lies below ROOT."
  (and (stringp file) (string-prefix-p root (expand-file-name file))))

(defun dired-filetags-test--cleanup (root buffers)
  "Delete ROOT, and the processes and buffers a test made below it.
Buffers in BUFFERS existed before the test and are never touched, and
only TagTrees builds of a tree below ROOT are stopped, so an interactive
session keeps its own buffers, edits and builds."
  (dolist (proc (process-list))
    (when (dired-filetags-test--in-root-p root (process-get proc 'dired-filetags-target))
      (set-process-sentinel proc #'ignore)
      (delete-process proc)))
  (dolist (buf (buffer-list))
    (unless (memq buf buffers)
      (when (or (equal (buffer-name buf) dired-log-buffer)
                (dired-filetags-test--in-root-p root (buffer-local-value 'default-directory buf)))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf))))
  (delete-directory root t))

(defmacro dired-filetags-test--with-prefix (key &rest body)
  "Run BODY with the tag commands under KEY, set with `setopt'.
The previous prefix is restored afterwards, also when BODY fails."
  (declare (indent 1) (debug (form body)))
  (let ((old (make-symbol "old")))
    `(let ((,old dired-filetags-prefix-key))
       (unwind-protect
           (progn (setopt dired-filetags-prefix-key ,key)
                  ,@body)
         (setopt dired-filetags-prefix-key ,old)))))

(defconst dired-filetags-test--log-buffer " *dired-filetags-test-log*"
  "The `dired-log-buffer' of the tests, so the user's *Dired log* is left alone.")

(defun dired-filetags-test--stock-dired-map ()
  "Return `dired-mode-map', or a child of it with Dired's EasyPG prefix.
The key tests expect Dired's own \":\" prefix.  A session that binds
\":\" to a command, as the README suggests for
`dired-filetags-add-remove', gets a child map with the prefix put back,
for the tests' Dired buffers only; `dired-mode-map' is never changed."
  (if (keymapp (keymap-lookup dired-mode-map ":"))
      dired-mode-map
    (define-keymap :parent dired-mode-map
      ": d" #'epa-dired-do-decrypt
      ": v" #'epa-dired-do-verify
      ": s" #'epa-dired-do-sign
      ": e" #'epa-dired-do-encrypt)))

(defmacro dired-filetags-test--with-dir (spec &rest body)
  "Run BODY with `root' bound to a fresh directory populated from SPEC.
Scratch directories, TagTrees and the Dired log are redirected, so
nothing outside ROOT is touched, and everything the test made is
deleted afterwards.  BODY starts in a buffer of its own, the user's
Dired hooks do not run, the tag commands are under the default
prefix, \";\", and Dired buffers have Dired's own \":\" prefix, as
`dired-filetags-test--stock-dired-map' provides."
  (declare (indent 1) (debug (sexp body)))
  (let ((buffers (make-symbol "buffers")))
    `(let ((,buffers (buffer-list)))
       (with-temp-buffer
         (let* ((root (file-name-as-directory
                       (file-truename (make-temp-file "dired-filetags-test-" t))))
                (temporary-file-directory (expand-file-name "tmp/" root))
                (dired-filetags-tagtrees-directory (expand-file-name "trees/" root))
                (dired-filetags-program "filetags")
                (dired-filetags-display-style 'aligned)
                (dired-filetags-align-width 32)
                (dired-filetags-tagtrees-depth 2)
                (dired-filetags-tagtrees-untagged "no-tags")
                (dired-filetags-tagtrees-link-limit 50000)
                (dired-filetags-tag-faces nil)
                (dired-listing-switches "-lah")
                (dired-vc-rename-file nil)
                (dired-mode-hook nil)
                (dired-mode-map (dired-filetags-test--stock-dired-map))
                (dired-log-buffer dired-filetags-test--log-buffer)
                (default-directory root))
           (make-directory temporary-file-directory)
           (when (get-buffer dired-log-buffer) (kill-buffer dired-log-buffer))
           (unwind-protect
               (save-window-excursion
                 (dired-filetags-test--with-prefix ";"
                   (dired-filetags-test--populate root ',spec)
                   ,@body))
             (dired-filetags-test--cleanup root ,buffers)))))))

(defun dired-filetags-test--names (dir)
  "Return the sorted entries of DIR, without . and ..."
  (sort (directory-files dir nil directory-files-no-dot-files-regexp) #'string<))

(defun dired-filetags-test--dired (dir)
  "Make a Dired buffer on DIR current and return it."
  (let ((buf (dired-noselect dir)))
    (set-buffer buf)
    buf))

(defun dired-filetags-test--goto (file)
  "Move point to FILE's line in the current Dired buffer, or fail."
  (should (dired-goto-file file)))

(defun dired-filetags-test--mark-files (files &optional char)
  "Mark FILES in the current Dired buffer with CHAR, default `*'."
  (dolist (file files)
    (dired-filetags-test--goto file)
    (let ((dired-marker-char (or char ?*)))
      (dired-mark 1))))

(defun dired-filetags-test--marks ()
  "Return the marked lines of this Dired buffer as sorted (NAME . CHAR)."
  (sort (mapcar (lambda (m) (cons (file-name-nondirectory (car m)) (cdr m)))
                (dired-remember-marks (point-min) (point-max)))
        (lambda (a b) (string< (car a) (car b)))))

(defun dired-filetags-test--log ()
  "Return the contents of `dired-log-buffer', or the empty string."
  (if-let* ((buf (get-buffer dired-log-buffer)))
      (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max)))
    ""))

(defun dired-filetags-test--last-message ()
  "Return the last non-empty line of the *Messages* buffer."
  (with-current-buffer (messages-buffer)
    (car (last (split-string (buffer-substring-no-properties (point-min) (point-max))
                             "\n" t)))))

(defun dired-filetags-test--case-insensitive-p (dir)
  "Return non-nil if the filesystem of directory DIR is case-insensitive.
A probe file in DIR decides, so the answer holds for case-insensitive
APFS, case-sensitive APFS and ext4 alike."
  (let ((probe (make-temp-file (expand-file-name "case-probe-" dir))))
    (unwind-protect
        (file-exists-p (concat (file-name-directory probe)
                               (upcase (file-name-nondirectory probe))))
      (delete-file probe))))

(defun dired-filetags-test--script (root name body)
  "Write an executable shell script NAME below ROOT running BODY.
Return its absolute file name."
  (let ((file (expand-file-name name root)))
    (let ((file-name-handler-alist nil))
      (write-region (concat "#!/bin/sh\n" body) nil file nil 0))
    (set-file-modes file #o755)
    file))

(defun dired-filetags-test--wait (proc)
  "Wait up to 30 seconds for PROC's sentinel to finish, then check it did."
  (let ((deadline (+ (float-time) 30)))
    (while (and (not (process-get proc 'dired-filetags-done))
                (< (float-time) deadline))
      (accept-process-output nil 0.05)))
  (should (process-get proc 'dired-filetags-done)))

(defun dired-filetags-test--overlays (&optional beg end)
  "Return this package's overlays in BEG..END, sorted by start.
BEG and END default to the whole buffer."
  (sort (seq-filter (lambda (ov) (overlay-get ov 'dired-filetags))
                    (overlays-in (or beg (point-min)) (or end (point-max))))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defmacro dired-filetags-test--forbid-cli (&rest body)
  "Run BODY, failing the test if filetags would be run."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'dired-filetags--call)
              (lambda (&rest _) (ert-fail "filetags must not run")))
             ((symbol-function 'dired-filetags--new-names)
              (lambda (&rest _) (ert-fail "filetags must not run"))))
     ,@body))

;;;; The fixture itself

(ert-deftest dired-filetags-test-fixture-spares-the-users-buffers-and-builds ()
  "Consecutive fixtures never kill or unmodify buffers or builds they did not make."
  (let* ((mine (generate-new-buffer "dired-filetags-test-user"))
         (had-log (get-buffer "*Dired log*"))
         (log (or had-log (get-buffer-create "*Dired log*")))
         (log-text (with-current-buffer log (buffer-string)))
         (proc (make-process :name "dired-filetags-test-foreign" :command '("sleep" "30")
                             :noquery t)))
    (process-put proc 'dired-filetags-target "/nonexistent-dired-filetags-test/tree/")
    (unwind-protect
        (with-current-buffer mine
          (insert "unsaved")
          (dotimes (_ 2)
            (dired-filetags-test--with-dir ("a.txt")
              (dired-filetags-test--dired root)
              (dired-log "test entry\n")))
          (should (buffer-live-p mine))
          (should (buffer-modified-p mine))
          (should (buffer-live-p log))
          (should (equal (with-current-buffer log (buffer-string)) log-text))
          (should (process-live-p proc)))
      (delete-process proc)
      (when (buffer-live-p mine)
        (with-current-buffer mine (set-buffer-modified-p nil))
        (kill-buffer mine))
      (unless had-log (kill-buffer log)))))

(ert-deftest dired-filetags-test-fixture-ignores-the-users-dired-hooks ()
  "The user's `dired-mode-hook', such as `dired-omit-mode', does not run in tests."
  (let* ((ran nil)
         (dired-mode-hook (list (lambda () (setq ran t)))))
    (dired-filetags-test--with-dir ("a.txt")
      (dired-filetags-test--dired root)
      (should-not ran))))

(ert-deftest dired-filetags-test-fixture-can-be-instrumented ()
  "Edebug can instrument a test that uses the fixture with a non-empty SPEC."
  (require 'edebug)
  (should (equal (get 'dired-filetags-test--with-dir 'edebug-form-spec) '(sexp body)))
  (with-temp-buffer
    (emacs-lisp-mode)
    (prin1 '(defun dired-filetags-test--instrumented ()
              (dired-filetags-test--with-dir ("a.txt" "sub/") root))
           (current-buffer))
    (goto-char (point-min))
    (let ((edebug-all-defs t))
      (eval-defun nil)))
  (fmakunbound 'dired-filetags-test--instrumented))

;;;; Step 0: scaffolding

(ert-deftest dired-filetags-scaffold-defines-options-and-faces ()
  "Every option is a typed defcustom, every face exists, defaults are right."
  (should (featurep 'dired-filetags))
  (dolist (sym '(dired-filetags-program dired-filetags-display-style
                                        dired-filetags-align-width dired-filetags-tag-colors
                                        dired-filetags-tag-faces dired-filetags-tagtrees-directory
                                        dired-filetags-tagtrees-depth dired-filetags-tagtrees-untagged
                                        dired-filetags-tagtrees-link-limit))
    (should (custom-variable-p sym))
    (should (get sym 'custom-type)))
  (dolist (face '(dired-filetags-tag dired-filetags-separator
                                     dired-filetags-added dired-filetags-removed))
    (should (facep face)))
  (should (= (length dired-filetags-tag-colors) 12))
  (should (equal (car dired-filetags-tag-colors) "#4D0000"))
  (should-not (string-search ".filetags_tagfilter" dired-filetags-tagtrees-directory)))

;;;; Step 1: name model

(defconst dired-filetags-test--reference-names
  '(("Report -- work urgent.pdf" (6 21 25) ("Report" ("work" "urgent") "pdf") "Report.pdf")
    ("foo -- a.PDF.LNK" (3 8 12) ("foo" ("a") "PDF") "foo.PDF.lnk")
    ("foo -- a b" (3 10 10) ("foo" ("a" "b") nil) "foo")
    ("x -- y" (1 6 6) ("x" ("y") nil) "x")
    ("multi -- x -- y.txt" (5 15 19) ("multi" ("x" "--" "y") "txt") "multi.txt")
    ("foo -- .txt" (3 11 11) ("foo" (".txt") nil) "foo")
    ("c -- ...txt" (1 7 11) ("c" ("..") "txt") "c.txt")
    ("foo.txt" nil nil "foo.txt")
    (".hidden" nil nil ".hidden")
    (" -- h.hidden" nil nil " -- h.hidden"))
  "Spec §4.1 reference rows: (NAME SPLIT PARSE UNTAGGED-NAME).")

(ert-deftest dired-filetags-parse-matches-cli-vectors ()
  "The parser agrees with filetags on every recorded vector."
  (dolist (v dired-filetags-test--vectors)
    (pcase-let ((`(,name ,base ,tags ,ext . ,_) v))
      (should (equal (list name (dired-filetags-parse name))
                     (list name (and base (list base tags ext))))))))

(ert-deftest dired-filetags-parse-split-returns-offsets ()
  "`dired-filetags--split' and the parser return the reference results."
  (pcase-dolist (`(,name ,split ,parse ,_) dired-filetags-test--reference-names)
    (should (equal (list name (dired-filetags--split name)) (list name split)))
    (should (equal (list name (dired-filetags-parse name)) (list name parse))))
  (should-not (dired-filetags--split "a -- b\nc"))
  (should-not (dired-filetags-parse "a -- b\nc")))

(ert-deftest dired-filetags-parse-word-char-matches-python ()
  "The extension alphabet is Python 3's \\w."
  (dolist (char '(?½ ?² ?Ⅻ ?_ ?a ?日))
    (should (dired-filetags--word-char-p char)))
  (dolist (char '(?- ?. ?~ ?# #x301))
    (should-not (dired-filetags--word-char-p char))))

(ert-deftest dired-filetags-parse-untagged-name ()
  "The untagged name drops the tag segment and downcases a trailing .lnk."
  (pcase-dolist (`(,name ,_ ,_ ,untagged) dired-filetags-test--reference-names)
    (should (equal (list name (dired-filetags--untagged-name name)) (list name untagged))))
  (should (equal (dired-filetags--untagged-name "foo.LNK") "foo.lnk"))
  (should (equal (dired-filetags--untagged-name "a.b.c.tar -- NEW.gz") "a.b.c.tar.gz")))

(ert-deftest dired-filetags-parse-tags-accept-paths ()
  "`dired-filetags-tags' reads the basename; clean tags drop \"\" and \"--\"."
  (should (equal (dired-filetags-tags "/x/y/a -- b c.txt") '("b" "c")))
  (should-not (dired-filetags-tags "/x/y/plain.txt"))
  (should (equal (dired-filetags--clean-tags "m -- x --  y.txt") '("x" "y"))))

;;;; Step 2: validation, tokens, verifier

(ert-deftest dired-filetags-verify-refuses-cli-quirks-for-add ()
  "Adding NEW is accepted exactly for the vectors the CLI retags cleanly."
  (let ((accepted 0))
    (pcase-dolist (`(,name ,_ ,_ ,_ ,after-add . ,_) dired-filetags-test--vectors)
      (let ((reason (dired-filetags--verify name after-add '("NEW") nil)))
        (should (equal (list name (and reason t))
                       (list name (and (member name dired-filetags-test--refused-adds) t))))
        (unless reason (cl-incf accepted))))
    (should (= accepted 32))))

(ert-deftest dired-filetags-verify-refuses-cli-quirks-for-remove ()
  "Removing a tag is accepted exactly for the vectors the CLI retags cleanly."
  (let ((accepted 0) (total 0))
    (pcase-dolist (`(,name ,_ ,_ ,_ ,_ ,removed ,after-remove) dired-filetags-test--vectors)
      (when removed
        (cl-incf total)
        (let ((reason (dired-filetags--verify name after-remove nil (list removed))))
          (should (equal (list name (and reason t))
                         (list name (and (member name dired-filetags-test--refused-removes) t))))
          (unless reason (cl-incf accepted)))))
    (should (= total 38))
    (should (= accepted 30))))

(ert-deftest dired-filetags-verify-accepts-exclusive-group-swaps ()
  "A tag dropped by an exclusive group is fine; a requested tag must stay."
  (should-not (dired-filetags--verify "baz -- gamma final.pdf" "baz -- gamma draft.pdf"
                                      '("draft") nil))
  (should (string-match-p "would not keep tag \"c\""
                          (dired-filetags--verify "x -- a.txt" "x -- b.txt" '("b" "c") nil))))

(ert-deftest dired-filetags-verify-refuses-unexpected-and-kept-tags ()
  "Unrequested new tags, kept removals and no-op results are refused."
  (should (string-match-p "unexpected"
                          (dired-filetags--verify "a -- x.txt" "a -- x y z.txt" '("y") nil)))
  (should (string-match-p "would not remove"
                          (dired-filetags--verify "a -- x y.txt" "a -- x y.txt" nil '("y"))))
  (should (dired-filetags--verify "a.txt" "a.txt" '("x") nil)))

(ert-deftest dired-filetags-check-tags-rejects-unsafe-tags ()
  "Tags that filetags would misread are refused before anything runs."
  (dolist (tags '(nil ("a b") ("a/b") ("a\tb") ("") ("-x") ("-") (".") ("..") ("--")
                      ("cuttimes")))
    (should-error (dired-filetags--check-tags tags) :type 'user-error))
  (let ((tags (list "c++" "日本語" "v1.2" "C#")))
    (should (equal (dired-filetags--check-tags tags) '("c++" "日本語" "v1.2" "C#"))))
  (dolist (tags '(("") ("a/b") ("cuttimes")))
    (should-error (dired-filetags--check-tags tags t) :type 'user-error))
  (should (equal (dired-filetags--check-tags '("-x" "." "--") t) '("-x" "." "--")))
  (should (equal (cadr (should-error (dired-filetags--check-tags nil) :type 'user-error))
                 "No tags given"))
  (should (equal (cadr (should-error (dired-filetags--check-tags '("a b"))
                                     :type 'user-error))
                 "Tags cannot contain spaces, control characters or \"/\": \"a b\""))
  (should (equal (cadr (should-error (dired-filetags--check-tags '("ok" "-x"))
                                     :type 'user-error))
                 "Filetags reads a leading \"-\" as removal: \"-x\""))
  (should (equal (cadr (should-error (dired-filetags--check-tags '("cuttimes"))
                                     :type 'user-error))
                 "Filetags reserves the tag \"cuttimes\""))
  (should (equal (cadr (should-error (dired-filetags--check-tags '("cuttimes") t)
                                     :type 'user-error))
                 "Filetags cannot remove a literal \"cuttimes\" tag; rename the file with R")))

(ert-deftest dired-filetags-tokens-put-removals-first ()
  "Removals come first, each with a leading dash."
  (should (equal (dired-filetags--tokens '("a" "b") '("c")) "-c a b"))
  (should (equal (dired-filetags--tokens nil '("-x")) "--x")))

;;;; Step 3: CLI runner, vocabulary, stand-in oracle

(defun dired-filetags-test--scratch-empty-p ()
  "Return non-nil if the variable `temporary-file-directory' has no entries."
  (null (directory-files temporary-file-directory nil
                         directory-files-no-dot-files-regexp)))

(defun dired-filetags-test--snapshot (dir)
  "Return the (NAME . CONTENTS) of every entry of DIR."
  (mapcar (lambda (name)
            (cons name (with-temp-buffer
                         (let ((file-name-handler-alist nil))
                           (insert-file-contents-literally (expand-file-name name dir)))
                         (buffer-string))))
          (dired-filetags-test--names dir)))

(ert-deftest dired-filetags-oracle-matches-cli-vectors ()
  "The stand-in oracle reproduces every recorded CLI rename."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ()
    (should (equal (dired-filetags--new-names (mapcar #'car dired-filetags-test--vectors)
                                              "NEW" nil)
                   (mapcar (lambda (v) (nth 4 v)) dired-filetags-test--vectors)))
    (pcase-dolist (`(,tag . ,vectors)
                   (seq-group-by (lambda (v) (nth 5 v))
                                 (seq-filter (lambda (v) (nth 5 v))
                                             dired-filetags-test--vectors)))
      (should (equal (list tag (dired-filetags--new-names (mapcar #'car vectors)
                                                          (concat "-" tag) nil))
                     (list tag (mapcar (lambda (v) (nth 6 v)) vectors)))))
    (should (dired-filetags-test--scratch-empty-p))))

(ert-deftest dired-filetags-oracle-applies-included-vocabulary ()
  "The real vocabulary, including its own includes, governs the stand-ins."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ((".filetags" . "draft final\n#include more.filetags\n")
                                  ("more.filetags" . "red blue\n")
                                  "src/sub/")
    (should (equal (dired-filetags--new-names '("baz -- gamma final.pdf" "x -- red.txt")
                                              "draft blue"
                                              (expand-file-name ".filetags" root))
                   '("baz -- gamma draft blue.pdf" "x -- draft blue.txt")))
    (should (dired-filetags-test--scratch-empty-p))))

(ert-deftest dired-filetags-oracle-blocks-ancestor-vocabulary ()
  "A vocabulary above the scratch directory never leaks into the oracle."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ((".filetags" . "draft final\n"))
    ;; The scratch directory lies below ROOT, whose .filetags would apply.
    (should (string-prefix-p root temporary-file-directory))
    (should (equal (dired-filetags--new-names '("baz -- gamma final.pdf") "draft" nil)
                   '("baz -- gamma final draft.pdf")))))

(ert-deftest dired-filetags-oracle-bypasses-file-name-handlers ()
  "Stand-ins are created without jka-compr, EasyPG or any other handler."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ()
    (let ((file-name-handler-alist
           (list (cons "\\.\\(gz\\|gpg\\)\\'" (lambda (&rest _) (error "Handler called"))))))
      (should (equal (dired-filetags--new-names '("a.tar.gz" "k.gpg") "x" nil)
                     '("a.tar -- x.gz" "k -- x.gpg"))))
    (should (dired-filetags-test--scratch-empty-p))))

(ert-deftest dired-filetags-oracle-never-touches-user-files ()
  "Only names travel to the oracle; the real files are left alone."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir (("src/a.txt" . "A") ("src/b -- x.txt" . "B"))
    (let* ((src (expand-file-name "src/" root))
           (before (dired-filetags-test--snapshot src)))
      (should (equal (dired-filetags--new-names '("a.txt" "b -- x.txt") "y" nil)
                     '("a -- y.txt" "b -- x y.txt")))
      (should (equal (dired-filetags-test--snapshot src) before))
      (should (dired-filetags-test--scratch-empty-p)))))

(ert-deftest dired-filetags-oracle-failures-are-reported-and-cleaned-up ()
  "CLI errors become `user-error's, odd results `error's, and no scratch remains."
  (dired-filetags-test--with-dir ()
    (let ((dired-filetags-program
           (dired-filetags-test--script root "fail1" "echo 'ERROR    boom' >&2; exit 1\n")))
      (should (string-match-p "exit 1.*boom"
                              (cadr (should-error (dired-filetags--new-names '("a.txt") "x" nil)
                                                  :type 'user-error))))
      (should (dired-filetags-test--scratch-empty-p))
      (should (string-search "boom" (dired-filetags-test--log))))
    (dolist (body '("echo 'ERROR    boom0'; exit 0\n"
                    "echo 'Traceback (most recent call last):' >&2; exit 0\n"))
      (let ((dired-filetags-program (dired-filetags-test--script root "fail2" body)))
        (should-error (dired-filetags--new-names '("a.txt") "x" nil) :type 'user-error)
        (should (dired-filetags-test--scratch-empty-p))))
    (let ((dired-filetags-program (dired-filetags-test--script root "noop" "exit 0\n")))
      (should (equal (dired-filetags--new-names '("a.txt") "x" nil) '("a.txt")))
      (should (dired-filetags-test--scratch-empty-p)))
    (let ((dired-filetags-program
           (dired-filetags-test--script
            root "eat" "for f; do case \"$f\" in /*) rm -f \"$f\";; esac; done\n")))
      (should (string-match-p "Filetags left"
                              (cadr (should-error (dired-filetags--new-names '("a.txt") "x" nil)
                                                  :type 'error))))
      (should (dired-filetags-test--scratch-empty-p)))
    (let ((dired-filetags-program "dired-filetags-no-such-program"))
      (should (string-match-p "Cannot find filetags"
                              (cadr (should-error (dired-filetags--new-names '("a.txt") "x" nil)
                                                  :type 'user-error))))
      (should (dired-filetags-test--scratch-empty-p)))))

(ert-deftest dired-filetags-cli-failure-rule ()
  "One rule, shared by the oracle and the TagTrees sentinel, says filetags failed.
A non-zero or signal status fails, and so does a line starting ERROR or
Traceback; the first non-empty line is what the message shows."
  (should-not (dired-filetags--failed-p 0 ""))
  (should-not (dired-filetags--failed-p 0 "  ERROR indented is not a report\n"))
  (should (dired-filetags--failed-p 1 ""))
  (should (dired-filetags--failed-p "Killed" ""))
  (should (dired-filetags--failed-p 0 "note\nERROR    boom\n"))
  (should (dired-filetags--failed-p 0 "Traceback (most recent call last):\n"))
  (should (equal (dired-filetags--first-line "") "no output"))
  (should (equal (dired-filetags--first-line "\n\nERROR    boom\nmore\n") "ERROR    boom"))
  (should (equal (dired-filetags--pretty-dir "/a/b/") "/a/b"))
  (should (equal (dired-filetags--pretty-dir (expand-file-name "~/x/")) "~/x")))

(ert-deftest dired-filetags-oracle-passes-safe-arguments ()
  "The CLI gets -q, one --tags= argument and absolute stand-in names."
  (dired-filetags-test--with-dir ()
    (let* ((args (expand-file-name "args" root))
           (dired-filetags-program
            (dired-filetags-test--script
             root "record"
             (format "{ pwd; printf '%%s\\n' \"$@\"; } > %s\nexit 0\n"
                     (shell-quote-argument args)))))
      (should (equal (dired-filetags--new-names '("-dash.txt") "a -b" nil) '("-dash.txt")))
      (let ((lines (with-temp-buffer
                     (insert-file-contents args)
                     (split-string (buffer-string) "\n" t))))
        (should (= (length lines) 4))
        (should (string-prefix-p (expand-file-name "tmp/" root) (nth 0 lines)))
        (should (string-suffix-p "/0" (nth 0 lines)))
        (should (equal (nth 1 lines) "-q"))
        (should (equal (nth 2 lines) "--tags=a -b"))
        (should (file-name-absolute-p (nth 3 lines)))
        (should (string-suffix-p "/0/-dash.txt" (nth 3 lines)))
        (dolist (bad '("--overwrite" "-s" "-i" "--force-cv"))
          (should-not (member bad lines))))
      (should (dired-filetags-test--scratch-empty-p)))))

(ert-deftest dired-filetags-vocabulary-file-walks-up ()
  "The nearest regular .filetags governs a file; remote files have none."
  (dired-filetags-test--with-dir ((".filetags" . "a\n") "a/b/f.txt" "a/b/.filetags/")
    (let ((file (expand-file-name "a/b/f.txt" root)))
      (should (equal (dired-filetags--vocabulary-file file)
                     (expand-file-name ".filetags" root)))
      (dired-filetags-test--populate root '(("a/.filetags" . "b\n")))
      (should (equal (dired-filetags--vocabulary-file file)
                     (expand-file-name "a/.filetags" root))))
    (with-timeout (5 (ert-fail "Remote vocabulary lookup tried to connect"))
      (should-not (dired-filetags--vocabulary-file "/ssh:nowhere.invalid:/x/f")))
    (should-not (seq-some (lambda (p) (string-prefix-p "*tramp" (process-name p)))
                          (process-list)))))

(ert-deftest dired-filetags-vocabulary-words-skip-comments ()
  "Vocabulary words exclude comments, includes and trailing comments."
  (dired-filetags-test--with-dir
      ((".filetags" . "draft final\n# comment\n#include other\nred  # trailing\n"))
    (should (equal (dired-filetags--vocabulary-words root) '("draft" "final" "red")))
    (should-not (dired-filetags--vocabulary-words "/ssh:nowhere.invalid:/x/"))))

;;;; Step 4: targets, classification, TagTree detection

(ert-deftest dired-filetags-targets-classify-files ()
  "Only regular files, or links to them, can be tagged."
  (dired-filetags-test--with-dir ("f.txt" "d/" (".filetags" . "") ("m/.filetags_tagtrees" . "")
                                  ("m/x/kept.pdf" . "ONLY COPY")
                                  ("l -- x.txt" :symlink "f.txt") ("dangling" :symlink "nowhere"))
    (cl-flet ((classify (name) (dired-filetags--classify (expand-file-name name root))))
      (should-not (classify "f.txt"))
      (should-not (classify "l -- x.txt"))
      (should (string-match-p "directory" (classify "d")))
      (should (string-match-p "control file" (classify ".filetags")))
      (should (string-match-p "control file" (classify "m/.filetags_tagtrees")))
      ;; A real file inside a TagTree would be deleted by the next build.
      (should (string-match-p "inside a TagTree but is not one of its links"
                              (classify "m/x/kept.pdf")))
      ;; On case-insensitive APFS, filetags reads .FILETAGS as the vocabulary.
      (should (string-match-p "control file" (classify ".FILETAGS")))
      (should (string-match-p "control file" (classify "sub/.FileTags_TagTrees")))
      (cl-letf (((symbol-function 'dired-filetags--call)
                 (lambda (&rest _) (ert-fail "filetags must not run"))))
        (should (string-match-p "vocabulary file itself"
                                (cadr (should-error (dired-filetags--new-names
                                                     '("a.txt" ".FILETAGS") "x" nil))))))
      (should (string-match-p "dangling" (classify "dangling")))
      (should (string-match-p "no longer exists" (classify "gone.txt"))))))

(ert-deftest dired-filetags-targets-classify-fifos ()
  "A named pipe exists but is not a regular file, so it cannot be tagged."
  (dired-filetags-test--with-dir ()
    (let ((fifo (expand-file-name "fifo" root)))
      ;; The probe is the pipe itself: some filesystems cannot hold one.
      (skip-unless (and (executable-find "mkfifo")
                        (eql 0 (call-process "mkfifo" nil nil nil fifo))))
      (should (file-exists-p fifo))
      (should (string-match-p "not a regular file" (dired-filetags--classify fifo))))))

(ert-deftest dired-filetags-targets-use-marks-point-or-arg ()
  "Targets follow Dired's convention: marks, else the next ARG files."
  (dired-filetags-test--with-dir ("a.txt" "b.txt" "c.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--goto (f "b.txt"))
      (should (equal (dired-filetags--targets nil) (list (f "b.txt"))))
      (dired-filetags-test--goto (f "a.txt"))
      (should (equal (dired-filetags--targets 2) (list (f "a.txt") (f "b.txt"))))
      (dired-filetags-test--mark-files (list (f "a.txt") (f "c.txt")))
      (should (equal (dired-filetags--targets nil) (list (f "a.txt") (f "c.txt")))))))

(ert-deftest dired-filetags-targets-reject-untaggable-selections ()
  "An empty or untaggable selection fails before anything else happens."
  (dired-filetags-test--with-dir ("d/" "a.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "d" root))
    (should (string-match-p "No taggable files"
                            (cadr (should-error (dired-filetags--targets nil)
                                                :type 'user-error))))
    (goto-char (point-min))
    (should (equal (cadr (should-error (dired-filetags--targets nil) :type 'user-error))
                   "No files specified"))))

(ert-deftest dired-filetags-targets-resolve-tagtree-links ()
  "Inside a TagTree, links are replaced by the files they point to."
  (dired-filetags-test--with-dir ("src/a -- x.txt" ("tree/.filetags_tagtrees" . "") "tree/x/")
    (cl-flet ((f (name) (expand-file-name name root)))
      (make-symbolic-link (f "src/a -- x.txt") (f "tree/x/a -- x.txt"))
      (make-symbolic-link (f "src/gone -- x.txt") (f "tree/x/b -- x.txt"))
      (dired-filetags-test--dired (f "tree/x/"))
      (dired-filetags-test--goto (f "tree/x/a -- x.txt"))
      (should (equal (dired-filetags--targets nil) (list (f "src/a -- x.txt"))))
      (dired-filetags-test--mark-files (list (f "tree/x/a -- x.txt") (f "tree/x/b -- x.txt")))
      (let ((targets (dired-filetags--targets nil)))
        (should (equal targets (list (f "src/a -- x.txt") (f "src/gone -- x.txt"))))
        (should (string-match-p "no longer exists" (dired-filetags--classify (cadr targets)))))
      (dired-unmark-all-marks)
      (dired-filetags-test--mark-files (list (f "tree/x/b -- x.txt")))
      (should (string-match-p "No taggable files"
                              (cadr (should-error (dired-filetags--targets nil)
                                                  :type 'user-error)))))))

(ert-deftest dired-filetags-targets-skip-self-referential-tagtree-links ()
  "A TagTree link to itself, as filetags makes for broken links, is refused alone."
  (dired-filetags-test--with-dir ("src/a -- x.txt" ("tree/.filetags_tagtrees" . "") "tree/x/"
                                  ("tree/x/b -- x.txt" :symlink "b -- x.txt"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (make-symbolic-link (f "src/a -- x.txt") (f "tree/x/a -- x.txt"))
      (dired-filetags-test--dired (f "tree/x/"))
      (dired-filetags-test--mark-files (list (f "tree/x/a -- x.txt") (f "tree/x/b -- x.txt")))
      (let ((targets (dired-filetags--targets nil)))
        (should (equal targets (list (f "src/a -- x.txt") (f "tree/x/b -- x.txt"))))
        (should (string-match-p "dangling" (dired-filetags--classify (cadr targets))))))))

(ert-deftest dired-filetags-tagtree-detection-and-sidecar ()
  "Any marker makes a TagTree; only a marker plus sidecar makes it ours."
  (dired-filetags-test--with-dir (("tree/.filetags_tagtrees" . "")
                                  ("tree/no-tags/.filetags_tagtrees" . "")
                                  "tree/x/" "src/")
    (cl-flet ((f (name) (expand-file-name name root)))
      (should (dired-filetags--inside-tagtree-p (f "tree/x/")))
      (should-not (dired-filetags--inside-tagtree-p (f "src/")))
      (should-not (dired-filetags--tagtree-root (f "tree/x/")))
      (dired-filetags--write-sidecar (f "tree/") '(:source "S"))
      (should (file-exists-p (f "tree.eld")))
      (should (equal (dired-filetags--tagtree-root (f "tree/x/")) (f "tree/")))
      (should (equal (dired-filetags--tagtree-root (f "tree/no-tags/")) (f "tree/")))
      (should (equal (dired-filetags--tagtree-root (f "tree/x")) (f "tree/")))
      (should-not (dired-filetags--tagtree-root (f "src/")))
      (let ((plist (dired-filetags--read-sidecar (f "tree/"))))
        (should (equal (plist-get plist :source) "S"))
        (should (stringp (plist-get plist :time))))
      (should (equal (dired-filetags--sidecar (f "tree/")) (f "tree.eld")))
      (should (equal (dired-filetags--sidecar (f "tree")) (f "tree.eld")))
      ;; A stale :time is replaced, not shadowed by a second entry.
      (dired-filetags--write-sidecar (f "tree/") '(:source "S" :time "old"))
      (let ((plist (dired-filetags--read-sidecar (f "tree/"))))
        (should (= (length plist) 4))
        (should-not (equal (plist-get plist :time) "old")))
      (dired-filetags-test--populate root '(("garbage.eld" . "not-a-plist")))
      (should-not (dired-filetags--read-sidecar (f "garbage/")))
      (should-not (dired-filetags--read-sidecar (f "src/")))
      (with-timeout (5 (ert-fail "Remote TagTree detection tried to connect"))
        (should-not (dired-filetags--inside-tagtree-p "/ssh:nowhere.invalid:/x/"))
        (should-not (dired-filetags--tagtree-root "/ssh:nowhere.invalid:/x/"))))))

;;;; Step 5: planning and preflight

(defmacro dired-filetags-test--with-oracle (spec &rest body)
  "Run BODY with `dired-filetags--new-names' replaced by a stub.
SPEC is (CALLS FN).  FN maps (NAME TOKENS) to the predicted basename.
CALLS is bound around BODY to the list of stub calls, each recorded as
\(NAMES TOKENS VOCABULARY), most recent first."
  (declare (indent 1) (debug ((symbolp form) body)))
  (let ((calls (car spec))
        (fn (make-symbol "fn")))
    `(let ((,calls nil)
           (,fn ,(cadr spec)))
       (cl-letf (((symbol-function 'dired-filetags--new-names)
                  (lambda (names tokens vocabulary)
                    (push (list names tokens vocabulary) ,calls)
                    (mapcar (lambda (name) (funcall ,fn name tokens)) names))))
         ,@body))))

(defun dired-filetags-test--insert-x (name _tokens)
  "Return NAME with \" -- x\" inserted before its extension."
  (concat (file-name-sans-extension name) " -- x."
          (file-name-extension name)))

(ert-deftest dired-filetags-plan-groups-by-vocabulary-and-tokens ()
  "One oracle call per (vocabulary, tokens) group, in input order."
  (dired-filetags-test--with-dir ("a.txt" "b.txt" "c -- x.txt" ("sub/.filetags" . "p q\n")
                                  "sub/d.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--with-oracle (calls #'dired-filetags-test--insert-x)
        (pcase-let ((`(,pairs ,unchanged ,refused)
                     (dired-filetags--plan (mapcar #'f '("a.txt" "b.txt" "c -- x.txt" "sub/d.txt"))
                                           (lambda (_f _t) (cons '("x") nil)))))
          (should (= (length calls) 2))
          (should (member '(("a.txt" "b.txt") "x" nil) calls))
          (should (member (list '("d.txt") "x" (f "sub/.filetags")) calls))
          (should (equal pairs (list (cons (f "a.txt") (f "a -- x.txt"))
                                     (cons (f "b.txt") (f "b -- x.txt"))
                                     (cons (f "sub/d.txt") (f "sub/d -- x.txt")))))
          (should (= unchanged 1))
          (should-not refused))))))

(ert-deftest dired-filetags-plan-sends-only-effective-tokens ()
  "Tags a file already has are never sent; absent tags are never removed."
  (dired-filetags-test--with-dir ("x -- draft other.txt")
    (let ((files (list (expand-file-name "x -- draft other.txt" root))))
      (dired-filetags-test--with-oracle
          (calls (lambda (name tokens)
                   (pcase tokens
                     ("new" "x -- draft other new.txt")
                     ("-other" "x -- draft.txt")
                     (_ name))))
        (pcase-let ((`(,pairs ,unchanged ,_)
                     (dired-filetags--plan files (lambda (_f _t) (cons '("draft" "new") nil)))))
          (should (equal (mapcar #'cadr calls) '("new")))
          (should (= (length pairs) 1))
          (should (= unchanged 0)))
        (setq calls nil)
        (dired-filetags--plan files (lambda (_f _t) (cons nil '("absent" "other"))))
        (should (equal (mapcar #'cadr calls) '("-other")))
        (setq calls nil)
        (pcase-let ((`(,pairs ,unchanged ,refused)
                     (dired-filetags--plan files (lambda (_f _t) (cons '("draft") nil)))))
          (should-not calls)
          (should-not pairs)
          (should-not refused)
          (should (= unchanged 1)))))))

(ert-deftest dired-filetags-plan-refuses-unclean-predictions ()
  "A prediction that changes more than the tags is refused with a reason."
  (dired-filetags-test--with-dir (".hidden" "ok.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--with-oracle
          (calls (lambda (name _tokens)
                   (cdr (assoc name '((".hidden" . " -- x.hidden") ("ok.txt" . "ok -- x.txt"))))))
        (pcase-let ((`(,pairs ,_ ,refused)
                     (dired-filetags--plan (list (f ".hidden") (f "ok.txt"))
                                           (lambda (_f _t) (cons '("x") nil)))))
          (should (equal calls '(((".hidden" "ok.txt") "x" nil))))
          (should (equal pairs (list (cons (f "ok.txt") (f "ok -- x.txt")))))
          (should (= (length refused) 1))
          (should (equal (caar refused) (f ".hidden")))
          (should (string-match-p "more than the tags" (cdar refused))))))))

(ert-deftest dired-filetags-plan-refuses-untaggable-files-without-calling-filetags ()
  "Directories and control files are refused before any CLI call."
  (dired-filetags-test--with-dir ("d/" (".filetags" . ""))
    (dired-filetags-test--forbid-cli
      (pcase-let ((`(,pairs ,unchanged ,refused)
                   (dired-filetags--plan (list (expand-file-name "d" root)
                                               (expand-file-name ".filetags" root))
                                         (lambda (_f _t) (cons '("x") nil)))))
        (should-not pairs)
        (should (= unchanged 0))
        (should (equal (mapcar #'car refused) (list (expand-file-name "d" root)
                                                    (expand-file-name ".filetags" root))))))))

(ert-deftest dired-filetags-plan-chunks-large-groups ()
  "A large group is sent in chunks, and the pairs keep the input order."
  (dired-filetags-test--with-dir ("1.txt" "2.txt" "3.txt" "4.txt" "5.txt")
    (let ((files (mapcar (lambda (n) (expand-file-name (format "%d.txt" n) root))
                         '(1 2 3 4 5)))
          (dired-filetags--chunk-size 2))
      (dired-filetags-test--with-oracle (calls #'dired-filetags-test--insert-x)
        (pcase-let ((`(,pairs ,_ ,refused)
                     (dired-filetags--plan files (lambda (_f _t) (cons '("x") nil)))))
          (should (equal (mapcar #'car (reverse calls))
                         '(("1.txt" "2.txt") ("3.txt" "4.txt") ("5.txt"))))
          (should (equal (mapcar #'car pairs) files))
          (should (equal (mapcar (lambda (p) (file-name-nondirectory (cdr p))) pairs)
                         '("1 -- x.txt" "2 -- x.txt" "3 -- x.txt" "4 -- x.txt" "5 -- x.txt")))
          (should-not refused))))))

(ert-deftest dired-filetags-plan-uses-each-files-vocabulary ()
  "With the real CLI, each directory's vocabulary applies only to its files."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir (("v/.filetags" . "draft final\n") "v/d -- draft.org"
                                  "w/e -- draft.org")
    (cl-flet ((f (name) (expand-file-name name root)))
      (pcase-let ((`(,pairs ,unchanged ,refused)
                   (dired-filetags--plan (list (f "v/d -- draft.org") (f "w/e -- draft.org"))
                                         (lambda (_f _t) (cons '("final") nil)))))
        (should (equal pairs (list (cons (f "v/d -- draft.org") (f "v/d -- final.org"))
                                   (cons (f "w/e -- draft.org") (f "w/e -- draft final.org")))))
        (should (= unchanged 0))
        (should-not refused)
        (should (dired-filetags-test--scratch-empty-p))
        (should (equal (dired-filetags-test--names (f "v/")) '(".filetags" "d -- draft.org")))))))

(ert-deftest dired-filetags-preflight-refuses-existing-targets ()
  "An existing file or dangling link at NEW refuses the pair."
  (dired-filetags-test--with-dir ("a.txt" ("a -- x.txt" . "KEEP") "b.txt"
                                  ("b -- x.txt" :symlink "nowhere"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (pcase-let ((`(,good . ,refused)
                   (dired-filetags--preflight (list (cons (f "a.txt") (f "a -- x.txt"))
                                                    (cons (f "b.txt") (f "b -- x.txt"))))))
        (should-not good)
        (should (equal (mapcar #'car refused) (list (f "a.txt") (f "b.txt"))))
        (should (seq-every-p (lambda (r) (string-match-p "already exists" (cdr r))) refused))
        (should (equal (cdar refused) "a -- x.txt already exists"))))))

(ert-deftest dired-filetags-preflight-refuses-case-variant-targets ()
  "On a case-insensitive filesystem, a case variant of NEW counts as existing."
  (dired-filetags-test--with-dir ("a.txt" "A -- X.txt")
    (skip-unless (dired-filetags-test--case-insensitive-p root))
    (let ((pair (cons (expand-file-name "a.txt" root) (expand-file-name "a -- x.txt" root))))
      (pcase-let ((`(,good . ,refused) (dired-filetags--preflight (list pair))))
        (should-not good)
        (should (string-match-p "already exists" (cdar refused)))))))

(ert-deftest dired-filetags-preflight-accepts-case-variant-targets-where-case-matters ()
  "On a case-sensitive filesystem, a case variant of NEW is another file.
Only case variants within one batch are refused there, by folding."
  (dired-filetags-test--with-dir ("a.txt" "A -- X.txt")
    (skip-unless (not (dired-filetags-test--case-insensitive-p root)))
    (let ((pair (cons (expand-file-name "a.txt" root) (expand-file-name "a -- x.txt" root))))
      (should (equal (dired-filetags--preflight (list pair)) (cons (list pair) nil))))))

(ert-deftest dired-filetags-preflight-refuses-batch-collisions ()
  "Every member of a set of pairs with the same folded NEW is refused."
  (dired-filetags-test--with-dir ("a -- x.txt" "a -- y.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (pcase-let ((`(,good . ,refused)
                   (dired-filetags--preflight (list (cons (f "a -- x.txt") (f "a.txt"))
                                                    (cons (f "a -- y.txt") (f "a.txt"))))))
        (should-not good)
        (should (= (length refused) 2))
        (should (seq-every-p (lambda (r) (string-match-p "another selected file" (cdr r)))
                             refused))))
    ;; Folding also catches case and normalization variants.
    (cl-flet ((f (name) (expand-file-name name root)))
      (pcase-let ((`(,good . ,refused)
                   (dired-filetags--preflight
                    (list (cons (f "a -- x.txt") (f "b -- café.txt"))
                          (cons (f "a -- y.txt") (f "B -- café.txt"))))))
        (should-not good)
        (should (= (length refused) 2))))))

(ert-deftest dired-filetags-preflight-refuses-visited-targets ()
  "A buffer already visiting NEW refuses the pair."
  (dired-filetags-test--with-dir ("a.txt")
    (let ((new (expand-file-name "a -- x.txt" root)))
      (find-file-noselect new)
      (pcase-let ((`(,good . ,refused)
                   (dired-filetags--preflight (list (cons (expand-file-name "a.txt" root) new)))))
        (should-not good)
        (should (string-match-p "a buffer already visits" (cdar refused)))))))

(ert-deftest dired-filetags-preflight-accepts-clean-pairs ()
  "A pair with a free, unvisited NEW passes."
  (dired-filetags-test--with-dir ("a.txt")
    (let ((pair (cons (expand-file-name "a.txt" root) (expand-file-name "a -- x.txt" root))))
      (should (equal (dired-filetags--preflight (list pair)) (cons (list pair) nil))))))

;;;; Step 6: execution, refresh, report and the tagging functions

(defun dired-filetags-test--contents (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer
    (let ((file-name-handler-alist nil))
      (insert-file-contents-literally file))
    (buffer-string)))

(defun dired-filetags-test--listing (root)
  "Return the sorted entries of ROOT, without the scratch directory tmp/."
  (remove "tmp" (dired-filetags-test--names root)))

(defmacro dired-filetags-test--with-git (&rest body)
  "Run BODY with git isolated from the user's and the system's configuration.
The user's global configuration signs commits, which must not happen here.
Every inherited GIT_ variable is dropped too: a git hook that runs the suite
exports GIT_INDEX_FILE, which would point the test repositories at the
index of the commit being made."
  (declare (indent 0) (debug t))
  `(let ((process-environment
          (append '("GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1")
                  (seq-remove (lambda (var) (string-prefix-p "GIT_" var))
                              process-environment))))
     ,@body))

(defun dired-filetags-test--git-init (root &rest files)
  "Make ROOT a git repository with FILES committed."
  (let ((default-directory root))
    (dolist (args `(("init" "-q") ("config" "user.email" "t@example.com")
                    ("config" "user.name" "T") ("add" ,@files) ("commit" "-qm" "init")))
      (should (equal (cons args (apply #'call-process "git" nil nil nil args))
                     (cons args 0))))))

(defun dired-filetags-test--git-status (root)
  "Return the lines of `git status --porcelain' in ROOT."
  (let ((default-directory root))
    (with-temp-buffer
      (call-process "git" nil t nil "status" "--porcelain")
      (split-string (buffer-string) "\n" t))))

(ert-deftest dired-filetags-retag-add-keeps-marks-and-point ()
  "Adding tags keeps every mark and leaves point on its file."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("a.txt" "b -- x.txt" "c.txt" "d.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--mark-files (list (f "a.txt") (f "b -- x.txt")))
      (dired-filetags-test--mark-files (list (f "d.txt")) ?D)
      (dired-filetags-test--goto (f "c.txt"))
      (let ((done (dired-filetags-add '("new"))))
        (should (equal (dired-filetags-test--listing root)
                       '("a -- new.txt" "b -- x new.txt" "c.txt" "d.txt")))
        (should (equal (dired-filetags-test--marks)
                       '(("a -- new.txt" . ?*) ("b -- x new.txt" . ?*) ("d.txt" . ?D))))
        (should (equal (dired-get-filename 'no-dir t) "c.txt"))
        (should (equal done (list (cons (f "a.txt") (f "a -- new.txt"))
                                  (cons (f "b -- x.txt") (f "b -- x new.txt")))))
        (should (string-match-p "^Retagged 2 files: \\+new"
                                (dired-filetags-test--last-message)))
        (should (dired-filetags-test--scratch-empty-p))))))

(ert-deftest dired-filetags-retag-point-follows-renamed-file ()
  "Point stays on the file it was on, under its new name."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("a.txt" "b.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "a.txt" root))
    (dired-filetags-add '("x"))
    (should (equal (dired-get-filename 'no-dir t) "a -- x.txt"))))

(ert-deftest dired-filetags-retag-remove-drops-separator ()
  "Removing tags keeps the rest; removing the last one drops \" -- \"."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("b -- x y.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "b -- x y.txt" root))
    (dired-filetags-remove '("x"))
    (should (equal (dired-filetags-test--listing root) '("b -- y.txt")))
    (should (equal (dired-get-filename 'no-dir t) "b -- y.txt"))
    (dired-filetags-remove '("y"))
    (should (equal (dired-filetags-test--listing root) '("b.txt")))
    (should (string-match-p "^Retagged 1 file: -y$" (dired-filetags-test--last-message)))))

(ert-deftest dired-filetags-retag-applies-exclusive-groups ()
  "A tag in an exclusive group replaces its group mate, and the message says so."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ((".filetags" . "draft final\n") "d -- draft.org")
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "d -- draft.org" root))
    (dired-filetags-add '("final"))
    (should (equal (dired-filetags-test--listing root) '(".filetags" "d -- final.org")))
    (let ((msg (dired-filetags-test--last-message)))
      (should (string-match-p "\\+final" msg))
      (should (string-match-p "-draft" msg)))))

(ert-deftest dired-filetags-retag-unchanged-files-are-left-alone ()
  "A file that already has the tag is not sent to filetags at all."
  (dired-filetags-test--with-dir ("a -- x.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "a -- x.txt" root))
    (dired-filetags-test--forbid-cli
      (should-not (dired-filetags-add '("x")))
      (should (equal (dired-filetags-test--last-message) "No file names change"))
      (should-not (dired-filetags-remove '("y"))))
    (should (equal (dired-filetags-test--listing root) '("a -- x.txt")))
    ;; *Messages* folds the repeated message into "... [2 times]".
    (should (string-match-p "\\`No file names change" (dired-filetags-test--last-message)))))

(ert-deftest dired-filetags-retag-skips-quirky-names-and-logs-reasons ()
  "Names that filetags would garble are skipped, and the reasons are logged."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir (".gitignore" "v1.2 notes -- foo" "ok.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--mark-files (list (f ".gitignore") (f "v1.2 notes -- foo") (f "ok.txt")))
      (should (equal (dired-filetags-add '("x")) (list (cons (f "ok.txt") (f "ok -- x.txt")))))
      (should (equal (dired-filetags-test--listing root)
                     '(".gitignore" "ok -- x.txt" "v1.2 notes -- foo")))
      (let ((log (dired-filetags-test--log)))
        (should (string-search "skipped .gitignore" log))
        (should (string-search "skipped v1.2 notes -- foo" log)))
      (should (string-match-p "Retagged 1 of 3 files: \\+x; 2 skipped (type \\? for details)"
                              (dired-filetags-test--last-message))))))

(ert-deftest dired-filetags-retag-never-overwrites ()
  "An existing file at the new name refuses the retag, and is kept intact."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("a.txt" ("a -- x.txt" . "KEEP"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--goto (f "a.txt"))
      (should (equal (cadr (should-error (dired-filetags-add '("x")) :type 'user-error))
                     "Cannot retag a.txt: a -- x.txt already exists"))
      (should (equal (dired-filetags-test--listing root) '("a -- x.txt" "a.txt")))
      (should (equal (dired-filetags-test--contents (f "a -- x.txt")) "KEEP")))))

(ert-deftest dired-filetags-retag-all-refused-is-user-error ()
  "When every file is refused, nothing is renamed and a `user-error' says so."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("a -- x.txt" "a -- y.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--mark-files (list (f "a -- x.txt") (f "a -- y.txt")))
      (should (string-match-p "Cannot retag any of the 2 files"
                              (cadr (should-error (dired-filetags-remove '("x" "y"))
                                                  :type 'user-error))))
      (should (equal (dired-filetags-test--listing root) '("a -- x.txt" "a -- y.txt")))
      (should (string-search "another selected file would also become a.txt"
                             (dired-filetags-test--log))))))

(ert-deftest dired-filetags-retag-visiting-buffers-follow ()
  "A buffer visiting a retagged file follows it and stays modified."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir (("a.txt" . "old"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (let* ((create-lockfiles nil)
             (buf (find-file-noselect (f "a.txt"))))
        (with-current-buffer buf (goto-char (point-max)) (insert "edit"))
        (dired-filetags-test--dired root)
        (dired-filetags-test--goto (f "a.txt"))
        (dired-filetags-add '("x"))
        (should (equal (buffer-file-name buf) (f "a -- x.txt")))
        (should (buffer-modified-p buf))
        (should (equal (dired-filetags-test--contents (f "a -- x.txt")) "old"))))))

(ert-deftest dired-filetags-retag-updates-subdirs-and-other-buffers ()
  "Inserted subdirectories and other Dired buffers show the new name."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("top.txt" "sub/f.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (let* ((main (dired-filetags-test--dired root))
             (other (progn (dired-insert-subdir (f "sub/")) (dired-noselect (f "sub/")))))
        (should-not (eq main other))
        (set-buffer main)
        (dired-filetags-test--mark-files (list (f "sub/f.txt")))
        (dired-filetags-add '("x"))
        (dolist (buf (list main other))
          (with-current-buffer buf
            (should (dired-goto-file (f "sub/f -- x.txt")))
            (should-not (dired-goto-file (f "sub/f.txt")))))
        (with-current-buffer main
          (should (equal (assoc "f -- x.txt" (dired-filetags-test--marks))
                         '("f -- x.txt" . ?*))))))))

(ert-deftest dired-filetags-retag-continues-after-plain-errors ()
  "A rename that signals a plain `error' fails alone; the batch goes on."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("bad.txt" "good.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--mark-files (list (f "bad.txt") (f "good.txt")))
      (let ((orig (symbol-function 'rename-file)))
        (cl-letf (((symbol-function 'rename-file)
                   (lambda (file new &optional ok)
                     (if (string-match-p "bad" (file-name-nondirectory file))
                         (error "Boom")
                       (funcall orig file new ok)))))
          (should (equal (dired-filetags-add '("x"))
                         (list (cons (f "good.txt") (f "good -- x.txt"))))))
        (should (file-exists-p (f "bad.txt")))
        (should (string-search "Boom" (dired-filetags-test--log)))
        (should (string-match-p "Retagged 1 of 2 files: \\+x; 1 failed"
                                (dired-filetags-test--last-message)))))))

(ert-deftest dired-filetags-retag-renames-through-vc ()
  "Registered files are renamed through VC, unregistered ones plainly."
  (skip-unless (executable-find "filetags"))
  (skip-unless (executable-find "git"))
  (dired-filetags-test--with-dir ("t.txt" "u.txt")
    (dired-filetags-test--with-git
      (dired-filetags-test--git-init root "t.txt")
      (cl-flet ((f (name) (expand-file-name name root)))
        (let ((dired-vc-rename-file t))
          (dired-filetags-test--dired root)
          (dired-filetags-test--mark-files (list (f "t.txt") (f "u.txt")))
          (should (= (length (dired-filetags-add '("x"))) 2)))
        (should (seq-some (lambda (line) (and (string-prefix-p "R " line)
                                              (string-search "t -- x.txt" line)))
                          (dired-filetags-test--git-status root)))
        (should (file-exists-p (f "u -- x.txt")))))))

(ert-deftest dired-filetags-retag-vc-modified-buffer-fails-only-that-file ()
  "VC's refusal to move a modified file fails that file alone."
  (skip-unless (executable-find "filetags"))
  (skip-unless (executable-find "git"))
  (dired-filetags-test--with-dir ("t.txt" ("m.txt" . "M"))
    (dired-filetags-test--with-git
      (dired-filetags-test--git-init root "t.txt" "m.txt")
      (cl-flet ((f (name) (expand-file-name name root)))
        (let* ((create-lockfiles nil)
               (dired-vc-rename-file t)
               (buf (find-file-noselect (f "m.txt"))))
          (with-current-buffer buf (insert "edit"))
          (dired-filetags-test--dired root)
          (dired-filetags-test--mark-files (list (f "m.txt") (f "t.txt")))
          (should (equal (dired-filetags-add '("x"))
                         (list (cons (f "t.txt") (f "t -- x.txt")))))
          (should (file-exists-p (f "t -- x.txt")))
          (should (file-exists-p (f "m.txt")))
          (should (equal (buffer-file-name buf) (f "m.txt")))
          (should (string-search "Please save files before moving them"
                                 (dired-filetags-test--log)))
          (should (string-match-p "1 failed" (dired-filetags-test--last-message))))))))

(ert-deftest dired-filetags-retag-refreshes-stale-lines ()
  "A Dired buffer still listing a renamed file is reverted; others are not."
  (dired-filetags-test--with-dir ("a.txt" "k.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (rename-file (f "a.txt") (f "b.txt"))
      (dired-filetags--refresh-stale-buffers (list (f "a.txt")))
      (should (dired-goto-file (f "b.txt")))
      (should-not (dired-goto-file (f "a.txt")))
      ;; A buffer that no longer lists any of the names is left alone,
      ;; so a `k'-killed line stays killed.
      (dired-filetags-test--goto (f "k.txt"))
      (dired-kill-line)
      (should-not (dired-goto-file (f "k.txt")))
      (dired-filetags--refresh-stale-buffers (list (f "a.txt") (f "nothing.txt")))
      (should-not (dired-goto-file (f "k.txt")))
      (should (dired-goto-file (f "b.txt"))))))

(ert-deftest dired-filetags-retag-refreshes-dired-subtree-lines ()
  "Renamed dired-subtree lines are refreshed."
  (skip-unless (executable-find "filetags"))
  (skip-unless (require 'dired-subtree nil t))
  (dired-filetags-test--with-dir ("top.txt" "sub/deep.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "sub" root))
    (dired-subtree-insert)
    (goto-char (point-min))
    (search-forward "deep.txt")
    (dired-filetags-add '("x"))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-search "deep -- x.txt" text))
      (should-not (string-search "deep.txt" text)))
    (should (file-exists-p (expand-file-name "sub/deep -- x.txt" root)))))

(ert-deftest dired-filetags-retag-leaves-no-scratch ()
  "No scratch directory survives a success, a refusal or a CLI failure."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("a.txt" ("a -- x.txt" . "KEEP") "b.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--goto (f "b.txt"))
      (should (dired-filetags-add '("y")))
      (should (dired-filetags-test--scratch-empty-p))
      (dired-filetags-test--goto (f "a.txt"))
      (should-error (dired-filetags-add '("x")) :type 'user-error)
      (should (dired-filetags-test--scratch-empty-p))
      (let ((dired-filetags-program
             (dired-filetags-test--script root "fail" "echo 'ERROR    boom' >&2; exit 1\n")))
        (dired-filetags-test--goto (f "b -- y.txt"))
        (should-error (dired-filetags-add '("z")) :type 'user-error))
      (should (file-exists-p (f "b -- y.txt")))
      (should (dired-filetags-test--scratch-empty-p)))))

(ert-deftest dired-filetags-retag-requires-a-dired-buffer ()
  "Outside Dired, and in wdired, nothing is planned or renamed."
  (dired-filetags-test--with-dir ("a.txt")
    (let ((file (expand-file-name "a.txt" root)))
      (dired-filetags-test--forbid-cli
        (with-temp-buffer
          (should-error (dired-filetags-add '("x") (list file)) :type 'user-error)
          (should-error (dired-filetags-add-remove '("x") (list file)) :type 'user-error))
        (dired-filetags-test--dired root)
        (dired-filetags-test--goto file)
        (wdired-change-to-wdired-mode)
        (unwind-protect
            (dolist (fn '(dired-filetags-add dired-filetags-remove dired-filetags-add-remove))
              (should-error (funcall fn '("x")) :type 'user-error))
          (wdired-abort-changes)))
      (should (equal (dired-filetags-test--listing root) '("a.txt"))))))

(ert-deftest dired-filetags-report-formats-changes ()
  "The summary counts files and lists the real tag changes in colour."
  (let ((pairs (list (cons "/d/a -- draft.org" "/d/a -- paid.org")
                     (cons "/d/b.txt" "/d/b -- paid.txt"))))
    (let ((s (dired-filetags--report pairs 1 0 0 nil)))
      (should (equal s "Retagged 2 files: +paid -draft; 1 unchanged"))
      (should (eq (get-text-property (string-search "+paid" s) 'face s) 'dired-filetags-added))
      (should (eq (get-text-property (string-search "-draft" s) 'face s) 'dired-filetags-removed))
      (should (equal (dired-filetags-test--last-message) s)))
    (should (equal (dired-filetags--report pairs 0 1 1 nil)
                   "Retagged 2 of 4 files: +paid -draft; 1 skipped, 1 failed (type ? for details)"))
    (should (equal (dired-filetags--report pairs 1 1 0 nil)
                   (concat "Retagged 2 of 3 files: +paid -draft; 1 unchanged, 1 skipped"
                           " (type ? for details)")))
    (let ((s (dired-filetags--report (list (cons "/d/c.txt" "/d/c -- w.txt")) 0 0 0 t)))
      (should (equal s "Retagged 1 file: +w; rebuilding TagTrees..."))
      (should (string-suffix-p "; rebuilding TagTrees..." s))
      (should (string-search "1 file" s)))
    ;; A rebuild that could not start reports why.
    (should (equal (dired-filetags--report (list (cons "/d/c.txt" "/d/c -- w.txt")) 0 0 0
                                           "Busy; TagTrees not rebuilt")
                   "Retagged 1 file: +w; Busy; TagTrees not rebuilt"))
    ;; Additions come first, then removals, each in first-seen order.
    (should (equal (dired-filetags--report
                    (list (cons "/d/a -- p q.txt" "/d/a -- r.txt")
                          (cons "/d/b -- q.txt" "/d/b -- s.txt"))
                    0 0 0 nil)
                   "Retagged 2 files: +r +s -p -q"))
    (should (equal (dired-filetags--report nil 0 0 1 nil)
                   "Retagged 0 of 1 file; 1 failed (type ? for details)"))))

(ert-deftest dired-filetags-add-remove-is-uniform ()
  "On a mixed selection, add-remove first adds the tag where it is missing.
Once every file has it, the same call removes it from all of them."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("a -- t u.txt" "b.txt" "c -- t.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--mark-files (list (f "a -- t u.txt") (f "b.txt") (f "c -- t.txt")))
      (should (equal (dired-filetags-add-remove '("t"))
                     (list (cons (f "b.txt") (f "b -- t.txt")))))
      (should (equal (dired-filetags-test--listing root)
                     '("a -- t u.txt" "b -- t.txt" "c -- t.txt")))
      (should (equal (dired-filetags-test--last-message) "Retagged 1 file: +t; 2 unchanged"))
      (should (equal (dired-filetags-test--marks)
                     '(("a -- t u.txt" . ?*) ("b -- t.txt" . ?*) ("c -- t.txt" . ?*))))
      (should (length= (dired-filetags-add-remove '("t")) 3))
      (should (equal (dired-filetags-test--listing root) '("a -- u.txt" "b.txt" "c.txt")))
      (should (equal (dired-filetags-test--last-message) "Retagged 3 files: -t"))
      (should (equal (dired-filetags-test--marks)
                     '(("a -- u.txt" . ?*) ("b.txt" . ?*) ("c.txt" . ?*)))))))

(ert-deftest dired-filetags-add-remove-single-file-adds-then-removes ()
  "On one file, add-remove adds a tag it lacks and removes a tag it has."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("a -- x.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--goto (f "a -- x.txt"))
      (should (equal (dired-filetags-add-remove '("y"))
                     (list (cons (f "a -- x.txt") (f "a -- x y.txt")))))
      (should (equal (dired-filetags-test--last-message) "Retagged 1 file: +y"))
      (dired-filetags-test--goto (f "a -- x y.txt"))
      (should (equal (dired-filetags-add-remove '("y"))
                     (list (cons (f "a -- x y.txt") (f "a -- x.txt")))))
      (should (equal (dired-filetags-test--last-message) "Retagged 1 file: -y"))
      ;; One call adds the tags the file lacks and removes the ones it has.
      (dired-filetags-test--goto (f "a -- x.txt"))
      (dired-filetags-add-remove '("x" "z"))
      (should (equal (dired-filetags-test--listing root) '("a -- z.txt")))
      (should (equal (dired-filetags-test--last-message) "Retagged 1 file: +z -x")))))

(ert-deftest dired-filetags-add-validates-before-planning ()
  "Bad tags are refused before any target is planned."
  (dired-filetags-test--with-dir ("a.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "a.txt" root))
    (dired-filetags-test--forbid-cli
      (should-error (dired-filetags-add '("a/b")) :type 'user-error)
      (should-error (dired-filetags-add-remove '("-x")) :type 'user-error)
      (should-error (dired-filetags-remove '("cuttimes")) :type 'user-error)
      (should-error (dired-filetags-add nil) :type 'user-error)
      ;; Removal accepts "-x", which a.txt lacks, so nothing changes.
      (should-not (dired-filetags-remove '("-x"))))))

(ert-deftest dired-filetags-add-remove-checks-removals-as-removals ()
  "A tag every target has is checked as a removal, any other as an addition.
So add-remove removes a \"-foo\" or \".FILETAGS\" tag that every target
has, as `dired-filetags-remove' does, and still refuses to add one."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("a -- -foo.txt" "b -- -foo x.txt" "c.txt"
                                  "y -- .FILETAGS q.txt" "z -- cuttimes.txt")
    (cl-flet ((f (name) (expand-file-name name root))
              (msg (err) (cadr err)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--forbid-cli
        ;; c.txt lacks "-foo", so it is an addition, refused before planning.
        (dired-filetags-test--mark-files (list (f "a -- -foo.txt") (f "c.txt")))
        (should (string-match-p "leading \"-\" as removal"
                                (msg (should-error (dired-filetags-add-remove '("-foo"))
                                                   :type 'user-error))))
        (dired-unmark-all-marks)
        ;; Each direction keeps its own refusal for "cuttimes".
        (dired-filetags-test--goto (f "c.txt"))
        (should (string-match-p "reserves the tag \"cuttimes\""
                                (msg (should-error (dired-filetags-add-remove '("cuttimes"))
                                                   :type 'user-error))))
        (dired-filetags-test--goto (f "z -- cuttimes.txt"))
        (should (string-match-p "cannot remove a literal \"cuttimes\""
                                (msg (should-error (dired-filetags-add-remove '("cuttimes"))
                                                   :type 'user-error))))
        (dired-filetags-test--goto (f "c.txt"))
        (should (string-match-p "reserves the tag \".FILETAGS\""
                                (msg (should-error (dired-filetags-add-remove '(".FILETAGS"))
                                                   :type 'user-error)))))
      (should (equal (dired-filetags-test--listing root)
                     '("a -- -foo.txt" "b -- -foo x.txt" "c.txt"
                       "y -- .FILETAGS q.txt" "z -- cuttimes.txt")))
      ;; Every target has "-foo", so add-remove removes it from both.
      (dired-filetags-test--mark-files (list (f "a -- -foo.txt") (f "b -- -foo x.txt")))
      (should (equal (dired-filetags-add-remove '("-foo"))
                     (list (cons (f "a -- -foo.txt") (f "a.txt"))
                           (cons (f "b -- -foo x.txt") (f "b -- x.txt")))))
      (should (equal (dired-filetags-test--last-message) "Retagged 2 files: --foo"))
      (dired-unmark-all-marks)
      (dired-filetags-test--goto (f "y -- .FILETAGS q.txt"))
      (dired-filetags-add-remove '(".FILETAGS"))
      (should (equal (dired-filetags-test--listing root)
                     '("a.txt" "b -- x.txt" "c.txt" "y -- q.txt" "z -- cuttimes.txt"))))))

(ert-deftest dired-filetags-add-remove-exclusive-group-displaces-mates ()
  "Adding a tag from an exclusive group replaces its mates, which never return.
A second call on one file removes the tag without restoring the mate it
displaced, and naming two mates on a mixed selection swaps them."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ((".filetags" . "draft final\n")
                                  "doc -- draft.txt" "a -- draft.txt" "b -- final.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--goto (f "doc -- draft.txt"))
      (dired-filetags-add-remove '("final"))
      (should (member "doc -- final.txt" (dired-filetags-test--listing root)))
      (should (equal (dired-filetags-test--last-message) "Retagged 1 file: +final -draft"))
      (dired-filetags-test--goto (f "doc -- final.txt"))
      (dired-filetags-add-remove '("final"))
      (should (member "doc.txt" (dired-filetags-test--listing root)))
      ;; Neither mate is on both files, so both are additions, and each
      ;; file trades the mate it had for the other.
      (dired-filetags-test--mark-files (list (f "a -- draft.txt") (f "b -- final.txt")))
      (dired-filetags-add-remove '("draft" "final"))
      (should (equal (dired-filetags-test--listing root)
                     '(".filetags" "a -- final.txt" "b -- draft.txt" "doc.txt"))))))

;;;; Step 7: reading tags, candidates and interactive specs

(defmacro dired-filetags-test--with-crm (spec &rest body)
  "Run BODY with `completing-read-multiple' replaced by a recording stub.
SPEC is (CALLS RESULT).  Each call is pushed onto CALLS as a plist with
:prompt, :table, :require-match and :separator (`crm-separator' at the
time of the call), and returns RESULT."
  (declare (indent 1) (debug ((symbolp form) body)))
  `(let ((,(car spec) nil))
     (cl-letf (((symbol-function 'completing-read-multiple)
                (lambda (prompt table &optional _pred require-match &rest _)
                  (push (list :prompt prompt :table table :require-match require-match
                              :separator crm-separator)
                        ,(car spec))
                  (copy-sequence ,(cadr spec)))))
       ,@body)))

(ert-deftest dired-filetags-read-binds-crm-separator-and-dedupes ()
  "Tags are read with the package's separator, and duplicates are dropped."
  (dired-filetags-test--with-crm (calls '("a" "b" "a"))
    (should (equal (dired-filetags--read-tags "P: " '(("a" . "1×"))) '("a" "b")))
    (should (eq (plist-get (car calls) :separator) dired-filetags--crm-separator))
    (should (equal (plist-get (car calls) :prompt) "P: ")))
  ;; Input that still holds separators is split again.
  (dired-filetags-test--with-crm (calls '("a,b" "c"))
    (should (equal (dired-filetags--read-tags "P: " nil) '("a" "b" "c")))))

(ert-deftest dired-filetags-read-table-metadata ()
  "The completion table has a category, annotations and a fixed order."
  (dired-filetags-test--with-crm (calls nil)
    (dired-filetags--read-tags "P: " '(("work" . "3×") ("x" . "vocab") ("bare")) t)
    (let* ((table (plist-get (car calls) :table))
           (md (completion-metadata "" table nil))
           (annotate (completion-metadata-get md 'annotation-function)))
      (should (eq (completion-metadata-get md 'category) 'dired-filetags-tag))
      (should (equal (funcall annotate "work") "  3×"))
      (should (eq (get-text-property 2 'face (funcall annotate "work")) 'completions-annotations))
      (should-not (funcall annotate "bare"))
      (should (equal (all-completions "" table) '("work" "x" "bare")))
      (should (equal (all-completions "w" table) '("work")))
      (should (eq (completion-metadata-get md 'display-sort-function) #'identity))
      (should (eq (completion-metadata-get md 'cycle-sort-function) #'identity))
      (should (eq (plist-get (car calls) :require-match) t)))))

(ert-deftest dired-filetags-read-crm-separator-splits-spaces-and-commas ()
  "Spaces and commas both separate tags."
  (should (equal (split-string "a, b  c,d" dired-filetags--crm-separator t) '("a" "b" "c" "d"))))

(ert-deftest dired-filetags-candidates-add-ranking ()
  "Add offers buffer tags by use, then vocabulary words, minus tags every target has."
  (dired-filetags-test--with-dir ("a -- work x.txt" "b -- work.txt" "c -- work.txt" "d -- x.txt"
                                  "e.txt" (".filetags" . "draft final work\n"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (should (equal (dired-filetags--add-candidates (list (f "e.txt")))
                     '(("work" . "3×") ("x" . "2×") ("draft" . "vocab") ("final" . "vocab"))))
      (let ((candidates (dired-filetags--add-candidates (list (f "b -- work.txt")))))
        (should (equal (car candidates) '("x" . "2×")))
        (should-not (assoc "work" candidates)))
      ;; Untaggable targets do not count.
      (should (assoc "work" (dired-filetags--add-candidates
                             (list (f "e.txt") (f ".filetags") (f "b -- work.txt"))))))))

(ert-deftest dired-filetags-candidates-remove-and-add-remove ()
  "Remove offers the targets' tags by frequency; add-remove adds the rest."
  (dired-filetags-test--with-dir ("a -- work x.txt" "b -- work.txt" "c -- work.txt" "d -- x.txt"
                                  "e.txt" (".filetags" . "draft final work\n"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (should (equal (dired-filetags--remove-candidates (list (f "a -- work x.txt") (f "d -- x.txt")))
                     '(("x" . "on 2/2") ("work" . "on 1/2"))))
      (should (equal (cadr (should-error (dired-filetags--remove-candidates (list (f "e.txt")))
                                         :type 'user-error))
                     "The selected files have no tags"))
      (should (equal (dired-filetags--add-remove-candidates (list (f "d -- x.txt")))
                     '(("x" . "on 1/1") ("work" . "3×") ("draft" . "vocab") ("final" . "vocab"))))
      ;; Add-remove works on untagged targets too.
      (should (equal (mapcar #'car (dired-filetags--add-remove-candidates (list (f "e.txt"))))
                     '("work" "x" "draft" "final"))))))

(ert-deftest dired-filetags-candidates-mark-point-first ()
  "Mark offers the tags of the file at point first."
  (dired-filetags-test--with-dir ("a -- work x.txt" "b -- work.txt" "c -- work.txt" "d -- x.txt"
                                  "e.txt" (".filetags" . "draft final work\n"))
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "d -- x.txt" root))
    (should (equal (dired-filetags--mark-candidates) '(("x" . "2×") ("work" . "3×"))))
    (goto-char (point-min))
    (should (equal (mapcar #'car (dired-filetags--mark-candidates)) '("work" "x")))))

(ert-deftest dired-filetags-prompt-names-single-file-or-count ()
  "The prompt names the one taggable file, untagged, or counts them."
  (dired-filetags-test--with-dir ("Report -- work.pdf" "a.txt" "sub/")
    (cl-flet ((f (name) (expand-file-name name root)))
      (should (equal (dired-filetags--prompt "Add tags to" (list (f "Report -- work.pdf")))
                     "Add tags to Report.pdf: "))
      (should (equal (dired-filetags--prompt "Add tags to" (list (f "Report -- work.pdf") (f "a.txt")))
                     "Add tags to 2 files: "))
      (should (equal (dired-filetags--prompt "Add tags to" (list (f "a.txt") (f "sub")))
                     "Add tags to a.txt: ")))))

(ert-deftest dired-filetags-command-reads-targets-before-prompting ()
  "An untaggable selection fails before the minibuffer is used."
  (dired-filetags-test--with-dir ("d/")
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "d" root))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) (ert-fail "The minibuffer must not be used"))))
      (dolist (command '(dired-filetags-add dired-filetags-remove dired-filetags-add-remove))
        (should (string-match-p "\\`No taggable files"
                                (cadr (should-error (call-interactively command)
                                                    :type 'user-error))))))))

(ert-deftest dired-filetags-command-add-interactive-end-to-end ()
  "`dired-filetags-add' reads tags for the file at point and adds them."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("e.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "e.txt" root))
    (dired-filetags-test--with-crm (calls '("work"))
      (call-interactively #'dired-filetags-add)
      (should (equal (plist-get (car calls) :prompt) "Add tags to e.txt: "))
      (should-not (plist-get (car calls) :require-match)))
    (should (equal (dired-filetags-test--listing root) '("e -- work.txt")))
    (dolist (command '(dired-filetags-add dired-filetags-remove dired-filetags-add-remove))
      (should (commandp command))
      (should (equal (command-modes command) '(dired-mode))))))

(ert-deftest dired-filetags-command-remove-requires-match ()
  "`dired-filetags-remove' insists on existing tags; `; a' does not."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("a -- x y.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-test--goto (expand-file-name "a -- x y.txt" root))
    (dired-filetags-test--with-crm (calls '("x"))
      (call-interactively #'dired-filetags-remove)
      (should (equal (plist-get (car calls) :prompt) "Remove tags from a.txt: "))
      (should (eq (plist-get (car calls) :require-match) t)))
    (should (equal (dired-filetags-test--listing root) '("a -- y.txt")))
    (dired-filetags-test--goto (expand-file-name "a -- y.txt" root))
    (dired-filetags-test--with-crm (calls '("y" "z"))
      (call-interactively #'dired-filetags-add-remove)
      (should (equal (plist-get (car calls) :prompt) "Add or remove tags on a.txt: "))
      (should-not (plist-get (car calls) :require-match))
      (should (equal (all-completions "" (plist-get (car calls) :table)) '("y"))))
    (should (equal (dired-filetags-test--listing root) '("a -- z.txt")))))

(ert-deftest dired-filetags-command-add-remove-prompt-counts-files ()
  "The add-remove prompt counts the targets and offers their tags first."
  (dired-filetags-test--with-dir ("a -- x y.txt" "b -- x.txt" "c -- w.txt"
                                  (".filetags" . "v\n"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--mark-files (list (f "a -- x y.txt") (f "b -- x.txt")))
      (cl-letf (((symbol-function 'dired-filetags--retag) #'ignore))
        (dired-filetags-test--with-crm (calls '("x"))
          (call-interactively #'dired-filetags-add-remove)
          (should (equal (plist-get (car calls) :prompt) "Add or remove tags on 2 files: "))
          (should (equal (mapcar (lambda (tag)
                                   (cons tag (funcall (completion-metadata-get
                                                       (completion-metadata
                                                        "" (plist-get (car calls) :table) nil)
                                                       'annotation-function)
                                                      tag)))
                                 (all-completions "" (plist-get (car calls) :table)))
                         '(("x" . "  on 2/2") ("y" . "  on 1/2") ("w" . "  1×")
                           ("v" . "  vocab")))))))))

(ert-deftest dired-filetags-command-add-remove-key-end-to-end ()
  "Typing ; a and a tag adds it to the file; typing the same again removes it."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("e -- x.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-mode 1)
      ;; The command loop reads keys in the selected window's buffer.
      (switch-to-buffer (current-buffer))
      (should (eq (key-binding (kbd "; a")) 'dired-filetags-add-remove))
      (dired-filetags-test--goto (f "e -- x.txt"))
      (execute-kbd-macro (kbd "; a work RET"))
      (should (equal (dired-filetags-test--listing root) '("e -- x work.txt")))
      (dired-filetags-test--goto (f "e -- x work.txt"))
      (execute-kbd-macro (kbd "; a work RET"))
      (should (equal (dired-filetags-test--listing root) '("e -- x.txt")))
      (should (equal (dired-filetags-test--last-message) "Retagged 1 file: -work")))))

(ert-deftest dired-filetags-command-add-and-remove-run-by-name ()
  "`dired-filetags-add' and `dired-filetags-remove' have no key but run by name."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("e.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-mode 1)
      (switch-to-buffer (current-buffer))
      (let ((suggest-key-bindings nil)
            (extended-command-suggest-shorter nil)
            ;; Offer only the commands meant for this buffer's mode, as M-x can.
            (read-extended-command-predicate #'command-completion-default-include-p))
        (dired-filetags-test--goto (f "e.txt"))
        (execute-kbd-macro (kbd "M-x dired-filetags-add RET work SPC x RET"))
        (should (equal (dired-filetags-test--listing root) '("e -- work x.txt")))
        (dired-filetags-test--goto (f "e -- work x.txt"))
        ;; Unlike ; a, adding a tag the file has leaves it alone.
        (execute-kbd-macro (kbd "M-x dired-filetags-add RET work RET"))
        (should (equal (dired-filetags-test--listing root) '("e -- work x.txt")))
        (execute-kbd-macro (kbd "M-x dired-filetags-remove RET work RET"))
        (should (equal (dired-filetags-test--listing root) '("e -- x.txt")))))))

;;;; Step 8: marking

(defmacro dired-filetags-test--with-mark-dir (&rest body)
  "Run BODY in a fresh Dired buffer on the marking fixture, bound to `root'."
  (declare (indent 0) (debug t))
  `(dired-filetags-test--with-dir ("a -- x y.txt" "b -- x.txt" "c.txt" "e -- emacs.txt"
                                   "F -- X.txt" "d -- x/" (".filetags" . "")
                                   ("ld -- x" :symlink "d -- x") "sub/s -- x.txt")
     (dired-filetags-test--dired root)
     ,@body))

(defun dired-filetags-test--marked ()
  "Return the sorted basenames of the files marked with `*'."
  (mapcar #'car (seq-filter (lambda (m) (eq (cdr m) ?*)) (dired-filetags-test--marks))))

(ert-deftest dired-filetags-mark-any-of-tags ()
  "`; m' marks the files that have at least one of the tags."
  (dired-filetags-test--with-mark-dir
    (should (= (dired-filetags-mark '("x")) 2))
    (should (equal (dired-filetags-test--marks) '(("a -- x y.txt" . ?*) ("b -- x.txt" . ?*))))
    (should (equal (dired-filetags-test--last-message) "2 tagged files marked"))
    (dired-unmark-all-marks)
    (dired-filetags-mark '("x" "emacs"))
    (should (equal (dired-filetags-test--marked) '("a -- x y.txt" "b -- x.txt" "e -- emacs.txt")))))

(ert-deftest dired-filetags-mark-not-is-the-complement-over-files ()
  "`; n' marks the other files, and never directories or control files."
  (dired-filetags-test--with-mark-dir
    (dired-filetags-mark-not '("x"))
    (should (equal (dired-filetags-test--marked) '("F -- X.txt" "c.txt" "e -- emacs.txt")))
    (should (equal (dired-filetags-test--last-message) "3 non-matching files marked"))
    (dired-unmark-all-marks)
    ;; A tag nobody has selects every file, and still no directory,
    ;; link to a directory, `.', `..' or .filetags.
    (dired-filetags-mark-not '("nothing"))
    (should (equal (dired-filetags-test--marked)
                   '("F -- X.txt" "a -- x y.txt" "b -- x.txt" "c.txt" "e -- emacs.txt")))))

(ert-deftest dired-filetags-mark-empty-means-tagged-or-untagged ()
  "Empty input marks tagged files, or with `; n' the untagged ones."
  (dired-filetags-test--with-mark-dir
    (dired-filetags-mark nil)
    (should (equal (dired-filetags-test--marked)
                   '("F -- X.txt" "a -- x y.txt" "b -- x.txt" "e -- emacs.txt")))
    (dired-unmark-all-marks)
    (dired-filetags-mark-not nil)
    (should (equal (dired-filetags-test--marked) '("c.txt")))
    (should (equal (dired-filetags-test--last-message) "1 untagged file marked"))))

(ert-deftest dired-filetags-mark-untagged-marks-only-untagged-files ()
  "`; u' marks the untagged files, never directories, links to them or control files."
  (dired-filetags-test--with-dir ("a -- x.txt" "c.txt" "sub/" "sub/s.txt" "d -- x/"
                                  (".filetags" . "") ("lc" :symlink "c.txt")
                                  ("lsub" :symlink "sub"))
    (dired-filetags-test--dired root)
    (should (= (dired-filetags-mark-untagged) 2))
    (should (equal (dired-filetags-test--marks) '(("c.txt" . ?*) ("lc" . ?*))))
    (should (equal (dired-filetags-test--last-message) "2 untagged files marked"))
    ;; The same files as `; n' with empty input.
    (dired-unmark-all-marks)
    (dired-filetags-mark-not nil)
    (should (equal (dired-filetags-test--marked) '("c.txt" "lc")))
    ;; Inserted subdirectories count too.
    (dired-insert-subdir (expand-file-name "sub/" root))
    (should (= (dired-filetags-mark-untagged) 1))
    (should (member (cons (expand-file-name "sub/s.txt" root) ?*)
                    (dired-remember-marks (point-min) (point-max))))
    ;; `C-u' unmarks them, and leaves the other marks alone.
    (dired-filetags-test--mark-files (list (expand-file-name "a -- x.txt" root)))
    (let ((current-prefix-arg '(4)))
      (call-interactively #'dired-filetags-mark-untagged))
    (should (equal (dired-filetags-test--marks) '(("a -- x.txt" . ?*))))
    (should (equal (dired-filetags-test--last-message) "3 untagged files unmarked"))
    (should-not (dired-filetags-mark-untagged t))
    (should (equal (command-modes 'dired-filetags-mark-untagged) '(dired-mode)))))

(ert-deftest dired-filetags-mark-matches-whole-tags-exactly ()
  "Tags match whole and case-sensitively."
  (dired-filetags-test--with-mark-dir
    (should-not (dired-filetags-mark '("em")))
    (should-not (dired-filetags-test--marks))
    (dired-filetags-mark '("X"))
    (should (equal (dired-filetags-test--marked) '("F -- X.txt")))))

(ert-deftest dired-filetags-mark-prefix-unmarks ()
  "With UNMARK, matching files are unmarked instead."
  (dired-filetags-test--with-mark-dir
    (dired-filetags-mark nil)
    (dired-filetags-mark '("y") t)
    (should (equal (dired-filetags-test--marked) '("F -- X.txt" "b -- x.txt" "e -- emacs.txt")))
    (should (equal (dired-filetags-test--last-message) "1 tagged file unmarked"))
    ;; An existing mark character is replaced.
    (dired-unmark-all-marks)
    (dired-filetags-test--mark-files (list (expand-file-name "c.txt" root)) ?D)
    (dired-filetags-mark-not '("x"))
    (should (equal (assoc "c.txt" (dired-filetags-test--marks)) '("c.txt" . ?*)))))

(ert-deftest dired-filetags-mark-covers-inserted-subdirs ()
  "Files in inserted subdirectories are marked too."
  (dired-filetags-test--with-mark-dir
    (dired-insert-subdir (expand-file-name "sub/" root))
    (dired-filetags-mark '("x"))
    (should (equal (dired-filetags-test--marked) '("a -- x y.txt" "b -- x.txt" "s -- x.txt")))
    (should (member (cons (expand-file-name "sub/s -- x.txt" root) ?*)
                    (dired-remember-marks (point-min) (point-max))))))

(ert-deftest dired-filetags-mark-interactive-spec ()
  "`; m' and `; n' read tags with REQUIRE-MATCH; a prefix unmarks."
  (dired-filetags-test--with-mark-dir
    (dired-filetags-test--with-crm (calls '("x"))
      (call-interactively #'dired-filetags-mark)
      (should (string-prefix-p "Mark files with any" (plist-get (car calls) :prompt)))
      (should (eq (plist-get (car calls) :require-match) t))
      (should (equal (dired-filetags-test--marked) '("a -- x y.txt" "b -- x.txt")))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'dired-filetags-mark))
      (should (string-prefix-p "Unmark files with any" (plist-get (car calls) :prompt)))
      (should-not (dired-filetags-test--marks))
      (call-interactively #'dired-filetags-mark-not)
      (should (equal (plist-get (car calls) :prompt)
                     "Mark files with none of these tags (empty: untagged): "))
      (should (equal (dired-filetags-test--marked) '("F -- X.txt" "c.txt" "e -- emacs.txt")))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'dired-filetags-mark-not))
      (should (string-prefix-p "Unmark files with none" (plist-get (car calls) :prompt)))
      (should-not (dired-filetags-test--marks)))
    (dolist (command '(dired-filetags-mark dired-filetags-mark-not))
      (should (equal (command-modes command) '(dired-mode))))))

(ert-deftest dired-filetags-mark-refuses-wdired ()
  "Marking never writes mark characters into a wdired buffer."
  (dired-filetags-test--with-mark-dir
    (wdired-change-to-wdired-mode)
    (unwind-protect
        (let ((text (buffer-string)))
          (should-error (dired-filetags-mark '("x")) :type 'user-error)
          (should-error (dired-filetags-mark-not nil) :type 'user-error)
          (should (equal (buffer-string) text)))
      (wdired-abort-changes))
    (should-not (dired-filetags-test--marks))))

;;;; Step 9: TagTrees locations, checks and prescan

(ert-deftest dired-filetags-tagtrees-target-is-per-source ()
  "Each source directory gets its own tree, named after it plus a hash."
  (dired-filetags-test--with-dir ("my docs/" "other/")
    (cl-flet ((f (name) (expand-file-name name root)))
      (let ((target (dired-filetags--tagtrees-target (f "my docs/"))))
        (should (string-prefix-p (f "trees/") target))
        (should (directory-name-p target))
        (should (string-match-p "\\`my_docs-[0-9a-f]\\{8\\}\\'"
                                (file-name-nondirectory (directory-file-name target))))
        (should (string-suffix-p
                 (substring (md5 (directory-file-name (file-truename (f "my docs/")))
                                 nil nil 'utf-8)
                            0 8)
                 (directory-file-name target)))
        (should-not (equal target (dired-filetags--tagtrees-target (f "other/"))))
        (should (equal target (dired-filetags--tagtrees-target (f "my docs"))))
        ;; A symbolic link to the source shares its tree.
        (make-symbolic-link (f "my docs") (f "alias"))
        (should (equal target (dired-filetags--tagtrees-target (f "alias/")))))
      (should (string-prefix-p "root-" (file-name-nondirectory
                                        (directory-file-name
                                         (dired-filetags--tagtrees-target "/")))))
      (with-timeout (5 (ert-fail "A remote TagTrees target tried to connect"))
        (should (equal (cadr (should-error (dired-filetags--tagtrees-target
                                            "/ssh:nowhere.invalid:/tmp/")
                                           :type 'user-error))
                       "TagTrees need a local directory"))))))

(ert-deftest dired-filetags-tagtrees-check-refuses-unsafe-geometry ()
  "Every unsafe source and target combination is refused before anything runs."
  (dired-filetags-test--with-dir ("src/a -- x.txt" ("tree/.filetags_tagtrees" . "") "tree/x/")
    (cl-flet ((f (name) (expand-file-name name root))
              (refused (source target &optional recursive)
                (cadr (should-error (dired-filetags--tagtrees-check source target recursive)
                                    :type 'user-error))))
      (let* ((src (f "src/"))
             (target (dired-filetags--tagtrees-target src))
             (file (directory-file-name target)))
        (should-not (dired-filetags--tagtrees-check src target nil))
        ;; Not empty and not a TagTree: refused and left alone.
        (dired-filetags-test--populate target '(("keep.txt" . "KEEP")))
        (should (string-match-p "\\`Refusing to use .*: it is not empty and not a TagTree\\'"
                                (refused src target)))
        (should (equal (dired-filetags-test--names target) '("keep.txt")))
        (should (equal (dired-filetags-test--contents (expand-file-name "keep.txt" target))
                       "KEEP"))
        ;; An empty directory or an existing TagTree is fine.
        (delete-file (expand-file-name "keep.txt" target))
        (should-not (dired-filetags--tagtrees-check src target t))
        (dired-filetags-test--populate target '((".filetags_tagtrees" . "") "x/"))
        (should-not (dired-filetags--tagtrees-check src target t))
        ;; The source is the tree directory itself.
        (delete-directory target t)
        (make-directory target)
        (should (string-match-p "is inside the TagTree directory\\'" (refused target target)))
        ;; A regular file, or a symbolic link, where the tree would go.
        (delete-directory target)
        (dired-filetags-test--populate root (list (cons file "FILE")))
        (should (string-match-p "is not a directory\\'" (refused src target)))
        (delete-file file)
        (make-symbolic-link (f "tree/x") file)
        (should (string-match-p "is not a directory\\'" (refused src target)))
        (delete-file file)
        ;; A source inside any TagTree, including foreign ones.
        (should (string-match-p "tree/x is inside a TagTree; run ; v in the directory"
                                (refused (f "tree/x/") (f "trees/x-00000000/"))))
        ;; A tree directory inside another TagTree.
        (let ((dired-filetags-tagtrees-directory (f "tree/x/")))
          (should (string-match-p "\\`Refusing to use .*: it is inside another TagTree\\'"
                                  (refused src (dired-filetags--tagtrees-target src)))))
        ;; A recursive build whose tree would lie inside the source.
        (let* ((dired-filetags-tagtrees-directory (f "src/trees/"))
               (inner (dired-filetags--tagtrees-target src)))
          (should (string-match-p (concat "\\`The TagTree directory is inside .*src;"
                                          " a recursive build would include it\\'")
                                  (refused src inner t)))
          (should-not (dired-filetags--tagtrees-check src inner nil)))
        ;; Remote directories are refused before any truename call.
        (with-timeout (5 (ert-fail "A remote TagTrees source tried to connect"))
          (should (equal (refused "/ssh:nowhere.invalid:/tmp/" (f "trees/x-00000000/"))
                         "TagTrees need a local directory"))
          (should (equal (refused src "/ssh:nowhere.invalid:/tmp/t/")
                         "TagTrees need a local directory")))
        ;; A build of the same tree is still running.
        (let ((proc (make-process :name "sleeper" :command '("sleep" "10") :noquery t)))
          (process-put proc 'dired-filetags-target target)
          (should (string-match-p "\\`TagTrees of .*src are already being built\\'"
                                  (refused src target)))
          (delete-process proc)
          (should-not (dired-filetags--tagtrees-check src target nil)))))))

(ert-deftest dired-filetags-tagtrees-inputs-match-os-walk ()
  "The inputs are the files filetags reads: hidden and broken ones, no directories."
  (dired-filetags-test--with-dir ("s/a.txt" "s/.hidden" "s/d/" "s/d/deep.txt"
                                  ("s/ld" :symlink "d") ("s/broken" :symlink "nowhere"))
    (cl-flet ((names (recursive)
                (let ((inputs (dired-filetags--tagtrees-inputs (expand-file-name "s/" root)
                                                               recursive)))
                  (should (seq-every-p #'file-name-absolute-p inputs))
                  (sort (mapcar #'file-name-nondirectory inputs) #'string<))))
      (should (equal (names nil) '(".hidden" "a.txt" "broken")))
      (should (equal (names t) '(".hidden" "a.txt" "broken" "deep.txt"))))))

(defun dired-filetags-test--prescan (root &optional recursive depth untagged)
  "Return the TagTrees prescan of ROOT/s/ for RECURSIVE, DEPTH and UNTAGGED.
DEPTH defaults to 2 and UNTAGGED to \"no-tags\"."
  (dired-filetags--tagtrees-prescan (expand-file-name "s/" root)
                                    (list :recursive recursive :depth (or depth 2)
                                          :untagged (or untagged "no-tags"))))

(defun dired-filetags-test--prescan-error (root &rest args)
  "Return the message of the `user-error' of the prescan of ROOT/s/ with ARGS."
  (cadr (should-error (apply #'dired-filetags-test--prescan root args) :type 'user-error)))

(ert-deftest dired-filetags-tagtrees-prescan-refuses-repeated-tags ()
  "A repeated tag makes filetags abort midway, so it is refused and logged."
  (dired-filetags-test--with-dir ("s/a -- x x.txt" "s/ok -- y.txt")
    (should (equal (dired-filetags-test--prescan-error root)
                   (concat "Cannot build TagTrees: 1 problem file(s), e.g. \"a -- x x.txt\""
                           " repeats a tag; type ? for details")))
    (should (string-search "TagTrees: a -- x x.txt: repeats a tag" (dired-filetags-test--log)))
    (should-not (string-search "ok -- y.txt" (dired-filetags-test--log)))
    ;; Depth 0 makes no tag directories, so a repeated tag is harmless.
    (should (= (dired-filetags-test--prescan root nil 0) 0))))

(ert-deftest dired-filetags-tagtrees-prescan-refuses-empty-tags ()
  "An empty tag is refused from depth 2 on."
  (dired-filetags-test--with-dir ("s/b -- p  q.txt")
    (should (string-match-p "has an empty tag" (dired-filetags-test--prescan-error root nil 2)))
    (should (string-search "b -- p  q.txt: has an empty tag" (dired-filetags-test--log)))
    (should (= (dired-filetags-test--prescan root nil 1) 3))))

(ert-deftest dired-filetags-tagtrees-prescan-refuses-dot-tags ()
  "A \".\" or \"..\" tag would escape the tree, so it is refused."
  (dired-filetags-test--with-dir ("s/c -- ...txt")
    (dired-filetags-test--prescan-error root)
    (should (string-search "c -- ...txt: has a \".\" or \"..\" tag" (dired-filetags-test--log)))))

(ert-deftest dired-filetags-tagtrees-prescan-refuses-shared-names ()
  "In a recursive build, files sharing a name, in any letter case, are refused."
  (dired-filetags-test--with-dir ("s/one/same.txt" "s/two/same.txt" "s/one/Other.txt"
                                  "s/two/other.txt")
    (should (string-match-p "\\`Cannot build TagTrees: 4 problem file(s)"
                            (dired-filetags-test--prescan-error root t)))
    (let ((log (dired-filetags-test--log)))
      (dolist (name '("one/same.txt" "two/same.txt" "one/Other.txt" "two/other.txt"))
        (should (string-search (concat name ": shares its name with another file") log))))
    (should (string-match-p "\\`No files in " (dired-filetags-test--prescan-error root nil)))
    ;; Untagged files are not linked under "ignore", so they cannot collide.
    (should (= (dired-filetags-test--prescan root t 2 "ignore") 0))))

(ert-deftest dired-filetags-tagtrees-prescan-refuses-vocabulary-at-the-root ()
  "With untagged files at the tree root, a .filetags cannot be linked there."
  (dired-filetags-test--with-dir (("s/.filetags" . "a b\n") "s/k.txt")
    (should (string-match-p "cannot be linked at the tree root"
                            (dired-filetags-test--prescan-error root nil 2 "treeroot")))
    (should (string-search ".filetags: cannot be linked at the tree root; set"
                           (dired-filetags-test--log)))
    (should (= (dired-filetags-test--prescan root nil 2 "no-tags") 2))
    (should (= (dired-filetags-test--prescan root nil 2 "ignore") 0))))

(ert-deftest dired-filetags-tagtrees-prescan-refuses-foreign-markers ()
  "Another tree's marker among the inputs is refused unless untagged files are left out."
  (dired-filetags-test--with-dir ("s/k -- t.txt" ("s/old/.filetags_tagtrees" . ""))
    (should (string-match-p "marker of another TagTree"
                            (dired-filetags-test--prescan-error root t 2 "no-tags")))
    (should (string-search "old/.filetags_tagtrees: is the marker of another TagTree"
                           (dired-filetags-test--log)))
    (dired-filetags-test--prescan-error root t 2 "treeroot")
    (should (= (dired-filetags-test--prescan root t 2 "ignore") 1))
    (should (= (dired-filetags-test--prescan root nil 2 "no-tags") 1))))

(ert-deftest dired-filetags-tagtrees-prescan-refuses-empty-sources ()
  "A source without files is refused before the tree is reset."
  (dired-filetags-test--with-dir ("s/")
    (should (string-match-p "\\`No files in .*s\\'" (dired-filetags-test--prescan-error root)))
    (should (string-match-p "\\`No files in " (dired-filetags-test--prescan-error root t)))))

(ert-deftest dired-filetags-tagtrees-prescan-estimate-matches-cli-count ()
  "The link estimate is the sum of k!/(k-d)! per tagged file, plus the untagged."
  (dired-filetags-test--with-dir ("s/a -- x y.txt" "s/b.txt" "s/c -- x.pdf"
                                  ("s/.filetags" . "draft final\n"))
    (should (= (dired-filetags-test--prescan root nil 2 "no-tags") 7))
    (should (= (dired-filetags-test--prescan root nil 2 "ignore") 5))
    (should (= (dired-filetags-test--prescan root nil 1 "no-tags") 5))
    (should (= (dired-filetags-test--prescan root nil 3 "no-tags") 7)))
  (should (= (dired-filetags--permutations 5 1) 5))
  (should (= (dired-filetags--permutations 5 2) 25))
  (should (= (dired-filetags--permutations 5 3) 85))
  (should (= (dired-filetags--permutations 2 0) 0)))

(ert-deftest dired-filetags-tagtrees-prescan-estimate-agrees-with-cli-report ()
  "The estimate equals the link count that filetags itself reports."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("s/a -- x y z.txt" "s/b.txt" "s/c -- x.pdf"
                                  ("s/.filetags" . "draft final\n"))
    (let ((n 0))
      (pcase-dolist (`(,depth ,untagged) '((1 "no-tags") (2 "no-tags") (3 "no-tags")
                                           (2 "ignore") (2 "sub")))
        (let* ((tree (expand-file-name (format "trees/cli-%d" (cl-incf n)) root))
               (default-directory (expand-file-name "s/" root))
               (report (with-temp-buffer
                         (call-process "filetags" nil t nil "--tagtrees" "--tagtrees-dir" tree
                                       "--filebrowser" "none" "--tagtrees-depth"
                                       (number-to-string depth)
                                       "--tagtrees-handle-no-tag" untagged)
                         (buffer-string)))
               (reported (and (string-match "for the [0-9]+ files: \\([0-9]+\\)" report)
                              (string-to-number (match-string 1 report)))))
          (should reported)
          (should (equal (list depth untagged
                               (dired-filetags-test--prescan root nil depth untagged))
                         (list depth untagged reported))))))))

;;;; Step 10: TagTrees builds, sentinel, rebuild and visit-original

(defmacro dired-filetags-test--with-tree (&rest body)
  "Run BODY after building the TagTrees of ROOT/s/ from its Dired buffer.
BODY sees `root', `src' (ROOT/s/) and `target' (the tree directory);
the selected window then shows the tree."
  (declare (indent 0) (debug t))
  `(dired-filetags-test--with-dir ("s/a -- x y.txt" "s/b.txt" "s/c -- x.pdf"
                                   ("s/.filetags" . "draft final\n"))
     (let* ((src (expand-file-name "s/" root))
            (target (dired-filetags--tagtrees-target src)))
       (ignore src target)
       (switch-to-buffer (dired-filetags-test--dired src))
       (dired-filetags-test--wait (dired-filetags-tagtrees))
       (should (file-exists-p (dired-filetags--sidecar target)))
       ,@body)))

(defun dired-filetags-test--build-process (root)
  "Return the build of a tree below ROOT whose sentinel has not finished, or nil."
  (seq-find (lambda (proc)
              (and (dired-filetags-test--in-root-p root (process-get proc 'dired-filetags-target))
                   (not (process-get proc 'dired-filetags-done))))
            (process-list)))

(defun dired-filetags-test--lines (file)
  "Return the non-empty lines of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (split-string (buffer-string) "\n" t)))

(ert-deftest dired-filetags-tagtrees-args-are-explicit-and-safe ()
  "The CLI gets an explicit tree directory, no browser, and never --overwrite."
  (dired-filetags-test--with-dir ("s/a -- x.txt")
    (let* ((args (expand-file-name "args" root))
           (src (expand-file-name "s/" root))
           (target (dired-filetags--tagtrees-target src))
           (dired-filetags-program
            (dired-filetags-test--script
             root "record" (format "{ pwd; printf '%%s\\n' \"$@\"; } > %s\nexit 0\n"
                                   (shell-quote-argument args)))))
      (switch-to-buffer (dired-filetags-test--dired src))
      (let ((proc (dired-filetags-tagtrees)))
        (should (processp proc))
        (should (string-match-p "\\`Building TagTrees of .*s (depth 2)\\.\\.\\.\\'"
                                (dired-filetags-test--last-message)))
        (dired-filetags-test--wait proc)
        (should-not (buffer-live-p (process-buffer proc))))
      (let ((lines (dired-filetags-test--lines args)))
        (should (file-equal-p (car lines) src))
        (should (equal (cdr lines)
                       (list "-q" "--tagtrees" "--tagtrees-dir" (directory-file-name target)
                             "--filebrowser" "none" "--tagtrees-depth" "2"
                             "--tagtrees-handle-no-tag" "no-tags"))))
      ;; The script makes no tree, which counts as a failure: no sidecar.
      (should-not (file-exists-p (dired-filetags--sidecar target)))
      (should (string-match-p "failed (exit 0): no output"
                              (dired-filetags-test--last-message)))
      (let ((dired-filetags-tagtrees-depth 3)
            (dired-filetags-tagtrees-untagged "ignore"))
        (dired-filetags-test--wait (dired-filetags-tagtrees t)))
      (let ((lines (dired-filetags-test--lines args)))
        (should (equal (last lines 4) '("3" "--tagtrees-handle-no-tag" "ignore" "-R")))
        (should-not (member "--overwrite" lines))))))

(ert-deftest dired-filetags-tagtrees-builds-and-visits ()
  "A build makes the tree, records its sidecar and shows it in Dired."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-tree
    (cl-flet ((tt (name) (expand-file-name name target)))
      (dolist (dir '("x/" "y/" "x/y/" "y/x/" "no-tags/"))
        (should (file-directory-p (tt dir))))
      (should (file-exists-p (tt ".filetags_tagtrees")))
      (should (file-symlink-p (tt "x/a -- x y.txt")))
      (should (file-symlink-p (tt "no-tags/b.txt")))
      (let ((sidecar (dired-filetags--read-sidecar target)))
        (should (file-equal-p (plist-get sidecar :source) src))
        (should (equal (plist-get sidecar :source) src))
        (should (equal (list (plist-get sidecar :recursive) (plist-get sidecar :depth)
                             (plist-get sidecar :untagged))
                       '(nil 2 "no-tags"))))
      (let ((shown (window-buffer (selected-window))))
        (should (eq (buffer-local-value 'major-mode shown) 'dired-mode))
        (should (file-equal-p (buffer-local-value 'default-directory shown) target)))
      (should (buffer-live-p (dired-find-buffer-nocreate src)))
      (should (string-match-p "\\`TagTrees of .*s ready\\'" (dired-filetags-test--last-message)))
      (should (dired-filetags-test--scratch-empty-p)))))

(ert-deftest dired-filetags-tagtrees-build-leaves-a-window-in-use-alone ()
  "A build that finishes after its window moved on is not visited there."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("s/a -- x.txt")
    (let* ((src (expand-file-name "s/" root))
           (other (get-buffer-create "*dired-filetags-test-other*")))
      (unwind-protect
          (progn
            (switch-to-buffer (dired-filetags-test--dired src))
            (let ((proc (dired-filetags-tagtrees)))
              (switch-to-buffer other)
              (dired-filetags-test--wait proc))
            (should (eq (window-buffer (selected-window)) other))
            (should (file-exists-p (dired-filetags--sidecar (dired-filetags--tagtrees-target src))))
            (should (string-match-p "\\`TagTrees of .*s ready\\'"
                                    (dired-filetags-test--last-message))))
        (kill-buffer other)))))

(ert-deftest dired-filetags-tagtrees-failure-is-reported ()
  "A failed build is logged and reported, and nothing is visited."
  (dired-filetags-test--with-dir ("s/a -- x.txt")
    (let* ((src (expand-file-name "s/" root))
           (dired-filetags-program
            (dired-filetags-test--script root "fail" "echo 'ERROR    boom' >&2; exit 21\n"))
           (buf (dired-filetags-test--dired src)))
      (switch-to-buffer buf)
      (dired-filetags-test--wait (dired-filetags-tagtrees))
      (should-not (file-exists-p (dired-filetags--sidecar (dired-filetags--tagtrees-target src))))
      (should (eq (window-buffer (selected-window)) buf))
      (should (string-search "failed (exit 21):\nERROR    boom" (dired-filetags-test--log)))
      (should (string-match-p "failed (exit 21): ERROR +boom; type \\? for details\\'"
                              (dired-filetags-test--last-message))))))

(ert-deftest dired-filetags-tagtrees-error-output-fails-a-build-that-exits-0 ()
  "The sentinel applies the failure rule of `dired-filetags--call'.
An ERROR or Traceback line fails a build even if it exits 0 and makes
its marker: no sidecar is written and the tree is not visited."
  (dolist (report '("ERROR    boom" "Traceback (most recent call last):"))
    (dired-filetags-test--with-dir ("s/a -- x.txt")
      (let* ((src (expand-file-name "s/" root))
             (target (dired-filetags--tagtrees-target src))
             (dired-filetags-program
              (dired-filetags-test--script
               root "build" (concat "mkdir -p \"$4\" && : > \"$4/.filetags_tagtrees\"\n"
                                    "echo '" report "' >&2\nexit 0\n")))
             (buf (dired-filetags-test--dired src)))
        (switch-to-buffer buf)
        (dired-filetags-test--wait (dired-filetags-tagtrees))
        (should (file-exists-p (expand-file-name ".filetags_tagtrees" target)))
        (should-not (file-exists-p (dired-filetags--sidecar target)))
        (should (eq (window-buffer (selected-window)) buf))
        (should (string-suffix-p (concat "failed (exit 0): " report "; type ? for details")
                                 (dired-filetags-test--last-message)))))))

(ert-deftest dired-filetags-tagtrees-rebuild-errors-name-directories-plainly ()
  "Rebuild errors spell directories as the other messages do, without a slash."
  (dired-filetags-test--with-dir ("s/a -- x.txt")
    (let* ((src (expand-file-name "s/" root))
           (gone (expand-file-name "gone/" root))
           (target (dired-filetags--tagtrees-target src)))
      (dired-filetags-test--populate target '((".filetags_tagtrees" . "")))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (ert-fail "No build may start"))))
        (dired-filetags--write-sidecar target '(:source 5))
        (should (equal (cadr (should-error (dired-filetags--tagtrees-rebuild target)
                                           :type 'user-error))
                       (format "Cannot read the parameters of the TagTree %s"
                               (dired-filetags--pretty-dir target))))
        (dired-filetags--write-sidecar target (list :source gone :recursive nil :depth 2
                                                    :untagged "no-tags"))
        (should (equal (cadr (should-error (dired-filetags--tagtrees-rebuild target)
                                           :type 'user-error))
                       (format "The source of this TagTree, %s, no longer exists"
                               (dired-filetags--pretty-dir gone))))))))

(ert-deftest dired-filetags-tagtrees-rebuild-from-inside-keeps-buffer ()
  "; v inside a tree rebuilds it with its own parameters, in place."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-tree
    (let ((buf (dired-noselect (expand-file-name "x/" target))))
      (switch-to-buffer buf)
      (set-buffer buf)
      (dired-filetags-test--populate src '("d -- x.txt"))
      ;; The prefix is ignored: the sidecar's parameters are used.
      (let ((proc (dired-filetags-tagtrees t)))
        (should (string-match-p "\\`Rebuilding TagTrees of .*s\\.\\.\\.\\'"
                                (dired-filetags-test--last-message)))
        (dired-filetags-test--wait proc))
      (should (buffer-live-p buf))
      (should (eq (window-buffer (selected-window)) buf))
      (with-current-buffer buf
        (should (dired-goto-file (expand-file-name "x/d -- x.txt" target))))
      (should-not (plist-get (dired-filetags--read-sidecar target) :recursive))
      (should (string-match-p "\\`TagTrees of .*s ready\\'" (dired-filetags-test--last-message))))))

(ert-deftest dired-filetags-tagtrees-vanished-directory-falls-back-to-root ()
  "A tree buffer whose directory is gone after a rebuild is replaced by the root."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-tree
    (let ((buf (dired-noselect (expand-file-name "x/y/" target))))
      (switch-to-buffer buf)
      (set-buffer buf)
      (delete-file (expand-file-name "c -- x.pdf" src))
      (delete-file (expand-file-name "a -- x y.txt" src))
      (dired-filetags-test--wait (dired-filetags-tagtrees))
      (should-not (buffer-live-p buf))
      (should-not (file-exists-p (expand-file-name "x/" target)))
      (let ((shown (window-buffer (selected-window))))
        (should (eq (buffer-local-value 'major-mode shown) 'dired-mode))
        (should (file-equal-p (buffer-local-value 'default-directory shown) target))))))

(ert-deftest dired-filetags-tagtrees-limit-asks ()
  "A tree with more estimated links than the limit is built only on request."
  (dired-filetags-test--with-dir ("s/a -- x y.txt")
    (let ((dired-filetags-tagtrees-link-limit 1)
          (prompts nil))
      (switch-to-buffer (dired-filetags-test--dired (expand-file-name "s/" root)))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt prompts) nil))
                ((symbol-function 'make-process)
                 (lambda (&rest _) (ert-fail "No build may start"))))
        (should (equal (cadr (should-error (dired-filetags-tagtrees) :type 'user-error))
                       "TagTrees not built")))
      (should (string-match-p "\\`TagTrees of .*s need about 4 links; build them\\? \\'"
                              (car prompts)))
      (should-not (dired-filetags-test--build-process root))
      ;; At the limit nothing is asked.
      (let ((dired-filetags-tagtrees-link-limit 4)
            (dired-filetags-program (dired-filetags-test--script root "noop" "exit 0\n")))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "Must not ask"))))
          (dired-filetags-test--wait (dired-filetags-tagtrees))))
      ;; A rebuild never asks, whatever the estimate.
      (let* ((src (expand-file-name "s/" root))
             (target (dired-filetags--tagtrees-target src))
             (dired-filetags-program (dired-filetags-test--script root "noop" "exit 0\n")))
        (dired-filetags-test--populate target '((".filetags_tagtrees" . "")))
        (dired-filetags--write-sidecar target (list :source src :recursive nil :depth 2
                                                    :untagged "no-tags"))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "Must not ask"))))
          (dired-filetags-test--wait (dired-filetags--tagtrees-rebuild target)))))))

(ert-deftest dired-filetags-tagtrees-inside-tagging-renames-original-and-rebuilds ()
  "Tagging a link in a tree renames its original, then rebuilds the tree."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-tree
    (let ((buf (dired-noselect (expand-file-name "x/" target))))
      (switch-to-buffer buf)
      (set-buffer buf)
      (dired-filetags-test--goto (expand-file-name "x/c -- x.pdf" target))
      (should (equal (dired-filetags-add '("w"))
                     (list (cons (expand-file-name "c -- x.pdf" src)
                                 (expand-file-name "c -- x w.pdf" src)))))
      (should (string-suffix-p "; rebuilding TagTrees..." (dired-filetags-test--last-message)))
      (let ((proc (dired-filetags-test--build-process root)))
        (should proc)
        (dired-filetags-test--wait proc))
      (should (member "c -- x w.pdf" (dired-filetags-test--names src)))
      (should (file-symlink-p (expand-file-name "w/c -- x w.pdf" target)))
      (with-current-buffer buf
        (should (dired-goto-file (expand-file-name "x/c -- x w.pdf" target)))
        (should-not (dired-goto-file (expand-file-name "x/c -- x.pdf" target))))
      (with-current-buffer (dired-find-buffer-nocreate src)
        (should (dired-goto-file (expand-file-name "c -- x w.pdf" src))))
      (should (eq (window-buffer (selected-window)) buf)))))

(ert-deftest dired-filetags-tagtrees-inside-tagging-reports-a-failed-rebuild ()
  "If the tree cannot be rebuilt, the retag message says why."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-tree
    (let ((buf (dired-noselect (expand-file-name "x/" target)))
          (sleeper (make-process :name "sleeper" :command '("sleep" "10") :noquery t)))
      (process-put sleeper 'dired-filetags-target target)
      (set-buffer buf)
      (dired-filetags-test--goto (expand-file-name "x/c -- x.pdf" target))
      (should (dired-filetags-add '("w")))
      (should (string-match-p (concat "\\`Retagged 1 file: \\+w; TagTrees of .*s are already"
                                      " being built; TagTrees not rebuilt\\'")
                              (dired-filetags-test--last-message)))
      (delete-process sleeper)
      (should (file-exists-p (expand-file-name "c -- x w.pdf" src))))))

(ert-deftest dired-filetags-tagtrees-inside-foreign-tree-is-refused ()
  "; v in a tree this package did not build is refused."
  (dired-filetags-test--with-dir (("f/.filetags_tagtrees" . "") "f/x/")
    (dired-filetags-test--dired (expand-file-name "f/x/" root))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "No build may start"))))
      (should (string-match-p "inside a TagTree"
                              (cadr (should-error (dired-filetags-tagtrees) :type 'user-error))))
      (should-error (dired-filetags-tagtrees t) :type 'user-error)
      (with-temp-buffer
        (should (equal (cadr (should-error (dired-filetags-tagtrees) :type 'user-error))
                       "Not in a Dired buffer"))))))

(ert-deftest dired-filetags-visit-original-jumps-to-source ()
  "; o visits the original of a link, and refuses other lines."
  (dired-filetags-test--with-dir ("src/a -- x.txt" ("l -- x.txt" :symlink "src/a -- x.txt")
                                  ("dead" :symlink "nowhere") "plain.txt")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--goto (f "l -- x.txt"))
      (dired-filetags-visit-original)
      (should (derived-mode-p 'dired-mode))
      (should (file-equal-p default-directory (f "src/")))
      (should (equal (dired-get-filename nil t) (f "src/a -- x.txt")))
      (dired-filetags-test--dired root)
      (dired-filetags-test--goto (f "dead"))
      (should (string-match-p "\\`Stale link: .*nowhere does not exist; rebuild with ; v\\'"
                              (cadr (should-error (dired-filetags-visit-original)
                                                  :type 'user-error))))
      (dired-filetags-test--goto (f "plain.txt"))
      (should (equal (cadr (should-error (dired-filetags-visit-original) :type 'user-error))
                     "Not a symbolic link"))
      (goto-char (point-min))
      (should (equal (cadr (should-error (dired-filetags-visit-original) :type 'user-error))
                     "Not a symbolic link"))
      (dolist (command '(dired-filetags-tagtrees dired-filetags-visit-original))
        (should (commandp command))
        (should (equal (command-modes command) '(dired-mode)))))))

;;;; Step 11: rendering, minor mode and keymaps

(defmacro dired-filetags-test--with-render (&rest body)
  "Run BODY in a Dired buffer on the rendering fixture, with the mode on.
jit-lock does not run in batch Emacs, so BODY calls the fontifier."
  (declare (indent 0) (debug t))
  `(dired-filetags-test--with-dir ("Report -- work urgent.pdf" "notes.txt" "multi -- x -- y.txt"
                                   "foo -- emacs" "bar -- emacs"
                                   ("l -- z.txt" :symlink "Report -- work urgent.pdf"))
     (dired-filetags-test--dired root)
     (dired-filetags-mode 1)
     ,@body))

(defun dired-filetags-test--fontify ()
  "Decorate the whole current buffer, as jit-lock would."
  (dired-filetags--fontify (point-min) (point-max)))

(defun dired-filetags-test--start (root name)
  "Move to the line of NAME below ROOT and return the start of the name."
  (dired-filetags-test--goto (expand-file-name name root))
  (point))

(defun dired-filetags-test--overlay-at (beg end)
  "Return the one package overlay that spans exactly BEG to END."
  (let ((found (seq-filter (lambda (ov) (and (= (overlay-start ov) beg) (= (overlay-end ov) end)))
                           (dired-filetags-test--overlays beg end))))
    (should (length= found 1))
    (car found)))

(defun dired-filetags-test--pill-p (ov)
  "Return non-nil if overlay OV is a tag label."
  (let ((face (overlay-get ov 'face)))
    (and (consp face) (eq (car (last face)) 'dired-filetags-tag))))

(defun dired-filetags-test--line-overlays ()
  "Return the package overlays on the current line."
  (dired-filetags-test--overlays (line-beginning-position) (line-end-position)))

(defun dired-filetags-test--header ()
  "Return the header line of the current buffer, which batch Emacs cannot format.
`format-mode-line' always returns \"\" when `noninteractive'."
  (should (eq (car-safe header-line-format) :eval))
  (eval (cadr header-line-format) t))

(ert-deftest dired-filetags-render-aligned-relocates-extension ()
  "In `aligned' style the extension follows the name and the tags are labels."
  (dired-filetags-test--with-render
    (dired-filetags-test--fontify)
    (let ((b (dired-filetags-test--start root "Report -- work urgent.pdf")))
      (should (equal (substring-no-properties
                      (overlay-get (dired-filetags-test--overlay-at (+ b 6) (+ b 7)) 'display))
                     ".pdf"))
      (should (equal (overlay-get (dired-filetags-test--overlay-at (+ b 7) (+ b 10)) 'display)
                     '(space :width 22)))
      (should (equal (overlay-get (dired-filetags-test--overlay-at (+ b 21) (+ b 25)) 'display)
                     ""))
      (dolist (range '((10 . 14) (15 . 21)))
        (should (dired-filetags-test--pill-p
                 (dired-filetags-test--overlay-at (+ b (car range)) (+ b (cdr range))))))
      (should (= (length (dired-filetags-test--line-overlays)) 5))
      (dolist (ov (dired-filetags-test--line-overlays))
        (should (eql (overlay-get ov 'priority) 50))
        (should (eq (overlay-get ov 'evaporate) t)))
      ;; The moved extension keeps the face font-lock gave it (diredfl's).
      (with-silent-modifications (put-text-property (+ b 21) (+ b 25) 'face 'bold))
      (dired-filetags-test--fontify)
      (should (eq (get-text-property 0 'face (overlay-get (dired-filetags-test--overlay-at
                                                           (+ b 6) (+ b 7))
                                                          'display))
                  'bold))
      (should (= (length (dired-filetags-test--line-overlays)) 5)))))

(ert-deftest dired-filetags-render-leaves-text-and-names-raw ()
  "Decoration never changes the buffer text, its properties, or file names."
  (dired-filetags-test--with-render
    (let ((before (buffer-string)))
      (dired-filetags-test--fontify)
      (should (dired-filetags-test--overlays))
      (should (equal-including-properties (buffer-string) before)))
    (dired-filetags-test--goto (expand-file-name "Report -- work urgent.pdf" root))
    (should (equal (dired-get-filename 'no-dir t) "Report -- work urgent.pdf"))
    (let ((copy (filter-buffer-substring (line-beginning-position) (line-end-position))))
      (should (string-search "Report -- work urgent.pdf" copy))
      (should-not (text-property-not-all 0 (length copy) 'display nil copy)))))

(ert-deftest dired-filetags-render-no-extension-pads-separator ()
  "Without an extension, the separator itself becomes the padding."
  (dired-filetags-test--with-render
    (dired-filetags-test--fontify)
    (let ((b (dired-filetags-test--start root "foo -- emacs")))
      (should (equal (overlay-get (dired-filetags-test--overlay-at (+ b 3) (+ b 7)) 'display)
                     '(space :width 29)))
      (should (dired-filetags-test--pill-p (dired-filetags-test--overlay-at (+ b 7) (+ b 12))))
      (should (= (length (dired-filetags-test--line-overlays)) 2)))))

(ert-deftest dired-filetags-render-double-dash-token-uses-separator-face ()
  "A literal \"--\" tag is grey, and the tags around it are labels."
  (dired-filetags-test--with-render
    (dired-filetags-test--fontify)
    (let ((b (dired-filetags-test--start root "multi -- x -- y.txt")))
      (should (eq (overlay-get (dired-filetags-test--overlay-at (+ b 11) (+ b 13)) 'face)
                  'dired-filetags-separator))
      (should (dired-filetags-test--pill-p (dired-filetags-test--overlay-at (+ b 9) (+ b 10))))
      (should (dired-filetags-test--pill-p (dired-filetags-test--overlay-at (+ b 14) (+ b 15)))))))

(ert-deftest dired-filetags-render-skips-symlink-targets-and-header ()
  "Only file names are decorated: not link targets, headers or untagged names."
  (dired-filetags-test--with-render
    (dired-filetags-test--fontify)
    (dired-filetags-test--goto (expand-file-name "l -- z.txt" root))
    (let ((end (save-excursion (dired-move-to-end-of-filename))))
      (should (dired-filetags-test--line-overlays))
      (should (seq-every-p (lambda (ov) (<= (overlay-end ov) end))
                           (dired-filetags-test--line-overlays)))
      (should (= (seq-count #'dired-filetags-test--pill-p (dired-filetags-test--line-overlays))
                 1)))
    ;; Lines without a tagged file name: the header, a "total" line if
    ;; `ls' prints one, `.', `..' and notes.txt.
    (goto-char (point-min))
    (should (looking-at-p (concat "^  " (regexp-quote (directory-file-name root)) ":$")))
    (let ((plain nil))
      (while (not (eobp))
        (let ((name (dired-get-filename 'no-dir t)))
          (unless (and name (dired-filetags--split name))
            (push (or name (string-trim (buffer-substring-no-properties
                                         (line-beginning-position) (line-end-position))))
                  plain)
            (should-not (dired-filetags-test--line-overlays))))
        (forward-line 1))
      (should (member "." plain))
      (should (member ".." plain))
      (should (member "notes.txt" plain))
      (should (member (concat (directory-file-name root) ":") plain)))))

(ert-deftest dired-filetags-render-display-objects-are-fresh-per-line ()
  "Each line gets its own padding object, even when the widths are equal."
  (dired-filetags-test--with-render
    (dired-filetags-test--fontify)
    (cl-flet ((pad (name offset)
                (let ((b (dired-filetags-test--start root name)))
                  (overlay-get (dired-filetags-test--overlay-at (+ b offset) (+ b offset 3 1))
                               'display))))
      (let ((report (dired-filetags-test--start root "Report -- work urgent.pdf")))
        (setq report (overlay-get (dired-filetags-test--overlay-at (+ report 7) (+ report 10))
                                  'display))
        (let ((foo (pad "foo -- emacs" 3))
              (bar (pad "bar -- emacs" 3)))
          (should (equal foo bar))
          (should-not (eq foo bar))
          (should-not (eq report foo)))))))

(ert-deftest dired-filetags-render-subtracts-line-prefix ()
  "A dired-subtree line prefix counts toward the alignment."
  (dired-filetags-test--with-render
    (let ((b (dired-filetags-test--start root "Report -- work urgent.pdf")))
      (overlay-put (make-overlay (line-beginning-position) (line-end-position))
                   'line-prefix "    ")
      (dired-filetags-test--fontify)
      (should (equal (overlay-get (dired-filetags-test--overlay-at (+ b 7) (+ b 10)) 'display)
                     '(space :width 18))))))

(ert-deftest dired-filetags-render-aligns-dired-subtree-lines ()
  "Real dired-subtree lines are decorated, and their prefix counts."
  (skip-unless (require 'dired-subtree nil t))
  (dired-filetags-test--with-dir ("top -- work.txt" "sub/deep -- work.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-mode 1)
    (dired-filetags-test--goto (expand-file-name "sub" root))
    (dired-subtree-insert)
    (goto-char (point-min))
    (search-forward "deep -- work.txt")
    (dired-filetags-test--fontify)
    (let ((b (progn (dired-move-to-filename) (point))))
      (should (equal (get-char-property b 'line-prefix) "  "))
      ;; 32 - (4 "deep" + 4 ".txt" + 2 of prefix)
      (should (equal (overlay-get (dired-filetags-test--overlay-at (+ b 5) (+ b 8)) 'display)
                     '(space :width 22)))
      (should (dired-filetags-test--pill-p (dired-filetags-test--overlay-at (+ b 8) (+ b 12)))))))

(ert-deftest dired-filetags-render-inline-style-uses-faces-only ()
  "`inline' style only colours; nil style decorates nothing."
  (dired-filetags-test--with-render
    (setq-local dired-filetags-display-style 'inline)
    (dired-filetags-test--fontify)
    (should (dired-filetags-test--overlays))
    (should-not (seq-some (lambda (ov) (overlay-get ov 'display)) (dired-filetags-test--overlays)))
    (let ((b (dired-filetags-test--start root "Report -- work urgent.pdf")))
      (should (eq (overlay-get (dired-filetags-test--overlay-at (+ b 6) (+ b 10)) 'face)
                  'dired-filetags-separator))
      (should (= (seq-count #'dired-filetags-test--pill-p (dired-filetags-test--line-overlays))
                 2)))
    (setq-local dired-filetags-display-style nil)
    (dired-filetags-test--fontify)
    (should-not (dired-filetags-test--overlays))))

(defun dired-filetags-test--right-labels ()
  "Return the right-edge label string of the current line."
  (let ((eol (line-end-position)))
    (overlay-get (dired-filetags-test--overlay-at eol (1+ eol)) 'before-string)))

(ert-deftest dired-filetags-render-right-style-labels-at-right-edge ()
  "`right' style hides the tags in the name and shows them at the right edge."
  (should (eq (eval (car (get 'dired-filetags-display-style 'standard-value)) t) 'right))
  (dired-filetags-test--with-render
    (setq-local dired-filetags-display-style 'right)
    (let ((before (buffer-string)))
      (dired-filetags-test--fontify)
      (should (equal-including-properties (buffer-string) before)))
    (let* ((b (dired-filetags-test--start root "Report -- work urgent.pdf"))
           (labels (dired-filetags-test--right-labels)))
      ;; "Report.pdf" remains, with the extension in place.
      (should (equal (overlay-get (dired-filetags-test--overlay-at (+ b 6) (+ b 21)) 'display)
                     ""))
      (should (= (length (dired-filetags-test--overlays (line-beginning-position)
                                                        (1+ (line-end-position))))
                 2))
      (should (equal (substring-no-properties labels) "  work urgent"))
      ;; In batch Emacs widths are columns; the labels end two short of the edge.
      (should (equal (get-text-property 1 'display labels) '(space :align-to (- right (11) 2))))
      (should-not (get-text-property 0 'display labels))
      (should (equal (get-text-property 2 'face labels) (dired-filetags--tag-face "work")))
      (should (equal (get-text-property 7 'face labels) (dired-filetags--tag-face "urgent")))
      (should-not (get-text-property 6 'face labels)))
    ;; A literal "--" tag keeps the separator face.
    (dired-filetags-test--start root "multi -- x -- y.txt")
    (let ((labels (dired-filetags-test--right-labels)))
      (should (equal (substring-no-properties labels) "  x -- y"))
      (should (eq (get-text-property 4 'face labels) 'dired-filetags-separator)))
    ;; On a symbolic link, the labels follow the link target.
    (let ((b (dired-filetags-test--start root "l -- z.txt")))
      (should (string-search " -> " (buffer-substring b (line-end-position))))
      (should (equal (substring-no-properties (dired-filetags-test--right-labels)) "  z")))
    ;; Untagged names are left alone.
    (dired-filetags-test--start root "notes.txt")
    (should-not (dired-filetags-test--overlays (line-beginning-position)
                                               (1+ (line-end-position))))))

(ert-deftest dired-filetags-render-right-labels-on-a-last-line ()
  "Without a final newline, the labels follow the last character."
  (with-temp-buffer
    (insert "x -- t")
    (dired-filetags--right-labels '("" "t"))
    (let ((ov (car (overlays-in (point-min) (point-max)))))
      (should (= (overlay-start ov) 6))
      (should (equal (substring-no-properties (overlay-get ov 'after-string)) "  t"))))
  (with-temp-buffer
    (insert "x\n")
    (goto-char (point-min))
    (dired-filetags--right-labels '(""))
    (should-not (overlays-in (point-min) (point-max)))))

(ert-deftest dired-filetags-mode-refontifies-on-text-scale ()
  "Right-edge labels are measured again when the text scale changes."
  (dired-filetags-test--with-render
    (should (memq #'jit-lock-refontify text-scale-mode-hook))
    (dired-filetags-mode -1)
    (should-not (memq #'jit-lock-refontify text-scale-mode-hook))))

(ert-deftest dired-filetags-render-skips-b-listings ()
  "Listings with escaped names are not decorated."
  (dired-filetags-test--with-dir ("a -- x.txt" "b -- y z.txt")
    (set-buffer (dired-noselect root "-lab"))
    (should (equal dired-actual-switches "-lab"))
    (dired-filetags-mode 1)
    (dired-filetags-test--fontify)
    (should-not (dired-filetags-test--overlays))))

(ert-deftest dired-filetags-render-skips-shortened-names ()
  "Names that `dired-filename-display-length' shortens are not decorated."
  (skip-unless (boundp 'dired-filename-display-length))    ; Emacs 30.1+
  (dired-filetags-test--with-render
    (setq-local dired-filename-display-length 12)
    (revert-buffer)
    (dired-filetags-test--fontify)
    (dired-filetags-test--goto (expand-file-name "Report -- work urgent.pdf" root))
    (should (seq-some (lambda (ov) (eq (overlay-get ov 'invisible) 'dired-filename-hide))
                      (overlays-in (line-beginning-position) (line-end-position))))
    (should-not (dired-filetags-test--line-overlays))
    (dired-filetags-test--goto (expand-file-name "foo -- emacs" root))
    (should (dired-filetags-test--line-overlays))))

(ert-deftest dired-filetags-render-steps-aside-in-wdired ()
  "In wdired, names are raw and ; and * self-insert; both exits redecorate."
  (dired-filetags-test--with-render
    (dolist (exit '(wdired-abort-changes wdired-finish-edit))
      (dired-filetags-test--fontify)
      (should (dired-filetags-test--overlays))
      (with-silent-modifications (put-text-property (point-min) (point-max) 'fontified t))
      (wdired-change-to-wdired-mode)
      (should-not (dired-filetags-test--overlays))
      (dired-filetags-test--fontify)
      (should-not (dired-filetags-test--overlays))
      (dolist (key '(";" "*" "#"))
        (should (equal (cons key (key-binding key)) (cons key 'wdired--self-insert))))
      (funcall exit)
      (should (eq major-mode 'dired-mode))
      (let ((b (dired-filetags-test--start root "Report -- work urgent.pdf")))
        (should-not (get-text-property b 'fontified)))
      (dired-filetags-test--fontify)
      (should (dired-filetags-test--overlays))
      (should (eq (key-binding (kbd "; a")) 'dired-filetags-add-remove)))))

(ert-deftest dired-filetags-tag-face-is-stable-and-overridable ()
  "Each tag hashes to a fixed colour, unless `dired-filetags-tag-faces' says otherwise."
  (let ((dired-filetags-tag-faces nil)
        (bg (nth (mod (string-to-number (substring (md5 "work" nil nil 'utf-8) 0 8) 16) 12)
                 dired-filetags-tag-colors)))
    (should (equal (dired-filetags--tag-face "work") (dired-filetags--tag-face "work")))
    (should (equal (dired-filetags--tag-face "work")
                   `((:background ,bg :box (:line-width (2 . -1) :color ,bg))
                     dired-filetags-tag)))
    (should (member (plist-get (car (dired-filetags--tag-face "日本語")) :background)
                    dired-filetags-tag-colors)))
  (let ((dired-filetags-tag-faces '(("work" . error))))
    (should (equal (dired-filetags--tag-face "work") '(error dired-filetags-tag))))
  (let ((dired-filetags-tag-faces '(("work" . (:background "#FF0080")))))
    (should (equal (dired-filetags--tag-face "work")
                   '((:background "#FF0080") dired-filetags-tag)))))

(ert-deftest dired-filetags-mode-keys-resolve-in-dired ()
  "The ; prefix and the * additions resolve in Dired; Dired's own keys stay.
; r and ; t are unbound, and `dired-filetags-add' and
`dired-filetags-remove' have no key in any of the mode's maps."
  (dired-filetags-test--with-render
    (pcase-dolist (`(,key . ,command)
                   '(("; a" . dired-filetags-add-remove) ("; r" . nil) ("; t" . nil)
                     ("; m" . dired-filetags-mark)
                     ("; n" . dired-filetags-mark-not) ("; u" . dired-filetags-mark-untagged)
                     ("; v" . dired-filetags-tagtrees) ("; o" . dired-filetags-visit-original)
                     ("* #" . dired-filetags-mark) ("* ~" . dired-filetags-mark-not)
                     ("#" . dired-flag-auto-save-files) (": v" . epa-dired-do-verify)
                     ("* %" . dired-mark-files-regexp) ("* t" . dired-toggle-marks)
                     ("* m" . dired-mark)))
      (should (equal (cons key (key-binding (kbd key))) (cons key command))))
    (should (keymapp (key-binding ";")))
    ;; `where-is-internal' looks through the filtered prefixes, as help does.
    (should (equal (mapcar #'key-description (where-is-internal #'dired-filetags-add-remove))
                   '("; a")))
    (should-not (where-is-internal #'dired-filetags-add))
    (should-not (where-is-internal #'dired-filetags-remove))
    (should (equal (dired-filetags--key "v") "; v"))))

(ert-deftest dired-filetags-mode-off-restores-keys-and-removes-overlays ()
  "Turning the mode off restores Dired's keys and removes every trace."
  (dired-filetags-test--with-render
    (dired-filetags-test--fontify)
    (should (dired-filetags-test--overlays))
    (should (memq #'dired-filetags--fontify jit-lock-functions))
    (should (memq #'dired-filetags--remove-overlays wdired-mode-hook))
    (dired-filetags-mode -1)
    (should (eq (key-binding "#") 'dired-flag-auto-save-files))
    (should-not (keymapp (key-binding ";")))
    (should-not (key-binding (kbd "; a")))
    (should-not (key-binding (kbd "* #")))
    (should-not (dired-filetags-test--overlays))
    (should-not (memq #'dired-filetags--fontify jit-lock-functions))
    (should-not (and (local-variable-p 'wdired-mode-hook)
                     (memq #'dired-filetags--remove-overlays wdired-mode-hook)))
    (dired-filetags-test--fontify)
    (should-not (dired-filetags-test--overlays))
    (dired-filetags-mode 1)
    (dired-filetags-test--fontify)
    (should (dired-filetags-test--overlays))))

(defun dired-filetags-test--key-sequences (map &optional prefix)
  "Return the key sequences bound in MAP, each after the vector PREFIX.
Prefix keys are included and walked, also behind a menu item, and a
character range contributes its first and last character."
  (let (seqs)
    (map-keymap
     (lambda (event def)
       (dolist (ev (if (consp event) (list (car event) (cdr event)) (list event)))
         (unless (eq ev t)                           ; a default binding
           (let ((seq (vconcat prefix (vector ev)))
                 (sub (if (eq (car-safe def) 'menu-item) (nth 2 def) def)))
             (push seq seqs)
             (when (keymapp sub)
               (setq seqs (nconc (dired-filetags-test--key-sequences sub seq) seqs)))))))
     map)
    seqs))

(ert-deftest dired-filetags-mode-only-adds-keys ()
  "With the default prefix, the mode changes no key that Dired binds.
Each sequence bound in `dired-mode-map' or in the mode's keymap either
resolves as before, or was unbound and is now one of the mode's keys.
Prefix keys that are keymaps before and after merge, so they count as
unchanged, and their keys are compared one by one."
  (dired-filetags-test--with-dir ("a -- x.txt" "b.txt")
    (dired-filetags-test--dired root)
    (let* ((seqs (delete-dups
                  (append (dired-filetags-test--key-sequences dired-mode-map)
                          (dired-filetags-test--key-sequences dired-filetags-mode-map))))
           (before (mapcar (lambda (seq) (cons seq (key-binding seq))) seqs))
           added changed)
      (should (length> seqs 100))
      (dired-filetags-mode 1)
      (pcase-dolist (`(,seq . ,old) before)
        (let ((new (key-binding seq)))
          (cond ((equal old new))
                ((and (keymapp old) (keymapp new)))
                ;; `suppress-keymap' makes unbound printing keys `undefined'.
                ((memq old '(nil undefined)) (push (key-description seq) added))
                (t (push (list (key-description seq) old new) changed)))))
      (should-not changed)
      (should (equal (sort added #'string<)
                     '("* #" "* ~" ";" "; a" "; m" "; n" "; o" "; u" "; v"))))))

(ert-deftest dired-filetags-command-add-remove-on-a-dired-key ()
  "Bound to \":\" in Dired's map, as the README suggests, add-remove runs there.
In wdired, whose keymap does not inherit Dired's, \":\" still inserts
itself, and the mode's keys are unchanged either way."
  (dired-filetags-test--with-render
    ;; A child of `dired-mode-map' stands in for it, so the real map is untouched.
    (use-local-map (define-keymap :parent dired-mode-map ":" #'dired-filetags-add-remove))
    (should (eq (key-binding ":") 'dired-filetags-add-remove))
    (should (eq (key-binding (kbd "; a")) 'dired-filetags-add-remove))
    (should (eq (key-binding (kbd "* #")) 'dired-filetags-mark))
    (wdired-change-to-wdired-mode)
    (unwind-protect
        (dolist (key '(":" ";"))
          (should (equal (cons key (key-binding key)) (cons key 'wdired--self-insert))))
      (wdired-abort-changes))))

(ert-deftest dired-filetags-test-stock-dired-map-restores-easypg ()
  "The tests' Dired map puts back an EasyPG prefix that the session rebound."
  (let* ((dired-mode-map (define-keymap :parent dired-mode-map
                           ":" #'dired-filetags-add-remove))
         (map (dired-filetags-test--stock-dired-map)))
    (should (eq (keymap-parent map) dired-mode-map))
    (should (eq (keymap-lookup map ": d") 'epa-dired-do-decrypt))
    (should (eq (keymap-lookup map ": v") 'epa-dired-do-verify))
    (should (eq (keymap-lookup map "* m") 'dired-mark))
    (should (eq (keymap-lookup dired-mode-map ":") 'dired-filetags-add-remove)))
  ;; An intact prefix is used as it is.
  (let ((dired-mode-map (define-keymap ":" (define-keymap "d" #'epa-dired-do-decrypt))))
    (should (eq (dired-filetags-test--stock-dired-map) dired-mode-map))))

(ert-deftest dired-filetags-prefix-key-moves-with-setopt ()
  "`setopt' moves the commands at once, also in open buffers."
  (dired-filetags-test--with-render
    (dired-filetags-test--with-prefix ":"
      (should (eq (key-binding (kbd ": a")) 'dired-filetags-add-remove))
      (should (eq (key-binding (kbd ": u")) 'dired-filetags-mark-untagged))
      ;; Prefix maps merge: of EasyPG's keys only ": v" is taken.
      (should (eq (key-binding (kbd ": v")) 'dired-filetags-tagtrees))
      (should (eq (key-binding (kbd ": d")) 'epa-dired-do-decrypt))
      (should-not (keymapp (key-binding ";")))
      (should-not (key-binding (kbd "; a")))
      (should (equal (dired-filetags--key "v") ": v"))
      ;; Prefixes that would take over "*", or are not keys, change nothing.
      (dolist (bad '("*" "* x"))
        (should-error (setopt dired-filetags-prefix-key bad) :type 'user-error))
      (should-error (funcall (get 'dired-filetags-prefix-key 'custom-set)
                             'dired-filetags-prefix-key "no such key")
                    :type 'user-error)
      (should (equal dired-filetags-prefix-key ":"))
      (should (eq (key-binding (kbd ": a")) 'dired-filetags-add-remove))
      (should (eq (key-binding (kbd "* m")) 'dired-mark))
      (should (eq (key-binding (kbd "* #")) 'dired-filetags-mark))
      ;; A longer prefix works, and the old one is released.
      (setopt dired-filetags-prefix-key "C-c t")
      (should (eq (key-binding (kbd "C-c t a")) 'dired-filetags-add-remove))
      (should-not (key-binding (kbd ": a")))
      (should (eq (key-binding (kbd ": v")) 'epa-dired-do-verify)))
    (should (eq (key-binding (kbd "; a")) 'dired-filetags-add-remove))
    (should-not (key-binding (kbd "C-c t a")))
    (should-not (key-binding (kbd ": a")))))

(ert-deftest dired-filetags-mode-prefix-help-lists-the-commands ()
  "PREFIX \\`C-h' lists the tag commands, though help runs in its own buffer."
  (dired-filetags-test--with-render
    (let ((dired (current-buffer)))
      (cl-flet ((help (prefix)
                  ;; What `describe-prefix-bindings' shows, from another buffer.
                  (with-temp-buffer
                    (describe-buffer-bindings dired (kbd prefix))
                    (buffer-string))))
        (should (string-match-p "^; a[ \t]+dired-filetags-add-remove$" (help ";")))
        (should (string-match-p "^; u[ \t]+dired-filetags-mark-untagged$" (help ";")))
        (should (string-match-p "^\\* #[ \t]+dired-filetags-mark$" (help "*")))
        (should (string-match-p "^\\* m[ \t]+dired-mark$" (help "*")))
        (dired-filetags-test--with-prefix ":"
          (should (string-match-p "^: a[ \t]+dired-filetags-add-remove$" (help ":")))
          (should (string-match-p "^: d[ \t]+epa-dired-do-decrypt$" (help ":"))))))))

(ert-deftest dired-filetags-prefix-key-set-before-loading ()
  "A prefix set before the package loads is bound when it loads.
A separate Emacs sets it through use-package's :custom with a deferred
load, which stores a theme value before the option exists, and with
`setq'."
  (dired-filetags-test--with-dir ("a -- x.txt")
    (let ((emacs (expand-file-name invocation-name invocation-directory))
          (lib (file-name-directory (locate-library "dired-filetags"))))
      (dolist (setup `((use-package dired-filetags
                         :load-path ,lib
                         :defer t
                         :custom (dired-filetags-prefix-key ":"))
                       (setq dired-filetags-prefix-key ":")))
        (with-temp-buffer
          (let ((status
                 (call-process
                  emacs nil t nil "-Q" "-batch"
                  "--eval"
                  (prin1-to-string
                   `(progn
                      (require 'use-package)
                      (setq load-prefer-newer t)
                      ,setup
                      (when (featurep 'dired-filetags) (error "Loaded too early"))
                      (push ,lib load-path)
                      (require 'dired-filetags)
                      (with-current-buffer (dired-noselect ,root)
                        (dired-filetags-mode 1)
                        (princ (format "\nRESULT %S %S %S %S\n"
                                       dired-filetags-prefix-key
                                       (key-binding (kbd ": a"))
                                       (key-binding (kbd ": d"))
                                       (key-binding (kbd "; a"))))))))))
            (should (equal (list (car setup) status
                                 (progn (goto-char (point-max))
                                        (and (re-search-backward "^RESULT .*" nil t)
                                             (match-string 0))))
                           (list (car setup) 0
                                 (concat "RESULT \":\" dired-filetags-add-remove"
                                         " epa-dired-do-decrypt nil"))))))))))

(ert-deftest dired-filetags-unload-feature-turns-the-mode-off ()
  "`unload-feature' leaves no trace in Dired buffers, and the package reloads.
It runs in a separate Emacs, so this session keeps its definitions."
  (dired-filetags-test--with-dir ("a -- x.txt")
    (let ((emacs (expand-file-name invocation-name invocation-directory))
          (lib (locate-library "dired-filetags.el")))
      (with-temp-buffer
        (let ((status
               (call-process
                emacs nil t nil "-Q" "-batch"
                "--eval"
                (prin1-to-string
                 `(progn
                    (load ,lib nil t t)
                    (let ((buf (dired-noselect ,root)))
                      (with-current-buffer buf
                        (dired-filetags-mode 1)
                        (dired-filetags--fontify (point-min) (point-max)))
                      (unload-feature 'dired-filetags t)
                      (with-current-buffer buf
                        (princ (format "\nRESULT %S %S %S"
                                       (memq 'dired-filetags--fontify jit-lock-functions)
                                       (seq-some (lambda (ov) (overlay-get ov 'dired-filetags))
                                                 (overlays-in (point-min) (point-max)))
                                       (fboundp 'dired-filetags-mode)))
                        (load ,lib nil t t)
                        (dired-filetags-mode 1)
                        (princ (format " %S\n" (key-binding (kbd "; a")))))))))))
          (should (equal (list status (progn (goto-char (point-max))
                                             (and (re-search-backward "^RESULT .*" nil t)
                                                  (match-string 0))))
                         '(0 "RESULT nil nil nil dired-filetags-add-remove"))))))))

(ert-deftest dired-filetags-render-untagged-regions-are-not-walked ()
  "Without \" -- \" in the region, the fontifier examines no line of it."
  (dired-filetags-test--with-dir ("a.txt" "b.txt" "notes-2026.org" "sub/")
    (dired-filetags-test--dired root)
    (dired-filetags-mode 1)
    (let ((lines 0)
          (names 0)
          (move (symbol-function 'dired-move-to-filename))
          (decorate (symbol-function 'dired-filetags--decorate)))
      (cl-letf (((symbol-function 'dired-move-to-filename)
                 (lambda (&rest args) (cl-incf lines) (apply move args)))
                ((symbol-function 'dired-filetags--decorate)
                 (lambda (&rest args) (cl-incf names) (apply decorate args))))
        (should (equal (dired-filetags-test--fontify)
                       `(jit-lock-bounds ,(point-min) . ,(point-max))))
        (should (equal (list lines names) '(0 0)))
        ;; One tagged name, and every line is examined again.
        (dired-filetags-test--populate root '("c -- x.txt"))
        (revert-buffer)
        (setq lines 0 names 0)
        (dired-filetags-test--fontify)
        ;; Every entry, "." and ".." included.
        (should (>= lines (length (directory-files root))))
        (should (= names (length (directory-files root))))
        (should (dired-filetags-test--overlays))))))

(ert-deftest dired-filetags-mode-refuses-non-dired-buffers ()
  "The mode only works in Dired."
  (with-temp-buffer
    (should (equal (cadr (should-error (dired-filetags-mode 1) :type 'user-error))
                   "Dired-Filetags mode only works in Dired buffers"))
    (should-not dired-filetags-mode)
    (should-not (memq #'dired-filetags--fontify jit-lock-functions))))

(ert-deftest dired-filetags-mode-sets-up-tagtree-buffers ()
  "Tree buffers hide link targets; our own trees also get a header line."
  (dired-filetags-test--with-dir (("f/.filetags_tagtrees" . "") ("t/.filetags_tagtrees" . "")
                                  "t/work/" "t/50%/" "plain/")
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags--write-sidecar (f "t/") (list :source (f "src/")))
      (dired-filetags-test--dired (f "f/"))
      (dired-filetags-mode 1)
      (should (local-variable-p 'dired-hide-details-hide-symlink-targets))
      (should (eq dired-hide-details-hide-symlink-targets t))
      (should-not (local-variable-p 'header-line-format))
      (should (eq dired-filetags--tagtree t))
      (dired-filetags-test--dired (f "t/work/"))
      (dired-filetags-mode 1)
      (should (local-variable-p 'dired-hide-details-hide-symlink-targets))
      (should (equal (plist-get dired-filetags--tagtree :root) (f "t/")))
      (should (string-match-p "\\` TagTrees of .*src › work   (; v rebuild, ; o original)\\'"
                              (dired-filetags-test--header)))
      (dired-filetags-mode -1)
      (should-not (local-variable-p 'dired-hide-details-hide-symlink-targets))
      (should-not (local-variable-p 'header-line-format))
      (should-not dired-filetags--tagtree)
      ;; The tree root has no crumbs, and a "%" is escaped for the mode line.
      (dired-filetags-test--dired (f "t/"))
      (dired-filetags-mode 1)
      (should (string-match-p "src   (; v" (dired-filetags-test--header)))
      (dired-filetags-test--dired (f "t/50%/"))
      (dired-filetags-mode 1)
      (should (string-search " › 50%%   (" (dired-filetags-test--header)))
      (dired-filetags-test--dired (f "plain/"))
      (dired-filetags-mode 1)
      (should-not (local-variable-p 'dired-hide-details-hide-symlink-targets))
      (should-not (local-variable-p 'header-line-format))
      (should-not dired-filetags--tagtree))))

(ert-deftest dired-filetags-mode-tagtree-buffer-after-build ()
  "The tree that a build visits is set up as a TagTree buffer."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("s/a -- x y.txt" "s/b.txt")
    (let ((dired-mode-hook '(dired-filetags-mode))
          (src (expand-file-name "s/" root)))
      (switch-to-buffer (dired-filetags-test--dired src))
      (dired-filetags-test--wait (dired-filetags-tagtrees))
      (with-current-buffer (window-buffer (selected-window))
        (should (file-equal-p default-directory (dired-filetags--tagtrees-target src)))
        (should dired-filetags-mode)
        (should (local-variable-p 'dired-hide-details-hide-symlink-targets))
        (should (eq dired-hide-details-hide-symlink-targets t))
        (should (string-match-p "\\` TagTrees of .*s   (; v rebuild"
                                (dired-filetags-test--header)))))))

;;;; Regressions from review

(defun dired-filetags-test--link (root target name)
  "Make NAME below ROOT a symbolic link to TARGET, a string used as is."
  (make-symbolic-link target (expand-file-name name root)))

(ert-deftest dired-filetags-oracle-handles-tilde-names ()
  "Basenames \"~\" and \"~USER\" stay in the scratch directory and get tagged."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("other.txt")
    (let ((names (list "~" (concat "~" (or (user-login-name) "root")))))
      ;; Not `populate': `expand-file-name' would name a home directory.
      (dolist (name names)
        (let ((file-name-handler-alist nil)) (write-region "" nil (concat root name) nil 0)))
      (should (equal (dired-filetags--new-names (append names '("other.txt")) "t1" nil)
                     (append (mapcar (lambda (n) (concat n " -- t1")) names) '("other -- t1.txt"))))
      (should (dired-filetags-test--scratch-empty-p))
      (dired-filetags-test--dired root)
      (dired-filetags-test--mark-files (mapcar (lambda (n) (concat root n)) (cons "other.txt" names)))
      (should (= (length (dired-filetags-add '("t1"))) 3))
      (should (equal (dired-filetags-test--listing root)
                     (sort (append (mapcar (lambda (n) (concat n " -- t1")) names)
                                   '("other -- t1.txt"))
                           #'string<))))))

(ert-deftest dired-filetags-retag-follows-other-spellings-of-a-directory ()
  "Buffers on a symbolic link to the directory follow a retag done elsewhere."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir (("real/a.txt" . "old"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--link root "real" "alias")
      (let* ((create-lockfiles nil)
             (make-backup-files nil)
             (find-file-visit-truename nil)
             (visit (find-file-noselect (f "alias/a.txt")))
             (other (dired-noselect (f "alias/"))))
        (with-current-buffer visit (goto-char (point-max)) (insert " edit"))
        (dired-filetags-test--dired (f "real/"))
        (dired-filetags-test--goto (f "real/a.txt"))
        (dired-filetags-add '("x"))
        (should (file-equal-p (buffer-file-name visit) (f "real/a -- x.txt")))
        (should (buffer-modified-p visit))
        (with-current-buffer other
          (should (dired-goto-file (f "alias/a -- x.txt")))
          (should-not (dired-goto-file (f "alias/a.txt"))))
        (with-current-buffer visit (save-buffer))
        (should (equal (dired-filetags-test--names (f "real/")) '("a -- x.txt")))
        (should (string-prefix-p "old edit" (dired-filetags-test--contents (f "real/a -- x.txt"))))))))

(ert-deftest dired-filetags-retag-refresh-never-contacts-other-hosts ()
  "Refreshing after a local retag never expands a remote Dired buffer's directory."
  (dired-filetags-test--with-dir ("a.txt")
    (let ((fake (generate-new-buffer "dired-filetags-test-remote"))
          (handler (lambda (operation &rest args)
                     (if (eq operation 'file-remote-p)
                         "/dired-filetags-test-remote:"
                       (ert-fail (format "Remote operation %s %S" operation args))))))
      (unwind-protect
          (let ((file-name-handler-alist
                 (cons (cons "\\`/dired-filetags-test-remote:" handler) file-name-handler-alist)))
            (dired-filetags-test--dired root)
            (with-current-buffer fake
              (setq major-mode 'dired-mode
                    default-directory "/dired-filetags-test-remote:~/docs/"))
            (dired-filetags--refresh-stale-buffers (list (expand-file-name "a.txt" root)))
            (dired-filetags--refresh-tree-buffers (expand-file-name "trees/x-00000000/" root)
                                                  root))
        (kill-buffer fake)))))

(ert-deftest dired-filetags-targets-refuse-real-files-inside-tagtrees ()
  "A regular file inside a TagTree is refused: the next build would delete it."
  (dired-filetags-test--with-dir (("tree/.filetags_tagtrees" . "")
                                  ("tree/x/saved -- x.pdf" . "ONLY COPY"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--dired (f "tree/x/"))
      (dired-filetags-test--goto (f "tree/x/saved -- x.pdf"))
      (dired-filetags-test--forbid-cli
        (should (string-match-p "No taggable files"
                                (cadr (should-error (dired-filetags--targets nil)
                                                    :type 'user-error))))
        (should (string-match-p "\\`Cannot retag saved -- x.pdf: is inside a TagTree"
                                (cadr (should-error (dired-filetags-add
                                                     '("keep") (list (f "tree/x/saved -- x.pdf")))
                                                    :type 'user-error)))))
      (should (equal (dired-filetags-test--names (f "tree/x/")) '("saved -- x.pdf"))))))

(ert-deftest dired-filetags-tagtrees-check-refuses-trees-holding-other-files ()
  "A tree that holds anything filetags did not make is never rebuilt."
  (dired-filetags-test--with-dir ("src/a -- x.txt")
    (let* ((src (expand-file-name "src/" root))
           (target (dired-filetags--tagtrees-target src)))
      (dired-filetags-test--populate target '((".filetags_tagtrees" . "")
                                              ("no-tags/.filetags_tagtrees" . "") "x/"))
      (dired-filetags-test--link target (expand-file-name "a -- x.txt" src) "x/a -- x.txt")
      (should-not (dired-filetags--tagtrees-check src target nil))
      ;; Finder's metadata files are disposable and do not block a rebuild.
      (dired-filetags-test--populate target '((".DS_Store" . "") ("x/.DS_Store" . "")
                                              ("x/._a -- x.txt" . "")))
      (should-not (dired-filetags--tagtrees-check src target nil))
      (dired-filetags-test--populate target '(("x/saved -- x.pdf" . "ONLY COPY")))
      (should (string-match-p
               "\\`Refusing to rebuild .*: x/saved -- x.pdf is not a link filetags made"
               (cadr (should-error (dired-filetags--tagtrees-check src target nil)
                                   :type 'user-error))))
      (should (file-exists-p (expand-file-name "x/saved -- x.pdf" target))))))

(defconst dired-filetags-test--bad-untagged
  "\\`Invalid dired-filetags-tagtrees-untagged .*: use a folder name\\'"
  "The message of a refused `dired-filetags-tagtrees-untagged'.")

(ert-deftest dired-filetags-tagtrees-check-untagged-is-a-folder-name ()
  "Only \"treeroot\", \"ignore\" or a single folder name reaches filetags."
  (require 'wid-edit)
  (dolist (bad '("" "." ".." "a/b" "/abs/olute" "../x" "-x" ".filetags" ".FileTags_TagTrees"
                 "a\nb" nil))
    (should-error (dired-filetags--check-untagged bad) :type 'user-error))
  (dolist (good '("treeroot" "ignore" "no-tags" "untagged files" "日本"))
    (should-not (dired-filetags--check-untagged good)))
  (let ((widget (widget-convert (get 'dired-filetags-tagtrees-untagged 'custom-type))))
    (should (widget-apply widget :match "no-tags"))
    (should (widget-apply widget :match "treeroot"))
    (should-not (widget-apply widget :match "a/b"))
    (should-not (widget-apply widget :match "..")))
  (dired-filetags-test--with-dir ("s/a -- x.txt" "s/b.txt")
    (let ((dired-filetags-tagtrees-untagged "/abs/olute"))
      (switch-to-buffer (dired-filetags-test--dired (expand-file-name "s/" root)))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (ert-fail "No build may start"))))
        (should (string-match-p dired-filetags-test--bad-untagged
                                (cadr (should-error (dired-filetags-tagtrees)
                                                    :type 'user-error))))
        ;; A sidecar is checked too, since every rebuild reuses its value.
        (let ((target (dired-filetags--tagtrees-target (expand-file-name "s/" root))))
          (dired-filetags-test--populate target '((".filetags_tagtrees" . "")))
          (dired-filetags--write-sidecar target (list :source (expand-file-name "s/" root)
                                                      :recursive nil :depth 2 :untagged "../x"))
          (should (string-match-p dired-filetags-test--bad-untagged
                                  (cadr (should-error (dired-filetags--tagtrees-rebuild target)
                                                      :type 'user-error)))))))))

(ert-deftest dired-filetags-tagtrees-prescan-refuses-root-collisions ()
  "At the tree root, an untagged file named like a tag collides with its folder."
  (dired-filetags-test--with-dir ("s/a -- work.txt" "s/Work")
    (should (string-match-p "collides with the tag folder"
                            (dired-filetags-test--prescan-error root nil 2 "treeroot")))
    (should (string-search "Work: collides with the tag folder" (dired-filetags-test--log)))
    (should (= (dired-filetags-test--prescan root nil 2 "no-tags") 2))
    (should (= (dired-filetags-test--prescan root nil 0 "treeroot") 1))))

(ert-deftest dired-filetags-tagtrees-prescan-refuses-untagged-folder-collisions ()
  "A tag named like the untagged folder makes its tag folders collide with files."
  (dired-filetags-test--with-dir ("s/a -- no-tags x.txt" "s/x")
    (should (string-match-p "collides with the tag folder no-tags/x"
                            (dired-filetags-test--prescan-error root nil 2 "no-tags")))
    (should (= (dired-filetags-test--prescan root nil 1 "no-tags") 3))
    (should (= (dired-filetags-test--prescan root nil 2 "other") 5))))

(ert-deftest dired-filetags-tagtrees-prescan-refuses-control-file-tags ()
  "A tag named like a filetags control file collides with that file."
  (dolist (name '("s/a -- .filetags_tagtrees.txt" "s/a -- x .FILETAGS.txt"))
    (dired-filetags-test--with-dir ()
      (dired-filetags-test--populate root (list name))
      (should (string-match-p "named like a filetags control file"
                              (dired-filetags-test--prescan-error root nil 2 "no-tags")))))
  (dolist (tag '(".filetags" ".FileTags_TagTrees"))
    (should-error (dired-filetags--check-tags (list tag)) :type 'user-error)
    (should (dired-filetags--check-tags (list tag) t))))

(ert-deftest dired-filetags-tagtrees-prescan-refusals-match-cli-aborts ()
  "Each new prescan refusal is a case in which filetags really aborts."
  (skip-unless (executable-find "filetags"))
  (let ((n 0))
    (pcase-dolist (`(,untagged . ,names)
                   '(("treeroot" "a -- work.txt" "work")
                     ("no-tags" "a -- no-tags x.txt" "x")
                     ("no-tags" "a -- .filetags_tagtrees.txt")))
      (dired-filetags-test--with-dir ()
        (dired-filetags-test--populate root (mapcar (lambda (name) (concat "s/" name)) names))
        (dired-filetags-test--prescan-error root nil 2 untagged)
        (let* ((default-directory (expand-file-name "s/" root))
               (status (call-process "filetags" nil nil nil "-q" "--tagtrees" "--tagtrees-dir"
                                     (expand-file-name (format "trees/cli-%d" (cl-incf n)) root)
                                     "--filebrowser" "none" "--tagtrees-depth" "2"
                                     "--tagtrees-handle-no-tag" untagged)))
          (should (equal (list untagged names (and (not (eql status 0)) t))
                         (list untagged names t))))))))

(ert-deftest dired-filetags-tagtrees-inside-tagging-renames-the-source-entry ()
  "A source entry that is itself a link is renamed as a link, never its target."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir ("s/b -- y.txt" ("elsewhere/real.txt" . "REAL"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--link root (f "elsewhere/real.txt") "s/alias -- a.txt")
      (dired-filetags-test--link root "b -- y.txt" "s/rel -- z.txt")
      (let* ((src (f "s/"))
             (target (dired-filetags--tagtrees-target src)))
        (switch-to-buffer (dired-filetags-test--dired src))
        (dired-filetags-test--wait (dired-filetags-tagtrees))
        (pcase-dolist (`(,dir ,link ,tag ,new)
                       '(("a/" "alias -- a.txt" "new" "alias -- a new.txt")
                         ("z/" "rel -- z.txt" "new2" "rel -- z new2.txt")))
          (dired-filetags-test--dired (expand-file-name dir target))
          (dired-filetags-test--goto (expand-file-name (concat dir link) target))
          (should (equal (dired-filetags--targets nil) (list (concat src link))))
          (should (equal (dired-filetags-add (list tag))
                         (list (cons (concat src link) (concat src new)))))
          (should (file-symlink-p (concat src new)))
          (dired-filetags-test--wait (dired-filetags-test--build-process root)))
        (should (equal (dired-filetags-test--names (f "elsewhere/")) '("real.txt")))
        (should (equal (dired-filetags-test--names src)
                       '("alias -- a new.txt" "b -- y.txt" "rel -- z new2.txt")))
        (should (equal (dired-filetags-test--contents (f "s/alias -- a new.txt")) "REAL"))
        ;; ; o lands on the entry in the source, not on its target.
        (dired-filetags-test--dired (expand-file-name "new/" target))
        (dired-filetags-test--goto (expand-file-name "new/alias -- a new.txt" target))
        (dired-filetags-visit-original)
        (should (equal (dired-get-filename nil t) (concat src "alias -- a new.txt")))))))

(ert-deftest dired-filetags-tagtrees-inside-tagging-follows-the-source-spelling ()
  "Tagging in a tree of a symlinked source updates that source's buffers."
  (skip-unless (executable-find "filetags"))
  (dired-filetags-test--with-dir (("Documents/org/notes -- x.txt" . "v1"))
    (cl-flet ((f (name) (expand-file-name name root)))
      (dired-filetags-test--link root "Documents/org" "org")
      (let* ((create-lockfiles nil)
             (make-backup-files nil)
             (find-file-visit-truename nil)
             (src (f "org/"))
             (target (dired-filetags--tagtrees-target src))
             (visit (find-file-noselect (f "org/notes -- x.txt")))
             (srcbuf (dired-filetags-test--dired src)))
        (with-current-buffer visit (goto-char (point-max)) (insert " v2"))
        (switch-to-buffer srcbuf)
        (dired-filetags-test--wait (dired-filetags-tagtrees))
        (dired-filetags-test--dired (expand-file-name "x/" target))
        (dired-filetags-test--goto (expand-file-name "x/notes -- x.txt" target))
        (should (equal (dired-filetags--targets nil) (list (f "org/notes -- x.txt"))))
        (dired-filetags-add '("w"))
        (dired-filetags-test--wait (dired-filetags-test--build-process root))
        (should (equal (buffer-file-name visit) (f "org/notes -- x w.txt")))
        (should (buffer-modified-p visit))
        (with-current-buffer srcbuf
          (should (dired-goto-file (f "org/notes -- x w.txt")))
          (should-not (dired-goto-file (f "org/notes -- x.txt"))))
        ;; ; o reuses the source's own Dired buffer.
        (dired-filetags-test--dired (expand-file-name "w/" target))
        (dired-filetags-test--goto (expand-file-name "w/notes -- x w.txt" target))
        (dired-filetags-visit-original)
        (should (eq (current-buffer) srcbuf))
        (with-current-buffer visit (save-buffer))
        (should (equal (dired-filetags-test--names (f "Documents/org/")) '("notes -- x w.txt")))))))

(ert-deftest dired-filetags-tagtrees-build-leaves-a-wdired-edit-alone ()
  "A build that finishes while its origin buffer is in wdired does not visit the tree."
  (dired-filetags-test--with-dir ("s/a -- x.txt" "s/b.txt")
    (let* ((src (expand-file-name "s/" root))
           (dired-filetags-program
            (dired-filetags-test--script
             root "build" "mkdir -p \"$4\" && : > \"$4/.filetags_tagtrees\"\n"))
           (buf (dired-filetags-test--dired src)))
      (switch-to-buffer buf)
      (let ((proc (dired-filetags-tagtrees)))
        (wdired-change-to-wdired-mode)
        (unwind-protect
            (progn
              (dired-filetags-test--wait proc)
              (should (file-exists-p (dired-filetags--sidecar (dired-filetags--tagtrees-target src))))
              (should (eq (window-buffer (selected-window)) buf))
              (should (eq major-mode 'wdired-mode)))
          (with-current-buffer buf (wdired-abort-changes)))))))

(defmacro dired-filetags-test--with-fake-vertico (&rest body)
  "Run BODY with the tag prompt's RET behaving like `vertico-exit'.
After a trailing separator, vertico fills the empty tag with the
highlighted candidate, \"work\" until \\`C-n' moves to \"x\" and, as
`vertico-next' does, sets `vertico--lock-candidate'."
  (declare (indent 0) (debug t))
  `(minibuffer-with-setup-hook
       (lambda ()
         (let ((map (make-sparse-keymap))
               (highlighted "work"))
           (set-keymap-parent map (current-local-map))
           (keymap-set map "C-n" (lambda ()
                                   (interactive)
                                   (setq highlighted "x")
                                   (setq-local vertico--lock-candidate t)))
           (keymap-set map "RET" (lambda ()
                                   (interactive)
                                   (when (string-match-p "[ ,]\\'" (minibuffer-contents))
                                     (goto-char (point-max))
                                     (insert highlighted))
                                   (exit-minibuffer)))
           (use-local-map map)))
     ,@body))

(defmacro dired-filetags-test--typing (keys &rest body)
  "Type KEYS in the current Dired buffer; return the tags BODY's command read.
The tagging itself is stubbed out, so no file is renamed."
  (declare (indent 1) (debug (form body)))
  `(let ((read nil)
         (minibuffer-message-timeout 0))
     (cl-letf (((symbol-function 'dired-filetags--retag)
                (lambda (_files fn) (push (funcall fn nil nil) read) nil)))
       ,@body
       ;; The command loop reads keys in the selected window's buffer.
       (switch-to-buffer (current-buffer))
       (execute-kbd-macro (kbd ,keys)))
     (let ((change (car read))) (or (car change) (cdr change)))))

(ert-deftest dired-filetags-read-trailing-separator-adds-nothing ()
  "RET after a trailing space or comma submits only the tags typed."
  (dired-filetags-test--with-dir ("a -- work x.txt" "b.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-mode 1)
    (dired-filetags-test--goto (expand-file-name "b.txt" root))
    (dired-filetags-test--with-fake-vertico
      (should (equal (dired-filetags-test--typing "; a x SPC RET") '("x"))))
    (dired-filetags-test--with-fake-vertico
      (should (equal (dired-filetags-test--typing "; a y , RET") '("y"))))
    ;; Without a trailing separator, RET is the completion UI's own.
    (dired-filetags-test--with-fake-vertico
      (should (equal (dired-filetags-test--typing "; a x SPC w RET") '("x" "w"))))
    ;; A candidate the user moved to after the separator is taken.
    (dired-filetags-test--with-fake-vertico
      (should (equal (dired-filetags-test--typing "; a new SPC C-n RET") '("new" "x"))))
    ;; A required match is still enforced: the typo is not submitted.
    ;; `dired-filetags-remove' has no key, so this test gives it one,
    ;; active in the Dired buffer only.
    (dired-filetags-test--goto (expand-file-name "a -- work x.txt" root))
    (let ((minor-mode-map-alist
           (cons (cons 'dired-filetags-mode (define-keymap "C-c r" #'dired-filetags-remove))
                 minor-mode-map-alist)))
      (dired-filetags-test--with-fake-vertico
        (should (equal (dired-filetags-test--typing "C-c r nosuch SPC RET C-a C-k x SPC RET")
                       '("x")))))))

(ert-deftest dired-filetags-read-space-separates-under-default-completion ()
  "SPC inserts a separator even where default completion would complete a word."
  (dired-filetags-test--with-dir ("a -- work x.txt" "b.txt")
    (dired-filetags-test--dired root)
    (dired-filetags-mode 1)
    (dired-filetags-test--goto (expand-file-name "b.txt" root))
    (should (equal (dired-filetags-test--typing "; a new SPC tag RET") '("new" "tag")))
    (should (equal (dired-filetags-test--typing "; a new , tag RET") '("new" "tag")))))

(ert-deftest dired-filetags-read-arguments-classify-each-file-once ()
  "Reading a tagging command's arguments examines each target once."
  (dired-filetags-test--with-dir ("a -- x.txt" "b.txt" "c -- y.txt")
    (let* ((files (mapcar (lambda (n) (expand-file-name n root)) '("a -- x.txt" "b.txt" "c -- y.txt")))
           (calls 0)
           (orig (symbol-function 'file-regular-p)))
      (dired-filetags-test--dired root)
      (dired-filetags-test--mark-files files)
      (dired-filetags-test--with-crm (crm '("z"))
        (cl-letf (((symbol-function 'file-regular-p)
                   (lambda (file) (when (member file files) (cl-incf calls)) (funcall orig file))))
          (dolist (candidates (list #'dired-filetags--add-candidates
                                    #'dired-filetags--add-remove-candidates))
            (setq calls 0)
            (should (equal (dired-filetags--read-arguments "Add tags to" candidates)
                           (list '("z") files)))
            (should (= calls (length files)))))))))

(ert-deftest dired-filetags-render-decorates-only-basenames-of-file-lists ()
  "In an explicit file-list buffer, only the basename of a listed path is parsed."
  (dired-filetags-test--with-dir ("sub -- proj/inner.txt" "sub -- proj/Report -- work.pdf")
    (let ((files '("sub -- proj/inner.txt" "sub -- proj/Report -- work.pdf")))
      (set-buffer (dired-noselect (cons root files)))
      (dired-filetags-mode 1)
      (dired-filetags-test--fontify)
      (dired-filetags-test--goto (expand-file-name (car files) root))
      (should-not (dired-filetags-test--line-overlays))
      (let ((b (dired-filetags-test--start root (cadr files))))
        (should (equal (substring-no-properties
                        (overlay-get (dired-filetags-test--overlay-at (+ b 18) (+ b 19)) 'display))
                       ".pdf"))
        ;; 32 - (12 "sub -- proj/" + 6 "Report" + 4 ".pdf")
        (should (equal (overlay-get (dired-filetags-test--overlay-at (+ b 19) (+ b 22)) 'display)
                       '(space :width 10)))
        (should (dired-filetags-test--pill-p (dired-filetags-test--overlay-at (+ b 22) (+ b 26))))
        (should (= (length (dired-filetags-test--line-overlays)) 4)))
      (should (equal (dired-filetags--buffer-tags) '(("work" . 1)))))))

(ert-deftest dired-filetags-tag-face-without-colours-is-plain ()
  "With no tag colours, labels use the plain face, and decoration still works."
  (let ((dired-filetags-tag-colors nil))
    (should (eq (dired-filetags--tag-face "work") 'dired-filetags-tag))
    (let ((dired-filetags-tag-faces '(("urgent" . error))))
      (should (equal (dired-filetags--tag-face "urgent") '(error dired-filetags-tag))))
    (dired-filetags-test--with-render
      (dired-filetags-test--fontify)
      (dired-filetags-test--goto (expand-file-name "Report -- work urgent.pdf" root))
      (should (= (length (dired-filetags-test--line-overlays)) 5)))))

(provide 'dired-filetags-test)
;;; dired-filetags-test.el ends here
