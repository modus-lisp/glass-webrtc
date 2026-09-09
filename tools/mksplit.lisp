;;;; mksplit.lisp — build the split client with no node, no npm, no esbuild.
;;;;
;;;; The single-page client is tools/mkbundle.lisp; this builds the two-part one from
;;;; index-shell.html + shell.js + payload.js.  See DEPLOY.md.
;;;;
;;;;   sbcl --script tools/mksplit.lisp [out-dir]        (default: $NSITE_BUILD or ./nsite-build)
;;;;
;;;; ==================================================================================
;;;; WHAT COMES OUT, and why there are four artefacts rather than two
;;;; ==================================================================================
;;;;
;;;;   nsite-shell.html   the page published to nsite.  Self-contained: the shell module is
;;;;                      SPLICED IN, replacing the <script src="./shell.js"> placeholder, for
;;;;                      exactly the reason the single-page build does the same -- a published
;;;;                      page that fetches a second file at runtime is a blank screen with
;;;;                      nothing in the log.
;;;;
;;;;   payload.js         what the gateway serves over data channel 104.  PAYLOAD_FILE overrides
;;;;                      where it looks.
;;;;   payload.js.gz      the same, gzipped.  The gateway prefers it when the browser says it can
;;;;                      inflate, and falls back to the raw file otherwise.  COMPRESSION IS DONE
;;;;                      HERE on purpose: the gateway has no deflate in its image, and adding one
;;;;                      to a process supervised by a respawn loop is a much worse trade than
;;;;                      writing a second file at build time.  cram writes it, with MTIME ZERO so
;;;;                      an unchanged payload produces an identical file -- the gateway hashes
;;;;                      what it reads, and a hash that moved because a clock moved would push a
;;;;                      pointless transfer to every phone.
;;;;
;;;;   standalone.html    shell and payload in ONE page, both inline, no data channel involved.
;;;;                      The escape hatch: if the payload channel is ever the problem, publishing
;;;;                      this puts you where the single-page client was, from the same sources,
;;;;                      with no second copy of the client to keep in step.
;;;;
;;;; ==================================================================================
;;;; THE INLINE ENTRY IS A WRAPPER, AND ITS MISSING `await` IS DELIBERATE
;;;; ==================================================================================
;;;;
;;;; standalone.html bundles a wrapper -- `import { init } from './payload.js'; init(...)` --
;;;; rather than appending a call to the payload bundle.  That is not an extra step for its own
;;;; sake: every module in the output is wrapped in its own factory function, so `init` is not in
;;;; scope in the emitted code and an appended call would fail with "init is not defined" at load,
;;;; on the page that exists to be the safe fallback.  Importing it by name makes the bundler
;;;; resolve it.
;;;;
;;;; The python version wrote `await init(...)`.  This one does not, because the bundler REFUSES
;;;; top-level await (a factory function cannot contain one) and nothing follows the call, so the
;;;; await bought nothing but a rejection path.  Errors from init still surface as an unhandled
;;;; rejection in the console, which is where a standalone escape hatch reports them anyway.

(require :asdf)
(let ((here (directory-namestring *load-truename*)))
  (push (truename (merge-pathnames "../" here)) asdf:*central-registry*)
  (dolist (c (list (merge-pathnames "../../shuttle/" here) (merge-pathnames "../shuttle/" here)
                   (merge-pathnames "../../cram/" here)    (merge-pathnames "../cram/" here)))
    (when (probe-file c) (push (truename c) asdf:*central-registry*))))

(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "shuttle/bundle")
    (asdf:load-system "cram")))

