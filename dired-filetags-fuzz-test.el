;;; dired-filetags-fuzz-test.el --- Property tests for dired-filetags -*- lexical-binding: t; -*-

;;; Commentary:

;; Seeded property tests ("fuzz tests") of the name model and of the
;; stand-in oracle.  Run them from the project directory with
;;
;;   ${EMACS:-emacs} --batch -Q -L . --eval '(setq load-prefer-newer t)' \
;;     -l dired-filetags-fuzz-test.el -f dired-filetags-fuzz-batch-and-exit
;;
;; or with scripts/fuzz.sh: `--check' is the fixed-seed run of the
;; pre-commit hook and of `nix flake check', and without arguments it
;; runs round after round with fresh seeds.
;;
;; DIRED_FILETAGS_FUZZ_SEED (default "dired-filetags") and
;; DIRED_FILETAGS_FUZZ_ITERATIONS (default 1000) choose the inputs.
;; Each property reseeds `random' with "SEED:PROPERTY" and generates
;; all its inputs before checking any, so its inputs depend on the seed
;; alone, whatever the order of the tests, on every system, and on no
;; code of the package: the generators follow the documented rules
;; (which tags can be applied, how filetags reads a name) with code of
;; their own, and with filetags' own reading of names from the oracle
;; below, so editing the package, to fix a failure or while bisecting
;; one, never changes which inputs a seed makes.  The first K inputs of
;; a run are those of a run of K iterations, so the command a failure
;; prints, with --iterations K, regenerates the failing input; the
;; test `dired-filetags-fuzz-rerun-regenerates-inputs' holds every
;; generator to that.  Each property prints a digest of its inputs.  A
;; failure names the property, the seed and the iteration, prints the
;; input and a shrunk one, and gives the command that reproduces it.
;;
;; The parser is compared with filetags itself: DIRED_FILETAGS_PYTHON
;; runs a short program that loads DIRED_FILETAGS_PY, the pinned
;; filetags/__init__.py, and reads each name with its
;; FILE_WITH_TAGS_REGEX.  `nix develop' sets both.  The CLI property
;; runs the real filetags on empty stand-ins, inside
;; `dired-filetags-test--with-dir', and never builds TagTrees.  Without
;; filetags or the oracle those tests skip, and
;; `dired-filetags-fuzz-batch-and-exit' fails on a skip.
;;
;; One difference from filetags is intended: its regexp ends in $,
;; which also matches before a final newline, so filetags reads
;; "a -- b\n" as tagged.  The package reads every name with a newline
;; as untagged, and the properties hold it to that.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'dired-filetags)
(require 'dired-filetags-test)

;;;; Seeds

(defconst dired-filetags-fuzz--default-seed "dired-filetags"
  "The seed used when DIRED_FILETAGS_FUZZ_SEED is unset.")

(defconst dired-filetags-fuzz--default-iterations 1000
  "The inputs per property when DIRED_FILETAGS_FUZZ_ITERATIONS is unset.")

(defun dired-filetags-fuzz--seed ()
  "Return the seed: DIRED_FILETAGS_FUZZ_SEED, or the default."
  (let ((seed (getenv "DIRED_FILETAGS_FUZZ_SEED")))
    (if (member seed '(nil "")) dired-filetags-fuzz--default-seed seed)))

(defun dired-filetags-fuzz--iterations ()
  "Return the inputs per property: DIRED_FILETAGS_FUZZ_ITERATIONS, or the default."
  (let ((n (getenv "DIRED_FILETAGS_FUZZ_ITERATIONS")))
    (cond ((member n '(nil "")) dired-filetags-fuzz--default-iterations)
          ((string-match-p "\\`[1-9][0-9]*\\'" n) (string-to-number n))
          (t (error "DIRED_FILETAGS_FUZZ_ITERATIONS is not a positive integer: %S" n)))))

(defun dired-filetags-fuzz--pick (seq)
  "Return a random element of the non-empty sequence SEQ."
  (elt seq (random (length seq))))

(defun dired-filetags-fuzz--chance (percent)
  "Return non-nil with a probability of PERCENT in 100."
  (< (random 100) percent))

;;;; Generators

(defconst dired-filetags-fuzz--alnum
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  "ASCII letters and digits.")

(defconst dired-filetags-fuzz--punctuation "-._~#+"
  "Punctuation common in file names and tags.")

