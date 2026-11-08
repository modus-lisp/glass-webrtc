;;;; card-gateway.lisp -- the Zero card's gateway (glass/nostr admission + glass-webrtc/nostr-lean),
;;;; the same file under SBCL and hosted modus, in front of an RFB server on GLASS_HOST:GLASS_PORT.
;;;; Mirrors kiln boot/zero-gateway.lisp START, with a real environment instead of the board's
;;;; table.  Started by card.sh, which sets all of this:
;;;;   MODUS_ROOT          source tree: one directory per system (glass, glass-webrtc, cl-nostr ...)
;;;;   QUICKLISP_SOFTWARE  optional: third-party systems (cl-base64 ...), searched BEHIND MODUS_ROOT
;;;;   NOSTR_SEC (64 hex), GLASS_NOSTR_ALLOW (owner npub), GLASS_LOGIN_URL_BASE, NOSTR_RELAYS
;;;;   TURN_SERVER_URL / TURN_USER / TURN_PASS, GLASS_PORT, GLASS_ADMISSION_PORT, PAYLOAD_FILE
;;;;   CARD_STORE          a directory for glass's stores (devices, seats, stats)
;;;; Diagnostics, all optional:
;;;;   CARD_LOGIN_TTL=S    a DM'd login link stays good S seconds (glass's default is 10 minutes)
;;;;   CARD_ONE_THREAD=1   modus: no net-loop thread; the relay pump turns it, as on the card's core 0
;;;;   CARD_TRACE=1        modus: print errors passing through the WebRTC data path, with frames
;;;;   CARD_ADMDIAG=1      admission requests' shapes (never a code's value) and what they signalled
;;;;   CARD_TS=1           time loading the system trust store
;;;;   CARD_SYMDUMP=FILE   modus: every function's code address, for naming PCs in a core dump
(require :asdf)
(defvar *root* (or (sb-ext:posix-getenv "MODUS_ROOT") "/opt/modus-lisp"))
;; third-party systems (cl-base64 ...) from Quicklisp's tree, BEHIND the pinned tree
(let ((ql (sb-ext:posix-getenv "QUICKLISP_SOFTWARE")))
  (when ql (dolist (d (directory (format nil "~A/*/" ql))) (push d asdf:*central-registry*))))
