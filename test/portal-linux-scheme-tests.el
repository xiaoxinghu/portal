;;; portal-linux-scheme-tests.el --- Terminals following the desktop's light or dark -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A terminal with a pair of themes shows the first while the desktop is
;; light and the second while it is dark, and switches as the desktop does.
;; The module hears the desktop's preference from the XDG desktop portal,
;; on the session bus.  Here this Emacs plays that portal, on a bus of its
;; own, which test/linux-gui.sh starts with dbus-run-session: the desktop
;; you work on is never asked to change, and its portal is not there to
;; answer.  Loaded after test/portal-linux-gui-tests.el and
;; test/portal-linux-terminal-tests.el, whose helpers these use.
;;
;; The light theme is Great Pumpkin, the flat orange of the terminals'
;; tests, and the dark one Dracula, whose background is #282a36.

(require 'ert)
(require 'dbus)
(require 'portal-terminal)
(require 'portal-linux-gui-tests)
(require 'portal-linux-terminal-tests)

(defconst portal-linux-scheme--pair '("Great Pumpkin" . "Dracula"))

(defun portal-linux-scheme--dracula-p (color)
  "Whether COLOR, (RED GREEN BLUE), is Dracula's background, #282a36."
  (pcase-let ((`(,red ,green ,blue) color))
    (and (< (abs (- red #x28)) 12) (< (abs (- green #x2a)) 12) (< (abs (- blue #x36)) 12))))

(defun portal-linux-scheme--own ()
  "Own the desktop portal's name on the session bus, which must be the test's."
  (should (featurep 'dbusbind))
  (should (eq (dbus-register-service :session "org.freedesktop.portal.Desktop" :do-not-queue)
              :primary-owner)))

(defun portal-linux-scheme--set (dark)
  "Say, as the desktop portal does, that the desktop is now DARK, or light."
  (dbus-send-signal :session nil "/org/freedesktop/portal/desktop"
                    "org.freedesktop.portal.Settings" "SettingChanged"
                    "org.freedesktop.appearance" "color-scheme"
                    (list :variant :uint32 (if dark 1 2))))

(defun portal-linux-scheme--shows (window predicate)
  "Wait until WINDOW's top left corner, Ghostty's padding, satisfies PREDICATE.
PREDICATE takes a color, (RED GREEN BLUE)."
  (let ((deadline (+ (float-time) 10)) seen)
    (while (progn
             (portal-linux-gui--pause 0.2)
             (pcase-let ((`(,left ,top . ,_) (portal-linux-gui--box window)))
               (setq seen (portal-linux-gui--pixel (portal-linux-gui--screen) left top)))
             (and (not (funcall predicate seen)) (< (float-time) deadline))))
    (ert-info ((format "Seen %S" seen))
      (should (funcall predicate seen)))))

(ert-deftest portal-linux-scheme-a-pair-follows-the-desktop ()
  :tags '(:gui)
  (portal-linux-scheme--own)
  (portal-linux-terminal--with
    (setq portal-terminal-theme portal-linux-scheme--pair)
    (let* ((window (selected-window))
           (first (portal-linux-terminal--open "/tmp/"))
           (first-buffer (window-buffer window)))
      (should (equal (portal-linux-gui--get :theme first) "Great Pumpkin"))
      (should (equal (portal-linux-gui--get :dark-theme first) "Dracula"))
      ;; No portal answered when the terminals started: the desktop is light.
      (portal-linux-scheme--shows window #'portal-linux-terminal--orange-p)
      (portal-linux-terminal--run first "echo PORTAL-PAIR-$((6*7))")
      (portal-linux-terminal--shows first "PORTAL-PAIR-42")
      ;; Dark, without restarting its shell.
      (portal-linux-scheme--set t)
      (portal-linux-scheme--shows window #'portal-linux-scheme--dracula-p)
      (portal-linux-terminal--shows first "PORTAL-PAIR-42")
      ;; A new terminal opens in the dark theme, and both turn light again,
      ;; the hidden one too.
      (let ((second (portal-linux-terminal--open "/tmp/")))
        (should-not (eq second first))
        (portal-linux-scheme--shows window #'portal-linux-scheme--dracula-p)
        (portal-linux-scheme--set nil)
        (portal-linux-scheme--shows window #'portal-linux-terminal--orange-p))
      (switch-to-buffer first-buffer)
      (portal-linux-scheme--shows window #'portal-linux-terminal--orange-p)
      ;; A single name stays fixed in both.
      (setq portal-terminal-theme "Dracula")
      (portal-linux-scheme--shows window #'portal-linux-scheme--dracula-p)
      (portal-linux-scheme--set t)
      (portal-linux-gui--pause 0.5)
      (portal-linux-scheme--set nil)
      (portal-linux-gui--pause 0.5)
      (portal-linux-scheme--shows window #'portal-linux-scheme--dracula-p)
      ;; An unknown name in a pair is refused, naming it, and changes nothing.
      (should (equal (cadr (should-error
                            (setq portal-terminal-theme '("Great Pumpkin" . "No such Portal theme"))))
                     "Unknown terminal theme: No such Portal theme"))
      (should (equal (portal-linux-gui--get :theme first) "Dracula")))))

(provide 'portal-linux-scheme-tests)
;;; portal-linux-scheme-tests.el ends here
