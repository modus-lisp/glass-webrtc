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
;;;; A connection is a little REPL: each complete form it sends is evaluated in its package (CL-USER
;;;; to start; an IN-PACKAGE sticks), and the answer is what a Lisp window would print -- output,
;;;; then each value on a line of its own (or "; No values"), an error as "; <type>: <message>" --
;;;; then a line "--", so a client knows the answer is complete.  End of input ends it.
;;;;
;;;; TWO THREADS, BECAUSE OF MODUS.  On modus only the main thread evaluates, and threads share
;;;; nothing.  So the socket has a thread of its own that only moves TEXT: it accepts a connection,
;;;; reads until it holds a complete form, posts the text to a mailbox and waits for the printed
;;;; answer.  The evaluating happens in CONTROL-TURN, which whoever owns evaluation calls: on modus
;;;; the gateway's relay pump, between relay reads (exactly as the Lisp window is served -- so a
;;;; long evaluation holds the gateway up until it returns); on SBCL a thread that does nothing
;;;; else.  ONE path on both, so the one used every day is the one modus runs.  Strings cross by
;;;; GLASS::%SHARE in GLASS::MB-POST.  Connections are served one at a time: modus never frees a
;;;; thread slot, so a thread per connection would leak one per CARD-EVAL.

(defvar *control-requests* nil "Mailbox: (TEXT PACKAGE REPLY-MAILBOX), from the socket thread.")

(defun %mb () (funcall (find-symbol "MAKE-RFB-MAILBOX" "GLASS")))
(defun %mb-post (mb msg) (funcall (find-symbol "MB-POST" "GLASS") mb msg))
(defun %mb-take (mb) (funcall (find-symbol "MB-TAKE" "GLASS") mb))
(defun %share (x) (funcall (find-symbol "%SHARE" "GLASS") x))

(defun %form-complete-p (text)
  "T when TEXT holds at least one whole top-level form and ends between forms: parentheses
balanced, outside a string, a |symbol| and a #| comment |#.  A scanner, not the reader -- this
runs on the socket thread, which on modus must not intern anything."
  (let ((depth 0) (seen nil) (i 0) (n (length text)))
    (loop while (< i n) do
      (let ((c (char text i)))
        (case c
          (#\; (loop while (and (< i n) (char/= (char text i) #\Newline)) do (incf i)))
          (#\" (incf i) (loop while (and (< i n) (char/= (char text i) #\"))
                              do (when (char= (char text i) #\\) (incf i)) (incf i))
               (setf seen t))
          (#\| (incf i) (loop while (and (< i n) (char/= (char text i) #\|))
                              do (when (char= (char text i) #\\) (incf i)) (incf i)))
          (#\\ (incf i) (setf seen t))
          (#\# (if (and (< (1+ i) n) (char= (char text (1+ i)) #\|))
                   (let ((nest 1)) (incf i 2)
                     (loop while (and (< (1+ i) n) (plusp nest)) do
                       (cond ((and (char= (char text i) #\|) (char= (char text (1+ i)) #\#)) (decf nest) (incf i 2))
                             ((and (char= (char text i) #\#) (char= (char text (1+ i)) #\|)) (incf nest) (incf i 2))
                             (t (incf i))))
                     (decf i))
                   (setf seen t)))
          (#\( (incf depth) (setf seen t))
          (#\) (decf depth))
          ((#\Space #\Tab #\Newline #\Return))
          (t (setf seen t))))
      (incf i))
    (and seen (<= depth 0))))

(defun control-turn ()
  "Evaluate what the control socket has sent so far, without waiting.  Call it from the thread
that may evaluate (on modus, the main one)."
  (when *control-requests*
    (dolist (m (%mb-take *control-requests*))
      (destructuring-bind (text package reply) m
        (let* ((out (make-string-output-stream))
               (eval-fn (and (find-package "GLASS-REPL") (find-symbol "EVALUATE-TEXT" "GLASS-REPL")))
               (pkg (if (and eval-fn (fboundp eval-fn))
                        (handler-case (funcall eval-fn text package out)
                          (serious-condition (e) (format out "~&; control: ~a~%" e) package))
                        (progn (format out "~&; control: no evaluator (glass-repl is not loaded)~%")
                               package))))
          (%mb-post reply (list (get-output-stream-string out) (or pkg package))))))))

(defun %control-serve-one (stream)
  (let ((reply (%share (%mb))) (package "COMMON-LISP-USER") (held ""))
    (loop
      (let ((line (read-line stream nil nil)))
        (unless line
          (return))
        (setf held (concatenate 'string held line (string #\Newline)))
        (when (%form-complete-p held)
          (%mb-post *control-requests* (list held package reply))
          (setf held "")
          (loop
            (let ((got (first (%mb-take reply))))
              (when got
                (destructuring-bind (printed pkg) got
                  (setf package pkg)
                  (write-string printed stream)
                  ;; not FRESH-LINE: modus's socket stream does not track the column after
                  ;; WRITE-STRING, so it would always add one
                  (unless (or (zerop (length printed))
                              (char= (char printed (1- (length printed))) #\Newline))
                    (terpri stream))
                  (format stream "--~%")
                  (finish-output stream))
                (return)))
            (sleep 0.005)))))))

(defun start-card-control (&optional (path (sb-ext:posix-getenv "CARD_CONTROL_PATH")))
  "The control socket at PATH, when CARD_CONTROL=1 put one there.  Returns T when it is up; then
CONTROL-TURN must be called by the thread that evaluates (on SBCL this starts one that does)."
  (when (and path (plusp (length path)) (equal (sb-ext:posix-getenv "CARD_CONTROL") "1"))
    (setf *control-requests* (%share (%mb)))
    (let ((l (funcall (find-symbol "OPEN-LISTENER" "GLASS") :unix :path path)))
      (format t "~&card-control: evaluating forms from ~a (0600, this uid only)~%" path)
      (finish-output)
      (sb-thread:make-thread
       (lambda ()
         (loop
           (handler-case
               (let ((s (funcall (find-symbol "ACCEPT-STREAM" "GLASS") l
                                 :element-type 'character :buffering :full)))
                 (unwind-protect (ignore-errors (%control-serve-one s))
                   (ignore-errors (close s))))
             (error (e) (format t "~&card-control: ~a~%" e) (finish-output) (sleep 1)))))
       :name "card-control")
      #-modus
      (sb-thread:make-thread (lambda () (loop (control-turn) (sleep 0.005)))
                             :name "card-control-eval")
      t)))
