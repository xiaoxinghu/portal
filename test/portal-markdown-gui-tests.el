;;; portal-markdown-gui-tests.el --- Markdown preview navigation in real WebKit -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Previews run on the real app host from ./build.sh.  Load the other
;; graphical suites and the test-only event injector first.
(require 'portal-input-gui-tests)
(declare-function portal-test-native-click "test-terminal-input" (x y))

(defvar portal-markdown-gui--directory nil "The current test's Markdown folder.")

(defmacro portal-markdown-gui--documents (&rest body)
  "Run BODY with the README preview of a folder of linked documents.
The folder is `portal-markdown-gui--directory'."
  (declare (indent 0))
  `(portal-test--with-web
     (skip-unless (file-executable-p (portal-server-program-file)))
     (let ((portal-markdown-gui--directory (make-temp-file "portal-markdown-gui-" t))
           (display-buffer-alist nil))
       (unwind-protect
           (progn
             (portal-markdown-gui--write
              "README.md"
              (concat "# Read me\n\n[Source](<src/main file.ts#L42>)\n\n"
                      (mapconcat (lambda (n) (format "Paragraph %d.\n\n" n)) (number-sequence 1 150))
                      "[Architecture](<docs é/arch notes.md>) [Decisions](<docs é/arch notes.md#decisions>) "
                      "[Other](other.md) [Missing](missing.md) [Picture](pic.png) [Folder](src/)\n\n"
                      "![Inline](pic.png)\n"))
             (portal-markdown-gui--write
              "docs é/arch notes.md"
              (concat "# Arch\n\n[Up](../README.md)\n\n"
                      (mapconcat (lambda (n) (format "Detail %d.\n\n" n)) (number-sequence 1 150))
                      "## Decisions\n\nChosen.\n"))
             (portal-markdown-gui--write "other.md" "# Other\n")
             (portal-markdown-gui--write
              "src/main file.ts"
              (mapconcat (lambda (n) (format "// line %d\n" n)) (number-sequence 1 60)))
             (let ((coding-system-for-write 'binary))
               (write-region (base64-decode-string
                              "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII=")
                             nil (portal-markdown-gui--file "pic.png")))
             (select-frame-set-input-focus (selected-frame))
             (sit-for 0.1)
             (should (portal-view--with-frame-title (selected-frame)
                                                    #'portal-test-native-target-frame))
             (portal-render-markdown (portal-markdown-gui--file "README.md"))
             (portal-test--wait-for-page "README.md")
             ,@body)
         (portal-test-native-target-frame nil)
         (setq unread-command-events nil)
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer)
                      (file-in-directory-p (buffer-file-name buffer) portal-markdown-gui--directory))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))
         (dolist (buffer (buffer-list))
           (when (and (eq (buffer-local-value 'major-mode buffer) 'dired-mode)
                      (file-in-directory-p (buffer-local-value 'default-directory buffer)
                                           portal-markdown-gui--directory))
             (kill-buffer buffer)))
         (delete-directory portal-markdown-gui--directory t)))))

(defun portal-markdown-gui--file (name)
  "Return file NAME in the test folder."
  (expand-file-name name portal-markdown-gui--directory))

(defun portal-markdown-gui--write (name text)
  "Write TEXT to file NAME in the test folder, creating its directory."
  (let ((file (portal-markdown-gui--file name)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))))

(defun portal-markdown-gui--link (text)
  "Follow the preview's link with TEXT as a page script would."
  (portal-excalidraw-gui--js
   (format "[...document.links].find(a => a.textContent === %S).click(); return true;" text)))

(defun portal-markdown-gui--link-point (text)
  "Scroll the preview's link with TEXT into view and return where to click it."
  (portal-excalidraw-gui--js
   (format "const a = [...document.links].find(a => a.textContent === %S);
            a.scrollIntoView({block: 'center'}); const r = a.getBoundingClientRect();
            return [Math.round(r.left + 3), Math.round(r.top + r.height / 2)];" text)))

(defun portal-markdown-gui--click-link (text)
  "Click the preview's link with TEXT with the real mouse."
  (let ((point (portal-markdown-gui--link-point text)))
    (should (portal-test-native-click (aref point 0) (aref point 1)))))

(defun portal-markdown-gui--scroll ()
  "Return the preview's vertical scroll position."
  (portal-excalidraw-gui--js "return Math.round(window.scrollY);"))

(defun portal-markdown-gui--event (type)
  "Read the next queued native event, which must be TYPE, and run its command."
  (let ((event (aref (with-timeout (5 (ert-fail (format "No %s event" type)))
                       (read-key-sequence-vector nil))
                     0)))
    (should (eq (car-safe event) type))
    (funcall (lookup-key global-map (vector type)) event)))

(ert-deftest portal-markdown-gui-links-go-back-and-forward-with-reading-position ()
  :tags '(:gui)
  (portal-markdown-gui--documents
    (let ((preview (current-buffer)))
      (portal-excalidraw-gui--js "window.scrollTo(0, 1200); return true;")
      (should (= (portal-markdown-gui--scroll) 1200))
      (portal-markdown-gui--link "Architecture")
      (portal-test--wait-for-page "arch notes.md")
      ;; Emacs renames the buffer once it reads the view's new address,
      ;; which can come just after the page reports its title.
      (portal-terminal-test--wait
       (lambda () (equal (buffer-name preview) "*portal: arch notes.md*")))
      (portal-excalidraw-gui--js "window.scrollTo(0, 700); return true;")
      ;; Relative links resolve from the new document's folder.
      (should (portal-excalidraw-gui--js
               "return [...document.links].find(a => a.textContent === 'Up').href.endsWith('README.md');"))
      (call-interactively (key-binding "l"))
      (portal-test--wait-for-page "README.md")
      (portal-terminal-test--wait
       (lambda () (equal (buffer-name preview) "*portal: README.md*")))
      (portal-terminal-test--wait (lambda () (= (portal-markdown-gui--scroll) 1200)))
      (call-interactively (key-binding "r"))
      (portal-test--wait-for-page "arch notes.md")
      (portal-terminal-test--wait (lambda () (= (portal-markdown-gui--scroll) 700)))
      ;; g rereads the file on screen.
      (portal-markdown-gui--write "docs é/arch notes.md" "# Rewritten\n")
      (call-interactively (key-binding "g"))
      (portal-terminal-test--wait
       (lambda () (equal (portal-excalidraw-gui--js "return document.querySelector('h1')?.textContent;")
                         "Rewritten")))
      (should (equal (buffer-name preview) "*portal: arch notes.md*"))
      ;; A new link after going back discards the old forward branch.
      (portal-web-back)
      (portal-test--wait-for-page "README.md")
      (portal-markdown-gui--link "Other")
      (portal-test--wait-for-page "other.md")
      ;; A heading fragment scrolls to the heading; lookup by file still works.
      (portal-web-back)
      (portal-test--wait-for-page "README.md")
      (portal-markdown-gui--link "Decisions")
      (portal-test--wait-for-page "arch notes.md")
      (portal-markdown-gui--write "docs é/arch notes.md"
                                  (concat "# Arch\n\n"
                                          (mapconcat (lambda (n) (format "Detail %d.\n\n" n))
                                                     (number-sequence 1 150))
                                          "## Decisions\n"))
      (call-interactively (key-binding "g"))
      (portal-test--wait-for-page "arch notes.md")
      (portal-web-back)
      (portal-test--wait-for-page "README.md")
      (portal-markdown-gui--link "Decisions")
      (portal-test--wait-for-page "arch notes.md")
      (portal-terminal-test--wait (lambda () (> (portal-markdown-gui--scroll) 1000)))
      (switch-to-buffer "*scratch*")
      (portal-render-markdown (portal-markdown-gui--file "docs é/arch notes.md"))
      (should (eq (current-buffer) preview))
      ;; A missing document shows the host's error page, and Back recovers.
      (portal-web-back)
      (portal-test--wait-for-page "README.md")
      (portal-markdown-gui--link "Missing")
      (portal-test--wait-for-page "Markdown preview unavailable")
      (should (string-match-p "could not be found"
                              (portal-excalidraw-gui--js "return document.body.innerText;")))
      (portal-web-back)
      (portal-test--wait-for-page "README.md"))))

(ert-deftest portal-markdown-gui-source-links-hand-off-and-return ()
  :tags '(:gui)
  (portal-markdown-gui--documents
    (let* ((preview (current-buffer))
           (target (portal-view-target))
           (origin (selected-window)))
      (portal-excalidraw-gui--js "window.marker = 'kept'; return true;")
      ;; Going back leaves a forward branch, which Emacs handoffs keep.
      (portal-markdown-gui--link "Other")
      (portal-test--wait-for-page "other.md")
      (portal-web-back)
      (portal-test--wait-for-page "README.md")
      (portal-excalidraw-gui--js "window.marker = 'kept'; return true;")
      ;; The preview has the keyboard; one click hands the file to Emacs.
      (portal-input-focus)
      (should (portal-input--action "focused" target))
      (portal-markdown-gui--click-link "Source")
      (portal-markdown-gui--event 'portal-web-follow)
      (should (equal buffer-file-name (portal-markdown-gui--file "src/main file.ts")))
      (should (= (line-number-at-pos) 42))
      (should-not (eq (selected-window) origin))
      (should (eq (window-buffer origin) preview))
      (should-not (portal-input--action "focused" target))
      (portal-integration-test--emacs-input)
      (let ((source-window (selected-window))
            (scroll (portal-markdown-gui--scroll)))
        (should (portal-test--shown target origin))
        ;; Clicking the preview selects its pane and gives it the keyboard.
        (portal-test-native-click 300 5)
        (portal-markdown-gui--event 'portal-input-select)
        (should (eq (selected-window) origin))
        (should (portal-input--action "focused" target))
        (should (= (portal-markdown-gui--scroll) scroll))
        ;; Command-period still returns to Emacs.
        (portal-test-native-key 47 (ash 1 20) ".")
        (should-not (portal-input--action "focused" target))
        (portal-integration-test--emacs-input)
        ;; Return from among other source buffers, without reloading.
        (select-window source-window)
        (find-file (portal-markdown-gui--file "docs é/arch notes.md"))
        (find-file (portal-markdown-gui--file "src/main file.ts"))
        (portal-render-return)
        (should (eq (selected-window) origin))
        (should (portal-input--action "focused" target))
        (should (= (portal-markdown-gui--scroll) scroll))
        (should (equal (portal-excalidraw-gui--js "return window.marker;") "kept"))
        ;; RET re-enters after Command-period.
        (portal-test-native-key 47 (ash 1 20) ".")
        (should-not (portal-input--action "focused" target))
        (call-interactively (key-binding (kbd "RET")))
        (should (portal-input--action "focused" target))
        ;; Images and folders open in their usual modes.
        (portal-markdown-gui--click-link "Picture")
        (portal-markdown-gui--event 'portal-web-follow)
        (should (eq major-mode 'image-mode))
        (should (eq (selected-window) source-window))
        (select-window origin)
        (portal-markdown-gui--click-link "Folder")
        (portal-markdown-gui--event 'portal-input-select)
        (portal-markdown-gui--event 'portal-web-follow)
        (should (eq major-mode 'dired-mode))
        (should (equal (portal-excalidraw-gui--js "return window.marker;") "kept"))))))

(ert-deftest portal-markdown-gui-link-click-ends-a-pending-sequence ()
  :tags '(:gui)
  (portal-markdown-gui--documents
    (let ((target (portal-view-target))
          (point (portal-markdown-gui--link-point "Source")))
      (portal-input-focus)
      ;; The page does not use C-x, so Emacs reads a key sequence from it.
      (portal-test-native-key 7 (ash 1 18) "\C-x")
      (let ((event (aref (with-timeout (5 (ert-fail "No key event"))
                           (read-key-sequence-vector nil))
                         0)))
        (should (eq (car-safe event) 'portal-input-key))
        ;; The click comes while Emacs reads the rest of the sequence.
        (run-at-time 0.2 nil (lambda () (portal-test-native-click (aref point 0) (aref point 1))))
        (with-timeout (5 (ert-fail "The click did not end the sequence"))
          (portal-input--dispatch event)))
      (should-not (portal-input--action "pending" target))
      (portal-markdown-gui--event 'portal-input-select)
      (portal-markdown-gui--event 'portal-web-follow)
      (should (equal buffer-file-name (portal-markdown-gui--file "src/main file.ts")))
      (should-not (portal-input--action "focused" target)))))

(ert-deftest portal-markdown-gui-open-in-emacs-edits-the-file-on-screen ()
  :tags '(:gui)
  (portal-markdown-gui--documents
    (let ((target (portal-view-target))
          (origin (selected-window)))
      (portal-markdown-gui--link "Architecture")
      (portal-test--wait-for-page "arch notes.md")
      (portal-web-back)
      (portal-test--wait-for-page "README.md")
      (portal-input-focus)
      (portal-render-open-in-emacs)
      (should (equal buffer-file-name (portal-markdown-gui--file "README.md")))
      (should-not (portal-input--action "focused" target))
      (portal-integration-test--emacs-input)
      (portal-render-return)
      (should (eq (selected-window) origin))
      (portal-web-forward)
      (portal-test--wait-for-page "arch notes.md")
      (portal-terminal-test--wait (lambda () (equal (buffer-name) "*portal: arch notes.md*")))
      (portal-render-open-in-emacs)
      (should (equal buffer-file-name (portal-markdown-gui--file "docs é/arch notes.md"))))))

;; Emacs frames may force an appearance of their own; previews follow the system's.
(ert-deftest portal-markdown-gui-appearance-follows-the-system-or-the-option ()
  :tags '(:gui)
  (let ((original portal-web-appearance)
        (frame-appearance (frame-parameter nil 'ns-appearance))
        (system-dark (equal (string-trim
                             (shell-command-to-string "defaults read -g AppleInterfaceStyle 2>/dev/null"))
                            "Dark")))
    (unwind-protect
        (progn
          (setq portal-web-appearance nil)
          (modify-frame-parameters nil `((ns-appearance . ,(if system-dark 'light 'dark))))
          (portal-markdown-gui--documents
            (let ((target (portal-view-target))
                  (dark "matchMedia('(prefers-color-scheme: dark)').matches"))
              (should (eq (plist-get (portal--inspect target) :dark) system-dark))
              (should (eq (eq (portal-excalidraw-gui--js (format "return %s;" dark)) t) system-dark))
              ;; The option applies to the open preview without loading it again.
              (portal-excalidraw-gui--js "window.portalStayed = true; return true;")
              (setopt portal-web-appearance 'light)
              (should-not (plist-get (portal--inspect target) :dark))
              (should-not (portal-excalidraw-gui--js (format "return %s;" dark)))
              (setopt portal-web-appearance 'dark)
              (should (eq (portal-excalidraw-gui--js (format "return %s;" dark)) t))
              (should (eq (portal-excalidraw-gui--js "return window.portalStayed === true;") t))
              ;; The next page keeps it.
              (portal-markdown-gui--link "Other")
              (portal-test--wait-for-page "other.md")
              (should (eq (portal-excalidraw-gui--js (format "return %s;" dark)) t))
              (portal-web-set-appearance nil)
              (should (eq (plist-get (portal--inspect target) :dark) system-dark)))))
      (setq portal-web-appearance original)
      (modify-frame-parameters nil `((ns-appearance . ,frame-appearance))))))

(provide 'portal-markdown-gui-tests)
;;; portal-markdown-gui-tests.el ends here
