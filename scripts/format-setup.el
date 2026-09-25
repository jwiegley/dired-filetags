;;; format-setup.el --- Prepare batch Emacs for format-all -*- lexical-binding: t; -*-

;;; Commentary:

;; check-format.sh and format.sh load this before running format-all,
;; so that batch formatting indents code as an interactive session does.
;;
;; format-all indents Emacs Lisp in a fresh temporary buffer, which
;; sees only default values.  Batch Emacs defaults `indent-tabs-mode'
;; to t, so every re-indented line would gain tabs; it is nil here.
;;
;; A macro's (declare (indent N)) only takes effect once the macro is
;; defined, and batch Emacs has not loaded the project.  So the
;; top-level `defmacro' and `cl-defmacro' forms of the *.el files in
;; the current directory are evaluated.  Nothing else in them is run.
;;
;; Saving the formatted file would also leave a FILE.el~ backup next
;; to it, so backups are off.

;;; Code:

(require 'cl-lib)

(setq-default indent-tabs-mode nil)
(setq make-backup-files nil)

(dolist (file (directory-files default-directory t "\\.el\\'"))
  (with-temp-buffer
    (insert-file-contents file)
    (condition-case nil
        (while t
          (let ((form (read (current-buffer))))
            (when (memq (car-safe form) '(defmacro cl-defmacro))
              (eval form t))))
      (end-of-file nil))))

;;; format-setup.el ends here