(defconst dired-filetags-fuzz--letters
  (string #xe9 #xdf #x130 #x131 #x149 #x17f #xfb01 #xfb02
          #x65e5 #xbd #x216b #x212a #xff21 #xff5a #xff10)
  "Letters and digits with special casing, or numeric values.
They are e with acute, sharp s, capital I with dot, dotless i, n
preceded by apostrophe, long s, the ligatures fi and fl, the
ideograph for sun, one half, roman numeral twelve, the Kelvin sign,
and fullwidth A, z and 0.")

(defconst dired-filetags-fuzz--oddities
  (string ?\r ?\v ?\f #x7f #x85 #x9f #xa0 #x1680 #x2003 #x200b
          #x2028 #x2029 #x202f #x3000 #xfeff)
  "Whitespace, control and invisible characters besides space, tab and newline.")

(defconst dired-filetags-fuzz--unsafe-chars
  (concat " \t\n/" (string 1 #x1b #x1f #x7f #x85 #x9f #xa0
                           #x1680 #x2003 #x2028 #x2029 #x3000))
  "Characters that no tag may contain: whitespace, control characters and slash.")

(defconst dired-filetags-fuzz--control-files '(".filetags" ".filetags_tagtrees")
  "The names of filetags' own files, which no tag may be added as.")

(defconst dired-filetags-fuzz--fragments
  '(" -- " " -- " " " "." ".lnk" ".LNK" ".tar.gz" "--")
  "Pieces of name structure that the generators splice in.")

(defconst dired-filetags-fuzz--seed-names
  (delete-dups (append (mapcar #'car dired-filetags-test--vectors)
                       (mapcar #'car dired-filetags-test--reference-names)))
  "The recorded CLI vectors and reference names, which the generators mutate.")

(defun dired-filetags-fuzz--code-point (lo hi)
  "Return a random Unicode scalar value from LO to HI, never NUL or slash."
  (let (char)
    (while (progn (setq char (+ lo (random (- hi lo -1))))
                  (or (<= #xd800 char #xdfff) (memq char '(0 ?/)))))
    char))

(defun dired-filetags-fuzz--char ()
  "Return a random character of a file name, from the weighted alphabet."
  (let ((r (random 100)))
    (cond ((< r 36) (dired-filetags-fuzz--pick dired-filetags-fuzz--alnum))
          ((< r 54) ?\s)
          ((< r 66) (dired-filetags-fuzz--pick dired-filetags-fuzz--punctuation))
          ((< r 67) ?\t)
          ((< r 68) ?\n)
          ((< r 82) (dired-filetags-fuzz--pick dired-filetags-fuzz--letters))
          ((< r 85) #x301)
          ((< r 89) (dired-filetags-fuzz--pick dired-filetags-fuzz--oddities))
          ((< r 96) (dired-filetags-fuzz--code-point 1 #xffff))
          ((< r 99) (dired-filetags-fuzz--code-point #x10000 #x1ffff))
          (t (dired-filetags-fuzz--code-point #x20000 #x3ffff)))))

(defun dired-filetags-fuzz--text (max)
  "Return random text of 1 to about MAX characters, with fragments spliced in."
  (let ((len (1+ (random (1+ (random max)))))
        (n 0)
        parts)
    (while (< n len)
      (let ((piece (if (dired-filetags-fuzz--chance 15)
                       (dired-filetags-fuzz--pick dired-filetags-fuzz--fragments)
                     (string (dired-filetags-fuzz--char)))))
        (push piece parts)
        (setq n (+ n (length piece)))))
    (apply #'concat (nreverse parts))))

(defun dired-filetags-fuzz--word-char ()
  "Return a random character of a base name, mostly a letter or digit."
  (let ((r (random 100)))
    (cond ((< r 70) (dired-filetags-fuzz--pick dired-filetags-fuzz--alnum))
          ((< r 78) ?\s)
          ((< r 86) (dired-filetags-fuzz--pick dired-filetags-fuzz--punctuation))
          ((< r 94) (dired-filetags-fuzz--pick dired-filetags-fuzz--letters))
          (t (dired-filetags-fuzz--char)))))

(defun dired-filetags-fuzz--tag-char ()
  "Return a random character of a tag, mostly a letter or digit."
  (let ((r (random 100)))
    (cond ((< r 72) (dired-filetags-fuzz--pick dired-filetags-fuzz--alnum))
          ((< r 82) (dired-filetags-fuzz--pick dired-filetags-fuzz--punctuation))
          ((< r 91) (dired-filetags-fuzz--pick dired-filetags-fuzz--letters))
          ((< r 93) #x301)
          (t (dired-filetags-fuzz--char)))))

(defun dired-filetags-fuzz--tag ()
  "Return a random tag of one to eight characters, often but not always valid."
  (apply #'string (cl-loop repeat (1+ (random 8)) collect (dired-filetags-fuzz--tag-char))))

(defun dired-filetags-fuzz--plain-tag ()
  "Return a random tag of letters, digits and punctuation."
  (apply #'string
         (cl-loop repeat (1+ (random 8))
                  collect (let ((r (random 100)))
                            (cond ((< r 80) (dired-filetags-fuzz--pick dired-filetags-fuzz--alnum))
                                  ((< r 90) (dired-filetags-fuzz--pick
                                             dired-filetags-fuzz--punctuation))
                                  ((< r 98) (dired-filetags-fuzz--pick dired-filetags-fuzz--letters))
                                  (t #x301))))))

(defun dired-filetags-fuzz--extension ()
  "Return a random extension of one to four characters, usually Python `\\w'."
  (apply #'string
         (cl-loop repeat (1+ (random 4))
                  collect (let ((r (random 100)))
                            (cond ((< r 80) (dired-filetags-fuzz--pick dired-filetags-fuzz--alnum))
                                  ((< r 90) (dired-filetags-fuzz--pick dired-filetags-fuzz--letters))
                                  (t (dired-filetags-fuzz--tag-char)))))))

(defun dired-filetags-fuzz--structured (&optional pool)
  "Return a name built as filetags builds one: BASE -- TAGS.EXT, maybe .lnk.
Half of the tags come from POOL, if it is given."
  (concat (apply #'string (cl-loop repeat (1+ (random 14))
                                   collect (dired-filetags-fuzz--word-char)))
          (and (dired-filetags-fuzz--chance 85)
               (concat " -- "
                       (string-join
                        (cl-loop repeat (1+ (random 4))
                                 collect (if (and pool (dired-filetags-fuzz--chance 50))
                                             (dired-filetags-fuzz--pick pool)
                                           (dired-filetags-fuzz--tag)))
                        " ")))
          (and (dired-filetags-fuzz--chance 65) (concat "." (dired-filetags-fuzz--extension)))
          (and (dired-filetags-fuzz--chance 12)
               (dired-filetags-fuzz--pick '(".lnk" ".LNK" ".Lnk")))))

(defun dired-filetags-fuzz--mutate (name)
  "Return NAME after one to three random edits."
  (dotimes (_ (1+ (random 3)))
    (let* ((i (random (1+ (length name))))
           (end (< i (length name))))
      (setq name
            (pcase (random 6)
              (0 (concat (substring name 0 i) (string (dired-filetags-fuzz--char))
                         (substring name i)))
              (1 (concat (substring name 0 i)
                         (dired-filetags-fuzz--pick dired-filetags-fuzz--fragments)
                         (substring name i)))
              (2 (if end (concat (substring name 0 i) (substring name (1+ i))) name))
              (3 (if end
                     (concat (substring name 0 i) (string (dired-filetags-fuzz--char))
                             (substring name (1+ i)))
                   name))
              (4 (concat name (dired-filetags-fuzz--pick dired-filetags-fuzz--fragments)))
              (_ (let ((j (random (1+ (length name)))))
                   (concat name (substring name (min i j) (max i j)))))))))
  name)

(defun dired-filetags-fuzz--bytes (string)
  "Return the length of STRING in UTF-8."
  (length (encode-coding-string string 'utf-8-unix)))

(defun dired-filetags-fuzz--valid-name-p (name)
  "Return non-nil if NAME can be a basename in the properties.
That is 1 to 60 characters and under 200 bytes of UTF-8, without NUL
or slash, not \".\" or \"..\", and not .filetags in any letter case,
which `dired-filetags--new-names' refuses.  Letter case is ASCII's
and APFS's, which also folds the ligature fi and long s."
  (and (stringp name)
       (< 0 (length name) 61)
       (< (dired-filetags-fuzz--bytes name) 200)
       (not (seq-some (lambda (char) (memq char '(0 ?/))) name))
       (not (member name '("." "..")))
       (not (member ".filetags" (list (dired-filetags-fuzz--ascii-downcase name)
                                      (dired-filetags-fuzz--apfs-fold name))))))

(defun dired-filetags-fuzz--python-word-char-p (char)
  "Return non-nil if CHAR matches Python 3's `\\w': a letter, a number or `_'.
That is Unicode's general categories L and N, as `str.isalnum' reads
them, and the underscore."
  (or (eq char ?_)
      (memq (get-char-code-property char 'general-category)
            '(Lu Ll Lt Lm Lo Nd Nl No))))

(defun dired-filetags-fuzz--ascii-downcase (string)
  "Return STRING with its ASCII capital letters, and only those, downcased."
  (apply #'string (mapcar (lambda (char) (if (<= ?A char ?Z) (+ char 32) char)) string)))

(defun dired-filetags-fuzz--apfs-fold (string)
  "Return STRING case-folded as APFS folds the letters of the control files.
Unicode's full case folding maps the ligature fi to \"fi\" and long s
to \"s\", besides the ASCII capitals."
  (dired-filetags-fuzz--ascii-downcase
   (mapconcat (lambda (char) (pcase char (#xfb01 "fi") (#x17f "s") (_ (string char))))
              string "")))

(defun dired-filetags-fuzz--fit (name)
  "Return NAME cut to at most 60 characters and under 200 bytes of UTF-8."
  (let ((name (if (> (length name) 60) (substring name 0 60) name)))
    (while (>= (dired-filetags-fuzz--bytes name) 200)
      (setq name (substring name 0 -1)))
    name))

(defun dired-filetags-fuzz--name (&optional pool)
  "Return a random valid basename: random text, structured or a mutated vector.
Structured names take half of their tags from POOL, if it is given."
  (let (name)
    (while (not (dired-filetags-fuzz--valid-name-p
                 (setq name (dired-filetags-fuzz--fit
                             (let ((r (random 20)))
                               (cond ((< r 7) (dired-filetags-fuzz--text 60))
                                     ((< r 14) (dired-filetags-fuzz--structured pool))
                                     (t (dired-filetags-fuzz--mutate
                                         (dired-filetags-fuzz--pick
                                          dired-filetags-fuzz--seed-names))))))))))
    name))

(defun dired-filetags-fuzz--accepted-p (tag removing)
  "Return non-nil if TAG can be applied, by the documented rules.
It is checked for removal if REMOVING is non-nil, else for addition.
These are the rules `dired-filetags--check-tags' documents, written
out here so that the generators do not depend on the package: no tag
is empty, contains a slash, whitespace or a control character (by
Unicode's general categories Cc, Zs, Zl and Zp, or by the classes
[:space:] and [:cntrl:] of the standard syntax table), or is
\"cuttimes\"; and an added tag does not start with \"-\", is not \".\",
\"..\" or \"--\", and is not the name of a control file as APFS folds
names.  `dired-filetags-fuzz-check-tags-is-sound' checks the package
against the same rules."
  (and (not (equal tag ""))
       (not (with-syntax-table (standard-syntax-table)
              (string-match-p "[[:space:][:cntrl:]]" tag)))
       (not (seq-some #'dired-filetags-fuzz--unsafe-char-p tag))
       (not (equal tag "cuttimes"))
       (or removing
           (not (or (string-prefix-p "-" tag)
                    (member tag '("." ".." "--"))
                    (member (dired-filetags-fuzz--apfs-fold tag)
                            dired-filetags-fuzz--control-files))))))

(defun dired-filetags-fuzz--tags (max removing &optional pool)
  "Return up to MAX distinct tags that can be applied, by the documented rules.
They are checked for removal if REMOVING is non-nil.  Half of them are
drawn from POOL, if it is given."
  (let ((want (random (1+ max)))
        (tries 0)
        tags)
    (while (and (< (length tags) want) (< (setq tries (1+ tries)) 50))
      (let ((tag (if (and pool (dired-filetags-fuzz--chance 50))
                     (dired-filetags-fuzz--pick pool)
                   (dired-filetags-fuzz--tag))))
        (when (and (not (member tag tags)) (dired-filetags-fuzz--accepted-p tag removing))
          (push tag tags))))
    (nreverse tags)))

(defun dired-filetags-fuzz--control-file-variant ()
  "Return a control file name in random letter case.
Sometimes \"fi\" becomes the ligature U+FB01 or a final \"s\" becomes
long s, U+017F, which APFS also treats as the same name."
  (let ((case-fold-search t)
        (name (mapconcat (lambda (char)
                           (string (if (dired-filetags-fuzz--chance 50) (upcase char) char)))
                         (dired-filetags-fuzz--pick dired-filetags-fuzz--control-files)
                         "")))
    (when (dired-filetags-fuzz--chance 20)
      (setq name (replace-regexp-in-string "fi" (string #xfb01) name t t)))
    (when (dired-filetags-fuzz--chance 20)
      (setq name (replace-regexp-in-string "s\\'" (string #x17f) name t t)))
    name))

(defun dired-filetags-fuzz--unsafe-tag (removing)
  "Return a tag that no retagging may use, for REMOVING or adding."
  (pcase (random (if removing 3 6))
    (0 "")
    (1 (let* ((tag (dired-filetags-fuzz--tag))
              (i (random (1+ (length tag)))))
         (concat (substring tag 0 i)
                 (string (dired-filetags-fuzz--pick dired-filetags-fuzz--unsafe-chars))
                 (substring tag i))))
    (2 "cuttimes")
    (3 (concat "-" (dired-filetags-fuzz--tag)))
    (4 (dired-filetags-fuzz--pick '("." ".." "--")))
    (_ (dired-filetags-fuzz--control-file-variant))))

(defun dired-filetags-fuzz--each (generate)
  "Return a function of N that collects N results of calling GENERATE."
  (lambda (n) (cl-loop repeat n collect (funcall generate))))

;;;; The Python oracle

(defconst dired-filetags-fuzz--oracle-program
  "import importlib.machinery, importlib.util, json, re, sys
loader = importlib.machinery.SourceFileLoader('filetags', sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader('filetags', loader))
loader.exec_module(m)
for line in sys.stdin.buffer:
    stem = m.split_up_filename(json.loads(line)[0])[3]
    g = re.match(m.FILE_WITH_TAGS_REGEX, stem)
    parse = g and [g.group(m.FILE_WITH_TAGS_REGEX_FILENAME_INDEX),
                   g.group(m.FILE_WITH_TAGS_REGEX_TAGLIST_INDEX).split(m.BETWEEN_TAG_SEPARATOR),
                   g.group(m.FILE_WITH_TAGS_REGEX_EXTENSION_INDEX)]
    sys.stdout.write(json.dumps([stem, parse]) + '\\n')
    sys.stdout.flush()
"
  "The program that reads names as filetags does.
Its argument is filetags/__init__.py.  For each line [NAME] of JSON on
standard input, it writes one line [STEM PARSE] of ASCII JSON: STEM is
NAME without a trailing .lnk, as split_up_filename returns it, and
PARSE is null, or the groups of FILE_WITH_TAGS_REGEX matched against
STEM, [BASE, TAGS, EXT], with TAGS split at spaces.")

(defun dired-filetags-fuzz--oracle-p ()
  "Return non-nil if DIRED_FILETAGS_PYTHON and DIRED_FILETAGS_PY are usable."
  (let ((python (getenv "DIRED_FILETAGS_PYTHON"))
        (source (getenv "DIRED_FILETAGS_PY")))
    (and python source (file-executable-p python) (file-readable-p source))))

(defun dired-filetags-fuzz--oracle-start ()
  "Start the Python oracle and return its process."
  (let ((buffer (generate-new-buffer " *dired-filetags-fuzz-oracle*")))
    (with-current-buffer buffer (set-buffer-multibyte nil))
    (make-process :name "dired-filetags-fuzz-oracle"
                  :buffer buffer
                  :command (list (getenv "DIRED_FILETAGS_PYTHON") "-I" "-B" "-W" "ignore"
                                 "-c" dired-filetags-fuzz--oracle-program
                                 (getenv "DIRED_FILETAGS_PY"))
                  :connection-type 'pipe
                  :coding 'binary
                  :noquery t)))

(defun dired-filetags-fuzz--oracle-stop (oracle)
  "Stop the Python process ORACLE and kill its buffer."
  (let ((buffer (process-buffer oracle)))
    (delete-process oracle)
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(defmacro dired-filetags-fuzz--with-oracle (var &rest body)
  "Run BODY with VAR bound to a running Python oracle, stopped afterwards."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,var (dired-filetags-fuzz--oracle-start)))
     (unwind-protect (progn ,@body)
       (dired-filetags-fuzz--oracle-stop ,var))))

(defun dired-filetags-fuzz--json-line (name)
  "Return NAME as a line of UTF-8 JSON for the oracle."
  (let ((json (json-serialize (vector name))))
    (concat (if (multibyte-string-p json) (encode-coding-string json 'utf-8-unix) json) "\n")))

(defun dired-filetags-fuzz--oracle (oracle names)
  "Return filetags' reading (STEM PARSE) of each of NAMES, from process ORACLE.
See `dired-filetags-fuzz--oracle-program'."
  (with-current-buffer (process-buffer oracle)
    (erase-buffer)
    (process-send-string oracle (mapconcat #'dired-filetags-fuzz--json-line names ""))
    (let ((deadline (+ (float-time) 120)))
      (while (< (count-lines (point-min) (progn (goto-char (point-max)) (line-beginning-position)))
                (length names))
        (unless (and (process-live-p oracle) (< (float-time) deadline))
          (error "The filetags oracle failed: %s"
                 (decode-coding-string (buffer-string) 'utf-8-unix)))
        (accept-process-output oracle 1)))
    (let ((readings (mapcar (lambda (line)
                              (json-parse-string line :array-type 'list :null-object nil))
                            (split-string (decode-coding-string (buffer-string) 'utf-8-unix)
                                          "\n" t))))
      (unless (and (length= readings (length names))
                   (seq-every-p (lambda (reading) (length= reading 2)) readings))
        (error "The filetags oracle answered %d lines for %d names: %s"
               (length readings) (length names) (buffer-string)))
      readings)))

;;;; Checking, shrinking and reporting

(defmacro dired-filetags-fuzz--safely (&rest body)
  "Return the value of BODY, or a reason string if BODY signals an error."
  (declare (indent 0) (debug t))
  `(condition-case err (progn ,@body)
     (error (format "signalled %S" err))))

(defun dired-filetags-fuzz--show (object)
  "Return OBJECT printed readably, with control and non-ASCII characters escaped."
  (let ((print-escape-newlines t)
        (print-escape-control-characters t)
        (print-escape-multibyte t)
        (print-length nil)
        (print-level nil))
    (prin1-to-string object)))

(defun dired-filetags-fuzz--inputs (property generate n)
  "Return N inputs of PROPERTY from GENERATE, after reseeding with SEED:PROPERTY."
  (random (format "%s:%s" (dired-filetags-fuzz--seed) property))
  (funcall generate n))

(defun dired-filetags-fuzz--generate (property generate)
  "Return the inputs of PROPERTY, from GENERATE called with the iteration count.
The random seed is reset to SEED:PROPERTY first, and a digest of the
inputs is printed, so that two runs can be compared."
  (let ((inputs (dired-filetags-fuzz--inputs property generate
                                             (dired-filetags-fuzz--iterations))))
    (message "fuzz: %-25s %6d inputs, digest %s" property (length inputs)
             (substring (md5 (dired-filetags-fuzz--show inputs)) 0 16))
    inputs))

(defun dired-filetags-fuzz--count (tally key)
  "Count one more KEY in TALLY, a hash table, unless TALLY is nil."
  (when tally (puthash key (1+ (gethash key tally 0)) tally)))

(defun dired-filetags-fuzz--note (property tally)
  "Print the counts in TALLY, a hash table, for PROPERTY."
  (let (counts)
    (maphash (lambda (key n) (push (format "%s %d" key n) counts)) tally)
    (message "fuzz: %-25s %s" property (string-join (sort counts #'string<) ", "))))

(defun dired-filetags-fuzz--shrinks (input)
  "Return the inputs one step smaller than INPUT.
A string loses one character, a list loses one element or has one
element shrunk, and a vector has one element shrunk."
  (cond ((stringp input)
         (cl-loop for i below (length input)
                  collect (concat (substring input 0 i) (substring input (1+ i)))))
        ((vectorp input)
         (cl-loop for i below (length input)
                  nconc (mapcar (lambda (smaller)
                                  (let ((copy (copy-sequence input)))
                                    (aset copy i smaller)
                                    copy))
                                (dired-filetags-fuzz--shrinks (aref input i)))))
        ((consp input)
         (append (cl-loop for i below (length input)
                          collect (append (seq-take input i) (nthcdr (1+ i) input)))
                 (cl-loop for i below (length input)
                          nconc (mapcar (lambda (smaller)
                                          (append (seq-take input i) (list smaller)
                                                  (nthcdr (1+ i) input)))
                                        (dired-filetags-fuzz--shrinks (nth i input))))))))

(defun dired-filetags-fuzz--shrink (input reason check valid shrinks)
  "Return (INPUT . REASON), greedily shrunk while it still fails.
CHECK maps a list of inputs to their failure reasons, nil for a pass.
Candidates come from SHRINKS and must satisfy VALID."
  (cl-loop repeat 500
           for candidates = (seq-filter valid (seq-uniq (funcall shrinks input)))
           for reasons = (and candidates (funcall check candidates))
           for i = (cl-position-if #'identity reasons)
           while i
           do (setq input (nth i candidates) reason (nth i reasons)))
  (cons input reason))

(defun dired-filetags-fuzz--iteration (index total)
  "Return (DESCRIPTION . ITERATIONS) for input INDEX of TOTAL inputs.
ITERATIONS is the count that regenerates the input."
  (cons (format "iteration %d of %d" (1+ index) total) (1+ index)))

(cl-defun dired-filetags-fuzz--verdict (property inputs check
                                                 &key (valid #'always)
                                                 (shrinks #'dired-filetags-fuzz--shrinks)
                                                 (where #'dired-filetags-fuzz--iteration)
                                                 reasons)
  "Fail the test if CHECK fails on any of INPUTS, the inputs of PROPERTY.
CHECK maps a list of inputs to a list of reasons, nil for a pass;
REASONS, if given, is its result for INPUTS.  The first failing input
is shrunk with SHRINKS over the candidates that satisfy VALID, and
reported with the seed, the place WHERE returns for its index, the
original and the shrunk input, and the command that reruns it."
  (let* ((reasons (or reasons (funcall check inputs)))
         (index (cl-position-if #'identity reasons)))
    (when index
      (let* ((input (nth index inputs))
             (shrunk (dired-filetags-fuzz--shrink input (nth index reasons) check valid shrinks))
             (place (funcall where index (length inputs)))
             (seed (dired-filetags-fuzz--seed))
             (info (format "Property %s, seed %S, %s; %d of %d inputs fail
      Input:  %s
      Shrunk: %s
      Rerun:  scripts/fuzz.sh --seed %s --iterations %d"
                           property seed (car place) (cl-count-if #'identity reasons)
                           (length inputs) (dired-filetags-fuzz--show input)
                           (dired-filetags-fuzz--show (car shrunk))
                           (shell-quote-argument seed) (cdr place))))
        (ert-info (info) (ert-fail (list property (cdr shrunk) (car shrunk))))))))

;;;; Filetags' reading of names, and the retagging model

(defun dired-filetags-fuzz--parse (name reading)
  "Return filetags' parse of NAME from its READING, or nil if untagged.
A name with a newline counts as untagged: the intended exception."
  (unless (string-search "\n" name) (nth 1 reading)))

(defun dired-filetags-fuzz--lnk (name reading)
  "Return \".lnk\" if filetags' READING of NAME stripped a .lnk, else \"\"."
  (if (equal (car reading) name) "" ".lnk"))

(defun dired-filetags-fuzz--lnk-downcase (name)
  "Return NAME with a trailing .lnk in any ASCII case downcased."
  (if (string-suffix-p ".lnk" (dired-filetags-fuzz--ascii-downcase name))
      (concat (substring name 0 -4) ".lnk")
    name))

(defun dired-filetags-fuzz--untagged (name reading)
  "Return NAME without its tags, according to filetags' READING of it.
A trailing .lnk is downcased, as filetags writes it, even where it ends
the base: filetags reads such a base as a .lnk file once untagged."
  (dired-filetags-fuzz--lnk-downcase
   (concat (pcase (dired-filetags-fuzz--parse name reading)
             (`(,base ,_ ,ext) (concat base (and ext (concat "." ext))))
             (_ (car reading)))
           (dired-filetags-fuzz--lnk name reading))))

(defun dired-filetags-fuzz--unfaithful (old old-reading new new-reading adds removes)
  "Return why NEW is not a faithful retagging of OLD, or nil if it is.
OLD-READING and NEW-READING are filetags' readings of the names, and
ADDS and REMOVES the tags requested.  A faithful retagging keeps the
base and the extension, when both names are tagged, and else the name
without tags; it has every added tag, no removed one, and no other new
one; and it has no empty or \"--\" tag."
  (let* ((old-parse (dired-filetags-fuzz--parse old old-reading))
         (new-parse (dired-filetags-fuzz--parse new new-reading))
         (old-tags (nth 1 old-parse))
         (new-tags (nth 1 new-parse)))
    (cond ((and old-parse new-parse
                (not (and (equal (car old-parse) (car new-parse))
                          (equal (nth 2 old-parse) (nth 2 new-parse)))))
           (format "filetags reads base and extension %S, not %S"
                   (list (car new-parse) (nth 2 new-parse))
                   (list (car old-parse) (nth 2 old-parse))))
          ((not (equal (dired-filetags-fuzz--untagged old old-reading)
                       (dired-filetags-fuzz--untagged new new-reading)))
           "the name without tags changed")
          ((seq-find (lambda (tag) (not (member tag new-tags))) adds)
           (format "tag %S was not added" (seq-find (lambda (tag) (not (member tag new-tags))) adds)))
          ((seq-find (lambda (tag) (member tag new-tags)) removes)
           (format "tag %S was not removed" (seq-find (lambda (tag) (member tag new-tags)) removes)))
          ((seq-find (lambda (tag) (not (or (member tag adds)
                                            (and (member tag old-tags) (not (member tag removes))))))
                     new-tags)
           "a tag appeared that was not asked for")
          ((or (member "" new-tags) (member "--" new-tags))
           "the new name has an empty or \"--\" tag"))))

(defun dired-filetags-fuzz--dotted-p (string)
  "Return non-nil if there is a dot in STRING."
  (string-search "." string))

(defun dired-filetags-fuzz--word-p (string)
  "Return non-nil if STRING is a non-empty run of Python `\\w' characters."
  (and (not (equal string "")) (seq-every-p #'dired-filetags-fuzz--python-word-char-p string)))

(defun dired-filetags-fuzz--extension-p (tags)
  "Return non-nil if tag segment TAGS would end in an extension.
That is a dot after its first character followed by Python `\\w' only."
  (let ((dot (cl-position ?. tags :from-end t)))
    (and dot (> dot 0) (dired-filetags-fuzz--word-p (substring tags (1+ dot))))))

(defun dired-filetags-fuzz--removal-states (tags removes)
  "Return each list that TAGS passes through during a removal.
The tags in REMOVES go one at a time, and filetags reads the name anew
after each."
  (let (states)
    (dolist (tag removes (nreverse states))
      (when (member tag tags)
        (setq tags (remove tag tags))
        (push tags states)))))

(defun dired-filetags-fuzz--separable-p (base)
  "Return non-nil if filetags would parse BASE \" -- \" with BASE as the base."
  (eql (string-search " -- " (concat base " -- ") 1) (length base)))

(defun dired-filetags-fuzz--retag (name reading adds removes)
  "Return the name that filetags gives NAME in a retagging, or nil.
The retagging adds ADDS and removes REMOVES, and READING is
filetags' reading of NAME.  The result keeps the base, the
extension and a trailing .lnk, downcased; its tags are the old ones
less REMOVES, then the ADDS that are missing.

Nil means that NAME is not well formed, so that filetags' own rules
need not give that: it has a newline; an empty, \"--\" or repeated tag;
or no extension and a dot anywhere, although tags are added (filetags
adds them before the last dot); or no extension, and tags left, after
any one removal, that would end in one; or, untagged, an extension
that is not Python `\\w',
or a base that the new separator would split.  ADDS from filetags'
built-in exclusive group teststring1 and teststring2 are not well
formed either.  The callers also check the result against filetags'
reading of it with `dired-filetags-fuzz--unfaithful', since a tag left
last can still become a suffix: \"  -- .lnk S2\" less S2 is a .lnk file."
  (let ((stem (car reading))
        (lnk (dired-filetags-fuzz--lnk name reading))
        (parse (dired-filetags-fuzz--parse name reading)))
    (unless (or (string-search "\n" name)
                (seq-intersection adds '("teststring1" "teststring2")))
      (if parse
          (pcase-let ((`(,base ,tags ,ext) parse))
            (let* ((kept (seq-difference tags removes))
                   (added (seq-difference (seq-uniq adds) kept))
                   (new (append kept added)))
              (when (and (not (member "" tags))
                         (not (member "--" tags))
                         (equal tags (seq-uniq tags))
                         (or ext
                             (and (not (and added (seq-some #'dired-filetags-fuzz--dotted-p
                                                            (cons base new))))
                                  (not (seq-some (lambda (state)
                                                   (dired-filetags-fuzz--extension-p
                                                    (string-join state " ")))
                                                 (cons new (dired-filetags-fuzz--removal-states
                                                            tags removes)))))))
                (if (equal new tags)
                    name
                  (concat base (and new (concat " -- " (string-join new " ")))
                          (and ext (concat "." ext)) lnk)))))
        (let* ((dot (cl-position ?. stem :from-end t))
               (base (if dot (substring stem 0 dot) stem))
               (ext (and dot (substring stem (1+ dot))))
               (new (seq-uniq adds)))
          (when (and (dired-filetags-fuzz--separable-p base)
                     (if ext
                         (dired-filetags-fuzz--word-p ext)
                       (not (seq-some #'dired-filetags-fuzz--dotted-p new))))
            (if new
                (concat base " -- " (string-join new " ") (and ext (concat "." ext)) lnk)
              name)))))))

(defun dired-filetags-fuzz--splice (name reading adds removes)
  "Return NAME retagged by splicing, on the tags filetags' READING sees.
ADDS are added and REMOVES removed.  Unlike `dired-filetags-fuzz--retag',
this works on any name, so it can be wrong."
  (let* ((parse (dired-filetags-fuzz--parse name reading))
         (tags (seq-uniq (append (seq-difference (nth 1 parse) removes) adds))))
    (concat (if parse (car parse) (car reading))
            (and tags (concat " -- " (string-join tags " ")))
            (and (nth 2 parse) (concat "." (nth 2 parse)))
            (dired-filetags-fuzz--lnk name reading))))

(defun dired-filetags-fuzz--mutate-retag (name reading)
  "Return NAME, a retagged name, after a random edit of its text or structure.
READING is filetags' reading of NAME, which splits it into its parts."
  (pcase (dired-filetags-fuzz--parse name reading)
    (`(,base ,tags ,ext)
     (let ((ext (if ext (concat "." ext) ""))
           (lnk (substring name (length (car reading)))))
       (pcase (random 9)
         (0 (dired-filetags-fuzz--mutate name))
         ;; The extension moves in front of the tags.
         (1 (concat base ext " -- " (string-join tags " ") lnk))
         (2 (concat base " -- " (string-join (or (butlast tags) '("")) " ") ext lnk))
         (3 (concat base " -- " (string-join (append tags (list (dired-filetags-fuzz--tag))) " ")
                    ext lnk))
         (4 (concat base " -- " (string-join (append tags (last tags)) " ") ext lnk))
         (5 (let ((odd (dired-filetags-fuzz--pick '("" "--"))))
              (concat base " -- " (string-join (append tags (list odd)) " ") ext lnk)))
         (6 (concat base " -- " (string-join tags " ") "." (dired-filetags-fuzz--extension) lnk))
         (7 (concat base " -- " (string-join tags " ") ext
                    (dired-filetags-fuzz--pick '("" ".LNK" ".lnk"))))
         ;; A dot moves into the base.
         (_ (concat base "." (dired-filetags-fuzz--extension) " -- " (string-join tags " ")
                    ext lnk)))))
    (_ (if (dired-filetags-fuzz--chance 50)
           (dired-filetags-fuzz--mutate name)
         (concat name " -- " (dired-filetags-fuzz--tag))))))

;;;; Properties

(defun dired-filetags-fuzz--parse-reason (name reading)
  "Return why `dired-filetags-parse' misreads NAME, given filetags' READING."
  (dired-filetags-fuzz--safely
    (let ((ours (dired-filetags-parse name))
          (theirs (nth 1 reading)))
      (cond ((not (eq (and (dired-filetags--lnk-p name) t) (not (equal (car reading) name))))
             (format "filetags reads the name without .lnk as %S" (car reading)))
            ((string-search "\n" name)
             (and ours (format "parse %S, but a name with a newline is untagged" ours)))
            ((not (equal ours theirs))
             (format "parse %S, filetags %S" ours theirs))))))

(ert-deftest dired-filetags-fuzz-parse-agrees-with-python ()
  "The parser reads every name as filetags' FILE_WITH_TAGS_REGEX does.
The oracle is the pinned filetags source itself.  A name with a newline
must be untagged, although Python's $ matches before a final newline."
  (skip-unless (dired-filetags-fuzz--oracle-p))
  (with-temp-buffer
    (dired-filetags-fuzz--with-oracle oracle
      (let* ((property "parse-agrees-with-python")
             (names (dired-filetags-fuzz--generate
                     property (dired-filetags-fuzz--generator property)))
             (readings (dired-filetags-fuzz--oracle oracle names))
             (tally (make-hash-table :test #'equal)))
        (cl-mapc (lambda (name reading)
                   (dired-filetags-fuzz--count tally (if (nth 1 reading) "tagged" "untagged"))
                   (unless (equal (car reading) name) (dired-filetags-fuzz--count tally ".lnk"))
                   (when (string-search "\n" name)
                     (dired-filetags-fuzz--count tally "newline")
                     (when (nth 1 reading)
                       (dired-filetags-fuzz--count tally "newline-tagged-by-filetags"))))
                 names readings)
        (dired-filetags-fuzz--note property tally)
        (dired-filetags-fuzz--verdict
         property names
         (lambda (batch)
           (cl-mapcar #'dired-filetags-fuzz--parse-reason
                      batch (dired-filetags-fuzz--oracle oracle batch)))
         :reasons (cl-mapcar #'dired-filetags-fuzz--parse-reason names readings)
         :valid #'dired-filetags-fuzz--valid-name-p)))))

(defun dired-filetags-fuzz--round-trip-reason (name)
  "Return why the name model does not round-trip NAME, or nil."
  (dired-filetags-fuzz--safely
    (let* ((lnk (string-suffix-p ".lnk" (dired-filetags-fuzz--ascii-downcase name)))
           (stem (if lnk (substring name 0 -4) name))
           (parse (dired-filetags-parse name))
           (untagged (dired-filetags--untagged-name name)))
      (pcase-let ((`(,base ,tags ,ext) parse))
        (cond ((and parse (or (equal base "") (null tags) (equal ext "")
                              (and ext (dired-filetags-fuzz--dotted-p ext))))
               (format "malformed parse %S" parse))
              ((and parse (not (equal stem (concat base " -- " (string-join tags " ")
                                                   (and ext (concat "." ext))))))
               (format "parse %S does not rebuild %S" parse stem))
              ((not (equal untagged (dired-filetags-fuzz--lnk-downcase
                                     (if parse
                                         (concat base (and ext (concat "." ext)) (and lnk ".lnk"))
                                       (concat stem (and lnk ".lnk"))))))
               (format "untagged name %S" untagged))
              ((not (equal (dired-filetags--untagged-name untagged) untagged))
               (format "untagged name %S is not idempotent" untagged))
              ((not (equal (dired-filetags-tags name) tags))
               (format "tags %S" (dired-filetags-tags name)))
              ((not (equal (dired-filetags--clean-tags name)
                           (seq-remove (lambda (tag) (member tag '("" "--"))) tags)))
               (format "clean tags %S" (dired-filetags--clean-tags name))))))))

(ert-deftest dired-filetags-fuzz-parse-round-trips ()
  "A parse rebuilds the name, and the untagged name drops exactly the tags.
The untagged name is idempotent, and the clean tags are the tags
without empty and \"--\" ones."
  (with-temp-buffer
    (let ((property "parse-round-trips"))
      (dired-filetags-fuzz--verdict
       property
       (dired-filetags-fuzz--generate property (dired-filetags-fuzz--generator property))
       (lambda (names) (mapcar #'dired-filetags-fuzz--round-trip-reason names))
       :valid #'dired-filetags-fuzz--valid-name-p))))

(defun dired-filetags-fuzz--tags-valid-p (adds removes)
  "Return non-nil if two lists of accepted tags are not both empty.
They are ADDS, accepted for adding, and REMOVES, for removing."
  (and (or adds removes)
       (seq-every-p (lambda (tag) (dired-filetags-fuzz--accepted-p tag nil)) adds)
       (seq-every-p (lambda (tag) (dired-filetags-fuzz--accepted-p tag t)) removes)))

(defun dired-filetags-fuzz--adds-and-removes (max-adds max-removes &optional pool)
  "Return two lists of accepted tags, disjoint and not both empty.
They are (ADDS REMOVES), of up to MAX-ADDS and MAX-REMOVES tags, half
of them from POOL if it is given."
  (let (adds removes)
    (while (not (or adds removes))
      (setq adds (dired-filetags-fuzz--tags max-adds nil pool)
            removes (seq-difference (dired-filetags-fuzz--tags max-removes t pool) adds)))
    (list adds removes)))

(ert-deftest dired-filetags-fuzz-tokens-round-trip ()
  "The --tags value splits into the removals, prefixed with -, then the additions."
  (with-temp-buffer
    (let ((property "tokens-round-trip"))
      (dired-filetags-fuzz--verdict
       property
       (dired-filetags-fuzz--generate property (dired-filetags-fuzz--generator property))
       (lambda (inputs)
         (mapcar (lambda (input)
                   (pcase-let ((`[,adds ,removes] input))
                     (dired-filetags-fuzz--safely
                       (let ((tokens (dired-filetags--tokens adds removes)))
                         (unless (equal (split-string tokens " ")
                                        (append (mapcar (lambda (tag) (concat "-" tag)) removes)
                                                adds))
                           (format "tokens %S" tokens))))))
                 inputs))
       :valid (lambda (input) (dired-filetags-fuzz--tags-valid-p (aref input 0) (aref input 1)))))))

(defun dired-filetags-fuzz--control-file-p (tag probe)
  "Return non-nil if TAG names a control file, in some letter case.
That is so if TAG equals a control file name up to ASCII case, or if
the filesystem finds TAG in directory PROBE, which holds just the two
control files: on APFS that also catches the ligature fi and long s."
  (or (member (dired-filetags-fuzz--ascii-downcase tag) dired-filetags-fuzz--control-files)
      (and (not (member tag '("" "." "..")))
           (not (seq-some (lambda (char) (memq char '(0 ?/))) tag))
           (let ((file-name-handler-alist nil))
             (file-exists-p (concat probe tag))))))

(defmacro dired-filetags-fuzz--with-probe (var &rest body)
  "Run BODY with VAR bound to a temporary directory holding the control files."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,var (file-name-as-directory (make-temp-file "dired-filetags-fuzz-" t))))
     (unwind-protect
         (progn (dolist (file dired-filetags-fuzz--control-files)
                  (let ((file-name-handler-alist nil))
                    (write-region "" nil (concat ,var file) nil 0)))
                ,@body)
       (delete-directory ,var t))))

(defun dired-filetags-fuzz--unsafe-char-p (char)
  "Return non-nil if CHAR is whitespace, a control character or a slash.
Whitespace is Unicode's space separators and line and paragraph
separators; control characters are Unicode's category Cc."
  (or (eq char ?/)
      (memq (get-char-code-property char 'general-category) '(Cc Zs Zl Zp))))

(defun dired-filetags-fuzz--tag-ok-p (tag removing probe)
  "Return non-nil if TAG meets the documented constraints, for REMOVING or adding.
No tag is empty, has whitespace, a control character or a slash, or is
\"cuttimes\".  An added tag also does not start with \"-\", is not
\".\", \"..\" or \"--\", and is not a control file name in any case,
which PROBE decides as `dired-filetags-fuzz--control-file-p' does."
  (and (not (equal tag ""))
       (not (seq-some #'dired-filetags-fuzz--unsafe-char-p tag))
       (not (equal tag "cuttimes"))
       (or removing
           (not (or (string-prefix-p "-" tag)
                    (member tag '("." ".." "--"))
                    (dired-filetags-fuzz--control-file-p tag probe))))))

(defun dired-filetags-fuzz--plain-p (tag removing probe)
  "Return non-nil if TAG is plainly fine, for REMOVING or adding.
That is: it meets the constraints, judged with PROBE, and has only
letters, marks, numbers and -._~#+.  An added tag must also not be a
control file name under APFS's folding, which counts on every system."
  (and (dired-filetags-fuzz--tag-ok-p tag removing probe)
       (or removing
           (not (member (dired-filetags-fuzz--apfs-fold tag) dired-filetags-fuzz--control-files)))
       (seq-every-p (lambda (char)
                      (or (memq char '(?- ?. ?_ ?~ ?# ?+))
                          (memq (get-char-code-property char 'general-category)
                                '(Lu Ll Lt Lm Lo Mn Mc Me Nd Nl No))))
                    tag)))

(defun dired-filetags-fuzz--check-tags-reason (probe input)
  "Return why `dired-filetags--check-tags' mishandles INPUT, [TAGS REMOVING].
PROBE decides which tags name control files."
  (pcase-let ((`[,tags ,removing] input))
    (dired-filetags-fuzz--safely
      (let ((result (condition-case nil
                        (list (dired-filetags--check-tags tags removing))
                      (user-error nil)))
            (bad (seq-find (lambda (tag) (not (dired-filetags-fuzz--tag-ok-p tag removing probe)))
                           tags)))
        (cond ((and result (not (eq (car result) tags))) "did not return its argument")
              ((and result (null tags)) "accepted no tags")
              ((and result bad) (format "accepted %S" bad))
              ((and (not result) tags
                    (seq-every-p (lambda (tag) (dired-filetags-fuzz--plain-p tag removing probe))
                                 tags))
               "refused plain tags"))))))

(defun dired-filetags-fuzz--check-tags-input ()
  "Return a random input of the check-tags property: [TAGS REMOVING]."
  (let ((removing (dired-filetags-fuzz--chance 40)))
    (vector (cl-loop repeat (random 5)
                     collect (pcase (random 4)
                               (0 (dired-filetags-fuzz--unsafe-tag removing))
                               (1 (dired-filetags-fuzz--tag))
                               (_ (dired-filetags-fuzz--plain-tag))))
            removing)))

(ert-deftest dired-filetags-fuzz-check-tags-is-sound ()
  "Accepted tags meet the documented constraints; plain tags are accepted.
Whitespace and control characters are Unicode's, whatever the syntax
table says.  A control file name matches in ASCII case, and wherever
the filesystem says it does, as APFS does for the ligature fi."
  (dired-filetags-fuzz--with-probe probe
    (let ((property "check-tags-is-sound"))
      (dired-filetags-fuzz--verdict
       property
       (dired-filetags-fuzz--generate property (dired-filetags-fuzz--generator property))
       (lambda (inputs)
         (with-temp-buffer
           (mapcar (apply-partially #'dired-filetags-fuzz--check-tags-reason probe) inputs)))))))

(defun dired-filetags-fuzz--reseed (property index &optional part)
  "Reseed `random' for input INDEX of PROPERTY, and for PART of it if given.
What is drawn next depends on the seed, PROPERTY, INDEX and PART alone,
not on how many inputs come before or after INDEX."
  (random (format "%s:%s:%d%s" (dired-filetags-fuzz--seed) property index
                  (if part (format ":%s" part) ""))))

(defun dired-filetags-fuzz--clean-tags (name reading)
  "Return the tags of NAME in filetags' READING of it, without empty and \"--\" ones."
  (seq-remove (lambda (tag) (member tag '("" "--")))
              (nth 1 (dired-filetags-fuzz--parse name reading))))

(defun dired-filetags-fuzz--verify-inputs (oracle property n)
  "Return N inputs of the verify property PROPERTY, with ORACLE to read names.
Each is [KIND OLD NEW ADDS REMOVES].  KIND is `constructed' (NEW is nil
and is computed by the check), or `pair' (NEW is a mutated retagging,
or a random name).

The old names come first, one after another from the property's
stream, so the first K of them do not depend on N.  Everything else
about input I is drawn after reseeding for I: the tags, which half the
time are tags OLD has, as filetags reads it; the kind; and, after
filetags has read the retagged name, its mutation.  So input I is the
same in a run of I+1 inputs, which is what the command a failure
prints reruns."
  (let* ((olds (cl-loop repeat n collect (dired-filetags-fuzz--name)))
         (old-readings (dired-filetags-fuzz--oracle oracle olds))
         (plans
          (cl-loop
           for old in olds
           for reading in old-readings
           for i from 0
           collect (progn
                     (dired-filetags-fuzz--reseed property i)
                     (pcase-let* ((`(,adds ,removes)
                                   (dired-filetags-fuzz--adds-and-removes
                                    3 2 (dired-filetags-fuzz--clean-tags old reading)))
                                  (kind (random 10)))
                       (list old adds removes kind
                             (and (<= 5 kind 7)
                                  (or (dired-filetags-fuzz--retag old reading adds removes)
                                      (dired-filetags-fuzz--splice old reading adds removes))))))))
         (retaggings (delq nil (mapcar (lambda (plan) (nth 4 plan)) plans)))
         (retagging-readings (dired-filetags-fuzz--oracle oracle retaggings)))
    (cl-loop
     for plan in plans
     for i from 0
     collect (pcase-let ((`(,old ,adds ,removes ,kind ,retagged) plan))
               (dired-filetags-fuzz--reseed property i "new")
               (cond ((< kind 5) (vector 'constructed old nil adds removes))
                     ((< kind 8)
                      (let ((new (dired-filetags-fuzz--fit
                                  (dired-filetags-fuzz--mutate-retag
                                   retagged (pop retagging-readings)))))
                        (vector 'pair old
                                (if (dired-filetags-fuzz--valid-name-p new)
                                    new
                                  (dired-filetags-fuzz--name))
                                adds removes)))
                     (t (vector 'pair old (dired-filetags-fuzz--name) adds removes)))))))

(defun dired-filetags-fuzz--verify-reasons (oracle inputs &optional tally)
  "Return why `dired-filetags--verify' mishandles each of INPUTS, or nil.
ORACLE reads the names; TALLY, a hash table, counts the outcomes.
Accepting an unfaithful pair is a failure, and so is refusing a
constructed pair of a well-formed name.  A name is well formed if
`dired-filetags-fuzz--retag' predicts a result that is faithful by
filetags' own reading of it."
  (let* ((olds (mapcar (lambda (input) (aref input 1)) inputs))
         (old-readings (dired-filetags-fuzz--oracle oracle olds))
         (expected (cl-mapcar (lambda (input reading)
                                (and (eq (aref input 0) 'constructed)
                                     (dired-filetags-fuzz--retag (aref input 1) reading
                                                                 (aref input 3) (aref input 4))))
                              inputs old-readings))
         (news (cl-mapcar (lambda (input reading retagged)
                            (cond ((eq (aref input 0) 'pair) (aref input 2))
                                  (retagged)
                                  (t (dired-filetags-fuzz--splice (aref input 1) reading
                                                                  (aref input 3) (aref input 4)))))
                          inputs old-readings expected))
         (new-readings (dired-filetags-fuzz--oracle oracle news)))
    (cl-mapcar
     (lambda (input old-reading new new-reading retagged)
       (pcase-let ((`[,kind ,old ,_ ,adds ,removes] input))
         (dired-filetags-fuzz--safely
           (let ((refusal (dired-filetags--verify old new adds removes))
                 (why (dired-filetags-fuzz--unfaithful old old-reading new new-reading adds removes)))
             (when (and retagged why)
               (dired-filetags-fuzz--count tally "model-rejected")
               (setq retagged nil))
             (dired-filetags-fuzz--count tally (format "%s-%s" kind (if refusal "refused" "accepted")))
             (when retagged (dired-filetags-fuzz--count tally "well-formed"))
             (cond ((and retagged refusal) (format "refused %S: %s" new refusal))
                   ((and (not refusal) why) (format "accepted %S, but %s" new why)))))))
     inputs old-readings news new-readings expected)))

(defun dired-filetags-fuzz--verify-valid-p (input)
  "Return non-nil if INPUT is a valid input of the verify property.
INPUT is [KIND OLD NEW ADDS REMOVES]."
  (pcase-let ((`[,kind ,old ,new ,adds ,removes] input))
    (and (dired-filetags-fuzz--valid-name-p old)
         (or (eq kind 'constructed) (dired-filetags-fuzz--valid-name-p new))
         (dired-filetags-fuzz--tags-valid-p adds removes)
         (not (seq-intersection adds removes)))))

(ert-deftest dired-filetags-fuzz-verify-is-sound ()
  "Verify accepts only faithful retaggings, and every well-formed one.
Faithfulness is judged on filetags' own reading of both names."
  (skip-unless (dired-filetags-fuzz--oracle-p))
  (with-temp-buffer
    (dired-filetags-fuzz--with-oracle oracle
      (let* ((property "verify-is-sound")
             (inputs (dired-filetags-fuzz--generate
                      property (dired-filetags-fuzz--generator property oracle)))
             (tally (make-hash-table :test #'equal))
             (reasons (dired-filetags-fuzz--verify-reasons oracle inputs tally)))
        (dired-filetags-fuzz--note property tally)
        (dired-filetags-fuzz--verdict
         property inputs (apply-partially #'dired-filetags-fuzz--verify-reasons oracle)
         :reasons reasons :valid #'dired-filetags-fuzz--verify-valid-p)))))

(defconst dired-filetags-fuzz--batch-size 16
  "Names per filetags call in the CLI property.")

(defun dired-filetags-fuzz--cli-inputs (n)
  "Return the units of the CLI property, for N iterations.
Each unit is [BATCH ADDS REMOVES NAME].  There are ceil(N/50) batches
of `dired-filetags-fuzz--batch-size' names that share ADDS and
REMOVES.  ADDS take at most 40 bytes, so that no new name exceeds the
255 bytes of a file name."
  (cl-loop
   for batch below (ceiling n 50)
   nconc (pcase-let ((`(,adds ,removes) (dired-filetags-fuzz--adds-and-removes 3 2)))
           (while (> (apply #'+ (mapcar #'dired-filetags-fuzz--bytes adds)) 40)
             (setq adds (butlast adds)))
           (unless (or adds removes) (setq adds '("fuzz")))
           (cl-loop repeat dired-filetags-fuzz--batch-size
                    collect (vector batch adds removes
                                    (dired-filetags-fuzz--name (append adds removes)))))))

(defun dired-filetags-fuzz--creatable-p (dir name)
  "Return non-nil if the filesystem accepts NAME as a file in directory DIR.
APFS refuses unassigned code points, for example."
  (let ((file-name-handler-alist nil)
        (file (concat dir name)))
    (condition-case nil
        (progn (write-region "" nil file nil 0) (delete-file file) t)
      (file-error nil))))

(defun dired-filetags-fuzz--cli-run (names tokens)
  "Return what filetags renames each of NAMES to, for --tags=TOKENS.
Each result is a name, or (error MESSAGE) if filetags failed on it."
  (condition-case nil
      (dired-filetags--new-names names tokens nil)
    (error (mapcar (lambda (name)
                     (condition-case err
                         (car (dired-filetags--new-names (list name) tokens nil))
                       (error (list 'error (error-message-string err)))))
                   names))))

(defun dired-filetags-fuzz--cli-reasons (oracle root units &optional tally)
  "Return why the real filetags or `dired-filetags--verify' fails each of UNITS.
Units that share a batch go to filetags in one call.  ORACLE reads the
names, and TALLY, a hash table, counts the outcomes.  An accepted
unfaithful result is a failure, and so is a well-formed name whose
result is refused or is not the expected one.

Names, and added tags, that the filesystem refuses are probed in a
directory below ROOT and skipped: APFS refuses unassigned code points,
and filetags then fails on every name of the batch."
  (let* ((probe (file-name-as-directory (make-temp-file (expand-file-name "probe-" root) t)))
         (creatable-p (apply-partially #'dired-filetags-fuzz--creatable-p probe))
         (creatable (mapcar (lambda (unit)
                              (seq-every-p creatable-p (cons (aref unit 3) (aref unit 1))))
                            units))
         (results (make-hash-table :test #'eq)))
    (delete-directory probe t)
    (pcase-dolist (`(,key . ,group)
                   (seq-group-by (lambda (unit) (seq-subseq unit 0 3))
                                 (cl-loop for unit in units for ok in creatable
                                          when ok collect unit)))
      (cl-mapc (lambda (unit result) (puthash unit result results))
               group
               (dired-filetags-fuzz--cli-run (mapcar (lambda (unit) (aref unit 3)) group)
                                             (dired-filetags--tokens (aref key 1) (aref key 2)))))
    (let* ((n (length units))
           (olds (mapcar (lambda (unit) (aref unit 3)) units))
           (old-readings (dired-filetags-fuzz--oracle oracle olds))
           (expecteds (cl-mapcar (lambda (unit reading)
                                   (dired-filetags-fuzz--retag (aref unit 3) reading
                                                               (aref unit 1) (aref unit 2)))
                                 units old-readings))
           (news (mapcar (lambda (unit)
                           (let ((result (gethash unit results))) (if (stringp result) result "x")))
                         units))
           (readings (dired-filetags-fuzz--oracle
                      oracle (append news (mapcar (lambda (name) (or name "x")) expecteds)))))
      (cl-mapcar
       (lambda (unit ok old-reading new-reading expected expected-reading)
         (pcase-let ((`[,_ ,adds ,removes ,old] unit)
                     (result (gethash unit results)))
           (cond ((not ok) (dired-filetags-fuzz--count tally "unwritable") nil)
                 ((not (stringp result)) (format "filetags failed on %S: %s" old (cadr result)))
                 (t (dired-filetags-fuzz--safely
                      (when (and expected
                                 (dired-filetags-fuzz--unfaithful old old-reading expected
                                                                  expected-reading adds removes))
                        (dired-filetags-fuzz--count tally "model-rejected")
                        (setq expected nil))
                      (let ((refusal (dired-filetags--verify old result adds removes)))
                        (dired-filetags-fuzz--count tally (if refusal "refused" "accepted"))
                        (when expected (dired-filetags-fuzz--count tally "well-formed"))
                        (cond ((and expected (not (equal result expected)))
                               (format "filetags gave %S, expected %S" result expected))
                              ((and expected refusal) (format "refused %S: %s" result refusal))
                              ((not refusal)
                               (when-let* ((why (dired-filetags-fuzz--unfaithful
                                                 old old-reading result new-reading adds removes)))
                                 (format "accepted %S, but %s" result why))))))))))
       units creatable old-readings (seq-take readings n) expecteds (nthcdr n readings)))))

(defun dired-filetags-fuzz--cli-where (index total)
  "Return (DESCRIPTION . ITERATIONS) for unit INDEX of TOTAL CLI units.
Units come in batches, one per 50 iterations, so ITERATIONS is the
count that generates INDEX's batch."
  (let ((batch (/ index dired-filetags-fuzz--batch-size)))
    (cons (format "batch %d of %d, name %d" (1+ batch)
                  (ceiling total dired-filetags-fuzz--batch-size)
                  (1+ (% index dired-filetags-fuzz--batch-size)))
          (* 50 (1+ batch)))))

(ert-deftest dired-filetags-fuzz-cli-retag-agrees ()
  "The real filetags retags well-formed names as expected, and verify is sound.
Batches of names go through `dired-filetags--new-names', with no
vocabulary, inside the test fixture.  Names that the filesystem
refuses are counted and skipped."
  (skip-unless (executable-find "filetags"))
  (skip-unless (dired-filetags-fuzz--oracle-p))
  (dired-filetags-fuzz--with-oracle oracle
    (dired-filetags-test--with-dir ()
      (let* ((property "cli-retag-agrees")
             (units (dired-filetags-fuzz--generate property (dired-filetags-fuzz--generator property)))
             (tally (make-hash-table :test #'equal))
             (reasons (dired-filetags-fuzz--cli-reasons oracle root units tally)))
        (puthash "batches" (ceiling (length units) dired-filetags-fuzz--batch-size) tally)
        (dired-filetags-fuzz--note property tally)
        (dired-filetags-fuzz--verdict
         property units (lambda (batch) (dired-filetags-fuzz--cli-reasons oracle root batch))
         :reasons reasons
         :valid (lambda (unit) (dired-filetags-fuzz--valid-name-p (aref unit 3)))
         :shrinks (lambda (unit)
                    (mapcar (lambda (name)
                              (let ((copy (copy-sequence unit))) (aset copy 3 name) copy))
                            (dired-filetags-fuzz--shrinks (aref unit 3))))
         :where (dired-filetags-fuzz--where property))))))

(ert-deftest dired-filetags-fuzz-fold-is-idempotent ()
  "Folding a folded name changes nothing."
  (with-temp-buffer
    (let ((property "fold-is-idempotent"))
      (dired-filetags-fuzz--verdict
       property
       (dired-filetags-fuzz--generate property (dired-filetags-fuzz--generator property))
       (lambda (names)
         (mapcar (lambda (name)
                   (dired-filetags-fuzz--safely
                     (let ((folded (dired-filetags--fold name)))
                       (unless (equal (dired-filetags--fold folded) folded)
                         (format "%S folds to %S, then to %S"
                                 name folded (dired-filetags--fold folded))))))
                 names))))))

(defconst dired-filetags-fuzz--tag-pool
  (list "a" "b" "c" "A" (string #xe9) (string ?e #x301) "x.y" "--" "")
  "A few tags, including near misses, for the match property.")

(defun dired-filetags-fuzz--match-tag ()
  "Return a tag for the match property: usually one of a few near misses."
  (if (dired-filetags-fuzz--chance 75)
      (dired-filetags-fuzz--pick dired-filetags-fuzz--tag-pool)
    (dired-filetags-fuzz--tag)))

(defun dired-filetags-fuzz--match-input ()
  "Return a random input of the match property: [FILE-TAGS TAGS]."
  (vector (cl-loop repeat (random 5) collect (dired-filetags-fuzz--match-tag))
          (cl-loop repeat (random 4) collect (dired-filetags-fuzz--match-tag))))

(ert-deftest dired-filetags-fuzz-match-p-complements ()
  "`any' and `none' are complements, and no tags at all means any tag."
  (with-temp-buffer
    (let ((property "match-p-complements"))
      (dired-filetags-fuzz--verdict
       property
       (dired-filetags-fuzz--generate property (dired-filetags-fuzz--generator property))
       (lambda (inputs)
         (mapcar (lambda (input)
                   (pcase-let ((`[,file-tags ,tags] input))
                     (dired-filetags-fuzz--safely
                       (let ((any (dired-filetags--match-p file-tags tags 'any))
                             (none (dired-filetags--match-p file-tags tags 'none))
                             (expected (if tags
                                           (and (cl-intersection tags file-tags :test #'equal) t)
                                         (and file-tags t))))
                         (cond ((not (and (memq any '(t nil)) (memq none '(t nil))))
                                (format "not booleans: %S %S" any none))
                               ((eq any none) (format "any %S and none %S" any none))
                               ((not (eq any expected))
                                (format "any %S, expected %S" any expected)))))))
                 inputs))))))

(defun dired-filetags-fuzz--paths (k depth)
  "Return the number of ordered paths of 1 to DEPTH distinct tags out of K.
The paths are enumerated one by one."
  (let ((count 0))
    (cl-labels ((walk (used length)
                  (when (< length depth)
                    (dotimes (tag k)
                      (unless (memq tag used)
                        (setq count (1+ count))
                        (walk (cons tag used) (1+ length)))))))
      (walk nil 0))
    count))

(ert-deftest dired-filetags-fuzz-permutations-counts-paths ()
  "The TagTree link estimate is the number of ordered tag paths."
  (with-temp-buffer
    (let ((property "permutations-counts-paths")
          (counted (make-hash-table :test #'equal)))
      (dired-filetags-fuzz--verdict
       property
       (dired-filetags-fuzz--generate property (dired-filetags-fuzz--generator property))
       (lambda (inputs)
         (mapcar (lambda (input)
                   (pcase-let ((`[,k ,depth] input))
                     (dired-filetags-fuzz--safely
                       (let ((ours (dired-filetags--permutations k depth))
                             (paths (with-memoization (gethash input counted)
                                      (dired-filetags-fuzz--paths k depth))))
                         (unless (eql ours paths)
                           (format "%S, but there are %d paths" ours paths))))))
                 inputs))))))

;;;; Generators by property, and replaying a failure

(defconst dired-filetags-fuzz--properties
  '("parse-agrees-with-python" "parse-round-trips" "tokens-round-trip"
    "check-tags-is-sound" "verify-is-sound" "cli-retag-agrees"
    "fold-is-idempotent" "match-p-complements" "permutations-counts-paths")
  "Every property, by the name that seeds its inputs.")

(defun dired-filetags-fuzz--generator (property &optional oracle)
  "Return the generator of PROPERTY, a function from N to N inputs.
ORACLE, a running Python oracle, reads names for the generator of the
verify property, which needs it."
  (pcase property
    ((or "parse-agrees-with-python" "parse-round-trips" "fold-is-idempotent")
     (dired-filetags-fuzz--each #'dired-filetags-fuzz--name))
    ("tokens-round-trip"
     (dired-filetags-fuzz--each
      (lambda () (apply #'vector (dired-filetags-fuzz--adds-and-removes 4 3)))))
    ("check-tags-is-sound" (dired-filetags-fuzz--each #'dired-filetags-fuzz--check-tags-input))
    ("verify-is-sound"
     (unless oracle (error "The verify property's generator needs the oracle"))
     (apply-partially #'dired-filetags-fuzz--verify-inputs oracle property))
    ("cli-retag-agrees" #'dired-filetags-fuzz--cli-inputs)
    ("match-p-complements" (dired-filetags-fuzz--each #'dired-filetags-fuzz--match-input))
    ("permutations-counts-paths"
     (dired-filetags-fuzz--each (lambda () (vector (random 8) (random 5)))))
    (_ (error "No generator for the property %S" property))))

(defun dired-filetags-fuzz--where (property)
  "Return the function that places a failing input of PROPERTY.
See the argument WHERE of `dired-filetags-fuzz--verdict'."
  (if (equal property "cli-retag-agrees")
      #'dired-filetags-fuzz--cli-where
    #'dired-filetags-fuzz--iteration))

(ert-deftest dired-filetags-fuzz-rerun-regenerates-inputs ()
  "The command that a failure prints regenerates the failing input.
For every property, input I of a run equals input I of a run of as
many iterations as the failure report names for I."
  (skip-unless (dired-filetags-fuzz--oracle-p))
  (with-temp-buffer
    (dired-filetags-fuzz--with-oracle oracle
      (let ((n 120))
        (dolist (property dired-filetags-fuzz--properties)
          (let* ((generate (dired-filetags-fuzz--generator property oracle))
                 (full (dired-filetags-fuzz--inputs property generate n)))
            (dolist (index '(0 1 2 3 7 9 17 31 60 119))
              (when (< index (length full))
                (let* ((iterations (cdr (funcall (dired-filetags-fuzz--where property)
                                                 index (length full))))
                       (rerun (dired-filetags-fuzz--inputs property generate iterations))
                       (info (format "Property %s, input %d, rerun with %d iterations"
                                     property (1+ index) iterations))
                       (again (dired-filetags-fuzz--show (nth index rerun)))
                       (first (dired-filetags-fuzz--show (nth index full))))
                  (ert-info (info) (should (equal again first))))))))))))

;;;; Batch runner

(defun dired-filetags-fuzz-batch-and-exit ()
  "Run the fuzz properties in batch mode, then exit Emacs.
The exit status is 0 if every test passed, and 1 if any failed or was
skipped: a skip means that filetags or the Python oracle is missing,
which must not pass unnoticed."
  (unless noninteractive
    (user-error "`dired-filetags-fuzz-batch-and-exit' is for batch mode only"))
  (let ((status 2))
    (unwind-protect
        (let ((seed (dired-filetags-fuzz--seed))
              (iterations (dired-filetags-fuzz--iterations)))
          (message "fuzz: seed %S, %d iterations" seed iterations)
          (let* ((stats (ert-run-tests-batch "\\`dired-filetags-fuzz-"))
                 (failed (ert-stats-completed-unexpected stats))
                 (skipped (ert-stats-skipped stats)))
            (setq status (if (and (> (ert-stats-total stats) 0) (zerop failed) (zerop skipped))
                             0
                           1))
            (message "fuzz: seed %S, %d iterations: %s" seed iterations
                     (if (zerop status)
                         "passed"
                       (string-join
                        (delq nil (list (and (> failed 0) (format "%d FAILED" failed))
                                        (and (> skipped 0)
                                             (format "%d skipped, as filetags or the oracle is missing"
                                                     skipped))
                                        (and (zerop (ert-stats-total stats)) "no tests ran")))
                        "; ")))))
      (kill-emacs status))))

(provide 'dired-filetags-fuzz-test)
;;; dired-filetags-fuzz-test.el ends here
