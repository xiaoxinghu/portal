;;; portal-web-gui-tests.el --- Windows pages open, in real WebKit -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Load the other graphical suites and the test-only event injector first.
(require 'portal-markdown-gui-tests)
(declare-function portal-test-native-click "test-terminal-input" (x y))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal-excalidraw-gui--js "portal-excalidraw-gui-tests" (script))

(defun portal-web-gui--run-until (type)
  "Run the queued native events up to one of TYPE, and that one too."
  (let (event)
    (while (not (eq (car-safe event) type))
      (setq event (aref (with-timeout (5 (ert-fail (format "No %s event" type)))
                          (read-key-sequence-vector nil))
                        0))
      (funcall (lookup-key global-map (vector (car-safe event))) event))))

(defun portal-web-gui--click (text)
  "Click the link with TEXT in the only visible page, with the real mouse."
  (let ((point (portal-markdown-gui--link-point text)))
    (should (portal-test-native-click (aref point 0) (aref point 1)))))

(defun portal-web-gui--open (text)
  "Click the link with TEXT, which opens a window; return the window's buffer.
The window's pane is then the only one, so scripts reach its page."
  (let ((opener (current-buffer)))
    (portal-web-gui--click text)
    (portal-web-gui--run-until 'portal-web-opened)
    (should-not (eq (current-buffer) opener))
    (should (eq major-mode 'portal-web-mode))
    ;; Shown beside the opener, which keeps its pane.
    (should (= (count-windows) 2))
    (should (get-buffer-window opener))
    (should (plist-get (portal--inspect (portal-view-target)) :focused))
    (delete-other-windows)
    (current-buffer)))

(defun portal-web-gui--close (buffer)
  "Have the page in window BUFFER close itself, and check that BUFFER goes."
  (let ((target (buffer-local-value 'portal-view--target buffer)))
    (should (eq (window-buffer) buffer))
    (should (eq (portal-excalidraw-gui--js "window.close(); return true;") t))
    (portal-web-gui--run-until 'portal-web-closed)
    (should-not (buffer-live-p buffer))
    (should-not (portal--inspect target))))

(ert-deftest portal-web-gui-windows-open-in-their-own-buffers-and-close-themselves ()
  :tags '(:gui)
  (portal-test--with-web
    (let ((directory (make-temp-file "portal-web-gui-" t))
          (display-buffer-alist nil))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "opener.html" directory)
              (insert "<title>Opener</title><style>a{display:block;font-size:40px}</style>
<a href=\"tab.html\" target=\"_blank\">Tab</a>
<a href=\"#\" onclick=\"window.open('popup.html', 'signin', 'width=400,height=500'); return false\">Popup</a>
<script>addEventListener('message', (e) => { document.title = 'Opener heard ' + e.data; });</script>"))
            (with-temp-file (expand-file-name "tab.html" directory)
              (insert "<title>Tab</title><p>A new tab"))
            (with-temp-file (expand-file-name "popup.html" directory)
              (insert "<title>Popup</title><script>
document.title = window.opener ? 'Popup with opener' : 'Popup without opener';
if (window.opener) window.opener.postMessage('hello', '*');
</script>"))
            (select-frame-set-input-focus (selected-frame))
            (sit-for 0.1)
            (should (portal-view--with-frame-title (selected-frame)
                                                   #'portal-test-native-target-frame))
            (portal-render-html (expand-file-name "opener.html" directory))
            (portal-test--wait-for-page "Opener")
            (let ((opener (current-buffer))
                  (opener-target (portal-view-target)))
              ;; A link to target=_blank opens its page in a new buffer.
              (let ((tab (portal-web-gui--open "Tab")))
                (should (equal (buffer-name tab) "*portal: tab.html*"))
                (portal-test--wait-for-page "Tab")
                (portal-web-gui--close tab))
              (switch-to-buffer opener)
              (redisplay t)
              (portal-test--wait-for-page "Opener")
              ;; A popup's page has its opener, which hears from it.
              (let ((popup (portal-web-gui--open "Popup")))
                (portal-test--wait-for-page "Popup with opener")
                (should (equal (plist-get (portal--inspect opener-target) :title)
                               "Opener heard hello"))
                (portal-web-gui--close popup))))
        (portal-test-native-target-frame nil)
        (setq unread-command-events nil)
        (delete-directory directory t)))))

(ert-deftest portal-web-gui-bookmarks-open-their-page-where-asked ()
  :tags '(:gui)
  (portal-test--with-web
    (let ((bookmark-default-file (make-temp-name
                                  (expand-file-name "portal-bookmarks-" temporary-file-directory)))
          (bookmark-alist nil)
          (bookmark-bookmarks-timestamp nil)
          (bookmark-save-flag nil)
          (bookmark-current-bookmark nil)
          (bookmark-automatically-show-annotations nil)
          (display-buffer-alist nil))
      (bookmark-store "Saved page"
                      '((location . "data:text/html,<title>Bookmarked</title><p>Kept")
                        (handler . portal-web-bookmark-jump))
                      nil)
      ;; The handler opens the view before bookmark.el shows its buffer.
      (switch-to-buffer "*scratch*")
      (bookmark-jump "Saved page")
      (should (eq major-mode 'portal-web-mode))
      (portal-test--wait-for-page "Bookmarked" portal-web--target)
      (should (portal-test--shown portal-web--target (selected-window)))
      ;; A page's bookmark takes its title.
      (should (equal (car (portal-web-bookmark-make-record)) "Bookmarked"))
      ;; In another window, it leaves this one as it was.
      (switch-to-buffer "*scratch*")
      (let ((origin (selected-window)))
        (bookmark-jump-other-window "Saved page")
        (should-not (eq (selected-window) origin))
        (should (eq (window-buffer origin) (get-buffer "*scratch*")))
        (portal-test--wait-for-page "Bookmarked" portal-web--target)
        (should (portal-test--shown portal-web--target (selected-window))))
      (should-not (file-exists-p bookmark-default-file)))))

(provide 'portal-web-gui-tests)
;;; portal-web-gui-tests.el ends here
