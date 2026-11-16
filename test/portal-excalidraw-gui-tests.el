;;; portal-excalidraw-gui-tests.el --- Real WKWebView drawing checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal)
(require 'portal-terminal-tests)
(declare-function portal-test-web-eval "test-terminal-input" (script))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal-test-native-drag "test-terminal-input" (x1 y1 x2 y2))
(declare-function portal-web-gui--run-until "portal-web-gui-tests" (type))

(defvar portal-excalidraw-gui--stalled 0
  "When the page last took over 5 s to answer a script, as a float time.")

(defun portal-excalidraw-gui--js (script)
  "Run SCRIPT in the actual webview, returning its result.
JavaScript's false and null are nil.  The answer may take 30 s: on
GitHub's runners the page now and then stops for 15 s and then goes on as
if nothing had happened.  An answer that slow is said in the log and
noted for `portal-excalidraw-gui--until'."
  (should (portal-test-web-eval script))
  (let ((start (float-time)))
    (while (and (not (portal-test-web-eval nil)) (< (- (float-time) start) 30))
      (accept-process-output nil 0.02)
      (redisplay t))
    (when (> (- (float-time) start) 5)
      (setq portal-excalidraw-gui--stalled (float-time))
      (message "The page took %.1f s to answer a script" (- (float-time) start))))
  (should (portal-test-web-eval nil))
  (let ((result (json-parse-string (portal-test-web-eval nil) :object-type 'plist
                                   :false-object nil :null-object nil)))
    (should-not (plist-get result :error))
    (plist-get result :value)))

;; Drawings with content are files that hold it, as Excalidraw saves them;
;; Excalidraw fills in the properties they leave out.
(defun portal-excalidraw-gui--text (id text)
  "A text element ID that says TEXT."
  (list :type "text" :id id :x 100 :y 100 :width 300 :height 25
        :text text :fontSize 20 :fontFamily 5))

(defconst portal-excalidraw-gui--picture
  (list :type "image" :id "picture" :x 0 :y 0 :width 64 :height 64
        :fileId "pixel" :status "saved")
  "An image element showing `portal-excalidraw-gui--pixel'.")

(defconst portal-excalidraw-gui--pixel
  (list :pixel (list :id "pixel" :mimeType "image/png" :created 1
                     :dataURL "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
  "The image files of a drawing with `portal-excalidraw-gui--picture'.")

(defun portal-excalidraw-gui--write (file elements &optional files)
  "Write a drawing holding ELEMENTS and FILES, its images, to FILE."
  (with-temp-file file
    (insert (json-serialize (list :type "excalidraw" :version 2 :source "portal"
                                  :elements (vconcat elements) :appState (make-hash-table)
                                  :files (or files (make-hash-table)))))))

(defmacro portal-excalidraw-gui--drawing (elements files &rest body)
  "Run BODY with drawing.excalidraw open in `document', its buffer.
The file holds ELEMENTS and FILES; without ELEMENTS, it is a new drawing.
`directory' is the file's directory."
  (declare (indent 2))
  `(progn
     (skip-unless (eq window-system 'ns))
     (save-window-excursion
       (let ((directory (make-temp-file "portal-drawing-gui-" t)) document)
         (unwind-protect
             (let ((file (expand-file-name "drawing.excalidraw" directory))
                   (elements ,elements))
               (when elements (portal-excalidraw-gui--write file elements ,files))
               (delete-other-windows)
               (select-frame-set-input-focus (selected-frame))
               (sit-for 0.1)
               (should (portal-view--with-frame-title (selected-frame)
                                                      #'portal-test-native-target-frame))
               (find-file file)
               (setq document (current-buffer))
               (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
               (redisplay t)
               (portal-view-sync)
               ,@body)
           (when (buffer-live-p document)
             (with-current-buffer document
               (portal-excalidraw--close)
               (set-buffer-modified-p nil)
               (kill-buffer document)))
           (portal-test-native-target-frame nil)
           (delete-directory directory t))))))

(defmacro portal-excalidraw-gui--document (&rest body)
  "Run BODY with a new drawing.excalidraw open in `document', its buffer."
  (declare (indent 0))
  `(portal-excalidraw-gui--drawing nil nil ,@body))

;; host/editor.test.ts checks that the editor loads only what the host serves.
(ert-deftest portal-excalidraw-gui-loads-editor-and-saves ()
  :tags '(:gui)
  (portal-excalidraw-gui--document
    (should (equal (portal-excalidraw-gui--js "return !!document.querySelector('.excalidraw canvas')") t))
    (portal-excalidraw-save)
    (should (file-exists-p buffer-file-name))
    (should-not (buffer-modified-p))
    (let ((scene (json-parse-string (buffer-string) :object-type 'plist)))
      (should (equal (plist-get scene :type) "excalidraw"))
      (should (= (length (plist-get scene :elements)) 0)))))

(ert-deftest portal-excalidraw-gui-drawing-survives-hiding-and-reopening ()
  :tags '(:gui)
  (portal-excalidraw-gui--drawing
      (list (portal-excalidraw-gui--text "words" "Portal local drawing")) nil
    (should (string-match-p "Portal local drawing" (buffer-string)))
    (should-not (buffer-modified-p))
    (let ((target (portal-view-target))
          (text (buffer-string)))
      (switch-to-buffer (get-buffer-create " *drawing-hidden*"))
      (redisplay t)
      (portal-view-sync)
      (should-not (plist-get (portal--inspect target) :visible))
      (switch-to-buffer document)
      (redisplay t)
      (portal-view-sync)
      (should (equal target (portal-view-target)))
      (portal-excalidraw--flush)
      (should (equal text (buffer-string)))
      (portal-excalidraw-reopen)
      (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
      (portal-excalidraw--flush)
      (should (string-match-p "Portal local drawing" (buffer-string)))
      (should-not (buffer-modified-p)))))

(ert-deftest portal-excalidraw-gui-revert-reloads-the-saved-drawing ()
  :tags '(:gui)
  (portal-excalidraw-gui--drawing
      (list (portal-excalidraw-gui--text "words" "Opened text")) nil
    (should (string-match-p "Opened text" (buffer-string)))
    ;; Another program saves the file meanwhile.
    (portal-excalidraw-gui--write buffer-file-name
                                  (list (portal-excalidraw-gui--text "words" "Saved text")))
    (revert-buffer nil t)
    (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
    (portal-excalidraw--flush)
    (should (string-match-p "Saved text" (buffer-string)))
    (should-not (string-match-p "Opened text" (buffer-string)))
    (should-not (buffer-modified-p))))

(ert-deftest portal-excalidraw-gui-image-roundtrip-and-document-isolation ()
  :tags '(:gui)
  (portal-excalidraw-gui--drawing
      (list portal-excalidraw-gui--picture) portal-excalidraw-gui--pixel
    (should (string-match-p "data:image/png;base64" (buffer-string)))
    ;; Written to another file, through Emacs, the drawing keeps its image.
    (let ((copy (expand-file-name "copy.excalidraw" directory)))
      (write-file copy)
      (should (equal buffer-file-name copy))
      (should (eq major-mode 'portal-excalidraw-mode))
      (should-not (buffer-modified-p))
      (should (string-match-p "data:image/png;base64"
                              (with-temp-buffer (insert-file-contents copy) (buffer-string)))))
    (let ((original (buffer-string)) other)
      (unwind-protect
          (progn
            (find-file (expand-file-name "other.excalidraw" directory))
            (setq other (current-buffer))
            (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
            (should-not (string-match-p "data:image/png;base64" (buffer-string)))
            (switch-to-buffer document)
            (redisplay t)
            (portal-view-sync)
            (portal-excalidraw-reopen)
            (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
            (portal-excalidraw--flush)
            (should (equal original (buffer-string))))
        (when (buffer-live-p other)
          (with-current-buffer other (portal-excalidraw--close) (set-buffer-modified-p nil))
          (kill-buffer other))))))

(ert-deftest portal-excalidraw-gui-unused-chord-keeps-fast-followup-keys ()
  :tags '(:gui)
  ;; The drawing does not use C-x, so C-x C-s reaches Emacs whole, typed at once.
  (portal-excalidraw-gui--document
    (select-frame-set-input-focus (selected-frame))
    (portal-view-focus)
    (portal-test-native-key 7 (ash 1 18) "\C-x")
    (portal-test-native-key 1 (ash 1 18) "\C-s")
    ;; Exercise the command loop's keymap lookup, not just a direct dispatch.
    (let ((post-command-hook
           (cons (lambda ()
                   (when (eq this-command #'portal-input--dispatch)
                     (exit-recursive-edit)))
                 post-command-hook)))
      (with-timeout (5 (ert-fail "Portal save command stalled"))
        (recursive-edit)))
    (should (file-exists-p buffer-file-name))
    (should-not (buffer-modified-p))
    (should (portal-input--action "focused"))))

(ert-deftest portal-excalidraw-gui-save-commits-active-text-editing ()
  :tags '(:gui)
  (portal-excalidraw-gui--document
    (portal-view-focus)
    (should (portal-excalidraw-gui--js
             "const canvas = document.querySelector('canvas.interactive');
              canvas.dispatchEvent(new MouseEvent('dblclick', {bubbles:true, clientX:250, clientY:200}));
              await new Promise(resolve => setTimeout(resolve, 30));
              const input = document.querySelector('textarea.excalidraw-wysiwyg');
              if (!input) throw new Error('Text editor did not open');
              input.value = 'Uncommitted text'; input.dispatchEvent(new Event('input', {bubbles:true}));
              return document.activeElement === input;"))
    (portal-excalidraw-save)
    (let ((file buffer-file-name))
      (should (string-match-p "Uncommitted text"
                              (with-temp-buffer (insert-file-contents file) (buffer-string)))))
    (should-not (buffer-modified-p))))

(ert-deftest portal-excalidraw-gui-save-button-prompts-for-untitled-file ()
  :tags '(:gui)
  (portal-excalidraw-gui--document
    (portal-excalidraw--close)
    (set-buffer-modified-p nil)
    (kill-buffer document)
    (portal-excalidraw)
    (setq document (current-buffer))
    (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
    (portal-view-focus)
    (portal-excalidraw-gui--js "document.querySelector('.portal-save button').click(); return true;")
    (let* ((notification (with-timeout (5 (ert-fail "Save button did not notify Emacs"))
                           (read-key-sequence-vector nil)))
           (event (aref notification 0))
           (file (expand-file-name "from-button.excalidraw" directory)))
      (should (eq (car-safe event) 'portal-excalidraw-command))
      (let ((use-dialog-box nil) (use-file-dialog nil))
        (minibuffer-with-setup-hook
            (lambda ()
              (delete-minibuffer-contents)
              (insert file)
              (portal-test-native-post-key 36 0 "\r"))
          (with-timeout (5 (ert-fail "Filename prompt did not receive native input"))
            (portal-excalidraw--dispatch event))))
      (should (equal buffer-file-name file))
      (should (file-exists-p file))
      (should-not (buffer-modified-p)))))

(defun portal-excalidraw-gui--frame (id name order x y width height &optional notes)
  "A frame ID called NAME, slide ORDER in its deck, at X Y, WIDTH by HEIGHT.
NOTES are its presenter notes."
  (list :type "frame" :id id :name name :x x :y y :width width :height height
        :customData (append (list :slidesOrder order)
                            (and notes (list :presenterNotes notes)))))

(defun portal-excalidraw-gui--slides ()
  "The slides Arrange shows, each as (NAME SELECTED IMAGED), in order."
  (append (portal-excalidraw-gui--js
           "return [...document.querySelectorAll('.portal-filmstrip [role=option]')].map(slide =>
              [slide.querySelector('.portal-slide-name').value,
               slide.getAttribute('aria-selected') === 'true',
               !!slide.querySelector('img')?.src.startsWith('data:image/svg+xml')]);")
          nil))

(defun portal-excalidraw-gui--key (code flags text)
  "Type the key CODE with FLAGS, which types TEXT, into the page."
  (should (portal-test-native-key code flags text))
  (redisplay t))

(defconst portal-excalidraw-gui--down
  (list 125 (logior (ash 1 23) (ash 1 21)) (string #xF701))
  "The Down arrow, as AppKit reports it: a function key on the keypad.")

(ert-deftest portal-excalidraw-gui-arrange-shows-the-slides-and-edits-one ()
  :tags '(:gui)
  ;; The second slide comes first on the page and is small, so the view the
  ;; drawing opens at is nearest the first.
  (portal-excalidraw-gui--drawing
      (list (portal-excalidraw-gui--frame "closing" "Closing" 1 2000 2000 400 225)
            (portal-excalidraw-gui--frame "opening" "Opening" 0 0 0 1600 900)
            (append (portal-excalidraw-gui--text "hello" "Hello") '(:frameId "opening"))
            (append (portal-excalidraw-gui--text "bye" "Bye") '(:frameId "closing" :x 2050 :y 2050)))
      nil
    (let ((arrange (lambda (enter)
                     (funcall enter)
                     (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "arrange")))
                     (portal-terminal-test--wait
                      (lambda () (equal (portal-excalidraw-gui--js
                                         "return document.hasFocus() && document.querySelectorAll('.portal-filmstrip img').length;")
                                        2)))))
          (draw (lambda () (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "draw")))
                  (should (equal (portal-excalidraw-gui--js
                                  "return !document.querySelector('.portal-arrange') && !document.querySelector('.portal-editor').inert;")
                                 t)))))
      (funcall arrange #'portal-excalidraw-arrange)
      (should (equal (portal-excalidraw-gui--slides)
                     '(["Opening" t t] ["Closing" nil t])))
      (should (string-match-p ":Arrange" (format-mode-line mode-line-process)))
      (should (equal (portal-excalidraw-gui--js
                      "return document.querySelector('.portal-editor').inert;")
                     t))
      (should-not (buffer-modified-p))
      ;; Command-S still saves; the page asks Emacs to.
      (portal-excalidraw-gui--key 1 (ash 1 20) "s")
      (let ((event (aref (with-timeout (5 (ert-fail "Command-S did not reach Emacs"))
                           (read-key-sequence-vector nil))
                         0)))
        (should (equal (car-safe event) 'portal-excalidraw-command))
        (portal-excalidraw--dispatch event))
      (should (equal portal-excalidraw--mode "arrange"))
      (should-not (buffer-modified-p))
      ;; Down selects the second slide, and Return edits it.
      (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--down)
      (portal-terminal-test--wait
       (lambda () (equal (portal-excalidraw-gui--slides) '(["Opening" nil t] ["Closing" t t]))))
      (portal-excalidraw-gui--key 36 0 "\r")
      (funcall draw)
      (should-not (string-match-p "Arrange" (format-mode-line mode-line-process)))
      (should-not (buffer-modified-p))
      ;; The editor shows that slide now, so Arrange, entered from the
      ;; editor's menu, starts at it.
      (funcall arrange
               (lambda ()
                 (should (eq t (portal-excalidraw-gui--js
                  "const button = document.querySelector('.main-menu-trigger');
                   if (!button) return 'no menu button';
                   button.click();
                   for (let tries = 0; tries < 100; tries++) {
                     const item = [...document.querySelectorAll('.dropdown-menu-item')]
                       .find(item => item.textContent.trim() === 'Slides');
                     if (item) { item.click(); return true; }
                     await new Promise(resolve => setTimeout(resolve, 20));
                   }
                   return [...document.querySelectorAll('.dropdown-menu-item')]
                     .map(item => item.textContent.trim());")))))
      (should (equal (portal-excalidraw-gui--slides)
                     '(["Opening" nil t] ["Closing" t t])))
      ;; Escape goes back as it was.
      (portal-excalidraw-gui--key 53 0 "\e")
      (funcall draw)
      (portal-excalidraw--flush)
      (should-not (buffer-modified-p)))))

(defun portal-excalidraw-gui--deck (json)
  "The frames in JSON, a drawing, each as (ID NAME ORDER NOTES), by ORDER."
  (sort (mapcan (lambda (element)
                  (when (equal (plist-get element :type) "frame")
                    (let ((data (plist-get element :customData)))
                      (list (list (plist-get element :id) (plist-get element :name)
                                  (plist-get data :slidesOrder)
                                  (plist-get data :presenterNotes))))))
                (append (plist-get (json-parse-string json :object-type 'plist
                                                      :null-object nil)
                                   :elements)
                        nil))
        (lambda (a b) (< (or (nth 2 a) 99) (or (nth 2 b) 99)))))

(defun portal-excalidraw-gui--buffer-deck (deck)
  "Wait until the buffer's drawing has DECK, as `portal-excalidraw-gui--deck'.
The page sends it on its own; nothing here asks it to."
  (portal-terminal-test--wait
   (lambda () (equal (portal-excalidraw-gui--deck (buffer-string)) deck)))
  (should (equal (portal-excalidraw-gui--deck (buffer-string)) deck)))

(defun portal-excalidraw-gui--focus (selector)
  "Give the field SELECTOR the page's keyboard, its text selected."
  (should (eq t (portal-excalidraw-gui--js
                 (format "const field = document.querySelector(%S);
                          field.spellcheck = false;
                          field.focus(); field.select();
                          return document.activeElement === field;"
                         selector)))))

(defun portal-excalidraw-gui--type (text)
  "Type TEXT, lower-case letters, into the page."
  (dolist (char (string-to-list text))
    (portal-excalidraw-gui--key
     (alist-get char '((?d . 2) (?e . 14) (?h . 4) (?i . 34) (?n . 45))) 0 (string char))))

(defconst portal-excalidraw-gui--option-down
  (list 125 (logior (ash 1 23) (ash 1 21) (ash 1 19)) (string #xF701))
  "Option-Down, as AppKit reports it.")

(defconst portal-excalidraw-gui--command-z (list 6 (ash 1 20) "z")
  "Command-Z.")

(ert-deftest portal-excalidraw-gui-arrange-edits-reach-the-file ()
  :tags '(:gui)
  (portal-excalidraw-gui--drawing
      (list (portal-excalidraw-gui--frame "opening" "Opening" 0 0 0 1600 900 "Welcome")
            (portal-excalidraw-gui--frame "middle" "Middle" 1 2000 0 400 225)
            (portal-excalidraw-gui--frame "closing" "Closing" 2 2000 2000 400 225))
      nil
    (portal-excalidraw-arrange)
    (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "arrange")))
    (portal-terminal-test--wait
     (lambda () (equal (portal-excalidraw-gui--js
                        "return document.hasFocus() && document.querySelectorAll('.portal-filmstrip img').length;")
                       3)))
    ;; The notes saved in the file are shown.
    (should (equal (portal-excalidraw-gui--js
                    "return document.getElementById('portal-notes-text').value;")
                   "Welcome"))
    (should-not (buffer-modified-p))
    ;; Command-Z in the notes box is the box's own undo.
    (let ((notes (lambda () (portal-excalidraw-gui--js
                             "return document.getElementById('portal-notes-text').value;"))))
      (portal-excalidraw-gui--js
       "const box = document.getElementById('portal-notes-text');
        box.spellcheck = false; box.focus(); box.setSelectionRange(7, 7);
        return true;")
      (portal-excalidraw-gui--type "hi")
      (portal-terminal-test--wait (lambda () (equal (funcall notes) "Welcomehi")))
      (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--command-z)
      (portal-terminal-test--wait (lambda () (equal (funcall notes) "Welcome")))
      (portal-excalidraw-gui--key 53 0 "\e"))
    ;; Option-Down moves the first slide down one, and every slide is
    ;; numbered in the new order.
    (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--option-down)
    (portal-excalidraw-gui--buffer-deck
     '(("middle" "Middle" 0 nil) ("opening" "Opening" 1 "Welcome") ("closing" "Closing" 2 nil)))
    (should (buffer-modified-p))
    (should (equal (portal-excalidraw-gui--slides)
                   '(["Middle" nil t] ["Opening" t t] ["Closing" nil t])))
    ;; Dragging the last slide above the first puts it first.
    (let ((points (portal-excalidraw-gui--js
                   "const box = slide => document.getElementById('portal-slide-' + slide)
                                        .querySelector('.portal-slide-image').getBoundingClientRect();
                    const from = box('closing'), to = box('middle');
                    return [from.left + from.width / 2, from.top + from.height / 2,
                            to.left + to.width / 2, to.top + 4].map(Math.round);")))
      (should (apply #'portal-test-native-drag (append points nil))))
    (portal-excalidraw-gui--buffer-deck
     '(("closing" "Closing" 0 nil) ("middle" "Middle" 1 nil) ("opening" "Opening" 2 "Welcome")))
    (portal-terminal-test--wait
     (lambda () (equal (portal-excalidraw-gui--slides)
                       '(["Closing" t t] ["Middle" nil t] ["Opening" nil t]))))
    ;; Notes typed for the second slide are written once typing stops.
    (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--down)
    (portal-terminal-test--wait
     (lambda () (equal (portal-excalidraw-gui--js
                        "return document.getElementById('portal-notes-text').value;")
                       "")))
    (portal-excalidraw-gui--focus "#portal-notes-text")
    (portal-excalidraw-gui--type "hi")
    (portal-excalidraw-gui--buffer-deck
     '(("closing" "Closing" 0 nil) ("middle" "Middle" 1 "hi") ("opening" "Opening" 2 "Welcome")))
    ;; Command-Z in Arrange takes the notes back, and a move at once after it
    ;; does not bring them back.
    (portal-excalidraw-gui--key 53 0 "\e")
    (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--command-z)
    (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--option-down)
    (portal-excalidraw-gui--buffer-deck
     '(("closing" "Closing" 0 nil) ("opening" "Opening" 1 "Welcome") ("middle" "Middle" 2 nil)))
    ;; A slide's name is typed in the filmstrip; Escape drops it, and Return
    ;; writes it.
    (portal-excalidraw-gui--focus "#portal-slide-closing input")
    (portal-excalidraw-gui--type "hi")
    (portal-excalidraw-gui--key 53 0 "\e")
    (portal-terminal-test--wait
     (lambda () (equal (portal-excalidraw-gui--js
                        "return document.querySelector('#portal-slide-closing input').value;")
                       "Closing")))
    (portal-excalidraw-gui--focus "#portal-slide-closing input")
    (portal-excalidraw-gui--type "end")
    (portal-excalidraw-gui--key 36 0 "\r")
    (portal-excalidraw-gui--buffer-deck
     '(("closing" "end" 0 nil) ("opening" "Opening" 1 "Welcome") ("middle" "Middle" 2 nil)))
    (should (equal (portal-excalidraw-gui--js "return document.activeElement.getAttribute('role');") "listbox"))
    ;; Command-Z in Arrange takes back the last edit, the name, and in Draw
    ;; the one before, the move.
    (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--command-z)
    (portal-excalidraw-gui--buffer-deck
     '(("closing" "Closing" 0 nil) ("opening" "Opening" 1 "Welcome") ("middle" "Middle" 2 nil)))
    (should (equal portal-excalidraw--mode "arrange"))
    (portal-excalidraw-gui--key 53 0 "\e")
    (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "draw")))
    (portal-terminal-test--wait
     (lambda () (portal-excalidraw-gui--js
                 "return document.activeElement?.classList.contains('excalidraw-container');")))
    (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--command-z)
    (let ((deck '(("closing" "Closing" 0 nil) ("middle" "Middle" 1 nil)
                  ("opening" "Opening" 2 "Welcome"))))
      (portal-excalidraw-gui--buffer-deck deck)
      ;; Saved, the file has them; reopened in the editor, so does the buffer.
      (portal-excalidraw-save)
      (should-not (buffer-modified-p))
      (let ((file buffer-file-name))
        (should (equal (portal-excalidraw-gui--deck
                        (with-temp-buffer (insert-file-contents file) (buffer-string)))
                       deck)))
      (portal-excalidraw-reopen)
      (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
      (portal-excalidraw--flush)
      (should (equal (portal-excalidraw-gui--deck (buffer-string)) deck))
      (should-not (buffer-modified-p))
      ;; A name still being typed when Emacs leaves Arrange is written.
      (portal-excalidraw-arrange)
      (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "arrange")))
      (portal-terminal-test--wait
       (lambda () (portal-excalidraw-gui--js "return document.hasFocus();")))
      (portal-excalidraw-gui--focus "#portal-slide-closing input")
      (portal-excalidraw-gui--type "end")
      (portal-terminal-test--wait
       (lambda () (equal (portal-excalidraw-gui--js
                          "return document.activeElement.value;")
                         "end")))
      (portal-excalidraw-draw)
      (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "draw")))
      (portal-excalidraw-gui--buffer-deck
       '(("closing" "end" 0 nil) ("middle" "Middle" 1 nil) ("opening" "Opening" 2 "Welcome"))))))

(defconst portal-excalidraw-gui--right
  (list 124 (logior (ash 1 23) (ash 1 21)) (string #xF703))
  "The Right arrow, as AppKit reports it.")

(defun portal-excalidraw-gui--until (predicate)
  "Service events until PREDICATE succeeds, for up to 10 s; return its value.
The 10 s start again when the page stalled meanwhile, as
`portal-excalidraw-gui--js' notes: the time it stood still is not time it
had to get there."
  (let ((start (float-time)) value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) (+ (max start portal-excalidraw-gui--stalled) 10)))
      (accept-process-output nil 0.02)
      (redisplay t))
    value))

(defun portal-excalidraw-gui--in-frame (frame script console)
  "Run SCRIPT in the page FRAME shows, then target frame CONSOLE again."
  (unwind-protect
      (progn
        (should (portal-view--with-frame-title frame #'portal-test-native-target-frame))
        (portal-excalidraw-gui--js script))
    (should (portal-view--with-frame-title console #'portal-test-native-target-frame))))

(defun portal-excalidraw-gui--showing (frame console slide)
  "Wait until the slide window in FRAME, and the console in frame CONSOLE,
show SLIDE of 2."
  (let ((expected (list (format "Slide %d of 2" slide) t t (format "%d / 2" slide)))
        seen)
    (portal-excalidraw-gui--until
     (lambda ()
       (setq seen (append (portal-excalidraw-gui--in-frame
                           frame "const slide = document.getElementById('slide');
                                  if (!slide) return [];  // Still loading.
                                  return [document.title, slide.src.startsWith('blob:'),
                                          slide.complete && slide.naturalWidth > 0];"
                           console)
                          (list (portal-excalidraw-gui--js
                                 "return document.querySelector('.portal-present-count')?.textContent ?? null;"))))
       (equal seen expected)))
    (should (equal seen expected))))

(defun portal-excalidraw-gui--console ()
  "What the console shows beside the slide: the next slide, as \"image\"
once drawn or what it says instead; the notes, their lines kept; and
whether it shows a time of day and the time presenting, as minutes and
seconds."
  (append (portal-excalidraw-gui--js
           "const next = document.querySelector('.portal-present-next-image');
            const image = next?.querySelector('img');
            const notes = document.querySelector('.portal-present-notes-text');
            return [image ? (image.complete && image.naturalWidth > 0 ? 'image' : 'pending')
                          : next?.textContent ?? null,
                    notes?.textContent ?? null,
                    notes ? getComputedStyle(notes).whiteSpace : null,
                    /\\d/.test(document.querySelector('.portal-present-time')?.textContent ?? ''),
                    /^\\d+:\\d\\d$/.test(document.querySelector('.portal-present-elapsed')?.textContent ?? '')];")
          nil))

(defun portal-excalidraw-gui--fit ()
  "How the console draws its slides, once their images are drawn: whether
the current slide fills its stage, less the padding, in one dimension;
whether the next slide fills its box so, or nil at the end; and whether
the current slide is drawn larger than the next, or nil at the end.
A slide is drawn as large as fits its image's box, at its own shape."
  (append (portal-excalidraw-gui--js
           "const drawn = (image) => {
              const box = image.getBoundingClientRect();
              const scale = Math.min(box.width / image.naturalWidth,
                                     box.height / image.naturalHeight);
              return [image.naturalWidth * scale, image.naturalHeight * scale];
            };
            const fills = ([width, height], [boxWidth, boxHeight]) =>
              Math.abs(width - boxWidth) < 1 || Math.abs(height - boxHeight) < 1;
            const stage = document.querySelector('.portal-present-stage');
            const current = stage?.querySelector('img');
            const next = document.querySelector('.portal-present-next-image img');
            if (![current, next].every(image => !image || (image.complete && image.naturalWidth > 0))
                || !current)
              return null;
            const style = getComputedStyle(stage);
            const inner = [stage.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
                           stage.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom)];
            const slide = drawn(current);
            const box = next?.parentElement;
            const following = next && drawn(next);
            return [fills(slide, inner),
                    next ? fills(following, [box.clientWidth, box.clientHeight]) : null,
                    next ? slide[0] > following[0] && slide[1] > following[1] : null];")
          nil))

(defun portal-excalidraw-gui--mode-line (drawing expected)
  "Wait until DRAWING's mode line says EXPECTED, a regexp, and check it."
  (with-current-buffer drawing
    (portal-excalidraw-gui--until
     (lambda () (string-match-p expected (format-mode-line mode-line-process))))
    (should (string-match-p expected (format-mode-line mode-line-process)))))

(ert-deftest portal-excalidraw-gui-presents-in-a-slide-window-and-stops ()
  :tags '(:gui)
  ;; The closing slide's frame is smaller than the console's every space
  ;; for a slide, the opening slide's larger.
  (portal-excalidraw-gui--drawing
      (list (portal-excalidraw-gui--frame "closing" "Closing" 1 2000 2000 160 90)
            (portal-excalidraw-gui--frame "opening" "Opening" 0 0 0 1600 900
                                          "Say hello.\nThen wave.")
            (append (portal-excalidraw-gui--text "hello" "Hello") '(:frameId "opening"))
            (append (portal-excalidraw-gui--text "bye" "Bye")
                    '(:frameId "closing" :x 2020 :y 2020 :width 100)))
      nil
    (let ((main (selected-frame))
          (frames (length (frame-list)))
          (pixelwise frame-resize-pixelwise))
      ;; From the editor, Present starts at the slide nearest the view.
      (portal-excalidraw-present)
      (portal-web-gui--run-until 'portal-web-opened)
      (portal-web-gui--run-until 'portal-excalidraw-command)
      (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "present")))
      (let ((slides portal-excalidraw--slides)
            (frame portal-excalidraw--slides-frame))
        (should (buffer-live-p slides))
        (should (frame-live-p frame))
        (should (= (length (frame-list)) (1+ frames)))
        ;; The slide window's frame is bare: the slide fills it.
        (should-not (eq (window-frame (minibuffer-window frame)) frame))
        (should (eq (window-buffer (frame-root-window frame)) slides))
        (should (= (window-mode-line-height (frame-root-window frame)) 0))
        (should frame-resize-pixelwise)
        ;; The console has the keyboard back.
        (should (eq (selected-frame) main))
        (should (eq (window-buffer) document))
        (portal-excalidraw-gui--mode-line document ":Present 1/2")
        (portal-excalidraw-gui--until
         (lambda () (portal-excalidraw-gui--js "return document.hasFocus();")))
        (should (portal-excalidraw-gui--js "return document.hasFocus();"))
        (portal-excalidraw-gui--showing frame main 1)
        ;; Beside the slide: the next one, the notes and both clocks.
        (let ((expected '("image" "Say hello.\nThen wave." "pre-wrap" t t)))
          (portal-excalidraw-gui--until
           (lambda () (equal (portal-excalidraw-gui--console) expected)))
          (should (equal (portal-excalidraw-gui--console) expected)))
        ;; Each slide is as large as its space allows, whatever its frame's
        ;; size: the next, a small frame, fills its box, and the current
        ;; slide is larger.
        (portal-excalidraw-gui--until
         (lambda () (equal (portal-excalidraw-gui--fit) '(t t t))))
        (should (equal (portal-excalidraw-gui--fit) '(t t t)))
        ;; Next in the console.
        (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--right)
        (portal-excalidraw-gui--showing frame main 2)
        (portal-excalidraw-gui--mode-line document ":Present 2/2")
        (portal-excalidraw-gui--key 115 (ash 1 23) (string #xF729)) ; Home
        (portal-excalidraw-gui--showing frame main 1)
        (portal-excalidraw-gui--mode-line document ":Present 1/2")
        ;; Next and previous from Emacs, by their keys in the drawing's
        ;; buffer: both windows move, and the mode line follows.
        (should (eq (window-buffer) document))
        (execute-kbd-macro (kbd "C-c C-n"))
        (portal-excalidraw-gui--showing frame main 2)
        (portal-excalidraw-gui--mode-line document ":Present 2/2")
        (should (equal (portal-excalidraw-gui--console) '("End" "No notes." "pre-wrap" t t)))
        ;; A small frame fills the stage too.
        (portal-excalidraw-gui--until
         (lambda () (equal (portal-excalidraw-gui--fit) '(t nil nil))))
        (should (equal (portal-excalidraw-gui--fit) '(t nil nil)))
        (execute-kbd-macro (kbd "C-c C-p"))
        (portal-excalidraw-gui--showing frame main 1)
        (portal-excalidraw-gui--mode-line document ":Present 1/2")
        ;; Typed in the console, they reach Emacs too: it leaves those chords.
        (should (portal-view--with-frame-title main #'portal-test-native-target-frame))
        (should (portal-excalidraw-gui--js "return document.hasFocus();"))
        (portal-test-native-key 8 (ash 1 18) "\C-c")
        (portal-test-native-key 45 (ash 1 18) "\C-n")
        (let ((post-command-hook
               (cons (lambda ()
                       (when (eq this-command #'portal-input--dispatch)
                         (exit-recursive-edit)))
                     post-command-hook)))
          (with-timeout (5 (ert-fail "C-c C-n from the console did not reach Emacs"))
            (recursive-edit)))
        (portal-excalidraw-gui--showing frame main 2)
        (portal-excalidraw-gui--mode-line document ":Present 2/2")
        (portal-excalidraw-gui--key 115 (ash 1 23) (string #xF729)) ; Home
        (portal-excalidraw-gui--showing frame main 1)
        ;; Next in the slide window, which passes it to the console's page.
        (select-frame-set-input-focus frame)
        (select-window (frame-root-window frame))
        (portal-view-focus)
        (portal-excalidraw-gui--until
         (lambda () (portal-excalidraw-gui--in-frame frame "return document.hasFocus();" main)))
        (should (portal-excalidraw-gui--in-frame frame "return document.hasFocus();" main))
        (should (portal-view--with-frame-title frame #'portal-test-native-target-frame))
        (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--right)
        (should (portal-view--with-frame-title main #'portal-test-native-target-frame))
        (portal-excalidraw-gui--showing frame main 2)
        ;; Escape there stops: the drawing goes to Arrange at that slide, and
        ;; the slide window and its frame go.
        (should (portal-view--with-frame-title frame #'portal-test-native-target-frame))
        (portal-excalidraw-gui--key 53 0 "\e")
        (with-current-buffer document
          (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "arrange")))
          (should-not (string-match-p "Present\\|/2" (format-mode-line mode-line-process))))
        (should-not (buffer-live-p slides))
        (should-not (frame-live-p frame))
        (should (= (length (frame-list)) frames))
        (should (eq frame-resize-pixelwise pixelwise))
        (portal-web-gui--run-until 'portal-excalidraw-command)
        (should (eq (selected-frame) main))
        (should (portal-view--with-frame-title main #'portal-test-native-target-frame))
        (should (equal (portal-excalidraw-gui--slides)
                       '(["Opening" nil t] ["Closing" t t])))
        (with-current-buffer document
          (portal-excalidraw--flush)
          (should-not (buffer-modified-p)))))))

;; The laser.

(defconst portal-excalidraw-gui--laser-pages
  '((console ".portal-present-stage img" ".portal-present-laser")
    (slides "#slide" "#laser"))
  "Each page's slide image and the laser's layer over it.")

(defun portal-excalidraw-gui--watch-laser (page)
  "The JavaScript that records, from now on, when the laser's first line
shows in PAGE and when it goes, and where it lies on the slide: the
edges of its box in hundredths of the slide as the page draws it."
  (pcase-let ((`(,image ,layer) (alist-get page portal-excalidraw-gui--laser-pages)))
    (format "window.laserWatch?.disconnect();
             const layer = document.querySelector('%s');
             const record = window.laserRecord = {added: null, removed: null, box: null};
             const look = () => {
               const path = layer.querySelector('path');
               if (path) {
                 record.added ??= performance.now();
                 const slide = document.querySelector('%s');
                 const box = slide.getBoundingClientRect();
                 const scale = Math.min(box.width / slide.naturalWidth,
                                        box.height / slide.naturalHeight);
                 const width = slide.naturalWidth * scale, height = slide.naturalHeight * scale;
                 const left = box.left + (box.width - width) / 2;
                 const top = box.top + (box.height - height) / 2;
                 const line = path.getBoundingClientRect();
                 record.box = [(line.left - left) / width, (line.top - top) / height,
                               (line.right - left) / width, (line.bottom - top) / height]
                   .map(edge => Math.round(edge * 100));
               } else if (record.added !== null) record.removed ??= performance.now();
             };
             window.laserWatch = new MutationObserver(look);
             window.laserWatch.observe(layer, {subtree: true, childList: true, attributes: true});
             return true;"
            layer image)))

(defun portal-excalidraw-gui--laser (frame console)
  "What the laser's watch saw in the console, in frame CONSOLE, and the
slide window, in FRAME: for each, whether a line showed, how many
milliseconds later it went or nil, and its box on the slide."
  (let ((script "const record = window.laserRecord;
                 return [record.added !== null,
                         record.removed === null ? null : Math.round(record.removed - record.added),
                         record.box];"))
    (list (append (portal-excalidraw-gui--js script) nil)
          (append (portal-excalidraw-gui--in-frame frame script console) nil))))

(defun portal-excalidraw-gui--drag-laser (frame console)
  "Watch the laser in both pages, then drag across the console's current
slide, from a quarter of its width to three quarters, halfway down. The
console is in frame CONSOLE, the slide window in FRAME."
  (should (portal-excalidraw-gui--in-frame
           frame (portal-excalidraw-gui--watch-laser 'slides) console))
  (should (portal-excalidraw-gui--js (portal-excalidraw-gui--watch-laser 'console)))
  (let ((points (portal-excalidraw-gui--js
                 "const slide = document.querySelector('.portal-present-stage img');
                  const box = slide.getBoundingClientRect();
                  const scale = Math.min(box.width / slide.naturalWidth,
                                         box.height / slide.naturalHeight);
                  const width = slide.naturalWidth * scale, height = slide.naturalHeight * scale;
                  const left = box.left + (box.width - width) / 2;
                  const top = box.top + (box.height - height) / 2;
                  return [left + width / 4, top + height / 2,
                          left + width * 3 / 4, top + height / 2].map(Math.round);")))
    (should (apply #'portal-test-native-drag (append points nil)))))

(defun portal-excalidraw-gui--near (box expected)
  "Whether BOX, edges in hundredths, is within 2 of EXPECTED's."
  (and box (cl-every (lambda (edge want) (<= (abs (- edge want)) 2))
                     (append box nil) expected)))

(ert-deftest portal-excalidraw-gui-laser-shows-in-the-slide-window-and-fades ()
  :tags '(:gui)
  ;; The slides are of different shapes, and neither is the shape of the
  ;; console's stage or of the slide window.
  (portal-excalidraw-gui--drawing
      (list (portal-excalidraw-gui--frame "opening" "Opening" 0 0 0 1600 900)
            (portal-excalidraw-gui--frame "closing" "Closing" 1 0 1000 800 800))
      nil
    (let ((main (selected-frame))
          (saved (portal-excalidraw-gui--file-text (buffer-file-name document))))
      (portal-excalidraw-present)
      (portal-web-gui--run-until 'portal-web-opened)
      (portal-web-gui--run-until 'portal-excalidraw-command)
      (let ((frame portal-excalidraw--slides-frame))
        (portal-excalidraw-gui--key 115 (ash 1 23) (string #xF729)) ; Home
        (portal-excalidraw-gui--showing frame main 1)
        (should (portal-view--with-frame-title main #'portal-test-native-target-frame))
        ;; A line dragged on the console's slide shows in both pages over
        ;; the same part of the slide, though each draws it at its own size.
        (portal-excalidraw-gui--drag-laser frame main)
        (let ((line '(25 50 75 50)) seen)
          (portal-excalidraw-gui--until
           (lambda ()
             (setq seen (portal-excalidraw-gui--laser frame main))
             (cl-every (lambda (page) (portal-excalidraw-gui--near (nth 2 page) line)) seen)))
          (should (portal-excalidraw-gui--near (nth 2 (nth 0 seen)) line))
          (should (portal-excalidraw-gui--near (nth 2 (nth 1 seen)) line))
          ;; Each fades once the pointer lifts and is gone 2 seconds later.
          (portal-excalidraw-gui--until
           (lambda ()
             (setq seen (portal-excalidraw-gui--laser frame main))
             (cl-every (lambda (page) (nth 1 page)) seen)))
          (dolist (page seen)
            (should (car page))
            (should (<= 1800 (nth 1 page) 3500))))
        ;; A line drawn, then a move to the next slide: neither page keeps
        ;; it until it fades.
        (portal-excalidraw-gui--drag-laser frame main)
        (portal-excalidraw-gui--until
         (lambda () (cl-every #'car (portal-excalidraw-gui--laser frame main))))
        (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--right)
        (portal-excalidraw-gui--showing frame main 2)
        (let (seen)
          (portal-excalidraw-gui--until
           (lambda ()
             (setq seen (portal-excalidraw-gui--laser frame main))
             (cl-every (lambda (page) (nth 1 page)) seen)))
          (dolist (page seen)
            (should (car page))
            (should (< (nth 1 page) 1500))))
        (with-current-buffer document (portal-excalidraw-stop-presenting))
        (should-not (frame-live-p frame)))
      ;; None of it touches the drawing.
      (with-current-buffer document
        (portal-excalidraw--flush)
        (should-not (buffer-modified-p))
        (should (equal (portal-excalidraw-gui--file-text (buffer-file-name document))
                       saved))))))

(ert-deftest portal-excalidraw-gui-present-and-stop-at-once-leave-no-slide-window ()
  :tags '(:gui)
  ;; Both reach the page before React draws either screen.
  (portal-excalidraw-gui--drawing
      (list (portal-excalidraw-gui--frame "opening" "Opening" 0 0 0 1600 900))
      nil
    (let ((frames (length (frame-list))))
      (should (eq (portal-excalidraw-gui--js
                   "window.portalBridge.receive({type: 'mode', mode: 'present'});
                    window.portalBridge.receive({type: 'mode', mode: 'arrange'});
                    return true;")
                  t))
      (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "arrange")))
      ;; The window the page opened is closed before Emacs shows it.
      (should-not (seq-find (lambda (event) (eq (car-safe event) 'portal-web-opened))
                            unread-command-events))
      (should (equal (portal-view-buffers 'web) (list document)))
      (should-not portal-excalidraw--slides)
      (should (= (length (frame-list)) frames))
      (portal-excalidraw--flush)
      (should-not (buffer-modified-p)))))

(defun portal-excalidraw-gui--shades-script (selector)
  "A script returning the shades of the slide image SELECTOR finds, once
it is drawn: at its bottom right, the drawing's background, and at its top
left, where `portal-excalidraw-gui--picture' is, each \"dark\", \"light\"
or the colour between."
  ;; willReadFrequently keeps the canvas in software.  It is only ever read,
  ;; and from the default canvas WebKit throws InvalidStateError on GitHub's
  ;; runners, macOS 27.0.1, for either window's image, every time.
  (format "const slide = document.querySelector(%S);
           if (!slide?.complete || !slide.naturalWidth) return null;
           const canvas = document.createElement('canvas');
           [canvas.width, canvas.height] = [slide.naturalWidth, slide.naturalHeight];
           const context = canvas.getContext('2d', { willReadFrequently: true });
           context.drawImage(slide, 0, 0);
           const shade = (x, y) => {
             const [r, g, b] = context.getImageData(
               Math.floor(x * canvas.width), Math.floor(y * canvas.height), 1, 1).data;
             const light = (r + g + b) / 3;
             return light < 64 ? 'dark' : light > 192 ? 'light' : `${r},${g},${b}`;
           };
           return [shade(0.75, 0.75), shade(0.1, 0.15)];"
          selector))

(defun portal-excalidraw-gui--shades (selector)
  "The shades of the slide image SELECTOR finds in the page, as
`portal-excalidraw-gui--shades-script' says."
  (append (portal-excalidraw-gui--js (portal-excalidraw-gui--shades-script selector))
          nil))

(defun portal-excalidraw-gui--slides-in (frame console expected)
  "Wait until the slide window in FRAME and the console in frame CONSOLE
show EXPECTED: the shades of each one's slide, then the console's switch's
label; and check it."
  (let (seen)
    (portal-excalidraw-gui--until
     (lambda ()
       (equal expected
              (setq seen
                    (list (append (portal-excalidraw-gui--in-frame
                                   frame (portal-excalidraw-gui--shades-script "#slide")
                                   console)
                                  nil)
                          (portal-excalidraw-gui--shades ".portal-present-stage img")
                          (portal-excalidraw-gui--js
                           "return document.querySelector('.portal-present-theme')?.textContent ?? null;"))))))
    (should (equal seen expected))))

(ert-deftest portal-excalidraw-gui-slides-follow-the-appearance-and-the-switch ()
  :tags '(:gui)
  ;; A white picture in the first slide: it stays white in a dark slide.
  (portal-excalidraw-gui--drawing
      (list (portal-excalidraw-gui--frame "opening" "Opening" 0 0 0 320 180)
            (append portal-excalidraw-gui--picture '(:frameId "opening"))
            (portal-excalidraw-gui--frame "closing" "Closing" 1 0 400 160 90))
      portal-excalidraw-gui--pixel
    (let ((main (selected-frame))
          (appearance portal-web-appearance)
          (saved (with-temp-buffer
                   (insert-file-contents (buffer-file-name document))
                   (buffer-string))))
      (unwind-protect
          (progn
            ;; The page is dark, so the slides are.
            (setq portal-web-appearance 'dark)
            (portal-excalidraw-present)
            (portal-web-gui--run-until 'portal-web-opened)
            (portal-web-gui--run-until 'portal-excalidraw-command)
            (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "present")))
            (let ((frame portal-excalidraw--slides-frame)
                  (count "return document.querySelector('.portal-present-count').textContent;"))
              (portal-excalidraw-gui--key 115 (ash 1 23) (string #xF729)) ; Home
              (portal-excalidraw-gui--slides-in
               frame main '(("dark" "light") ("dark" "light") "Light slides"))
              ;; The switch, reached with Option-Tab, as WebKit reaches a
              ;; button unless macOS's keyboard navigation is on, makes them
              ;; light with Space, in both windows at once, and then dark
              ;; again with Return; it moves no slide.
              (dolist (key '((49 " " ("light" "light") "Dark slides")
                             (36 "\r" ("dark" "light") "Light slides")))
                (portal-excalidraw-gui--key 48 (ash 1 19) "\t")
                (portal-excalidraw-gui--until
                 (lambda () (portal-excalidraw-gui--js
                             "return document.activeElement?.className === 'portal-present-theme';")))
                (should (portal-excalidraw-gui--js
                         "return document.activeElement?.className === 'portal-present-theme';"))
                (portal-excalidraw-gui--key (nth 0 key) 0 (nth 1 key))
                (portal-excalidraw-gui--slides-in
                 frame main (list (nth 2 key) (nth 2 key) (nth 3 key)))
                (should (equal (portal-excalidraw-gui--js count) "1 / 2")))
              ;; The console has the keyboard back: Space shows the next slide.
              (portal-excalidraw-gui--key 49 0 " ")
              (portal-excalidraw-gui--until
               (lambda () (equal (portal-excalidraw-gui--js count) "2 / 2")))
              (should (equal (portal-excalidraw-gui--js count) "2 / 2"))
              (portal-excalidraw-gui--key 115 (ash 1 23) (string #xF729)) ; Home
              ;; Chosen, the theme outlasts a change of the page's appearance.
              (setq portal-web-appearance 'light)
              (portal-excalidraw-gui--until
               (lambda () (not (portal-excalidraw-gui--js
                                "return matchMedia('(prefers-color-scheme: dark)').matches;"))))
              (sit-for 0.5)
              (portal-excalidraw-gui--slides-in
               frame main '(("dark" "light") ("dark" "light") "Light slides"))
              ;; Arrange shows the slides the console chose.
              (with-current-buffer document (portal-excalidraw-stop-presenting))
              (portal-excalidraw--wait (lambda () (equal portal-excalidraw--mode "arrange")))
              (should-not (frame-live-p frame))
              (portal-excalidraw-gui--until
               (lambda () (equal (portal-excalidraw-gui--shades ".portal-stage-image img")
                                 '("dark" "light"))))
              (should (equal (portal-excalidraw-gui--shades ".portal-stage-image img")
                             '("dark" "light")))))
        (setq portal-web-appearance appearance))
      ;; None of it touches the drawing.
      (with-current-buffer document
        (portal-excalidraw--flush)
        (should-not (buffer-modified-p))
        (should (equal (with-temp-buffer
                         (insert-file-contents (buffer-file-name document))
                         (buffer-string))
                       saved))))))

(defun portal-excalidraw-gui--page-size (frame console)
  "The size of the page the slide window in FRAME shows, as [WIDTH HEIGHT]."
  (portal-excalidraw-gui--in-frame frame "return [innerWidth, innerHeight];" console))

(ert-deftest portal-excalidraw-gui-slide-window-fills-the-display-and-draws-covered ()
  :tags '(:gui :expensive)
  (portal-excalidraw-gui--drawing
      (list (portal-excalidraw-gui--frame "opening" "Opening" 0 0 0 1600 900)
            (portal-excalidraw-gui--frame "closing" "Closing" 1 0 1000 1600 900))
      nil
    (let ((main (selected-frame)))
      (portal-excalidraw-present)
      (portal-web-gui--run-until 'portal-web-opened)
      (portal-web-gui--run-until 'portal-excalidraw-command)
      (let ((frame portal-excalidraw--slides-frame))
        (portal-excalidraw-gui--showing frame main 1)
        ;; Covered by another frame, the slide window still draws the slide
        ;; it is sent: a call app sharing it shows what it draws.
        (let ((cover (make-frame '((name . "Cover") (left . 0) (top . 0)
                                   (width . 400) (height . 200) (user-position . t)))))
          (unwind-protect
              (progn
                ;; It shows no web view, or the drawing's would move there.
                (set-window-buffer (frame-root-window cover) (get-buffer-create "*scratch*"))
                (select-frame-set-input-focus cover)
                (raise-frame cover)
                (sit-for 1)
                (select-frame-set-input-focus main)
                (raise-frame cover)
                ;; The console's Next button, which leaves the windows as they are.
                (should (eq (portal-excalidraw-gui--js
                             "const next = [...document.querySelectorAll('.portal-present button')]
                                .find(button => button.textContent === 'Next');
                              next.click();
                              return true;")
                            t))
                (portal-excalidraw-gui--showing frame main 2)
                (should (equal (portal-excalidraw-gui--in-frame
                                frame "return document.visibilityState;" main)
                               "visible")))
            (delete-frame cover)))
        ;; Fullscreen, it fills the display to the pixel, and so does its page.
        (let ((before (portal-excalidraw-gui--page-size frame main))
              (display (alist-get 'geometry (frame-monitor-attributes frame))))
          (select-frame-set-input-focus frame)
          (toggle-frame-fullscreen frame)
          (let ((expected (list 'fullboth (nth 2 display) (nth 3 display)
                                (vector (nth 2 display) (nth 3 display))))
                seen)
            (portal-excalidraw-gui--until
             (lambda ()
               (equal expected
                      (setq seen (list (frame-parameter frame 'fullscreen)
                                       (frame-pixel-width frame) (frame-pixel-height frame)
                                       (portal-excalidraw-gui--page-size frame main))))))
            (should (equal seen expected)))
          ;; macOS ignores a toggle while its animation runs.
          (let ((deadline (+ (float-time) 3)))
            (while (< (float-time) deadline)
              (accept-process-output nil 0.05)
              (redisplay t)))
          (select-frame-set-input-focus frame)
          (toggle-frame-fullscreen frame)
          ;; Nothing touches the frame while its animation runs: retitling
          ;; it to target it, and running a script in its page, every few
          ;; milliseconds then aborted Emacs in the VM.
          (portal-excalidraw-gui--until
           (lambda () (null (frame-parameter frame 'fullscreen))))
          (let ((deadline (+ (float-time) 3)))
            (while (< (float-time) deadline)
              (accept-process-output nil 0.05)
              (redisplay t)))
          (should (equal (list (frame-parameter frame 'fullscreen)
                               (portal-excalidraw-gui--page-size frame main))
                         (list nil before)))
          (select-frame-set-input-focus main))
        (with-current-buffer document (portal-excalidraw-stop-presenting))
        (should-not (frame-live-p frame))))))

;; The scratch drawing.

(defun portal-excalidraw-gui--rectangles (json)
  "How many rectangles drawing JSON holds, or nil when JSON is nil."
  (when json
    (cl-count-if (lambda (element)
                   (and (equal (plist-get element :type) "rectangle")
                        (not (plist-get element :isDeleted))))
                 (plist-get (json-parse-string json :object-type 'plist
                                               :false-object nil :null-object nil)
                            :elements))))

(defun portal-excalidraw-gui--file-text (file)
  "FILE's text, or nil when it is missing."
  (when (file-exists-p file)
    (with-temp-buffer (insert-file-contents file) (buffer-string))))

(defun portal-excalidraw-gui--draw-rectangle (x1 y1 x2 y2)
  "Draw a rectangle from X1 Y1 to X2 Y2 in the page, with the mouse."
  (should (portal-excalidraw-gui--js
           "document.querySelector('[data-testid=toolbar-rectangle]').click(); return true;"))
  (should (portal-test-native-drag x1 y1 x2 y2)))

(ert-deftest portal-excalidraw-gui-scratch-keeps-its-drawing-and-asks-nothing ()
  :tags '(:gui)
  (skip-unless (eq window-system 'ns))
  (save-window-excursion
    (let* ((directory (make-temp-file "portal-scratch-gui-" t))
           (file (expand-file-name "portal/scratch.excalidraw" directory))
           (portal-excalidraw-scratch-file file)
           (before (get-buffer-create "*before scratch*"))
           scratch)
      (unwind-protect
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (ert-fail prompt)))
                    ((symbol-function 'y-or-n-p) (lambda (prompt) (ert-fail prompt)))
                    ((symbol-function 'kill-buffer--possibly-save)
                     (lambda (_) (ert-fail "Asked before killing the scratch drawing"))))
            (delete-other-windows)
            (switch-to-buffer before)
            (select-frame-set-input-focus (selected-frame))
            (sit-for 0.1)
            (should (portal-view--with-frame-title (selected-frame)
                                                   #'portal-test-native-target-frame))
            ;; The command shows it here, ready to draw in.
            (portal-excalidraw-scratch)
            (setq scratch (current-buffer))
            (should (eq (window-buffer) scratch))
            (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
            (portal-view-sync)
            (should (portal-excalidraw-gui--until
                     (lambda () (portal-input-focused-p scratch))))
            ;; Each rectangle is in the file within a second.
            (dolist (shape '((1 (150 150 250 220)) (2 (300 150 400 220))))
              (apply #'portal-excalidraw-gui--draw-rectangle (cadr shape))
              (let ((deadline (+ (float-time) 1)))
                (while (and (not (eql (portal-excalidraw-gui--rectangles
                                       (portal-excalidraw-gui--file-text file))
                                      (car shape)))
                            (< (float-time) deadline))
                  (accept-process-output nil 0.02)))
              (should (eql (portal-excalidraw-gui--rectangles
                            (portal-excalidraw-gui--file-text file))
                           (car shape))))
            (should-not (buffer-modified-p scratch))
            ;; Put away, the window shows what it did, and Emacs has the keyboard.
            (let ((target (portal-view-target)))
              (portal-excalidraw-scratch)
              (redisplay t)
              (portal-view-sync)
              (should (eq (window-buffer) before))
              (should-not (plist-get (portal--inspect target) :visible))
              (should (portal-excalidraw-gui--until
                       (lambda () (not (portal-input-focused-p scratch)))))
              ;; Shown again, it is the same page, with its undo history.
              (portal-excalidraw-scratch)
              (should (eq (window-buffer) scratch))
              (should (equal (portal-view-target) target))
              (portal-terminal-test--wait
               (lambda () (portal-excalidraw-gui--js "return document.hasFocus();")))
              (apply #'portal-excalidraw-gui--key portal-excalidraw-gui--command-z)
              (should (portal-excalidraw-gui--until
                       (lambda () (eql (portal-excalidraw-gui--rectangles
                                        (portal-excalidraw-gui--file-text file))
                                       1)))))
            ;; Killed and shown again, it comes from the file.
            (kill-buffer scratch)
            (should-not (buffer-live-p scratch))
            (portal-excalidraw-scratch)
            (setq scratch (current-buffer))
            (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
            (portal-excalidraw--flush)
            (should (eql (portal-excalidraw-gui--rectangles (buffer-string)) 1))
            (should-not (buffer-modified-p)))
        (when (buffer-live-p scratch)
          (with-current-buffer scratch
            (portal-excalidraw--close)
            (set-buffer-modified-p nil)
            (kill-buffer scratch)))
        (kill-buffer before)
        (portal-test-native-target-frame nil)
        (delete-directory directory t)))))

(provide 'portal-excalidraw-gui-tests)
