;;;; card-site.lisp -- CARD_SITE=1: the card publishes its own client page, as the McCLIM desktop did.
;;;;
;;;;   CARD_ONE_PROCESS=1 CARD_CONTROL=1 CARD_SITE=1 card.sh TAG ...
;;;;   SITE_VERSION=k52 CARD_DIR=... CARD_TAG=TAG sbcl --script glass-webrtc/publish.lisp nsite-index.html
;;;;     (or: hosted-card/card-eval $CARD_DIR/TAG.control '(glass:publish-site-file "/path/nsite-index.html" :version "k52")')
;;;;
;;;; A login link is a token AND a URL, and glass/src/site.lisp says why both must come from the image
;;;; that mints the link: a URL carried in from a launcher's environment is a URL that freezes.  The
;;;; card mints links, so with CARD_SITE=1 it loads :glass/site, which
;;;;   - reads ~/.glass/site-url (the memo of the last publish) and makes it the link base -- AFTER
;;;;     card-gateway.lisp has applied $GLASS_LOGIN_URL_BASE, because the memo outranks a launcher's
;;;;     guess (CARD-SITE-INSTALL-MEMO);
;;;;   - and lets a publish asked for over the control socket (CARD_CONTROL=1, one process) set the
;;;;     link base in the same call that published the manifest.
;;;;
;;;; OFF BY DEFAULT, and the reason is the one site.lisp's header gives under "THE GATEWAY MUST NOT GET
;;;; THIS": on the card the gateway and the desktop are one internet-facing process.  The site key is
;;;; read from ~/.glass/site-key ($GLASS_SITE_KEY) per publish, into gossamer memory, and wiped when
;;;; the publish returns; it is never in this process otherwise.  card.sh does not pass
;;;; $GLASS_SITE_SEC / $SITE_SEC on to the card: an environment variable lives for the whole process,
;;;; is readable at /proc/PID/environ, and is inherited by every shell a terminal on the card starts.
;;;;
;;;; *CARD-SITE* is what publish.lisp's request checks before it publishes, so a card started
;;;; without CARD_SITE=1 answers "not publishing" instead of loading the system on demand.  That is a
;;;; guard against a mistake, not a security boundary: the control socket evaluates anything its
;;;; (same-uid) peer sends.

(defvar *card-site* nil
  "True when this card was started with CARD_SITE=1: it publishes its own client and mints links to
what it published.")

(defun load-card-site ()
  "With CARD_SITE=1, load :glass/site (which installs the published-URL memo as it loads) and say so.
Returns *CARD-SITE*."
  (when (equal (sb-ext:posix-getenv "CARD_SITE") "1")
    (asdf:load-system "glass/site")
    (setf *card-site* t)
    (format t "~&card-site: publishing on (CARD_SITE=1); site key ~a, read per publish~%"
            (symbol-value (find-symbol "*SITE-KEY-FILE*" "GLASS")))
    (unless (and (equal (sb-ext:posix-getenv "CARD_ONE_PROCESS") "1")
                 (equal (sb-ext:posix-getenv "CARD_CONTROL") "1"))
      (format t "~&card-site: no control socket (needs CARD_ONE_PROCESS=1 CARD_CONTROL=1), so ~
                 nothing can ask this card to publish; it still mints links to the last publish~%"))
    (finish-output))
  *card-site*)

(defun card-site-install-memo ()
  "Make the last published URL the link base again, over whatever the launcher's environment set.
Call it AFTER the environment has been applied.  Returns the URL, or NIL (link base untouched)."
  (when *card-site*
    (let ((url (funcall (find-symbol "LOAD-SITE-URL" "GLASS"))))
      (format t "~&card-site: link base ~:[left as the launcher set it (nothing published yet)~;~:*~a (the last publish)~]~%"
              url)
      (finish-output)
      url)))
