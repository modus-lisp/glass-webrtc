;;;; login-link.lisp — DM a one-time glass login link to a Nostr identity.
;;;;
;;;;   NOSTR_SEC=<box 64-hex> sbcl --script login-link.lisp <npub | hex | name@domain> [ttl-seconds]
;;;;
;;;; Mints a one-time code (login-token.lisp), builds the nsite URL with the box npub +
;;;; code in the #hash fragment, and gift-wraps it as a NIP-17 DM to the target.  Only
;;;; that npub can decrypt the DM, so receiving the code is the login — no browser signer
;;;; is needed.  The gateway (same box secret) verifies the code and answers.  Override the
;;;; hosting nsite with NSITE_NPUB, the relays with NOSTR_RELAYS.

(require :asdf)
(require :sb-bsd-sockets)
;; WHERE QUICKLISP IS.  ~/quicklisp is one machine's answer, not the answer: in a
;; container image it is /opt/quicklisp, system-wide, because the desktop runs as a
;; user who does not own a home directory worth installing into.  Hardcoding the home
;; path means this script -- the one that MINTS the credential you need to get in --
;; is the one that cannot run on the box it mints for.  QUICKLISP_SETUP overrides;
;; otherwise try the system location, then the user's.  Already loaded (running from a
;; saved core) means there is nothing to do at all.
(let ((here (or *load-pathname* *default-pathname-defaults*)))
  (unless (find-package :quicklisp)
    (let ((setup (find-if #'probe-file
                          (remove nil
                                  (list (let ((e (uiop:getenv "QUICKLISP_SETUP")))
                                          (and e (pathname e)))
                                        #p"/opt/quicklisp/setup.lisp"
                                        (merge-pathnames "quicklisp/setup.lisp"
                                                         (user-homedir-pathname)))))))
      (unless setup
        (format *error-output* "~&login-link: no Quicklisp (tried QUICKLISP_SETUP, ~
                                /opt/quicklisp, ~~/quicklisp).~%")
        (sb-ext:exit :code 1))
      (load setup)))
  (handler-bind ((warning #'muffle-warning))
    (let ((*standard-output* (make-broadcast-stream)))
      (funcall (read-from-string "ql:quickload") '(:cl-nostr :ironclad))))
  (load (merge-pathnames "login-token.lisp" here)))

(defpackage #:login-link-cli (:use #:cl))
(in-package #:login-link-cli)

;; REQUIRED, and for a sharper reason here than in the gateway: this script MINTS credentials.
;; With the old committed fallback it would cheerfully issue a link signed by a secret anyone can
;; read — a link that looks exactly like a real one and admits anybody who copies it.  A minter
;; with no key must fail, never improvise.  See gateway-nostr.lisp's note.
(defparameter *box-secret*
  (let ((s (uiop:getenv "NOSTR_SEC")))
    (unless (and s (= (length s) 64) (every (lambda (c) (digit-char-p c 16)) s))
      (format *error-output*
              "~&login-link: NOSTR_SEC unset or not 64 hex chars — refusing to mint a link.~@
                 ~&  Use the same secret the gateway runs on (gw-keepalive.sh), or the code will~@
                 ~&  not verify:  NOSTR_SEC=$(...) sbcl --script login-link.lisp <npub|email>~%")
      (finish-output *error-output*)
      (sb-ext:exit :code 2))
    s))
(defparameter *site*
  (or (uiop:getenv "NSITE_NPUB")
      "npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc"))
(defparameter *relays*
  (let ((e (uiop:getenv "NOSTR_RELAYS")))
    (if e (remove "" (uiop:split-string e :separator ",") :test #'string=)
        '("wss://relay.damus.io" "wss://nos.lol" "wss://relay.primal.net"))))

(defun target->hex (s)
  "npub / 64-hex / name@domain -> 64-hex pubkey."
  (cond ((cl-nostr.nip05:nip05-address-p s) (cl-nostr.nip05:resolve-pubkey s))
        ((and (>= (length s) 4) (string-equal (subseq s 0 4) "npub"))
         (cl-nostr.util:bytes->hex (cl-nostr.bech32:npub-decode s)))
        (t (string-downcase s))))

(defun %ctl-ask (path form)
  "Evaluate FORM on a desktop's control socket and return the reply line, or NIL."
  (ignore-errors
   (let ((sock (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
     (unwind-protect
          (progn
            (sb-bsd-sockets:socket-connect sock (namestring path))
            (let ((s (sb-bsd-sockets:socket-make-stream sock :input t :output t
                                                             :element-type 'character)))
              (write-string form s) (terpri s) (finish-output s)
              (read-line s nil nil)))
       (ignore-errors (sb-bsd-sockets:socket-close sock))))))

(defun %desktop-name (pubkey-hex)
  "What the desktop with this key WRITES IN ITS LOWER-LEFT CORNER, or NIL.

NOT DERIVED.  A session's name defaults to BIP-39 words computed from its key, and that is only the
DEFAULT -- kiln takes --resume=<name> and the sessions on this box include one called `cortez'.  So
a computed name is a guess that is right until somebody names a desktop, and a DM that confidently
names the wrong desktop is worse than one that names none.

ASKED, THEN LOOKED UP, AND NEVER GUESSED:

  the live desktop, over its control socket, which is the value GLASS:*DESKTOP-NAME* holds and
  therefore literally the string WM-DRAW-SESSION-NAME paints on the screen;
  failing that, the session store, whose DIRECTORY NAME is what kiln resumed and handed to that
  variable at boot;
  failing that, NIL, and the DM says what it always said.

The socket is matched by KEY, not by display number: several desktops can be up, and the link is
for exactly one of them."
  (let ((want (string-downcase pubkey-hex)))
    (or
     ;; 1. ask whoever is running
     (dolist (ctl (ignore-errors
                   (directory (merge-pathnames ".glass/run/*.control" (user-homedir-pathname)))))
       (let* ((r (%ctl-ask ctl
                           "(let ((s (find-symbol \"*KILN-SESSION-SEC*\" \"CL-USER\")))
                              (list glass:*desktop-name*
                                    (and s (boundp s)
                                         (cl-nostr.keys:public-hex
                                          (cl-nostr.keys:keypair-from-secret (symbol-value s))))))"))
              (got (and r (ignore-errors (read-from-string r)))))
         (when (and (consp got) (stringp (first got)) (stringp (second got))
                    (string-equal want (second got)))
           (return (first got)))))
     ;; 2. the store: a directory per session, named the way the desktop will be
     (dolist (dir (ignore-errors
                   (directory (merge-pathnames ".kiln/sessions/*/" (user-homedir-pathname)))))
       (let* ((nsec (merge-pathnames "nsec" dir))
              (sec (and (probe-file nsec)
                        (string-trim '(#\Space #\Newline #\Return #\Tab)
                                     (uiop:read-file-string nsec))))
              (hex (and sec (plusp (length sec))
                        (ignore-errors
                         (cl-nostr.keys:public-hex
                          (cl-nostr.keys:keypair-from-secret sec))))))
         (when (and hex (string-equal want hex))
           (return (car (last (pathname-directory dir))))))))))

(let* ((arg (second sb-ext:*posix-argv*))
       ;; 600 s, matching GLASS:*LOGIN-TTL* — a LINK is a credential in transit and its TTL is the
       ;; only bound on a leaked one.  These used to disagree (900 here, 1800 there) with nothing
       ;; saying which was meant.  Still overridable as the second argument.
       (ttl (or (ignore-errors (parse-integer (or (third sb-ext:*posix-argv*) ""))) 600)))
  (unless arg
    (format *error-output* "usage: login-link <npub | 64-hex | name@domain> [ttl-seconds]~%")
    (sb-ext:exit :code 1))
(handler-case
      (let* ((target (or (target->hex arg) (error "could not resolve ~a to a pubkey" arg)))
             (box-kp (cl-nostr.keys:keypair-from-secret *box-secret*))
             (box-npub (cl-nostr.bech32:npub-encode (cl-nostr.keys:public-hex box-kp)))
             (token (glass-login:mint-token *box-secret* :ttl ttl))
             ;; LOGIN_URL_BASE overrides the page location (e.g. a Blossom blob URL while an
             ;; nsite gateway's cache catches up); default is the nsite site URL.
             (base (or (uiop:getenv "LOGIN_URL_BASE")
                       (format nil "https://~a.nsite.lol/" *site*)))
             (url (format nil "~a#box=~a&code=~a" base box-npub token))
             ;; WHICH DESKTOP.  A link on its own says "a glass desktop"; with several running,
             ;; the one thing the reader needs is which -- and it must be the name ON THE SCREEN,
             ;; not a name computed from the key.  See %DESKTOP-NAME.
             (session-name (%desktop-name (cl-nostr.keys:public-hex box-kp)))
             (msg (format nil "Your one-time link to the glass desktop~@[ ~a~] ~
(expires in ~a min):~%~%~a"
                          session-name (max 1 (round ttl 60)) url))
             (wrap (cl-nostr.nip59:build-giftwrap box-kp target msg))
             (pool (cl-nostr.pool:make-pool *relays*)))
        (cl-nostr.pool:pool-publish pool wrap)
        (sleep 2)                                   ; let the relays ack before we exit
        (format t "~&@@ DM'd a one-time login link to ~a…~@[ (desktop ~a)~]~%@@ ~a~%"
                (subseq target 0 8) session-name url))
    (error (e) (format *error-output* "login-link: ~a~%" e) (sb-ext:exit :code 1))))
