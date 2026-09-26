;;; leak-check.el --- Per-test leak check for the ERT suite -*- lexical-binding: t; -*-

;;; Commentary:

;; The closest meaningful analogue of a memory sanitizer for this
;; package.  ASan and MSan instrument C code, and here they would test
;; Emacs's own C core, not the package.  Lisp objects are garbage
;; collected, so what an Emacs Lisp test can leak is whatever it leaves
;; reachable from global state, where it outlives the test in the
;; user's session.  This harness checks each test for:
;;
;; - live buffers it made, and processes;
;; - buffers and processes it left for the test fixture to kill: when
;;   `dired-filetags-test--with-dir' ends, it kills every buffer whose
;;   directory is below its own, and stops the TagTrees builds of trees
;;   there, so the check looks just before it does.  A buffer the
;;   package makes while a Dired buffer is current inherits that
;;   directory, and would otherwise be killed unseen.  What a test
;;   legitimately leaves the fixture is exempt: Dired and wdired buffers
;;   on a directory below the fixture's, buffers visiting a file there,
;;   the fixture's log buffer, the buffers of the builds it stops, and
;;   the fixture's own temporary buffer;
;; - timers, idle ones too;
;; - package functions (any symbol whose name starts with
;;   "dired-filetags") and anonymous functions (closures, lambdas,
;;   compiled code) gained or lost by the default value of a `*-hook',
;;   `*-hooks' or `*-functions' variable, or by its buffer-local value
;;   in a buffer that existed before the test;
;; - entries gained or lost by `file-name-handler-alist';
;; - overlays with a `dired-filetags' property in buffers that existed
;;   before the test;
;; - files left in the temporary directory, and files left in the
;;   temporary directory of `dired-filetags-test--with-dir', which the
;;   fixture redirects below its own directory and then deletes;
;; - changed bindings in `global-map', `dired-mode-map' and the
;;   package's keymaps, prefix maps included;
;; - changed values of the package's variables (every option,
;;   `dired-filetags--bound-prefix', the history, ...), of every
;;   minibuffer history, of the `kill-ring', of `process-environment'
;;   and of `exec-path'.  Values are compared by contents, including
;;   the contents of any hash table they hold, so a table that grows
;;   in place is a change;
;; - functions whose names start with "dired-filetags" that were
;;   defined, redefined or undefined;
;; - advice added with `advice-add' and not removed.
;;
;; Run it after loading the suite:
;;
;;   ${EMACS:-emacs} --batch -Q -L . --eval '(setq load-prefer-newer t)' \
;;     -l ert -l dired-filetags-test.el -l scripts/leak-check.el \
;;     -f dired-filetags-leak-check-batch-and-exit [SELECTOR]
;;
;; SELECTOR is a test-name regexp, or an ERT selector written in Lisp
;; when it starts with "("; without one every test runs.  Advice on
;; `ert-run-test' takes a snapshot before each test and compares it with
;; one taken afterwards; anything new that is still alive is a leak of
;; that test.  At the end the leaks are printed per test, followed by a
;; memory summary that is for information only.  Emacs exits with status
;; 1 if a test had an unexpected result or anything leaked, and 2 if the
;; run itself failed.
;;
;; The run gets a private `temporary-file-directory', and TMPDIR for
;; child processes, below the real one.  So the file check sees every
;; file the suite leaves there, not only those with a known prefix, and
;; the ERT, coverage and fuzz runs that lefthook starts alongside, which
;; share the real temporary directory, cannot disturb it.
;;
;; Only residue that Emacs itself creates lazily and keeps is
;; allowlisted, each entry with its reason.  Never run this under
;; undercover, whose instrumentation keeps a buffer on the source.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ert)

(declare-function dired-filetags-test--in-root-p "dired-filetags-test" (root file))
(defvar dired-log-buffer)

;;;; Allowlists

(defconst dired-filetags-leak-check--buffer-allowlist
  '(("\\` \\*string-pixel-width\\*\\'"
     . "`string-pixel-width' makes it on first use and keeps it for reuse")
    ("\\` \\*Minibuf-[0-9]+\\*\\'"
     . "Emacs makes the minibuffer of each depth on its first use and keeps it")
    ("\\` \\*code-conversion-work\\*"
     . "Emacs decodes text in this work buffer, made on first use and kept for reuse")
    ("\\`\\*vc\\*\\'"
     . "VC runs its commands in this buffer, made on first use and kept for the next")
    ("\\` \\*work\\*"
     . "`with-work-buffer' keeps up to `work-buffer-limit' of these for reuse (Emacs 31)"))
  "Buffers Emacs creates lazily and keeps, as (REGEXP . REASON).")