(in-package #:shuttle)

(defparameter *repo*
  (namestring (truename (merge-pathnames "../" (directory-namestring *load-truename*)))))

(defparameter *out-dir*
  (let ((arg (second sb-ext:*posix-argv*))
        (env (sb-ext:posix-getenv "NSITE_BUILD")))
    (let ((d (or arg env (merge-pathnames "nsite-build/" *repo*))))
      (ensure-directories-exist
       (if (char= (char (namestring d) (1- (length (namestring d)))) #\/)
           d (concatenate 'string (namestring d) "/"))))))

(defparameter *esm-sh-prefix* "https://esm.sh/nostr-tools@2.15.0/")
(defparameter *placeholder* "<script type=\"module\" src=\"./shell.js\"></script>")

(defun count-substring (needle haystack)
  (loop with n = 0 with start = 0
        for p = (search needle haystack :start2 start)
        while p do (incf n) (setf start (+ p (length needle)))
        finally (return n)))

(defun replace-all (s from to)
  (loop for p = (search from s) while p
        do (setf s (concatenate 'string (subseq s 0 p) to (subseq s (+ p (length from))))))
  s)

(defun bundle-source (text name)
  "Bundle one module's TEXT.  The entry is written into the REPO ROOT so its own `./novnc/...`
imports and the bare specifiers under vendor/ both resolve from where the real sources sit."
  (let ((entry (merge-pathnames (format nil ".mksplit-~a.mjs" name) *repo*)))
    (with-open-file (s entry :direction :output :if-exists :supersede :external-format :utf-8)
      (write-string (replace-all text *esm-sh-prefix* "nostr-tools/") s))
    (unwind-protect
         (handler-case (bundle entry :id-root (pathname *repo*))
           (bundle-error (e)
             (format *error-output* "~&bundling ~a failed: ~a~%" name (bundle-error-text e))
             (sb-ext:exit :code 1)))
      (ignore-errors (delete-file entry)))))

(defun write-text (name text)
  (let ((path (merge-pathnames name *out-dir*)))
    (with-open-file (s path :direction :output :if-exists :supersede :external-format :utf-8)
      (write-string text s))
    path))

(defun splice (page replacement)
  (let ((at (search *placeholder* page)))
    (unless at
      (format *error-output* "~&index-shell.html: no <script src=\"./shell.js\"> placeholder~%")
      (sb-ext:exit :code 1))
    (concatenate 'string (subseq page 0 at) replacement
                 (subseq page (+ at (length *placeholder*))))))

(let* ((page (slurp-file (merge-pathnames "index-shell.html" *repo*)))
       (shell-js (bundle-source (slurp-file (merge-pathnames "shell.js" *repo*)) "shell"))
       (payload-js (bundle-source (slurp-file (merge-pathnames "payload.js" *repo*)) "payload"))
       (inline-js (bundle-source
                   (format nil "import { init } from './payload.js';~%init(window.__glass);~%")
                   "inline"))
       (shell-page (splice page (format nil "<script type=\"module\">~%~a~%</script>" shell-js)))
       (standalone (splice page
                           (format nil "<script>window.__glassPayloadInline = true;</script>~%~
                                        <script type=\"module\">~%~a~%</script>~%~
                                        <script type=\"module\">~%~a~%</script>"
                                   shell-js inline-js)))
       ;; UTF-8, not char-code: the client's own prose contains em dashes, and the browser
       ;; decodes what the gateway sends as UTF-8.  CHAR-CODE would either overflow a byte or
       ;; silently emit latin-1 for anything above U+00FF.
       (raw (sb-ext:string-to-octets payload-js :external-format :utf-8))
       (gz (cram:gzip-compress raw)))
  (write-text "nsite-shell.html" shell-page)
  (write-text "payload.js" payload-js)
  (with-open-file (s (merge-pathnames "payload.js.gz" *out-dir*)
                     :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
    (write-sequence gz s))
  (write-text "standalone.html" standalone)

  (format t "~&nsite-shell.html: ~d  (shell bundle ~d)~%" (length shell-page) (length shell-js))
  (format t "payload.js:       ~d~%" (length raw))
  (format t "payload.js.gz:    ~d  (~,0f% of raw)~%" (length gz)
          (* 100.0 (/ (length gz) (max 1 (length raw)))))
  (format t "standalone.html:  ~d~%" (length standalone))
  (format t "-> ~a~%" *out-dir*)

  ;; A CDN URL surviving into the output means a rewrite was missed and the page would fetch at
  ;; runtime -- the thing bundling exists to prevent.  Same self-check the python build printed,
  ;; and it means the same thing: non-zero is a failed build.
  (let ((leftover (+ (count-substring "esm.sh" shell-page) (count-substring "esm.sh" payload-js))))
    (format t "leftover esm.sh: ~d~%" leftover)
    (when (plusp leftover) (sb-ext:exit :code 1))))
