;;; portal-rex-list.el --- A buffer listing what Rex blocks' programs are doing -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; `portal-rex-list-agents' shows *Rex agents*, a table of every Rex block
;; whose program reports a status: what it is doing, since when, and what
;; it said, as `list-processes' lists processes.  The rows follow
;; `portal-rex-status-functions', so the buffer left open stays current
;; with no key pressed; how long ago each report came is redrawn once a
;; minute while a window shows it.  The marks, faces and order are the
;; terminal pickers'.

(require 'cl-lib)
(require 'tabulated-list)
(require 'portal-rex)
(require 'portal-terminal-choose)

(defconst portal-rex-list--name "*Rex agents*"
  "The name of the buffer `portal-rex-list-agents' shows.")

(defvar portal-rex-list--leaving nil
  "A block's buffer being killed, which the rows leave out.")

(defvar-local portal-rex-list--timer nil
  "The timer that redraws this list's times while a window shows it.")

(defun portal-rex-list--buffers ()
  "Return the buffers of the Rex blocks that have a status, in the list's order.
Those that wait come first, the one that has waited longest at the top,
then those at work, the most recently selected first: the pickers' order."
  (portal-terminal--recent
   (cl-loop for buffer in (portal-rex-buffers)
            when (and (not (eq buffer portal-rex-list--leaving))
                      (buffer-local-value 'portal-terminal--status buffer))
            collect buffer)))

(defun portal-rex-list--entry (buffer)
  "Return the row of block BUFFER, as `tabulated-list-entries' holds one.
Its cells carry what they sort by as `portal-rex-list-key'."
  (let* ((status (buffer-local-value 'portal-terminal--status buffer))
         (time (plist-get status :time)))
    (list buffer
          (vector (propertize (portal-terminal--status-cell status)
                              'portal-rex-list-key
                              (cl-position (plist-get status :state) portal-rex--states
                                           :key #'cdr))
                  (buffer-name buffer)
                  (or (plist-get status :app) "")
                  (propertize (portal-terminal--ago time) 'portal-rex-list-key time)
                  (or (plist-get status :message) "")))))

(defun portal-rex-list--by-key (column)
  "Return a predicate that sorts rows by the key of their cell in COLUMN."
  (lambda (a b)
    (< (get-text-property 0 'portal-rex-list-key (aref (cadr a) column))
       (get-text-property 0 'portal-rex-list-key (aref (cadr b) column)))))

(defun portal-rex-list--format (entries)
  "Return the columns of a list holding ENTRIES.
The Block column is as wide as the longest name, within reason."
  (let ((width (apply #'max 16 (mapcar (lambda (entry) (string-width (aref (cadr entry) 1)))
                                       entries))))
    (vector `("Status" 14 ,(portal-rex-list--by-key 0))
            `("Block" ,(min width 40) t)
            '("App" 12 t)
            `("Since" 11 ,(portal-rex-list--by-key 3))
            '("Message" 0 t))))

(defun portal-rex-list--row-at (position)
  "Return the block of the row at POSITION and the column there, as a cons."
  (save-excursion
    (goto-char position)
    (cons (tabulated-list-get-id) (current-column))))

(defun portal-rex-list--go-to (block column line)
  "Move to BLOCK's row, at COLUMN, or to LINE when it has none, and return point."
  (goto-char (point-min))
  (while (and block (not (eobp)) (not (eq (tabulated-list-get-id) block)))
    (forward-line 1))
  (if (and block (eq (tabulated-list-get-id) block))
      (move-to-column column)
    (goto-char (point-min))
    (forward-line (1- line)))
  (point))

(defun portal-rex-list--refresh (&optional buffer)
  "Draw the rows of BUFFER, by default the current buffer, afresh.
Point stays on its block's row, in each window that shows the buffer."
  (with-current-buffer (or buffer (current-buffer))
    (let ((places (mapcar (lambda (window)
                            (let ((position (window-point window)))
                              (list window (portal-rex-list--row-at position)
                                    (line-number-at-pos position))))
                          (get-buffer-window-list nil nil t)))
          (here (list (portal-rex-list--row-at (point)) (line-number-at-pos))))
      (setq tabulated-list-entries (mapcar #'portal-rex-list--entry (portal-rex-list--buffers))
            tabulated-list-format (portal-rex-list--format tabulated-list-entries))
      (tabulated-list-init-header)
      (tabulated-list-print)
      (pcase-dolist (`(,window (,block . ,column) ,line) places)
        (set-window-point window (portal-rex-list--go-to block column line)))
      (pcase-let ((`((,block . ,column) ,line) here))
        (portal-rex-list--go-to block column line)))))

(defun portal-rex-list--lists ()
  "Return the live buffers that list Rex agents."
  (cl-loop for buffer in (buffer-list)
           when (eq (buffer-local-value 'major-mode buffer) 'portal-rex-list-mode)
           collect buffer))

(defun portal-rex-list--status-changed (&rest _)
  "Draw every list of Rex agents afresh, as a block's status has changed.
On `portal-rex-status-functions'."
  (mapc #'portal-rex-list--refresh (portal-rex-list--lists)))

(add-hook 'portal-rex-status-functions #'portal-rex-list--status-changed)

(defun portal-rex-list--block-killed ()
  "Take the row of the block whose buffer is being killed out of every list.
On `kill-buffer-hook' while a list is live."
  (when (and portal-rex-block-id portal-terminal--status)
    (let ((portal-rex-list--leaving (current-buffer)))
      (portal-rex-list--status-changed))))

(defun portal-rex-list--tick (buffer)
  "Redraw list BUFFER's times if a window shows it."
  (when (and (buffer-live-p buffer) (get-buffer-window buffer 'visible))
    (portal-rex-list--refresh buffer)))

(defun portal-rex-list--stop ()
  "Stop this list's timer, and follow killed blocks no more if it was the last.
On its `kill-buffer-hook' and `change-major-mode-hook'."
  (when (timerp portal-rex-list--timer)
    (cancel-timer portal-rex-list--timer))
  (setq portal-rex-list--timer nil)
  (unless (remq (current-buffer) (portal-rex-list--lists))
    (remove-hook 'kill-buffer-hook #'portal-rex-list--block-killed)))

(defun portal-rex-list--block ()
  "Return the live block's buffer on the current row, or signal a user error."
  (let ((buffer (tabulated-list-get-id)))
    (unless buffer (user-error "No block on this line"))
    (unless (and (buffer-live-p buffer) (portal-terminal-metadata buffer))
      (user-error "That terminal has closed"))
    buffer))

(defun portal-rex-list-visit ()
  "Select the block on the current row, as the terminal pickers do.
From a side or dedicated window, it opens in the window used last."
  (interactive nil portal-rex-list-mode)
  (let ((buffer (portal-rex-list--block)))
    (when (or (window-dedicated-p) (window-parameter nil 'window-side))
      (when-let* ((window (get-mru-window nil nil t)))
        (select-window window)))
    (portal-terminal--visit buffer)))

(defun portal-rex-list-visit-other-window ()
  "Select the block on the current row in another window."
  (interactive nil portal-rex-list-mode)
  (switch-to-buffer-other-window (portal-rex-list--block)))

(defvar-keymap portal-rex-list-mode-map
  :doc "Keys in the list of Rex agents."
  :parent tabulated-list-mode-map
  "RET" #'portal-rex-list-visit
  "o" #'portal-rex-list-visit-other-window)

(define-derived-mode portal-rex-list-mode tabulated-list-mode "Rex Agents"
  "The Rex blocks whose programs report what they are doing.
Each row is a block: its status, its buffer, the program that reports,
how long ago it did, and what it said.  Blocks that wait for you come
first, the one that has waited longest at the top, then those at work.
The rows change as the blocks do; how long ago is redrawn once a minute
while a window shows the list, and by \\[revert-buffer].

\\{portal-rex-list-mode-map}"
  :group 'portal-rex
  :interactive nil
  (setq tabulated-list-padding 1
        tabulated-list-format (portal-rex-list--format nil))
  (setq-local revert-buffer-function (lambda (&rest _) (portal-rex-list--refresh)))
  (add-hook 'kill-buffer-hook #'portal-rex-list--stop nil t)
  (add-hook 'change-major-mode-hook #'portal-rex-list--stop nil t)
  ;; A block's buffer gives no status change as it is killed.
  (add-hook 'kill-buffer-hook #'portal-rex-list--block-killed)
  (setq portal-rex-list--timer
        (run-at-time 60 60 #'portal-rex-list--tick (current-buffer)))
  (tabulated-list-init-header))

;;;###autoload
(defun portal-rex-list-agents ()
  "Show every Rex block whose program reports what it is doing.
The list stays current as they change: a block that starts to wait moves
to the top, one whose report you have seen leaves it.
\\<portal-rex-list-mode-map>\\[portal-rex-list-visit] selects a block, and \
\\[portal-rex-list-visit-other-window] shows it in another window."
  (interactive)
  (let ((buffer (get-buffer-create portal-rex-list--name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'portal-rex-list-mode)
        (portal-rex-list-mode))
      (portal-rex-list--refresh))
    (pop-to-buffer buffer)))

(provide 'portal-rex-list)
;;; portal-rex-list.el ends here
