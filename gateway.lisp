;;;; gateway.lisp — serve glass over WebRTC to a browser (noVNC on the data channel).
;;;;
;;;; cl-transport/http-server serves the noVNC page + one POST /signal for the SDP exchange.  For each
;;;; browser we set up the webrtc-data answerer (ICE-lite -> DTLS -> SCTP), and when the data
;;;; channel opens we open a TCP connection to glass's RFB server and pump bytes both ways:
;;;;   glass -> channel  (one message per read; SCTP fragments + the peer reassembles)
;;;;   channel -> glass  (noVNC's RFB client messages)
;;;; The gateway is transparent to RFB: noVNC is the client, glass is the server.

(require :asdf)
;; Bigger GC nursery: the SCTP/DTLS send path conses ~7 KB/packet, so at a few thousand
;; packets/s the default nursery collects often enough to skim ~6% off throughput.  Trade some
;; resident memory for fewer collections during a full-frame blast.  (Measured ~6%; the rest of
;; the throughput ceiling is CPU-bound in AES-GCM, not GC.)
#+sbcl (setf (sb-ext:bytes-consed-between-gcs) (* 256 1024 1024))
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system "webrtc-data")
  ;; glass, for GLASS:OPEN-CONNECTION alone: the desktop can be a port or a SOCKET FILE, and the
  ;; endpoint syntax that says which lives in glass so that both ends of it cannot drift.  It
  ;; starts nothing and listens on nothing — see gateway-nostr.lisp, which loads it for the
  ;; audio, microphone and admission halves as well.
  (asdf:load-system "glass")
  ;; The HTTP half is the org's own (it was hunchentoot, which brought cl+ssl, CFFI and
  ;; OpenSSL along for a server that never spoke TLS): no Quicklisp needed.
  (asdf:load-system "cl-transport/http-server")
  (asdf:load-system "cl-transport/chan"))

