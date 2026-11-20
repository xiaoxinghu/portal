;;; portal-terminal-choose.el --- Choosing terminals with completion -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Pickers over ordinary Emacs completion.  Each candidate is one string that
;; holds a terminal's label, the status of a Rex block's program, and its
;; project, directory and title, so any of them matches, and resolves to the
;; buffer, whatever its name.  The optional `portal-terminal-consult' adapter
;; reads the same choices with Consult.

(require 'cl-lib)
(require 'portal-project)
(require 'portal-terminal)

(declare-function portal-terminal-quick--editing-window "portal-terminal-quick" ())

(defvar portal-terminal-consult-auto-enable) ; In `portal'.

(defcustom portal-terminal-choose-quick nil
  "Whether terminal selection lists quick terminals too.
A chosen quick terminal opens in its quick panel, as
`portal-terminal-toggle' shows it; it is never previewed elsewhere."
  :type 'boolean
  :group 'portal-terminal)

(defvar-keymap portal-terminal-choose-map
  :doc "Keys in the minibuffer while choosing a terminal."
  "M-a" #'portal-terminal-choose-toggle-scope)

(defvar portal-terminal--reader #'portal-terminal--completing-read
  "Function that reads a terminal choice.
It is called with PROMPT, TERMINALS, ACTIONS and INITIAL.  TERMINALS and
ACTIONS are lists of (STRING . VALUE), in order: VALUE is a terminal
buffer, or `new' or `named'.  It returns the chosen VALUE, and must
require a match.  INITIAL is the initial input.  While it reads,
`portal-terminal-choose-map' must be active.
`portal-terminal-consult-mode' replaces it; the first picker loads
Consult for that, through `portal-terminal--reader-function'.")

;;; What a Rex block's program is doing

(defface portal-terminal-status-blocked '((t :inherit warning))
  "Face of the status of a terminal whose program is blocked on you."
  :group 'portal-terminal)

(defface portal-terminal-status-error '((t :inherit error))
  "Face of the status of a terminal whose program failed."
  :group 'portal-terminal)

(defface portal-terminal-status-done '((t :inherit success))
  "Face of the status of a terminal whose program is done, not yet seen."
  :group 'portal-terminal)

(defface portal-terminal-status-working '((t :inherit shadow))
  "Face of the status of a terminal whose program is working."
  :group 'portal-terminal)

(defcustom portal-terminal-status-marks
  '((blocked . "●") (error . "✗") (done . "✓") (working . "◌"))
  "The mark before each status word in the terminal pickers, by state.
The states are those of `:status' in `portal-terminal-metadata'.  Change
them for a font without these characters; a state left out has no mark."
  :type '(alist :key-type (choice (const blocked) (const error) (const done) (const working))
                :value-type string)
  :group 'portal-terminal)

(defcustom portal-terminal-status-message-width 60
  "The most columns a program's message takes in a terminal picker.
A longer message is cut short, ending in `truncate-string-ellipsis'."
  :type 'natnum
  :group 'portal-terminal)

(defvar portal-terminal--listed-statuses (make-hash-table :test #'eq :weakness 'key)
  "The status each terminal buffer had when it was last made a candidate.
Its annotation tells the same story as its candidate while the list is
open, however the program's status has changed since.")

(defun portal-terminal--waiting-p (buffer)
  "Return non-nil if terminal BUFFER's program waits for you."
  (plist-get (plist-get (portal-terminal-metadata buffer) :status) :waiting))

(defun portal-terminal--status-word (status)
  "Return the word that names STATUS: why it is blocked, or its state."
  (pcase (plist-get status :state)
    ('blocked (or (plist-get status :kind) "blocked"))
    ('error "failed")
    (state (symbol-name state))))

(defun portal-terminal--status-cell (status)
  "Return STATUS as a mark and a word in its state's face."
  (let ((mark (alist-get (plist-get status :state) portal-terminal-status-marks))
        (word (truncate-string-to-width (portal-terminal--status-word status) 12)))
    (propertize (if mark (concat mark " " word) word)
                'face (intern (format "portal-terminal-status-%s" (plist-get status :state))))))

(defun portal-terminal--status-cells (statuses)
  "Return the status column for STATUSES, one string each, or nil.
Each is a mark and a word in the state's face, padded to the same width;
a nil status gives spaces.  Without any status there is no column."
  (when (delq nil (copy-sequence statuses))
    (let* ((cells (mapcar (lambda (status) (and status (portal-terminal--status-cell status)))
                          statuses))
           (width (apply #'max (mapcar #'string-width (delq nil (copy-sequence cells))))))
      (mapcar (lambda (cell)
                (concat "  " (or cell "")
                        (make-string (- width (if cell (string-width cell) 0)) ?\s)))
              cells))))

(defun portal-terminal--ago (time)
  "Return how long ago TIME, as `float-time' gives it, was, in a few words."
  (let ((minutes (floor (- (float-time) time) 60)))
    (cond ((< minutes 1) "just now")
          ((< minutes 60) (format "%d min ago" minutes))
          ((< minutes (* 24 60)) (format "%d h ago" (/ minutes 60)))
          (t (format "%d d ago" (/ minutes (* 24 60)))))))

