;;;; glass-webrtc.asd — the gateway that puts glass in a browser.

(asdf:defsystem "glass-webrtc"
  :description "glass over WebRTC: hunchentoot serves noVNC and one POST /signal for the
SDP exchange, webrtc-data answers (ICE-lite -> DTLS -> SCTP), and when the data channel
opens the gateway pumps RFB bytes to glass in both directions.  Transparent to RFB —
noVNC is the client and glass is the server; the gateway only carries.

Was demo/glass-webrtc inside webrtc-data, where it accounted for 124 of that repo's 147
commits.  A demo that is most of a repository's history and the only way a phone reaches
the desktop is not a demo, and being a subdirectory meant everything reached it by
absolute path — six of them in kiln alone, and one in glass pointing at another
machine's home directory."
  :version "0.0.1"
  :author "ynniv"
  :license "MIT"
  ;; hunchentoot is quicklisp's; the rest are siblings.  These used to be quickloaded
  ;; from inside gateway.lisp at load time, which works for a script and is invisible to
  ;; anything that wants to know what this depends on.
  ;; webrtc-media for the VP8 encoder the video ladder drives — an undeclared
  ;; dependency until now, because a subdirectory loaded by path declares nothing.
  :depends-on ("webrtc-data" "webrtc-media" "glass" "hunchentoot")
  :serial t
  :components ((:file "video-profiles")
               (:file "gateway")))

;;; The nostr-signalled half: the same gateway reached over relays instead of a local
;;; port.  Separate because it pulls in glass/nostr and cl-nostr, and a LAN gateway
;;; should not have to.
(asdf:defsystem "glass-webrtc/nostr"
  :description "The gateway, signalled over nostr: gift-wrapped SDP over relays instead
of a POST, so a browser reaches the desktop without a reachable address."
  :depends-on ("glass-webrtc" "glass/nostr" "cl-nostr")
  :serial t
  :components ((:file "glass-capture")
               (:file "gateway-nostr")))
