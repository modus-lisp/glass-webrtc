;;;; card-apps.lisp -- the McCLIM desktop's applications on the card's window manager, when asked for.
;;;;
;;;; The card's desktop is glass's window manager (glass.wm) with its own menu: Clock, the desk's
;;;; apps, a Lisp listener and a Terminal.  The McCLIM desktop (cortez/desktop-5903.lisp) had more,
;;;; each in a system of its own, and glass.wm's root menu offers whichever of them is loaded
;;;; (glass.wm:*WM-OPTIONAL-APPS*).  This file loads the ones CARD_APPS names:
;;;;
;;;;   files     warren, the file browser
;;;;   browser   loom/glass, the web browser
;;;;   podcasts  spool/desk, the podcast client (plays into the desktop's sound)
;;;;   voice     Speak and Listen windows, and "Speak selection" / "Speak clipboard" in the menus:
;;;;             glass/voice-apps over glass/speech (chord, GLASS_VOICE) and glass/hearing (stave,
;;;;             GLASS_EARS), with the phone's microphone taken on the RFB port + 11
;;;;   all       every one of them
;;;;
;;;; Unset, nothing is loaded and the card is what it was -- on the board as everywhere else.
;;;; Each is loaded on its own and a failure costs only that app, with a line saying why.
;;;;
;;;; SOUND.  Podcasts and the voice need the desktop's sound to reach the phone, so either one loads
;;;; glass/wm-sound and CARD-APPS-SOUND-P says to serve it on the RFB port + 10, where the gateway
;;;; listens (gateway-nostr.lisp *AUDIO-PORT*).  The window manager's mixer is then the session's,
;;;; so the voice and the player are heard in the one mix the gateway takes.

(defvar *card-apps* '()
  "The apps CARD_APPS asked for that loaded, as keywords.")

(defun %card-apps-wanted ()
  (let* ((raw (or (sb-ext:posix-getenv "CARD_APPS") ""))
         (names (loop with start = 0
                      for comma = (position #\, raw :start start)
                      for name = (string-trim " " (subseq raw start (or comma (length raw))))
                      unless (string= name "") collect (intern (string-upcase name) :keyword)
                      while comma do (setf start (1+ comma)))))
    (if (member :all names) '(:files :browser :podcasts :voice) names)))

(defun %card-load (what systems)
  "Load SYSTEMS for WHAT; T if every one loaded, else NIL with a line saying which did not."
  (handler-case
      (let ((t0 (get-internal-real-time)))
        (handler-bind ((warning #'muffle-warning))
          (dolist (s systems) (asdf:load-system s)))
        (format t "~&card-apps: ~(~a~) loaded (~,1f s)~%" what
                (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
        t)
    (error (e)
      (format t "~&card-apps: ~(~a~) NOT loaded -- ~a~%" what e)
      nil)))

(defun load-card-apps ()
  "Load what CARD_APPS names.  Returns the list that loaded."
  (setf *card-apps* '())
  (dolist (app (%card-apps-wanted))
    (when (%card-load app (case app
                            (:files '("warren"))
                            (:browser '("loom/glass"))
                            (:podcasts '("spool/desk"))
                            (:voice '("glass/voice-apps" "glass/speech" "glass/hearing" "glass/mic-stream"))
                            (t (format t "~&card-apps: no app called ~(~a~)~%" app) nil)))
      (push app *card-apps*)))
  (when (card-apps-sound-p) (%card-load :sound '("glass/wm-sound")))
  (finish-output)
  (setf *card-apps* (nreverse *card-apps*)))

(defun card-apps-sound-p ()
  "Does a loaded app make sound the phone should hear?"
  (and (intersection *card-apps* '(:podcasts :voice)) t))

(defun card-wm-sound-args (rfb-port)
  "START-WM's sound arguments: the mix served on RFB-PORT + 10, if anything makes sound."
  (and (card-apps-sound-p) (find-package "GLASS.WM")
       (fboundp (find-symbol "WM-SOUND-OPEN" "GLASS.WM"))
       (list :audio-port (+ rfb-port 10))))

(defun start-card-app-services (rfb-port)
  "What the loaded apps need running beside the desktop: the phone's microphone, taken on
RFB-PORT + 11 for the ear (glass/mic-stream; the gateway sends it there, *MIC-PORT*)."
  (when (member :voice *card-apps*)
    (let ((start (find-symbol "START-SESSION-MIC" "GLASS")))
      (when (and start (fboundp start))
        (funcall start :port (+ rfb-port 11))))
    (format t "~&card-apps: voice ~:[none (set GLASS_VOICE)~;~:*~a~], ears ~:[none (set GLASS_EARS)~;~:*~a~]~%"
            (sb-ext:posix-getenv "GLASS_VOICE") (sb-ext:posix-getenv "GLASS_EARS"))
    (finish-output)))
