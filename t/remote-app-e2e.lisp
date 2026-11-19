;;;; t/remote-app-e2e.lisp -- glass's "Remote" window (glass/remote-webrtc) on a local window
;;;; manager, dialling the card t/dial-e2e.py started.  Run by that harness (E2E_* as there).
;;;;
;;;;   1. a fresh login link for the owner (as dial-e2e.lisp gets one)
;;;;   2. a local glass window manager with the Remote app on its menu, opened with the form
;;;;      filled from GLASS_REMOTE_BOX / GLASS_REMOTE_LINK -- and Connect CLICKED through the WM
;;;;   3. "connecting…", then the box's desktop inside the window, sized to the window
;;;;      (SetDesktopSize), seen on the LOCAL screen through an RFB viewer of the local WM
;;;;   4. a drag of the box's Clock window, made with the local pointer through the Remote window
;;;;   5. the window closed with its close box: the session ends at the box
;;;; Screenshots of the local screen to E2E_OUT/local-*.png.

(require :asdf)
(let ((setup (sb-ext:posix-getenv "E2E_SETUP")))
  (if (and setup (plusp (length setup)))
      (load setup)
      (asdf:initialize-source-registry
       `(:source-registry (:tree ,(namestring (merge-pathnames "../../" *load-truename*)))
                          :inherit-configuration))))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)) (*error-output* (make-broadcast-stream)))
    (asdf:load-system "glass/remote-webrtc")
    (asdf:load-system "glass/wm")
    (asdf:load-system "png-pure")))

(defpackage #:remote-app-e2e (:use #:cl) (:local-nicknames (#:gc #:glass-client) (#:rw #:glass-remote-webrtc)
                                                           (#:d #:glass-dial) (#:wd #:webrtc-data)))
(in-package #:remote-app-e2e)

(defvar *fails* 0)
(defvar *checks* 0)
(defun check (name ok &optional detail)
  (incf *checks*) (unless ok (incf *fails*))
  (format t "  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" ok name detail) (finish-output) ok)
(defun env (k) (let ((v (sb-ext:posix-getenv k))) (and v (plusp (length v)) v)))
(defun now () (/ (float (get-internal-real-time) 1d0) internal-time-units-per-second))
(defun wait-until (secs fn)
  (let ((end (+ (now) secs)))
    (loop (let ((v (funcall fn))) (when v (return v)))
          (when (> (now) end) (return nil))
          (sleep 0.05))))

(defparameter *relay* (env "E2E_RELAY"))
(defparameter *box* (env "E2E_BOX"))
(defparameter *out* (pathname (concatenate 'string (string-right-trim "/" (env "E2E_OUT")) "/")))

(defun owner-login-link (&key (timeout 60))
  "A fresh login link: the owner DMs the box `link', the box DMs one back (dial-e2e.lisp's)."
  (let* ((kp (cl-nostr.keys:keypair-from-secret (env "E2E_OWNER_SEC")))
         (me (cl-nostr.keys:public-hex kp))
         (pool (cl-nostr.pool:make-pool (list *relay*)))
         (asked (- (get-universal-time) (encode-universal-time 0 0 0 1 1 1970 0) 1))
         (link nil))
    (unwind-protect
         (progn
           (cl-nostr.pool:pool-subscribe
            pool (list (cl-nostr.filter:make-filter :kinds '(1059) :tags (list (cons "p" (list me)))))
            :on-event (lambda (ev relay)
                        (declare (ignore relay))
                        (multiple-value-bind (text sender at) (ignore-errors (cl-nostr.nip59:unwrap-giftwrap kp ev))
                          (let ((p (and text (equal sender *box*) (>= at asked) (search "code=" text))))
                            (when p
                              (setf link (subseq text (1+ (or (position #\Space text :end p :from-end t) -1))
                                                 (or (position-if (lambda (c) (member c '(#\Space #\Newline))) text :start p)
                                                     (length text)))))))))
           (cl-nostr.pool:pool-publish-sync pool (cl-nostr.nip59:build-giftwrap kp *box* "link"))
           (wait-until timeout (lambda () link)))
      (ignore-errors (cl-nostr.pool:close-pool pool))
      (cl-nostr.keys:keypair-wipe kp))))

(defun light-grey-p (p)
  (let ((r (ldb (byte 8 16) p)) (g (ldb (byte 8 8) p)) (b (ldb (byte 8 0) p)))
    (and (<= 190 r 230) (< (abs (- r g)) 8) (< (abs (- g b)) 8))))

(defun title-bar (fb &key (x0 0) (y0 20) (x1 (glass:fb-width fb)) (y1 (floor (glass:fb-height fb) 2)))
  "(X Y LEFT) in the first title bar inside the box X0..X1, Y0..Y1 (dial-e2e.lisp's)."
  (glass:with-fb-locked (fb)
    (loop for y from y0 below (min y1 (glass:fb-height fb))
          do (let ((run 0) (best 0) (best-start 0) (start 0))
               (loop for x from x0 below (min x1 (glass:fb-width fb))
                     do (if (light-grey-p (glass:fb-get fb x y))
                            (progn (when (zerop run) (setf start x)) (incf run)
                                   (when (> run best) (setf best run best-start start)))
                            (setf run 0)))
               (when (and (>= best 150) (< best 600))
                 (return-from title-bar (list (+ best-start (floor best 3)) (+ y 8) best-start)))))
    nil))

(defun screenshot (fb name)
  (let* ((w (glass:fb-width fb)) (h (glass:fb-height fb))
         (rgb (make-array (* w h 3) :element-type '(unsigned-byte 8)))
         (path (merge-pathnames (format nil "~a.png" name) *out*)))
    (glass:with-fb-locked (fb)
      (dotimes (y h) (dotimes (x w)
                       (let ((p (glass:fb-get fb x y)) (i (* 3 (+ x (* y w)))))
                         (setf (aref rgb i) (ldb (byte 8 16) p) (aref rgb (+ i 1)) (ldb (byte 8 8) p)
                               (aref rgb (+ i 2)) (ldb (byte 8 0) p))))))
    (png-pure:write-png-file rgb w h path)
    (format t "     screenshot ~a~%" (namestring path))
    path))

(defun free-port ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect (progn (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
                           (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (sb-bsd-sockets:socket-close s))))

(defun card-aborts ()
  (let ((log (ignore-errors (uiop:read-file-string (env "E2E_CARD_LOG")))))
    (if log (loop for p = (search "SCTP aborted" log) then (search "SCTP aborted" log :start2 (1+ p))
                  while p count t)
        0)))

(defun run ()
  (format t "~&== remote-app-e2e: the Remote window, relay ~a, box ~a… ==~%" *relay* (subseq *box* 0 8))
  (let ((link (owner-login-link))
        (dir (merge-pathnames "remote-app-store/" *out*)))
    (unless (check "a fresh login link for the owner" link) (return-from run))
    (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)
    (sb-posix:setenv "GLASS_REMOTE_BOX" (cl-nostr.bech32:npub-encode (cl-nostr.util:hex->bytes *box*)) 1)
    (sb-posix:setenv "GLASS_REMOTE_LINK" link 1)
    (sb-posix:setenv "GLASS_REMOTE_RELAYS" *relay* 1)
    (sb-posix:setenv "GLASS_REMOTE_DIR" (namestring dir) 1)
    (let* ((port (free-port)) (sw 1100) (sh 760))
      (multiple-value-bind (listener network compositor)
          (glass.wm:start-wm port :width sw :height sh :open '("Remote"))
        (declare (ignore network compositor))
        (sb-thread:make-thread (lambda () (ignore-errors (glass-repl:run-listener listener))) :name "listener")
        (let* ((view (gc:connect-remote "127.0.0.1" port))      ; our own screen, as a viewer sees it
               (lfb (gc:remote-fb view))
               (app (wait-until 10 (lambda () (first rw:*remote-apps*))))
               ;; the first window opens at (40, 40 + title) when it fits: wm.lisp's WM-OPEN
               (ox 40) (oy (+ 40 (glass.wm::wm-titleh))))
          (check "the window manager offers Remote and opened it" app)
          (check "a viewer of the local desktop is up" (wait-until 10 (lambda () (and (gc:remote-connected-p view)
                                                                                       (plusp (getf (gc:remote-stats view) :frames))))))
          (sleep 0.5)
          (check "the form is showing, filled from the environment" (eq (rw:remote-app-state app) :ask))
          (screenshot lfb "local-0-form")
          ;; 2. click Connect (content 24,244 .. 144,278: remote-webrtc.lisp's %DRAW-FORM)
          (let ((bx (+ ox 24 50)) (by (+ oy 244 15)) (t0 (now)))
            (gc:remote-pointer view 0 bx by) (sleep 0.1)
            (gc:remote-pointer view 1 bx by) (sleep 0.1)
            (gc:remote-pointer view 0 bx by)
            (check "Connect clicked: the window says it is connecting"
                   (wait-until 3 (lambda () (eq (rw:remote-app-state app) :connecting))))
            (sleep 0.3)
            (screenshot lfb "local-1-connecting")
            (let ((up (wait-until 40 (lambda () (eq (rw:remote-app-state app) :up)))))
              (check "the box's desktop is in the window" up
                     (if up (format nil "~,2fs from the click" (- (now) t0))
                         (format nil "state ~(~a~): ~a" (rw:remote-app-state app) (rw:remote-app-status app))))
              (unless up (screenshot lfb "local-1-failed") (return-from run))))
          (let* ((r (rw:remote-app-remote app)) (rfb (gc:remote-fb r)))
            ;; 3. the desktop takes the window's shape
            (check "the box's desktop became the window's size (SetDesktopSize)"
                   (wait-until 10 (lambda () (and (= (gc:remote-width r) 900) (= (gc:remote-height r) 600))))
                   (format nil "~dx~d" (gc:remote-width r) (gc:remote-height r)))
            (let ((tb (wait-until 15 (lambda () (title-bar rfb)))))
              (check "the box's Clock window is on the box's desktop" tb tb)
              (let ((ltb (wait-until 10 (lambda () (title-bar lfb :x0 (+ ox 1) :y0 (+ oy 1)
                                                                   :x1 (+ ox 900) :y1 (+ oy 600))))))
                (sleep 0.5)
                (screenshot lfb "local-2-connected")
                (check "...and on the LOCAL screen, inside the Remote window, where it should be"
                       (and tb ltb (<= (abs (- (third ltb) (+ ox (third tb)))) 2))
                       (format nil "remote x ~a -> local x ~a (window at ~d)" (third tb) (third ltb) ox))
                ;; 4. drag it, with the local pointer
                (when (and tb ltb)
                  (destructuring-bind (lx ly lleft) ltb
                    (gc:remote-pointer view 0 lx ly) (sleep 0.1)
                    (gc:remote-pointer view 1 lx ly) (sleep 0.1)
                    (loop for i from 1 to 10 do (gc:remote-pointer view 1 (+ lx (* i 10)) (+ ly (* i 6))) (sleep 0.05))
                    (gc:remote-pointer view 0 (+ lx 100) (+ ly 60))
                    (let ((moved (wait-until 10 (lambda ()
                                                  (let ((n (title-bar lfb :x0 (+ ox 1) :y0 (+ oy 1)
                                                                          :x1 (+ ox 900) :y1 (+ oy 600))))
                                                    (and n (> (- (third n) lleft) 50) n))))))
                      (sleep 0.5)
                      (screenshot lfb "local-3-dragged")
                      (check "a local drag through the Remote window moved the box's Clock"
                             (and moved (<= 90 (- (third moved) lleft) 110))
                             (if moved (format nil "left ~d -> ~d" lleft (third moved)) "no movement")))))))
            ;; 5. close it with its close box (the title bar's right end)
            (let ((aborts (card-aborts))
                  (cx (+ ox 900 -10)) (cy (- oy (floor (glass.wm::wm-titleh) 2))))
              (gc:remote-pointer view 0 cx cy) (sleep 0.1)
              (gc:remote-pointer view 1 cx cy) (sleep 0.1)
              (gc:remote-pointer view 0 cx cy)
              (check "the close box closed the window" (wait-until 5 (lambda () (null rw:*remote-apps*))))
              (check "...and the box ended the session" (wait-until 10 (lambda () (> (card-aborts) aborts))))
              (sleep 0.5)
              (screenshot lfb "local-4-closed"))))))))

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
(format t "~&remote-app-e2e: ~d/~d passed~%" (- *checks* *fails*) *checks*)
(finish-output)
(sb-ext:exit :code (if (zerop *fails*) 0 1) :abort t)
