;;; ert-skip-budget.el --- Fail an ERT run in which too many tests skip -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT counts a skipped test as a pass, and the suite's tests skip when
;; filetags, git, mkfifo or dired-subtree is missing, so a green run
;; could have skipped dozens of them.  Load this file after the suite
;; and before running it:
;;
;;   ${EMACS:-emacs} --batch -Q -L . --eval '(setq load-prefer-newer t)' \
;;     -l ert -l dired-filetags-test.el -l scripts/ert-skip-budget.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; A run in which more than `dired-filetags-skip-budget' tests skip
;; then signals an error once its tests have run.  That makes
;; `ert-run-tests-batch-and-exit' exit with status 2, as for a run that
;; went wrong, and so does the leak check, after its own cleanup.  The
;; budget is one test: of the two case-sensitivity tests, the one that
;; does not fit the file system always skips.
;;
;; The flake's ert and leak checks, `nix run .#test', the pre-commit
;; ert and leak jobs and scripts/coverage.sh all load this file, so
;; the budget is defined once.  Only the count reaches the function
;; that signals, so the backtrace batch Emacs prints holds no test
;; results, which would be megabytes of them.

;;; Code:

(require 'ert)

(defconst dired-filetags-skip-budget 1
  "How many tests may skip in a run of the suite.")

(defun dired-filetags-skip-budget--check (skipped)
  "Signal an error if SKIPPED is more than `dired-filetags-skip-budget'."
  (when (> skipped dired-filetags-skip-budget)
    (error "%d tests skipped, and only %d may; %s" skipped
           dired-filetags-skip-budget
           "is filetags, git or dired-subtree missing?")))

(defun dired-filetags-skip-budget--run (run &rest args)
  "Call RUN, which is `ert-run-tests-batch', with ARGS, and count skips.
Return the statistics that RUN returns."
  (let ((stats (apply run args)))
    (dired-filetags-skip-budget--check (ert-stats-skipped stats))
    stats))

(advice-add 'ert-run-tests-batch :around #'dired-filetags-skip-budget--run)

(provide 'ert-skip-budget)
;;; ert-skip-budget.el ends here
