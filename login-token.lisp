;;;; login-token.lisp — one-time login codes for the glass gateway.
;;;;
;;;; A code is self-authenticating and stateless to MINT + cryptographically verify:
;;;;
;;;;   token = <nonce-hex> "." <exp-unix> "." <mac-hex>
;;;;   mac   = HMAC-SHA256( box-secret-bytes, "glass-login|" nonce "|" exp )
;;;;
;;;; Whoever holds the box secret can verify a token's MAC + expiry with no shared state.
;;;; The token is delivered to a user inside a gift-wrapped DM (only that npub can read it),
;;;; so holding a valid code is the proof of identity — no browser signer needed.
;;;;
;;;; SINGLE USE IS NOT IN THE TOKEN AND NEVER WAS.  An older version of this header claimed
;;;; the GATEWAY remembered spent nonces.  It never did, and the gateway's own comment said
;;;; the opposite — two files disagreeing about whether a credential could be replayed.  The
;;;; feature the doc described has since been written, and it lives in the DESKTOP, not here:
;;;; glass/src/nostr.lisp keeps a login-code store beside its enrolments and decides, in one
;;;; critical section, what becomes of every code:
;;;;
;;;;   redeemed    bound to the FIRST pubkey that presented it.  That key may re-present it
;;;;               as often as it likes (the phone re-offers after a lost answer, and relay
;;;;               fan-out delivers one offer several times); ANY OTHER key is refused, and
;;;;               loudly, because a code goes to exactly one npub and two holders is a leak.
;;;;   superseded  a newer link was minted for the same recipient.
;;;;   expired     the MAC check refuses it and the row is pruned.
;;;;
;;;; NONE OF THAT IS VISIBLE IN THE WIRE FORMAT, which is frozen: the MAC is over
;;;; "glass-login|nonce|exp" and nothing else, so a token minted by this file still verifies
;;;; there and every link ever issued keeps working.  The bindings are the STORE's.
;;;;
;;;; SO A CODE MINTED HERE IS SINGLE-USE BUT SUPERSEDES NOTHING.  This file mints in whatever
;;;; process loads it — the login-link CLI, out of band — and cannot reach the desktop's store
;;;; to record a recipient.  It is still redeemed exactly once (the desktop records it at
;;;; redemption).  A surface that wants "this link replaces the last one I sent you" has to
;;;; ask the desktop instead: the `link' DM command, or `glass-admit/1 mint pub=… for=…'.

(defpackage #:glass-login
  (:use #:cl)
  (:export #:mint-token #:verify-token #:token-nonce #:token-exp))

(in-package #:glass-login)

(defparameter *default-ttl* 900 "Default code lifetime, seconds (15 min).")
(defconstant +unix-epoch+ 2208988800)
(defun %now () (- (get-universal-time) +unix-epoch+))

(defun %u8 (n) (make-array n :element-type '(unsigned-byte 8)))
(defun %hex (bytes) (format nil "~(~{~2,'0x~}~)" (coerce bytes 'list)))

(defun %secret-bytes (secret)
  "SECRET as 64-hex string, bytes, or integer -> (unsigned-byte 8) vector."
  (etypecase secret
    (string (let ((v (%u8 (floor (length secret) 2))))
              (dotimes (i (length v) v)
                (setf (aref v i) (parse-integer secret :start (* 2 i) :end (+ 2 (* 2 i)) :radix 16)))))
    (integer (let ((v (%u8 32)))             ; 256 bits, big-endian
               (dotimes (i 32 v) (setf (aref v (- 31 i)) (ldb (byte 8 (* 8 i)) secret)))))
    (sequence (coerce secret '(simple-array (unsigned-byte 8) (*))))))

(defun %hmac-hex (key-bytes message)
  (%hex (natrium:hmac-sha256 key-bytes (map '(simple-array (unsigned-byte 8) (*)) #'char-code message))))

(defun %mac (secret nonce exp)
  (%hmac-hex (%secret-bytes secret) (format nil "glass-login|~a|~a" nonce exp)))

(defun %ct-equal (a b)
  "Constant-time string compare (avoid a timing oracle on the MAC)."
  (and (stringp a) (stringp b) (= (length a) (length b))
       (loop with diff = 0
             for ca across a for cb across b
             do (setf diff (logior diff (logxor (char-code ca) (char-code cb))))
             finally (return (zerop diff)))))

(defun mint-token (secret &key (ttl *default-ttl*))
  "Mint a one-time login code valid for TTL seconds, keyed by box SECRET."
  (let* ((nonce (%hex (natrium:random-bytes 16)))
         (exp   (+ (%now) ttl)))
    (format nil "~a.~a.~a" nonce exp (%mac secret nonce exp))))

(defun verify-token (secret token)
  "Verify TOKEN's MAC and expiry against box SECRET.  Returns (values OK NONCE EXP):
OK is T only if the MAC checks out AND the code has not expired.

CRYPTOGRAPHY ONLY.  OK means `this box minted it and it has not expired', which is strictly
weaker than `this key may use it'.  Whether it has already been traded, and to whom, is the
desktop's login-code store — see the header, and GLASS:ADMIT-PEER."
  (when (stringp token)
    (let ((dots (loop for i from 0 for c across token when (char= c #\.) collect i)))
      (when (= (length dots) 2)
        (let* ((nonce (subseq token 0 (first dots)))
               (exp-s (subseq token (1+ (first dots)) (second dots)))
               (mac   (subseq token (1+ (second dots))))
               (exp   (ignore-errors (parse-integer exp-s))))
          (when (and exp (%ct-equal mac (%mac secret nonce exp)))
            (values (> exp (%now)) nonce exp)))))))
