;;;; gateway-http-test.lisp — the HTTP gateway's routes, asked by clients that are not ours.
;;;;
;;;;   sbcl --dynamic-space-size 2048 --non-interactive --load gateway-http-test.lisp
;;;;
;;;; START-GATEWAY on 127.0.0.1 and an ephemeral port, then Python's http.client for GET / (the
;;;; page), GET /novnc/<a vendored file> (the static folder), GET /stats, GET /drop?rate=,
;;;; a 404 and a path that tries to leave novnc/; then a real offer from webrtc-data's own
;;;; calling side POSTed to /signal by curl, and its answer carried through ICE and DTLS to
;;;; an open data channel.  NO DESKTOP: GLASS_HOST names a socket file that does not exist,
;;;; so the session's dial to glass fails and the session closes; what is checked is that
;;;; the gateway signalled and connected, not that it drew anything.  STOP-GATEWAY must leave
;;;; the port closed.

(require :asdf)
(asdf:initialize-source-registry)       ; modus's ASDF reads CL_SOURCE_REGISTRY only when asked
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "glass-webrtc")))
;; Set after loading, not through GLASS_HOST: no SB-POSIX:SETENV needed (modus has none).
(defvar *no-desktop* (format nil "unix:~a/gw-http-test-no-desktop-~d.rfb"
                             (or (uiop:getenv "TMPDIR") "/tmp") (random 1000000000 (make-random-state t))))
(setf webrtc-data::*glass-host* *no-desktop*)

(defpackage #:gw-http-test (:use #:cl) (:local-nicknames (#:wd #:webrtc-data)
                                                         (#:http #:cl-transport.http-server)))
(in-package #:gw-http-test)

(defvar *checks* 0) (defvar *fails* 0)
(defun check (name ok &optional detail)
  (incf *checks*) (unless ok (incf *fails*))
  (format t "  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" ok name detail) (finish-output))

(defun run (program args &optional input)
  (with-output-to-string (o)
    (with-input-from-string (in (or input ""))
      (sb-ext:run-program program args :search t :input in :output o :error nil))))

(defun refused-p (port)
  (handler-case
      (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
        (unwind-protect (progn (sb-bsd-sockets:socket-connect s #(127 0 0 1) port) nil)
          (ignore-errors (sb-bsd-sockets:socket-close s))))
    (error () t)))

(format t "~&== glass-webrtc: the HTTP gateway ==~%")
(check "hunchentoot is not loaded" (not (find-package "HUNCHENTOOT")))
(defvar *server* (wd::start-gateway :port 0 :address "127.0.0.1" :park nil))
(defvar *port* (http:server-port *server*))
(check "START-GATEWAY returns the server, and *ACCEPTOR* is it (vessel's one.lisp waits on it)"
       (and *server* (eq *server* wd::*acceptor*) (integerp *port*)))

;; a vendored noVNC file, whichever one is there, by its path under novnc/
(defvar *novnc-file*
  (let ((f (first (directory (merge-pathnames "core/*.js" wd::*novnc*)))))
    (and f (subseq (namestring f) (length (namestring wd::*novnc*))))))

(let ((got (run "python3" (list "-I" "-c" (format nil "
import http.client, json
port = ~d
def get(path):
    c = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    c.request('GET', path); r = c.getresponse(); b = r.read()
    return [r.status, r.getheader('Content-Type'), len(b), b[:200].decode('utf-8', 'replace')]
print(json.dumps({'index': get('/'), 'novnc': get('/novnc/~a'), 'stats': get('/stats'),
                  'drop': get('/drop?rate=0.0'), 'missing': get('/nope'),
                  'escape': get('/novnc/../gateway.lisp')}))
" *port* *novnc-file*)))))
  (check "python: GET / is the page, text/html" (search "\"index\": [200, \"text/html\"" got) got)
  (check (format nil "python: GET /novnc/~a from the static folder" *novnc-file*)
         (search "\"novnc\": [200, \"text/javascript; charset=utf-8\"" got))
  (check "python: GET /stats is JSON ({} with no session yet)"
         (search "\"stats\": [200, \"application/json\", 2, \"{}\"]" got))
  (check "python: GET /drop?rate=0.0 sets the knob" (search "drop-rate=0.0" got))
  (check "python: an unrouted path is a 404" (search "\"missing\": [404" got))
  (check "python: nothing outside novnc/ is served" (search "\"escape\": [404" got)))

;; a real offer, from webrtc-data's calling side, POSTed by curl
(let* ((status nil)
       (peer (handler-case
                 (wd:connect-peer
                  (lambda (offer)
                    (let* ((out (run "curl" (list "-sS" "-o" "-" "-w" (format nil "~%%{http_code} %{content_type}")
                                                  "--data-binary" "@-"
                                                  (format nil "http://127.0.0.1:~d/signal" *port*))
                                     offer))
                           (nl (position #\Newline out :from-end t)))
                      (setf status (subseq out (1+ nl)))
                      (subseq out 0 nl)))
                  :local-ip "127.0.0.1" :channels '(("rfb")) :timeout 20.0)
               (error (e) (check "connect-peer through POST /signal" nil (princ-to-string e)) nil))))
  (when peer
    (check "curl: POST /signal answered 200 application/sdp" (equal status "200 application/sdp") status)
    (check "the answer connected: ICE, DTLS, SCTP, a data channel open" (wd:rtc-open-p peer))
    (ignore-errors (wd:rtc-close peer :abort t))))

(check "STOP-GATEWAY says it stopped" (wd::stop-gateway))
(check "*ACCEPTOR* is NIL after" (null wd::*acceptor*))
(check "and the port no longer accepts" (refused-p *port*))

(format t "~&checks: ~d   failures: ~d   => ~:[FAIL~;PASS~]~%" *checks* *fails* (zerop *fails*))
(finish-output)
(sb-ext:exit :code (if (zerop *fails*) 0 1) :abort t)
