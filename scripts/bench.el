;;; bench.el --- Benchmarks and performance gates for dired-filetags -*- lexical-binding: t; -*-

;;; Commentary:

;; Measures the hot paths of dired-filetags.el, writes a profiling
;; report, and compares the numbers with baselines/perf.eld.  Run it
;; from the project root in a fresh Emacs:
;;
;;   ${EMACS:-emacs} -Q --batch -L . -l scripts/bench.el \
;;     -f dired-filetags-bench-batch [OPTION...]
;;
;;   --report DIR    write perf.txt, perf.eld, elp.txt, profile.txt,
;;                   cpu.prof and mem.prof to DIR
;;   --gate MODE     none (the default), alloc, time or all
;;   --results FILE  gate, or with --update record the allocation
;;                   baseline, from a perf.eld that --report wrote,
;;                   instead of measuring
;;   --update        record this system's allocation baseline and this
;;                   machine's timing baseline, the median of three
;;                   Emacs processes
;;   --samples N     timing samples per workload (5)
;;   --results-out FILE
;;                   write the results, as --report writes perf.eld,
;;                   to FILE, and nothing else
;;   --single-process
;;                   measure in this Emacs only: a timing failure is not
;;                   confirmed in new processes (the ones that --update
;;                   and a failed gate start pass it)
;;   --system SYS    the system key; default $DIRED_FILETAGS_SYSTEM,
;;                   else derived from uname, as coverage.sh does
;;
;; The exit status is 0 unless an error occurs or a gate fails.  A gate
;; fails, rather than compare nothing, if baselines/perf.eld is missing,
;; if it has no allocation entry for the system, or if the entry it has
;; for the system (or for this machine's timings) was recorded with
;; another Emacs version or without native compilation where this one
;; has it, or the other way round; so does a gated workload that has no
;; baseline.  Only a machine without a timing entry is report-only, as
;; CI runners and Nix builders are, and the run says so.
;;
;; Pinned code.  dired-filetags.el and this file are byte-compiled
;; into a temporary directory, with every warning an error, and those
;; .elc files are loaded; native JIT compilation is off, so no
;; definition changes under the benchmark.  The package must not be
;; loaded already, and undercover must not be.
;;
;; Inputs.  Every name is computed from its index, so the corpus is
;; the same everywhere.  The Dired buffers are synthetic listings in
;; GNU ls -al format (fixed owner, size and date), made into Dired
;; buffers as `dired-readin' does, so every file line is byte-identical
;; on every machine.  A real listing would not be: ls and ls-lisp
;; print the time zone's date, the locale's month, the file system's
;; directory sizes, and the free space.  Only the header line names
;; the directory, and no workload reads it.  The listed files exist,
;; for the workloads that stat them, inside one directory that is
;; deleted at the end.  It is made in /tmp, whatever TMPDIR says.  The
;; four :paths workloads build absolute file names, and their
;; string-chars and their time grow with the length of that
;; directory's name; TMPDIR differs from one shell to the next (nix
;; develop, macOS and the Nix sandbox each set their own), but a
;; directory made in /tmp has a truename of the same length in every
;; shell and sandbox of a system.  Where /tmp cannot be written, the
;; directory goes into TMPDIR, and the run says so; every baseline
;; records the length of the name it was measured with (:root-length),
;; and the path-dependent numbers are gated only against a baseline of
;; the same length.  `locate-dominating-file' stops at that directory,
;; and no directory is abbreviated to "~", so file lookups never see a
;; .filetags outside it.
;;
;; Timing.  Raw seconds are never compared with raw seconds: they
;; change with the power source, Low Power Mode and the kind of core.
;; The workloads run in rounds.  In each, every workload takes one
;; sample, after a full garbage collection and with `gc-cons-threshold'
;; at 1 GiB, so that no collection happens inside it, followed by a
;; sample of a calibration loop: string work that allocates at about
;; the workloads' rate, measured in the same process.  So every
;; workload sample lies between two calibration samples.  The run's
;; calibration is the lower quartile of the calibration samples, not
;; the fastest one: a single lucky sample, a few percent faster than
;; all the others, would raise every ratio by as much, and more
;; samples only ever lower a minimum, where a quartile stays put.  A
;; workload sample is clean if the calibration samples around it took
;; at most 1.1 times the run's calibration: the machine ran at full
;; speed around it.  A workload's ratio is its fastest clean sample
;; over the run's calibration.  The ratio cancels the clock speed,
;; which is most of what Low Power Mode and the power source change on
;; a performance core; the minimum drops sporadic interruptions; the
;; rounds spread each workload's samples over the whole run, and the
;; clean test drops those taken while the machine was busy, or had
;; moved Emacs to an efficiency core for a while.  Three workloads
;; only report their time: oracle waits for the filetags process,
;; prescan for the file system, and fontify-untagged is one buffer
;; search, whose speed varies by up to 5% from one Emacs process to
;; the next with the memory layout.
;;
;; Time gate.  The baseline key is SYSTEM/HOST, with the Emacs version
;; and whether it has native compilation.  A gated workload with fewer
;; than three clean samples, or with a ratio above the threshold times
;; its baseline, takes twice as many rounds again, up to three times,
;; and its ratio then comes from all its samples.  If it is still
;; above, two new Emacs processes run the timing gate too, since a
;; ratio moves by a percent or two from one process to the next with
;; the memory layout, which more samples in one process cannot change;
;; the workload fails only if the median of its three ratios is above.
;; The threshold is 1.05, or 1.08 when the run and the baseline were
;; in different macOS power modes: the ratio does not cancel all of
;; the change, and some workloads' ratios move by a few percent
;; between Low Power Mode and AC power.  The workloads to measure again
;; are chosen anew after each extra measurement, as more samples can
;; move the calibration, and so the ratios of the others.  A workload
;; that never gets three clean samples is not gated, and the run says
;; so; nor are the :paths workloads when the baseline's :root-length
;; is not this run's.  The whole timing gate is skipped, with a notice,
;; when the run's calibration is too far from the recorded one: the
;; ratios hold between a performance core on battery, in Low Power
;; Mode or on AC power, whose speeds differ by about 1.55 times, but
;; not between a performance core and an efficiency core, which is 2.5
;; times slower or more, and which is where an Emacs lands that is
;; denied the performance cores, as under heavy load.  The entry
;; records macOS's power mode (pmset's powermode), so the allowed
;; range is 1/1.35 to 1.35 times the recorded calibration in the same
;; mode, up to 2.2 times in Low Power Mode when recorded out of it,
;; down to 1/2.2 the other way round, and 1/1.8 to 1.8 when either
;; mode is unknown.  The allocation gate runs regardless.  --update
;; records the timing baseline only if every gated workload has three
;; clean samples, and not if the calibration is slower than that range
;; allows against the entry it replaces; it records no baseline at all
;; from a directory outside /tmp.  A ratio moves by a percent or two
;; from one Emacs process to the next, with the memory layout, so
;; --update measures the timings in three processes, this one and two
;; it starts, each with the gate's number of samples, and records each
;; workload's median ratio and the median calibration: the middle of
;; what a gate run measures, rather than one end of it.
;;
;; Allocation gate.  `memory-use-counts' deltas are deterministic for
;; a given Emacs, so they are compared on any machine of the SYSTEM.
;; Each workload is counted apart from the timing: it runs once, and
;; then twice counted, and the two counts must agree, or it is not
;; gated.  The gated counters are weighed by the object sizes that
;; `garbage-collect' reports, and the total may not exceed 1.05 times
;; the baseline's.  Every counter is gated, the string-chars of the
;; :paths workloads included, since their files are in /tmp; only when
;; the name of this run's directory and that of the baseline's differ
;; in length are those string-chars reported and not gated, and the
;; run says so.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'bytecomp)
(require 'dired)
(require 'elp)
(require 'profiler)

(declare-function dired-filetags-parse "dired-filetags" (name))
(declare-function dired-filetags--untagged-name "dired-filetags" (name))
(declare-function dired-filetags--check-tags "dired-filetags" (tags &optional removing))
(declare-function dired-filetags--tokens "dired-filetags" (adds removes))
(declare-function dired-filetags--verify "dired-filetags" (old new adds removes))
(declare-function dired-filetags--fontify "dired-filetags" (start end))
(declare-function dired-filetags--mark "dired-filetags" (tags match unmark))
(declare-function dired-filetags--buffer-tags "dired-filetags" ())
(declare-function dired-filetags--add-remove-candidates "dired-filetags" (files))
(declare-function dired-filetags--new-names "dired-filetags" (names tokens vocabulary))
(declare-function dired-filetags--tagtrees-prescan "dired-filetags" (source params))
(declare-function dired-filetags-mode "dired-filetags" (&optional arg))

(defvar dired-filetags-program)
(defvar dired-filetags-display-style)
(defvar dired-filetags-tag-faces)
(defvar dired-filetags-tagtrees-directory)
(defvar dired-filetags--cache)

;;;; Configuration

(defvar dired-filetags-bench--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "The scripts directory, which this file was first loaded from.
A `defvar', so that loading the pinned .elc keeps it.")

(defconst dired-filetags-bench--root-parent "/tmp/"
  "The directory in which the benchmarks make their files.
Not the variable `temporary-file-directory': the string-chars and the
time of the :paths workloads grow with the length of their directory's
name, and TMPDIR differs from one shell to the next, where /tmp gives
a name of one length in every shell and Nix sandbox of a system.")

(defconst dired-filetags-bench--threshold 1.05
  "The largest allowed ratio of a measurement to its baseline.")

(defconst dired-filetags-bench--cross-power-threshold 1.08
  "The largest allowed ratio of a time to a baseline of another power mode.
It replaces `dired-filetags-bench--threshold' for the timings when the
run and the baseline were measured in different macOS power modes: the
ratio to the calibration cancels most of the change of clock speed,
not all of it, and some workloads' ratios move by a few percent.")

(defconst dired-filetags-bench--clean-tolerance 1.1
  "How slow the calibration samples around a clean sample may be.
A workload sample is clean if the calibration samples just before and
just after it took at most this times the calibration of the run.")

(defconst dired-filetags-bench--min-clean 3
  "The clean samples a workload needs for its time to be gated.")

(defconst dired-filetags-bench--state-band 1.8
  "How far the calibration may be from the recorded one, as a factor.
Timings are gated only if the calibration of the run took at most
this times as long as the baseline's, and at least its inverse, when
the power mode of the recording or of the run is unknown.  A
performance core in Low Power Mode is about 1.55 times slower than on
AC power, and an efficiency core 2.5 times or more.")

(defconst dired-filetags-bench--same-power-band 1.35
  "The factor of `dired-filetags-bench--state-band' for the same power mode.
With the power mode of the recording, a performance core runs the
calibration at the recorded speed, give or take heat and noise.")

(defconst dired-filetags-bench--low-power-band 2.2
  "How much slower Low Power Mode may make the calibration, as a factor.
It applies when the power mode changed since the recording, in the
direction of the change; the other way, the same-mode factor applies.")

(defconst dired-filetags-bench--runs 3
  "How many Emacs processes measure a timing baseline or a timing failure.
A ratio moves by a percent or two from one Emacs process to the next,
with the memory layout, so --update records the median of the ratios
of this many processes, and a workload that fails the timing gate
fails only if the median of this many processes' ratios is still over
the threshold.")

(defconst dired-filetags-bench--extra-rounds 3
  "How many times a workload is measured again, with twice the samples.")

(defconst dired-filetags-bench--counters
  '(:conses :floats :vector-cells :symbols :string-chars :intervals :strings)
  "The counters of `memory-use-counts', in its order.")

(defconst dired-filetags-bench--size-names
  '(conses floats vector-slots symbols string-bytes intervals strings)
  "The `garbage-collect' entries whose sizes weigh each counter.")

(defconst dired-filetags-bench--workloads
  '((parse :reps 32 :time t :alloc t
           :doc "dired-filetags-parse and --untagged-name on every corpus name")
    (verify :reps 6 :time t :alloc t
            :doc "--verify on an addition and a removal for every tagged name")
    (tokens :reps 56 :time t :alloc t
            :doc "--check-tags (adding and removing) and --tokens per tagged name")
    (fontify-tagged :reps 6 :time t :alloc t
                    :doc "--fontify, right style, over the 615-entry tagged listing")
    (fontify-untagged :reps 1200 :time nil :alloc t
                      :doc "--fontify over the 600-line untagged listing (report-only time)")
    (mark :reps 3 :time t :alloc t :paths t
          :doc "--mark any of two tags, then unmark them, over the tagged listing")
    (tally :reps 7 :time t :alloc t :paths t
           :doc "--buffer-tags and --add-remove-candidates for 20 marked files")
    (oracle :reps 1 :time nil :alloc t :paths t
            :doc "--new-names: filetags retags 200 stand-ins (report-only time)")
    (prescan :reps 8 :time nil :alloc t :paths t
             :doc "--tagtrees-prescan of a 200-file directory (report-only time)"))
  "The workloads, in running order, as (NAME . PLIST).
:reps is the number of passes in one sample, :time and :alloc say
whether the gates check its time and its allocations, and :paths means
it builds absolute file names, so its string-chars and its time depend
on the length of the name of the directory that holds its files.")

(defconst dired-filetags-bench--calibration-reps 425
  "Passes of the calibration loop over the corpus in one sample.")

;;;; Corpus

(defconst dired-filetags-bench--bases
  ["Report" "2024-01-01 Meeting" "notes" "café menu" "v1.2 notes" "IMG_2041"
   "Quarterly budget" "日本語 memo" "a.b.c" "README" "draft" "Invoice 0042"
   " leading" "scan" "Makefile" "archive.tar" "Straße"]
  "Base names of the corpus; 17, coprime with the other tables.")

(defconst dired-filetags-bench--tags
  ["work" "urgent" "home" "draft" "2024" "naïve" "日本語" "c++" "node.js"
   "a_b-c" "finance" "travel" "photo" "todo" "done" "x"]
  "Tags of the corpus; 16, and each name draws distinct ones.")

(defconst dired-filetags-bench--extensions
  [".pdf" ".txt" ".org" ".jpg" ".tar.gz" "" ".md" ".PDF.lnk" ".½"]
  "Extensions of the corpus, including none, a double one and a .lnk.")

(defconst dired-filetags-bench--tricky
  '("foo -- a.txt" "multi -- x -- y.txt" "foo -- .txt" "foo -- a  b.txt"
    "foo -- a.txt " "foo -- a a.txt" "Foo -- A a.txt" "a.b.c -- x.tar.gz"
    "foo -- a.tar-gz" "foo -- a.日本" "foo -- a.PDF.LNK" "foo --a.txt"
    "foo -- " "x --  a.txt" "v1.2 notes -- foo" "foo -- a.txt~" "foo -- a b.")
  "Awkward names from the CLI vectors of the test suite, for the parser.")

(defun dired-filetags-bench--tags-of (i)
  "Return the tags of corpus name I: 0 to 3 distinct ones."
  (cl-loop for j below (% i 4)
           collect (aref dired-filetags-bench--tags (% (+ (* 3 i) (* 5 j)) 16))))

(defun dired-filetags-bench--name (i &optional untagged)
  "Return corpus name I, without its tags if UNTAGGED.
The index makes every name unique."
  (let ((tags (and (not untagged) (dired-filetags-bench--tags-of i))))
    (concat (aref dired-filetags-bench--bases (% i 17))
            (format " %03d" i)
            (if tags (concat " -- " (string-join tags " ")) "")
            (aref dired-filetags-bench--extensions (% i 9)))))

(defun dired-filetags-bench--corpus (n &optional untagged)
  "Return the first N corpus names, without tags if UNTAGGED."
  (cl-loop for i below n collect (dired-filetags-bench--name i untagged)))

(defun dired-filetags-bench--retagged (name plus minus)
  "Return tagged NAME with the tags PLUS appended and the tags MINUS dropped."
  (pcase-let* ((`(,base ,tags ,ext) (dired-filetags-parse name))
               (lnk (and (string-suffix-p ".lnk" (downcase name)) (substring name -4)))
               (new (append (seq-difference tags minus) plus)))
    (concat base
            (if new (concat " -- " (string-join new " ")) "")
            (if ext (concat "." ext) "")
            lnk)))

;;;; Environment

(defun dired-filetags-bench--say (format-string &rest args)
  "Print FORMAT-STRING with ARGS, as `format' does, and a newline to stdout."
  (princ (apply #'format format-string args))
  (terpri))

(defun dired-filetags-bench--uname-system ()
  "Return the Nix system name derived from uname, as coverage.sh does."
  (let ((machine (car (ignore-errors (process-lines "uname" "-m"))))
        (kernel (car (ignore-errors (process-lines "uname" "-s")))))
    (if (and machine kernel)
        (format "%s-%s"
                (if (equal machine "arm64") "aarch64" machine)
                (pcase kernel ("Darwin" "darwin") ("Linux" "linux") (_ (downcase kernel))))
      (let ((config (split-string system-configuration "-")))
        (format "%s-%s" (car config)
                (if (eq system-type 'darwin) "darwin" (symbol-name system-type)))))))

(defun dired-filetags-bench--system (option)
  "Return the system key: OPTION, else $DIRED_FILETAGS_SYSTEM, else uname's."
  (or option
      (let ((env (getenv "DIRED_FILETAGS_SYSTEM")))
        (and env (not (string-empty-p env)) env))
      (dired-filetags-bench--uname-system)))

(defun dired-filetags-bench--host ()
  "Return the short, lowercase host name."
  (downcase (car (split-string (system-name) "\\."))))

(defun dired-filetags-bench--power ()
  "Return \"low\" in macOS's Low Power Mode, \"normal\" out of it, else nil.
Nil means that the mode is unknown: another system, or no pmset."
  (when (and (eq system-type 'darwin) (file-executable-p "/usr/bin/pmset"))
    (with-temp-buffer
      (when (eql 0 (ignore-errors (call-process "/usr/bin/pmset" nil t nil "-g")))
        (goto-char (point-min))
        ;; "powermode" since macOS 14, "lowpowermode" before; 1 is low.
        (when (re-search-forward "^[ \t]*\\(?:low\\)?powermode[ \t]+\\([0-9]+\\)" nil t)
          (if (equal (match-string 1) "1") "low" "normal"))))))

(defun dired-filetags-bench--state-range (recorded current)
  "Return (LOW . HIGH): how the calibration may compare with the recorded one.
Timings are gated only if the calibration of the run over the
recorded one is from LOW to HIGH.  RECORDED and CURRENT are the power
modes, as `dired-filetags-bench--power' returns them, of the recording
and of this run.  An efficiency core, which is where an Emacs that is
denied the performance cores runs, falls outside the range either way."
  (let ((same dired-filetags-bench--same-power-band)
        (low dired-filetags-bench--low-power-band)
        (any dired-filetags-bench--state-band))
    (cond ((not (and recorded current)) (cons (/ 1 any) any))
          ((equal recorded current) (cons (/ 1 same) same))
          ((equal current "low") (cons (/ 1 same) low))
          (t (cons (/ 1 low) same)))))

(defun dired-filetags-bench--time-threshold (recorded current)
  "Return the timing threshold for power modes RECORDED and CURRENT.
They are the power modes of the recording and of this run, as
`dired-filetags-bench--power' returns them.  When both are known and
differ, that is `dired-filetags-bench--cross-power-threshold', else
`dired-filetags-bench--threshold'."
  (if (and recorded current (not (equal recorded current)))
      dired-filetags-bench--cross-power-threshold
    dired-filetags-bench--threshold))

(defun dired-filetags-bench--make-root ()
  "Make the directory for the benchmarks' files; return (ROOT . FALLBACK).
ROOT is its truename, as a directory name.  It is made in
`dired-filetags-bench--root-parent', and FALLBACK is nil, unless that
directory cannot be written; then ROOT is made in the variable
`temporary-file-directory', and FALLBACK is t."
  (let ((root (and (file-directory-p dired-filetags-bench--root-parent)
                   (ignore-error file-error
                     (let ((temporary-file-directory dired-filetags-bench--root-parent))
                       (make-temp-file "dired-filetags-bench-" t))))))
    (cons (file-name-as-directory
           (file-truename (or root (make-temp-file "dired-filetags-bench-" t))))
          (not root))))

(defun dired-filetags-bench--native-p ()
  "Return t if this Emacs has native compilation, else nil."
  (and (fboundp 'native-comp-available-p) (native-comp-available-p) t))

(defun dired-filetags-bench--sizes ()
  "Return the byte size of one unit of each counter, from `garbage-collect'."
  (let ((stats (garbage-collect)))
    (cl-loop for name in dired-filetags-bench--size-names
             for default in '(16 8 8 48 1 56 32)
             collect (or (nth 1 (assq name stats)) default))))

;;;; Pinning

(defun dired-filetags-bench--compile (source dest)
  "Byte-compile SOURCE into directory DEST, warnings being errors.
Return the .elc file name."
  (let* ((elc (expand-file-name (concat (file-name-base source) ".elc") dest))
         (byte-compile-dest-file-function (lambda (_) elc))
         (byte-compile-error-on-warn t)
         (byte-compile-warnings 'all)
         (load-prefer-newer t))
    (unless (byte-compile-file source)
      (error "Cannot byte-compile %s" source))
    elc))

(defun dired-filetags-bench--pin (dest)
  "Load byte-compiled dired-filetags and this file, both compiled into DEST.
Signal an error unless that is what runs."
  (when (featurep 'undercover)
    (error "The benchmarks must not run under undercover"))
  (when (featurep 'dired-filetags)
    (error "Dired-filetags is already loaded; run the benchmarks with -Q"))
  (setq native-comp-jit-compilation nil)
  (make-directory dest t)
  (let* ((root (expand-file-name ".." dired-filetags-bench--dir))
         (package (dired-filetags-bench--compile
                   (expand-file-name "dired-filetags.el" root) dest))
         (bench (dired-filetags-bench--compile
                 (expand-file-name "bench.el" dired-filetags-bench--dir) dest)))
    (push dest load-path)
    (require 'dired-filetags)
    (load bench nil t t)
    (dolist (fn '(dired-filetags-parse dired-filetags--fontify
                                       dired-filetags-bench--calibrate
                                       dired-filetags-bench--sample))
      (unless (and (compiled-function-p (symbol-function fn))
                   (not (and (fboundp 'native-comp-function-p)
                             (native-comp-function-p (symbol-function fn)))))
        (error "%s is not byte-compiled" fn)))
    (unless (equal (symbol-file 'dired-filetags-parse) package)
      (error "Dired-filetags was loaded from %s, not %s"
             (symbol-file 'dired-filetags-parse) package))))

;;;; Fixtures

(defun dired-filetags-bench--line (name &optional type target)
  "Return the ls -al line of NAME, a file, or of TYPE ?d or ?l with TARGET."
  (format "  %s  1 bench bench %6d Jan  1  2020 %s%s\n"
          (pcase type (?d "drwxr-xr-x") (?l "lrwxrwxrwx") (_ "-rw-r--r--"))
          (pcase type (?d 64) (?l (length target)) (_ 0))
          name
          (if target (concat " -> " target) "")))

(defun dired-filetags-bench--dired (dir lines)
  "Return a Dired buffer on DIR listing LINES, with the mode on.
LINES are file lines in ls -al format, which follow the header line."
  (let ((buffer (generate-new-buffer " *dired-filetags-bench*")))
    (with-current-buffer buffer
      (setq default-directory dir)
      (let ((enable-dir-local-variables nil))
        (dired-mode dir "-al"))
      (setq buffer-undo-list t)
      (let ((inhibit-read-only t))
        (insert "  " (directory-file-name dir) ":\n  total 0\n")
        (dolist (line lines) (insert line))
        (dired-insert-set-properties (point-min) (point-max)))
      (dired-build-subdir-alist)
      (set-buffer-modified-p nil)
      (dired-filetags-mode 1)
      (goto-char (point-min)))
    buffer))

(defun dired-filetags-bench--touch (file &optional contents)
  "Write CONTENTS, default empty, to FILE, bypassing file name handlers."
  (let ((file-name-handler-alist nil)
        (coding-system-for-write 'utf-8-unix))
    (write-region (or contents "") nil file nil 0)))

(defun dired-filetags-bench--setup (root)
  "Create the fixtures below ROOT and return them as a plist."
  (let* ((listing (file-name-as-directory (expand-file-name "listing" root)))
         (untagged (file-name-as-directory (expand-file-name "untagged" root)))
         (prescan (file-name-as-directory (expand-file-name "prescan" root)))
         (names (dired-filetags-bench--corpus 600))
         (tagged (seq-filter #'dired-filetags-parse names))
         (links (cl-loop for i below 10
                         collect (cons (format "link %02d -- %s.txt" i
                                               (aref dired-filetags-bench--tags i))
                                       (nth (* 7 i) names))))
         (dirs '("archive" "photos 2024" "projects -- work")))
    (dolist (dir (list listing untagged prescan)) (make-directory dir t))
    (dolist (name names) (dired-filetags-bench--touch (concat listing name)))
    (dolist (dir dirs) (make-directory (concat listing dir)))
    (pcase-dolist (`(,link . ,target) links)
      (make-symbolic-link target (concat listing link)))
    (dired-filetags-bench--touch
     (concat listing ".filetags")
     (concat (mapconcat #'identity dired-filetags-bench--tags "\n")
             "\nbench\nreview\narchive\n"))
    (dolist (name (dired-filetags-bench--corpus 200))
      (dired-filetags-bench--touch (concat prescan name)))
    (list
     :names (append names dired-filetags-bench--tricky)
     :adds (mapcar (lambda (name)
                     (list name (dired-filetags-bench--retagged name '("bench") nil)
                           '("bench") nil))
                   tagged)
     :removes (mapcar (lambda (name)
                        (let ((tag (car (nth 1 (dired-filetags-parse name)))))
                          (list name (dired-filetags-bench--retagged name nil (list tag))
                                nil (list tag))))
                      tagged)
     :tag-lists (mapcar (lambda (name) (nth 1 (dired-filetags-parse name))) tagged)
     :tagged-buffer
     (dired-filetags-bench--dired
      listing
      (append (list (dired-filetags-bench--line "." ?d)
                    (dired-filetags-bench--line ".." ?d))
              (mapcar (lambda (entry)
                        (pcase entry
                          (`(,link . ,target) (dired-filetags-bench--line link ?l target))
                          ((pred (lambda (name) (member name dirs)))
                           (dired-filetags-bench--line entry ?d))
                          (_ (dired-filetags-bench--line entry))))
                      (sort (append (copy-sequence names) (copy-sequence dirs) links)
                            (lambda (a b)
                              (string< (if (consp a) (car a) a) (if (consp b) (car b) b)))))))
     :untagged-buffer
     (dired-filetags-bench--dired
      untagged
      (append (list (dired-filetags-bench--line "." ?d)
                    (dired-filetags-bench--line ".." ?d))
              (mapcar #'dired-filetags-bench--line
                      (sort (dired-filetags-bench--corpus 600 t) #'string<))))
     :selection (cl-loop for i below 20 collect (concat listing (nth (* 22 i) tagged)))
     :oracle-names (dired-filetags-bench--corpus 200)
     :vocabulary (concat listing ".filetags")
     :prescan prescan)))

;;;; Workloads

(defun dired-filetags-bench--driver (name reps fixtures)
  "Return the function for workload NAME: REPS passes over FIXTURES."
  (let ((names (plist-get fixtures :names))
        (adds (plist-get fixtures :adds))
        (removes (plist-get fixtures :removes))
        (tag-lists (plist-get fixtures :tag-lists))
        (tagged (plist-get fixtures :tagged-buffer))
        (untagged (plist-get fixtures :untagged-buffer))
        (selection (plist-get fixtures :selection))
        (oracle-names (plist-get fixtures :oracle-names))
        (vocabulary (plist-get fixtures :vocabulary))
        (prescan (plist-get fixtures :prescan)))
    (pcase-exhaustive name
      ('parse
       (lambda ()
         (dotimes (_ reps)
           (dolist (name names)
             (dired-filetags-parse name)
             (dired-filetags--untagged-name name)))))
      ('verify
       (lambda ()
         (dotimes (_ reps)
           (dolist (pair adds) (apply #'dired-filetags--verify pair))
           (dolist (pair removes) (apply #'dired-filetags--verify pair)))))
      ('tokens
       (lambda ()
         (dotimes (_ reps)
           (dolist (tags tag-lists)
             (dired-filetags--check-tags (cons "bench" tags))
             (dired-filetags--check-tags tags t)
             (dired-filetags--tokens '("bench") tags)))))
      ('fontify-tagged
       (lambda ()
         (with-current-buffer tagged
           (dotimes (_ reps) (dired-filetags--fontify (point-min) (point-max))))))
      ('fontify-untagged
       (lambda ()
         (with-current-buffer untagged
           (dotimes (_ reps) (dired-filetags--fontify (point-min) (point-max))))))
      ('mark
       (lambda ()
         (with-current-buffer tagged
           (dotimes (_ reps)
             (dired-filetags--mark '("work" "travel") 'any nil)
             (dired-filetags--mark '("work" "travel") 'any t)))))
      ('tally
       (lambda ()
         (with-current-buffer tagged
           (dotimes (_ reps)
             (dired-filetags--buffer-tags)
             ;; A fresh memo table, as each command binds one.
             (let ((dired-filetags--cache (make-hash-table :test #'equal)))
               (dired-filetags--add-remove-candidates selection))))))
      ('oracle
       (lambda ()
         (dotimes (_ reps) (dired-filetags--new-names oracle-names "bench" vocabulary))))
      ('prescan
       (lambda ()
         (dotimes (_ reps)
           (dired-filetags--tagtrees-prescan
            prescan '(:recursive nil :depth 2 :untagged "no-tags"))))))))

(defvar dired-filetags-bench--calibration-corpus nil
  "The names the calibration loop works on.")

(defun dired-filetags-bench--calibrate ()
  "Run the calibration loop: string work like the package's, on the corpus.
It scans characters and allocates at about the workloads' rate, so a
change of speed of the machine affects it as it affects them, and it
uses no regular expression, so it leaves the cache of compiled ones as
the workload before it left it.  Return a number, so that the work
cannot be dropped."
  (let ((n 0))
    (dotimes (_ dired-filetags-bench--calibration-reps)
      (dolist (s dired-filetags-bench--calibration-corpus)
        (let* ((len (length s))
               (sep (string-search " -- " s))
               (space (string-search " " s))
               (head (substring s 0 (or sep len)))
               (dot (cl-loop for i downfrom (1- len) to 0
                             thereis (and (eq (aref s i) ?.) i))))
          (setq n (+ n
                     (length head)
                     (if (member head '("Report" "notes" "README")) 1 0)
                     (length (list space dot)))))))
    n))

;;;; Measuring

(defun dired-filetags-bench--sample (fn &optional no-gc)
  "Run FN once, after a full garbage collection unless NO-GC.
Return (SECONDS . COUNTS), COUNTS being the `memory-use-counts' deltas."
  (unless no-gc (garbage-collect))
  (let* ((gc-cons-threshold (* 1024 1024 1024))
         (before (memory-use-counts))
         (start (float-time)))
    (funcall fn)
    (let* ((end (float-time))
           (after (memory-use-counts)))
      (cons (- end start) (cl-mapcar #'- after before)))))

(defun dired-filetags-bench--plist (counts)
  "Return COUNTS, a list in `memory-use-counts' order, as a plist."
  (cl-mapcan #'list dired-filetags-bench--counters counts))

(defun dired-filetags-bench--count (fn)
  "Return (COUNTS . STABLE): the allocations of FN, and if two counts agree.
COUNTS is a plist.  FN runs once first, so that each counted run
follows a run of FN: Emacs copies a regexp into its cache of compiled
ones when it compiles it, so what a run allocates depends on the
regexps that ran before it."
  (funcall fn)
  (let* ((first (cdr (dired-filetags-bench--sample fn)))
         (second (cdr (dired-filetags-bench--sample fn))))
    (cons (dired-filetags-bench--plist second) (equal first second))))

(defconst dired-filetags-bench--report-samples 3
  "The most samples taken of a workload whose time is only reported.")

(defun dired-filetags-bench--calibration-sample (timing)
  "Take a sample of the calibration loop, add it to TIMING, return its seconds."
  (let ((seconds (car (dired-filetags-bench--sample #'dired-filetags-bench--calibrate t))))
    (push seconds (car timing))
    seconds))

(defun dired-filetags-bench--time (drivers rounds &optional timing)
  "Take ROUNDS rounds of samples of DRIVERS, (NAME . FUNCTION) pairs.
Each round runs every function once, after a garbage collection, and
after each a sample of the calibration loop, which also precedes the
first; so every workload sample lies between two calibration samples,
and the samples of a workload spread over the whole run.  A workload
whose time is not gated takes at most
`dired-filetags-bench--report-samples' samples.

Return the timing, (CALIBRATIONS . SAMPLES): CALIBRATIONS lists the
seconds of every calibration sample, and SAMPLES maps each workload's
name to its samples, each (SECONDS BEFORE AFTER), the last two being
the calibration samples around it.  TIMING, a timing returned before,
is extended in place instead of starting anew."
  (let ((timing (or timing (cons nil nil))))
    (dolist (driver drivers)
      (unless (assq (car driver) (cdr timing))
        (setcdr timing (append (cdr timing) (list (list (car driver)))))))
    (let ((before (dired-filetags-bench--calibration-sample timing)))
      (dotimes (_ rounds)
        (dolist (driver drivers)
          (let ((cell (assq (car driver) (cdr timing))))
            (when (or (plist-get (alist-get (car driver) dired-filetags-bench--workloads) :time)
                      (< (length (cdr cell)) dired-filetags-bench--report-samples))
              (let* ((seconds (car (dired-filetags-bench--sample (cdr driver))))
                     (after (dired-filetags-bench--calibration-sample timing)))
                (push (list seconds before after) (cdr cell))
                (setq before after)))))))
    timing))

(defun dired-filetags-bench--calibration (timing)
  "Return the calibration of TIMING, the lower quartile of its samples.
That is of its calibration samples, and not the fastest one: one
lucky sample, a few percent faster than all the others, would raise
every ratio by as much, and more samples can only lower a minimum
further, where a quartile stays put."
  (let ((sorted (sort (copy-sequence (car timing)) #'<)))
    (nth (/ (1- (length sorted)) 4) sorted)))

(defun dired-filetags-bench--summary (timing name)
  "Return the plist that sums up the samples of workload NAME in TIMING.
:calibration is the calibration of the whole timing, as
`dired-filetags-bench--calibration' computes it.  A sample is clean if
the calibration samples around it took at most
`dired-filetags-bench--clean-tolerance' times as long.  :seconds is
the fastest clean sample, or the fastest of all if none is clean,
:ratio is :seconds over :calibration, :clean counts the clean samples
and :count all of them, and :spread is the slowest sample over the
fastest."
  (let* ((calibration (dired-filetags-bench--calibration timing))
         (samples (cdr (assq name (cdr timing))))
         (limit (* dired-filetags-bench--clean-tolerance calibration))
         (all (mapcar #'car samples))
         (clean (cl-loop for (seconds before after) in samples
                         when (<= (max before after) limit) collect seconds))
         (fastest (apply #'min (or clean all))))
    (list :seconds fastest
          :calibration calibration
          :ratio (/ fastest calibration)
          :clean (length clean)
          :count (length samples)
          :spread (/ (apply #'max all) (apply #'min all)))))

(defun dired-filetags-bench--gated-counters (spec &optional paths-differ)
  "Return the counters gated for workload SPEC, a (NAME . PLIST).
That is every counter, unless PATHS-DIFFER says that the run and the
baseline had directories whose names differ in length; then a :paths
workload's string-chars, which grow with that length, are left out."
  (if (and paths-differ (plist-get (cdr spec) :paths))
      (remq :string-chars dired-filetags-bench--counters)
    dired-filetags-bench--counters))

(defun dired-filetags-bench--paths-differ-p (results entry)
  "Return non-nil if RESULTS and the baseline ENTRY, a plist, differ in root.
That is, if their :root-length differ, or one of them has none: the
names of the directories that held the files of the :paths workloads
differ in length, so their string-chars and times cannot be compared."
  (not (eql (plist-get results :root-length) (plist-get entry :root-length))))

(defun dired-filetags-bench--paths-names ()
  "Return the names of the :paths workloads, joined by commas."
  (mapconcat (lambda (spec) (symbol-name (car spec)))
             (seq-filter (lambda (spec) (plist-get (cdr spec) :paths))
                         dired-filetags-bench--workloads)
             ", "))

(defun dired-filetags-bench--bytes (counts counters sizes)
  "Return the bytes that COUNTERS of plist COUNTS weigh, with SIZES.
Return nil if COUNTS lacks one of them."
  (cl-loop for counter in counters
           for count = (plist-get counts counter)
           unless (numberp count) return nil
           sum (* count (nth (cl-position counter dired-filetags-bench--counters) sizes))))

;;;; Baselines

(defun dired-filetags-bench--baselines-file ()
  "Return the file name of baselines/perf.eld."
  (expand-file-name "../baselines/perf.eld" dired-filetags-bench--dir))

(defun dired-filetags-bench--read (file)
  "Return the first Lisp object in FILE, or nil if FILE does not exist."
  (when (file-exists-p file)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents file))
      (read (current-buffer)))))

(defun dired-filetags-bench--entry (baselines kind key emacs native)
  "Return the (KEY . PLIST) of KIND in BASELINES if it matches, else a symbol.
KIND is `alloc' or `time'.  The entry matches if its :emacs is EMACS
and its :native is NATIVE.  Otherwise return `absent' if BASELINES is
nil, as it is when baselines/perf.eld does not exist, `missing' if
there is no entry for KEY, and `stale' if the entry for KEY is for
another Emacs; the caller says what that means."
  (let ((entry (assoc key (alist-get kind baselines))))
    (cond ((not baselines) 'absent)
          ((not entry) 'missing)
          ((not (and (equal (plist-get (cdr entry) :emacs) emacs)
                     (eq (plist-get (cdr entry) :native) native)))
           (dired-filetags-bench--say
            "perf: the %s baseline for %s is for Emacs %s (native %s), not %s (native %s)"
            kind key (plist-get (cdr entry) :emacs) (plist-get (cdr entry) :native)
            emacs native)
           'stale)
          (t entry))))

(defun dired-filetags-bench--no-baseline (kind key problem)
  "Say that the KIND gate for KEY fails because of PROBLEM, and how to fix it.
PROBLEM is a symbol that `dired-filetags-bench--entry' returns.
Return the name of the failure, KIND-baseline."
  (dired-filetags-bench--say
   "perf: FAILED: %s; the %s gate compared nothing"
   (pcase problem
     ('absent (format "%s is missing" (dired-filetags-bench--baselines-file)))
     ('missing (format "baselines/perf.eld has no %s entry for %s" kind key))
     (_ (format "the %s baseline for %s was recorded with another Emacs" kind key)))
   (if (eq kind 'time) "timing" "allocation"))
  (dired-filetags-bench--say
   (concat "perf: record it deliberately, in a commit of its own:"
           " bench.el --update (nix run .#update-baselines)%s")
   (if (eq kind 'alloc)
       ", or for another system bench.el --results RESULT/perf.eld --update --system SYS"
     ""))
  (intern (format "%s-baseline" kind)))

(defun dired-filetags-bench--format-number (x)
  "Return float X printed with six significant digits, readable as a float."
  (let ((s (format "%.6g" x)))
    (if (string-match-p "[.e]" s) s (concat s ".0"))))

(defun dired-filetags-bench--write-baselines (baselines)
  "Write BASELINES to baselines/perf.eld, sorted, one workload per line."
  (let* ((file (dired-filetags-bench--baselines-file))
         (sorted (lambda (items) (sort (copy-sequence items)
                                       (lambda (a b) (string< (car a) (car b))))))
         (entries
          (lambda (kind format-entry)
            (mapconcat (lambda (entry)
                         (funcall format-entry (car entry) (cdr entry)))
                       (funcall sorted (alist-get kind baselines)) ""))))
    (make-directory (file-name-directory file) t)
    (dired-filetags-bench--write
     file
     (concat
      ";;; perf.eld --- dired-filetags performance baselines  -*- lisp-data -*-\n"
      ";;\n"
      ";; Written by scripts/bench.el --update; see the README.\n"
      ";; alloc: per SYSTEM, the `memory-use-counts' deltas of each\n"
      ";; workload.  time: per SYSTEM/HOST, each workload's fastest clean\n"
      ";; sample over the lower quartile of the calibration samples, that\n"
      ";; calibration in seconds, and macOS's power mode then.  Both record\n"
      ";; the length of the name of the directory that held the files.\n\n"
      "((alloc"
      (funcall entries 'alloc
               (lambda (key plist)
                 (format "\n  (%S :emacs %S :native %S%s\n   :counts\n   (%s))"
                         key (plist-get plist :emacs) (plist-get plist :native)
                         (dired-filetags-bench--root-length-string plist)
                         (mapconcat #'prin1-to-string
                                    (funcall sorted (plist-get plist :counts))
                                    "\n    "))))
      ")\n (time"
      (funcall entries 'time
               (lambda (key plist)
                 (format "\n  (%S :emacs %S :native %S%s%s :calibration %s\n   :ratios\n   (%s))"
                         key (plist-get plist :emacs) (plist-get plist :native)
                         (dired-filetags-bench--root-length-string plist)
                         (if (plist-get plist :power)
                             (format " :power %S" (plist-get plist :power))
                           "")
                         (dired-filetags-bench--format-number (plist-get plist :calibration))
                         (mapconcat (lambda (ratio)
                                      (format "(%s . %s)" (car ratio)
                                              (dired-filetags-bench--format-number (cdr ratio))))
                                    (funcall sorted (plist-get plist :ratios))
                                    "\n    "))))
      "))\n"))
    (dired-filetags-bench--say "perf: wrote %s" file)))

(defun dired-filetags-bench--root-length-string (plist)
  "Return \" :root-length N\" for the :root-length of PLIST, or \"\"."
  (if (plist-get plist :root-length)
      (format " :root-length %d" (plist-get plist :root-length))
    ""))

(defun dired-filetags-bench--put (baselines kind key plist)
  "Return BASELINES with the KIND entry for KEY replaced by (KEY . PLIST)."
  (let* ((entries (assoc-delete-all key (copy-sequence (alist-get kind baselines))))
         (entries (cons (cons key plist) entries)))
    (cons (cons kind entries) (assq-delete-all kind (copy-sequence baselines)))))

(defun dired-filetags-bench--update-alloc (baselines results system)
  "Return BASELINES with SYSTEM's allocation entry taken from RESULTS."
  (dired-filetags-bench--put
   baselines 'alloc system
   (list :emacs (plist-get results :emacs)
         :native (plist-get results :native)
         :root-length (plist-get results :root-length)
         :counts
         (cl-loop for spec in dired-filetags-bench--workloads
                  for result = (alist-get (car spec) (plist-get results :workloads))
                  when (and result (plist-get (cdr spec) :alloc))
                  collect (cons (car spec)
                                (cl-loop with counts = (plist-get result :counts)
                                         for counter in dired-filetags-bench--counters
                                         append (list counter (plist-get counts counter))))))))

(defun dired-filetags-bench--update-time (baselines results key)
  "Return BASELINES with KEY's timing entry taken from RESULTS."
  (dired-filetags-bench--put
   baselines 'time key
   (append
    (list :emacs (plist-get results :emacs)
          :native (plist-get results :native)
          :root-length (plist-get results :root-length))
    (and (plist-get results :power) (list :power (plist-get results :power)))
    (list :calibration (plist-get results :calibration)
          :ratios
          (cl-loop for spec in dired-filetags-bench--workloads
                   for result = (alist-get (car spec) (plist-get results :workloads))
                   when (and result (plist-get (cdr spec) :time))
                   collect (cons (car spec) (plist-get result :ratio)))))))

;;;; Gates

(defun dired-filetags-bench--percent (now base)
  "Return the change from BASE to NOW as a signed percentage string."
  (format "%+.1f%%" (* 100 (- (/ (float now) base) 1))))

(defun dired-filetags-bench--over (threshold)
  "Return THRESHOLD, a factor such as 1.05, as a percentage such as \"5%\"."
  (format "%.0f%%" (* 100 (- threshold 1))))

(defun dired-filetags-bench--annotate (results name &rest props)
  "Set PROPS, a plist, in the plist of workload NAME in RESULTS, in place."
  (let ((cell (assq name (plist-get results :workloads))))
    (while props
      (setcdr cell (plist-put (cdr cell) (pop props) (pop props))))))

(defun dired-filetags-bench--gate-alloc (results baselines system)
  "Check the allocations in RESULTS against SYSTEM's entry in BASELINES.
Record each verdict in RESULTS, and return the names of the workloads
that fail, and a note for the last line of the output if some counters
were not gated, as (FAILED . NOTE)."
  (let* ((found (dired-filetags-bench--entry
                 baselines 'alloc system (plist-get results :emacs) (plist-get results :native)))
         (entry (and (consp found) found))
         (sizes (plist-get results :sizes))
         (paths-differ (and entry (dired-filetags-bench--paths-differ-p results (cdr entry))))
         failed improved)
    (unless entry
      (push (dired-filetags-bench--no-baseline 'alloc system found) failed))
    (when paths-differ
      (plist-put results :paths-differ t)
      (dired-filetags-bench--say
       (concat "perf: NOTE: the string-chars of %s are NOT gated: the name of the directory"
               " that held their files had %s characters, and the baseline's %s")
       (dired-filetags-bench--paths-names) (plist-get results :root-length)
       (or (plist-get (cdr entry) :root-length) "an unknown number")))
    (dolist (spec dired-filetags-bench--workloads)
      (let* ((name (car spec))
             (result (alist-get name (plist-get results :workloads)))
             (counters (dired-filetags-bench--gated-counters spec paths-differ))
             (base (and entry (alist-get name (plist-get (cdr entry) :counts))))
             (bytes (and result (dired-filetags-bench--bytes
                                 (plist-get result :counts) counters sizes)))
             (base-bytes (and base (dired-filetags-bench--bytes base counters sizes)))
             (verdict
              (cond ((not result) nil)
                    ((not (plist-get (cdr spec) :alloc)) "report")
                    ((not (plist-get result :stable)) "unstable")
                    ((not entry) "report")
                    ((not (and base-bytes (> base-bytes 0))) "new")
                    ((> bytes (* dired-filetags-bench--threshold base-bytes)) "FAIL")
                    ((< bytes (/ base-bytes dired-filetags-bench--threshold)) "better")
                    (t "ok"))))
        (when verdict
          (dired-filetags-bench--annotate results name :alloc-verdict verdict
                                          :alloc-base base-bytes))
        (pcase verdict
          ("FAIL"
           (push name failed)
           (dired-filetags-bench--say
            "perf: %s allocates %.1f%% more than its baseline (%d > %d bytes):"
            name (* 100 (- (/ (float bytes) base-bytes) 1)) bytes base-bytes)
           (dolist (counter counters)
             (let ((now (plist-get (plist-get result :counts) counter))
                   (was (plist-get base counter)))
               (unless (eql now was)
                 (dired-filetags-bench--say "perf:   %s %s -> %s"
                                            (substring (symbol-name counter) 1) was now)))))
          ("better" (push name improved))
          ("new"
           (push name failed)
           (dired-filetags-bench--say
            "perf: FAILED: %s has no allocation baseline; record one with --update" name))
          ("unstable"
           (dired-filetags-bench--say
            "perf: NOTE: %s allocated differently in two runs; its allocations are NOT gated"
            name)))))
    (when improved
      (dired-filetags-bench--say
       "perf: %s allocate 5%% less than the baseline; record that with --update"
       (mapconcat #'symbol-name (nreverse improved) ", ")))
    (cons (nreverse failed)
          (and paths-differ
               (format "string-chars of %s not gated: the directory's name differs in length"
                       (dired-filetags-bench--paths-names))))))

(defun dired-filetags-bench--needy (timing ratios threshold)
  "Return the gated workloads of TIMING that need more samples.
They are those with fewer than `dired-filetags-bench--min-clean' clean
samples, and those whose ratio exceeds THRESHOLD times its baseline in
the alist RATIOS; RATIOS nil means that none has one."
  (cl-loop for spec in dired-filetags-bench--workloads
           for name = (car spec)
           for summary = (and (plist-get (cdr spec) :time)
                              (assq name (cdr timing))
                              (dired-filetags-bench--summary timing name))
           for base = (alist-get name ratios)
           when (and summary
                     (or (< (plist-get summary :clean) dired-filetags-bench--min-clean)
                         (and base (> (plist-get summary :ratio) (* threshold base)))))
           collect name))

(defun dired-filetags-bench--settle (timing drivers samples ratios threshold &optional skip)
  "Measure the workloads of TIMING that need it again, and return their names.
While `dired-filetags-bench--needy' names workloads, with RATIOS and
THRESHOLD, those of them not in SKIP and measured again fewer than
`dired-filetags-bench--extra-rounds' times take twice SAMPLES rounds
more, running their functions from the alist DRIVERS.  The needy are
named anew each time, since more samples can move the calibration,
and so raise the ratio of a workload that was not needy before.
TIMING is extended in place."
  (let ((times nil)
        (needy nil))
    (while (setq needy (seq-remove (lambda (name)
                                     (or (memq name skip)
                                         (>= (alist-get name times 0)
                                             dired-filetags-bench--extra-rounds)))
                                   (dired-filetags-bench--needy timing ratios threshold)))
      (dired-filetags-bench--say "perf: measuring %s again, %d more rounds"
                                 (mapconcat #'symbol-name needy ", ") (* 2 samples))
      (dired-filetags-bench--time (mapcar (lambda (name) (assq name drivers)) needy)
                                  (* 2 samples) timing)
      (dolist (name needy)
        (setf (alist-get name times) (1+ (alist-get name times 0)))))
    (mapcar #'car times)))

(defun dired-filetags-bench--update-summaries (results timing)
  "Put the summary of every workload of TIMING into RESULTS, in place.
The run's :calibration becomes the calibration of TIMING, as
`dired-filetags-bench--calibration' computes it."
  (dolist (entry (cdr timing))
    (apply #'dired-filetags-bench--annotate results (car entry)
           (dired-filetags-bench--summary timing (car entry))))
  (plist-put results :calibration (dired-filetags-bench--calibration timing)))

(defun dired-filetags-bench--gate-time (results baselines key samples drivers timing)
  "Check the timings in RESULTS against KEY's entry in BASELINES.
TIMING holds the samples that RESULTS sums up.  First the machine's
state is checked: the run's calibration over the entry's :calibration
must lie in `dired-filetags-bench--state-range', or no timing is gated.
Then the workloads that need it are measured again, running their
functions from the alist DRIVERS, with twice SAMPLES rounds, and a
workload fails if its ratio still exceeds the threshold times its
baseline; the threshold is `dired-filetags-bench--time-threshold''s
for the two power modes.  The :paths workloads are not gated if the
entry's :root-length is not the run's.  Record each verdict in
RESULTS, and return the names of the workloads that fail, and a note
for the last line of the output if timings were not gated, as
\(FAILED . NOTE)."
  (let* ((found (dired-filetags-bench--entry
                 baselines 'time key (plist-get results :emacs) (plist-get results :native)))
         (entry (and (consp found) found))
         (ratios (plist-get (cdr entry) :ratios))
         (recorded (plist-get (cdr entry) :calibration))
         (calibration (plist-get results :calibration))
         (factor (and recorded (/ calibration recorded)))
         (power (plist-get results :power))
         (recorded-power (plist-get (cdr entry) :power))
         (range (dired-filetags-bench--state-range recorded-power power))
         (threshold (dired-filetags-bench--time-threshold recorded-power power))
         (skip (and entry (dired-filetags-bench--paths-differ-p results (cdr entry))
                    (mapcar #'car (seq-filter (lambda (spec) (and (plist-get (cdr spec) :paths)
                                                                  (plist-get (cdr spec) :time)))
                                              dired-filetags-bench--workloads))))
         failed improved busy again)
    (cond
     ((memq found '(absent stale))
      (cons (list (dired-filetags-bench--no-baseline 'time key found)) nil))
     ((eq found 'missing)
      (dired-filetags-bench--say
       "perf: NOTE: timings are NOT gated: baselines/perf.eld has no timing entry for %s" key)
      (dired-filetags-bench--say
       "perf: only a machine with its own entry gates timings; record one with --update")
      (cons nil (format "timings not gated: no timing baseline for %s" key)))
     ((not (and (numberp recorded) (> recorded 0)))
      (error "The timing baseline for %s has no :calibration" key))
     ((not (<= (car range) factor (cdr range)))
      (dired-filetags-bench--say
       (concat "perf: NOTE: timings are NOT gated: the calibration took %.1f ms,"
               " %.2f times the %.1f ms recorded for %s, outside %.2f to %.2f"
               " (power mode %s, recorded in %s)")
       (* 1000 calibration) factor (* 1000 recorded) key (car range) (cdr range)
       (or power "unknown") (or recorded-power "unknown"))
      (dired-filetags-bench--say
       "perf: the ratios hold only on the kind of core the baseline was recorded on; %s"
       (if (> factor 1)
           (concat "this Emacs ran on an efficiency core, or on a machine too busy to"
                   " measure; run it again when the machine is idle")
         (concat "the baseline was recorded on a slower core, or while the machine was"
                 " busy; record it again with --update")))
      (dolist (spec dired-filetags-bench--workloads)
        (when (and (plist-get (cdr spec) :time)
                   (alist-get (car spec) (plist-get results :workloads)))
          (dired-filetags-bench--annotate results (car spec) :time-verdict "not gated"
                                          :time-base (alist-get (car spec) ratios))))
      (cons nil (format "timings not gated: calibration %.2f times the recorded one" factor)))
     (t
      (let ((first (mapcar (lambda (w) (cons (car w) (plist-get (cdr w) :ratio)))
                           (plist-get results :workloads))))
        (unless (= threshold dired-filetags-bench--threshold)
          (dired-filetags-bench--say
           (concat "perf: the power mode is %s, and the baseline was recorded in %s;"
                   " timings are gated at %s over the baseline, not %s")
           power recorded-power
           (dired-filetags-bench--over threshold)
           (dired-filetags-bench--over dired-filetags-bench--threshold)))
        (when skip
          (dired-filetags-bench--say
           (concat "perf: NOTE: the times of %s are NOT gated: the name of the directory"
                   " that held their files had %s characters, and the baseline's %s")
           (mapconcat #'symbol-name skip ", ") (plist-get results :root-length)
           (or (plist-get (cdr entry) :root-length) "an unknown number")))
        (setq again (dired-filetags-bench--settle timing drivers samples ratios threshold skip))
        (dired-filetags-bench--update-summaries results timing)
        (dolist (spec dired-filetags-bench--workloads)
          (let* ((name (car spec))
                 (result (alist-get name (plist-get results :workloads)))
                 (ratio (plist-get result :ratio))
                 (base (alist-get name ratios))
                 (verdict
                  (cond ((not result) nil)
                        ((not (plist-get (cdr spec) :time)) "report")
                        ((not base)
                         (dired-filetags-bench--say
                          "perf: FAILED: %s has no timing baseline; record one with --update" name)
                         (push name failed)
                         "new")
                        ((memq name skip) "not gated")
                        ((< (plist-get result :clean) dired-filetags-bench--min-clean)
                         (dired-filetags-bench--say
                          (concat "perf: NOTE: %s had %d clean samples of %d, too few;"
                                  " its time is NOT gated")
                          name (plist-get result :clean) (plist-get result :count))
                         (push name busy)
                         "not gated")
                        ((> ratio (* threshold base))
                         (dired-filetags-bench--say
                          (concat "perf: FAILED: %s ratio %.4f is %s over its baseline %.4f,"
                                  " with %d clean samples")
                          name ratio (dired-filetags-bench--percent ratio base) base
                          (plist-get result :clean))
                         (push name failed)
                         "FAIL")
                        ((< ratio (/ base threshold))
                         (push name improved)
                         "better")
                        ((memq name again) "ok, re-measured")
                        (t "ok"))))
            (when (memq name again)
              (dired-filetags-bench--annotate results name :first-ratio (alist-get name first)))
            (when verdict
              (dired-filetags-bench--annotate results name :time-verdict verdict :time-base base))))
        (when improved
          (dired-filetags-bench--say
           "perf: %s run %s faster than the baseline; record that with --update"
           (mapconcat #'symbol-name (nreverse improved) ", ")
           (dired-filetags-bench--over threshold)))
        (cons (nreverse failed)
              (let ((notes
                     (delq nil
                           (list (and busy (format "time not gated for %s: too few clean samples"
                                                   (mapconcat #'symbol-name (nreverse busy) ", ")))
                                 (and skip (format (concat "time not gated for %s: the"
                                                           " directory's name differs in length")
                                                   (mapconcat #'symbol-name skip ", ")))))))
                (and notes (string-join notes "; ")))))))))

;;;; Reports

(defun dired-filetags-bench--table (results)
  "Return the summary table of RESULTS as a string."
  (with-temp-buffer
    (insert (format (concat "dired-filetags performance: system %s, host %s, Emacs %s,"
                            " native %s, power %s\n")
                    (plist-get results :system) (plist-get results :host)
                    (plist-get results :emacs) (plist-get results :native)
                    (or (plist-get results :power) "unknown"))
            (format (concat "%d samples per workload; calibration %.2f ms (lower quartile);"
                            " files in a directory whose name has %s characters\n\n")
                    (plist-get results :samples)
                    (* 1000 (plist-get results :calibration))
                    (or (plist-get results :root-length) "an unknown number of"))
            (format "%-16s %5s %9s %8s %8s %7s %5s %6s %10s %10s %7s %s\n"
                    "workload" "reps" "min ms" "ratio" "base" "delta" "clean" "spread"
                    "alloc KiB" "base KiB" "delta" "verdict (time/alloc)"))
    (dolist (spec dired-filetags-bench--workloads)
      (let* ((r (alist-get (car spec) (plist-get results :workloads)))
             (base (plist-get r :time-base))
             (bytes (dired-filetags-bench--bytes
                     (plist-get r :counts)
                     (dired-filetags-bench--gated-counters spec (plist-get results :paths-differ))
                     (plist-get results :sizes)))
             (alloc-base (plist-get r :alloc-base)))
        (when r
          (insert (format "%-16s %5d %9.2f %8.4f %8s %7s %5s %6.3f %10.1f %10s %7s %s/%s\n"
                          (car spec) (plist-get r :reps)
                          (* 1000 (plist-get r :seconds)) (plist-get r :ratio)
                          (if base (format "%.4f" base) "-")
                          (if base (dired-filetags-bench--percent (plist-get r :ratio) base) "-")
                          (if (plist-get r :count)
                              (format "%d/%d" (plist-get r :clean) (plist-get r :count))
                            "-")
                          (plist-get r :spread)
                          (/ bytes 1024.0)
                          (if alloc-base (format "%.1f" (/ alloc-base 1024.0)) "-")
                          (if alloc-base (dired-filetags-bench--percent bytes alloc-base) "-")
                          (or (plist-get r :time-verdict)
                              (if (plist-get (cdr spec) :time) "-" "report"))
                          (or (plist-get r :alloc-verdict) "-"))))))
    (insert (format "\n%-16s %s\n" "counters"
                    (mapconcat (lambda (c) (format "%13s" (substring (symbol-name c) 1)))
                               dired-filetags-bench--counters "")))
    (dolist (spec dired-filetags-bench--workloads)
      (let ((r (alist-get (car spec) (plist-get results :workloads)))
            (gated (dired-filetags-bench--gated-counters
                    spec (plist-get results :paths-differ))))
        (when r
          (insert (format "%-16s %s\n" (car spec)
                          (mapconcat (lambda (c)
                                       (format "%12d%s" (plist-get (plist-get r :counts) c)
                                               (if (memq c gated) " " "*")))
                                     dired-filetags-bench--counters ""))))))
    (insert "\n"
            (if (plist-get results :paths-differ)
                (concat "* not gated: the count grows with the length of the name of the"
                        " directory, which is not the baseline's.\n")
              "")
            "ratio: fastest clean sample over the calibration's lower quartile.\n"
            "clean: samples taken while the calibration ran within 10% of that quartile.\n"
            "spread: slowest sample over the fastest.  alloc: gated counters, in bytes.\n")
    (dolist (spec dired-filetags-bench--workloads)
      (insert (format "%-16s %s\n" (car spec) (plist-get (cdr spec) :doc))))
    (buffer-string)))

(defun dired-filetags-bench--write (file string)
  "Write STRING to FILE as UTF-8."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region string nil file nil 0)))

(defun dired-filetags-bench--results-string (results)
  "Return RESULTS printed for perf.eld, one workload per line."
  (with-temp-buffer
    (insert ";;; perf.eld --- dired-filetags benchmark results  -*- lisp-data -*-\n"
            ";; Written by scripts/bench.el --report; read by --results.\n\n(")
    (let ((first t))
      (cl-loop for (k v) on results by #'cddr
               unless (eq k :workloads)
               do (insert (if first "" " ") (prin1-to-string k) " " (prin1-to-string v))
               (setq first nil)))
    (insert "\n :workloads\n (")
    (let ((first t))
      (dolist (w (plist-get results :workloads))
        (unless first (insert "\n  "))
        (setq first nil)
        (insert (prin1-to-string w))))
    (insert "))\n")
    (buffer-string)))

(defun dired-filetags-bench--elp (drivers)
  "Return the elp table of one run of each of DRIVERS, an alist.
Every function of the package is instrumented, and restored afterwards."
  (let ((functions '()))
    (mapatoms (lambda (sym)
                (let ((name (symbol-name sym)))
                  (when (and (string-prefix-p "dired-filetags-" name)
                             (not (string-prefix-p "dired-filetags-bench-" name))
                             (fboundp sym)
                             (not (macrop sym))
                             (elp-profilable-p sym))
                    (push sym functions)))))
    (unwind-protect
        (progn
          (elp-instrument-list functions)
          (dolist (driver drivers) (funcall (cdr driver)))
          (let ((standard-output #'ignore)
                (elp-sort-by-function #'elp-sort-by-total-time)
                (elp-report-limit 1)
                (elp-reset-after-results t))
            (save-window-excursion (elp-results)))
          (with-current-buffer elp-results-buffer
            (prog1 (concat "elp: one run of each workload, sorted by total seconds\n\n"
                           (buffer-substring-no-properties (point-min) (point-max)))
              (kill-buffer))))
      (elp-restore-list functions))))

(defun dired-filetags-bench--calltree (profile &optional reversed)
  "Return PROFILE rendered as a fully expanded calltree.
With REVERSED, return its bottom-up tree instead, unexpanded: each
function with the samples in which it was running."
  (let ((buffer (profiler-report-setup-buffer profile)))
    (unwind-protect
        (with-current-buffer buffer
          (if reversed
              (profiler-report-render-reversed-calltree)
            (goto-char (point-min))
            (while (not (eobp))
              (profiler-report-expand-entry t)
              (forward-line 1)))
          (buffer-substring-no-properties (point-min) (point-max)))
      (kill-buffer buffer))))

(defun dired-filetags-bench--profile (drivers dir)
  "Profile each of DRIVERS, an alist, three times; write the report to DIR.
That is profile.txt, the CPU and memory calltrees, and cpu.prof and
mem.prof, for `profiler-find-profile'."
  (profiler-reset)
  (profiler-start (if (fboundp 'profiler-cpu-start) 'cpu+mem 'mem))
  (unwind-protect
      ;; Three runs, as some systems sample the CPU only every few ms.
      (dotimes (_ 3)
        (dolist (driver drivers) (funcall (cdr driver))))
    (profiler-stop))
  (let ((cpu (and profiler-cpu-log (profiler-cpu-profile)))
        (mem (and profiler-memory-log (profiler-memory-profile)))
        (make-backup-files nil))
    (dired-filetags-bench--write
     (expand-file-name "profile.txt" dir)
     (concat "profiler: three runs of each workload\n"
             (if (not cpu) "\n(no CPU profile)\n"
               (concat "\nCPU samples by function, bottom-up (count, percent, function)\n"
                       (dired-filetags-bench--calltree cpu t)
                       "\nCPU samples, top-down\n"
                       (dired-filetags-bench--calltree cpu)))
             (if (not mem) "\n(no memory profile)\n"
               (concat "\nBytes allocated by function, bottom-up (bytes, percent, function)\n"
                       (dired-filetags-bench--calltree mem t)
                       "\nBytes allocated, top-down\n"
                       (dired-filetags-bench--calltree mem)))))
    (when cpu (profiler-write-profile cpu (expand-file-name "cpu.prof" dir)))
    (when mem (profiler-write-profile mem (expand-file-name "mem.prof" dir)))
    (profiler-reset)))

;;;; Entry point

(defun dired-filetags-bench--parse-args (args)
  "Return the options in ARGS, a list of strings, as a plist."
  (let (options)
    (while args
      (let ((arg (pop args)))
        (pcase arg
          ("--update" (setq options (plist-put options :update t)))
          ("--single-process" (setq options (plist-put options :single-process t)))
          ((or "--report" "--gate" "--results" "--samples" "--system" "--results-out")
           (unless args (error "Option %s needs a value" arg))
           (setq options (plist-put options (intern (concat ":" (substring arg 2))) (pop args))))
          (_ (error "Unknown argument %S; see the Commentary of scripts/bench.el" arg)))))
    (let ((gate (plist-get options :gate))
          (samples (plist-get options :samples)))
      (unless (member gate '(nil "none" "alloc" "time" "all"))
        (error "The --gate option takes none, alloc, time or all, not %S" gate))
      (when (and (plist-get options :update) (member gate '("alloc" "time" "all")))
        (error "The --update option records baselines, so it takes no --gate"))
      (when (and (plist-get options :results)
                 (or (plist-get options :report) (plist-get options :results-out)))
        (error "The --results option reads a report, so it takes no --report or --results-out"))
      ;; Relative to the directory Emacs started in, not the benchmarks'.
      (dolist (option '(:report :results :results-out))
        (when (plist-get options option)
          (setq options (plist-put options option
                                   (expand-file-name (plist-get options option))))))
      (when samples
        (unless (string-match-p "\\`[1-9][0-9]*\\'" samples)
          (error "The --samples option takes a positive number, not %S" samples))
        (setq options (plist-put options :samples (string-to-number samples)))))
    options))

(defun dired-filetags-bench--run (samples root fallback)
  "Measure every workload with SAMPLES samples, using ROOT for all files.
FALLBACK non-nil says that ROOT is not in `dired-filetags-bench--root-parent'.
Return (RESULTS DRIVERS TIMING): the results plist without :system,
the (NAME . FUNCTION) of each workload, and the timing, as
`dired-filetags-bench--time' returns it, which RESULTS sums up."
  (let* ((fixtures (dired-filetags-bench--setup root))
         ;; Named, so that the profile shows which workload ran.
         (drivers (cl-loop for spec in dired-filetags-bench--workloads
                           for name = (intern (format "dired-filetags-bench--run-%s" (car spec)))
                           do (defalias name (dired-filetags-bench--driver
                                              (car spec) (plist-get (cdr spec) :reps) fixtures)
                                (plist-get (cdr spec) :doc))
                           collect (cons (car spec) name)))
         (workloads '()))
    (setq dired-filetags-bench--calibration-corpus (plist-get fixtures :names))
    (dired-filetags-bench--calibrate)
    (let ((counts (mapcar (lambda (driver)
                            (cons (car driver) (dired-filetags-bench--count (cdr driver))))
                          drivers))
          (timing (dired-filetags-bench--time drivers samples)))
      (dolist (spec dired-filetags-bench--workloads)
        (let ((count (alist-get (car spec) counts)))
          (push (append (list (car spec) :reps (plist-get (cdr spec) :reps))
                        (dired-filetags-bench--summary timing (car spec))
                        (list :counts (car count) :stable (cdr count)))
                workloads)))
      (list (list :version 3
                  :host (dired-filetags-bench--host)
                  :emacs emacs-version
                  :native (dired-filetags-bench--native-p)
                  :power (dired-filetags-bench--power)
                  :root-length (length root)
                  :root-fallback fallback
                  :samples samples
                  :calibration (dired-filetags-bench--calibration timing)
                  :sizes (dired-filetags-bench--sizes)
                  :workloads (nreverse workloads))
            drivers
            timing))))

(defun dired-filetags-bench--report (results drivers dir)
  "Write the report of RESULTS to directory DIR, profiling DRIVERS."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (make-directory dir t)
    (dired-filetags-bench--write (expand-file-name "perf.txt" dir)
                                 (dired-filetags-bench--table results))
    (dired-filetags-bench--write (expand-file-name "perf.eld" dir)
                                 (dired-filetags-bench--results-string results))
    (dired-filetags-bench--write (expand-file-name "elp.txt" dir)
                                 (dired-filetags-bench--elp drivers))
    (dired-filetags-bench--profile drivers dir)
    (dired-filetags-bench--say "perf: wrote the report to %s" dir)))

(defun dired-filetags-bench--median (numbers)
  "Return the median of NUMBERS, a non-empty list."
  (let* ((sorted (sort (copy-sequence numbers) #'<))
         (n (length sorted)))
    (if (cl-oddp n)
        (nth (/ n 2) sorted)
      (/ (+ (nth (1- (/ n 2)) sorted) (nth (/ n 2) sorted)) 2.0))))

(defun dired-filetags-bench--child-results (samples &optional gate)
  "Measure every workload in a new Emacs, with SAMPLES samples.
Return the results it wrote.  It runs this file from the project root,
as the Commentary says, with --results-out and --single-process, so it
pins, sets up and measures on its own.  With GATE non-nil it also
gates its timings, re-measuring as a gate run does, and the results
carry its verdicts; its exit status 1, a failed gate, is expected."
  (let* ((dir (make-temp-file "dired-filetags-bench-child-" t))
         (file (expand-file-name "perf.eld" dir))
         (default-directory (file-name-as-directory
                             (expand-file-name ".." dired-filetags-bench--dir))))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process
                               (expand-file-name invocation-name invocation-directory)
                               nil t nil "-Q" "--batch" "-L" "." "-l" "scripts/bench.el"
                               "-f" "dired-filetags-bench-batch"
                               "--samples" (number-to-string samples)
                               "--results-out" file "--single-process"
                               (and gate '("--gate" "time")))))
            (unless (or (eql status 0) (and gate (eql status 1) (file-exists-p file)))
              (error "A benchmark process exited with status %s:\n%s" status (buffer-string)))
            (or (dired-filetags-bench--read file)
                (error "A benchmark process wrote no results"))))
      (delete-directory dir t))))

(defun dired-filetags-bench--confirm-time (results baselines key samples time)
  "Decide the timing failures in TIME in new Emacs processes.
TIME is what `dired-filetags-bench--gate-time' returned for RESULTS,
\(FAILED . NOTE), with KEY's entry in BASELINES.  So many other
processes that `dired-filetags-bench--runs' measure in all run the
timing gate with SAMPLES samples, and a workload that failed here fails
only if the median of its ratios in all of them, leaving out those of
processes that did not gate its time, is over the threshold.  Return
TIME with the failures that remain, and update the verdicts in
RESULTS."
  (let* ((entry (cdr (assoc key (alist-get 'time baselines))))
         (threshold (dired-filetags-bench--time-threshold (plist-get entry :power)
                                                          (plist-get results :power)))
         (names (seq-filter (lambda (name) (alist-get name (plist-get entry :ratios)))
                            (car time)))
         (runs nil)
         (failed (seq-remove (lambda (name) (memq name names)) (car time))))
    (when names
      (dired-filetags-bench--say
       (concat "perf: %s failed in this Emacs process; measuring the timings in %d more,"
               " as a ratio moves by a percent or two from one process to the next")
       (mapconcat #'symbol-name names ", ") (1- dired-filetags-bench--runs))
      (setq runs (cons results (cl-loop repeat (1- dired-filetags-bench--runs)
                                        collect (dired-filetags-bench--child-results
                                                 samples t)))))
    (dolist (name names)
      (let* ((base (alist-get name (plist-get entry :ratios)))
             (ratios (delq nil (mapcar (lambda (run)
                                         (let ((result (alist-get name (plist-get run :workloads))))
                                           (and (member (plist-get result :time-verdict)
                                                        '("ok" "ok, re-measured" "FAIL" "better"))
                                                (plist-get result :ratio))))
                                       runs)))
             (median (dired-filetags-bench--median ratios)))
        (dired-filetags-bench--say
         "perf: %s ratios %s in %d processes: the median, %.4f, is %s against its baseline %.4f"
         name (mapconcat (lambda (ratio) (format "%.4f" ratio)) ratios " ") (length ratios)
         median (dired-filetags-bench--percent median base) base)
        (if (> median (* threshold base))
            (progn
              (dired-filetags-bench--say "perf: FAILED: %s is still %s over its baseline"
                                         name (dired-filetags-bench--percent median base))
              (push name failed))
          (dired-filetags-bench--annotate results name :time-verdict
                                          (format "ok, median of %d" (length ratios))))))
    (cons (nreverse failed) (cdr time))))

(defun dired-filetags-bench--combine (measured)
  "Combine the results in the list MEASURED for the timing baseline.
Return the first of them, with the median of their calibrations as
:calibration, and :workloads mapping each workload to the median of
their ratios as :ratio."
  (append
   (list :calibration (dired-filetags-bench--median
                       (mapcar (lambda (run) (plist-get run :calibration)) measured))
         :workloads
         (mapcar (lambda (workload)
                   (list (car workload)
                         :ratio (dired-filetags-bench--median
                                 (mapcar (lambda (run)
                                           (plist-get (alist-get (car workload)
                                                                 (plist-get run :workloads))
                                                      :ratio))
                                         measured))))
                 (plist-get (car measured) :workloads)))
   (car measured)))

(defun dired-filetags-bench--record (results baselines system key samples drivers timing)
  "Record SYSTEM's allocation baseline and KEY's timing baseline from RESULTS.
BASELINES are the baselines so far.  First the gated workloads with
too few clean samples in TIMING are measured again, running their
functions from the alist DRIVERS with twice SAMPLES rounds.  Then
`dired-filetags-bench--runs' minus one new Emacs processes
measure the timings again, with SAMPLES samples, and the timing
baseline records the median of the ratios, and of the calibrations,
of all of them.  It is not recorded if a gated workload has fewer
than `dired-filetags-bench--min-clean' clean samples in one of them,
if one of them had another power mode, Emacs or directory, or if
their calibration took more than the upper end of
`dired-filetags-bench--state-range' times as long as that of the entry
it would replace: the machine was then busy, or Emacs ran on an
efficiency core.  Return nil, or (FAILED . NOTE) if the timing
baseline was not recorded."
  (dired-filetags-bench--settle timing drivers samples nil dired-filetags-bench--threshold)
  (dired-filetags-bench--update-summaries results timing)
  (dired-filetags-bench--say "perf: measuring the timings in %d more Emacs processes"
                             (1- dired-filetags-bench--runs))
  (let* ((runs (cons results
                     (cl-loop repeat (1- dired-filetags-bench--runs)
                              collect (dired-filetags-bench--child-results samples))))
         (combined (dired-filetags-bench--combine runs))
         (entry (cdr (assoc key (alist-get 'time baselines))))
         (old (plist-get entry :calibration))
         (limit (cdr (dired-filetags-bench--state-range (plist-get entry :power)
                                                        (plist-get results :power))))
         (calibration (plist-get combined :calibration))
         (few (cl-loop for spec in dired-filetags-bench--workloads
                       when (and (plist-get (cdr spec) :time)
                                 (cl-some (lambda (run)
                                            (let ((result (alist-get (car spec)
                                                                     (plist-get run :workloads))))
                                              (and result (< (plist-get result :clean)
                                                             dired-filetags-bench--min-clean))))
                                          runs))
                       collect (car spec)))
         (changed (cl-loop for property in '(:emacs :native :power :root-length)
                           unless (cl-every (lambda (run) (equal (plist-get run property)
                                                                 (plist-get results property)))
                                            runs)
                           collect (substring (symbol-name property) 1)))
         (slower (and (numberp old) (> old 0) (> (/ calibration old) limit)))
         (baselines (dired-filetags-bench--update-alloc baselines results system)))
    (dolist (spec dired-filetags-bench--workloads)
      (let ((name (car spec)))
        (unless (cl-every (lambda (run)
                            (equal (plist-get (alist-get name (plist-get run :workloads)) :counts)
                                   (plist-get (alist-get name (plist-get results :workloads))
                                              :counts)))
                          runs)
          (dired-filetags-bench--say
           "perf: NOTE: %s allocated differently in another Emacs process" name))
        (when (plist-get (cdr spec) :time)
          (dired-filetags-bench--say
           "perf: %s ratios %s: recording the median, %.4f" name
           (mapconcat (lambda (run)
                        (format "%.4f" (plist-get (alist-get name (plist-get run :workloads))
                                                  :ratio)))
                      runs " ")
           (plist-get (alist-get name (plist-get combined :workloads)) :ratio)))))
    (if (not (or few changed slower))
        (progn (dired-filetags-bench--write-baselines
                (dired-filetags-bench--update-time baselines combined key))
               nil)
      (dired-filetags-bench--say
       "perf: FAILED: the timing baseline for %s is NOT recorded: %s; record it on an idle machine"
       key
       (cond (few
              (format "%s had fewer than %d clean samples"
                      (mapconcat #'symbol-name few ", ") dired-filetags-bench--min-clean))
             (changed
              (format "the Emacs processes differed in %s" (string-join changed ", ")))
             (t
              (format (concat "the calibration took %.1f ms, %.2f times the %.1f ms"
                              " of the entry it would replace, over %.2f")
                      (* 1000 calibration) (/ calibration old) (* 1000 old) limit))))
      (dired-filetags-bench--write-baselines baselines)
      (cons (list 'time-update) (format "timing baseline for %s not recorded" key)))))

(defun dired-filetags-bench--measure-and-gate (options root fallback)
  "Measure, report, gate and update as OPTIONS say, with files below ROOT.
FALLBACK non-nil says that ROOT is not in `dired-filetags-bench--root-parent'.
The pinned package is loaded.  Return (FAILED . NOTES): the names of
the workloads that fail a gate, and notes for the last line of the
output."
  (let* ((gate (or (plist-get options :gate) "none"))
         (samples (or (plist-get options :samples) 5))
         (system (dired-filetags-bench--system (plist-get options :system)))
         (baselines (dired-filetags-bench--read (dired-filetags-bench--baselines-file)))
         (temporary-file-directory (expand-file-name "tmp/" root))
         (dired-filetags-tagtrees-directory (expand-file-name "trees/" root))
         (dired-log-buffer " *dired-filetags-bench-log*")
         (dired-mode-hook nil)
         (dired-filetags-display-style 'right)
         (dired-filetags-tag-faces nil)
         (dired-filetags-program
          (or (executable-find "filetags")
              (error "Cannot find filetags on PATH; run inside nix develop")))
         ;; File lookups stop at ROOT, which is never spelled "~/...".
         (locate-dominating-stop-dir-regexp
          (concat "\\`" (regexp-quote (file-name-directory (directory-file-name root))) "\\'"))
         (abbreviated-home-dir "\\`\\'.")
         (inhibit-message t)
         (message-log-max nil)
         (make-backup-files nil)
         (run (progn (make-directory temporary-file-directory)
                     (make-directory dired-filetags-tagtrees-directory)
                     (dired-filetags-bench--run samples root fallback)))
         (results (plist-put (nth 0 run) :system system))
         (drivers (nth 1 run))
         (timing (nth 2 run))
         (key (format "%s/%s" system (plist-get results :host)))
         (alloc (and (member gate '("alloc" "all"))
                     (dired-filetags-bench--gate-alloc results baselines system)))
         (time (and (member gate '("time" "all"))
                    (dired-filetags-bench--gate-time results baselines key samples drivers timing)))
         (time (if (and (car time) (not (plist-get options :single-process)))
                   (dired-filetags-bench--confirm-time results baselines key samples time)
                 time))
         (update (and (plist-get options :update)
                      (dired-filetags-bench--record results baselines system key
                                                    samples drivers timing))))
    (dired-filetags-bench--say "%s" (dired-filetags-bench--table results))
    (when (plist-get options :report)
      (dired-filetags-bench--report results drivers (plist-get options :report)))
    (when (plist-get options :results-out)
      (dired-filetags-bench--write (plist-get options :results-out)
                                   (dired-filetags-bench--results-string results)))
    (cons (append (car alloc) (car time) (car update))
          (delq nil (list (cdr alloc) (cdr time) (cdr update))))))

(defun dired-filetags-bench--gate-results (options)
  "Gate or update from the results file that OPTIONS name, without measuring.
Return (FAILED . NOTES), as `dired-filetags-bench--measure-and-gate'."
  (let* ((file (expand-file-name (plist-get options :results)))
         (results (or (dired-filetags-bench--read file)
                      (error "Cannot read results from %s" file)))
         (system (or (plist-get options :system) (plist-get results :system)
                     (dired-filetags-bench--system nil)))
         (gate (or (plist-get options :gate) "none"))
         (baselines (dired-filetags-bench--read (dired-filetags-bench--baselines-file)))
         (alloc (and (member gate '("alloc" "all"))
                     (dired-filetags-bench--gate-alloc results baselines system)))
         (timed (member gate '("time" "all"))))
    (when (and (plist-get options :update) (plist-get results :root-fallback))
      (error "%s was measured outside %s; record baselines only from a run inside it"
             file dired-filetags-bench--root-parent))
    (when timed
      (dired-filetags-bench--say
       "perf: NOTE: timings are NOT gated: timings read from a file cannot be re-measured"))
    (dired-filetags-bench--say "%s" (dired-filetags-bench--table results))
    (when (plist-get options :update)
      (dired-filetags-bench--write-baselines
       (dired-filetags-bench--update-alloc baselines results system)))
    (cons (car alloc)
          (delq nil (list (cdr alloc) (and timed "timings not gated: read from a file"))))))

(defun dired-filetags-bench-batch ()
  "Run the benchmarks in batch Emacs, with options from the command line.
See the Commentary of scripts/bench.el.  Exit with status 1 if a gate
fails."
  (let* ((start (float-time))
         (options (dired-filetags-bench--parse-args command-line-args-left))
         (buffers (buffer-list))
         (outcome
          (if (plist-get options :results)
              (dired-filetags-bench--gate-results options)
            (pcase-let ((`(,root . ,fallback) (dired-filetags-bench--make-root)))
              (unwind-protect
                  (progn
                    (when fallback
                      (dired-filetags-bench--say
                       (concat "perf: NOTE: cannot write in %s, so the files are in %s;"
                               " the string-chars and times of %s are gated only against"
                               " baselines measured in a directory with a name as long")
                       dired-filetags-bench--root-parent root (dired-filetags-bench--paths-names))
                      (when (plist-get options :update)
                        (error "Baselines are recorded only from a run in %s"
                               dired-filetags-bench--root-parent)))
                    (dired-filetags-bench--pin (expand-file-name "elc/" root))
                    ;; In a buffer whose directory is absolute:
                    ;; `expand-file-name' re-expands a "~/..." one, as a
                    ;; batch Emacs started below HOME has, on every call.
                    (with-current-buffer (generate-new-buffer " *dired-filetags-bench*")
                      (setq default-directory root)
                      ;; Called by name, so the compiled definition runs.
                      (dired-filetags-bench--measure-and-gate options root fallback)))
                (dolist (buffer (buffer-list))
                  (unless (memq buffer buffers)
                    (with-current-buffer buffer (set-buffer-modified-p nil))
                    (kill-buffer buffer)))
                (delete-directory root t)))))
         (failed (car outcome)))
    (setq command-line-args-left nil)
    (dired-filetags-bench--say "perf: %s in %.1f s%s"
                               (if failed
                                   (format "FAILED: %s" (mapconcat #'symbol-name failed ", "))
                                 "done")
                               (- (float-time) start)
                               (mapconcat (lambda (note) (concat "; NOTE: " note))
                                          (cdr outcome) ""))
    (kill-emacs (if failed 1 0))))

;;; bench.el ends here