(dolist (d (directory (format nil "~A/*/" *root*))) (push d asdf:*central-registry*))
(defun env (n) (sb-ext:posix-getenv n))
(let ((t0 (get-internal-real-time)))
  (asdf:load-system "glass/nostr")
  (asdf:load-system "glass-webrtc/nostr-lean")
  (format t "~&card-gateway: loaded in ~,1f s~%" (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
  (finish-output))
;; CARD_SYMDUMP=FILE (modus): every function's code address, for naming PCs in a core dump later
#+modus
(let ((f (sb-ext:posix-getenv "CARD_SYMDUMP")))
  (when (and f (plusp (length f)))
    (with-open-file (o f :direction :output :if-exists :supersede)
      (do-all-symbols (s)
        (let ((fn (and (fboundp s) (not (special-operator-p s)) (not (macro-function s))
                       (ignore-errors (symbol-function s)))))
          (when fn
            (let ((w (modus-int::%val->word fn)))
              (when (eql (logand w 15) 3)
                (format o "~x ~a::~a~%" (- w 3)
                        (if (symbol-package s) (package-name (symbol-package s)) "") (symbol-name s))))))))
    (format t "~&card-gateway: symbols dumped~%") (finish-output)))
(defun ts-probe (label)
  (when (sb-ext:posix-getenv "CARD_TS")
    (setf (symbol-value (find-symbol "*SYSTEM-TRUST-STORE-CACHE*" "SEAL")) nil
          (symbol-value (find-symbol "*SYSTEM-TRUST-STORE-LOCAL*" "SEAL")) nil)
    (let ((t0 (get-internal-real-time)))
      (funcall (find-symbol "LOAD-SYSTEM-TRUST-STORE" "SEAL"))
      (format t "~&card-gateway: trust store (~a) ~d ms~%" label
              (round (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second))
      (finish-output))))
(ts-probe "after load")
;; ONE THREAD on hosted modus, as the card runs it on core 0: a hosted modus thread has a heap of
;; its own and may not store into the loop object another thread made, so the net loop gets no
;; thread -- the gateway's relay pump turns it, between relay reads, every few ms.
(defvar *card-max-turn* 0)
(defvar *card-next-report* 0)
#+modus
(when (equal (sb-ext:posix-getenv "CARD_ONE_THREAD") "1")
  (let ((lp-sym (find-symbol "*NET-LOOP*" "WEBRTC-DATA"))
        (orig-pump (symbol-function (find-symbol "PUMP" "CL-NOSTR.RELAY"))))
    (setf (symbol-function (find-symbol "ENSURE-NET-LOOP" "WEBRTC-DATA"))
          (lambda ()
            (or (symbol-value lp-sym)
                (setf (symbol-value lp-sym) (cl-transport.loop:make-event-loop)))))
    (setf (symbol-function (find-symbol "PUMP" "CL-NOSTR.RELAY"))
          (lambda (&optional (timeout 0))
            (let ((end (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second))))
                  (n 0))
              (loop
                (incf n (funcall orig-pump 0))
                (let ((lp (symbol-value lp-sym)) (t0 (get-internal-real-time)))
                  (if lp (cl-transport.loop:run-once lp :max-wait 0.002) (sleep 0.002))
                  (setf *card-max-turn* (max *card-max-turn* (- (get-internal-real-time) t0)))
                  (when (and lp (> (get-internal-real-time) *card-next-report*))
                    (setf *card-next-report* (+ (get-internal-real-time) (* 2 internal-time-units-per-second)))
                    (handler-case
                    (let ((g (funcall (intern "%GC-STATS" "MODUS-INT"))))
                      (format t "~&[card] gc ~a pause-Mticks ~d max-turn ~dms ~s~%"
                              (getf g :count)
                              (round (getf g :total-ticks) 1000000)
                              (round (* 1000 *card-max-turn*) internal-time-units-per-second)
                              (cl-transport.loop:loop-stats lp))
                      (finish-output))
                      (error (e) (format t "~&[card] report failed: ~a~%" e) (finish-output)))
                    (setf *card-max-turn* 0)))
                (when (>= (get-internal-real-time) end) (return n))))))
    (let ((u (find-symbol "*PUMP*" "CL-NOSTR.UTIL")))
      (when (and u (boundp u)) (setf (symbol-value u) (symbol-function (find-symbol "PUMP" "CL-NOSTR.RELAY")))))
    (format t "~&card-gateway: one thread (net loop turned by the relay pump)~%") (finish-output)))
;; CARD_TRACE: these functions print any error that passes through them, with its frames
#+modus
(when (sb-ext:posix-getenv "CARD_TRACE")
  (dolist (spec '(("WEBRTC-DATA" "%GLASS-PUMP") ("WEBRTC-DATA" "%CURRENT-LINK") ("WEBRTC-DATA" "GLASS-CONNECT")
                  ("CL-TRANSPORT.LOOP" "EVERY-SECONDS") ("CL-TRANSPORT.LOOP" "WATCH")
                  ("WEBRTC-DATA" "PAYLOAD-ON-MESSAGE") ("WEBRTC-DATA" "SCTP-HANDLE-DCEP")))
    (let* ((s (find-symbol (second spec) (first spec))) (orig (and s (fboundp s) (symbol-function s))))
      (when orig
        (setf (symbol-function s)
              (let ((name (second spec)))
                (lambda (&rest args)
                  (handler-bind ((error (lambda (c)
                                          (format t "~&[trace] ~a: ~a~%" name c)
                                          (dolist (f (ignore-errors (subseq (modus::condition-backtrace-list c) 0 14)))
                                            (format t "~&[trace]    ~a~%" f))
                                          (finish-output))))
                    (apply orig args)))))))))
(defun set-by-name (pkg name value)
  (let ((s (and (find-package pkg) (find-symbol name pkg))))
    (when (and s (boundp s)) (setf (symbol-value s) value))
    (and s t)))
