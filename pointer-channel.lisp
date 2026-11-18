;;;; pointer-channel.lisp — pointer moves on a channel that never waits for a lost packet.
;;;;
;;;; ==============================================================================================
;;;; WHY
;;;; ==============================================================================================
;;;;
;;;; Input used to ride the RFB channel, which is ordered and reliable.  On a lossy link a lost
;;;; pointer move is resent by the BROWSER'S SCTP, on its own retransmission timer -- 0.3 s and up,
;;;; doubling -- and nothing the box does shortens that.  Measured over glass-webrtc t/linkcond's lossy
;;;; links, those were most of the worst drag steps (0.6-1.5 s) once webrtc-data's RACK-TLP had
;;;; dealt with the box's own losses.
;;;;
;;;; A pointer move does not need to be reliable.  It needs the LATEST one to arrive, soon.  So the
;;;; payload sends moves on stream 106 -- unordered, never retransmitted -- with a sequence number,
;;;; and repeats the latest one a little later unless a newer one has gone.  One lost copy costs
;;;; nothing; losing all of them takes three losses in a row.
;;;;
;;;; ==============================================================================================
;;;; WHAT STAYS ON THE RFB CHANNEL, AND HOW THE TWO ARE KEPT IN ORDER
;;;; ==============================================================================================
;;;;
;;;; A button change -- press, release -- is NOT a move.  Lose one and a click is gone or a drag never
;;;; ends.  So it stays on the reliable channel, in order with the keystrokes around it (shift-click
;;;; must not become a click).  The payload sends each pointer event there ON ITS OWN, and counts
;;;; them; every message on 106 carries that count.  The gateway counts the 6-byte PointerEvents it
;;;; passes to glass from the RFB channel, and compares:
;;;;
;;;;   count < ours   the move was sent before a click glass already has: stale, dropped
;;;;   count = ours   in step: forwarded if it is newer than the last move forwarded
;;;;   count > ours   sent after a click that has not arrived yet: HELD (the newest such one), and
;;;;                  forwarded the moment that click is -- so a press and the drag after it reach
;;;;                  glass in that order even when the press is the packet that was lost
;;;;
;;;; A 106 message is 12 bytes: SEQ (u32) COUNT (u16) and the RFB PointerEvent itself (type 5, mask,
;;;; x u16, y u16), which is what glass is handed.
;;;;
;;;; PURE: no socket, no association.  The gateway passes bytes in and writes what comes out to glass
;;;; between two whole RFB-channel messages -- one event loop, so nothing can split one.

(in-package #:webrtc-data)

(defconstant +pointer-stream-id+ 106)

(defun pointer-sid-p (sid)
  "T iff SID is the pointer stream -- claimed unconditionally, like the payload and warp streams:
falling through to the RFB branch would hand glass a 12-byte message as desktop input."
  (eql sid +pointer-stream-id+))

(defclass pointer-state ()
  ((seq :initform nil :accessor pointer-seq
        :documentation "SEQ of the last move forwarded to glass, or NIL")
   (rfb-count :initform 0 :accessor pointer-rfb-count
              :documentation "PointerEvents passed to glass from the RFB channel, mod 2^16")
   (held :initform nil :accessor pointer-held
         :documentation "(seq count event): the newest move waiting for its click")
   (forwarded :initform 0 :accessor pointer-forwarded
              :documentation "moves passed to glass from this channel, for [stats]"))
  (:documentation "One session's pointer channel: what has been forwarded, and what is waiting."))

(defun make-pointer-state () (make-instance 'pointer-state))

(defun %seq-after-p (a b bits)
  "Is A after B in BITS-bit serial arithmetic?"
  (let ((d (logand (- a b) (1- (ash 1 bits)))))
    (and (plusp d) (< d (ash 1 (1- bits))))))

(defun %rfb-pointer-event-p (bytes)
  (and (= (length bytes) 6) (= (aref bytes 0) 5)))

(defun pointer-note-rfb (state bytes)
  "BYTES were just passed to glass from the RFB channel.  If they were a PointerEvent, count it,
and return a held move that was waiting for exactly this one -- to be passed to glass next -- or NIL."
  (when (and state (%rfb-pointer-event-p bytes))
    (setf (pointer-rfb-count state) (logand (1+ (pointer-rfb-count state)) #xffff))
    (let ((held (pointer-held state)))
      (when (and held (= (second held) (pointer-rfb-count state)))
        (setf (pointer-held state) nil
              (pointer-seq state) (first held))
        (incf (pointer-forwarded state))
        (third held)))))

(defun pointer-on-message (state payload)
  "One message from stream 106.  Returns the RFB PointerEvent to pass to glass now, or NIL."
  (when (and state (= (length payload) 12) (= (aref payload 6) 5))
    (let* ((p (coerce payload '(vector (unsigned-byte 8))))
           (seq (logior (ash (aref p 0) 24) (ash (aref p 1) 16) (ash (aref p 2) 8) (aref p 3)))
           (count (logior (ash (aref p 4) 8) (aref p 5)))
           (event (subseq p 6 12))
           (ours (pointer-rfb-count state))
           (last (pointer-seq state)))
      (cond ((and last (not (%seq-after-p seq last 32))) nil)          ; a repeat, or overtaken
            ((%seq-after-p ours count 16) nil)                         ; before a click glass has
            ((%seq-after-p count ours 16)                              ; after a click still coming
             (let ((held (pointer-held state)))
               (when (or (null held) (%seq-after-p seq (first held) 32))
                 (setf (pointer-held state) (list seq count event))))
             nil)
            (t (setf (pointer-seq state) seq)
               (incf (pointer-forwarded state))
               event)))))

(defun pointer-stats (state)
  "Moves forwarded from this channel so far (0 without a state)."
  (if state (pointer-forwarded state) 0))
