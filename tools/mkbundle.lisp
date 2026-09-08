;;;; mkbundle.lisp — build the phone client with no node, no npm, no esbuild.
;;;;
;;;; ==================================================================================
;;;; WHAT THIS REPLACES
;;;; ==================================================================================
;;;;
;;;; mkbundle.py extracted index-nostr.html's module, ran it through ESBUILD, and spliced the
;;;; result back.  That needed a node binary and an npm-installed node_modules holding several
;;;; hundred megabytes, to build the client for a system whose display layer is meant to run on
;;;; bare metal.
;;;;
;;;; This does the same three steps with shuttle: shuttle parses the module graph, resolves it
;;;; against vendor/ (committed, no package manager), and prints one script.  The dependencies
;;;; are checked in by tools/vendor-js.sh; nothing is fetched at build time.
;;;;
;;;;   sbcl --script tools/mkbundle.lisp [out.html]
;;;;
;;;; NOT MINIFIED, deliberately.  esbuild's --minify took the shell from 109 KB to ~36 KB over
;;;; the wire; this emits every byte.  Correctness first: a minifier is a second implementation
;;;; of the language's semantics, and the point of the exercise was to stop trusting one we do
;;;; not own.  The size is a known, stated cost, not an oversight.

(require :asdf)
(let ((here (directory-namestring *load-truename*)))
  (push (truename (merge-pathnames "../" here)) asdf:*central-registry*)
  ;; shuttle lives beside this repo in the usual checkout
  (dolist (c (list (merge-pathnames "../../shuttle/" here)
                   (merge-pathnames "../shuttle/" here)))
    (when (probe-file c) (push (truename c) asdf:*central-registry*))))

(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "shuttle/bundle")))

(in-package #:shuttle)

(defparameter *repo*
  (namestring (truename (merge-pathnames "../" (directory-namestring *load-truename*)))))

(defparameter *esm-sh-prefix* "https://esm.sh/nostr-tools@2.15.0/"
  "The source imports nostr-tools from a CDN so the page runs unbundled during development.
The bundler resolves BARE specifiers against vendor/, so the prefix is dropped here -- the same
rewrite mkbundle.py did, for the same reason.")

(defun replace-all (s from to)
  (loop for p = (search from s) while p
        do (setf s (concatenate 'string (subseq s 0 p) to (subseq s (+ p (length from))))))
  s)

(let* ((src-path (merge-pathnames "index-nostr.html" *repo*))
       (html (slurp-file src-path))
       (open "<script type=\"module\">")
       (a (search open html))
       (b (and a (search "</script>" html :start2 a))))
  (unless (and a b)
    (format *error-output* "~&no <script type=\"module\"> in ~a~%" src-path)
    (sb-ext:exit :code 1))
  (let* ((module-src (replace-all (subseq html (+ a (length open)) b) *esm-sh-prefix* "nostr-tools/"))
         ;; The entry lives in the REPO ROOT so its own `./novnc/...` imports and the bare
         ;; specifiers under vendor/ both resolve from where the real file sits.
         (entry (merge-pathnames ".mkbundle-entry.mjs" *repo*))
         (out-path (or (second sb-ext:*posix-argv*)
                       (namestring (merge-pathnames "nsite-index.html" *repo*)))))
    (with-open-file (s entry :direction :output :if-exists :supersede :external-format :utf-8)
      (write-string module-src s))
    (unwind-protect
         (let ((bundle (handler-case (bundle entry :id-root (pathname *repo*))
                         (bundle-error (e)
                           (format *error-output* "~&bundle failed: ~a~%" (bundle-error-text e))
                           (sb-ext:exit :code 1)))))
           (with-open-file (s out-path :direction :output :if-exists :supersede
                                       :external-format :utf-8)
             (write-string (subseq html 0 a) s)
             (write-string open s) (terpri s)
             (write-string bundle s)
             (write-string (subseq html b) s))
           (format t "~&module: ~a bytes | bundle: ~a bytes | ~a~%"
                   (length module-src) (length bundle) out-path)
           ;; A CDN URL left in the output means a rewrite was missed and the page would fetch at
           ;; runtime -- the exact thing bundling exists to prevent.
           (let ((leftover (search "esm.sh" bundle)))
             (when leftover
               (format *error-output* "~&WARNING: esm.sh survives in the output~%")
               (sb-ext:exit :code 1))))
      (ignore-errors (delete-file entry)))))
