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
;; the project root, the parent of this file's directory, are
;; evaluated.  Nothing else in them is run.  Only regular files whose
;; names start with neither "." nor "#" are read, which leaves out
;; Emacs's lock files (.#NAME.el, dangling symbolic links that exist
;; while a buffer has unsaved changes).  A file that cannot be read is
;; skipped with a message, so that it cannot stop every other file
;; from being formatted.
;;
;; Saving the formatted file would also leave a FILE.el~ backup next
;; to it, so backups are off.

;;; Code:

(require 'cl-lib)

(setq-default indent-tabs-mode nil)
(setq make-backup-files nil)

(let ((root (file-name-directory
             (directory-file-name (file-name-directory load-file-name)))))
  (dolist (file (directory-files root t "\\`[^.#].*\\.el\\'"))
    (when (file-regular-p file)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (condition-case nil
                (while t
                  (let ((form (read (current-buffer))))
                    (when (memq (car-safe form) '(defmacro cl-defmacro))
                      (eval form t))))
              (end-of-file nil)))
        (error
         (message "format-setup.el: skipped the macros of %s: %s"
                  (file-name-nondirectory file)
                  (error-message-string err)))))))

;;; format-setup.el ends here
