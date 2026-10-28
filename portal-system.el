;;; portal-system.el --- System-wide actions outside Portal's views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Actions on the system rather than on a Portal view, such as posting a key
;; chord to whatever application is frontmost, or showing a status above
;; every application.  The native module does the work; loading this file
;; does nothing.

(require 'cl-lib)
(require 'portal-view)

(declare-function portal--key-post "portal-system" (chord))
(declare-function portal--status-show "portal-system"
                  (text tone position screen dx dy width height min-width max-width lines))
(declare-function portal--status-hide "portal-system" ())

(defun portal-post-key (chord)
  "Press and release CHORD in the frontmost application.
CHORD is written as for `portal-global-shortcut-set', such as
\"Command-V\", except that its letter or digit names the character the
key types in the current keyboard layout, not a position on a US
keyboard: on a Dvorak layout, \"Command-V\" still pastes.  Exactly
CHORD's modifiers are held with the key, whatever keys the user holds.

The chord goes to whatever application is frontmost, which may be Emacs
itself.  It is only posted: the application handles it after this
returns, or ignores it, as when no text field has focus.

Posting needs Accessibility permission for Emacs.app.  A post without
it makes macOS ask: its alert offers to open System Settings > Privacy
& Security > Device Control and Data Access (Accessibility before macOS
27), where Emacs is now listed, switched off; that post still fails.
Once the switch is on, the next post works without restarting Emacs.
The grant belongs to Emacs's code signature, so a rebuilt Emacs no
longer matches its entry: the switch shows on, yet posts fail and macOS
asks again.  Remove Emacs from that list and add it again.

Return nil.  Signal an error and post nothing if CHORD is invalid, if
no key types its character in the current layout, or if Emacs lacks
Accessibility permission."
  (unless (stringp chord)
    (user-error "A key chord must be a string, not %S" chord))
  (portal-view--load)
  (unless (fboundp 'portal--key-post)
    (user-error "Rebuild Portal and restart Emacs to post key chords"))
  (portal--key-post chord)
  nil)

;;; Status panel

(defconst portal-status-positions
  '(top-left top top-right left center right bottom-left bottom bottom-right)
  "Where `portal-status-show' can anchor the status panel on a screen.")

(defconst portal-status-tones '(neutral progress success warning error)
  "What a status can mean, for `portal-status-show'.")

(defcustom portal-status-margin 24
  "Points between the status panel and the screen edges it is anchored to.
`portal-status-show' uses this unless given an :offset."
  :type 'natnum
  :group 'portal)

(defvar portal-status--timer nil
  "The timer that hides the status panel, or nil.")

(cl-defun portal-status-show (text &key (position 'bottom) offset (screen 'pointer)
                                   width height min-width max-width (max-lines 1)
                                   (tone 'neutral) timeout)
  "Show TEXT in the status panel, above every application.
The status panel is one small panel, on every Space and over fullscreen
apps, that shows TEXT, such as what a command bound with
`portal-global-shortcut-set' is doing while another application is
frontmost.  TEXT replaces what the panel showed.  The panel never takes
the keyboard or the mouse: showing it neither activates Emacs nor
changes where keys go.

Keywords:

:position  where on the screen, one of `portal-status-positions':
           a corner, the middle of an edge, or `center'.  Default
           `bottom', the middle of the bottom edge.
:offset    (X . Y), points to move the panel: inward from each edge it
           is anchored to, and along an axis it is centered on, right or
           down.  Default `portal-status-margin' from anchored edges.
           The panel always stays on the screen, clear of the menu bar
           and the Dock.
:screen    `pointer', the screen under the pointer, where the panel
           stays while shown; `primary', the screen with the menu bar;
           or N, the Nth screen from 0.  A missing screen means
           `pointer'.  Default `pointer'.
:width, :height
           a fixed size in points.  By default the panel fits TEXT.
:min-width, :max-width
           bounds for the fitted width.
:max-lines how many lines TEXT may wrap to at the panel's width; the
           last is cut short with an ellipsis.  Default 1.
:tone      what the status means, one of `portal-status-tones', which
           marks it: a spinner for `progress'; a green, yellow or red
           sign for `success', `warning' and `error'.  Default
           `neutral', unmarked.
:timeout   seconds after which the panel hides, unless shown again
           first.  Default nil: until `portal-status-hide'.

Return nil."
  (unless (and (stringp text) (not (string-empty-p text)))
    (user-error "A status must be a nonempty string, not %S" text))
  (unless (memq position portal-status-positions)
    (user-error "A status position is one of %S, not %S" portal-status-positions position))
  (unless (or (null offset) (and (consp offset) (integerp (car offset))
                                 (integerp (cdr offset))))
    (user-error "A status offset is (X . Y) in points, not %S" offset))
  (unless (or (memq screen '(pointer primary)) (natnump screen))
    (user-error "A status screen is `pointer', `primary' or a screen number, not %S" screen))
  (dolist (size (list width height min-width max-width))
    (unless (or (null size) (and (integerp size) (> size 0)))
      (user-error "A status panel size is a positive number of points, not %S" size)))
  (unless (and (integerp max-lines) (> max-lines 0))
    (user-error "A status shows a positive number of lines, not %S" max-lines))
  (unless (memq tone portal-status-tones)
    (user-error "A status tone is one of %S, not %S" portal-status-tones tone))
  (unless (or (null timeout) (and (numberp timeout) (> timeout 0)))
    (user-error "A status timeout is a positive number of seconds, not %S" timeout))
  (portal-view--load)
  (unless (fboundp 'portal--status-show)
    (user-error "Rebuild Portal and restart Emacs to show a status"))
  (let ((offset (or offset
                    (cons (if (memq position '(top center bottom)) 0 portal-status-margin)
                          (if (memq position '(left center right)) 0 portal-status-margin)))))
    (portal--status-show text (symbol-name tone) (symbol-name position)
                         (pcase screen ('pointer -1) ('primary 0) (_ screen))
                         (car offset) (cdr offset) (or width 0) (or height 0)
                         (or min-width 0) (or max-width 0) max-lines))
  (portal-status--cancel-timer)
  (when timeout
    (setq portal-status--timer (run-at-time timeout nil #'portal-status-hide)))
  nil)

(defun portal-status-hide ()
  "Hide the status panel of `portal-status-show'.
Do nothing when it is hidden.  Return nil."
  (portal-status--cancel-timer)
  (portal-view--load)
  (unless (fboundp 'portal--status-hide)
    (user-error "Rebuild Portal and restart Emacs to hide a status"))
  (portal--status-hide)
  nil)

(defun portal-status--cancel-timer ()
  "Cancel the timer that would hide the status panel."
  (when (timerp portal-status--timer)
    (cancel-timer portal-status--timer))
  (setq portal-status--timer nil))

(provide 'portal-system)
;;; portal-system.el ends here
