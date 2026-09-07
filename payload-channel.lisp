;;;; payload-channel.lisp — the client's own code, on the connection it is the client for.
;;;;
;;;; ==============================================================================================
;;;; WHAT THIS IS, AND WHAT IT IS FOR
;;;; ==============================================================================================
;;;;
;;;; The browser client used to be one 329 KB page published to nsite.  Every change to it — a
;;;; button, a gesture, a threshold — meant a new tag, a publish, a check-deploy, a re-pointed
;;;; `site-url.env`, a gateway restart and a user reloading at a DIFFERENT url, because publishing
;;;; REPLACES the manifest and the previous tag 404s.  That happened four times in one day.
;;;;
;;;; So the page was split.  The SHELL — signalling, the PeerConnection, credentials, the progress
;;;; screen — is what must run before a connection exists, so it cannot arrive over one, and it
;;;; stays on nsite.  The PAYLOAD is everything that only matters once the connection is up: noVNC,
;;;; the trackpad, the modifier row, paste, the quality ladder, the warp panel.  This file serves
;;;; that payload, over the connection the phone already has.
;;;;
;;;; The whole of the benefit is in one sentence: A CHANGE TO THE PAYLOAD NEEDS NO PUBLISH.  It does
;;;; not even need a restart — see the mtime check in PAYLOAD-BYTES — so shipping one is `cp` and a
;;;; reload of the SAME url.
;;;;
;;;; ==============================================================================================
;;;; WHY ALMOST NOTHING IS IN HERE
;;;; ==============================================================================================
;;;;
;;;; Same reason as warp-channel.lisp, and it is worth restating because it is the constraint that
;;;; shaped every decision below: THIS GATEWAY CARRIES A LIVE SESSION AND MAY NOT BE RUN to check
;;;; anything.  Every line here is verified by reading and by nothing else, so the design goal is to
;;;; have as few of them as possible and to give each one an obvious failure.
;;;;
;;;; Three things that could have lived here deliberately do not:
;;;;
;;;;   * COMPRESSION.  There is no deflate in this image, and adding one to a process supervised by
;;;;     a respawn loop is a bad trade for 70 KB.  `mksplit.py` writes `payload.js.gz` at build
;;;;     time and this file picks whichever of the two files the browser said it could take.
;;;;   * A JSON PARSER.  The one message this channel ever receives is ours and is three fields
;;;;     long, so it is scraped, exactly as `handle-control-message` scrapes the control channel.
;;;;   * ANY OPINION ABOUT THE PAYLOAD'S CONTENT.  We read a file, hash it, and send it.  The
;;;;     browser verifies the hash and refuses a mismatch, so a truncated or half-written file
;;;;     fails at the far end as a hash error rather than as an undebuggable client.
;;;;
;;;; ==============================================================================================
;;;; OFF UNLESS ASKED, AND INERT WHEN OFF
;;;; ==============================================================================================
;;;;
;;;; PAYLOAD_CHANNEL must be set for any of this to do anything.  Unset — the default, and what the
;;;; running gateway has — no file is read, no thread is started, nothing is sent, and the startup
;;;; banner does not mention it.  The one new branch in the session's message dispatch matches only
;;;; stream 104, which no deployed client has ever sent on; for streams 0, 100 and 102 the dispatch
;;;; is what it was, one NIL test earlier.
;;;;
;;;; What that branch is NOT is gated on the flag — see PAYLOAD-SID-P.  Disabled has to mean the
;;;; bytes are DROPPED, not that the clause is skipped, because skipping it would let them fall into
;;;; the RFB branch and reach a desktop as input.  0x7B is not an RFB client message type, and the
;;;; cost of finding that out is somebody's desktop connection.
;;;;
;;;; ==============================================================================================
;;;; THE STREAM ID
;;;; ==============================================================================================
;;;;
;;;;   rfb      stream 0     DCEP-negotiated by the browser   raw RFB bytes, binary
;;;;   control  stream 100   negotiated: true                 flat JSON, the video ladder
;;;;   warp     stream 102   negotiated: true                 warp's JSON delta frames
;;;;   payload  stream 104   negotiated: true                 JSON control + binary chunks
;;;;
;;;; 104 follows the convention warp-channel.lisp set: even, near the one that already works, out of
;;;; reach of the DCEP-allocated ids the browser hands out from the bottom.
;;;;
;;;; A negotiated channel COSTS NOTHING TO OPEN — no DCEP handshake — so the shell creating this one
;;;; for a box that does not serve it puts zero bytes on the wire, and the box learns the channel
;;;; exists the only way it can: a message arrives on 104.
;;;;
;;;; ==============================================================================================
;;;; THE PROTOCOL
;;;; ==============================================================================================
;;;;
;;;;   phone -> box   {"t":"hello","api":1,"have":"<sha256|>","enc":["gzip","raw"]}
;;;;
;;;;   box -> phone   {"t":"same","sha":"…"}                     the phone's cached copy is current
;;;;                  {"t":"none","why":"…"}                     this box has no payload to serve
;;;;                  {"t":"begin","sha":"…","enc":"gzip","len":N,"api":1}
;;;;                  …N bytes as binary messages on the same stream…
;;;;
;;;; No sequence numbers on the chunks, because the stream is ORDERED and that is exactly the
;;;; guarantee ordered delivery makes; the browser reassembles by arrival and checks the hash.  The
;;;; hash is over the bytes AS SENT (compressed, if compressed), so it is both the integrity check
;;;; and the cache key, and the two cannot disagree.
;;;;
;;;; ==============================================================================================
;;;; WHAT THIS MUST NEVER DO
;;;; ==============================================================================================
;;;;
;;;; gw-keepalive.sh respawns the gateway on exit, so an unguarded failure in here is not a missing
;;;; feature — it is a dead desktop, until somebody reaches a shell.  Hence: the load in
;;;; gateway-nostr.lisp is inside HANDLER-CASE with fallbacks for all four names; PAYLOAD-ON-MESSAGE
;;;; never signals; PAYLOAD-CLOSE never signals and tolerates being called with nothing to close;
;;;; and the sender runs on its OWN thread so that a full SCTP ready queue — SCTP-SEND-DATA blocks
;;;; when the queue is full — stalls the payload transfer and nothing else.  Sending 70 KB from the
;;;; receive loop would have blocked RFB input and video behind it.

