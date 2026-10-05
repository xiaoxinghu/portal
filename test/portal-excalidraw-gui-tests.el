;;; portal-excalidraw-gui-tests.el --- Real WKWebView drawing checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-gui-testing)
(declare-function portal-test-native-target-frame "test-terminal-input" (title))

(ert-deftest portal-excalidraw-gui-loads-offline-editor-and-saves ()
  (portal-excalidraw-gui--document
    (should (equal (portal-excalidraw-gui--js "return !!document.querySelector('.excalidraw canvas')") t))
    (should (equal (portal-excalidraw-gui--js
                    "try { await fetch('https://example.com/'); return false; } catch { return true; }") t))
    (should (equal (portal-excalidraw-gui--js
                    "await document.fonts.load('20px Excalifont'); return document.fonts.check('20px Excalifont');") t))
    (portal-excalidraw-save)
    (should (file-exists-p buffer-file-name))
    (should-not (buffer-modified-p))
    (let ((scene (json-parse-string (buffer-string) :object-type 'plist)))
      (should (equal (plist-get scene :type) "excalidraw"))
      (should (= (length (plist-get scene :elements)) 0)))))

(ert-deftest portal-excalidraw-gui-edits-survive-hiding-and-reopening ()
  (portal-excalidraw-gui--document
    ;; Paste goes through Excalidraw's normal clipboard import and history.
    (portal-view-focus)
    (portal-excalidraw-gui--js
     "const container = document.querySelector('.excalidraw'); container.focus();
      const data = new DataTransfer(); data.setData('text/plain', 'Portal local drawing');
      container.dispatchEvent(new ClipboardEvent('paste', {bubbles: true, clipboardData: data})); return true;")
    (portal-terminal-test--wait (lambda () (string-match-p "Portal local drawing" (buffer-string))))
    (should (buffer-modified-p))
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
      (portal-excalidraw-save)
      (should-not (buffer-modified-p))
      (portal-excalidraw-reopen)
      (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
      (portal-excalidraw--flush)
      (should (string-match-p "Portal local drawing" (buffer-string)))
      (should-not (buffer-modified-p)))))

(ert-deftest portal-excalidraw-gui-revert-reloads-the-saved-drawing ()
  (portal-excalidraw-gui--document
    (portal-excalidraw-save)
    (portal-view-focus)
    (portal-excalidraw-gui--js
     "const container = document.querySelector('.excalidraw'); container.focus();
      const data = new DataTransfer(); data.setData('text/plain', 'Unsaved text');
      container.dispatchEvent(new ClipboardEvent('paste', {bubbles: true, clipboardData: data})); return true;")
    (portal-terminal-test--wait (lambda () (string-match-p "Unsaved text" (buffer-string))))
    (should (buffer-modified-p))
    (revert-buffer nil t)
    (portal-excalidraw--wait (lambda () portal-excalidraw--ready))
    (portal-excalidraw--flush)
    (should-not (string-match-p "Unsaved text" (buffer-string)))
    (should-not (buffer-modified-p))))

(ert-deftest portal-excalidraw-gui-image-roundtrip-and-document-isolation ()
  (portal-excalidraw-gui--document
    (portal-view-focus)
    (portal-excalidraw-gui--js
     "const container = document.querySelector('.excalidraw'); container.focus();
      const image = {id:'picture', type:'image', x:0, y:0, width:64, height:64,
        angle:0, strokeColor:'transparent', backgroundColor:'transparent', fillStyle:'solid',
        strokeWidth:1, strokeStyle:'solid', roughness:0, opacity:100, groupIds:[],
        seed:1, version:1, versionNonce:1, isDeleted:false, boundElements:null,
        updated:1, link:null, locked:false, fileId:'pixel', scale:[1,1], status:'saved'};
      const files = {pixel:{id:'pixel', mimeType:'image/png', created:1,
        dataURL:'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII='}};
      const data = new DataTransfer();
      data.setData('text/plain', JSON.stringify({type:'excalidraw/clipboard', elements:[image], files}));
      container.dispatchEvent(new ClipboardEvent('paste', {bubbles:true, clipboardData:data})); return true;")
    (portal-terminal-test--wait (lambda () (string-match-p "data:image/png;base64" (buffer-string))))
    (portal-excalidraw-save)
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
