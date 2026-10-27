;;; portal-excalidraw-gui-tests.el --- Real WKWebView drawing checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal)
(require 'portal-terminal-tests)
(declare-function portal-test-web-eval "test-terminal-input" (script))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))

(defun portal-excalidraw-gui--js (script)
  "Run SCRIPT in the actual webview, returning its result.
JavaScript's false and null are nil."
  (should (portal-test-web-eval script))
  (portal-terminal-test--wait (lambda () (portal-test-web-eval nil)))
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
                     :dataURL "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII="))
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

(provide 'portal-excalidraw-gui-tests)
