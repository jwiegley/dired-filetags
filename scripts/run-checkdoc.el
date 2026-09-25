;;; run-checkdoc.el --- Batch checkdoc runner -*- lexical-binding: t; -*-

;;; Commentary:

;; Run checkdoc in batch mode on files passed as command-line arguments.
;; Exit non-zero if any warnings are found.

;;; Code:

(require 'checkdoc)

(let ((files command-line-args-left)
      (errors-found nil))
  (setq command-line-args-left nil)
  ;; Pre-create the diagnostic buffer as writable
  (with-current-buffer (get-buffer-create "*checkdoc-batch*")
    (setq buffer-read-only nil)
    (erase-buffer))
  (dolist (file files)
    (with-current-buffer (find-file-noselect file)
      (let ((checkdoc-diagnostic-buffer "*checkdoc-batch*"))
        (condition-case err
            (checkdoc-current-buffer t)
          (error
           (message "checkdoc error in %s: %s" file err)))
        (let ((diag-buf (get-buffer "*checkdoc-batch*")))
          (when diag-buf
            (with-current-buffer diag-buf
              (setq buffer-read-only nil)
              ;; Strip the "*** file: checkdoc-current-buffer" header
              ;; that checkdoc always writes, even with no warnings.
              (goto-char (point-min))
              (while (re-search-forward
                      "^\\*\\*\\* .*: checkdoc-current-buffer\n?"
                      nil t)
                (replace-match ""))
              (let ((content
                     (string-trim (buffer-string)
                                  "[\t\n\r\f ]+"
                                  "[\t\n\r\f ]+")))
                (when (> (length content) 0)
                  (message "checkdoc warnings in %s:\n%s"
                           file
                           content)
                  (setq errors-found t)))
              (erase-buffer)))))))
  (when errors-found
    (kill-emacs 1)))

;;; run-checkdoc.el ends here