(defun portal-terminal--status-said (status)
  "Return what STATUS has to say beside a candidate, or nil.
That is the program's message, cut to `portal-terminal-status-message-width',
or, for a block that waits without one, how long ago it reported."
  (let ((message (plist-get status :message)))
    (cond (message (truncate-string-to-width message portal-terminal-status-message-width
                                             nil nil t))
          ((plist-get status :waiting) (portal-terminal--ago (plist-get status :time))))))

(defun portal-terminal--candidates (buffers)
  "Return completion candidates for BUFFERS, as (STRING . BUFFER) pairs.
Each string holds the terminal's name, the status of a Rex block's
program in a column of its own, and its project, directory and title, so
that completion matches any of them, and is unique because its name is.
The column is there when one of BUFFERS has a status: blank for the
others.  The string also carries its buffer as its `portal-terminal'
property."
  (let* ((data (mapcar #'portal-terminal-metadata buffers))
         (statuses (mapcar (lambda (entry) (plist-get entry :status)) data))
         (cells (portal-terminal--status-cells statuses))
         (projects (portal-terminal--project-names
                    (delq nil (mapcar (lambda (entry) (plist-get entry :project)) data))))
         (width (apply #'max 0 (mapcar #'string-width (mapcar #'buffer-name buffers)))))
    (cl-mapcar
     (lambda (buffer entry status)
       (let ((project (alist-get (plist-get entry :project) projects nil nil #'equal))
             (title (plist-get entry :title)))
         (puthash buffer status portal-terminal--listed-statuses)
         (cons (propertize
                (concat (truncate-string-to-width (buffer-name buffer) width nil ?\s)
                        (pop cells)
                        (propertize
                         (string-join
                          (delq nil (list "" (or project "-")
                                          (and (plist-get entry :directory)
                                               (abbreviate-file-name (plist-get entry :directory)))
                                          (and title (replace-regexp-in-string
                                                      "[[:cntrl:]]" " " title))))
                          "  ")
                         'face 'completions-annotations))
                'portal-terminal buffer)
               buffer)))
     buffers data statuses)))

(defun portal-terminal--annotation (buffer)
  "Return the facts about terminal BUFFER that its candidate leaves out, or nil.
They are what its program said, as its candidate's status was made, or
how long ago a block that waits reported; then the program in its
foreground, by its file name, and whether it is quick or has exited."
  (when-let* ((entry (and (bufferp buffer) (portal-terminal-metadata buffer))))
    (let ((said (portal-terminal--status-said
                 (gethash buffer portal-terminal--listed-statuses (plist-get entry :status))))
          (facts (delq nil (list (and (plist-get entry :program)
                                      (file-name-nondirectory (plist-get entry :program)))
                                 (and (plist-get entry :quick) "quick")
                                 (and (plist-get entry :exited) "exited")))))
      (when (or said facts)
        (propertize (concat (and said (concat "  " said))
                            (and facts (concat "  " (string-join facts " "))))
                    'face 'completions-annotations)))))

;; Match any part of a candidate, as Emacs does for buffer names, so context
;; after the name is searchable without extra packages.  Users' overrides win.
(add-to-list 'completion-category-defaults '(portal-terminal (styles basic substring)))

(defun portal-terminal--recent (buffers)
  "Return BUFFERS in the order to offer them, the current buffer last.
Rex blocks that wait for you come first, the one that has waited longest
at the top, then the rest, most recently selected first.  Emacs's buffer
list records a buffer when a window showing it is selected, unless the
caller asks it not to, as previews do."
  (let* ((order (buffer-list))
         (others (sort (remq (current-buffer) buffers)
                       :key (lambda (buffer) (cl-position buffer order))))
         (waiting (sort (seq-filter #'portal-terminal--waiting-p others)
                        :key (lambda (buffer)
                               (plist-get (plist-get (portal-terminal-metadata buffer) :status)
                                          :time)))))
    (append waiting (seq-remove (lambda (buffer) (memq buffer waiting)) others)
            (and (memq (current-buffer) buffers) (list (current-buffer))))))

(defun portal-terminal--context ()
  "Return (PROJECT . DIRECTORY) for choosing terminals from the current buffer.
In a terminal, they are its assigned project and its directory.  Elsewhere,
DIRECTORY is the frame's editing context, the directory of the file or
Dired buffer selected last, and PROJECT is its project, or nil."
  (let ((editing (lambda () (expand-file-name (or (portal-project-context) default-directory)))))
    (if (portal-terminal-metadata)
        ;; A terminal whose directory is not known yet starts new ones in
        ;; the editing context's.
        (cons portal-terminal--project (or portal-terminal--directory (funcall editing)))
      (let ((directory (funcall editing)))
        (cons (portal-project-root directory) directory)))))

(defun portal-terminal--place-name (project directory)
  "Return a short name for PROJECT's root, or for DIRECTORY without one."
  (abbreviate-file-name (if project
                            (file-name-nondirectory (directory-file-name project))
                          (directory-file-name directory))))

(defun portal-terminal--completing-read (prompt terminals actions initial)
  "Read one of TERMINALS or ACTIONS with `completing-read'.
See `portal-terminal--reader' for PROMPT, TERMINALS, ACTIONS and INITIAL.
Candidates keep their order, in two groups, and are annotated with
what a Rex block's program said and whether a terminal is quick or has
exited.  The default is the first terminal."
  (let* ((entries (append terminals actions))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata
                        (category . portal-terminal)
                        (display-sort-function . identity)
                        (cycle-sort-function . identity)
                        (group-function
                         . ,(lambda (candidate transform)
                              (cond (transform candidate)
                                    ((assoc candidate terminals) "Terminal")
                                    (t "New"))))
                        (annotation-function
                         . ,(lambda (candidate)
                              (portal-terminal--annotation (cdr (assoc candidate terminals))))))
                    (complete-with-action action entries string predicate))))
         (choice (minibuffer-with-setup-hook
                     (lambda ()
                       (use-local-map (make-composed-keymap portal-terminal-choose-map
                                                            (current-local-map))))
                   (completing-read prompt table nil t initial nil (caar terminals)))))
    (cdr (assoc choice entries))))

(defun portal-terminal-choose-toggle-scope ()
  "Switch between the current project's terminals and every terminal.
The input typed so far stays."
  (interactive)
  (throw 'portal-terminal--toggle (minibuffer-contents-no-properties)))

(defun portal-terminal--reader-function ()
  "Return the function that reads a terminal choice now.
A config that loads Consult lazily may open a picker before anything has
loaded Consult, and `portal-terminal-consult-mode' waits for Consult to
load, so the first picker after startup would read without preview or
narrowing.  When `portal-terminal-consult-auto-enable' is non-nil and
Consult is installed but not loaded, load it: `portal' enables the mode
when Consult loads, and that replaces `portal-terminal--reader'.  Once
Consult is loaded, the mode is left as it is."
  (when (and (bound-and-true-p portal-terminal-consult-auto-enable)
             (not (featurep 'consult))
             (locate-library "consult"))
    (require 'consult))
  portal-terminal--reader)

(defun portal-terminal--read-choice (project directory scoped)
  "Read a terminal of PROJECT, or of every project unless SCOPED, or a New action.
New terminals start at PROJECT's root, or DIRECTORY without a project.
Return the chosen buffer, or `new' or `named'."
  (let (input result)
    (while (stringp
            (setq result
                  (catch 'portal-terminal--toggle
                    (let ((buffers (portal-terminal-buffers (and scoped project)
                                                            portal-terminal-choose-quick))
                          (place (portal-terminal--place-name project directory)))
                      (list (funcall (portal-terminal--reader-function)
                                     (if scoped (format "Terminal in %s: " place) "Terminal: ")
                                     (portal-terminal--candidates (portal-terminal--recent buffers))
                                     (list (cons (format "New terminal in %s" place) 'new)
                                           (cons (format "New named terminal in %s…" place) 'named))
                                     input))))))
      ;; A toggle throws the input.  Without a project, every terminal stays.
      (setq input result
            scoped (and project (not scoped)))
      (unless project (message "Not in a project: listing every terminal")))
    (car result)))

(defun portal-terminal--visit (buffer)
  "Select terminal BUFFER where terminals of its kind are shown.
A quick terminal opens in the quick panel, with keyboard focus.  Any other
opens in the selected window, or in the editing window behind a quick panel."
  (unless (portal-terminal--p buffer)
    (user-error "That terminal has closed"))
  (if (buffer-local-value 'portal-terminal--quick-root buffer)
      (progn (portal-terminal-quick--display buffer)
             (portal-terminal-focus))
    (when (window-parameter nil 'portal-terminal-quick)
      (select-window (portal-terminal-quick--editing-window)))
    (portal-terminal--switch buffer)))

(defun portal-terminal--new-in (directory named)
  "Start a terminal in DIRECTORY, labelled with a name read when NAMED.
It belongs to the project DIRECTORY is in, as any new terminal does."
  (let ((label (and named (string-trim (read-string "Terminal name: ")))))
    (unless (file-directory-p directory)
      (user-error "Terminal directory no longer exists: %s" directory))
    (let ((default-directory (file-name-as-directory directory)))
      (portal-terminal--new nil nil nil nil nil
                            (and label (not (string-empty-p label)) label)))))

(defun portal-terminal--choose (scoped)
  "Choose a terminal, of the current project when SCOPED, and act on the choice.
The project is resolved before reading.  From a quick panel, the choice
applies to the editing window behind it; cancelling returns to the panel."
  (let* ((context (portal-terminal--context))
         (project (car context))
         (origin (selected-window))
         done)
    (when (and scoped (not project))
      (user-error "Not in a project; `portal-terminal-choose' lists every terminal"))
    (when (window-parameter origin 'portal-terminal-quick)
      (select-window (portal-terminal-quick--editing-window) 'norecord))
    (unwind-protect
        (let ((choice (portal-terminal--read-choice project (cdr context) scoped)))
          (pcase choice
            ((pred bufferp) (portal-terminal--visit choice))
            ((or 'new 'named) (portal-terminal--new-in (or project (cdr context)) (eq choice 'named)))
            (_ (user-error "No terminal chosen")))
          (setq done t))
      (unless (or done (not (window-live-p origin)))
        (select-window origin 'norecord)))))

;;;###autoload
(defun portal-terminal-choose ()
  "Choose a terminal with completion and select it.
Type any part of a terminal's name, project, directory or title, or the
status of a Rex block's program, such as \"question\" or \"working\".
Rex blocks that wait for you come first, longest waiting at the top, then
the most recently selected terminals.  The New group starts a terminal
in the current project, or asks for its name first.
\\<portal-terminal-choose-map>\\[portal-terminal-choose-toggle-scope] lists \
only the current project's terminals, and back."
  (interactive)
  (portal-terminal--choose nil))

;;;###autoload
(defun portal-terminal-choose-project ()
  "Choose one of the current project's terminals and select it.
The project is the one a terminal belongs to, when run from a terminal,
and the project being edited otherwise, however its shells have moved.
\\<portal-terminal-choose-map>\\[portal-terminal-choose-toggle-scope] lists \
every terminal, and back.  See `portal-terminal-choose'."
  (interactive)
  (portal-terminal--choose t))

(defun portal-terminal--read-buffer (prompt)
  "Read the name of a live terminal with PROMPT; the current one is the default."
  (read-buffer prompt (and (portal-terminal-metadata) (current-buffer)) t
               (lambda (entry)
                 (let ((buffer (if (consp entry) (cdr entry) (get-buffer entry))))
                   (and buffer (portal-terminal-metadata buffer))))))

;;;###autoload
(defun portal-terminal-select (buffer)
  "Select terminal BUFFER, a buffer or its name.
A quick terminal opens in its quick panel, and any other in the selected
window.  Interactively, read a terminal's name."
  (interactive (list (portal-terminal--read-buffer "Select terminal: ")))
  (portal-terminal--visit (get-buffer buffer)))

(provide 'portal-terminal-choose)
;;; portal-terminal-choose.el ends here
