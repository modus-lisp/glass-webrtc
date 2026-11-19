;;;; card-site-test-card.lisp -- the parts of a card that CARD_SITE touches, and nothing that reaches
;;;; the network: card-site.lisp and card-control.lisp exactly as card-gateway.lisp loads them, with
;;;; the site's relays and Blossom servers pointed at loopback fakes (glass/inspect/site-fakes.lisp).
;;;; Started by card-site-test.sh; not a card anyone should run.
(require :asdf)
(load "~/quicklisp/setup.lisp")          ; CL_SOURCE_REGISTRY, if set, pins which checkouts load
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "glass/nostr")))
(defvar *here* (directory-namestring *load-truename*))
(load (merge-pathnames "card-site.lisp" *here*))
(load-card-site)
;; as card-gateway.lisp: the launcher's link base first, then the memo over it
(setf glass:*login-url-base* (sb-ext:posix-getenv "GLASS_LOGIN_URL_BASE"))
(card-site-install-memo)
;; never the real site key: the test hands us a throwaway file, and we check that we got it
(when *card-site*
  (let ((real (namestring (merge-pathnames ".glass/site-key" (user-homedir-pathname)))))
    (unless (and (equal glass:*site-key-file* (sb-ext:posix-getenv "GLASS_SITE_KEY"))
                 (not (equal glass:*site-key-file* real)))
      (format t "~&fake-card: REFUSING: the site key file is not the test's (~a)~%" glass:*site-key-file*)
      (sb-ext:exit :code 3 :abort t))))
(load (asdf:system-relative-pathname :glass "inspect/site-fakes.lisp"))
(multiple-value-bind (relay blossom) (glass-site-fakes:start-fakes)
  (setf glass:*site-relays* (list relay)
        glass:*site-lookup-relays* '()
        glass:*site-blossom* (list blossom))
  (format t "~&fake-card: site relays ~a, Blossom ~a (loopback)~%" relay blossom))
(load (merge-pathnames "card-control.lisp" *here*))
(start-card-control)
(format t "~&fake-card: ready~%")
(finish-output)
(loop (sleep 3600))
