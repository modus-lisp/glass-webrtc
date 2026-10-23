;;;; lean-feature.lisp — first component of GLASS-WEBRTC/NOSTR-LEAN: tells gateway-nostr, at
;;;; read time, not to load the media systems it would otherwise ASDF-load itself.
(pushnew :glass-webrtc-lean *features*)
;; Read AT RUN TIME (WEBRTC-DATA::%LEAN-P), never as #+/#-: both nostr systems compile the same
;; gateway-nostr.lisp, so a reader conditional would bake whichever was compiled first into the
;; one fasl the other then reuses.
