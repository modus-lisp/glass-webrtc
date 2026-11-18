;;;; card-control.lisp -- the running card, evaluated into: a UNIX socket that reads Lisp forms and
;;;; answers with what they returned (the McCLIM desktop's control socket, cortez/desktop-5903.lisp).
;;;;
;;;;   CARD_CONTROL=1 card.sh TAG ...        then      hosted-card/card-eval $CARD_DIR/TAG.control '(+ 1 2)'
;;;;
;;;; OFF unless CARD_CONTROL=1: nothing we ship listens by default, and this one evaluates anything
;;;; it is sent.  What guards it is the kernel: a socket file at 0600 in the card's folder, and a
;;;; peer whose uid is not the card's own is refused at accept(2) (cl-transport's :SAME-UID peer
;;;; policy, SO_PEERCRED) -- before a byte of it is read.  No TCP, so nothing off the box reaches it.
;;;;
;;;; A connection is a little REPL: each form read is evaluated in CL-USER with its output going back
;;;; down the connection, then its values, one per line, then a line "--" so a client knows the
;;;; answer is complete; an error is answered as "ERROR: ..." and the connection stays up.  End of
;;;; input ends it.  Each connection is a thread of its own (SBCL; on modus the card evaluates on
;;;; its main thread only, so this is SBCL's).

(defun %control-serve-one (stream)
  (let ((*package* (find-package "CL-USER")))
    (loop
      (let ((form (handler-case (read stream nil stream)
                    (error (e) (format stream "ERROR: unreadable: ~a~%--~%" e) (finish-output stream)
                      (return)))))
        (when (eq form stream) (return))
        (let ((values (handler-case
                          (let ((*standard-output* stream) (*error-output* stream))
                            (multiple-value-list (eval form)))
                        (error (e) (list (format nil "ERROR: ~a" e))))))
          (fresh-line stream)
          (dolist (v values) (format stream "~s~%" v))
          (format stream "--~%")
          (finish-output stream))))))

(defun start-card-control (&optional (path (sb-ext:posix-getenv "CARD_CONTROL_PATH")))
  "The control socket at PATH, when CARD_CONTROL=1 put one there.  Returns its thread, or NIL."
  (when (and path (plusp (length path)) (equal (sb-ext:posix-getenv "CARD_CONTROL") "1"))
    #+modus (progn (format t "~&card-control: not on modus (one evaluating thread)~%") nil)
    #-modus
    (let ((l (funcall (find-symbol "OPEN-LISTENER" "GLASS") :unix :path path)))
      (format t "~&card-control: evaluating forms from ~a (0600, this uid only)~%" path)
      (finish-output)
      (sb-thread:make-thread
       (lambda ()
         (loop
           (handler-case
               (let ((s (funcall (find-symbol "ACCEPT-STREAM" "GLASS") l
                                 :element-type 'character :buffering :full)))
                 (sb-thread:make-thread
                  (lambda () (unwind-protect (ignore-errors (%control-serve-one s))
                               (ignore-errors (close s))))
                  :name "card-control-conn"))
             (error (e) (format t "~&card-control: ~a~%" e) (finish-output) (sleep 1)))))
       :name "card-control"))))
