;;;; card-desk.lisp -- the card's desktop, the same file under SBCL and hosted modus: glass's window
;;;; manager (glass.wm:serve-wm), or with CARD_DESK=lean glass's lean desk (glass.desk:serve-desk).
;;;; MODUS_ROOT = source tree, MODUS_RFB_PORT = loopback port.
(require :asdf)
(defvar *root* (or (sb-ext:posix-getenv "MODUS_ROOT") "/opt/modus-lisp"))
(dolist (d (directory (format nil "~A/*/" *root*))) (push d asdf:*central-registry*))
(let ((t0 (get-internal-real-time)))
  (asdf:load-system (if (equal (sb-ext:posix-getenv "CARD_DESK") "lean") :glass/desk-serve :glass/wm))
  (format t "~&card-desk: loaded in ~,1f s~%"
          (/ (- (get-internal-real-time) t0) internal-time-units-per-second)))
;; CARD_SYMDUMP=FILE (modus): every function's code address, for naming PCs in a core dump later
#+modus
(let ((f (sb-ext:posix-getenv "CARD_SYMDUMP")))
  (when (and f (plusp (length f)))
    (with-open-file (o f :direction :output :if-exists :supersede)
      (do-all-symbols (s)
        (let ((fn (and (fboundp s) (not (special-operator-p s)) (not (macro-function s))
                       (ignore-errors (symbol-function s)))))
          (when fn
            (let ((w (modus-int::%val->word fn)))
              (when (eql (logand w 15) 3)
                (format o "~x ~a::~a~%" (- w 3)
                        (if (symbol-package s) (package-name (symbol-package s)) "") (symbol-name s))))))))
    (format t "~&card-desk: symbols dumped~%") (finish-output)))
(let ((port (parse-integer (sb-ext:posix-getenv "MODUS_RFB_PORT"))))
  (format t "~&card-desk: serving on 127.0.0.1:~D~%" port)
  (finish-output)
  ;; CARD_DESK=lean: glass.desk:serve-desk, the lean desk; otherwise glass.wm:serve-wm
  (if (not (equal (sb-ext:posix-getenv "CARD_DESK") "lean"))
      (funcall (find-symbol "SERVE-WM" "GLASS.WM") port :width 640 :height 480)
      (funcall (find-symbol "SERVE-DESK" "GLASS.DESK") port :width 640 :height 480)))
