;;;; pointer-channel-test.lisp — pointer-channel.lisp, exercised in a process that is not a gateway.
;;;;
;;;; gateway-nostr.lisp MAY NOT BE LOADED (it would answer offers as the box -- see
;;;; payload-channel-test.lisp), so its wiring is checked against its TEXT and the rules it
;;;; delegates to run here for real.
;;;;
;;;;     sbcl --non-interactive --load pointer-channel-test.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "webrtc-data")))
(load (merge-pathnames "pointer-channel.lisp" *load-truename*))

(defpackage #:pointer-channel-test (:use #:cl))
(in-package #:pointer-channel-test)

(defvar *checks* 0)
(defvar *fails* 0)
(defun ok (name pass &optional detail)
  (incf *checks*)
  (unless pass (incf *fails*))
  (format t "  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" pass name detail))

(defun ev (x &optional (mask 1))
  "An RFB PointerEvent at (X, 7)."
  (coerce (list 5 mask (ash x -8) (logand x 255) 0 7) '(vector (unsigned-byte 8))))
(defun msg (seq count x &optional (mask 1))
  (concatenate '(vector (unsigned-byte 8))
               (list (ldb (byte 8 24) seq) (ldb (byte 8 16) seq) (ldb (byte 8 8) seq) (ldb (byte 8 0) seq)
                     (ldb (byte 8 8) count) (ldb (byte 8 0) count))
               (ev x mask)))
(defun x-of (event) (and event (logior (ash (aref event 2) 8) (aref event 3))))

(defmacro with-state ((s) &body body)
  `(let ((,s (webrtc-data::make-pointer-state))) ,@body))
(defun on (s seq count x) (x-of (webrtc-data::pointer-on-message s (msg seq count x))))
(defun click (s) (x-of (webrtc-data::pointer-note-rfb s (ev 0))))

(format t "~&[pointer channel]~%")

(with-state (s)
  (ok "a move in step is forwarded" (eql (on s 1 0 10) 10))
  (ok "its repeat is not" (null (on s 1 0 10)))
  (ok "a newer move is" (eql (on s 2 0 11) 11))
  (ok "an older move arriving late (unordered) is not" (null (on s 1 0 10))))

(with-state (s)
  (click s)                                             ; press, via the RFB channel
  (ok "a move sent before a click glass already has is stale" (null (on s 5 0 50)))
  (ok "a move sent after it is forwarded" (eql (on s 6 1 60) 60)))

(with-state (s)
  (ok "a move sent after a click that has not arrived is held" (null (on s 7 1 70)))
  (ok "a newer one replaces it" (null (on s 8 1 80)))
  (ok "an older one does not" (null (on s 7 1 70)))
  (ok "the click arriving releases the newest held move, right after it" (eql (click s) 80))
  (ok "...once" (null (click s)))
  (ok "and a repeat of the released move is then a repeat" (null (on s 8 1 80))))

(with-state (s)
  (ok "a non-pointer RFB message is not counted"
      (progn (webrtc-data::pointer-note-rfb s (coerce '(3 0 0 0 0 0 0 0 0 0) '(vector (unsigned-byte 8))))
             (eql (on s 1 0 10) 10))))

(with-state (s)
  (ok "a malformed message is ignored"
      (null (webrtc-data::pointer-on-message s (coerce '(1 2 3) '(vector (unsigned-byte 8))))))
  (ok "...and so is one that is not a PointerEvent"
      (null (webrtc-data::pointer-on-message
             s (concatenate '(vector (unsigned-byte 8)) '(0 0 0 1 0 0) '(4 1 0 0 0 7))))))

(with-state (s)
  (on s #xFFFFFFFF 0 1)
  (ok "SEQ wraps at 2^32" (eql (on s 0 0 2) 2)))

(with-state (s)
  (setf (webrtc-data::pointer-rfb-count s) #xFFFF)
  (ok "COUNT wraps at 2^16" (and (null (on s 1 0 5)) (eql (click s) 5))))

(ok "a missing state forwards nothing and does not signal"
    (and (null (webrtc-data::pointer-on-message nil (msg 1 0 1)))
         (null (webrtc-data::pointer-note-rfb nil (ev 1)))))

;;; ---- the gateway, by its text ---------------------------------------------------------------
(let ((gw (uiop:read-file-string (merge-pathnames "gateway-nostr.lisp" *load-truename*))))
  (flet ((has (s) (search s gw)))
    (ok "the gateway loads pointer-channel.lisp under a guard, with stubs"
        (and (has "\"pointer-channel.lisp\"") (has "(defun pointer-sid-p (sid) (eql sid 106))")))
    (ok "stream 106 is claimed in the dispatch, before the RFB branch"
        (let ((a (has "((pointer-sid-p sid)")) (b (has "((and glass (plusp (length payload)))")))
          (and a b (< a b))))
    (ok "every RFB-channel message is shown to the pointer state after it is sent"
        (has "(pointer-note-rfb ptr bytes)"))))

(format t "checks: ~d   failures: ~d   => ~:[FAIL~;PASS~]~%" *checks* *fails* (zerop *fails*))
(uiop:quit (if (zerop *fails*) 0 1))
