;;;; glass-webrtc.asd — the gateway that puts glass in a browser.

(asdf:defsystem "glass-webrtc"
  :description "glass over WebRTC: cl-transport/http-server serves noVNC and one POST /signal for the
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
  ;; All siblings.  The HTTP server was hunchentoot (quicklisp's, and through it cl+ssl ->
  ;; CFFI -> OpenSSL, for a server that never spoke TLS); it is cl-transport/http-server now.
  ;; These used to be quickloaded from inside gateway.lisp at load time, which works for a
  ;; script and is invisible to anything that wants to know what this depends on.
  ;; webrtc-media for the VP8 encoder the video ladder drives — an undeclared
  ;; dependency until now, because a subdirectory loaded by path declares nothing.
  :depends-on ("glass-webrtc/media" "cl-transport/http-server" "bobbin")
  :serial t
  :components ((:file "gateway")))

;;; The media half both gateways share: the audio/video hooks and the VP8 ladder, without the HTTP
;;; server.  Split out so the nostr gateway does not pull in the HTTP server: it never served HTTP,
;;; it only loaded the system that does.  (That server was hunchentoot -> cl+ssl -> CFFI, which modus
;;; does not have; it is cl-transport/http-server now, but the split still keeps the nostr side lean.)
(asdf:defsystem "glass-webrtc/media"
  :description "The gateways' media half: audio/video hooks and the VP8 bandwidth ladder."
  :depends-on ("webrtc-data" "webrtc-media" "glass")
  :serial t
  :components ((:file "media-hooks")
               (:file "video-profiles")))

;;; The nostr-signalled half: the same gateway reached over relays instead of a local
;;; port.  Separate because it pulls in glass/nostr and cl-nostr, and a LAN gateway
;;; should not have to.
(asdf:defsystem "glass-webrtc/nostr"
  :description "The gateway, signalled over nostr: gift-wrapped SDP over relays instead
of a POST, so a browser reaches the desktop without a reachable address."
  :depends-on ("glass-webrtc/media" "glass/nostr" "cl-nostr" "json-simple" "cram")   ; cram: the payload's gzip
  :serial t
  :components ((:file "glass-capture")
               (:file "gateway-nostr")))

;;; The same nostr gateway with ONLY the RFB data channel: no audio, no VP8 video, no HTTP/noVNC
;;; server), none of webrtc-media.  For a board that serves its own desktop -- a Pi Zero --
;;; where the media stack is most of the code and its encoder far too heavy.  Same session,
;;; admission, signalling and channels; see media-hooks.lisp for how the media calls go away.
(asdf:defsystem "glass-webrtc/nostr-lean"
  :description "The nostr gateway, RFB over the data channel only (no audio/video/HTTP)."
  :depends-on ("webrtc-data" "glass/nostr" "cl-nostr" "json-simple" "cram")
  :serial t
  :components ((:file "lean-feature")
               (:file "media-hooks")
               (:file "video-profiles")
               ;; a component here, not gateway-nostr's run-time LOAD by system-relative path:
               ;; a board cannot find the file that way, and the stubs it fell back to answered
               ;; a published shell's payload request with nothing
               (:file "payload-channel")
               (:file "pointer-channel")
               (:file "gateway-nostr")))

;;; The OTHER end: dial a box the way the phone does (shell.js) -- a login code or the device
;;; key it enrolled, a gift-wrapped non-trickle offer over the relays, the answer by its ufrag,
;;; and the desktop's RFB as a byte stream over webrtc-data's calling side.  No glass, no
;;; gateway: a client library, for glass's Remote window and for tests.
(asdf:defsystem "glass-webrtc/dial"
  :description "Dial a glass box over Nostr + WebRTC, as the phone does; RFB as a byte stream."
  :depends-on ("webrtc-data" "cl-nostr" "json-simple" "sb-posix")
  :components ((:file "dial")))
