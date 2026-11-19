(require :asdf)(load "~/quicklisp/setup.lisp")
(handler-bind ((warning #'muffle-warning))(let ((*standard-output*(make-broadcast-stream)))(asdf:load-system :glass/site)))
(defpackage :pub (:use :cl)) (in-package :pub)

;;;; publish.lisp — hand the built page to the box, and let the box publish it.
;;;;
;;;;   SITE_VERSION=k43 sbcl --script publish.lisp [/path/to/nsite-index.html]
;;;;   SITE_VERSION=k43 CARD_DIR=... CARD_TAG=TAG sbcl --script publish.lisp [...]     # a hosted card
;;;;
;;;; THIS FILE USED TO BE THE PUBLISHER.  It is not any more, and the reason is a bug it caused.
;;;;
;;;; A login link is two things joined: a token, minted by the box, and a URL, minted here.  This
;;;; script published a build at a new PATH (/k42.html) and wrote that path into `site-url.env';
;;;; `gw-keepalive.sh' re-sourced that file every loop, so the GATEWAY always had the current one.
;;;; Then the `link' command moved out of the gateway and into the DESKTOP — which has no such loop,
;;;; and takes LOGIN_URL_BASE from its environment once, at exec.  On 2026-08-18 the site served
;;;; /k42.html on nsite.run while the desktop handed out /k27.html on nsite.lol: a tag from weeks
;;;; earlier, on a gateway host that had been stale all week, from a build predating the box-key
;;;; rotation.  Somebody tapped it and could not connect.
;;;;
;;;; The fault was not a value.  It was that PUBLISHING AND MINTING WERE DIFFERENT PROCESSES
;;;; COORDINATING THROUGH A FILE, and a file cannot tell its writer that its reader has stopped
;;;; reading.  So publishing moved into the image that mints — GLASS:PUBLISH-SITE, in glass's
;;;; :glass/site system — where the tag is a variable and there is no handoff to go stale.
;;;;
;;;; WHAT IS LEFT HERE IS THE DECISION OF WHERE TO RUN IT:
;;;;
;;;;   a desktop is running   -> hand it the request over its control socket.  The box publishes,
;;;;                             and the link it will mint one second later is the one it just
;;;;                             published, because the same call set both.
;;;;   no desktop is running  -> publish in THIS process, from the same code, and leave the memo
;;;;                             (~/.glass/site-url) the desktop reads when it next starts.
;;;;
;;;; It decides by CONNECTING.  Not by the socket file existing — a process killed with -9 leaves
;;;; the file behind — and not by a pidfile: connect(2) returning ECONNREFUSED is the kernel
;;;; answering the actual question, and it is the same probe glass's own OPEN-LISTENER uses to
;;;; decide a socket file is stale.
;;;;
;;;; AND THERE IS NO FALLBACK FROM THE FIRST CASE TO THE SECOND.  If the desktop answers but cannot
;;;; publish, this script stops and says so, rather than quietly publishing here — because a
;;;; successful publish by the wrong process is precisely the bug: the site would move and the
;;;; running box would go on minting links to what used to be there.
;;;;
;;;; THE SITE KEY IS NOT IN THIS FILE and never was.  It is read by GLASS:WITH-SITE-SECRET at the
;;;; moment of publishing, from ~/.glass/site-key (0600) or $GLASS_SITE_SEC / $SITE_SEC, straight
;;;; into gossamer memory, in whichever image does the work, and wiped when the publish returns;
;;;; there is no fallback and no committed placeholder, which is what lets this file live in a
;;;; repository at all.
;;;;
;;;; A HOSTED CARD (glass-webrtc/hosted-card) is the other box that mints links.  CARD_DIR + CARD_TAG
;;;; (or CARD_CONTROL_PATH) name its control socket, $CARD_DIR/TAG.control, which exists when the
;;;; card was started with CARD_ONE_PROCESS=1 CARD_CONTROL=1; it publishes only if it was also
;;;; started with CARD_SITE=1 (hosted-card/card-site.lisp).  Two differences from the desktop:
;;;;   - its socket is a little REPL that answers each form with a "--" line and waits for the next,
;;;;     so this half-closes after sending, and the card answers and hangs up;
;;;;   - a card need not HAVE a control socket, so "nobody answered" does not mean "nobody is
;;;;     running".  If $CARD_DIR/TAG.pids names a live process, this refuses to publish locally —
;;;;     the running card would go on minting links to what used to be there.

(defun %trim (s) (string-trim '(#\Space #\Tab #\Newline #\Return) (or s "")))
(defun %env (name) (let ((v (%trim (sb-posix:getenv name)))) (and (plusp (length v)) v)))

;; The built artefact: argv, then $NSITE_BUILD, then a build dir beside this script.  Nothing here
;; is machine-specific, so the file is portable between checkouts.
(defparameter *path*
  (or (second sb-ext:*posix-argv*)
      (%env "NSITE_BUILD")
      (namestring (merge-pathnames "nsite-build/nsite-index.html"
                                   (or *load-truename* *default-pathname-defaults*)))))

;; A VERSIONED PATH, not a ?v= query.  An nsite gateway resolves a request by PATH against the
;; kind-15128 manifest, so a query string selects the same blob and the browser is free to serve its
;; cached copy — which is why ?v= never busted anything.
(defparameter *version* (or (%env "SITE_VERSION") "latest"))

;; The desktop's control socket.  GLASS_CONTROL overrides; otherwise it is derived exactly the way
;; the launcher derives it, from the seat's wire — see GLASS:SOCKET-SIBLING, which exists so that
;; the two ends of this cannot be typed in twice and drift.
(defparameter *card-control*
  (or (%env "CARD_CONTROL_PATH")
      (and (%env "CARD_DIR") (%env "CARD_TAG")
           (format nil "~a/~a.control" (string-right-trim "/" (%env "CARD_DIR")) (%env "CARD_TAG"))))
  "A hosted card's control socket, when the caller named a card; NIL means the McCLIM desktop.")

(defparameter *control*
  (or *card-control*
      (%env "GLASS_CONTROL")
      (glass:socket-sibling (glass:socket-path "seat-0.rfb") "control")))

;; Long, because a publish uploads to three Blossom servers and waits for five relays to answer.
;; The alternative to waiting is guessing, and the whole reason NSITE-PUBLISH waits for each
;; relay's OK is that a websocket swallows a send on a dead socket without a word.
(defparameter *timeout* (or (ignore-errors (parse-integer (or (%env "PUBLISH_TIMEOUT") "300"))) 300))

(unless (probe-file *path*)
  (format *error-output* "~&publish: no such build: ~a~%  Build it first ~
(sbcl --script tools/mksplit.lisp), or~@
                            ~&  pass the path as argv / $NSITE_BUILD.~%" *path*)
  (finish-output *error-output*)
  (sb-ext:exit :code 2))

;;; ---- the running desktop, if there is one ------------------------------------

(defun ask-desktop (form)
  "Send FORM to the desktop's control socket and return everything it says, or NIL if there is no
desktop to ask.  Never signals: `nobody answered' and `it answered badly' are different facts and
only the first one is this function's business."
  (let ((sock nil) (stream nil))
    (handler-case
        (unwind-protect
             (progn
               (multiple-value-setq (sock stream)
                 (glass:open-connection :path *control* :element-type 'character
                                        :timeout *timeout*))
               (let ((*package* (find-package :cl-user)))
                 (write-string (prin1-to-string form) stream))
               (terpri stream)
               (force-output stream)
               ;; A card's socket waits for another form after answering; end of input is what
               ;; makes it hang up.  (The desktop's reads one form and closes on its own.)
               (when *card-control*
                 (sb-bsd-sockets:socket-shutdown sock :direction :output))
               ;; The control socket reads ONE form, evaluates it, writes the printed result and
               ;; closes.  So the answer is "everything until end of stream", which is also what
               ;; makes a multi-line report possible.
               (with-output-to-string (out)
                 (loop for line = (read-line stream nil nil)
                       while line
                       unless (and *card-control* (string= line "--"))  ; the card's end-of-answer
                         do (write-line line out))))
          (ignore-errors (when stream (close stream)))
          (ignore-errors (when sock (sb-bsd-sockets:socket-close sock))))
      (serious-condition () nil))))

;;; The form the desktop evaluates.  It LOADS :glass/site itself rather than assuming the launcher
;;; already did — the symbol is exported by core glass's package definition, so this reads in a
;;; desktop that has never seen site.lisp, and ASDF then puts it there.  That is what makes this
;;; work against the desktop currently running, whose launcher predates all of this.
(defparameter *request*
  (if *card-control*
      ;; A card publishes only if it was started to (CARD_SITE=1): it does not load the system on
      ;; demand, because whether the internet-facing process holds the publisher is the card
      ;; operator's decision, made at start.  (A guard against a mistake, not a boundary — the
      ;; socket evaluates anything.)  PRINC, so the report comes back as text, not a quoted string.
      `(if (and (boundp 'cl-user::*card-site*) (symbol-value 'cl-user::*card-site*))
           (progn (glass:publish-site-file ,(namestring (truename *path*)) :version ,*version*)
                  (princ (glass:site-report))
                  (values))
           "ERROR: this card was not started with CARD_SITE=1 -- not publishing")
      `(progn (asdf:load-system "glass/site")
              (glass:publish-site-file ,(namestring (truename *path*)) :version ,*version*)
              (glass:site-report))))

(defun card-running-p ()
  "With a card named: T if its pids file ($CARD_DIR/TAG.pids, beside the socket) names a live
process.  Then nobody answering means the card has no control socket, not that it is gone."
  (when *card-control*
    (let ((pids (concatenate 'string (subseq *card-control* 0 (- (length *card-control*)
                                                               (length ".control")))
                             ".pids")))
      (with-open-file (s pids :if-does-not-exist nil)
        (and s (loop for pid = (read s nil nil)
                     while pid
                     thereis (and (integerp pid) (plusp pid)
                                  (ignore-errors (zerop (sb-posix:kill pid 0))))))))))

