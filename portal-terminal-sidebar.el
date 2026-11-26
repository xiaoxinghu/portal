;;; portal-terminal-sidebar.el --- A side window listing every terminal -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; `portal-terminal-sidebar' shows *Portal terminals* in a narrow side
;; window: every terminal, the blocks of each Rex session under the
;; session's heading, then Portal's own terminals, each row with the mark
;; of what its program is doing.  It is a roster: a row keeps its place
;; whatever its status, where `*Rex agents*' sorts by urgency.  It is
;; drawn from what Emacs holds, asking the server nothing, and drawn
;; afresh as that changes while a window shows it.

(require 'cl-lib)
(require 'portal-rex)
(require 'portal-terminal-choose)

(defconst portal-terminal-sidebar--name "*Portal terminals*"
  "The name of the sidebar's buffer.")

(defvar portal-terminal-sidebar-width 32
  "The total width of the sidebar of terminals, in columns, as last given.
The sidebar is shown at this width.  Resizing its side window, by its
edge or with \\[enlarge-window-horizontally], sets it, so the sidebar comes back at
the width it had, in any tab or frame.  With `savehist-mode' on, it
lasts across Emacs sessions.  A `window-width' in an entry of
`display-buffer-alist' for the sidebar wins over it.")

(defvar savehist-additional-variables)
(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables 'portal-terminal-sidebar-width))

(defcustom portal-terminal-sidebar-display-action
  '(display-buffer-in-side-window
    (side . left)
    (slot . 0)
    (preserve-size . (t . nil))
    (window-parameters . ((no-delete-other-windows . t))))
  "The action `portal-terminal-sidebar' shows the sidebar with.
It is the ACTION argument of `display-buffer': an entry for the buffer
*Portal terminals* in `display-buffer-alist' wins over it.  Its
`window-width' is `portal-terminal-sidebar-width' unless it names one.
The default is a side window on the left whose width balancing and frame
resizes leave alone, and which \\[delete-other-windows] keeps."
  :type display-buffer--action-custom-type
  :group 'portal-terminal)

(defface portal-terminal-sidebar-server '((t :inherit (bold underline)))
  "Face of a Rex server's heading, shown when more than one is connected."
  :group 'portal-terminal)

(defface portal-terminal-sidebar-session '((t :inherit bold))
  "Face of the heading of a Rex session with blocks."
  :group 'portal-terminal)

(defface portal-terminal-sidebar-empty-session
  '((t :inherit (shadow portal-terminal-sidebar-session)))
  "Face of the heading of a Rex session without blocks."
  :group 'portal-terminal)

(defface portal-terminal-sidebar-terminal '((t :inherit default))
  "Face of the name of one of Portal's own terminals, whose programs Emacs runs."
  :group 'portal-terminal)

(defface portal-terminal-sidebar-program '((t :inherit shadow))
  "Face of the program at the right of a row, and of a folded session's count."
  :group 'portal-terminal)

(defface portal-terminal-sidebar-current '((t :inherit bold))
  "Face of the row of the terminal in use."
  :group 'portal-terminal)

(defface portal-terminal-sidebar-current-indicator
  '((t :inherit mode-line-emphasis :slant normal))
  "Face of the left-edge bar marking the row of the terminal in use."
  :group 'portal-terminal)

(defface portal-terminal-sidebar-hover '((t :inherit highlight :extend nil))
  "Face of a clickable row or heading under the mouse pointer."
  :group 'portal-terminal)

(defcustom portal-terminal-sidebar-evil-keys t
  "Non-nil starts the sidebar in Evil's normal state with keys for it.
Set it before Evil or this file loads; nil leaves Evil untouched."
  :type 'boolean
  :group 'portal-terminal)

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'portal-terminal-sidebar-current-bar
    [224] nil nil '(center repeated)))

;;; The order

(defun portal-terminal-sidebar-tree ()
  "Return the terminals as the sidebar lists them, with their groups.
The value is (SERVERS . TERMINALS).  SERVERS holds an entry for each
connection to a Rex server that has its sessions, oldest first:
\(CONNECTION . SESSIONS).  SESSIONS are in the order the connection holds
them, the server's, empty ones included, each (SESSION-ID LABEL . BLOCKS):
the buffers of its blocks, in the order they were made.  TERMINALS are
the buffers of Portal's own terminals, whose programs Emacs runs, in the
order they were made.  Quick terminals are left out."
  (cons (cl-loop for connection in portal-rex--connections
                 when (portal-rex-connection-sessions connection)
                 collect (cons connection
                               (cl-loop for session across (portal-rex-connection-sessions connection)
                                        for id = (plist-get session :session_id)
                                        collect (cons id (cons (plist-get session :label)
                                                               (portal-terminal-sidebar--blocks
                                                                connection id))))))
        (cl-remove-if (lambda (buffer) (buffer-local-value 'portal-rex-block-connection buffer))
                      (portal-terminal-buffers))))

(defun portal-terminal-sidebar--blocks (connection session-id)
  "Return the buffers of CONNECTION's blocks in SESSION-ID, oldest first."
  (sort (portal-rex-buffers connection session-id)
        :key (lambda (buffer) (or (buffer-local-value 'portal-terminal--elsewhere buffer) 0))))

(defun portal-terminal-sidebar-buffers ()
  "Return the terminals' buffers in the sidebar's order, folded or not.
That is each connection's sessions' blocks, then Portal's own terminals,
as `portal-terminal-sidebar-tree' groups them."
  (pcase-let ((`(,servers . ,terminals) (portal-terminal-sidebar-tree)))
    (append (cl-loop for (_connection . sessions) in servers
                     append (cl-loop for (_id _label . blocks) in sessions append blocks))
            terminals)))

;;; Drawing

(defvar portal-terminal-sidebar--folded nil
  "The IDs of the Rex sessions folded in the sidebar, whose rows it leaves out.")

(defvar-local portal-terminal-sidebar--drawn nil
  "The terminals the sidebar was last drawn with, folded ones too.
Each is (BUFFER NAME PROGRAM): its buffer's name and the program its row
named then.")

(defvar-local portal-terminal-sidebar--drawn-width nil
  "The width, in columns, the sidebar's text was last drawn to.")

(defvar portal-terminal-sidebar--drawn-at 0
  "When the sidebar was last drawn, as `float-time' gives it.")

(defvar portal-terminal-sidebar--missed nil
  "Non-nil when the sidebar was not drawn for a change, as no window showed it.
A window that shows it again draws it, such as one of a tab restored.")

(defvar-local portal-terminal-sidebar--overlay nil
  "The overlay that styles the row of the terminal in use.")

(defvar-local portal-terminal-sidebar--bar-overlays nil
  "The overlays drawing the left-edge bar on each line of the terminal in use.")

(defun portal-terminal-sidebar--program (buffer)
  "Return what names the program of terminal BUFFER on its row, or nil.
That is the app its status reports, else the file name of the program
in its foreground."
  (let ((program (buffer-local-value 'portal-terminal--program buffer)))
    (or (plist-get (buffer-local-value 'portal-terminal--status buffer) :app)
        (and program (file-name-nondirectory program)))))

(defun portal-terminal-sidebar--label (buffer)
  "Return the name of terminal BUFFER's row.
A block's label, or the buffer's name without its asterisks."
  (let ((label (buffer-local-value 'portal-rex--block-label buffer)))
    (if (and label (not (string-empty-p label)))
        label
      (replace-regexp-in-string "\\`\\*\\|\\*\\(<[0-9]+>\\)?\\'" "\\1" (buffer-name buffer)))))

(defun portal-terminal-sidebar--face (status)
  "Return the face of STATUS's state."
  (intern (format "portal-terminal-status-%s" (plist-get status :state))))

(defun portal-terminal-sidebar--mark (status)
  "Return STATUS's mark in its face, padded to the width of every mark.
Without a status or a mark for it, spaces."
  (let* ((width (apply #'max 1 (mapcar (lambda (entry) (string-width (cdr entry)))
                                       portal-terminal-status-marks)))
         (mark (and status (alist-get (plist-get status :state) portal-terminal-status-marks))))
    (concat (and mark (propertize mark 'face (portal-terminal-sidebar--face status)))
            (make-string (- width (if mark (string-width mark) 0)) ?\s))))

(defun portal-terminal-sidebar--urgent (buffers)
  "Return the most urgent status of BUFFERS' terminals, or nil."
  (car (sort (delq nil (mapcar (lambda (buffer) (buffer-local-value 'portal-terminal--status buffer))
                               buffers))
             :key (lambda (status)
                    (cl-position (plist-get status :state) portal-rex--states :key #'cdr)))))

(defun portal-terminal-sidebar--line (prefix text face right width)
  "Return a line WIDTH columns wide: PREFIX, then TEXT in FACE, then RIGHT.
TEXT is cut short to leave room for RIGHT, which ends at the right; on
a line too narrow for both, RIGHT is left out.  Lines without RIGHT are
padded with spaces to WIDTH so hover and clicks span the full row."
  (let* ((right-width (if right (1+ (string-width right)) 0))
         (room (- width (string-width prefix) right-width)))
    (when (and right (< room 6))
      (setq right nil
            room (- width (string-width prefix))))
    (let* ((text (truncate-string-to-width text (max room 1) nil nil t))
           (pad (max 0 (- width (string-width prefix) (string-width text)
                          (if right (string-width right) 0)))))
      (concat prefix (propertize text 'face face)
              (when (> pad 0) (make-string pad ?\s))
              right))))

(defun portal-terminal-sidebar--tail (text width)
  "Return TEXT, or as much of its end as fits in WIDTH columns after an ellipsis.
A server is told apart by the end of its socket's name."
  (if (<= (string-width text) width)
      text
    (let* ((ellipsis (truncate-string-ellipsis))
           (room (- width (string-width ellipsis)))
           (start (length text)))
      (while (and (> start 0) (<= (string-width text (1- start)) room))
        (cl-decf start))
      (concat ellipsis (substring text start)))))

(defun portal-terminal-sidebar--insert (lines clickable &rest properties)
  "Insert LINES, each followed by a newline, with PROPERTIES on all of them.
When CLICKABLE is non-nil, put `mouse-face' on the item up to, but not
including, its final newline so consecutive items hover separately."
  (let ((start (point)))
    (dolist (line lines)
      (insert line "\n"))
    (add-text-properties start (point) properties)
    (when clickable
      (put-text-property start (1- (point)) 'mouse-face 'portal-terminal-sidebar-hover))))

(defun portal-terminal-sidebar--insert-row (buffer indent width &optional connection session-id)
  "Insert the row of terminal BUFFER, INDENT before its mark, WIDTH columns wide.
CONNECTION and SESSION-ID are those of a block's session.  A blocked or
failed terminal has a second line, saying what its program said."
  (let* ((status (buffer-local-value 'portal-terminal--status buffer))
         (program (portal-terminal-sidebar--program buffer))
         (prefix (concat indent (portal-terminal-sidebar--mark status) " "))
         (lines (list (portal-terminal-sidebar--line
                       prefix (portal-terminal-sidebar--label buffer)
                       (and (not connection) 'portal-terminal-sidebar-terminal)
                       (and program (propertize program 'face 'portal-terminal-sidebar-program))
                       width))))
    (when (memq (plist-get status :state) '(blocked error))
      (setq lines (append lines
                          (list (portal-terminal-sidebar--line
                                 (make-string (string-width prefix) ?\s)
                                 (or (plist-get status :message)
                                     (portal-terminal--status-word status))
                                 (portal-terminal-sidebar--face status) nil width)))))
    (portal-terminal-sidebar--insert
     lines t
     'portal-terminal-sidebar-item buffer
     'portal-terminal-sidebar-connection connection
     'portal-terminal-sidebar-session session-id)))

(defun portal-terminal-sidebar--insert-heading (connection session-id label blocks indent width)
  "Insert the heading of CONNECTION's session SESSION-ID, called LABEL.
BLOCKS are its blocks' buffers.  INDENT comes before it, and it is WIDTH
columns wide.  A folded session's heading ends with its most urgent
block's mark and how many blocks it has."
  (let ((urgent (portal-terminal-sidebar--urgent blocks)))
    (portal-terminal-sidebar--insert
     (list (portal-terminal-sidebar--line
            indent (if (and label (not (string-empty-p label))) label session-id)
            (if blocks 'portal-terminal-sidebar-session 'portal-terminal-sidebar-empty-session)
            (and blocks (member session-id portal-terminal-sidebar--folded)
                 (concat (and urgent (concat (portal-terminal-sidebar--mark urgent) " "))
                         (propertize (number-to-string (length blocks))
                                     'face 'portal-terminal-sidebar-program)))
            width))
     t
     'portal-terminal-sidebar-item (cons 'session session-id)
     'portal-terminal-sidebar-connection connection
     'portal-terminal-sidebar-session session-id)))

(defun portal-terminal-sidebar--width ()
  "Return the width to draw the sidebar's text to, in columns.
That of the narrowest window showing it, less a column at the right."
  (let ((windows (get-buffer-window-list (current-buffer) 'nomini t)))
    (max 8 (1- (if windows
                   (apply #'min (mapcar #'window-max-chars-per-line windows))
                 (- portal-terminal-sidebar-width 2))))))

(defun portal-terminal-sidebar--draw ()
  "Draw the sidebar afresh in the current buffer."
  (let* ((inhibit-read-only t)
         (width (portal-terminal-sidebar--width))
         (tree (portal-terminal-sidebar-tree))
         (several (cdar tree))
         (indent (if several "   " " "))
         drawn)
    (erase-buffer)
    (pcase-dolist (`(,connection . ,sessions) (car tree))
      (when several
        (portal-terminal-sidebar--insert
         (list (portal-terminal-sidebar--line
                " " (portal-terminal-sidebar--tail (portal-rex--named connection) (1- width))
                'portal-terminal-sidebar-server nil width))
         nil
         'portal-terminal-sidebar-item (cons 'server (portal-rex-connection-socket connection))))
      (pcase-dolist (`(,id ,label . ,blocks) sessions)
        (portal-terminal-sidebar--insert-heading connection id label blocks indent width)
        (dolist (buffer blocks)
          (push buffer drawn)
          (unless (member id portal-terminal-sidebar--folded)
            (portal-terminal-sidebar--insert-row buffer indent width connection id)))))
    (dolist (buffer (cdr tree))
      (push buffer drawn)
      (portal-terminal-sidebar--insert-row buffer " " width))
    (when (bobp)
      (insert (propertize " No terminals\n" 'face 'shadow)))
    (setq portal-terminal-sidebar--drawn
          (mapcar (lambda (buffer)
                    (list buffer (buffer-name buffer) (portal-terminal-sidebar--program buffer)))
                  (nreverse drawn))
          portal-terminal-sidebar--drawn-width width
          portal-terminal-sidebar--drawn-at (float-time)
          portal-terminal-sidebar--missed nil)))

(defun portal-terminal-sidebar--find (item)
  "Return where ITEM's lines start in the sidebar, or nil."
  (let ((position (point-min)))
    (while (and position (< position (point-max))
                (not (equal (get-text-property position 'portal-terminal-sidebar-item) item)))
      (setq position (next-single-property-change position 'portal-terminal-sidebar-item)))
    (and position (< position (point-max)) position)))

(defun portal-terminal-sidebar--place (position)
  "Return what POSITION is on, to find it again after a redraw.
That is (ITEM SESSION OFFSET LINE COLUMN): the row or heading there, the
session of a block's row, which of the item's lines it is, the line's
number and the column."
  (save-excursion
    (goto-char position)
    (let* ((item (get-text-property (line-beginning-position) 'portal-terminal-sidebar-item))
           (start (and item (portal-terminal-sidebar--find item))))
      (list item
            (get-text-property (line-beginning-position) 'portal-terminal-sidebar-session)
            (if start (1- (count-lines start (line-end-position))) 0)
            (line-number-at-pos)
            (current-column)))))

(defun portal-terminal-sidebar--go-to (place)
  "Move to PLACE, as `portal-terminal-sidebar--place' gave it, and return point.
A row folded away gives its session's heading, and an item gone the
line of the same number."
  (pcase-let* ((`(,item ,session ,offset ,line ,column) place)
               (start (or (and item (portal-terminal-sidebar--find item))
                          (and session (portal-terminal-sidebar--find (cons 'session session))))))
    (if (not start)
        (progn (goto-char (point-min))
               (forward-line (1- line)))
      (goto-char start)
      (when (equal (get-text-property start 'portal-terminal-sidebar-item) item)
        (dotimes (_ offset)
          (when (equal (get-text-property (line-beginning-position 2) 'portal-terminal-sidebar-item)
                       item)
            (forward-line 1)))))
    (move-to-column column)
    (point)))

(defun portal-terminal-sidebar--refresh (&optional buffer)
  "Draw the sidebar in BUFFER, by default the current buffer, afresh.
Point stays on its row in each window that shows it."
  (with-current-buffer (or buffer (current-buffer))
    (let ((places (mapcar (lambda (window)
                            (cons window (portal-terminal-sidebar--place (window-point window))))
                          (get-buffer-window-list nil nil t)))
          (here (portal-terminal-sidebar--place (point))))
      (portal-terminal-sidebar--draw)
      (pcase-dolist (`(,window . ,place) places)
        (set-window-point window (portal-terminal-sidebar--go-to place)))
      (portal-terminal-sidebar--go-to here)
      (portal-terminal-sidebar--highlight))))

;;; The terminal in use

(defun portal-terminal-sidebar--in-use ()
  "Return the buffer of the terminal in use, as the sidebar highlights it.
That of the selected window, or, while the sidebar is selected, of the
window used last."
  (let ((window (portal-view--selected-pane)))
    (when (eq (window-buffer window) (get-buffer portal-terminal-sidebar--name))
      (setq window (get-mru-window nil nil t)))
    (and window (window-buffer window))))

(defun portal-terminal-sidebar--fringe-p ()
  "Return non-nil when the sidebar can draw its bar in the left fringe."
  (and (fboundp 'fringe-bitmap-p)
       (fringe-bitmap-p 'portal-terminal-sidebar-current-bar)
       (let* ((window (get-buffer-window (current-buffer) t))
              (frame (if window (window-frame window) (selected-frame)))
              (width (or (and window (car (window-fringes window)))
                         (frame-parameter frame 'left-fringe))))
         (and (display-graphic-p frame)
              (or (null width) (> width 0))))))

(defun portal-terminal-sidebar--make-bars (start end)
  "Draw the left-edge indicator bar on every line from START to END."
  (let ((fringe (portal-terminal-sidebar--fringe-p))
        (pos start)
        bars)
    (save-excursion
      (while (< pos end)
        (goto-char pos)
        (if fringe
            (let ((ov (make-overlay pos pos)))
              (overlay-put ov 'before-string
                           (propertize " " 'display
                                       '(left-fringe portal-terminal-sidebar-current-bar
                                                     portal-terminal-sidebar-current-indicator)))
              (push ov bars))
          (when (eq (char-after pos) ?\s)
            (let ((ov (make-overlay pos (1+ pos))))
              (overlay-put ov 'display
                           (propertize "▎" 'face 'portal-terminal-sidebar-current-indicator))
              (overlay-put ov 'evaporate t)
              (push ov bars))))
        (forward-line 1)
        (setq pos (point))))
    (nreverse bars)))

(defun portal-terminal-sidebar--highlight ()
  "Mark the row of the terminal in use in the current buffer, the sidebar.
A row folded away marks its session's heading."
  (mapc #'delete-overlay portal-terminal-sidebar--bar-overlays)
  (setq portal-terminal-sidebar--bar-overlays nil)
  (let* ((buffer (portal-terminal-sidebar--in-use))
         (start (and buffer
                     (or (portal-terminal-sidebar--find buffer)
                         (when-let* ((session (buffer-local-value 'portal-rex-session-id buffer)))
                           (portal-terminal-sidebar--find (cons 'session session)))))))
    (unless (overlayp portal-terminal-sidebar--overlay)
      (setq portal-terminal-sidebar--overlay (make-overlay (point-min) (point-min)))
      (overlay-put portal-terminal-sidebar--overlay 'face 'portal-terminal-sidebar-current)
      (overlay-put portal-terminal-sidebar--overlay 'priority -50))
    (if start
        (let ((end (or (next-single-property-change start 'portal-terminal-sidebar-item)
                       (point-max))))
          (move-overlay portal-terminal-sidebar--overlay start end)
          (setq portal-terminal-sidebar--bar-overlays
                (portal-terminal-sidebar--make-bars start end)))
      (delete-overlay portal-terminal-sidebar--overlay))))

(defun portal-terminal-sidebar--selection-changed (&rest _)
  "Move the sidebar's highlight to the terminal now in use, drawing nothing.
On `window-selection-change-functions' while the sidebar's buffer lives."
  (when-let* ((sidebar (get-buffer portal-terminal-sidebar--name)))
    (with-current-buffer sidebar (portal-terminal-sidebar--highlight))))

(defun portal-terminal-sidebar--windows-changed (&rest _)
  "Follow windows that changed buffers, or came, as a tab's do when it is restored.
The highlight moves to the terminal now in use, and a sidebar shown again
after missing a change is drawn afresh.  On `window-buffer-change-functions'
while the sidebar's buffer lives."
  (portal-terminal-sidebar--selection-changed)
  (when portal-terminal-sidebar--missed
    (portal-terminal-sidebar--schedule)))

;;; When it is drawn

(defvar portal-terminal-sidebar--timer nil
  "The timer that will draw the sidebar afresh, or nil.")

(defun portal-terminal-sidebar--schedule (&rest _)
  "Draw the sidebar afresh soon, if a window shows it.
It is drawn at most once in a tenth of a second.  With no window showing
it, it is drawn once one does."
  (when-let* ((sidebar (get-buffer portal-terminal-sidebar--name))
              ((not (timerp portal-terminal-sidebar--timer))))
    (if (not (get-buffer-window sidebar t))
        (setq portal-terminal-sidebar--missed t)
      (setq portal-terminal-sidebar--timer
            (run-at-time (max 0 (- (+ portal-terminal-sidebar--drawn-at 0.1) (float-time)))
                         nil #'portal-terminal-sidebar--redraw)))))

(defun portal-terminal-sidebar--redraw ()
  "Draw the sidebar afresh if a window still shows it."
  (setq portal-terminal-sidebar--timer nil)
  (when-let* ((sidebar (get-buffer portal-terminal-sidebar--name)))
    (if (get-buffer-window sidebar t)
        (portal-terminal-sidebar--refresh sidebar)
      (setq portal-terminal-sidebar--missed t))))

(defun portal-terminal-sidebar--drawn-entry (buffer)
  "Return BUFFER's entry in what the sidebar was last drawn with, or nil."
  (when-let* ((sidebar (get-buffer portal-terminal-sidebar--name)))
    (assq buffer (buffer-local-value 'portal-terminal-sidebar--drawn sidebar))))

(defun portal-terminal-sidebar--terminal-changed (_state)
  "Draw the sidebar afresh if this terminal is new to it or its program changed.
On `portal-terminal--changed-functions', which also runs as a terminal
starts."
  (unless portal-terminal--quick-root
    (let ((entry (portal-terminal-sidebar--drawn-entry (current-buffer))))
      (unless (and entry (equal (nth 2 entry)
                                (portal-terminal-sidebar--program (current-buffer))))
        (portal-terminal-sidebar--schedule)))))

(defun portal-terminal-sidebar--view-closed ()
  "Draw the sidebar afresh if this buffer's view was a terminal it lists.
On `portal-view-close-hook': a terminal of Portal's own has ended, or a
block's program is not known any more."
  (when (portal-terminal-sidebar--drawn-entry (current-buffer))
    (portal-terminal-sidebar--schedule)))

(defun portal-terminal-sidebar--buffers-changed ()
  "Draw the sidebar afresh if a terminal it lists was renamed or killed.
On `buffer-list-update-hook'."
  (when-let* ((sidebar (get-buffer portal-terminal-sidebar--name)))
    (when (cl-some (lambda (entry) (not (equal (buffer-name (car entry)) (nth 1 entry))))
                   (buffer-local-value 'portal-terminal-sidebar--drawn sidebar))
      (portal-terminal-sidebar--schedule))))

(defun portal-terminal-sidebar--resized (window)
  "Keep the width WINDOW, a window showing the sidebar, has now.
A side window's width becomes `portal-terminal-sidebar-width', and is
preserved again: a resize does not update a preserved width, nor does
`enlarge-window' leave it preserved.  The text is drawn afresh for a
new width.  On the sidebar's `window-size-change-functions'."
  (when (window-parameter window 'window-side)
    (setq portal-terminal-sidebar-width (window-total-width window))
    (window-preserve-size window t t))
  (with-current-buffer (window-buffer window)
    (unless (eql (portal-terminal-sidebar--width) portal-terminal-sidebar--drawn-width)
      (portal-terminal-sidebar--schedule))))

(defconst portal-terminal-sidebar--hooks
  '((portal-rex-status-functions . portal-terminal-sidebar--schedule)
    (portal-rex-sessions-changed-functions . portal-terminal-sidebar--schedule)
    (portal-terminal--changed-functions . portal-terminal-sidebar--terminal-changed)
    (portal-view-close-hook . portal-terminal-sidebar--view-closed)
    (buffer-list-update-hook . portal-terminal-sidebar--buffers-changed)
    (window-selection-change-functions . portal-terminal-sidebar--selection-changed)
    (window-buffer-change-functions . portal-terminal-sidebar--windows-changed))
  "The hooks the sidebar follows while its buffer lives, and its function on each.")

(defun portal-terminal-sidebar--follow (install)
  "INSTALL the sidebar's functions on the hooks it follows, or remove them."
  (pcase-dolist (`(,hook . ,function) portal-terminal-sidebar--hooks)
    (if install (add-hook hook function) (remove-hook hook function))))

(defun portal-terminal-sidebar--stop ()
  "Follow nothing more, as the sidebar's buffer goes or changes its mode.
On its `kill-buffer-hook' and `change-major-mode-hook'."
  (when (timerp portal-terminal-sidebar--timer)
    (cancel-timer portal-terminal-sidebar--timer))
  (setq portal-terminal-sidebar--timer nil)
  (portal-terminal-sidebar--follow nil))

;;; Commands on a row

(defun portal-terminal-sidebar--at (property)
  "Return PROPERTY of the line at point."
  (get-text-property (line-beginning-position) property))

(defun portal-terminal-sidebar--terminal ()
  "Return the live terminal's buffer on the current line, or signal a user error."
  (let ((buffer (portal-terminal-sidebar--at 'portal-terminal-sidebar-item)))
    (unless (bufferp buffer) (user-error "No terminal on this line"))
    (unless (portal-terminal-metadata buffer) (user-error "That terminal has closed"))
    buffer))

(defun portal-terminal-sidebar--leave ()
  "Select the window used last, from a side or dedicated window.
Return the window that was selected."
  (prog1 (selected-window)
    (when (or (window-dedicated-p) (window-parameter nil 'window-side))
      (when-let* ((window (get-mru-window nil nil t)))
        (select-window window)))))

(defun portal-terminal-sidebar-visit ()
  "Select the terminal on the current line, or fold the session on it.
The terminal opens as the pickers open one: from the side window, in
the window used last."
  (interactive nil portal-terminal-sidebar-mode)
  (if (eq (car-safe (portal-terminal-sidebar--at 'portal-terminal-sidebar-item)) 'session)
      (portal-terminal-sidebar-toggle-fold)
    (let ((buffer (portal-terminal-sidebar--terminal)))
      (portal-terminal-sidebar--leave)
      (portal-terminal--visit buffer))))

(defun portal-terminal-sidebar-click (event)
  "Visit the terminal clicked on, or fold the session, as \\`RET' does.
EVENT is the click."
  (interactive "e" portal-terminal-sidebar-mode)
  (mouse-set-point event)
  (portal-terminal-sidebar-visit))

(defun portal-terminal-sidebar-visit-other-window ()
  "Select the terminal on the current line in another window."
  (interactive nil portal-terminal-sidebar-mode)
  (let ((buffer (portal-terminal-sidebar--terminal)))
    (portal-terminal-sidebar--leave)
    (switch-to-buffer-other-window buffer)))

(defun portal-terminal-sidebar-display ()
  "Show the terminal on the current line, and stay in the sidebar.
From the side window it is shown in the window used last, as \\`RET'
shows it, without selecting it."
  (interactive nil portal-terminal-sidebar-mode)
  (let* ((buffer (portal-terminal-sidebar--terminal))
         (sidebar (portal-terminal-sidebar--leave)))
    (if (eq (selected-window) sidebar)
        (display-buffer buffer t)
      (unwind-protect (portal-terminal--visit buffer)
        (select-window sidebar)))))

(defun portal-terminal-sidebar-toggle-fold ()
  "Fold the Rex session whose heading is on the current line, or unfold it.
A folded session's blocks are left out, and its heading shows the mark
of its most urgent block and how many blocks it has."
  (interactive nil portal-terminal-sidebar-mode)
  (let ((item (portal-terminal-sidebar--at 'portal-terminal-sidebar-item)))
    (unless (eq (car-safe item) 'session)
      (user-error "Not on the heading of a session"))
    (setq portal-terminal-sidebar--folded
          (if (member (cdr item) portal-terminal-sidebar--folded)
              (delete (cdr item) portal-terminal-sidebar--folded)
            (cons (cdr item) portal-terminal-sidebar--folded)))
    (portal-terminal-sidebar--refresh)))

(defun portal-terminal-sidebar-new ()
  "Start a terminal in the session of the current line, in the window used last.
On a session's heading or one of its blocks, it is a block of that
session; on one of Portal's own terminals, or no terminal, one of
Portal's own.  It starts in the directory of that window's buffer."
  (interactive nil portal-terminal-sidebar-mode)
  (let ((connection (portal-terminal-sidebar--at 'portal-terminal-sidebar-connection))
        (session-id (portal-terminal-sidebar--at 'portal-terminal-sidebar-session)))
    (when (eq (car-safe (portal-terminal-sidebar--at 'portal-terminal-sidebar-item)) 'server)
      (user-error "Not in a session: start a terminal from a session's heading"))
    (portal-terminal-sidebar--leave)
    (if session-id
        (portal-rex-new-terminal connection session-id)
      (portal-terminal-new))))

(defvar-keymap portal-terminal-sidebar-mode-map
  :doc "Keys in the sidebar of terminals."
  "RET" #'portal-terminal-sidebar-visit
  "TAB" #'portal-terminal-sidebar-toggle-fold
  "o" #'portal-terminal-sidebar-visit-other-window
  "C-o" #'portal-terminal-sidebar-display
  "c" #'portal-terminal-sidebar-new
  "n" #'next-line
  "p" #'previous-line
  "<mouse-2>" #'portal-terminal-sidebar-click
  "<follow-link>" 'mouse-face)

(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))

(defun portal-terminal-sidebar--setup-evil ()
  "Bind the sidebar's Evil normal-state keys, unless disabled.
Does nothing when `portal-terminal-sidebar-evil-keys' is nil."
  (when portal-terminal-sidebar-evil-keys
    (evil-set-initial-state 'portal-terminal-sidebar-mode 'normal)
    (evil-define-key* 'normal portal-terminal-sidebar-mode-map
      (kbd "RET") #'portal-terminal-sidebar-visit
      (kbd "TAB") #'portal-terminal-sidebar-toggle-fold
      "o" #'portal-terminal-sidebar-visit-other-window
      (kbd "C-o") #'portal-terminal-sidebar-display
      "c" #'portal-terminal-sidebar-new
      "gr" #'revert-buffer
      "q" #'quit-window)))

(with-eval-after-load 'evil
  (portal-terminal-sidebar--setup-evil))

(define-derived-mode portal-terminal-sidebar-mode special-mode "Terminals"
  "The sidebar of terminals: every terminal, grouped by Rex session.
Each Rex session has a heading, in the server's order, and its blocks
under it in the order they were made; Portal's own terminals follow,
with no heading.  A row has the mark of what its program is doing, its
name and its program, and a blocked or failed one a second line with
what its program said.  Rows keep their places whatever their status.
The row of the terminal in use is highlighted.  The sidebar is drawn
afresh as the terminals change while a window shows it, and by \\[revert-buffer].

\\{portal-terminal-sidebar-mode-map}"
  :group 'portal-terminal
  :interactive nil
  (setq mode-line-format nil
        truncate-lines t)
  (setq-local revert-buffer-function (lambda (&rest _) (portal-terminal-sidebar--refresh)))
  (add-hook 'window-size-change-functions #'portal-terminal-sidebar--resized nil t)
  (add-hook 'kill-buffer-hook #'portal-terminal-sidebar--stop nil t)
  (add-hook 'change-major-mode-hook #'portal-terminal-sidebar--stop nil t)
  (portal-terminal-sidebar--follow t))

;;; Showing it

(defun portal-terminal-sidebar--buffer ()
  "Return the sidebar's buffer, made if need be."
  (let ((buffer (get-buffer-create portal-terminal-sidebar--name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'portal-terminal-sidebar-mode)
        (portal-terminal-sidebar-mode)))
    buffer))

(defun portal-terminal-sidebar--windows ()
  "Return the windows of the selected frame that show the sidebar."
  (when-let* ((buffer (get-buffer portal-terminal-sidebar--name)))
    (get-buffer-window-list buffer 'nomini)))

(defun portal-terminal-sidebar--action ()
  "Return the action that shows the sidebar, its width as last given."
  (pcase-let ((`(,functions . ,alist) portal-terminal-sidebar-display-action))
    (if (assq 'window-width alist)
        portal-terminal-sidebar-display-action
      (cons functions (append alist `((window-width . ,portal-terminal-sidebar-width)))))))

(defun portal-terminal-sidebar--show ()
  "Show the sidebar, drawn afresh, without selecting it, and return its window."
  (let* ((buffer (portal-terminal-sidebar--buffer))
         (window (or (display-buffer buffer (portal-terminal-sidebar--action))
                     (user-error "Cannot show the sidebar of terminals"))))
    (portal-terminal-sidebar--refresh buffer)
    window))

;;;###autoload
(defun portal-terminal-sidebar ()
  "Show the sidebar of terminals, or hide it if the selected frame shows it.
The selected window stays selected.  The sidebar lists every terminal,
the blocks of each Rex session under its heading, then Portal's own
terminals, and keeps itself current; `portal-terminal-sidebar-select'
selects it.  It is shown with `portal-terminal-sidebar-display-action',
by default a side window on the left, `portal-terminal-sidebar-width'
columns wide."
  (interactive)
  (if-let* ((windows (portal-terminal-sidebar--windows)))
      (let ((selected (selected-window)))
        (dolist (window windows)
          (if (window-parameter window 'window-side)
              (delete-window window)
            (quit-restore-window window)))
        (when (window-live-p selected)
          (select-window selected 'norecord)))
    (portal-terminal-sidebar--show))
  nil)

;;;###autoload
(defun portal-terminal-sidebar-select ()
  "Select the sidebar of terminals, showing it first if the frame does not.
See `portal-terminal-sidebar'."
  (interactive)
  (select-window (or (car (portal-terminal-sidebar--windows))
                     (portal-terminal-sidebar--show))))

(provide 'portal-terminal-sidebar)
;;; portal-terminal-sidebar.el ends here