(defun call (pkg name &rest args) (apply (symbol-function (find-symbol name pkg)) args))
;; CARD_ADMDIAG: say what an admission request carried (shapes only, never a code's value) and
;; what it signalled -- a phone was DENIED with reason "nil", the print of a condition.
(when (env "CARD_ADMDIAG")
  (let ((ask (fdefinition (find-symbol "%ADMISSION-ASK" "WEBRTC-DATA")))
        (serve (fdefinition (find-symbol "ADMISSION-SERVE" "GLASS"))))
    (flet ((shape (v) (if (stringp v) (format nil "string/~d" (length v)) (format nil "~s" (type-of v)))))
      (setf (fdefinition (find-symbol "%ADMISSION-ASK" "WEBRTC-DATA"))
            (lambda (verb &rest params)
              (format t "~&@@ ADMDIAG ask ~a~{ ~a=~a~}~%" verb
                      (loop for (k v) on params by #'cddr collect k collect (shape v)))
              (finish-output)
              (let ((r (multiple-value-list (apply ask verb params))))
                (format t "~&@@ ADMDIAG -> ~s ~s~%" (first r)
                        (loop for (k v) on (second r) by #'cddr
                              collect k collect (if (member k '(:token :code)) (shape v) v)))
                (finish-output)
                (values-list r))))
      (setf (fdefinition (find-symbol "ADMISSION-SERVE" "GLASS"))
            (lambda (verb params)
              (handler-bind ((serious-condition
                               (lambda (e)
                                 (format t "~&@@ ADMDIAG signalled ~s: ~a~%" (type-of e) e)
                                 (ignore-errors (sb-debug:print-backtrace :count 30))
                                 (finish-output))))
                (funcall serve verb params)))))))
(let ((secret (env "NOSTR_SEC")) (owner (env "GLASS_NOSTR_ALLOW"))
      (store (env "CARD_STORE")) (aport (parse-integer (env "GLASS_ADMISSION_PORT")))
      (rport (parse-integer (env "GLASS_PORT"))))
  (set-by-name "GLASS" "*BOX-SECRET*" secret)
  (set-by-name "GLASS" "*ENROLMENT-FILE*" (format nil "~a/devices" store))
  (set-by-name "GLASS" "*SEAT-KEY-FILE*" (format nil "~a/seats" store))
  (set-by-name "GLASS" "*LOGIN-CODE-FILE*" nil)
  (set-by-name "GLASS" "*TURN-ICE*" (list (env "TURN_SERVER_URL") (env "TURN_USER") (env "TURN_PASS")))
  (set-by-name "GLASS" "*LOGIN-URL-BASE*" (env "GLASS_LOGIN_URL_BASE"))
  ;; CARD_LOGIN_TTL: seconds a DM'd login link stays good (glass's default is 10 minutes)
  (when (env "CARD_LOGIN_TTL") (set-by-name "GLASS" "*LOGIN-TTL*" (parse-integer (env "CARD_LOGIN_TTL"))))
  (set-by-name "WEBRTC-DATA" "*STATS-FILE*" (format nil "~a/glass-stats.sexp" store))
  (set-by-name "WEBRTC-DATA" "*OFFER-BACKLOG*" 3)
  (set-by-name "WEBRTC-DATA" "*BOX-SECRET*" secret)
  (set-by-name "WEBRTC-DATA" "*GLASS-HOST*" "127.0.0.1")
  (set-by-name "WEBRTC-DATA" "*GLASS-PORT*" rport)
  (set-by-name "WEBRTC-DATA" "*ADMISSION-PORT*" aport)
  (ts-probe "before session")
  ;; the loop's errors with their frames (a refused store carries the frames of its fault)
  #+modus
  (let ((lp (call "WEBRTC-DATA" "ENSURE-NET-LOOP")))
    (setf (cl-transport.loop:loop-error-hook lp)
          (lambda (c what)
            (format t "~&[loop] ~a: ~a~%" what c)
            (dolist (f (ignore-errors (subseq (modus::condition-backtrace-list c) 0 25)))
              (format t "~&[loop]    ~a~%" f))
            (finish-output))))
  (call "GLASS" "START-SESSION-NOSTR" :port aport)
  (set-by-name "WEBRTC-DATA" "*ON-READY*" (lambda () (call "GLASS" "SEND-LOGIN-LINK" owner)))
  (format t "~&card-gateway: starting the gateway~%") (finish-output)
  (call "WEBRTC-DATA" "START-NOSTR-GATEWAY"))
