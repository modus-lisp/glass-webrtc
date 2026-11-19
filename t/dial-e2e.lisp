;;;; t/dial-e2e.lisp -- dial a real card from Lisp, as the phone does, and look at its desktop.
;;;; Run by t/dial-e2e.py (which starts the relay, the TURN and the card and sets E2E_*):
;;;;
;;;;   1. the owner's DM: the card DMs its owner a login link when it is ready; read it off the relay
;;;;      as the owner (the human's step: tap the link).
;;;;   2. dial with the link's CODE under a fresh device key (the first visit: spends the code,
;;;;      enrols the device), over the relay, with the link's TURN gathered.
;;;;   3. RFB over the `rfb' channel (glass-client, through its CONNECTOR): the desktop's pixels
;;;;      arrive, and the Clock window's title bar is found on them.
;;;;   4. a pointer drag on that title bar, and the title bar is seen to move by as much.
;;;;   5. SetDesktopSize: ask for another size, the desktop takes it.
;;;;   6. close, and the box ends its session.
;;;;   7. dial AGAIN with no code at all: the enrolled device key (and the renewal code the
;;;;      first answer carried) must get in -- the phone's every-later-visit.
;;;; Screenshots of the remote framebuffer go to E2E_OUT.

(require :asdf)
(let ((setup (sb-ext:posix-getenv "E2E_SETUP")))
  (if (and setup (plusp (length setup)))
      (load setup)
      (asdf:initialize-source-registry
       `(:source-registry (:tree ,(namestring (merge-pathnames "../../" *load-truename*)))
                          :inherit-configuration))))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "glass-webrtc/dial")
    (asdf:load-system "glass/client")
    (asdf:load-system "png-pure")))

