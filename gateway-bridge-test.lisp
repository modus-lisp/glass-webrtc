;;;; gateway-bridge-test.lisp — the gateway's session bridging a data channel to a desktop.
;;;;
;;;;   sbcl --dynamic-space-size 2048 --non-interactive --load gateway-bridge-test.lisp
;;;;
;;;; gateway-http-test.lisp has no desktop, so the session's half that talks to glass never runs
;;;; there.  Here a stand-in desktop (an echo server on 127.0.0.1 and an ephemeral port, on a
;;;; thread of its own) takes the gateway's connection; a caller dials through POST /signal and
;;;; sends bytes on the channel, which must come back through glass's side of the bridge.  Then
;;;; GET /stats must show the session's SCTP counters, and GET /drop must reach the session.
;;;; Exits 0 iff all pass.

(require :asdf)
(asdf:initialize-source-registry)       ; modus's ASDF reads CL_SOURCE_REGISTRY only when asked
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "glass-webrtc")))

(defpackage #:gw-bridge-test (:use #:cl) (:local-nicknames (#:wd #:webrtc-data)
                                                           (#:http #:cl-transport.http-server)
                                                           (#:sock #:cl-transport.sockets)))
(in-package #:gw-bridge-test)

(defvar *checks* 0) (defvar *fails* 0)
(defun check (name ok &optional detail)
  (incf *checks*) (unless ok (incf *fails*))
  (format t "  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" ok name detail) (finish-output))

(defun echo-desktop (listener)
  "The stand-in desktop: one connection, every byte back, until it closes."
  (let ((ts (sock:tcp-accept listener :timeout-ms 60000)))
    (when ts
      (loop (multiple-value-bind (bytes eof) (sock:tcp-read-available ts)
              (when (plusp (length bytes)) (sock:tcp-write ts bytes))
              (when eof (return))
              (when (zerop (length bytes)) (sock:wait-readable (list ts) 100))))
      (sock:tcp-close ts))))

(defun run (program args &optional input)
  (with-output-to-string (o)
    (with-input-from-string (in (or input ""))
      (sb-ext:run-program program args :search t :input in :output o :error nil))))

(format t "~&== glass-webrtc: the gateway's bridge to a desktop ==~%")
(defvar *desk* (sock:tcp-listen :host "127.0.0.1" :port 0))
(setf wd::*glass-host* "127.0.0.1" wd::*glass-port* (sock:tcp-listener-port *desk*))
(sb-thread:make-thread #'echo-desktop :name "echo desktop" :arguments (list *desk*))
(defvar *server* (wd::start-gateway :port 0 :address "127.0.0.1" :park nil))
(defvar *port* (http:server-port *server*))

(let ((peer (handler-case
                (wd:connect-peer
                 (lambda (offer)
                   (let* ((out (run "curl" (list "-sS" "-o" "-" "--data-binary" "@-"
                                                 (format nil "http://127.0.0.1:~d/signal" *port*))
                                    offer)))
                     out))
                 :local-ip "127.0.0.1" :channels '(("rfb")) :timeout 30.0)
              (error (e) (check "connect-peer through POST /signal" nil (princ-to-string e)) nil))))
  (when peer
    (let* ((s (wd:rtc-channel-stream (wd:rtc-channel peer "rfb")))
           (msg (map '(vector (unsigned-byte 8)) #'char-code "RFB 003.008 through the bridge"))
           (back (make-array (length msg) :element-type '(unsigned-byte 8))))
      (write-sequence msg s) (force-output s)
      (read-sequence back s)
      (check "bytes on the channel reach the desktop and come back" (equalp back msg)
             (map 'string #'code-char back)))
    (sleep 2.5)                         ; the session publishes its stats once a second
    (let ((stats (run "curl" (list "-sS" (format nil "http://127.0.0.1:~d/stats" *port*)))))
      (check "GET /stats shows the session's counters" (search "\"bytes-out\":" stats) stats))
    (let ((drop (run "curl" (list "-sS" (format nil "http://127.0.0.1:~d/drop?rate=0.25" *port*)))))
      (check "GET /drop sets the knob" (search "drop-rate=0.25" drop) drop))
    (check "...in the knob every session reads on its next pass"
           (loop repeat 50 thereis (progn (sleep 0.1) (= (wd::drop-rate) 0.25d0))))
    (wd:rtc-close peer)
    (check "closed" (eq (wd:peer-state peer) :closed))))

(check "STOP-GATEWAY says it stopped" (wd::stop-gateway))
(sock:tcp-listener-close *desk*)
(format t "~&checks: ~d   failures: ~d   => ~:[FAIL~;PASS~]~%" *checks* *fails* (zerop *fails*))
(finish-output)
(sb-ext:exit :code (if (zerop *fails*) 0 1) :abort t)
