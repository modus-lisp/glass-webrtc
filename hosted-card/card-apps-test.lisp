;;;; card-apps-test.lisp -- the McCLIM desktop's apps on the card's window manager (card-apps.lisp).
;;;;
;;;;   CARD_APPS=all GLASS_VOICE=/path/voice.graph sbcl --non-interactive --load hosted-card/card-apps-test.lisp
;;;;
;;;; Loads them as the card does, opens each from the window manager's menu and checks it paints;
;;;; the Speak clipboard / Speak selection items appear when, and only when, there is something to
;;;; say; and the voice is heard on the RFB port + 10, the mix the gateway takes to the phone.
;;;; Writes a screenshot of every window to $CARD_APPS_SHOTS (if set).

(require :asdf)
(let ((root (or (sb-ext:posix-getenv "MODUS_ROOT") (namestring (merge-pathnames "modus-lisp/" (user-homedir-pathname))))))
  (dolist (d (directory (format nil "~A/*/" root))) (push d asdf:*central-registry*)))
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system "glass/wm")))
(load (merge-pathnames "card-apps.lisp" *load-truename*))
(load-card-apps)
(require :sb-bsd-sockets)

(defvar *fails* 0)
(defun ok (name pass &optional detail)
  (format t "~&  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" pass name detail) (finish-output)
  (unless pass (incf *fails*)))

(defun painted-p (fb)
  "Does FB hold more than one colour?"
  (let ((px (glass:fb-pixels fb)) (seen (make-hash-table)))
    (loop for i below (length px) by 97 do (setf (gethash (aref px i) seen) t))
    (> (hash-table-count seen) 2)))

(defun shot (fb name)
  "FB as a PNG in $CARD_APPS_SHOTS (png-pure), to look at."
  (let ((dir (sb-ext:posix-getenv "CARD_APPS_SHOTS")))
    (when dir
      (ignore-errors
       (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system "png-pure"))
       (let* ((w (glass:fb-width fb)) (h (glass:fb-height fb)) (px (glass:fb-pixels fb))
              (out (make-array (* w h 3) :element-type '(unsigned-byte 8))))
         (dotimes (i (* w h))
           (let ((p (aref px i)))                         ; X8R8G8B8
             (setf (aref out (* 3 i)) (ldb (byte 8 16) p) (aref out (+ 1 (* 3 i))) (ldb (byte 8 8) p)
                   (aref out (+ 2 (* 3 i))) (ldb (byte 8 0) p))))
         (funcall (find-symbol "WRITE-PNG-FILE" "PNG-PURE") out w h (format nil "~a/~a.png" dir name)))))))

(format t "~&[card apps: ~{~(~a~)~^, ~}]~%" *card-apps*)
(let ((labels (mapcar #'first (glass.wm:wm-available-apps))))
  (dolist (want '((:files "Files") (:browser "Browser") (:podcasts "Podcasts") (:voice "Speak") (:voice "Listen")))
    (when (member (first want) *card-apps*)
      (ok (format nil "~a is on the root menu" (second want)) (member (second want) labels :test #'string=)))))

;;; every app opens and paints
(let* ((fb (glass:make-framebuffer 1280 720 glass:+white+))
       (wm (glass.wm:make-wm fb)))
  (setf (glass.wm:wm-apps wm)
        (mapcar (lambda (a) (destructuring-bind (l f &key (width 400) (height 300)) a (list l f width height)))
                (glass.wm:wm-available-apps)))
  (dolist (label '("Files" "Browser" "Podcasts" "Speak" "Listen" "Media"))
    (when (find label (glass.wm:wm-apps wm) :key #'first :test #'string=)
      (let ((s (handler-case (glass.wm:wm-open wm label) (error (e) (format t "~&  open ~a: ~a~%" label e) nil))))
        (ok (format nil "~a opens" label) s)
        (when s
          (loop repeat 40 do (glass.wm:wm-tick wm) (sleep 0.05))
          (let ((wfb (glass.wm::surf-fb s)))
            (ok (format nil "~a paints its window (~dx~d)" label (glass:fb-width wfb) (glass:fb-height wfb))
                (painted-p wfb))
            (shot wfb (string-downcase label)))
          (glass.wm::wm-close wm s)))))

  ;; Speak clipboard / Speak selection
  (when (member :voice *card-apps*)
    (let ((cb (glass:session-clipboard)))
      (glass:clipboard-clear cb)
      (ok "no Speak clipboard while nothing was copied" (null (glass.wm::clipboard-menu-items)))
      (glass:clipboard-set cb "copied from the phone")
      (ok "Speak clipboard once something was" (equal "Speak clipboard" (car (first (glass.wm::clipboard-menu-items))))))
    (let ((sel nil))
      (glass.wm:wm-register-app wm "Picked" (lambda (fb) (declare (ignore fb))
                                              (values nil nil nil nil nil nil nil (lambda () sel))))
      (let ((s (glass.wm:wm-open wm "Picked")))
        (ok "no Speak selection while nothing is highlighted"
            (not (find "Speak selection" (glass.wm::window-menu-items wm s) :key #'car :test #'string=)))
        (setf sel "highlighted words")
        (ok "Speak selection while something is"
            (find "Speak selection" (glass.wm::window-menu-items wm s) :key #'car :test #'string=))))))

;;; the voice is heard where the gateway listens
(when (and (member :voice *card-apps*) (sb-ext:posix-getenv "GLASS_VOICE"))
  (let* ((port (+ 20000 (random 20000))))
    (apply #'glass.wm:start-wm port :width 640 :height 480 (card-wm-sound-args port))
    (sleep 1)
    ;; (the compositor binds *MEDIA-MIXER* in its own thread; what is visible here is the global)
    (ok "the window manager's mixer became the session's (one mix)" glass::*session-mixer*)
    (let ((sock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
      (sb-bsd-sockets:socket-connect sock #(127 0 0 1) (+ port 10))
      (let* ((s (sb-bsd-sockets:socket-make-stream sock :input t :output t :element-type '(unsigned-byte 8)))
             (buf (make-array 4096 :element-type '(unsigned-byte 8)))
             (loud 0) (deadline (+ (get-internal-real-time) (* 30 internal-time-units-per-second))))
        (sleep 0.5)
        (glass.desk:voice-say glass.desk:*voice* "hello from the card")
        (loop while (and (< loud 2000) (< (get-internal-real-time) deadline))
              do (let ((n (read-sequence buf s)))
                   (loop for i from 0 below (1- n) by 2
                         for v = (let ((x (logior (aref buf i) (ash (aref buf (1+ i)) 8)))) (if (>= x 32768) (- x 65536) x))
                         when (> (abs v) 2000) do (incf loud))))
        (ok "the voice is heard on the RFB port + 10" (>= loud 2000) (format nil "~d loud samples" loud))))))

(format t "~&card apps: ~d failure~:p~%" *fails*)
(finish-output)
(sb-ext:exit :code (if (zerop *fails*) 0 1) :abort t)