(in-package #:webrtc-data)

;;; ---- the gate ---------------------------------------------------------------------------

(defparameter *payload-channel-enabled* (and (uiop:getenv "PAYLOAD_CHANNEL") t)
  "Whether this gateway serves the client payload at all.  Off unless PAYLOAD_CHANNEL is set.")

(defconstant +payload-stream-id+ 104)

(defun payload-sid-p (sid)
  "T iff SID is the payload stream.

DELIBERATELY NOT GATED ON *PAYLOAD-CHANNEL-ENABLED*, for the same reason WARP-SID-P is not.  Gated,
a phone whose shell asks for a payload from a box that does not serve one would fall past this
clause into the RFB one, and its {\"t\":\"hello\",…} would be handed to glass as remote-desktop
input.  The stream id claims its own traffic unconditionally; the DISABLED case is handled in
PAYLOAD-ON-MESSAGE, which answers `none` so the phone can say so and offer Retry."
  (eql sid +payload-stream-id+))

(defparameter *payload-file*
  (or (uiop:getenv "PAYLOAD_FILE")
      (namestring (merge-pathnames "payload.js"
                                   (or *load-pathname* *default-pathname-defaults*))))
  "The client payload, as mksplit.py writes it.  `payload.js.gz` beside it is used when the browser
says it can inflate.")

(defparameter *payload-chunk* 16384
  "Bytes per SCTP message.  Not per FRAGMENT — the association fragments at 1152 anyway.  This is
how much is handed to SCTP-SEND-DATA at once, and it is small for one reason: that call enqueues
every fragment of a message together and BLOCKS while the ready queue is full, so a single 70 KB
message would take 62 of the 512 ready-queue slots in one go and hold the queue against the glass
pump.  16 KB is 14 fragments — enough that the per-message overhead is nothing, small enough that
RFB and video keep interleaving normally.")

;;; ---- the file, read once and re-read when it changes -------------------------------------
;;; MTIME-CHECKED rather than read-once, and that is the feature rather than an optimisation: it is
;;; what makes shipping a client change `cp payload.js` with no gateway restart at all.  A phone
;;; that reconnects gets the new hash, sees it differs from its cache, and fetches.

(defvar *payload-cache* nil
  "(path enc bytes sha mtime size) for the most recently read payload, or NIL.")
(defvar *payload-lock* (bt:make-lock "payload-file"))

(defun %sha256-hex (bytes)
  (string-downcase (ironclad:byte-array-to-hex-string
                    (ironclad:digest-sequence :sha256 bytes))))

(defun %read-file-bytes (path)
  "PATH's contents as a byte vector, or NIL if it cannot be read.  Never signals."
  (ignore-errors
   (with-open-file (s path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
     (when s
       (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8))))
         (read-sequence buf s)
         buf)))))

(defun payload-bytes (gzip-ok)
  "The payload to serve, as (values BYTES SHA ENC), or NIL if there is nothing to serve.

Prefers payload.js.gz when the browser said it can inflate.  Cached on (path mtime size) so the
steady state is one FILE-WRITE-DATE per phone rather than a re-read and a re-hash — and so replacing
the file is picked up on the next connection with no restart."
  (let* ((base *payload-file*)
         (path (or (and gzip-ok
                        (let ((gz (concatenate 'string base ".gz")))
                          (and (probe-file gz) gz)))
                   (and (probe-file base) base))))
    (when path
      (let ((enc (if (and gzip-ok (> (length path) 3)
                          (string= ".gz" (subseq path (- (length path) 3))))
                     "gzip" "raw"))
            (mtime (ignore-errors (file-write-date path))))
        (bt:with-lock-held (*payload-lock*)
          (let ((c *payload-cache*))
            (if (and c (equal (first c) path) (eql (fifth c) mtime))
                (values (third c) (fourth c) (second c))
                (let ((bytes (%read-file-bytes path)))
                  (when (and bytes (plusp (length bytes)))
                    (let ((sha (%sha256-hex bytes)))
                      (setf *payload-cache* (list path enc bytes sha mtime (length bytes)))
                      (format *error-output* "~&[payload] ~a — ~a B ~a sha ~a~%"
                              path (length bytes) enc (subseq sha 0 16))
                      (finish-output *error-output*)
                      (values bytes sha enc)))))))))))

;;; ---- the one message we ever receive ------------------------------------------------------
;;; Scraped, not parsed: three fields, ours, and a parser would be the larger thing to trust.  This
;;; is the same call %JSON-STRING-VALUE makes for the control channel, and it is made here rather
;;; than reused because video-profiles.lisp may not be loaded before this file is.

(defun %payload-field (json key)
  "The quoted string value of KEY in a flat JSON object, or NIL."
  (let ((at (search (format nil "\"~a\"" key) json)))
    (when at
      (let* ((colon (position #\: json :start (+ at (length key) 2)))
             (open (and colon (position #\" json :start (1+ colon))))
             (close (and open (position #\" json :start (1+ open)))))
        (when close (subseq json (1+ open) close))))))

;;; ---- sending -------------------------------------------------------------------------------

(defun %payload-send-loop (assoc sid bytes sha enc alive-p)
  "Push BYTES down SID in *PAYLOAD-CHUNK* pieces.  Runs on its own thread; see the note at the top
about why.  Stops early if the association is gone or the session closed, because a transfer nobody
is waiting for is just a thread holding a queue."
  (handler-case
      (progn
        (sctp-send-string
         assoc sid
         (format nil "{\"t\":\"begin\",\"sha\":\"~a\",\"enc\":\"~a\",\"len\":~d,\"api\":1}"
                 sha enc (length bytes)))
        (loop with n = (length bytes)
              for off from 0 below n by *payload-chunk*
              do (unless (and (funcall alive-p)
                              (not (eq (getf (sctp-stats assoc) :state) :aborted)))
                   (format *error-output* "~&[payload] transfer abandoned at ~a/~a B~%" off n)
                   (finish-output *error-output*)
                   (return))
                 (sctp-send-binary assoc sid (subseq bytes off (min n (+ off *payload-chunk*))))
              finally (format *error-output* "~&[payload] sent ~a B (~a) to the phone~%" n enc)
                      (finish-output *error-output*)))
    (error (e)
      (format *error-output* "~&[payload] send failed: ~a~%" e)
      (finish-output *error-output*))))
;;; ---- the other direction: the phone puts a file on this box --------------------------------
;;;
;;; THE FILE BROWSER COULD LOOK AND NOT TOUCH.  warp-files has six commands and five of them read;
;;; the only writer is `delete'.  This is the missing half, and it is here rather than in warp
;;; because warp is a PRESENTATION protocol: stream 102 carries JSON deltas under a 1024 B/pass
;;; budget at 4 Hz, so a file would arrive base64'd, 33% fat, one kilobyte per quarter second,
;;; through the pipe that is supposed to be drawing the UI at the same time.  Stream 104 is already
;;; the bulk path -- 16 KB chunks, its own thread -- and it is IDLE from the moment the client is
;;; served.  Bytes go where bytes already go.
;;;
;;; NO NEW GATE, AND THAT IS DELIBERATE.  Every other capability here is behind an environment
;;; variable, and this session was spent discovering that three of them had never been set by the
;;; launcher -- the panel, the file browser and the chat all shipped invisible for a month because
;;; a flag nobody knew about defaulted off.  Upload is part of the file browser: if WARP_FILES is
;;; on, the browser can write.  One less thing that can be silently not-on.
;;;
;;; THE CLIENT ALREADY KNOWS WHERE TO PUT IT.  Container names on the warp wire are `col:<path>'
;;; per open column (files/dom.lisp), so the rightmost column IS the current directory and the
;;; phone can name it without asking.  Nothing was added to warp for this -- no command, no delta
;;; kind, no round trip.  And the new file needs no refresh: BROWSE-ROWS re-reads the open columns
;;; from disk every epoch (model.lisp), so it appears on the next pass by itself.
;;;
;;; WHAT IS *NOT* CHECKED, because the owner asked for it not to be: the destination is not confined
;;; to a root, the name is not rewritten, the size is not capped and an existing file is replaced.
;;; This is the owner's own box, reachable only by a terminal they enrolled, and the desktop beside
;;; this panel has a shell in its root menu -- an upload grants nothing that was not already there.
;;; (TRASH-ENTRY keeps its *WRITABLE-ROOT* check: that is existing policy in another repo and not
;;; mine to relax on the way past.)
;;;
;;; WHAT *IS* CHECKED IS THE PART THAT IS NOT A PERMISSION.  Bytes land in a dotfile beside the
;;; destination and are RENAMEd onto the real name only when the declared length has arrived, so an
;;; interrupted transfer leaves `.name.part' and never a truncated file wearing the real name --
;;; the browser would list it, the preview would decode it, and nothing would say it was half a
;;; file.  A short transfer is reported as an error and the part file is removed.  Rename within
;;; one directory is atomic on every filesystem this runs on.

(defclass payload-peer ()
  ((served :initarg :served :initform nil :accessor peer-served
           :documentation "NIL, T, or the closure that stops an in-flight payload send.")
   (up     :initarg :up     :initform nil :accessor peer-up
           :documentation "The upload in progress, or NIL."))
  (:documentation "One phone's state on stream 104.

IT USED TO BE THE BARE VALUE -- NIL / T / a stopper closure -- and the first clause of
PAYLOAD-ON-MESSAGE was `(state state)': once this peer had been served, EVERY later message was
dropped unread.  That is correct for a duplicate hello and fatal for an upload, which by definition
arrives after the client is running.  Two slots instead of one value, and the early-return now asks
only about the thing it was protecting."))

(defclass upload ()
  ((name   :initarg :name   :reader upload-name)
   (dir    :initarg :dir    :reader upload-dir)
   (len    :initarg :len    :reader upload-len)
   (got    :initform 0      :accessor upload-got)
   (part   :initarg :part   :reader upload-part)
   (stream :initarg :stream :reader upload-stream))
  (:documentation "One file arriving.  PART is the dotfile being written; the real name is claimed
by RENAME-FILE only once GOT reaches LEN."))

(defun %payload-field-int (json key)
  "The integer value of KEY in a flat JSON object, or NIL.  Unquoted, so %PAYLOAD-FIELD -- which
reads the text BETWEEN quotes -- cannot be used for it."
  (let ((at (search (format nil "\"~a\"" key) json)))
    (when at
      (let ((colon (position #\: json :start (+ at (length key) 2))))
        (when colon
          (let* ((s (position-if #'digit-char-p json :start colon))
                 (e (and s (or (position-if-not #'digit-char-p json :start s) (length json)))))
            (when s (values (parse-integer json :start s :end e)))))))))


(defun %upload-begin (json)
  "Open the transfer described by JSON, or signal.  Returns an UPLOAD."
  (let* ((name (%payload-field json "name"))
         (dir  (%payload-field json "dir"))
         (len  (%payload-field-int json "len")))
    (unless (and name (plusp (length name)))  (error "upload: no name"))
    (unless (and dir  (plusp (length dir)))   (error "upload: no dir"))
    (unless (and len  (>= len 0))             (error "upload: no length"))
    ;; The name is a BASENAME by construction: anything up to the last separator is dropped, so a
    ;; phone cannot walk out of the directory it is looking at by calling a file `../../x'.  That is
    ;; not a permission check -- the owner may browse anywhere and upload anywhere -- it is that the
    ;; destination shown in the UI must be the destination written, or the panel is lying.
    (let* ((base (subseq name (1+ (or (position #\/ name :from-end t) -1))))
           (base (if (plusp (length base)) base (error "upload: empty name")))
           (dirp (uiop:ensure-directory-pathname dir))
           (dest (merge-pathnames base dirp))
           (part (merge-pathnames (format nil ".~a.part" base) dirp)))
      (declare (ignorable dest))
      (make-instance 'upload
                     :name base :dir dirp :len len :part part
                     :stream (open part :direction :output :element-type '(unsigned-byte 8)
                                        :if-exists :supersede :if-does-not-exist :create)))))

(defun %upload-chunk (up bytes)
  "Write BYTES into UP.  Returns T when the declared length has arrived."
  (write-sequence bytes (upload-stream up))
  (incf (upload-got up) (length bytes))
  (>= (upload-got up) (upload-len up)))

(defun %upload-finish (up)
  "Close UP and claim the real name.  Returns the destination pathname."
  (close (upload-stream up))
  (let ((dest (merge-pathnames (upload-name up) (upload-dir up))))
    (rename-file (upload-part up) dest)
    dest))

(defun %upload-abort (up)
  "Give up on UP and leave nothing behind.  Never signals."
  (ignore-errors (close (upload-stream up)))
  (ignore-errors (delete-file (upload-part up)))
  nil)



(defun %payload-as-text (payload)
  "PAYLOAD as a string, whichever way the transport handed it over.

THE TRANSPORT GIVES EITHER, AND FORGETTING THAT COST A WORKING DESKTOP.  A control message on this
stream can arrive as a Lisp STRING or as a byte vector depending on how it came off the wire; the
original code tested for the string first and the upload rewrite dropped the test, so the hello --
which begins `{' -- went into AS-U8VEC and died with

    The value #\{ is not of type (UNSIGNED-BYTE 8)

on every single connection.  The handler caught it, returned the state unchanged, and answered
nothing at all, so the phone sat on `no answer on the payload channel -- the box may be running an
older gateway'.  It was running a NEWER one, and the newer one could not read hello."
  (if (stringp payload) payload (map 'string #'code-char (as-u8vec payload))))

(defun %payload-as-bytes (payload)
  "PAYLOAD as an (unsigned-byte 8) vector, whichever way the transport handed it over.  File chunks
arrive binary, so this is normally AS-U8VEC -- but it accepts a string for the same reason its twin
accepts bytes: which one turns up is the transport's business, not this file's."
  (if (stringp payload)
      (map '(vector (unsigned-byte 8)) #'char-code payload)
      (as-u8vec payload)))

(defun payload-on-message (state assoc sid payload pub)
  "One message on the payload stream.  Returns the peer's (possibly new) state.  NEVER SIGNALS.

TWO CONVERSATIONS SHARE THIS STREAM AND ONLY ONE OF THEM IS OLD.  Downward, the phone sends its
hello and we push the client; that half is unchanged.  Upward, the phone sends a file, and it does
so LONG AFTER it has been served -- so the first thing this function used to do, return early
because the peer was already answered, is exactly the thing an upload must get past.  The early
return is now about the payload send alone.

AN UPLOAD IN FLIGHT CLAIMS EVERY MESSAGE, which is what makes the framing free: there is no chunk
header, no magic byte and no base64, because once `up' has been accepted the next N bytes on this
ordered stream are the file and nothing else is talking.  It ends when the declared length arrives,
not on a trailer, so a client that dies mid-transfer cannot leave the stream in upload mode -- and
the association dying is what PAYLOAD-CLOSE is for.

THE FEATURE GATE IS HERE for the downward half, not in PAYLOAD-SID-P.  With the channel off we
answer `none` rather than dropping silently: the phone can then say 'this desktop is not serving the
client' and offer Retry, which is a much better failure than a spinner, and it costs one 40-byte
message."
  (declare (ignore pub))
  (handler-case
      (let ((peer (if (typep state 'payload-peer) state (make-instance 'payload-peer))))
        (cond
          ;; ---- bytes of a file already being received ----------------------------------------
          ((peer-up peer)
           (let ((up (peer-up peer)))
             (handler-case
                 (when (%upload-chunk up (%payload-as-bytes payload))
                   (let ((dest (%upload-finish up)))
                     (setf (peer-up peer) nil)
                     (format *error-output* "~&[payload] received ~a (~a B)~%"
                             dest (upload-len up))
                     (finish-output *error-output*)
                     (ignore-errors
                      (sctp-send-string
                       assoc sid (format nil "{\"t\":\"upok\",\"name\":\"~a\",\"len\":~d}"
                                         (upload-name up) (upload-len up))))))
               (error (e)
                 (%upload-abort up)
                 (setf (peer-up peer) nil)
                 (format *error-output* "~&[payload] upload failed: ~a~%" e)
                 (finish-output *error-output*)
                 (ignore-errors
                  (sctp-send-string assoc sid
                                    (format nil "{\"t\":\"uperr\",\"why\":\"~a\"}"
                                            (substitute #\Space #\" (princ-to-string e)))))))
             peer))
          (t
           (let ((json (%payload-as-text payload)))
             (cond
               ;; ---- the phone offers a file ---------------------------------------------------
               ((search "\"t\":\"up\"" json)
                (handler-case
                    (let ((up (%upload-begin json)))
                      (setf (peer-up peer) up)
                      (format *error-output* "~&[payload] receiving ~a into ~a (~a B)~%"
                              (upload-name up) (upload-dir up) (upload-len up))
                      (finish-output *error-output*)
                      ;; A zero-byte file is complete the moment it is opened and no chunk will
                      ;; ever arrive for it, so finish it here or it would hang the stream in
                      ;; upload mode forever.
                      (when (zerop (upload-len up))
                        (let ((dest (%upload-finish up)))
                          (setf (peer-up peer) nil)
                          (ignore-errors
                           (sctp-send-string
                            assoc sid (format nil "{\"t\":\"upok\",\"name\":\"~a\",\"len\":0}"
                                              (pathname-name dest)))))))
                  (error (e)
                    (format *error-output* "~&[payload] upload refused: ~a~%" e)
                    (finish-output *error-output*)
                    (ignore-errors
                     (sctp-send-string assoc sid
                                       (format nil "{\"t\":\"uperr\",\"why\":\"~a\"}"
                                               (substitute #\Space #\" (princ-to-string e)))))))
                peer)
               ;; A second hello from a phone we are already serving.  Ignore it: the first transfer
               ;; is either in flight or done, and starting another would put a second copy on the
               ;; wire and interleave the two on one ordered stream.
               ((peer-served peer) peer)
               ((not (search "\"hello\"" json)) peer)
               ((not *payload-channel-enabled*)
                (ignore-errors
                 (sctp-send-string assoc sid
                                   "{\"t\":\"none\",\"why\":\"this gateway does not serve the client payload\"}"))
                (setf (peer-served peer) t)
                peer)
               (t
                (let ((gzip-ok (and (%payload-field json "enc") (search "gzip" json))))
                  (multiple-value-bind (bytes sha enc) (payload-bytes (and gzip-ok t))
                    (cond
                      ((null bytes)
                       (format *error-output* "~&[payload] no payload file at ~a~%" *payload-file*)
                       (finish-output *error-output*)
                       (ignore-errors
                        (sctp-send-string assoc sid
                                          "{\"t\":\"none\",\"why\":\"no payload file on this box\"}"))
                       (setf (peer-served peer) t))
                      ;; The phone already holds this exact build.  Nothing goes on the wire, which
                      ;; is the whole of the cache: a reconnect costs one message each way.
                      ((equal sha (%payload-field json "have"))
                       (format *error-output* "~&[payload] phone already has ~a — nothing sent~%"
                               (subseq sha 0 16))
                       (finish-output *error-output*)
                       (ignore-errors
                        (sctp-send-string assoc sid
                                          (format nil "{\"t\":\"same\",\"sha\":\"~a\"}" sha)))
                       (setf (peer-served peer) t))
                      (t
                       ;; The flag the sender reads, so PAYLOAD-CLOSE can stop a transfer that is
                       ;; still running when the session unwinds.
                       (let ((closed nil))
                         (bt:make-thread
                          (lambda () (%payload-send-loop assoc sid bytes sha enc
                                                         (lambda () (not closed))))
                          :name "payload-send")
                         (setf (peer-served peer) (lambda () (setf closed t)))))))
                  peer)))))))
    (error (e)
      (format *error-output* "~&[payload] message: ~a~%" e)
      (finish-output *error-output*)
      state)))

(defun payload-close (state)
  "Stop this peer's transfer if one is still running and abandon any half-received upload.  Called
from the session's unwind path, so it may not signal and may be called with nothing to close.

THE UPLOAD HALF IS THE REASON THIS IS NOT A ONE-LINER ANY MORE.  A phone that goes away mid-transfer
leaves an open stream and a part file; without this the file would sit in the browsed directory as
`.name.part' forever, which is litter rather than a truncated file wearing a real name -- but litter
that accumulates once per dropped connection."
  (when (typep state 'payload-peer)
    (let ((s (peer-served state)))
      (when (functionp s) (ignore-errors (funcall s))))
    (when (peer-up state) (%upload-abort (peer-up state))))
  ;; The pre-CLOS representation, in case a session started before this file was reloaded.
  (when (functionp state) (ignore-errors (funcall state)))
  nil)
