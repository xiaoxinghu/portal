;;; portal-web-tests.el --- Web buffers against the fake module -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Real buffers and windows drive `portal-web.el'; only the native module is
;; replaced.  Most tests simulate the app host; one runs the real one, from
;; PORTAL_TEST_HOST when set.  Batch Emacs never runs window change hooks, so
;; tests sync.
(require 'ert)
(require 'cl-lib)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal)

(when-let* ((program (getenv "PORTAL_TEST_HOST")))
  (setq portal-server-program program))

(defmacro portal-web-test--environment (&rest body)
  "Run BODY in one fresh window, then kill its buffers and check cleanup."
  (declare (indent 0))
  `(let ((initial-buffers (buffer-list)))
     (portal-fake-native-reset)
     (save-window-excursion
       (unwind-protect
           (progn
             (delete-other-windows)
             (switch-to-buffer (get-buffer-create "*scratch*"))
             ,@body)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (kill-buffer buffer))))
     (should-not (portal-view-buffers))
     (should-not (portal-fake-native-targets))))

(defun portal-web-test--state (&optional target)
  "Inspect TARGET, by default the selected pane's view."
  (portal--inspect (or target (portal-view-target))))

(ert-deftest portal-web-appearance-starts-new-views-and-changes-open-ones ()
  (portal-web-test--environment
    (let ((original portal-web-appearance))
      (unwind-protect
          (progn
            ;; The system's appearance passes no option.
            (setq portal-web-appearance nil)
            (portal-open-url "https://example.com/")
            (let ((system (portal-view-target)))
              (should-not (plist-member (plist-get (portal-web-test--state) :options)
                                        :appearance))
              (setq portal-fake-native-log nil)
              (setopt portal-web-appearance 'dark)
              (should (equal (portal-fake-native-calls 'portal--web-appearance) '(("dark"))))
              (portal-open-url "https://example.com/")
              (should (equal (plist-get (plist-get (portal-web-test--state) :options) :appearance)
                             "dark"))
              (should-not (equal (portal-view-target) system)))
            ;; An unknown appearance changes nothing.
            (setq portal-fake-native-log nil)
            (should-error (setq portal-web-appearance 'sepia))
            (should-error (setq portal-web-appearance "light"))
            (should (eq portal-web-appearance 'dark))
            (should-error (portal-web-set-appearance 'sepia))
            (should-not (portal-fake-native-calls 'portal--web-appearance))
            ;; The command sets the option; "system" is nil.
            (portal-web-set-appearance 'light)
            (should (eq portal-web-appearance 'light))
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "system")))
              (call-interactively #'portal-web-set-appearance))
            (should-not portal-web-appearance)
            (should (equal (portal-fake-native-calls 'portal--web-appearance)
                           '(("light") (nil)))))
        (setq portal-web-appearance original)))))

(ert-deftest portal-web-inspectable-marks-new-views ()
  (portal-web-test--environment
    (let ((original portal-web-inspectable))
      (unwind-protect
          (progn
            (should (eq original t))
            (portal-open-url "https://example.com/")
            (should (eq (plist-get (plist-get (portal-web-test--state) :options) :inspectable) t))
            (setq portal-web-inspectable nil)
            (portal-open-url "https://example.com/")
            (should-not (plist-member (plist-get (portal-web-test--state) :options)
                                      :inspectable)))
        (setq portal-web-inspectable original)))))

(ert-deftest portal-web-open-url-opens-a-new-buffer-each-time ()
  (portal-web-test--environment
    (portal-open-url "https://example.com/page")
    (let ((first (current-buffer))
          (first-target (portal-view-target)))
      (portal-open-url "https://example.com/page")
      (let ((second-target (portal-view-target)))
        (should-not (eq (current-buffer) first))
        (should (equal (buffer-name first) "*portal: example.com*"))
        (should (equal (buffer-name) "*portal: example.com*<2>"))
        (should (eq major-mode 'portal-web-mode))
        (should portal-input-mode)
        (should (string-prefix-p "web:" second-target))
        (should-not (equal first-target second-target))
        (should (equal (portal-view-buffers 'web) (list first (current-buffer))))
        (dolist (target (list first-target second-target))
          (should (equal (plist-get (portal-web-test--state target) :url)
                         "https://example.com/page")))
        (portal-view-sync)
        (should-not (plist-get (portal-web-test--state first-target) :visible))
        (should (plist-get (portal-web-test--state second-target) :visible))))
    (should (equal (buffer-name (progn (portal-open-url "data:text/html,<p>x</p>")
                                       (current-buffer)))
                   "*portal: data*"))
    (dolist (url '("" "relative/path" "javascript:alert(1)" "https://" 42))
      (should-error (portal-open-url url) :type 'user-error))
    (should (= (length (portal-fake-native-calls 'portal--open)) 3))))

(ert-deftest portal-web-view-appears-only-in-the-selected-pane ()
  (portal-web-test--environment
    (portal-open-url "about:blank")
    (let* ((target (portal-view-target))
           (origin (selected-window))
           (other (split-window-right)))
      (should (eq (window-buffer other) (current-buffer)))
      (portal-view-sync)
      (should (equal (portal-view-target origin) target))
      (should-not (portal-view-target other))
      (should (equal (plist-get (portal-web-test--state target) :edges)
                     (window-inside-pixel-edges origin)))
      (select-window other)
      (portal-view-sync)
      (should (equal (portal-view-target other) target))
      (should-not (portal-view-target origin))
      (should (equal (plist-get (portal-web-test--state target) :edges)
                     (window-inside-pixel-edges other)))
      (should (= (length (portal-fake-native-calls 'portal--open)) 1)))))

(ert-deftest portal-web-render-html-reuses-its-buffer-and-g-reloads ()
  (portal-web-test--environment
    (let* ((directory (make-temp-file "portal-web-" t))
           (file (expand-file-name "Résumé #%?.html" directory))
           (other (expand-file-name "other.html" directory))
           (url (browse-url-file-url file)))
      (unwind-protect
          (progn
            (with-temp-file file (insert "<title>Page</title>"))
            (with-temp-file other (insert "<title>Other</title>"))
            (with-temp-buffer
              (setq buffer-file-name file)
              (call-interactively #'portal-render-html))
            (set-buffer (window-buffer))
            (let ((buffer (current-buffer))
                  (target (portal-view-target)))
              (should (equal (buffer-name) "*portal: Résumé #%?.html*"))
              (should (equal (plist-get (portal-web-test--state) :url) url))
              (switch-to-buffer "*scratch*")
              (let ((default-directory directory))
                (portal-render-html "Résumé #%?.html"))
              (should (eq (current-buffer) buffer))
              (should (equal (portal-view-target) target))
              (should (equal (portal-fake-native-calls 'portal--web-load)
                             (list (list target url) (list target url))))
              (setq portal-fake-native-log nil)
              (call-interactively (key-binding "g"))
              (should (equal portal-fake-native-log `((portal--web-load ,target ,url))))
              ;; Another file gets its own buffer.
              (portal-render-html other)
              (should-not (eq (current-buffer) buffer))
              (should (= (length (portal-fake-native-calls 'portal--open)) 1))))
        (delete-directory directory t)))
    (dolist (input '("" "relative/missing.html" "/ssh:host:/index.html" "javascript:alert(1)"))
      (should-error (portal-render-html input) :type 'user-error))))

(ert-deftest portal-web-render-html-only-reuses-preview-buffers ()
  (portal-web-test--environment
    (let* ((file (make-temp-file "portal-web-" nil ".html" "<title>Page</title>"))
           (url (browse-url-file-url file)))
      (unwind-protect
          (progn
            (portal-open-url url)
            (let ((page (current-buffer)))
              (switch-to-buffer (generate-new-buffer "client"))
              (portal-web-open url)
              (let ((client (current-buffer)))
                (portal-render-html file)
                (let ((preview (current-buffer)))
                  (should-not (memq preview (list page client)))
                  (switch-to-buffer page)
                  (portal-render-html file)
                  (should (eq (current-buffer) preview))
                  (should (= (length (portal-fake-native-calls 'portal--open)) 3))))))
        (delete-file file)))))

(ert-deftest portal-web-quit-window-hides-and-kill-buffer-releases ()
  (portal-web-test--environment
    (portal-open-url "about:blank")
    (let ((buffer (current-buffer))
          (target (portal-view-target)))
      (should (eq (key-binding "q") #'quit-window))
      (call-interactively (key-binding "q"))
      (portal-view-sync)
      (should-not (eq (window-buffer) buffer))
      (should (buffer-live-p buffer))
      (should (portal-web-test--state target))
      (should-not (plist-get (portal-web-test--state target) :visible))
      (should-not (portal-fake-native-calls 'portal--close))
      (switch-to-buffer buffer)
      (portal-view-sync)
      (should (plist-get (portal-web-test--state target) :visible))
      (should (= (length (portal-fake-native-calls 'portal--web-load)) 1))
      (kill-buffer buffer)
      (should (equal (portal-fake-native-calls 'portal--close) (list (list target))))
      (should-not (portal-web-test--state target)))))

(ert-deftest portal-web-open-gives-any-buffer-a-web-view ()
  (portal-web-test--environment
    (switch-to-buffer (generate-new-buffer "client"))
    (should-error (portal-web-open "relative") :type 'user-error)
    (should-not portal-fake-native-log)
    (let ((target (portal-web-open "about:blank")))
      (should (equal (portal-view-target) target))
      (should (eq major-mode 'fundamental-mode))
      ;; The shared prefix and RET reach the view.
      (should (equal (portal-input--target) target))
      (should (eq (key-binding (kbd "RET")) #'portal-input-focus))
      (should (equal (plist-get (portal-web-test--state) :url) "about:blank"))
      (should (equal (portal-view-buffers 'web) (list (current-buffer)))))
    (switch-to-buffer (generate-new-buffer "plain"))
    (should-error (portal-web-reload) :type 'user-error)
    ;; A view that fails to open leaves the buffer as it was.
    (let ((targets (portal-fake-native-targets)))
      (dolist (failure '(portal--open portal--place portal--web-load))
        (let ((portal-fake-native-failures (list failure)))
          (should-error (portal-web-open "about:blank")))
        (should-not portal-input-mode)
        (should-not (memq (current-buffer) (portal-view-buffers)))
        (should (equal (portal-fake-native-targets) targets))))
    ;; The buffer can still open a view afterwards.
    (should (equal (portal-web-open "about:blank") (portal-view-target)))))

(ert-deftest portal-web-hosted-apps-open-at-once-and-load-when-the-app-host-is-ready ()
  (portal-web-test--environment
    (let ((file (make-temp-file "portal-web-" nil ".md" "# Notes\n"))
          (host nil)
          (starts 0))
      (unwind-protect
          (cl-letf (((symbol-function 'portal-start-server) (lambda () (cl-incf starts)))
                    ((symbol-function 'portal-server-url) (lambda () host)))
            (portal-hello)
            (let ((hello (current-buffer))
                  (hello-target (portal-view-target)))
              (should (equal (buffer-name) "*portal: hello*"))
              (portal-render-markdown file)
              (let ((markdown (current-buffer))
                    (markdown-target (portal-view-target))
                    (markdown-url (concat "http://127.0.0.1:1/token/markdown?path="
                                          (url-hexify-string file))))
                (should (equal (buffer-name) (format "*portal: %s*" (file-name-nondirectory file))))
                ;; Both views open at once, before the app host is ready.
                (should (= starts 2))
                (dolist (target (list hello-target markdown-target))
                  (should (plist-get (plist-get (portal-web-test--state target) :options) :hosted))
                  (should (equal (plist-get (portal-web-test--state target) :url) "about:blank")))
                (setq host "http://127.0.0.1:1/token")
                (run-hooks 'portal-server-ready-hook)
                (should (equal (plist-get (portal-web-test--state hello-target) :url)
                               "http://127.0.0.1:1/token/hello"))
                (should (equal (plist-get (portal-web-test--state markdown-target) :url)
                               markdown-url))
                ;; Previewing the same file again reuses its buffer.
                (switch-to-buffer hello)
                (setq portal-fake-native-log nil)
                (portal-render-markdown file)
                (should (eq (current-buffer) markdown))
                (should (equal portal-fake-native-log
                               `((portal--web-load ,markdown-target ,markdown-url))))
                ;; A restarted host leaves loaded apps alone; g loads from it.
                (setq host "http://127.0.0.1:2/other"
                      portal-fake-native-log nil)
                (run-hooks 'portal-server-ready-hook)
                (should-not portal-fake-native-log)
                (call-interactively (key-binding "g"))
                (should (= starts 4))
                (should (equal (plist-get (portal-web-test--state markdown-target) :url)
                               (replace-regexp-in-string "1/token" "2/other" markdown-url)))
                (should (equal (plist-get (portal-web-test--state hello-target) :url)
                               "http://127.0.0.1:1/token/hello"))
                (should (= (length (portal-fake-native-targets)) 2)))))
        (delete-file file)))))

(ert-deftest portal-web-about-passes-the-portal-and-emacs-versions ()
  (portal-web-test--environment
    (cl-letf (((symbol-function 'portal-start-server) #'ignore)
              ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token"))
              ((symbol-function 'portal-build-version) (lambda () "1.2.3"))
              (emacs-version "31.1 (test)"))
      (portal-about)
      (let ((about (current-buffer)) (target (portal-view-target)))
        (should (equal (buffer-name) "*portal: about*"))
        (should (equal (plist-get (portal-web-test--state target) :url)
                       "http://127.0.0.1:1/token/about?portal=1.2.3&emacs=31.1%20%28test%29"))
        ;; Asking again shows the same page.
        (switch-to-buffer "*scratch*")
        (portal-about)
        (should (eq (current-buffer) about))
        (should (= (length (portal-fake-native-targets)) 1))))))

(ert-deftest portal-web-hosted-app-stays-when-the-app-host-cannot-start ()
  (portal-web-test--environment
    (let ((host nil))
      (cl-letf (((symbol-function 'portal-start-server)
                 (lambda () (unless host (user-error "Build the Portal UI host"))))
                ((symbol-function 'portal-server-url) (lambda () host)))
        (should-error (portal-hello) :type 'user-error)
        (let ((target (portal-view-target)))
          (should (equal (buffer-name) "*portal: hello*"))
          (should (equal (plist-get (portal-web-test--state target) :url) "about:blank"))
          ;; Once the host can start, g loads the app in the same view.
          (setq host "http://127.0.0.1:1/token")
          (call-interactively (key-binding "g"))
          (should (equal (plist-get (portal-web-test--state target) :url)
                         "http://127.0.0.1:1/token/hello"))
          (should (= (length (portal-fake-native-calls 'portal--open)) 1)))))))

(ert-deftest portal-web-open-hosted-gives-any-buffer-a-hosted-app ()
  (portal-web-test--environment
    (cl-letf (((symbol-function 'portal-start-server) #'ignore)
              ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token")))
      (switch-to-buffer (generate-new-buffer "client"))
      (let ((target (portal-web-open-hosted "/hello")))
        (should (equal (portal-view-target) target))
        (should (eq major-mode 'fundamental-mode))
        (should (equal (portal-fake-native-calls 'portal--web-load)
                       `((,target "about:blank") (,target "http://127.0.0.1:1/token/hello"))))))))

(ert-deftest portal-web-bridge-passes-an-apps-messages-to-its-buffer-in-order ()
  (portal-web-test--environment
    (cl-letf (((symbol-function 'portal-start-server) #'ignore)
              ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token")))
      (switch-to-buffer (generate-new-buffer "client"))
      (let ((target (portal-web-open-hosted "/app"))
            received)
        (setq portal-web-bridge-function
              (lambda (message) (push (cons (buffer-name) message) received)))
        (portal-fake-native-post target "{\"type\":\"first\",\"n\":1}" "{\"type\":\"second\"}")
        (with-current-buffer "*scratch*"
          (portal-fake-native-send (format "bridge %s\n" target)))
        (should (equal (reverse received)
                       '(("client" :type "first" :n 1) ("client" :type "second"))))
        (should (equal (portal--web-receive target) "[]"))
        (portal-web-send '(:type "reply" :n 2))
        (should (equal (portal-fake-native-calls 'portal--web-send)
                       `((,target "{\"type\":\"reply\",\"n\":2}"))))))))

(defun portal-web-test--wait (predicate)
  "Allow asynchronous process work until PREDICATE succeeds."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun portal-web-test--stop-host ()
  "Stop the app host, and wait until its process has exited."
  (let ((process portal--server-process))
    (portal-stop-server)
    (when process
      (portal-web-test--wait (lambda () (not (process-live-p process)))))))

(ert-deftest portal-web-markdown-preview-with-the-real-app-host ()
  (skip-unless (file-executable-p (portal-server-program-file)))
  (portal-web-test--environment
    (let ((file (make-temp-file "portal-web-" nil ".md" "# Real notes\n"))
          (url-proxy-services nil))
      (unwind-protect
          (progn
            (should-not (portal-server-url))
            ;; The preview opens before the app host is ready.
            (portal-render-markdown file)
            (let ((target (portal-view-target))
                  (path (concat "/markdown?path=" (url-hexify-string file))))
              (should (equal (plist-get (portal-web-test--state) :url) "about:blank"))
              (portal-web-test--wait #'portal-server-url)
              (let ((url (concat (portal-server-url) path)))
                (should (equal (plist-get (portal-web-test--state target) :url) url))
                (let ((response (url-retrieve-synchronously url t t 3)))
                  (unwind-protect
                      (should (string-match-p "Real notes</h1>"
                                              (with-current-buffer response (buffer-string))))
                    (kill-buffer response)))
                ;; Stopping and restarting the host leave the loaded preview alone.
                (portal-web-test--stop-host)
                (should (equal (plist-get (portal-web-test--state target) :url) url))
                (portal-restart-server)
                (portal-web-test--wait #'portal-server-url)
                (should-not (string-prefix-p (portal-server-url) url))
                (should (equal (plist-get (portal-web-test--state target) :url) url))
                ;; g reloads it from the running host.
                (call-interactively (key-binding "g"))
                (should (equal (plist-get (portal-web-test--state target) :url)
                               (concat (portal-server-url) path))))))
        (portal-web-test--stop-host)
        (delete-file file)))))

(ert-deftest portal-web-history-commands-use-the-selected-pane-view ()
  (portal-web-test--environment
    (portal-open-url "https://example.com")
    (let ((target (portal-view-target))
          (other (split-window-right)))
      (setq portal-fake-native-log nil)
      (call-interactively (key-binding "l"))
      (call-interactively (key-binding "r"))
      (portal-web-back)
      (should (equal (portal-fake-native-calls 'portal--web-go)
                     `((,target "back") (,target "forward") (,target "back"))))
      ;; A pane showing another buffer has no view to act on.
      (set-window-buffer other (get-buffer "*scratch*"))
      (select-window other)
      (portal-view-sync)
      (should-error (portal-web-back) :type 'user-error)
      (should (= (length (portal-fake-native-calls 'portal--web-go)) 3)))))

;; Markdown previews: navigation, handoff to Emacs, and return.

(defconst portal-web-test--host "http://127.0.0.1:1/0123abcd"
  "The simulated app host's base URL.")

(defvar portal-web-test--directory nil "The Markdown tests' temporary folder.")

(defmacro portal-web-test--markdown (&rest body)
  "Run BODY with a simulated app host and `portal-web-test--directory'.
The folder holds README.md, \"docs é/arch notes.md\", a source file with
60 lines, an image and a folder."
  (declare (indent 0))
  `(portal-web-test--environment
     (let* ((portal-web-test--directory (make-temp-file "portal-markdown-" t))
            (directory portal-web-test--directory)
            (display-buffer-alist nil))
       (unwind-protect
           (cl-letf (((symbol-function 'portal-start-server) #'ignore)
                     ((symbol-function 'portal-server-url) (lambda () portal-web-test--host)))
             (make-directory (expand-file-name "docs é" directory))
             (make-directory (expand-file-name "src" directory))
             (with-temp-file (expand-file-name "README.md" directory) (insert "# Read me\n"))
             (with-temp-file (expand-file-name "docs é/arch notes.md" directory) (insert "# Arch\n"))
             (with-temp-file (expand-file-name "src/main file.ts" directory)
               (dotimes (line 60) (insert (format "// line %d\n" (1+ line)))))
             (with-temp-file (expand-file-name "pic.png" directory) (insert "\211PNG\r\n\032\n"))
             ,@body)
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer) (file-in-directory-p (buffer-file-name buffer) directory))
             (kill-buffer buffer)))
         (delete-directory directory t)))))

(defun portal-web-test--file (name)
  "Return file NAME in `portal-web-test--directory'."
  (expand-file-name name portal-web-test--directory))

(defun portal-web-test--record (type target &optional file fragment)
  "Send what TARGET's view does for TYPE, with a URL for FILE when non-nil.
\"page\", \"follow\" and \"edit\" are bridge messages, and others records.  A
Markdown FILE gets its preview URL, and any other a file: URL."
  (let ((url (cond ((null file) nil)
                   ((string-suffix-p ".md" file)
                    (concat portal-web-test--host "/markdown?path=" (url-hexify-string file)))
                   (t (concat "file://" (url-hexify-string file (cons ?/ url-unreserved-chars)))))))
    (with-current-buffer "*scratch*"
      (if (member type '("page" "follow" "edit"))
          (progn
            (portal-fake-native-post
             target (json-serialize
                     (if url (list :type type :url (concat url (and fragment (concat "#" fragment))))
                       (list :type type))))
            (portal-fake-native-send (format "bridge %s\n" target)))
        (portal-fake-native-send (concat type " " target "\n"))))))

(defun portal-web-test--run-events ()
  "Run the commands that native records queued, as the command loop would."
  (while unread-command-events
    (let ((event (pop unread-command-events)))
      (funcall (lookup-key global-map (vector (car event))) event))))

(defun portal-web-test--preview (file)
  "Preview Markdown FILE; return its buffer, which the selected pane shows."
  (portal-render-markdown file)
  (portal-view-sync)
  (current-buffer))

(ert-deftest portal-web-markdown-preview-takes-the-identity-of-the-page-it-shows ()
  (portal-web-test--markdown
    (let* ((readme (portal-web-test--file "README.md"))
           (arch (portal-web-test--file "docs é/arch notes.md"))
           (preview (portal-web-test--preview readme))
           (target (portal-view-target)))
      (should (equal (buffer-name) "*portal: README.md*"))
      ;; A link to another Markdown file, with a heading, commits in the view.
      (portal-web-test--record "page" target arch "decisions")
      (should (equal (buffer-name preview) "*portal: arch notes.md*"))
      ;; g rereads the file on screen.
      (setq portal-fake-native-log nil)
      (call-interactively (key-binding "g"))
      (should (equal portal-fake-native-log
                     `((portal--web-load ,target ,(concat portal-web-test--host "/markdown?path="
                                                          (url-hexify-string arch))))))
      ;; Previewing the file on screen finds this buffer; the first file does not.
      (switch-to-buffer "*scratch*")
      (should (eq (portal-web-test--preview arch) preview))
      (let ((other (portal-web-test--preview readme)))
        (should-not (eq other preview))
        (should (equal (buffer-name other) "*portal: README.md*"))
        ;; Each preview keeps its own identity, even for the same file.
        (portal-web-test--record "page" (portal-view-target) arch)
        (should (equal (buffer-name other) "*portal: arch notes.md*<2>"))
        (should (equal (buffer-name preview) "*portal: arch notes.md*"))
        ;; Back in the first preview.
        (portal-web-test--record "page" target readme)
        (should (equal (buffer-name preview) "*portal: README.md*"))
        (switch-to-buffer "*scratch*")
        (should (eq (portal-web-test--preview readme) preview)))
      ;; Other pages, and pages of other hosted apps, change nothing.
      (with-current-buffer "*scratch*"
        (portal-fake-native-post target "{\"type\":\"page\",\"url\":\"about:blank\"}"
                                 (format "{\"type\":\"page\",\"url\":\"%s/hello\"}" portal-web-test--host))
        (portal-fake-native-send (format "bridge %s\n" target)))
      (should (equal (buffer-name preview) "*portal: README.md*"))
      (portal-hello)
      (portal-web-test--record "page" (portal-view-target) arch)
      (should (equal (buffer-name) "*portal: hello*")))))

(ert-deftest portal-web-markdown-preview-hands-local-files-to-another-pane ()
  (portal-web-test--markdown
    (let* ((preview (portal-web-test--preview (portal-web-test--file "README.md")))
           (target (portal-view-target))
           (origin (selected-window))
           (source (portal-web-test--file "src/main file.ts")))
      (portal-input-focus)
      (should (plist-get (portal-web-test--state target) :focused))
      ;; With one pane, the file gets a new one and the preview stays.
      (portal-web-test--record "follow" target source "L42-L50")
      (portal-web-test--run-events)
      (should (equal buffer-file-name source))
      (should (= (line-number-at-pos) 42))
      (should-not (eq (selected-window) origin))
      (should (eq (window-buffer origin) preview))
      (portal-view-sync)
      (should (plist-get (portal-web-test--state target) :visible))
      (should-not (plist-get (portal-web-test--state target) :focused))
      (should (eq (frame-parameter nil 'portal-render-return) preview))
      ;; The clicked preview's pane need not be selected; its other pane is reused.
      (let ((other (selected-window)))
        (should (= (count-windows) 2))
        (portal-web-test--record "follow" target (portal-web-test--file "pic.png"))
        (portal-web-test--run-events)
        (should (eq (selected-window) other))
        (should (equal buffer-file-name (portal-web-test--file "pic.png")))
        (select-window origin)
        (portal-web-test--record "follow" target (portal-web-test--file "src/"))
        (portal-web-test--run-events)
        (should (eq (selected-window) other))
        (should (eq major-mode 'dired-mode))
        ;; Existing buffers keep their point and edits; other fragments are ignored.
        (portal-web-test--record "follow" target source)
        (portal-web-test--run-events)
        (should (= (line-number-at-pos) 42))
        (insert "unsaved ")
        (forward-line -32)
        (portal-web-test--record "follow" target source "heading")
        (portal-web-test--run-events)
        (should (buffer-modified-p))
        (should (= (line-number-at-pos) 10))
        (set-buffer-modified-p nil)
        ;; A path far longer than a notification record still arrives.
        (let ((deep (portal-web-test--file
                     (concat (mapconcat #'identity (make-list 20 "très long dossier") "/")
                             "/fichier é.ts"))))
          (make-directory (file-name-directory deep) t)
          (with-temp-file deep (insert "one\ntwo\nthree\n"))
          (should (> (length (url-hexify-string deep)) 600))
          (portal-web-test--record "follow" target deep "L3")
          (portal-web-test--run-events)
          (should (equal buffer-file-name deep))
          (should (= (line-number-at-pos) 3))))
      (should (= (count-windows) 2))
      (should (eq (window-buffer origin) preview))
      (should (= (length (portal-fake-native-calls 'portal--web-load)) 2)))))

(ert-deftest portal-web-markdown-handoff-respects-placement-rules-and-failures ()
  (portal-web-test--markdown
    (let* ((preview (portal-web-test--preview (portal-web-test--file "README.md")))
           (target (portal-view-target))
           (source (portal-web-test--file "src/main file.ts")))
      ;; A failed visit reports the error and leaves the preview as it was.
      (cl-letf (((symbol-function 'find-file-noselect)
                 (lambda (&rest _) (signal 'file-error '("Opening input file" "Permission denied")))))
        (portal-web-test--record "follow" target source)
        (should-error (portal-web-test--run-events) :type 'file-error))
      (should (eq (window-buffer) preview))
      (should (= (count-windows) 1))
      ;; Placement rules win, even when they replace the preview.
      (let ((display-buffer-alist '(("\\.ts\\'" display-buffer-same-window))))
        (portal-web-test--record "follow" target source)
        (portal-web-test--run-events))
      (should (equal buffer-file-name source))
      (should (= (count-windows) 1))
      (portal-view-sync)
      (should-not (plist-get (portal-web-test--state target) :visible))
      ;; Return shows it again, with the page it had.
      (setq portal-fake-native-log nil)
      (portal-render-return)
      (should (eq (window-buffer) preview))
      (should (plist-get (portal-web-test--state target) :visible))
      (should (plist-get (portal-web-test--state target) :focused))
      (should-not (portal-fake-native-calls 'portal--web-load)))))

(ert-deftest portal-web-markdown-open-in-emacs-and-return ()
  (portal-web-test--markdown
    (let* ((readme (portal-web-test--file "README.md"))
           (arch (portal-web-test--file "docs é/arch notes.md"))
           (preview (portal-web-test--preview readme))
           (target (portal-view-target))
           (origin (selected-window)))
      (should-error (with-current-buffer "*scratch*" (portal-render-open-in-emacs)) :type 'user-error)
      (should-error (portal-render-return) :type 'user-error)
      ;; The command opens the file on screen, after back or forward too.
      (portal-web-test--record "page" target arch)
      (portal-web-test--run-events)
      (portal-render-open-in-emacs)
      (should (equal buffer-file-name arch))
      (should-not (eq (selected-window) origin))
      (should-not (plist-get (portal-web-test--state target) :focused))
      (portal-web-test--record "page" target readme)
      (select-window origin)
      (portal-render-open-in-emacs)
      (should (equal buffer-file-name readme))
      ;; Return survives switching among source buffers, and does not reload.
      (find-file (portal-web-test--file "src/main file.ts"))
      (find-file arch)
      (setq portal-fake-native-log nil)
      (portal-render-return)
      (should (eq (selected-window) origin))
      (should (plist-get (portal-web-test--state target) :focused))
      (should-not (portal-fake-native-calls 'portal--web-load))
      ;; The most recent handoff wins, and a killed preview is reported.
      (switch-to-buffer "*scratch*")
      (let ((second (portal-web-test--preview arch)))
        (should-not (eq second preview))
        (portal-render-open-in-emacs)
        (portal-render-return)
        (should (eq (window-buffer) second))
        (kill-buffer second))
      (should (buffer-live-p preview))
      (should-error (portal-render-return) :type 'user-error))))

(ert-deftest portal-web-markdown-return-follows-a-handoff-into-another-frame ()
  (portal-web-test--markdown
    (portal-fake-native-with-frame frame
      (let* ((preview (portal-web-test--preview (portal-web-test--file "README.md")))
             (source (portal-web-test--file "src/main file.ts")))
        (with-selected-frame frame (find-file source))
        (let ((display-buffer-alist
               '(("\\.ts\\'" (display-buffer-reuse-window) (reusable-frames . t)))))
          (portal-web-test--record "follow" (portal-view-target) source)
          (portal-web-test--run-events))
        (should (eq (selected-frame) frame))
        (should (eq (frame-parameter frame 'portal-render-return) preview))
        (should (eq (frame-parameter portal-fake-native--selected 'portal-render-return) preview))
        ;; Return selects the preview's pane in the first frame, not a copy here.
        (let ((origin (get-buffer-window preview portal-fake-native--selected)))
          (portal-render-return)
          (should (eq (selected-window) origin))
          (should-not (get-buffer-window preview frame))
          (should (plist-get (portal-web-test--state (portal-view-target)) :focused)))))))

(ert-deftest portal-web-windows-a-page-opens-get-buffers-of-their-own ()
  (portal-web-test--environment
    (let ((display-buffer-alist nil))
      (portal-open-url "https://example.com/")
      (portal-view-sync)
      (portal-input-focus)
      (let* ((opener (current-buffer))
             (origin (selected-window))
             (target (portal-view-target))
             (window (portal-fake-native-open-window target "https://accounts.example.com/signin")))
        (portal-web-test--run-events)
        ;; It is named after its page and shown beside its opener, with the keyboard.
        (should (equal (buffer-name) "*portal: accounts.example.com*"))
        (should (eq major-mode 'portal-web-mode))
        (should-not (eq (selected-window) origin))
        (should (eq (window-buffer origin) opener))
        (should (equal (portal-view-target) window))
        (should (plist-get (portal-web-test--state window) :focused))
        (should-not (plist-get (portal-web-test--state target) :focused))
        ;; g loads the page it shows.
        (portal-web-reload)
        (should (equal (car (last (portal-fake-native-calls 'portal--web-load)))
                       (list window "https://accounts.example.com/signin")))
        ;; Its page closes it, and its pane goes too.
        (let ((buffer (current-buffer)))
          (portal-fake-native-send (format "closed %s\n" window))
          (portal-web-test--run-events)
          (should-not (buffer-live-p buffer)))
        (should-not (portal--inspect window))
        (should (= (count-windows) 1))
        (should (eq (selected-window) origin))
        (should (portal--inspect target))
        ;; A window outlives its opener, and one closed before Emacs saw it gets no buffer.
        (let ((orphan (portal-fake-native-open-window target "about:blank"))
              (closed (portal-fake-native-open-window target "https://example.com/gone")))
          (portal--close closed)
          (kill-buffer opener)
          (portal-web-test--run-events)
          (should (equal (buffer-name) "*portal: about:blank*"))
          (should (equal (portal-view-target) orphan))
          ;; It takes the name of each page it goes to.
          (portal-fake-native-commit orphan "https://accounts.example.com/signin")
          (should (equal (buffer-name) "*portal: accounts.example.com*"))
          (should-not (get-buffer "*portal: example.com*"))
          (should (equal (portal-fake-native-targets) (list orphan)))
          ;; A window that closes itself before Emacs gives it a buffer goes all the same.
          (let ((brief (portal-fake-native-open-window orphan "https://example.com/brief")))
            (portal-fake-native-send (format "closed %s\n" brief))
            (portal-web-test--run-events)
            (should-not (portal--inspect brief))
            (should-not (get-buffer "*portal: example.com*"))
            (should (equal (portal-view-target) orphan))))))))

(ert-deftest portal-web-click-selects-the-views-pane ()
  (portal-web-test--environment
    (portal-open-url "about:blank")
    (let ((target (portal-view-target))
          (origin (selected-window)))
      (select-window (split-window-right))
      (switch-to-buffer "*scratch*")
      (portal-view-sync)
      (with-current-buffer "*scratch*"
        (portal-fake-native-send (format "select %s\n" target)))
      (portal-web-test--run-events)
      (should (eq (selected-window) origin))
      (should (plist-get (portal-web-test--state target) :focused)))))

(provide 'portal-web-tests)
;;; portal-web-tests.el ends here