(defpackage #:dial-e2e (:use #:cl) (:local-nicknames (#:d #:glass-dial) (#:gc #:glass-client)
                                                     (#:wd #:webrtc-data)))
(in-package #:dial-e2e)

(defvar *fails* 0)
(defvar *checks* 0)
(defun check (name ok &optional detail)
  (incf *checks*) (unless ok (incf *fails*))
  (format t "  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" ok name detail) (finish-output) ok)
(defun env (k) (let ((v (sb-ext:posix-getenv k))) (and v (plusp (length v)) v)))
(defun now () (/ (float (get-internal-real-time) 1d0) internal-time-units-per-second))

(defparameter *relay* (env "E2E_RELAY"))
(defparameter *box* (env "E2E_BOX"))
(defparameter *out* (pathname (concatenate 'string (string-right-trim "/" (env "E2E_OUT")) "/")))
(defparameter *dial-dir* (merge-pathnames "dial-store/" *out*))
(defparameter *log* (if (env "E2E_VERBOSE") *standard-output* nil))

;;; ---- 1. the login link, from the owner's DMs ------------------------------------------------

(defun owner-login-link (&key (timeout 60))
  "A fresh login link from the box, as its owner gets one: DM the box `link' (what the phone's
REQUESTFRESHCODE sends) and read the DM'd link off the relay.  Fresh, not the one the card sent at
start, because a code is one-time and an earlier run of this test may have spent that one."
  (let* ((kp (cl-nostr.keys:keypair-from-secret (env "E2E_OWNER_SEC")))
         (me (cl-nostr.keys:public-hex kp))
         (pool (cl-nostr.pool:make-pool (list *relay*)))
         (asked (- (get-universal-time) (encode-universal-time 0 0 0 1 1 1970 0) 1))
         (links '()) (lock (sb-thread:make-mutex)))
    (unwind-protect
         (progn
           (cl-nostr.pool:pool-subscribe
            pool (list (cl-nostr.filter:make-filter :kinds '(1059) :tags (list (cons "p" (list me)))))
            :on-event (lambda (ev relay)
                        (declare (ignore relay))
                        (multiple-value-bind (text sender at) (ignore-errors (cl-nostr.nip59:unwrap-giftwrap kp ev))
                          (when (and text (equal sender *box*))
                            (let* ((p (search "code=" text))
                                   (start (and p (or (position #\Space text :end p :from-end t) -1)))
                                   (end (and p (or (position-if (lambda (c) (member c '(#\Space #\Newline #\Return)))
                                                                text :start p)
                                                   (length text)))))
                              (when (and p (>= at asked))
                                (sb-thread:with-mutex (lock)
                                  (push (cons at (subseq text (1+ start) end)) links))))))))
           (cl-nostr.pool:pool-publish-sync pool (cl-nostr.nip59:build-giftwrap kp *box* "link"))
           (loop repeat (* timeout 10) until links do (sleep 0.1))
           (cdr (first (sort (copy-list links) #'> :key #'car))))
      (ignore-errors (cl-nostr.pool:close-pool pool))
      (cl-nostr.keys:keypair-wipe kp))))

;;; ---- the remote's pixels ---------------------------------------------------------------------

(defun px (fb x y) (glass:fb-get fb x y))
(defun light-grey-p (p)
  (let ((r (ldb (byte 8 16) p)) (g (ldb (byte 8 8) p)) (b (ldb (byte 8 0) p)))
    (and (<= 190 r 230) (< (abs (- r g)) 8) (< (abs (- g b)) 8))))

(defun title-bar (fb)
  "(values X Y LEFT WIDTH) inside the topmost title bar: the first row (from the top, below the
menu strip) with a run of light-grey pixels at least 150 wide -- t/linkcond.py's TITLE_BAR."
  (glass:with-fb-locked (fb)
    (loop for y from 20 below (floor (glass:fb-height fb) 2)
          do (let ((run 0) (best 0) (best-start 0) (start 0))
               (dotimes (x (glass:fb-width fb))
                 (if (light-grey-p (px fb x y))
                     (progn (when (zerop run) (setf start x))
                            (incf run)
                            (when (> run best) (setf best run best-start start)))
                     (setf run 0)))
               (when (>= best 150)
                 (return-from title-bar (values (+ best-start (floor best 3)) (+ y 8) best-start best)))))
    nil))

(defun screenshot (fb name)
  (let* ((w (glass:fb-width fb)) (h (glass:fb-height fb))
         (rgb (make-array (* w h 3) :element-type '(unsigned-byte 8)))
         (path (merge-pathnames (format nil "~a.png" name) *out*)))
    (glass:with-fb-locked (fb)
      (dotimes (y h) (dotimes (x w)
                       (let ((p (px fb x y)) (i (* 3 (+ x (* y w)))))
                         (setf (aref rgb i) (ldb (byte 8 16) p) (aref rgb (+ i 1)) (ldb (byte 8 8) p)
                               (aref rgb (+ i 2)) (ldb (byte 8 0) p))))))
    (png-pure:write-png-file rgb w h path)
    (format t "     screenshot ~a~%" (namestring path))
    path))

(defun wait-until (secs fn)
  (let ((end (+ (now) secs)))
    (loop (let ((v (funcall fn))) (when v (return v)))
          (when (> (now) end) (return nil))
          (sleep 0.05))))

;;; ---- the dial, as a glass-client CONNECTOR ------------------------------------------------------

(defvar *dial* nil)

(defun dial (&rest args)
  (let ((t0 (now)))
    (handler-case
        (let ((r (apply #'d:dial-box :box *box* :relays (list *relay*) :dir *dial-dir* :log *log*
                        :answer-timeout 60 args)))
          (values r (- (now) t0)))
      (error (e) (values nil (- (now) t0) e)))))

(defun view (dialled)
  "A glass-client REMOTE over DIALLED's rfb stream (no reconnecting: the connector serves once)."
  (let ((served nil))
    (gc:connect-remote "box" 0 :resizable t
                               :connector (lambda (r)
                                            (declare (ignore r))
                                            (if served
                                                (error "this test dials once per view")
                                                (progn (setf served t)
                                                       (values (lambda () (d:dial-close dialled))
                                                               (d:dial-stream dialled))))))))

(defun run ()
  (format t "~&== dial-e2e: relay ~a, box ~a… ==~%" *relay* (subseq *box* 0 8))
  (uiop:delete-directory-tree *dial-dir* :validate t :if-does-not-exist :ignore)
  ;; 1
  (let ((link (owner-login-link)))
    (unless (check "the owner was DM'd a login link" link) (return-from run))
    (let ((lk (d:parse-login-link link)))
      (check "...carrying the box, a live code and the TURN relay"
             (and (equal (cl-nostr.bech32:pubkey-hex (getf lk :box)) *box*)
                  (d:code-alive-p (getf lk :code)) (getf lk :turn))
             (format nil "code alive until ~a, turn ~a" (d:code-expiry (getf lk :code)) (first (getf lk :turn)))))
    ;; 2
    (multiple-value-bind (dialled secs err) (dial :link link)
      (unless (check "dialled with the code: offer gift-wrapped, answered, connected" dialled
                     (if dialled
                         (format nil "~,2fs (~{~(~a~) ~,2f~^, ~})" secs
                                 (loop for (k . v) in (d:dial-timings dialled) collect k collect v))
                         err))
        (return-from run))
      (check "admitted on the code" (eq (d:dial-via dialled) :code))
      (let ((cred (d:load-dial-credential *box* :dir *dial-dir*)))
        (check "the device is stored (secret not printed) with the renewal the answer carried"
               (and (d:credential-device-pub cred) (d:credential-code-alive-p cred))
               (princ-to-string cred)))
      (check "the route" t (wd::ice-route-label (wd:peer-agent (d:dial-peer dialled))))
      ;; 3
      (let* ((r (view dialled)) (fb (gc:remote-fb r)))
        (check "RFB is up over the data channel" (wait-until 20 (lambda () (gc:remote-connected-p r)))
               (format nil "~a ~dx~d" (gc:remote-name r) (gc:remote-width r) (gc:remote-height r)))
        (destructuring-bind (&optional x y left width)
            (wait-until 20 (lambda () (and (plusp (getf (gc:remote-stats r) :frames))
                                           (title-bar fb) (multiple-value-list (title-bar fb)))))
          (declare (ignore width))
          (screenshot fb "remote-1-first")
          (unless (check "the desktop's pixels arrived: a window's title bar is on them" x
                         (format nil "~a frames, title bar at y ~a from x ~a"
                                 (getf (gc:remote-stats r) :frames) y left))
            (gc:remote-stop r) (return-from run))
          ;; 4. drag the window by its title bar, 80 px right and 40 down
          (gc:remote-pointer r 0 x y) (sleep 0.1)
          (gc:remote-pointer r 1 x y) (sleep 0.1)
          (loop for i from 1 to 8 do (gc:remote-pointer r 1 (+ x (* i 10)) (+ y (* i 5))) (sleep 0.05))
          (gc:remote-pointer r 0 (+ x 80) (+ y 40))
          (let ((moved (wait-until 10 (lambda ()
                                        (multiple-value-bind (nx ny nleft) (title-bar fb)
                                          (declare (ignore nx))
                                          (and nleft (> (- nleft left) 40) (list nleft ny)))))))
            (screenshot fb "remote-2-dragged")
            (check "a pointer drag on the title bar moved the window"
                   (and moved (<= 70 (- (first moved) left) 90))
                   (if moved (format nil "left edge ~d -> ~d, title row ~d -> ~d"
                                     left (first moved) y (second moved))
                       "no movement seen"))))
        ;; 5. resize
        (let ((w0 (gc:remote-width r)) (h0 (gc:remote-height r)))
          (check "the box granted SetDesktopSize (ExtendedDesktopSize seen)"
                 (wait-until 5 (lambda () (gc:remote-set-desktop-size r 900 640))))
          (check "...and the desktop took the size asked for"
                 (wait-until 10 (lambda () (and (= (gc:remote-width r) 900) (= (gc:remote-height r) 640))))
                 (format nil "~dx~d -> ~dx~d" w0 h0 (gc:remote-width r) (gc:remote-height r)))
          (wait-until 5 (lambda () (title-bar fb)))
          (sleep 0.5)
          (screenshot fb "remote-3-resized"))
        (format t "     ~a~%" (gc:remote-report r))
        ;; 6
        (gc:remote-stop r)
        (check "closed" (eq (wd:peer-state (d:dial-peer dialled)) :closed)
               (wd:peer-reason (d:dial-peer dialled)))))
    ;; 7. the next visit: no code given
    (sleep 1)
    (multiple-value-bind (dialled secs err) (dial)
      (check "dialled AGAIN with no code: the stored credential gets in" dialled
             (if dialled (format nil "via ~(~a~), ~,2fs (~{~(~a~) ~,2f~^, ~})" (d:dial-via dialled) secs
                                 (loop for (k . v) in (d:dial-timings dialled) collect k collect v))
                 err))
      (when dialled
        (let* ((r (view dialled)) (fb (gc:remote-fb r)))
          (check "...and its desktop paints"
                 (wait-until 20 (lambda () (and (gc:remote-connected-p r) (title-bar fb)))))
          (screenshot fb "remote-4-second-visit")
          (gc:remote-stop r))))
    ;; 8. ...and with no code at all, stored or given: the enrolled DEVICE KEY alone
    (let ((cred (d:load-dial-credential *box* :dir *dial-dir*)))
      (setf (glass-dial::%credential-code cred) nil)
      (glass-dial::%save-credential cred))
    (multiple-value-bind (dialled secs err) (dial)
      (check "dialled with the device key alone (no code anywhere)"
             (and dialled (eq (d:dial-via dialled) :device))
             (if dialled (format nil "via ~(~a~), ~,2fs" (d:dial-via dialled) secs) err))
      (when dialled
        (let* ((r (view dialled)) (fb (gc:remote-fb r)))
          (check "...and its desktop paints"
                 (wait-until 20 (lambda () (and (gc:remote-connected-p r) (title-bar fb)))))
          (gc:remote-stop r))))
    ;; 9. through the TURN relay only, as a phone on a hard NAT connects
    (multiple-value-bind (dialled secs err) (dial :relay-only t :turn (let ((f (uiop:split-string (env "E2E_TURN"))))
                                                                       (list (first f) (second f) (third f))))
      (let ((route (and dialled (first (wd::ice-agent-peer (wd:peer-agent (d:dial-peer dialled)))))))
        (check "dialled through the TURN relay only" (member route '(:relay :relay-send))
               (if dialled (format nil "route ~(~a~), ~,2fs" route secs) err)))
      (when dialled
        (let* ((r (view dialled)) (fb (gc:remote-fb r)))
          (check "...and its desktop paints, relayed"
                 (wait-until 20 (lambda () (and (gc:remote-connected-p r) (title-bar fb)))))
          (screenshot fb "remote-5-relayed")
          (format t "     ~a~%" (gc:remote-report r))
          (gc:remote-stop r))))
    ;; the box's side of it
    (let ((log (ignore-errors (uiop:read-file-string (env "E2E_CARD_LOG")))))
      (when log
        (check "the box admitted the code, then the device"
               (and (search "(via code)" log) (search "(via device)" log)))))))

;; A hang is a failure with a stack, not a timeout with nothing: after E2E_WATCHDOG seconds
;; (default 150) every thread prints where it is and the test fails.
(sb-thread:make-thread
 (lambda ()
   (sleep (or (ignore-errors (parse-integer (env "E2E_WATCHDOG"))) 150))
   (format t "~&!! watchdog: still running -- every thread's stack:~%")
   (dolist (th (sb-thread:list-all-threads))
     (unless (eq th sb-thread:*current-thread*)
       (ignore-errors
        (sb-thread:interrupt-thread
         th (lambda ()
              (format t "~&-- ~a~%" (sb-thread:thread-name sb-thread:*current-thread*))
              (sb-debug:print-backtrace :count 30 :stream *standard-output*)
              (finish-output))))))
   (sleep 3)
   (format t "~&FAIL watchdog~%") (finish-output)
   (sb-ext:exit :code 1 :abort t))
 :name "watchdog")
(handler-case (run)
  (error (e) (check "no error" nil (princ-to-string e))))
(format t "~&dial-e2e: ~d/~d passed~%" (- *checks* *fails*) *checks*)
(finish-output)
(sb-ext:exit :code (if (zerop *fails*) 0 1) :abort t)