(in-package #:webrtc-data)

(defparameter *dir*
  ;; WHERE THIS FILE'S ASSETS ARE — novnc/ and index.html sit beside the source.
  ;;
  ;; *LOAD-PATHNAME* alone was right while this was only ever LOADed as a script, and
  ;; wrong the moment it became an ASDF system: compiling through ASDF loads a FASL out
  ;; of ~/.cache, so the directory of the thing being loaded is the cache, and noVNC
  ;; would be looked for in there.  Ask ASDF where the system's source is when the
  ;; system is registered, and fall back to the load path for a plain script load,
  ;; which is still how kiln's boot files start it.
  (or (ignore-errors (asdf:system-source-directory "glass-webrtc"))
      (uiop:pathname-directory-pathname
       (or *load-pathname* *default-pathname-defaults*))))
;; noVNC: $NOVNC_DIR, else the vendored copy next to this demo (novnc/, includes our TRLE decoder).
(defparameter *novnc* (truename (or (uiop:getenv "NOVNC_DIR")
                                    (merge-pathnames "novnc/" *dir*))))
(defparameter *index* (uiop:read-file-string (merge-pathnames "index.html" *dir*)))
(defparameter *port*       (or (ignore-errors (parse-integer (uiop:getenv "GW_PORT"))) 8765))
(defparameter *epoch* (get-internal-real-time))   ; series time origin (ms since load)
(defparameter *glass-host* (or (uiop:getenv "GLASS_HOST") "127.0.0.1")
  "Where the desktop is: a hostname beside GLASS_PORT (the default, unchanged), or a SOCKET FILE
   — `unix:/home/claude/.glass/run/seat-0.rfb', or a bare absolute path.  127.0.0.1 is not a
   boundary: every process of every uid on the box can open a loopback port.  A socket file at
   mode 0600 is owner-only and the kernel enforces it.")
(defparameter *glass-port* (or (ignore-errors (parse-integer (uiop:getenv "GLASS_PORT"))) 5900))

(defun glass-connect ()
  ;; no Nagle: we forward tiny RFB messages (FramebufferUpdateRequests, key/pointer events)
  ;; toward glass — Nagle would batch them and add ~40ms of interactive latency per round trip.
  ;; glass sets TCP_NODELAY on its accept socket; we set it on our end of the same connection.
  ;; (On a socket file there is no Nagle to disable, and OPEN-CONNECTION ignores the refusal.)
  (values (glass:open-connection :host *glass-host* :port *glass-port*)))

;;; ---- THREADS SHARE NOTHING ---------------------------------------------------------------------
;;;
;;; An HTTP handler runs on a connection thread of the server.  It stores nothing of its own
;;; anywhere shared: POST /signal starts the browser's session on a NAMED function (SESSION-MAIN)
;;; with the offer STRING as an argument and waits for the answer on a REPLY channel
;;; (CL-TRANSPORT.CHAN); the session thread owns everything it builds -- the ICE agent (PULL mode:
;;; it reads the UDP socket itself), DTLS, the SCTP association and the glass connection, which
;;; it also reads itself on every pass of its loop.  So there are no per-session helper threads.
;;;
;;; What other threads need to SEE crosses through memory made once, at load, on the main thread,
;;; and written only with numbers and bytes -- which on modus is the only kind of store one thread
;;; may make into another's memory:
;;;   *KNOBS*       integer knobs (the /drop rate, in parts per million), read by every session on
;;;                 every pass.  Integers, not doubles: on modus a DOUBLE-FLOAT array is not
;;;                 specialised (its element type is T), so a double a worker made is an object,
;;;                 and storing it into the main thread's array is refused.
;;;   *STATS-BUF*   the latest session's SCTP stats as JSON bytes, with *STATS-META* = [generation,
;;;                 length]: the writer makes the generation odd while it writes, so a reader that
;;;                 sees it change (or odd) reads again.

(defvar *knobs* (make-array 1 :element-type '(unsigned-byte 32) :initial-element 0)
  "[0] the outbound drop rate GET /drop sets, in parts per million; each session copies it into
its *SCTP-DROP-RATE*.")

(defun drop-rate () (/ (aref *knobs* 0) 1d6))
(defconstant +stats-bytes+ 8192)
(defvar *stats-buf* (make-array +stats-bytes+ :element-type '(unsigned-byte 8) :initial-element 0))
(defvar *stats-meta* (make-array 2 :element-type '(unsigned-byte 32) :initial-element 0))
(defvar *stats-lock* (sb-thread:make-mutex :name "gateway stats"))

(defun %stats-json (stats)
  (format nil "{~{~a~^,~}}"
          (loop for (k v) on stats by #'cddr
                collect (format nil "\"~(~a~)\":~a"
                                k (cond ((null v) -1) ((symbolp v) (format nil "\"~(~a~)\"" v))
                                        ((floatp v) (format nil "~,2f" v)) (t v))))))

(defun publish-stats (stats)
  "STATS (an SCTP-STATS plist) as what GET /stats answers, until the next one."
  (let* ((bytes (as-u8vec (map 'vector #'char-code (%stats-json stats))))
         (n (min (length bytes) +stats-bytes+)))
    (sb-thread:with-mutex (*stats-lock*)
      (setf (aref *stats-meta* 0) (logand (1+ (aref *stats-meta* 0)) #xffffffff))   ; odd: writing
      (replace *stats-buf* bytes :end2 n)
      (setf (aref *stats-meta* 1) n)
      (setf (aref *stats-meta* 0) (logand (1+ (aref *stats-meta* 0)) #xffffffff)))))

(defun read-stats ()
  "The JSON the last session published, or \"{}\"."
  (loop
    (let ((g (aref *stats-meta* 0)))
      (when (evenp g)
        (let* ((n (aref *stats-meta* 1))
               (s (map 'string #'code-char (subseq *stats-buf* 0 n))))
          (when (= g (aref *stats-meta* 0))
            (return (if (zerop n) "{}" s))))))
    (sleep 0.001)))

;;; ---- the session ---------------------------------------------------------------------------------

(defun %print-rates (prev now dt)
  (flet ((d (k) (- (getf now k) (getf prev k))))
    (format *error-output*
            "~&[stats] out ~,1f KB/s  in ~,1f KB/s  rtx ~a (~,1f%)  drops ~a  ~
             cwnd ~a  rwnd ~a  flight ~a  outq ~a  srtt ~a  rto ~,2f~%"
            (/ (d :bytes-out) 1024d0 dt) (/ (d :bytes-in) 1024d0 dt)
            (d :rtx)
            (if (plusp (d :data-out)) (* 100d0 (/ (d :rtx) (d :data-out))) 0d0)
            (d :drops)
            (getf now :cwnd) (getf now :peer-rwnd) (getf now :flight)
            (getf now :send-q)
            (let ((s (getf now :srtt-ms))) (if s (format nil "~,1fms" s) "-"))
            (getf now :rto))
    ;; machine-readable series line (parsed by the perf harness)
    (format *error-output*
            "~&PERFSVR ~,1f ~,2f ~,2f ~a ~a ~a ~,1f ~a ~a ~,2f~%"
            (/ (float (- (get-internal-real-time) *epoch*) 1d0) internal-time-units-per-second)
            (/ (d :bytes-out) 1024d0 dt) (/ (d :bytes-in) 1024d0 dt)
            (d :rtx) (d :drops) (getf now :cwnd)
            (or (getf now :srtt-ms) -1) (getf now :flight) (getf now :send-q)
            (getf now :rto))
    (finish-output *error-output*)))             ; flush: survive an ungraceful kill

(defun session-main (offer-sdp reply)
  "One browser's session, on its own thread: answer OFFER-SDP on REPLY, drive DTLS, run the data
channel, and bridge it to glass once it opens -- every part of it on this thread."
  (let ((glass nil) (glass-fd nil) (agent nil) (answered nil) (sid nil)
        (buf (make-array 16384 :element-type '(unsigned-byte 8)))
        (prev nil) (t0 (get-internal-real-time))
        (*sctp-drop-rate* (drop-rate)))           ; this thread's own copy of the knob
    (unwind-protect
        (handler-case
            (let* ((offer (parse-sdp offer-sdp))
                   ;; ICE_LOCAL_IP pins the advertised host candidate (multi-homed / netns /
                   ;; container deploys, where auto-detect can't reach 8.8.8.8); nil = auto-detect.
                   (a (setf agent (make-ice :local-ip (uiop:getenv "ICE_LOCAL_IP"))))
                   (conn (webrtc-dtls-setup a :remote-fingerprint (sdp-fingerprint offer)))
                   ;; GATHER_SRFLX=1 → advertise our public (STUN) address for NAT traversal;
                   ;; TURN_SERVER/TURN_USER/TURN_PASS additionally Allocates a TURN relay
                   ;; candidate, which covers symmetric NAT.  Both add a round-trip; off for LAN.
                   (answer (ice-answer a offer :fingerprint (dtls-conn-fingerprint conn)
                                               :gather-srflx (and (uiop:getenv "GATHER_SRFLX") t)
                                               :gather-relay (and (uiop:getenv "TURN_SERVER") t))))
              (ice-serve a :mode :pull)
              ;; full-agent checks (punch our NAT mapping open toward the peer) when NAT traversal is on
              (when (uiop:getenv "GATHER_SRFLX") (ice-start-checks a))
              (setf answered t)
              (cl-transport.chan:chan-send reply answer :timeout 5)
              (webrtc-dtls-run conn)
              (webrtc-serve-datachannel
               conn :duration 3600.0 :tick 0.005
               :on-ready
               (lambda (assoc id)
                 (declare (ignore assoc))
                 (unless sid
                   (setf sid id glass (glass-connect)
                         glass-fd (sb-bsd-sockets:socket-file-descriptor glass))
                   (format *error-output* "~&[gw] channel open (stream ~a) -> glass ~a~%"
                           id (glass:endpoint-string :host *glass-host* :port *glass-port*))))
               :on-message
               (lambda (assoc id payload)
                 (declare (ignore assoc id))
                 (when (and glass (plusp (length payload)))
                   (sb-bsd-sockets:socket-send glass (as-u8vec payload) (length payload))))
               :on-pass
               (lambda (assoc)
                 (setf *sctp-drop-rate* (drop-rate))
                 ;; glass -> browser: what glass has sent, each read as ONE message (SCTP
                 ;; fragments it; the peer reassembles, so noVNC sees one onmessage per read)
                 (when glass
                   (loop repeat 8
                         while (sb-sys:wait-until-fd-usable glass-fd :input 0)
                         do (multiple-value-bind (b n) (sb-bsd-sockets:socket-receive glass buf nil)
                              (declare (ignore b))
                              (when (or (null n) (zerop n))
                                (error "glass closed the connection"))
                              (sctp-send-binary assoc sid (subseq buf 0 n)))))
                 ;; transport health, every second: logged, and published for GET /stats
                 (when (and sid (> (- (get-internal-real-time) t0) internal-time-units-per-second))
                   (let ((now (sctp-stats assoc))
                         (dt (/ (float (- (get-internal-real-time) t0) 1d0)
                                internal-time-units-per-second)))
                     (when prev (%print-rates prev now dt))
                     (publish-stats now)
                     (setf prev now t0 (get-internal-real-time)))))))
          (error (e)
            (unless answered
              (ignore-errors (cl-transport.chan:chan-send reply (list :error (princ-to-string e))
                                                          :timeout 1)))
            (format *error-output* "~&[gw] session error: ~a~%" e)))
      ;; cleanup: close the glass connection so glass's per-client thread exits too
      (when glass (ignore-errors (sb-bsd-sockets:socket-close glass)))
      (when agent (ignore-errors (ice-close agent)))
      (format *error-output* "~&[gw] session closed~%"))))

;;; Reply channels, made once by START-GATEWAY on the thread that calls it (on modus a channel is
;;; never reclaimed): a free list of their numbers is itself a channel.
(defvar *replies* nil)
(defvar *free-replies* nil)
(defconstant +max-signals+ 16)

(defun handle-signal (request)
  "POST /signal: body is the browser's offer SDP; return our answer SDP."
  (setf (cl-transport.http-server:reply-content-type request) "application/sdp")
  (multiple-value-bind (i ok) (cl-transport.chan:chan-receive *free-replies* :timeout 10)
    (unless ok (error "gateway: too many offers at once"))
    (let ((reply (svref *replies* i)))
      (unwind-protect
           (progn
             (cl-transport.chan:chan-drain reply)
             (sb-thread:make-thread #'session-main :name "webrtc-session"
                                    :arguments (list (cl-transport.http-server:request-body-string request)
                                                     reply))
             (multiple-value-bind (answer got) (cl-transport.chan:chan-receive reply :timeout 60)
               (cond ((not got) (error "gateway: no answer within 60 s"))
                     ((stringp answer) answer)
                     (t (error "gateway: ~a" (second answer))))))
        (cl-transport.chan:chan-send *free-replies* i :timeout 1)))))

(defun handle-index (request)
  (setf (cl-transport.http-server:reply-content-type request) "text/html") *index*)

(defun handle-drop (request)
  "GET /drop?rate=R — set the outbound drop rate (a dev knob for simulating loss): *KNOBS*[0],
which every session copies into its *SCTP-DROP-RATE* on its next pass."
  (setf (cl-transport.http-server:reply-content-type request) "text/plain")
  (let ((r (ignore-errors (let ((*read-eval* nil))
                            (read-from-string (cl-transport.http-server:query-param request "rate"))))))
    (when (realp r)
      (setf (aref *knobs* 0) (max 0 (min 1000000 (round (* r 1000000)))))))
  (format nil "drop-rate=~a~%" (drop-rate)))

(defun handle-stats (request)
  "GET /stats — the latest session's SCTP transport stats as JSON."
  (setf (cl-transport.http-server:reply-content-type request) "application/json")
  (read-stats))

(defvar *acceptor* nil
  "The running HTTP server (a CL-TRANSPORT.HTTP-SERVER:SERVER), or NIL.  The name is from
   when it was a hunchentoot acceptor; vessel's one.lisp waits on it being non-NIL.")

(defun start-gateway (&key (port *port*) (address "0.0.0.0") (park t))
  "Install the routes, start the server, and (unless PARK is NIL) never return.

   SEPARATED FROM LOADING, which is what lets this file be part of a system rather
   than only a script.  It used to be four top-level forms: set the dispatch table,
   START the acceptor, print a banner, and (LOOP (SLEEP 5)).  Loading the file was
   therefore the same act as running the gateway — so an ASDF component of it would
   bind a port as a side effect of COMPILE-OP, and then never return from
   LOAD-SYSTEM.  Nothing could depend on this code without also starting it.

   PARK is what kiln's boot files want: they load this and expect it to hold the
   process open.  A caller that has its own event loop passes :PARK NIL and gets the
   server back.  PORT 0 binds an ephemeral port: (cl-transport.http-server:server-port
   *acceptor*) says which.

   The routes are THIS server's own, not a global dispatch table (hunchentoot's was one
   per image, so webrtc-data/transport's :webrtc EXPOSE in the same image replaced them)."
  (unless *replies*
    (setf *replies* (coerce (loop repeat +max-signals+
                                  collect (cl-transport.chan:make-chan :capacity 65536))
                            'simple-vector)
          *free-replies* (cl-transport.chan:make-chan :capacity 4096))
    (dotimes (i +max-signals+) (cl-transport.chan:chan-send *free-replies* i)))
  (webrtc-identity)                     ; made here, once, where every session can read it
  (setf *acceptor*
        (cl-transport.http-server:start-server
         :host address :port port :name "gateway"
         :routes `(("POST" "/signal" ,#'handle-signal)
                   ("GET" "/drop" ,#'handle-drop)
                   ("GET" "/stats" ,#'handle-stats)
                   ("GET" "/" ,#'handle-index))
         :static `(("/novnc/" ,*novnc*))))
  (format t "~&@@ gateway on http://~a:~a  (glass ~a, noVNC ~a)~%"
          address (cl-transport.http-server:server-port *acceptor*)
          (glass:endpoint-string :host *glass-host* :port *glass-port*) *novnc*)
  (finish-output)
  (when park (loop (sleep 5)))
  *acceptor*)

(defun stop-gateway ()
  "Stop the server if one is running: when this returns its port is closed."
  (when *acceptor*
    (ignore-errors (cl-transport.http-server:stop-server *acceptor*))
    (setf *acceptor* nil)
    t))
