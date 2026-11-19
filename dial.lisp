;;;; dial.lisp — the box dialer: a Lisp program reaching a glass box the way the phone does.
;;;;
;;;; THE PHONE IS THE SPEC (shell.js), and this is its connect sequence in Lisp, step for step:
;;;;
;;;;   1. THE CREDENTIAL.  A login link's one-time CODE (box=…&code=…[&turn=…&user=…&pass=…] in its
;;;;      fragment), or -- once a code has been spent -- the DEVICE KEY it enrolled.  Kept per box
;;;;      as the phone keeps them in localStorage: the device secret (`glass-device:BOX'), the
;;;;      latest renewal code (`glass-code:BOX', only while alive), and the enrolment's expiry
;;;;      (`glass-enrol:BOX').  Here they are one file per box under *DIAL-DIRECTORY*, mode 0600.
;;;;      A code is "alive" by the expiry in its middle field (NONCE.EXP.MAC) -- the phone's
;;;;      CODEALIVE -- and a dead one is not sent.  No code and no device is "no credential".
;;;;   2. THE CHANNELS, BEFORE THE OFFER: `rfb' in-band (DCEP), `control' 100, `warp' 102,
;;;;      `payload' 104, all ordered; the negotiated ones on the ids the gateway claims.
;;;;   3. THE OFFER, NON-TRICKLE: every candidate gathered first (host, and a relay when the link
;;;;      carried a TURN server), then {"sdp", "code"?} gift-wrapped (NIP-59: rumor kind 14 ->
;;;;      seal 13 by the DEVICE key -> wrap 1059 by an ephemeral key) to the box's pubkey and
;;;;      published to the relays.
;;;;   4. THE ANSWER: a gift wrap to the device key whose seal the BOX signed, holding
;;;;      {"sdp","ufrag","code"?,"expires"?}.  Only one whose ufrag is our offer's counts -- the
;;;;      relays replay every old answer to this key -- and an answer IS the admission: the
;;;;      renewal code and expiry are stored, exactly as the phone's MARKADMITTED /
;;;;      NOTEENROLEXPIRY / STORECODE do.  A refusal is SILENCE, so no answer within the timeout
;;;;      is all a denied credential ever looks like.
;;;;   5. CONNECT (webrtc-data's CONNECT-PEER) and hand back the `rfb' channel as a byte stream.
;;;;
;;;; SECRETS: the device key is generated here and lives in its file and in a cl-nostr keypair;
;;;; it is never printed (DIAL-CREDENTIAL's PRINT-OBJECT shows the public key only), and the
;;;; code is shown only as its expiry.

(defpackage #:glass-dial
  (:use #:cl)
  (:local-nicknames (#:wd #:webrtc-data) (#:j #:json-simple))
  (:export #:dial-box #:dial-result #:dial-peer #:dial-stream #:dial-credential-of #:dial-timings
           #:dial-via #:dial-box-hex #:dial-close
           #:parse-login-link #:load-dial-credential #:dial-credential #:credential-box-hex
           #:credential-device-pub #:credential-code-alive-p #:credential-expires
           #:code-alive-p #:code-expiry
           #:*dial-directory* #:*default-relays* #:*dial-channels* #:dial-error))

(in-package #:glass-dial)

(define-condition dial-error (error)
  ((msg :initarg :msg :reader dial-error-msg))
  (:report (lambda (c s) (format s "dial: ~a" (dial-error-msg c)))))
(defun derr (fmt &rest args) (error 'dial-error :msg (apply #'format nil fmt args)))

(defparameter *default-relays*
  '("wss://relay.snort.social" "wss://nostr.oxtr.dev" "wss://relay.primal.net")
  "The phone's default relays (shell.js), used when neither the caller nor NOSTR_RELAYS says.")

(defparameter *dial-directory*
  (merge-pathnames ".config/glass/dial/" (user-homedir-pathname))
  "Where each box's credential file lives (the phone's localStorage).")

(defparameter *dial-channels*
  '(("rfb")                                    ; DCEP: the desktop, raw RFB
    ("control" :id 100) ("warp" :id 102) ("payload" :id 104))
  "The channels the phone's shell creates before its offer, in its order.")

(defun %unix-now () (- (get-universal-time) (encode-universal-time 0 0 0 1 1 1970 0)))

;;; ---- codes -------------------------------------------------------------------------------------

(defun code-expiry (code)
  "A login code's expiry (unix seconds) from its middle field, or NIL -- the phone's CODEEXP."
  (when (stringp code)
    (let* ((d1 (position #\. code)) (d2 (and d1 (position #\. code :start (1+ d1)))))
      (and d2 (not (position #\. code :start (1+ d2)))
           (ignore-errors (parse-integer code :start (1+ d1) :end d2))))))

(defun code-alive-p (code &optional (margin 0))
  (let ((e (code-expiry code))) (and e (> (- e margin) (%unix-now)))))

;;; ---- the login link ----------------------------------------------------------------------------

(defun %url-decode (s)
  (with-output-to-string (o)
    (loop with i = 0 while (< i (length s))
          do (let ((c (char s i)))
               (cond ((and (char= c #\%) (<= (+ i 3) (length s)))
                      (write-char (code-char (parse-integer s :start (1+ i) :end (+ i 3) :radix 16)) o)
                      (incf i 3))
                     ((char= c #\+) (write-char #\Space o) (incf i))
                     (t (write-char c o) (incf i)))))))

(defun parse-login-link (link)
  "A login link (or just its fragment / query) -> plist (:box :code :turn :relays), TURN being
(\"host:port\" user pass) when the link carries a relay.  The fragment wins over the query, as in
the shell."
  (let* ((hash (position #\# link)) (q (position #\? link))
         (frag (if hash (subseq link (1+ hash)) (if q (subseq link (1+ q) (or hash (length link))) link)))
         (params (loop for kv in (uiop:split-string frag :separator "&")
                       for eq = (position #\= kv)
                       when eq collect (cons (subseq kv 0 eq) (%url-decode (subseq kv (1+ eq))))))
         (get (lambda (k) (cdr (assoc k params :test #'string=)))))
    (when (and (null (funcall get "box")) (plusp (length frag)) (not (position #\= frag)))
      (push (cons "box" frag) params))
    (let ((turn (funcall get "turn")))
      (list :box (funcall get "box") :code (funcall get "code")
            :relays (let ((r (funcall get "relays"))) (and r (uiop:split-string r :separator ",")))
            :turn (and turn (list (if (eql 0 (search "turn:" turn)) (subseq turn 5) turn)
                                  (funcall get "user") (funcall get "pass")))))))

;;; ---- the credential (the phone's localStorage, per box) ----------------------------------------

(defclass dial-credential ()
  ((box :initarg :box :reader credential-box-hex)
   (path :initarg :path :reader credential-path)
   (device :initarg :device :initform nil :accessor %credential-device)   ; secret hex: never printed
   (code :initarg :code :initform nil :accessor %credential-code)
   (expires :initarg :expires :initform nil :accessor credential-expires)
   (last-ok :initarg :last-ok :initform nil :accessor credential-last-ok))
  (:documentation "What this machine holds for one box: a device key, a renewal code, when the
box says the enrolment runs out.  PRINT-OBJECT shows none of the secrets."))

(defmethod print-object ((c dial-credential) s)
  (print-unreadable-object (c s :type t)
    (format s "box ~a… device ~:[none~;~:*~a…~] code ~:[none~;~:*~a~]"
            (subseq (credential-box-hex c) 0 8)
            (let ((p (credential-device-pub c))) (and p (subseq p 0 8)))
            (let ((code (%credential-code c)))
              (and code (if (code-alive-p code) (format nil "alive until ~d" (code-expiry code)) "dead"))))))

(defun credential-device-pub (c)
  (let ((d (%credential-device c)))
    (and d (cl-nostr.keys:public-hex (cl-nostr.keys:keypair-from-secret d)))))

(defun credential-code-alive-p (c) (code-alive-p (%credential-code c)))

(defun %credential-file (box-hex dir)
  (merge-pathnames (format nil "~a.sexp" box-hex) dir))

(defun load-dial-credential (box-hex &key (dir *dial-directory*))
  (let* ((path (%credential-file box-hex dir))
         (plist (ignore-errors
                 (with-open-file (in path :if-does-not-exist nil)
                   (and in (let ((*read-eval* nil)) (read in nil nil)))))))
    (make-instance 'dial-credential :box box-hex :path path
                   :device (getf plist :device) :code (getf plist :code)
                   :expires (getf plist :expires) :last-ok (getf plist :last-ok))))

(defun %save-credential (c)
  "Write C's file, 0600, through a temporary file renamed over it."
  (let* ((path (credential-path c))
         (tmp (make-pathname :type "tmp" :defaults path)))
    (ensure-directories-exist path)
    (with-open-file (o tmp :direction :output :if-exists :supersede)
      #+sbcl (ignore-errors (sb-posix:chmod (namestring tmp) #o600))
      (let ((*print-readably* nil))
        (prin1 (list :device (%credential-device c)
                     :code (and (code-alive-p (%credential-code c)) (%credential-code c))
                     :expires (credential-expires c) :last-ok (credential-last-ok c))
               o)))
    (rename-file tmp path)
    c))

(defun %ensure-device (c)
  "The device secret (hex), made the first time -- as the phone's DEVICESECRET mints one."
  (or (%credential-device c)
      (let ((kp (cl-nostr.keys:generate-keypair)))
        (setf (%credential-device c) (cl-nostr.keys:secret-hex kp))
        (cl-nostr.keys:keypair-wipe kp)
        (%credential-device c))))

;;; ---- the dial ----------------------------------------------------------------------------------

(defclass dial-result ()
  ((peer :initarg :peer :reader dial-peer)
   (stream :initarg :stream :reader dial-stream)
   (credential :initarg :credential :reader dial-credential-of)
   (via :initarg :via :reader dial-via)                   ; :code or :device
   (box :initarg :box :reader dial-box-hex)
   (timings :initarg :timings :accessor dial-timings))
  (:documentation "A connected box: the RTC-PEER, the `rfb' channel as a byte stream, and how."))

(defmethod print-object ((d dial-result) s)
  (print-unreadable-object (d s :type t)
    (format s "box ~a… via ~(~a~) ~(~a~)" (subseq (dial-box-hex d) 0 8) (dial-via d)
            (wd:peer-state (dial-peer d)))))

(defun dial-close (d)
  "Hang up as the phone does when its page goes: the going-away hint on the control channel
({\"away\":1,\"why\":\"pagehide\"}, i.e. not coming back -- the box then keeps no grace for this
session), then the SCTP ABORT that ends it at once."
  (let* ((peer (dial-peer d)) (ctl (wd:rtc-channel peer 100)))
    (when (and ctl (wd:rtc-open-p peer))
      (ignore-errors (wd:channel-send ctl "{\"away\":1,\"why\":\"pagehide\"}"))
      (sleep 0.05))
    (wd:rtc-close peer)))

(defun %relays (relays link-relays)
  (or relays link-relays
      (let ((e (uiop:getenv "NOSTR_RELAYS")))
        (and e (plusp (length e)) (remove "" (uiop:split-string e :separator ",") :test #'string=)))
      *default-relays*))

(defun %envelope (payload)
  "The answer envelope as a hash table, or NIL (a bare SDP is only an old box's)."
  (let ((j (ignore-errors (j:parse payload))))
    (and (hash-table-p j) (gethash "sdp" j) j)))

(defun dial-box (&key box code link relays turn (dir *dial-directory*) (answer-timeout 120)
                      (connect-timeout 30) local-ip log (channels *dial-channels*) on-close
                      relay-only)
  "Reach the glass box BOX (an npub or hex pubkey) the way the phone does, and return a
DIAL-RESULT whose DIAL-STREAM is the desktop's RFB byte stream.

The credential: CODE (a login code), or LINK (a whole login link: box, code, TURN and relays from
its fragment), else whatever this machine holds for BOX in DIR -- a live renewal code, or the
enrolled device key.  RELAYS is a list of wss:// URLs (default: the link's, NOSTR_RELAYS, the
phone's); TURN is (\"host:port\" user pass) to gather a relay candidate (default: the link's).
ANSWER-TIMEOUT is how long the box may take to answer (a small board takes a minute; a denial is
never answered at all).  RELAY-ONLY offers and uses only the TURN relay (a browser's
iceTransportPolicy \"relay\"; needs TURN).  LOG, a stream, gets the connect sequence.  Signals
DIAL-ERROR."
  (let* ((lk (and link (parse-login-link link)))
         (box-hex (cl-nostr.bech32:pubkey-hex (or box (getf lk :box) (derr "no box given"))))
         (cred (load-dial-credential box-hex :dir dir))
         (given (or code (getf lk :code)))
         (use-code (cond ((code-alive-p given) given)
                         ((credential-code-alive-p cred) (%credential-code cred))))
         (turn (or turn (getf lk :turn)))
         (relays (%relays relays (getf lk :relays)))
         (t0 (get-internal-real-time))
         (marks '()))
    (flet ((mark (what) (push (cons what (/ (float (- (get-internal-real-time) t0) 1d0)
                                            internal-time-units-per-second))
                              marks))
           (say (fmt &rest args)
             (when log (format log "~&[dial] ~?~%" fmt args) (finish-output log))))
      (when (and given (not use-code))
        (say "the given code ~:[is malformed~;expired at ~:*~d~] -- not sent" (code-expiry given)))
      (unless (or use-code (%credential-device cred))
        (derr "no login code and no enrolled device for ~a…" (subseq box-hex 0 8)))
      (%ensure-device cred)
      (%save-credential cred)               ; the device key survives a failed first dial
      (let* ((kp (cl-nostr.keys:keypair-from-secret (%credential-device cred)))
             (me (cl-nostr.keys:public-hex kp))
             (pool nil) (lock (bt:make-lock "dial")) (cv (bt:make-condition-variable))
             (wraps '()) (my-ufrag nil) (env nil))
        (say "box ~a…, device ~a…, ~:[enrolled device~;one-time code~], ~d relay~:p~@[, TURN ~a~]"
             (subseq box-hex 0 8) (subseq me 0 8) use-code (length relays) (first turn))
        (unwind-protect
             (let ((peer-result
                     (wd:connect-peer
                      (lambda (offer)
                        (mark :gathered)
                        (setf my-ufrag (wd:sdp-ice-ufrag (wd:parse-sdp offer)))
                        (setf pool (cl-nostr.pool:make-pool relays :timeout 10))
                        (mark :relays)
                        ;; subscribe BEFORE publishing: the answer may beat a slow EOSE
                        (cl-nostr.pool:pool-subscribe
                         pool (list (cl-nostr.filter:make-filter
                                     :kinds '(1059) :tags (list (cons "p" (list me)))
                                     :since (- (%unix-now) 172800)))
                         :on-event (lambda (ev relay)
                                     (declare (ignore relay))
                                     (bt:with-lock-held (lock)
                                       (setf wraps (nconc wraps (list ev)))
                                       (bt:condition-notify cv))))
                        (let* ((ht (make-hash-table :test 'equal)))
                          (setf (gethash "sdp" ht) offer)
                          (when use-code (setf (gethash "code" ht) use-code))
                          (let ((wrap (cl-nostr.nip59:build-giftwrap kp box-hex (j:stringify ht))))
                            (let ((acks (cl-nostr.pool:pool-publish-sync pool wrap :timeout 8)))
                              (unless (cl-nostr.pool:acks-accepted acks)
                                (derr "no relay accepted the offer (~{~a~^, ~})" relays)))))
                        (mark :offer-sent)
                        (say "offer sent (ufrag ~a), waiting for the box" my-ufrag)
                        ;; the answer: ours by its ufrag, from the box by its seal's signer
                        (let ((deadline (+ (get-internal-real-time)
                                           (* answer-timeout internal-time-units-per-second))))
                          (loop until env
                                do (let ((batch (bt:with-lock-held (lock)
                                                  (loop while (and (null wraps)
                                                                   (< (get-internal-real-time) deadline))
                                                        do (bt:condition-wait cv lock :timeout 0.25))
                                                  (prog1 wraps (setf wraps '())))))
                                     (dolist (ev batch)
                                       (multiple-value-bind (payload sender)
                                           (ignore-errors (cl-nostr.nip59:unwrap-giftwrap kp ev))
                                         (when (and payload (equal sender box-hex))
                                           (let ((e (%envelope payload)))
                                             (cond ((null e))
                                                   ((equal (gethash "ufrag" e) my-ufrag) (setf env e))
                                                   (t (say "ignored a replayed answer (ufrag ~a)"
                                                           (gethash "ufrag" e))))))))
                                     (when (and (null env) (>= (get-internal-real-time) deadline))
                                       (derr "no answer from the box in ~ds -- refused, or not there ~
                                              (a refusal is silence)" answer-timeout)))))
                        (mark :answered)
                        ;; AN ANSWER IS THE ADMISSION: keep what it renewed
                        (setf (credential-last-ok cred) (%unix-now)
                              (credential-expires cred) (let ((x (gethash "expires" env)))
                                                          (and (realp x) (plusp x) (floor x))))
                        (let ((renewed (gethash "code" env)))
                          (when (code-alive-p renewed) (setf (%credential-code cred) renewed)))
                        (when (and use-code (equal use-code (%credential-code cred))
                                   (not (gethash "code" env)))
                          (setf (%credential-code cred) nil))   ; spent, and nothing in its place
                        (%save-credential cred)
                        (say "answered (~:[no renewal~;credential renewed~]~@[, enrolled until ~d~])"
                             (gethash "code" env) (credential-expires cred))
                        (gethash "sdp" env))
                      :channels (mapcar (lambda (spec)
                                          (if (getf (rest spec) :id)
                                              ;; the box's control/warp/payload talk is not ours to
                                              ;; read: drop it rather than queue it forever
                                              (append spec (list :on-message (lambda (ch p) (declare (ignore ch p)))))
                                              spec))
                                        channels)
                      :local-ip local-ip
                      :gather-relay (and turn (list :server (first turn) :user (second turn)
                                                    :pass (third turn)))
                      :relay-only (and relay-only t)
                      :timeout connect-timeout :log log :on-close on-close)))
               (mark :connected)
               (say "connected in ~,2fs" (cdr (first marks)))
               (make-instance 'dial-result
                              :peer peer-result
                              :stream (wd:rtc-channel-stream (wd:rtc-channel peer-result "rfb"))
                              :credential cred :via (if use-code :code :device) :box box-hex
                              :timings (reverse marks)))
          (when pool (ignore-errors (cl-nostr.pool:close-pool pool)))
          (cl-nostr.keys:keypair-wipe kp))))))
