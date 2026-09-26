;;; compile.el --- Compile with every warning as an error -*- lexical-binding: t; -*-

;;; Commentary:

;; Byte- or native-compile the files named on the command line, with
;; every warning enabled and treated as an error.  From the project
;; root, as scripts/lint.sh runs it:
;;
;;   $EMACS -Q --batch -L . -l scripts/compile.el \
;;     -f dired-filetags-compile-batch MODE FILE...
;;
;; where EMACS is the Emacs to use (lint.sh defaults it to the `emacs'
;; on PATH) and MODE is byte or native.
;;
;; `byte-compile-warnings' is `all' rather than t, because t leaves out
;; `docstrings-non-ascii-quotes', and `byte-compile-error-on-warn' is t.
;; The .elc and .eln files go to a temporary directory that is deleted
;; on exit, so none is left next to a source, where Emacs could load it
;; instead of a newer edit.
;;
;; Native mode runs `native-compile' on each file.  It byte-compiles
;; first, with the same settings, and then hands the result to
;; libgccjit in a child Emacs.  A warning the native compiler reports
;; with `display-warning' (types `comp' and `native-compiler') fails
;; the file, and so does a "Warning:" or "Error:" line in the child's
;; output, which Emacs only logs.  An Emacs without a native compiler
;; prints a notice and passes.
;;
;; Every file is compiled, even after one fails.  Emacs exits 1 if any
;; file failed, and 0 otherwise.

;;; Code:

(require 'bytecomp)

(defvar native-comp-jit-compilation)
(defvar native-comp-enable-subr-trampolines)
(defvar native-compile-target-directory)
(defvar comp-log-buffer-name)
(declare-function native-compile "comp" (function-or-file &optional output))

(defvar dired-filetags-compile--warnings nil
  "Native-compiler warnings seen while compiling the current file.")

(defconst dired-filetags-compile--log-warning-regexp
  "^.*\\<\\(?:[Ww]arning\\|[Ee]rror\\): .*$"
  "Regexp for a warning or an error line in the native compiler's log.
It matches Emacs's own \"Warning: \" and \"Error: \" lines as well as
the lower-case ones of libgccjit and the linker.")

(defun dired-filetags-compile--record-warning (type message &rest _)
  "Record MESSAGE when TYPE is a native-compiler warning type.
This is `:before' advice on `display-warning', so the warning is
still shown."
  (when (memq (if (consp type) (car type) type) '(comp native-compiler))
    (push (format "%s" message) dired-filetags-compile--warnings)))

(defun dired-filetags-compile--log-warnings (start)
  "Return the warning lines in the native compiler's log after START.
START is the log buffer's size before the compilation began."
  (let ((buffer (and (boundp 'comp-log-buffer-name)
                     (get-buffer comp-log-buffer-name)))
        (found nil))
    (when buffer
      (with-current-buffer buffer
        (save-excursion
          (goto-char (min (1+ start) (point-max)))
          (let ((case-fold-search nil))
            (while (re-search-forward
                    dired-filetags-compile--log-warning-regexp nil t)
              (push (match-string-no-properties 0) found))))))
    (nreverse found)))

(defun dired-filetags-compile--log-size ()
  "Return the size of the native compiler's log buffer, or 0."
  (let ((buffer (and (boundp 'comp-log-buffer-name)
                     (get-buffer comp-log-buffer-name))))
    (if buffer (buffer-size buffer) 0)))

(defun dired-filetags-compile--byte (file)
  "Byte-compile FILE into the temporary directory.
Return non-nil if it compiled without an error or a warning.  A
file that sets `no-byte-compile' fails, as it escapes the check."
  (condition-case err
      (pcase (byte-compile-file file)
        ('t t)
        ('no-byte-compile
         (message "%s: sets no-byte-compile" file)
         nil))
    (error
     (message "%s: %s" file (error-message-string err))
     nil)))

(defun dired-filetags-compile--native (file)
  "Native-compile FILE into the temporary directory.
Return non-nil if it compiled without an error or a warning."
  (setq dired-filetags-compile--warnings nil)
  (let ((start (dired-filetags-compile--log-size)))
    (condition-case err
        (progn
          (native-compile file)
          (let ((warnings
                 (append (reverse dired-filetags-compile--warnings)
                         (dired-filetags-compile--log-warnings start))))
            (dolist (warning warnings)
              (message "%s: native-compile: %s" file warning))
            (null warnings)))
      (error
       ;; The native compiler puts the file name in the error data.
       (let ((text (error-message-string err)))
         (message "%s" (if (string-prefix-p file text)
                           text
                         (format "%s: %s" file text))))
       nil))))

(defun dired-filetags-compile--dest-file (dir)
  "Return a `byte-compile-dest-file-function' that writes into DIR.
The name of each .elc carries a hash of the source's full name, so
two sources with the same base name do not collide."
  (lambda (source)
    (expand-file-name
     (format "%s-%s.elc"
             (file-name-base source)
             (substring (md5 (expand-file-name source)) 0 8))
     dir)))

(defun dired-filetags-compile--run (mode files)
  "Compile FILES in MODE, `byte' or `native'.
Return the number of files that failed."
  (let ((failed 0)
        (compile (if (eq mode 'native)
                     #'dired-filetags-compile--native
                   #'dired-filetags-compile--byte)))
    (dolist (file files)
      (cond
       ((not (file-readable-p file))
        (message "%s: no such file" file)
        (setq failed (1+ failed)))
       ((funcall compile file)
        (message "%s: %s-compiled cleanly" file mode))
       (t
        (message "%s: %s-compile FAILED" file mode)
        (setq failed (1+ failed)))))
    failed))

(defun dired-filetags-compile-batch ()
  "Compile the files in `command-line-args-left' and exit.
The first argument is the mode, byte or native; the rest are the
files.  Exit with status 1 if any file failed or drew a warning,
2 on a usage error, and 0 otherwise."
  (unless noninteractive
    (user-error "`dired-filetags-compile-batch' is for batch mode only"))
  (let* ((args command-line-args-left)
         (mode (intern (or (car args) "")))
         (files (cdr args)))
    (setq command-line-args-left nil)
    (unless (and (memq mode '(byte native)) files)
      (message "Usage: emacs -Q --batch -L . -l scripts/compile.el \
-f dired-filetags-compile-batch byte|native FILE...")
      (kill-emacs 2))
    (if (and (eq mode 'native)
             (not (and (fboundp 'native-comp-available-p)
                       (native-comp-available-p))))
        (progn
          (message "native-compile: this Emacs has no native compiler; \
skipping %d file(s)" (length files))
          (kill-emacs 0))
      (let* ((dir (make-temp-file "dired-filetags-compile-" t))
             (temporary-file-directory (file-name-as-directory dir))
             (load-prefer-newer t)
             (byte-compile-warnings 'all)
             (byte-compile-error-on-warn t)
             (byte-compile-dest-file-function
              (dired-filetags-compile--dest-file dir))
             (native-comp-jit-compilation nil)
             (native-comp-enable-subr-trampolines dir)
             (native-compile-target-directory dir)
             (failed 0))
        (when (eq mode 'native)
          (advice-add 'display-warning :before
                      #'dired-filetags-compile--record-warning))
        (unwind-protect
            (setq failed (dired-filetags-compile--run mode files))
          (advice-remove 'display-warning
                         #'dired-filetags-compile--record-warning)
          (delete-directory dir t))
        (message "%s-compile: %d file(s), %d failed"
                 mode (length files) failed)
        (kill-emacs (if (zerop failed) 0 1))))))

;;; compile.el ends here