(defconst dired-filetags-leak-check--timer-allowlist
  '((undo-auto--boundary-timer
     . "the first undoable change arms Emacs's one-shot undo boundary timer")
    (completions--background-update
     . "the minibuffer arms this idle timer (Emacs 31), which a batch Emacs never runs"))
  "Timer functions Emacs starts lazily, as (FUNCTION . REASON).")

(defconst dired-filetags-leak-check--handler-allowlist
  '((tramp-file-name-handler
     . "tramp installs its handlers when it is first loaded")
    (tramp-completion-file-name-handler
     . "tramp installs its handlers when it is first loaded")
    (tramp-autoload-file-name-handler
     . "loading tramp replaces this autoload handler with the real ones")
    (tramp-archive-file-name-handler
     . "with D-Bus, as on Linux, loading tramp installs the archive handler")
    (tramp-archive-autoload-file-name-handler
     . "with D-Bus, loading tramp replaces this autoload archive handler"))
  "File name handlers Emacs installs lazily, as (HANDLER . REASON).")

(defconst dired-filetags-leak-check--preloaded-features
  '((edebug
     . "loading it binds C-x X in `global-map' and advises `eval-defun'")
    (tramp-sh
     . "tests of remote names load tramp's ssh method, which adds closures to tramp's hooks")
    (tramp-cache
     . "tramp loads it on first use, and it adds closures to tramp's own hooks"))
  "Libraries loaded before the first test, as (FEATURE . REASON).
A test that loads one of these for the first time would otherwise be
blamed for the global changes the library makes when it loads.")

(defconst dired-filetags-leak-check--global-variables
  '(process-environment exec-path kill-ring)
  "Global variables compared along with the package's own.
Every minibuffer history is compared too; see
`dired-filetags-leak-check--scan'.")

(defconst dired-filetags-leak-check--global-keymaps
  '(global-map dired-mode-map)
  "Keymap variables compared along with the package's own.")

;;;; State

(defvar dired-filetags-leak-check--temp-dir nil
  "The private temporary directory of this run.")

(defvar dired-filetags-leak-check--leaks nil
  "The leaks found so far, as (TEST-NAME . DESCRIPTIONS), latest first.")

(defvar dired-filetags-leak-check--advised nil
  "The (SYMBOL . FUNCTION) pairs `advice-add' installed in this test.")

(defvar dired-filetags-leak-check--running nil
  "Non-nil while a checked test runs, so nested tests are not checked.")

(defvar dired-filetags-leak-check--fixture-leaks nil
  "Descriptions of what the test left for its fixture to delete or kill.")

(defvar dired-filetags-leak-check--before nil
  "The snapshot taken before the test that runs.")

(cl-defstruct (dired-filetags-leak-check--snapshot
               (:constructor dired-filetags-leak-check--make-snapshot)
               (:copier nil))
  "The global state that a test must leave as it found it."
  buffers processes timers hooks local-hooks handlers overlays files keymaps
  variables functions)

;;;; Snapshots

;; One `apropos-internal' scan of the obarray, in C, finds every
;; symbol that snapshots compare; four separate scans cost twice as much.
(defconst dired-filetags-leak-check--symbol-regexp
  "\\`dired-filetags\\|-\\(?:hooks?\\|functions\\|history\\)\\'"
  "Regexp matching the names of the symbols that snapshots compare.")

(defun dired-filetags-leak-check--ours-p (object)
  "Return non-nil if OBJECT is a symbol named like this package's."
  (and (symbolp object)
       (string-prefix-p "dired-filetags" (symbol-name object))))

