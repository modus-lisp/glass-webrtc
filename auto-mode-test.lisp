;;;; auto-mode-test.lisp — the box's own choice between the sharp (RFB) and fuzzy (video) desktop,
;;;; AUTO-TICK in video-profiles.lisp, on made-up ticks of the stats it reads.
;;;;
;;;;     sbcl --non-interactive --load auto-mode-test.lisp
;;;;
;;;; The numbers are the ones measured with linkcond: ordinary links keep the smoothed RTT at or
;;;; below ~270 ms; a 300 kbps link sending the sharp desktop sat at 750 ms - 3 s while moving
;;;; ~40 KB/s, a 96 kbps one at 3 - 10 s and ~11 KB/s.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "webrtc-data")
    ;; as glass-webrtc/nostr-lean loads them: the media hooks first, which video-profiles uses
    (load (merge-pathnames "media-hooks.lisp" *load-truename*))
    (load (merge-pathnames "video-profiles.lisp" *load-truename*))))

(defpackage #:auto-mode-test (:use #:cl))
(in-package #:auto-mode-test)

(defvar *checks* 0)
(defvar *fails* 0)
(defun ok (name pass &optional detail)
  (incf *checks*)
  (unless pass (incf *fails*))
  (format t "  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" pass name detail))

(defun run (a mode ticks)
  "Feed TICKS -- (secs out-kbs srtt-ms [flight]) -- in MODE; the first verdict, as (secs to rung), or
NIL.  FLIGHT defaults to a saturated 64 KB."
  (loop for (secs kbs srtt flight) in ticks
        do (multiple-value-bind (to rung) (webrtc-data::auto-tick a mode secs kbs srtt (or flight 65536))
             (when to (return (list secs to rung))))))

(defun ticks (from n kbs srtt) (loop for i below n collect (list (+ from (* 2 i)) kbs srtt)))

(format t "~&[auto: sharp or fuzzy]~%")
(let ((a (webrtc-data::make-auto-switch)))
  (ok "an ordinary link (rtt100, far, slow: srtt <= 270 ms) stays sharp"
      (null (run a :rfb (append (ticks 0 10 80 120) (ticks 20 10 60 275) (ticks 40 10 9 150))))))
(let ((a (webrtc-data::make-auto-switch)))
  (ok "a single slow tick is not a verdict" (null (run a :rfb (list '(0 40 1500) '(2 40 200) '(4 40 1500))))))
(let ((a (webrtc-data::make-auto-switch)))
  (ok "an idle desktop's stale RTT says nothing (no data moving)" (null (run a :rfb (ticks 0 10 0.2 4000)))))
(let ((a (webrtc-data::make-auto-switch)))
  (let ((v (run a :rfb (ticks 0 5 40 1200))))
    (ok "a 300 kbps link (40 KB/s at 1.2 s srtt) goes fuzzy after two ticks, at 160 kbps"
        (equal v '(2 :video 160)) (format nil "~a" v))))
(let ((a (webrtc-data::make-auto-switch)))
  (let ((v (run a :rfb (list '(0 30 3000) '(2 10.5 6000) '(4 11 6000)))))
    (ok "a 96 kbps link goes fuzzy at 48 kbps: the median of its saturated ticks, not the first burst (30 KB/s)"
        (equal v '(2 :video 48)) (format nil "~a" v))))
(let ((a (webrtc-data::make-auto-switch)))
  (ok "a link slower than the bottom rung's share still gets the bottom rung"
      (equal (run a :rfb (ticks 0 3 0.5 9000)) nil))        ; below the moving floor: no verdict
  (ok "...and with data moving, the lowest rung" (eql 5 (third (run a :rfb (ticks 10 3 1.2 9000))))))

(let ((a (webrtc-data::make-auto-switch)))
  (run a :rfb (ticks 0 2 40 1200))                           ; fuzzy at t=2
  (ok "fuzzy stays fuzzy through the dwell" (null (run a :video (ticks 4 28 0 0))))
  (let ((v (run a :video (ticks 60 5 0 0))))
    (ok "...then probes sharp after 60 s" (equal (second v) :rfb) (format nil "~a" v)))
  (let ((v (run a :rfb (ticks 64 3 38 1500))))
    (ok "a probe that lags goes back to fuzzy" (equal (second v) :video) (format nil "~a" v)))
  (ok "...and the next probe waits twice as long (120 s)"
      (and (null (run a :video (ticks 70 55 0 0))) (equal (second (run a :video (ticks 190 2 0 0))) :rfb))))

(let ((a (webrtc-data::make-auto-switch)))
  (run a :rfb (ticks 0 2 40 1200))
  (run a :video (ticks 64 1 0 0))                            ; probe at 64
  (run a :rfb (ticks 66 2 38 1500))                          ; fails at 68: the wait doubles to 120
  (ok "(the failed probe doubled the wait)" (= 120 (webrtc-data::auto-probe-secs a)))
  (run a :video (ticks 190 1 0 0))                           ; probe at 190
  (ok "a probe that holds a full wait keeps sharp, and the wait goes back to 60 s"
      (and (null (run a :rfb (ticks 192 65 50 150)))
           (= 60 (webrtc-data::auto-probe-secs a)))
      (format nil "dwell ~a" (webrtc-data::auto-probe-secs a))))

(let ((a (webrtc-data::make-auto-switch)))
  (let ((v (run a :rfb (list '(0 40 1200 50000) '(2 1.9 2100 900)))))
    (ok "a lagging tick that was not saturated (900 B in flight, 1.9 KB/s) is not taken as the link's rate"
        (equal v '(2 :video 160)) (format nil "~a" v))))
(let ((a (webrtc-data::make-auto-switch)))
  (let ((v (run a :rfb (list '(0 1.5 2100 900) '(2 1.9 2100 900)))))
    (ok "with no saturated tick at all, the fallback rung (48)" (equal v '(2 :video 48)) (format nil "~a" v))))

(format t "checks: ~d   failures: ~d   => ~:[FAIL~;PASS~]~%" *checks* *fails* (zerop *fails*))
(uiop:quit (if (zerop *fails*) 0 1))
