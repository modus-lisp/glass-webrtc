;;;; media-hooks.lisp — the gateway's optional halves, reached by NAME at run time.
;;;;
;;;; The nostr gateway carries RFB over the data channel, and on a desktop it also sends audio
;;;; (webrtc-media/rtc, glass/audio-stream, glass/mic-stream) and VP8 video (webrtc-media, vp8,
;;;; glass-capture).  A gateway on a Pi Zero carries only the RFB: the media stack is most of the
;;;; code, the encoder is far too heavy for the board, and reel's decoders do not even load there.
;;;; So gateway-nostr and video-profiles name those packages only through these, and a build
;;;; without them (GLASS-WEBRTC/NOSTR-LEAN) reads and runs without the packages existing.
;;;; With them loaded nothing changes: the same functions are called with the same arguments.

(in-package #:webrtc-data)

(defun %opt-sym (pkg name)
  "The symbol NAME of package PKG, or NIL when the package (or the symbol) is not there."
  (let ((p (find-package pkg)))
    (and p (find-symbol name p))))

(defun %opt-call (pkg name &rest args)
  "Call PKG::NAME with ARGS; an error when it is not loaded (callers already guard with
IGNORE-ERRORS or %MEDIA-P)."
  (let ((s (%opt-sym pkg name)))
    (if (and s (fboundp s))
        (apply (symbol-function s) args)
        (error "~a::~a is not loaded" pkg name))))

(defun %opt-val (pkg name &optional default)
  "The value of special PKG::NAME, or DEFAULT when it is not there."
  (let ((s (%opt-sym pkg name)))
    (if (and s (boundp s)) (symbol-value s) default)))

(defun %set-opt-val (pkg name value)
  "Set special PKG::NAME to VALUE when it exists; VALUE either way."
  (let ((s (%opt-sym pkg name)))
    (when (and s (boundp s)) (setf (symbol-value s) value))
    value))

(defun %lean-p ()
  "Was this gateway loaded as GLASS-WEBRTC/NOSTR-LEAN (lean-feature.lisp)?  A run-time test: both
systems compile the same files, so it cannot be a reader conditional."
  (and (member :glass-webrtc-lean *features*) t))

(defun %media-p ()
  "Is the audio/video half of the gateway loaded?"
  (and (%opt-sym "WEBRTC-MEDIA" "START-AUDIO")
       (fboundp (%opt-sym "WEBRTC-MEDIA" "START-AUDIO"))))