(defun dired-filetags-leak-check--scan ()
  "Return the symbols that snapshots compare, as (HOOKS VARIABLES FUNCTIONS).
HOOKS are the bound variables named `*-hook', `*-hooks' or
`*-functions', other than aliases of another variable, such as the
obsolete `find-file-hooks', which would report each change twice.
VARIABLES are the bound variables named `dired-filetags-*', and every
minibuffer history, any variable named `*-history' except
`load-history', which records the files loaded.  FUNCTIONS are the
functions named `dired-filetags*'.  The harness's own symbols are left
out."
  (let ((hooks nil)
        (variables nil)
        (functions nil))
    (dolist (sym (apropos-internal dired-filetags-leak-check--symbol-regexp))
      (let ((name (symbol-name sym)))
        (unless (or (eq sym 'load-history)
                    (string-prefix-p "dired-filetags-leak-check-" name))
          (when (default-boundp sym)
            (when (and (string-match-p "-\\(?:hooks?\\|functions\\)\\'" name)
                       (eq (indirect-variable sym) sym))
              (push sym hooks))
            (when (or (string-prefix-p "dired-filetags-" name)
                      (string-suffix-p "-history" name))
              (push sym variables)))
          (when (and (fboundp sym) (string-prefix-p "dired-filetags" name))
            (push sym functions)))))
    (list hooks variables functions)))

(defun dired-filetags-leak-check--hook-member-p (object)
  "Return non-nil if OBJECT, a member of a hook, is compared.
That is a package function, named like this package's, or any
anonymous function: a closure or lambda, interpreted or compiled,
which can call the package without naming it.  Other named functions
come and go as Emacs loads libraries."
  (or (dired-filetags-leak-check--ours-p object)
      (and (not (symbolp object)) (functionp object))))

(defun dired-filetags-leak-check--hook-members (hooks)
  "Return (HOOK . FUNCTION) for each compared function on one of HOOKS.
See `dired-filetags-leak-check--hook-member-p'.  Only the default value
of each hook counts."
  (let ((members nil))
    (dolist (hook hooks)
      (let ((value (default-value hook)))
        (dolist (fn (if (and (listp value) (not (functionp value)))
                        value
                      (list value)))
          (when (dired-filetags-leak-check--hook-member-p fn)
            (push (cons hook fn) members)))))
    members))

(defun dired-filetags-leak-check--local-hook-members (hooks)
  "Return (BUFFER HOOK . FUNCTION) for each compared function on one of HOOKS.
That is every function that `dired-filetags-leak-check--hook-member-p'
compares on the buffer-local value of one of HOOKS in a live buffer."
  (let ((wanted (make-hash-table :test #'eq))
        (members nil))
    (dolist (hook hooks) (puthash hook t wanted))
    (dolist (buffer (buffer-list))
      (dolist (binding (buffer-local-variables buffer))
        (when (and (consp binding) (gethash (car binding) wanted))
          (let ((value (cdr binding)))
            (dolist (fn (if (and (listp value) (not (functionp value)))
                            value
                          (list value)))
              (when (dired-filetags-leak-check--hook-member-p fn)
                (push (cons buffer (cons (car binding) fn)) members)))))))
    members))

(defun dired-filetags-leak-check--overlays ()
  "Return the live overlays with a `dired-filetags' property."
  (let ((overlays nil))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (save-restriction
          (widen)
          (dolist (ov (overlays-in (point-min) (point-max)))
            (when (overlay-get ov 'dired-filetags)
              (push ov overlays))))))
    overlays))

(defun dired-filetags-leak-check--files ()
  "Return the entries of the private temporary directory."
  (directory-files dired-filetags-leak-check--temp-dir nil
                   directory-files-no-dot-files-regexp t))

(defun dired-filetags-leak-check--submap (binding)
  "Return the keymap that BINDING leads to, or nil.
A symbol or a menu item can lead to a keymap.  An autoloaded keymap
is not followed, as that would load its library."
  (let ((def (if (eq (car-safe binding) 'menu-item)
                 (nth 2 binding)
               binding)))
    (when (symbolp def)
      (setq def (indirect-function def)))
    (and (keymapp def) def)))

(defun dired-filetags-leak-check--walk (map prefix seen record)
  "Call RECORD with (KEYS BINDING) for every binding reachable from MAP.
PREFIX is the key vector that leads to MAP.  SEEN is a hash table of
the maps walked so far; each map is walked once."
  (unless (gethash map seen)
    (puthash map t seen)
    (map-keymap
     (lambda (event binding)
       (let ((keys (vconcat prefix (list event)))
             (submap (dired-filetags-leak-check--submap binding)))
         (cond (submap
                (dired-filetags-leak-check--walk submap keys seen record))
               (binding
                (funcall record keys (copy-tree binding t))))))
     map)))

(defun dired-filetags-leak-check--bindings (map)
  "Return the bindings reachable from keymap MAP, as (KEYS . BINDING)."
  (let ((bindings nil))
    (dired-filetags-leak-check--walk
     map [] (make-hash-table :test #'eq)
     (lambda (keys binding) (push (cons keys binding) bindings)))
    (nreverse bindings)))

(defconst dired-filetags-leak-check--freeze-depth 40
  "How deep `dired-filetags-leak-check--freeze' copies nested values.")

(defun dired-filetags-leak-check--freeze (value &optional depth ancestors)
  "Return a copy of VALUE that `equal' compares by contents.
Conses, vectors and records are copied; a hash table becomes a list
\=(hash-table TEST WEAKNESS . ENTRIES), its entries sorted by their
printed keys, since `equal' compares hash tables by identity.  DEPTH
counts the levels copied so far, and ANCESTORS holds the objects being
copied, so a circular or very deep value ends in the object itself."
  (let ((depth (or depth 0)))
    (cond
     ((or (>= depth dired-filetags-leak-check--freeze-depth)
          (memq value ancestors))
      value)
     ((hash-table-p value)
      (let ((ancestors (cons value ancestors))
            (entries nil))
        (maphash (lambda (key val)
                   (push (cons (dired-filetags-leak-check--freeze key (1+ depth) ancestors)
                               (dired-filetags-leak-check--freeze val (1+ depth) ancestors))
                         entries))
                 value)
        (append (list 'hash-table (hash-table-test value) (hash-table-weakness value))
                (sort entries
                      (lambda (a b) (string< (prin1-to-string (car a))
                                             (prin1-to-string (car b))))))))
     ((consp value)
      ;; A list is copied along its spine, so a long one costs no depth.
      (let ((ancestors (cons value ancestors))
            (length (safe-length value))
            (copy nil)
            (tail value))
        (dotimes (_ length)
          (push (dired-filetags-leak-check--freeze (car tail) (1+ depth) ancestors) copy)
          (setq tail (cdr tail)))
        (nconc (nreverse copy)
               (and tail (if (consp tail)
                             'circular
                           (dired-filetags-leak-check--freeze tail (1+ depth) ancestors))))))
     ((or (and (vectorp value) (not (bool-vector-p value))) (recordp value))
      (let ((ancestors (cons value ancestors))
            (copy (copy-sequence value)))
        (dotimes (i (length copy))
          (aset copy i (dired-filetags-leak-check--freeze (aref copy i) (1+ depth) ancestors)))
        copy))
     (t value))))

(defun dired-filetags-leak-check--take ()
  "Return a snapshot of the global state."
  (let* ((scan (dired-filetags-leak-check--scan))
         (keymaps nil)
         (variables nil))
    (dolist (var (delete-dups
                  (append dired-filetags-leak-check--global-keymaps
                          dired-filetags-leak-check--global-variables
                          (nth 1 scan))))
      (when (default-boundp var)
        (let ((value (default-value var)))
          (if (and (keymapp value) (not (symbolp value)))
              (push (cons var (dired-filetags-leak-check--bindings value))
                    keymaps)
            (push (cons var (dired-filetags-leak-check--freeze value)) variables)))))
    (dired-filetags-leak-check--make-snapshot
     :buffers (buffer-list)
     :processes (process-list)
     :timers (append timer-list timer-idle-list nil)
     :hooks (dired-filetags-leak-check--hook-members (nth 0 scan))
     :local-hooks (dired-filetags-leak-check--local-hook-members (nth 0 scan))
     :handlers (copy-sequence (default-value 'file-name-handler-alist))
     :overlays (dired-filetags-leak-check--overlays)
     :files (dired-filetags-leak-check--files)
     :keymaps keymaps
     :variables variables
     :functions (mapcar (lambda (fn) (cons fn (symbol-function fn)))
                        (nth 2 scan)))))

;;;; Comparison

(defun dired-filetags-leak-check--allowed-p (key allowlist)
  "Return non-nil if KEY is on ALLOWLIST, an alist of (KEY . REASON)."
  (assq key allowlist))

(defun dired-filetags-leak-check--allowed-buffer-p (buffer)
  "Return non-nil if BUFFER's name matches the buffer allowlist."
  (cl-some (lambda (entry) (string-match-p (car entry) (buffer-name buffer)))
           dired-filetags-leak-check--buffer-allowlist))

(defun dired-filetags-leak-check--show (object)
  "Return OBJECT printed, shortened to one line of at most 70 characters."
  (let ((text (replace-regexp-in-string "\n" "\\\\n" (prin1-to-string object))))
    (if (> (length text) 70)
        (concat (substring text 0 67) "...")
      text)))

(defun dired-filetags-leak-check--keys (keys)
  "Return a description of the key vector KEYS."
  (condition-case nil
      (key-description keys)
    (error (prin1-to-string keys))))

(defun dired-filetags-leak-check--keymap-changes (var old new)
  "Describe how keymap VAR's bindings changed from OLD to NEW.
OLD and NEW are lists of (KEYS . BINDING)."
  (let ((before (make-hash-table :test #'equal))
        (after (make-hash-table :test #'equal))
        (changes nil))
    (dolist (entry old) (puthash (car entry) (cdr entry) before))
    (dolist (entry new) (puthash (car entry) (cdr entry) after))
    (maphash (lambda (keys binding)
               (let ((was (gethash keys before 'unbound)))
                 (unless (equal was binding)
                   (push (format "keymap %s: %s bound to %s (was %s)"
                                 var (dired-filetags-leak-check--keys keys)
                                 (dired-filetags-leak-check--show binding)
                                 (if (eq was 'unbound)
                                     "unbound"
                                   (dired-filetags-leak-check--show was)))
                         changes))))
             after)
    (maphash (lambda (keys binding)
               (when (eq (gethash keys after 'unbound) 'unbound)
                 (push (format "keymap %s: %s unbound (was %s)"
                               var (dired-filetags-leak-check--keys keys)
                               (dired-filetags-leak-check--show binding))
                       changes)))
             before)
    (sort changes #'string<)))

(defun dired-filetags-leak-check--environment-change (old new)
  "Describe how `process-environment' changed from OLD to NEW.
Only the names of the environment variables are shown, as their
values can be secrets.  An entry without \"=\" unsets its variable."
  (let* ((name (lambda (entry) (car (split-string entry "="))))
         (added (cl-set-difference new old :test #'equal))
         (removed (mapcar name (cl-set-difference old new :test #'equal)))
         (assigned (mapcar name (cl-remove-if-not
                                 (lambda (entry) (string-search "=" entry))
                                 added)))
         (unset (mapcar name (cl-remove-if
                              (lambda (entry) (string-search "=" entry))
                              added)))
         (parts nil))
    (dolist (part (list (cons "set" (cl-set-difference assigned removed
                                                       :test #'equal))
                        (cons "changed" (cl-intersection assigned removed
                                                         :test #'equal))
                        (cons "unset" (cl-union
                                       unset
                                       (cl-set-difference removed
                                                          (append assigned
                                                                  unset)
                                                          :test #'equal)
                                       :test #'equal))))
      (when (cdr part)
        (push (format "%s %s" (car part)
                      (string-join (sort (cdr part) #'string<) " "))
              parts)))
    (format "variable process-environment changed: %s"
            (string-join (nreverse parts) "; "))))

(defun dired-filetags-leak-check--variable-changes (old new)
  "Describe how the variables in alist NEW changed from those in OLD.
Both map each variable to its value.  A variable bound in only one
of them counts too, unless it is new and holds nil."
  (let ((changes nil))
    (dolist (entry new)
      (let ((var (car entry))
            (was (assq (car entry) old)))
        (cond ((null was)
               ;; A library loaded during the test defines variables;
               ;; one that holds nil holds nothing the test left.
               (when (cdr entry)
                 (push (format "variable %s became bound to %s" var
                               (dired-filetags-leak-check--show (cdr entry)))
                       changes)))
              ((equal (cdr was) (cdr entry)))
              ((eq var 'process-environment)
               (push (dired-filetags-leak-check--environment-change
                      (cdr was) (cdr entry))
                     changes))
              (t
               (push (format "variable %s changed from %s to %s" var
                             (dired-filetags-leak-check--show (cdr was))
                             (dired-filetags-leak-check--show (cdr entry)))
                     changes)))))
    (dolist (entry old)
      (unless (assq (car entry) new)
        (push (format "variable %s is no longer bound" (car entry)) changes)))
    (nreverse changes)))

(defun dired-filetags-leak-check--compare (before after advised)
  "Return descriptions of what AFTER leaked relative to BEFORE.
ADVISED lists the (SYMBOL . FUNCTION) pairs added with `advice-add'
in between."
  (let* ((leaks nil)
         (old-buffers (dired-filetags-leak-check--snapshot-buffers before))
         (old-overlays (dired-filetags-leak-check--snapshot-overlays before))
         (old-timers (dired-filetags-leak-check--snapshot-timers before))
         (old-processes (dired-filetags-leak-check--snapshot-processes before))
         (old-hooks (dired-filetags-leak-check--snapshot-hooks before))
         (new-hooks (dired-filetags-leak-check--snapshot-hooks after))
         (old-handlers (dired-filetags-leak-check--snapshot-handlers before))
         (new-handlers (dired-filetags-leak-check--snapshot-handlers after))
         (old-files (dired-filetags-leak-check--snapshot-files before)))
    (dolist (buffer (dired-filetags-leak-check--snapshot-buffers after))
      (unless (or (memq buffer old-buffers)
                  (not (buffer-live-p buffer))
                  (dired-filetags-leak-check--allowed-buffer-p buffer))
        (push (format "buffer %S (%s, in %s)" (buffer-name buffer)
                      (buffer-local-value 'major-mode buffer)
                      (buffer-local-value 'default-directory buffer))
              leaks)))
    (dolist (process (dired-filetags-leak-check--snapshot-processes after))
      (unless (memq process old-processes)
        (push (format "process %S (%s, %s)" (process-name process)
                      (process-status process)
                      (dired-filetags-leak-check--show
                       (process-command process)))
              leaks)))
    (dolist (timer (dired-filetags-leak-check--snapshot-timers after))
      (let ((fn (timer--function timer)))
        (unless (or (memq timer old-timers)
                    (dired-filetags-leak-check--allowed-p
                     fn dired-filetags-leak-check--timer-allowlist))
          (push (format "timer calling %s"
                        (dired-filetags-leak-check--show fn))
                leaks))))
    (dolist (pair new-hooks)
      (unless (member pair old-hooks)
        (push (format "hook %s gained %s" (car pair)
                      (dired-filetags-leak-check--show (cdr pair)))
              leaks)))
    (dolist (pair old-hooks)
      (unless (member pair new-hooks)
        (push (format "hook %s lost %s" (car pair)
                      (dired-filetags-leak-check--show (cdr pair)))
              leaks)))
    (let ((old-local (dired-filetags-leak-check--snapshot-local-hooks before))
          (new-local (dired-filetags-leak-check--snapshot-local-hooks after)))
      ;; Only in buffers that existed before the test and still live: a
      ;; buffer the test made, and its hooks, is a leak of its own.
      (dolist (entry new-local)
        (when (and (memq (car entry) old-buffers)
                   (not (member entry old-local)))
          (push (format "hook %s in buffer %S gained %s" (cadr entry)
                        (buffer-name (car entry))
                        (dired-filetags-leak-check--show (cddr entry)))
                leaks)))
      (dolist (entry old-local)
        (when (and (buffer-live-p (car entry))
                   (not (member entry new-local)))
          (push (format "hook %s in buffer %S lost %s" (cadr entry)
                        (buffer-name (car entry))
                        (dired-filetags-leak-check--show (cddr entry)))
                leaks))))
    (dolist (entry new-handlers)
      (unless (or (member entry old-handlers)
                  (dired-filetags-leak-check--allowed-p
                   (cdr entry) dired-filetags-leak-check--handler-allowlist))
        (push (format "file-name-handler-alist gained %s for %s" (cdr entry)
                      (dired-filetags-leak-check--show (car entry)))
              leaks)))
    (dolist (entry old-handlers)
      (unless (or (member entry new-handlers)
                  (dired-filetags-leak-check--allowed-p
                   (cdr entry) dired-filetags-leak-check--handler-allowlist))
        (push (format "file-name-handler-alist lost %s for %s" (cdr entry)
                      (dired-filetags-leak-check--show (car entry)))
              leaks)))
    (dolist (ov (dired-filetags-leak-check--snapshot-overlays after))
      (let ((buffer (overlay-buffer ov)))
        (when (and buffer
                   (memq buffer old-buffers)
                   (not (memq ov old-overlays)))
          (push (format "overlay in buffer %S at %d-%d" (buffer-name buffer)
                        (overlay-start ov) (overlay-end ov))
                leaks))))
    (dolist (file (dired-filetags-leak-check--snapshot-files after))
      (unless (member file old-files)
        (push (format "file %s in the temporary directory" file) leaks)))
    (let ((old-keymaps (dired-filetags-leak-check--snapshot-keymaps before)))
      (dolist (entry (dired-filetags-leak-check--snapshot-keymaps after))
        (let ((old (assq (car entry) old-keymaps)))
          (if old
              (setq leaks (append (reverse
                                   (dired-filetags-leak-check--keymap-changes
                                    (car entry) (cdr old) (cdr entry)))
                                  leaks))
            (push (format "keymap %s became bound" (car entry)) leaks)))))
    (setq leaks (append (reverse
                         (dired-filetags-leak-check--variable-changes
                          (dired-filetags-leak-check--snapshot-variables before)
                          (dired-filetags-leak-check--snapshot-variables after)))
                        leaks))
    (let ((old-functions (dired-filetags-leak-check--snapshot-functions
                          before)))
      (dolist (entry (dired-filetags-leak-check--snapshot-functions after))
        (let ((was (assq (car entry) old-functions)))
          (cond ((null was)
                 (push (format "function %s became defined" (car entry))
                       leaks))
                ((not (eq (cdr was) (cdr entry)))
                 (push (format "function %s was redefined" (car entry))
                       leaks)))))
      (dolist (entry old-functions)
        (unless (fboundp (car entry))
          (push (format "function %s became undefined" (car entry)) leaks))))
    (dolist (pair (reverse advised))
      (when (advice-member-p (cdr pair) (car pair))
        (push (format "advice %s on %s"
                      (dired-filetags-leak-check--show (cdr pair)) (car pair))
              leaks)))
    (nreverse leaks)))

;;;; Hooks into ERT and nadvice

(defun dired-filetags-leak-check--note-advice (symbol _how function
                                                      &optional _props)
  "Remember that `advice-add' put FUNCTION on SYMBOL during this test."
  (when dired-filetags-leak-check--running
    (push (cons symbol function) dired-filetags-leak-check--advised)))

(defun dired-filetags-leak-check--fixture-kills-p (buffer root buffers)
  "Return non-nil if the test fixture on ROOT will kill BUFFER.
BUFFERS are the buffers that existed when the fixture began.  This is
the condition of `dired-filetags-test--cleanup': a buffer made since
that is the fixture's log buffer, or has a directory below ROOT.  The
fixture kills no other buffer, so any other buffer a test leaves is
still alive afterwards, where the snapshot after the test finds it."
  (and (buffer-live-p buffer)
       (not (memq buffer buffers))
       (or (equal (buffer-name buffer) dired-log-buffer)
           (dired-filetags-test--in-root-p
            root (buffer-local-value 'default-directory buffer)))))

(defun dired-filetags-leak-check--fixture-buffer-p (buffer root stopped fixture)
  "Return non-nil if BUFFER is one a test may leave the fixture on ROOT.
That is a Dired or wdired buffer on a directory below ROOT, a buffer
visiting a file below ROOT, the fixture's log buffer, the buffer of a
process in STOPPED, the builds the fixture stops, or FIXTURE, the
buffer that is current when the fixture cleans up, if it is the
`with-temp-buffer' the fixture runs in (its `save-window-excursion'
makes that buffer current again)."
  (with-current-buffer buffer
    (or (and (or (derived-mode-p 'dired-mode) (eq major-mode 'wdired-mode))
             (dired-filetags-test--in-root-p root default-directory))
        (dired-filetags-test--in-root-p root buffer-file-name)
        (equal (buffer-name) dired-log-buffer)
        (cl-some (lambda (process) (eq (process-buffer process) buffer)) stopped)
        (and (eq buffer fixture) (string-prefix-p " *temp*" (buffer-name))))))

(defun dired-filetags-leak-check--note-fixture (root buffers)
  "Record what the test left for the fixture on ROOT to delete or kill.
This runs before `dired-filetags-test--cleanup' deletes ROOT, kills the
buffers it made on directories below ROOT, and stops the TagTrees
builds of trees below ROOT; BUFFERS are the buffers that existed when
the fixture began.

The fixture redirects the variable `temporary-file-directory' below
ROOT, where the package makes its scratch directories, so what is left
there would otherwise be deleted unseen.  A buffer the package makes
inherits the directory of the current one, which in a test is often a
Dired buffer below ROOT, so a buffer it leaked would be killed unseen
too, with its process: of the buffers the fixture will kill, as
`dired-filetags-leak-check--fixture-kills-p' decides, each is a leak
unless `dired-filetags-leak-check--fixture-buffer-p' says a test may
leave it, or it is on the allowlist; and so is a live process started
during the test whose buffer is such a leak, or is one the fixture
kills, unless it is a build the fixture stops."
  (when dired-filetags-leak-check--running
    (let ((dir (if (and (stringp temporary-file-directory)
                        (string-prefix-p root temporary-file-directory))
                   temporary-file-directory
                 (expand-file-name "tmp/" root)))
          (old-processes (dired-filetags-leak-check--snapshot-processes
                          dired-filetags-leak-check--before))
          (fixture (current-buffer))
          (stopped nil)
          (running nil))
      (when (file-directory-p dir)
        (dolist (file (directory-files dir nil directory-files-no-dot-files-regexp t))
          (push (format "file %s in the temporary directory of the test fixture" file)
                dired-filetags-leak-check--fixture-leaks)))
      (dolist (process (process-list))
        (when (and (process-live-p process) (not (memq process old-processes)))
          (if (dired-filetags-test--in-root-p root (process-get process 'dired-filetags-target))
              (push process stopped)
            (push process running))))
      (dolist (process running)
        (when (dired-filetags-leak-check--fixture-kills-p (process-buffer process) root buffers)
          (push (format "process %S (%s, %s) left for the test fixture to kill with its buffer"
                        (process-name process) (process-status process)
                        (dired-filetags-leak-check--show (process-command process)))
                dired-filetags-leak-check--fixture-leaks)))
      (dolist (buffer (buffer-list))
        (when (and (dired-filetags-leak-check--fixture-kills-p buffer root buffers)
                   (not (dired-filetags-leak-check--allowed-buffer-p buffer))
                   (not (dired-filetags-leak-check--fixture-buffer-p
                         buffer root stopped fixture)))
          (push (format "buffer %S (%s, in %s) left for the test fixture to kill"
                        (buffer-name buffer)
                        (buffer-local-value 'major-mode buffer)
                        (buffer-local-value 'default-directory buffer))
                dired-filetags-leak-check--fixture-leaks))))))

(defun dired-filetags-leak-check--around (run test)
  "Call RUN on TEST between two snapshots and record what TEST leaked."
  (if dired-filetags-leak-check--running
      (funcall run test)
    (let* ((before (dired-filetags-leak-check--take))
           (dired-filetags-leak-check--before before)
           (dired-filetags-leak-check--advised nil)
           (dired-filetags-leak-check--fixture-leaks nil)
           (dired-filetags-leak-check--running t))
      (prog1 (funcall run test)
        (let ((leaks (append (dired-filetags-leak-check--compare
                              before (dired-filetags-leak-check--take)
                              dired-filetags-leak-check--advised)
                             (reverse dired-filetags-leak-check--fixture-leaks))))
          (when leaks
            (push (cons (ert-test-name test) leaks)
                  dired-filetags-leak-check--leaks)))))))

(defun dired-filetags-leak-check--setup ()
  "Give this run a private temporary directory and start checking."
  (setq dired-filetags-leak-check--temp-dir
        (file-name-as-directory
         (make-temp-file "dired-filetags-leak-check-" t)))
  (setq temporary-file-directory dired-filetags-leak-check--temp-dir)
  (setenv "TMPDIR" dired-filetags-leak-check--temp-dir)
  (dolist (entry dired-filetags-leak-check--preloaded-features)
    (require (car entry)))
  (advice-add 'dired-filetags-test--cleanup :before
              #'dired-filetags-leak-check--note-fixture)
  (advice-add 'ert-run-test :around #'dired-filetags-leak-check--around)
  (advice-add 'advice-add :after #'dired-filetags-leak-check--note-advice))

(defun dired-filetags-leak-check--teardown ()
  "Stop checking and delete the private temporary directory."
  (advice-remove 'advice-add #'dired-filetags-leak-check--note-advice)
  (advice-remove 'ert-run-test #'dired-filetags-leak-check--around)
  (advice-remove 'dired-filetags-test--cleanup
                 #'dired-filetags-leak-check--note-fixture)
  (when dired-filetags-leak-check--temp-dir
    (ignore-errors (delete-directory dired-filetags-leak-check--temp-dir t))))

;;;; Report

(defun dired-filetags-leak-check--memory-summary (start)
  "Print a memory summary; START is `memory-use-counts' before the run."
  (let ((names '("conses" "floats" "vector cells" "symbols"
                 "string chars" "intervals" "strings")))
    (message "leak-check: memory, for information only:")
    (message "  allocated during the run:")
    (cl-mapc (lambda (name old new)
               (message "    %-13s %12d" name (- new old)))
             names start (memory-use-counts)))
  (let ((total 0))
    (message "  live after a final garbage collection:")
    (dolist (entry (garbage-collect))
      (let* ((size (nth 1 entry))
             (used (nth 2 entry))
             (bytes (* size used)))
        (setq total (+ total bytes))
        (message "    %-13s %12d objects %10.1f KiB"
                 (car entry) used (/ bytes 1024.0))))
    (message "    %-13s %32.1f MiB" "total" (/ total 1048576.0)))
  (message "  %d garbage collections, %.2f s in total, %d live buffers"
           gcs-done gc-elapsed (length (buffer-list))))

(defun dired-filetags-leak-check--report (stats start)
  "Print the leaks and a memory summary, and return the exit status.
STATS is the result of the ERT run and START `memory-use-counts'
before it."
  (let ((unexpected (ert-stats-completed-unexpected stats))
        (total (ert-stats-total stats))
        (count 0))
    (message "")
    (dolist (test (reverse dired-filetags-leak-check--leaks))
      (message "leak-check: %s leaked:" (car test))
      (dolist (leak (cdr test))
        (setq count (1+ count))
        (message "  %s" leak)))
    (message "leak-check: %d tests, %d unexpected results, %d leaks in %d tests"
             total unexpected count (length dired-filetags-leak-check--leaks))
    (dired-filetags-leak-check--memory-summary start)
    (cond ((zerop total)
           (message "leak-check: FAILED: no test matched the selector")
           1)
          ((or (> unexpected 0) (> count 0))
           (message "leak-check: FAILED")
           1)
          (t
           (message "leak-check: passed")
           0))))

(defun dired-filetags-leak-check--selector (arg)
  "Return the ERT selector that the command-line argument ARG names.
A missing or empty ARG, or \"t\", selects every test; an ARG that
starts with \"(\" is read as a Lisp selector; any other is a regexp."
  (cond ((member arg '(nil "" "t")) t)
        ((string-prefix-p "(" arg) (car (read-from-string arg)))
        (t arg)))

(defun dired-filetags-leak-check-batch-and-exit ()
  "Run the ERT suite with a leak check around each test, then exit Emacs.
The next command-line argument, if any, is the ERT selector: a
test-name regexp, or a Lisp selector when it starts with \"(\".
Exit with status 0 if every test gave its expected result and
nothing leaked, 1 otherwise, and 2 if the run itself failed."
  (unless noninteractive
    (user-error "The leak check runs only in batch Emacs"))
  (setq attempt-stack-overflow-recovery nil
        attempt-orderly-shutdown-on-fatal-signal nil)
  (let ((selector (dired-filetags-leak-check--selector
                   (pop command-line-args-left)))
        (status 2))
    (unwind-protect
        (condition-case err
            (progn
              (when (featurep 'undercover)
                (error "Undercover is loaded; run the leak check without it"))
              (dired-filetags-leak-check--setup)
              (let* ((start (memory-use-counts))
                     (stats (ert-run-tests-batch selector)))
                (dired-filetags-leak-check--teardown)
                (setq status (dired-filetags-leak-check--report stats start))))
          (error
           (message "leak-check: error running the tests: %s"
                    (error-message-string err))))
      (dired-filetags-leak-check--teardown)
      (kill-emacs status))))

;;; leak-check.el ends here
