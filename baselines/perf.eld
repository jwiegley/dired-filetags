;;; perf.eld --- dired-filetags performance baselines  -*- lisp-data -*-
;;
;; Written by scripts/bench.el --update; see the README.
;; alloc: per SYSTEM, the `memory-use-counts' deltas of each
;; workload.  time: per SYSTEM/HOST, each workload's fastest clean
;; sample over the lower quartile of the calibration samples, that
;; calibration in seconds, and macOS's power mode then.  Both record
;; the length of the name of the directory that held the files.

((alloc
  ("aarch64-darwin" :emacs "30.2" :native t :root-length 41
   :counts
   ((fontify-tagged :conses 455533 :floats 2 :vector-cells 96006 :symbols 2766 :string-chars 635064 :intervals 49194 :strings 51318)
    (fontify-untagged :conses 6007 :floats 2 :vector-cells 20400 :symbols 0 :string-chars 56400 :intervals 0 :strings 2400)
    (mark :conses 70519 :floats 2 :vector-cells 150114 :symbols 3660 :string-chars 1249842 :intervals 4266 :strings 46488)
    (oracle :conses 20729 :floats 2 :vector-cells 5168 :symbols 0 :string-chars 389437 :intervals 0 :strings 12275)
    (parse :conses 208135 :floats 2 :vector-cells 0 :symbols 0 :string-chars 1026976 :intervals 0 :strings 116192)
    (prescan :conses 86167 :floats 2 :vector-cells 518856 :symbols 8 :string-chars 765048 :intervals 0 :strings 37936)
    (tally :conses 118986 :floats 2 :vector-cells 121583 :symbols 8764 :string-chars 768194 :intervals 0 :strings 51275)
    (tokens :conses 126007 :floats 2 :vector-cells 0 :symbols 0 :string-chars 778288 :intervals 0 :strings 75600)
    (verify :conses 140407 :floats 2 :vector-cells 237600 :symbols 0 :string-chars 706026 :intervals 0 :strings 78948)))
  ("aarch64-linux" :emacs "30.2" :native t :root-length 33
   :counts
   ((fontify-tagged :conses 455533 :floats 2 :vector-cells 96006 :symbols 2766 :string-chars 635064 :intervals 49194 :strings 51318)
    (fontify-untagged :conses 6007 :floats 2 :vector-cells 20400 :symbols 0 :string-chars 56400 :intervals 0 :strings 2400)
    (mark :conses 70519 :floats 2 :vector-cells 150114 :symbols 3660 :string-chars 1190994 :intervals 4266 :strings 46488)
    (oracle :conses 20729 :floats 2 :vector-cells 5168 :symbols 0 :string-chars 353525 :intervals 0 :strings 12275)
    (parse :conses 208135 :floats 2 :vector-cells 0 :symbols 0 :string-chars 1026976 :intervals 0 :strings 116192)
    (prescan :conses 86167 :floats 2 :vector-cells 518856 :symbols 8 :string-chars 741560 :intervals 0 :strings 37936)
    (tally :conses 118986 :floats 2 :vector-cells 121583 :symbols 8764 :string-chars 765961 :intervals 0 :strings 51282)
    (tokens :conses 126007 :floats 2 :vector-cells 0 :symbols 0 :string-chars 778288 :intervals 0 :strings 75600)
    (verify :conses 140407 :floats 2 :vector-cells 237600 :symbols 0 :string-chars 706026 :intervals 0 :strings 78948)))
  ("x86_64-linux" :emacs "30.2" :native t :root-length 33
   :counts
   ((fontify-tagged :conses 455533 :floats 2 :vector-cells 96006 :symbols 2766 :string-chars 635064 :intervals 49194 :strings 51318)
    (fontify-untagged :conses 6007 :floats 2 :vector-cells 20400 :symbols 0 :string-chars 56400 :intervals 0 :strings 2400)
    (mark :conses 70519 :floats 2 :vector-cells 150114 :symbols 3660 :string-chars 1190994 :intervals 4266 :strings 46488)
    (oracle :conses 20729 :floats 2 :vector-cells 5168 :symbols 0 :string-chars 353525 :intervals 0 :strings 12275)
    (parse :conses 208135 :floats 2 :vector-cells 0 :symbols 0 :string-chars 1026976 :intervals 0 :strings 116192)
    (prescan :conses 86167 :floats 2 :vector-cells 518856 :symbols 8 :string-chars 741560 :intervals 0 :strings 37936)
    (tally :conses 118986 :floats 2 :vector-cells 121583 :symbols 8764 :string-chars 765961 :intervals 0 :strings 51282)
    (tokens :conses 126007 :floats 2 :vector-cells 0 :symbols 0 :string-chars 778288 :intervals 0 :strings 75600)
    (verify :conses 140407 :floats 2 :vector-cells 237600 :symbols 0 :string-chars 706026 :intervals 0 :strings 78948))))
 (time
  ("aarch64-darwin/clio" :emacs "30.2" :native t :root-length 41 :power "normal" :calibration 0.0483608
   :ratios
   ((fontify-tagged . 0.513165)
    (mark . 0.54261)
    (parse . 0.45076)
    (tally . 0.475528)
    (tokens . 0.464042)
    (verify . 0.33978)))))