(format t "~&publish: ~a  ->  /~a.html~%" *path* *version*)
(format t "publish: asking the ~:[desktop~;card~] at ~a~%" *card-control* *control*)
(finish-output)

(let ((answer (ask-desktop *request*)))
  (cond
    ;; ---- the desktop published it -------------------------------------------------------------
    (answer
     (format t "~&~a~%" (%trim answer))
     (when (search "ERROR" answer)
       (format *error-output*
               "~&publish: the ~:[desktop~;card~] answered but did not publish.  NOT falling back to~@
                  ~&  publishing here: the site would move and that box would go on minting links~@
                  ~&  to what used to be there — which is the bug this file exists to prevent.~%"
               *card-control*)
       (finish-output *error-output*)
       (sb-ext:exit :code 1))
     (unless (search "link base ->" answer)
       (format *error-output* "~&publish: the link base was NOT moved — see the report above.~%")
       (finish-output *error-output*)
       (sb-ext:exit :code 1))
     (format t "~&publish: the box that minted that link is the box that just published it.~%")
     (finish-output))
    ;; ---- a card that is running but not answering: NOT here either ----------------------------
    ((ignore-errors (card-running-p))
     (format *error-output*
             "~&publish: the card is running but nothing answers on ~a.  NOT publishing here: the~@
                ~&  site would move and that card would go on minting links to what used to be there.~@
                ~&  Restart it with CARD_ONE_PROCESS=1 CARD_CONTROL=1 CARD_SITE=1, or stop it first.~%"
             *control*)
     (finish-output *error-output*)
     (sb-ext:exit :code 1))
    ;; ---- nobody there: do it here -------------------------------------------------------------
    (t
     (format t "~&publish: no ~:[desktop~;card~] on ~a — publishing from this process.~%"
             *card-control* *control*)
     (format t "publish: the memo (~a) is what the desktop will read when it next starts.~%"
             glass:*site-url-file*)
     (finish-output)
     (multiple-value-bind (url publication) (glass:publish-site-file *path* :version *version*)
       ;; :DETAIL NIL — the per-server lines went past on stderr as they happened, and printing
       ;; them a second time is how a deploy log stops being read.
       (format t "~&~a~%" (glass:site-report publication :detail nil))
       (finish-output)
       (unless url (sb-ext:exit :code 1))))))

(sb-ext:exit)
