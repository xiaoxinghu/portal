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

(ert-deftest portal-web-downloads-go-to-the-chosen-directory-and-emacs-says-how-they-went ()
  (portal-web-test--environment
    (let ((original portal-web-download-directory)
          said)
      (unwind-protect
          (cl-letf (((symbol-function 'message)
                     (lambda (format &rest arguments)
                       (push (apply #'format-message format arguments) said))))
            (setopt portal-web-download-directory "/tmp/portal downloads/")
            (portal-open-url "https://example.com/")
            (let ((target (portal-view-target))
                  (home (abbreviate-file-name (expand-file-name "~/report.pdf"))))
              ;; Opening a view tells the core where downloads go, as does a change.
              (setopt portal-web-download-directory "~/")
              (should (equal (last (portal-fake-native-calls 'portal--web-download-directory) 2)
                             `(("/tmp/portal downloads/") (,(expand-file-name "~/")))))
              (should-error (setq portal-web-download-directory nil))
              (setq said nil)
              (portal-fake-native-queue
               target
               (format "{\"type\":\"download\",\"state\":\"started\",\"url\":\"https://example.com/r\",\"file\":%S}"
                       (expand-file-name "~/report.pdf"))
               (format "{\"type\":\"download\",\"state\":\"finished\",\"url\":\"https://example.com/r\",\"file\":%S}"
                       (expand-file-name "~/report.pdf"))
               (format "{\"type\":\"download\",\"state\":\"failed\",\"url\":\"https://example.com/z\",\"file\":%S,\"message\":\"The disk is full.\"}"
                       (expand-file-name "~/report.pdf"))
               "{\"type\":\"download\",\"state\":\"failed\",\"url\":\"https://example.com/z\",\"file\":\"\",\"message\":\"Portal has no download directory\"}")
              (with-current-buffer "*scratch*"
                (portal-fake-native-send (format "bridge %s\n" target)))
              (should (equal (reverse said)
                             (list (format "Downloading %s..." home)
                                   (format "Downloaded %s" home)
                                   (format "Could not download %s: The disk is full." home)
                                   (concat "Could not download https://example.com/z: "
                                           "Portal has no download directory"))))))
        (setopt portal-web-download-directory original)))))

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
      (call-interactively (key-binding (kbd "s-[")))
      (call-interactively (key-binding (kbd "s-]")))
      (should (equal (portal-fake-native-calls 'portal--web-go)
                     `((,target "back") (,target "forward") (,target "back")
                       (,target "back") (,target "forward"))))
      ;; A pane showing another buffer has no view to act on.
      (set-window-buffer other (get-buffer "*scratch*"))
      (select-window other)
      (portal-view-sync)
      (should-error (portal-web-back) :type 'user-error)
      (should (= (length (portal-fake-native-calls 'portal--web-go)) 5)))))

(ert-deftest portal-web-load-url-loads-in-this-view-as-an-address-bar-does ()
  (portal-web-test--environment
    (let ((file (make-temp-file "portal-web-" nil ".html" "<p>Hi</p>")))
      (unwind-protect
          (progn
            (portal-render-html file)
            (let ((target (portal-view-target))
                  (buffer (current-buffer))
                  prompted)
              (setq portal-fake-native-log nil)
              ;; The minibuffer starts from the page on screen.
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt _table _predicate _require initial &rest _)
                           (setq prompted initial)
                           "https://example.com/a")))
                (call-interactively (key-binding (kbd "s-l"))))
              (should (equal prompted (browse-url-file-url file)))
              (should (equal (portal-view-target) target))
              (should (eq (current-buffer) buffer))
              (should (equal (buffer-name) "*portal: example.com*"))
              (should (equal (portal-fake-native-calls 'portal--web-load)
                             `((,target "https://example.com/a"))))
              ;; g reloads the new page, and previewing the file opens it afresh.
              (call-interactively (key-binding "g"))
              (should (equal (plist-get (portal-web-test--state) :url) "https://example.com/a"))
              (portal-render-html file)
              (should-not (eq (current-buffer) buffer))
              (should (= (length (portal-view-buffers 'web)) 2))
              ;; A URL a web view cannot load changes nothing.
              (switch-to-buffer buffer)
              (portal-view-sync)
              (setq portal-fake-native-log nil)
              (should-error (portal-web-load-url "example.com") :type 'user-error)
              (should-not (portal-fake-native-calls 'portal--web-load))))
        (delete-file file)))
    ;; A hosted app keeps its page and opens the URL in a new buffer.
    (cl-letf (((symbol-function 'portal-start-server) #'ignore)
              ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token")))
      (switch-to-buffer (generate-new-buffer "client"))
      (let ((target (portal-web-open-hosted "/hello")))
        (portal-web-load-url "https://example.org/")
        (should (equal (buffer-name) "*portal: example.org*"))
        (should-not (equal (portal-view-target) target))
        (should (equal (plist-get (portal-web-test--state target) :url)
                       "http://127.0.0.1:1/token/hello"))))
    ;; A buffer without a view has nothing to load.
    (with-temp-buffer
      (should-error (portal-web-load-url "https://example.com/") :type 'user-error))))

;; Finding text and zooming.

(defmacro portal-web-test--reading (input &rest body)
  "Run BODY with the minibuffer reading INPUT, a function.
INPUT runs in a minibuffer, where it may type and run commands, and its
value is what the minibuffer returns.  Batch Emacs reads the minibuffer
from standard input, so this stands in for it."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'read-from-minibuffer)
              (lambda (_prompt _initial _map _read history &rest _)
                (let ((text (with-current-buffer (window-buffer (minibuffer-window))
                              (let ((inhibit-read-only t))
                                (unwind-protect (funcall ,input)
                                  (erase-buffer))))))
                  (unless (string-empty-p text) (add-to-history history text))
                  text))))
     ,@body))

(defvar portal-web-test--messages nil
  "The messages shown in `portal-web-test--messages', newest first.")

(defmacro portal-web-test--messages (&rest body)
  "Run BODY, keeping the messages it shows in `portal-web-test--messages'.
They go there newest first: batch Emacs has no echo area to read."
  (declare (indent 0))
  `(let ((portal-web-test--messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format &rest arguments)
                  (push (and format (apply #'format-message format arguments))
                        portal-web-test--messages))))
       ,@body)))

(ert-deftest portal-web-find-reads-text-and-moves-between-matches ()
  (portal-web-test--environment
    (portal-open-url "https://example.com")
    (let ((target (portal-view-target))
          (portal-web-find-history nil)
          (case-fold-search t)
          (search-upper-case t))
      (setq portal-fake-native-log nil)
      ;; RET finds what was typed; C-s and C-r in the minibuffer move from
      ;; match to match, and RET then stays.
      (portal-web-test--reading (lambda ()
                                  (insert "apple")
                                  (portal-web-find-next)
                                  (portal-web-find-next)
                                  (portal-web-find-previous)
                                  (minibuffer-contents))
        (call-interactively (key-binding (kbd "C-s"))))
      (should (equal (portal-fake-native-calls 'portal--web-find)
                     `((,target "apple" nil nil) (,target "apple" nil nil) (,target "apple" t nil))))
      ;; Text changed after moving is found on RET, backward from C-r.
      (setq portal-fake-native-log nil)
      (portal-web-test--reading (lambda ()
                                  (insert "pear")
                                  (portal-web-find-next)
                                  (insert "s")
                                  (minibuffer-contents))
        (call-interactively (key-binding (kbd "C-r"))))
      (should (equal (portal-fake-native-calls 'portal--web-find)
                     `((,target "pear" nil nil) (,target "pears" t nil))))
      ;; Empty input finds the last text; C-s in an empty minibuffer brings it back.
      (setq portal-fake-native-log nil)
      (portal-web-test--reading (lambda () "")
        (call-interactively (key-binding (kbd "s-f"))))
      (portal-web-test--reading (lambda () (portal-web-find-next) (minibuffer-contents))
        (portal-web-find))
      ;; Command-G and Command-Shift-G move without the minibuffer.
      (call-interactively (key-binding (kbd "s-g")))
      (call-interactively (key-binding (kbd "s-G")))
      (should (equal (portal-fake-native-calls 'portal--web-find)
                     `((,target "pears" nil nil) (,target "pears" nil nil)
                       (,target "pears" nil nil) (,target "pears" t nil))))
      ;; Case matters for an upper-case letter, or without case folding.
      (setq portal-fake-native-log nil)
      (portal-web-test--reading (lambda () "Apple") (portal-web-find))
      (let ((search-upper-case nil))
        (portal-web-test--reading (lambda () "Apple") (portal-web-find)))
      (let ((case-fold-search nil))
        (portal-web-test--reading (lambda () "apple") (portal-web-find)))
      (should (equal (mapcar #'cadddr (portal-fake-native-calls 'portal--web-find)) '(t nil t)))
      ;; With nothing found yet, Command-G reads the text first.
      (setq portal-web-find-history nil portal-fake-native-log nil)
      (should-error (portal-web-test--reading (lambda () "") (portal-web-find))
                    :type 'user-error)
      (portal-web-test--reading (lambda () "kiwi")
        (call-interactively (key-binding (kbd "s-g"))))
      (should (equal (portal-fake-native-calls 'portal--web-find) `((,target "kiwi" nil nil)))))))

(ert-deftest portal-web-find-says-when-the-page-has-no-match ()
  (portal-web-test--environment
    (portal-open-url "https://example.com")
    (let ((target (portal-view-target))
          (portal-web-find-history nil))
      (portal-web-test--reading (lambda () "kiwi") (portal-web-find))
      (portal-web-test--messages
        (portal-fake-native-send (format "found %s 1\n" target))
        (should-not portal-web-test--messages)
        (portal-fake-native-send (format "found %s 0\n" target))
        (should (equal portal-web-test--messages '("No match for \"kiwi\""))))
      ;; Another pane with no view has nothing to find in.
      (select-window (split-window-right))
      (switch-to-buffer "*scratch*")
      (portal-view-sync)
      (should-error (portal-web-find-next) :type 'user-error))))

(ert-deftest portal-web-zoom-steps-and-remembers-each-site ()
  (portal-web-test--environment
    (let ((portal-web-zoom-levels '(("other.org" . 50))))
      (portal-open-url "https://Example.com/page")
      (setq portal-fake-native-log nil)
      (call-interactively (key-binding "+"))
      (call-interactively (key-binding (kbd "s-=")))
      (should (equal portal-web-zoom-levels '(("example.com" . 125) ("other.org" . 50))))
      (portal-web-test--messages
        (call-interactively (key-binding "-"))
        (should (equal portal-web-test--messages '("Zoom 115% for example.com"))))
      (call-interactively (key-binding "0"))
      (should (equal portal-web-zoom-levels '(("other.org" . 50))))
      (should (equal (portal-fake-native-calls 'portal--web-zoom)
                     '(("example.com" 115) ("example.com" 125) ("example.com" 115)
                       ("example.com" 100))))
      ;; The steps end; local pages share one level.
      (let ((portal-web-zoom-steps '(90 100 110)))
        (portal-open-url "data:text/html,hi")
        (setq portal-fake-native-log nil)
        (portal-web-test--messages
          (dotimes (_ 3) (portal-web-zoom-out))
          (should (equal (car portal-web-test--messages) "Zoom 90% for local pages")))
        (should (equal (portal-fake-native-calls 'portal--web-zoom) '(("" 90) ("" 90) ("" 90)))))
      (should (equal portal-web-zoom-levels '(("" . 90) ("other.org" . 50))))
      ;; The module learns every level when it loads.
      (setq portal-fake-native-log nil)
      (run-hooks 'portal-view-load-hook)
      (should (equal (portal-fake-native-calls 'portal--web-zoom) '(("" 90) ("other.org" 50))))
      (require 'savehist)
      (should (memq 'portal-web-zoom-levels savehist-additional-variables)))))

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

;; The address bar and bookmarks.

(defun portal-web-test--type (command keys)
  "Run COMMAND and type KEYS, in `kbd' notation, into a real minibuffer.
Batch Emacs reads a keyboard macro's keys in a real minibuffer, so the
address bar's selection and completion run as they do for a person."
  (let ((map (make-sparse-keymap))
        (global (current-global-map)))
    (keymap-set map "<f12>" command)
    (set-keymap-parent map global)
    (use-global-map map)
    (unwind-protect
        (execute-kbd-macro (vconcat (kbd "<f12>") (kbd keys)))
      (use-global-map global))
    (should-not (active-minibuffer-window))))

(defmacro portal-web-test--bookmarks (&rest body)
  "Run BODY with no bookmarks, in a bookmark file of its own that it never saves."
  (declare (indent 0))
  `(let* ((bookmark-default-file (make-temp-name
                                  (expand-file-name "portal-bookmarks-" temporary-file-directory)))
          (bookmark-alist nil)
          (bookmark-bookmarks-timestamp nil)
          (bookmark-save-flag nil)
          (bookmark-current-bookmark nil)
          (bookmark-history nil)
          (bookmark-fringe-mark nil)
          (bookmark-automatically-show-annotations nil))
     ,@body
     (should-not (file-exists-p bookmark-default-file))))

(ert-deftest portal-web-address-bar-tells-urls-from-searches ()
  (let ((portal-web-search-url "https://www.google.com/search?q=%s")
        (candidates (list (cons (propertize "Docs  https://docs.example.com/"
                                            'portal-web-url "https://docs.example.com/")
                                "https://docs.example.com/"))))
    (dolist (case '(;; A suggestion gives its URL.
                    ("Docs  https://docs.example.com/" . "https://docs.example.com/")
                    ;; A URL a web view loads stands as typed.
                    ("https://example.com/a?b=c" . "https://example.com/a?b=c")
                    ("  http://example.com/  " . "http://example.com/")
                    ("about:blank" . "about:blank")
                    ("file:///tmp/a.html" . "file:///tmp/a.html")
                    ;; A host, with a port or a path, is a site.
                    ("example.com" . "https://example.com")
                    ("www.example.co.uk:8443" . "https://www.example.co.uk:8443")
                    ("192.168.1.1" . "https://192.168.1.1")
                    ("en.wikipedia.org/wiki/Free software" . "https://en.wikipedia.org/wiki/Free%20software")
                    ("myhost:8080/status" . "https://myhost:8080/status")
                    ;; Local servers rarely have certificates.
                    ("localhost" . "http://localhost")
                    ("localhost:3000/app" . "http://localhost:3000/app")
                    ;; Anything else searches, each word percent-encoded.
                    ("emacs" . "https://www.google.com/search?q=emacs")
                    ("what is c++ & why" . "https://www.google.com/search?q=what+is+c%2B%2B+%26+why")
                    ("example.com is down" . "https://www.google.com/search?q=example.com+is+down")
                    ("note: buy milk" . "https://www.google.com/search?q=note%3A+buy+milk")
                    ("javascript:alert(1)" . "https://www.google.com/search?q=javascript%3Aalert%281%29")))
      (should (equal (portal-web--resolve (car case) candidates) (cdr case))))
    ;; A suggestion's string, as a completion framework returns it.
    (should (equal (portal-web--resolve (propertize "renamed" 'portal-web-url "https://a.example/")
                                        nil)
                   "https://a.example/"))
    (let ((portal-web-search-url "https://duckduckgo.com/?q=%s"))
      (should (equal (portal-web--resolve "two words" nil) "https://duckduckgo.com/?q=two+words")))
    (should-error (portal-web--resolve "  " nil) :type 'user-error)))

(ert-deftest portal-web-address-bar-starts-with-the-current-url-selected ()
  (portal-web-test--environment
    (portal-open-url "http://example.com/page")
    (let ((target (portal-view-target))
          (portal-web-search-url "https://search.example/?q=%s"))
      (dolist (case '(;; A typed character replaces the URL.
                      ("e m a c s RET" . "https://search.example/?q=emacs")
                      ;; Backspace clears it.
                      ("DEL e x a m p l e . o r g RET" . "https://example.org")
                      ;; Left keeps it, with the cursor at its start.
                      ("<left> <right> <right> <right> <right> s RET" . "https://example.com/page")
                      ;; Right keeps it, with the cursor at its end.
                      ("<right> / a RET" . "http://example.com/page/a")
                      ;; Other commands keep it as text too.
                      ("C-a C-k a b o u t : b l a n k RET" . "about:blank")
                      ;; RET loads it again.
                      ("RET" . "http://example.com/page")))
        (dolist (transient '(nil t))
          (let ((transient-mark-mode transient))
            (portal-fake-native-commit target "http://example.com/page")
            (setq portal-fake-native-log nil)
            (portal-web-test--type #'portal-web-load-url (car case))
            (should (equal (portal-fake-native-calls 'portal--web-load)
                           `((,target ,(cdr case)))))
            (should (equal (portal-view-target) target)))))
      ;; Yanking replaces the URL too.
      (kill-new "https://example.net/")
      (portal-fake-native-commit target "http://example.com/page")
      (portal-web-test--type #'portal-web-load-url "C-y RET")
      (should (equal (plist-get (portal-web-test--state target) :url) "https://example.net/"))
      ;; Command-T opens what it reads in a new buffer, starting from this page.
      (setq portal-fake-native-log nil)
      (portal-web-test--type (key-binding (kbd "s-t")) "<right> b RET")
      (should-not (equal (portal-view-target) target))
      (should (equal (portal-fake-native-calls 'portal--web-load)
                     `((,(portal-view-target) "https://example.net/b"))))
      ;; Elsewhere, the minibuffer starts empty, and empty input asks for more.
      (switch-to-buffer "*scratch*")
      (let ((count (length (portal-view-buffers 'web))))
        (should-error (portal-web-test--type #'portal-open-url "RET") :type 'user-error)
        (portal-web-test--type #'portal-open-url "e x a m p l e . c o m RET")
        (should (equal (buffer-name) "*portal: example.com*"))
        (should (= (length (portal-view-buffers 'web)) (1+ count)))))))

(ert-deftest portal-web-bookmarks-are-ordinary-bookmarks-of-type-web ()
  (portal-web-test--environment
    (portal-web-test--bookmarks
      (portal-open-url "https://example.com/a")
      (let ((buffer (current-buffer))
            (target (portal-view-target)))
        ;; A page's bookmark takes its title, or its host without one.
        (should (equal (portal-web-bookmark-make-record)
                       '("example.com" (location . "https://example.com/a")
                         (handler . portal-web-bookmark-jump))))
        (portal-fake-native-title target "  Example\nA  ")
        (should (equal (car (portal-web-bookmark-make-record)) "Example A"))
        ;; C-x r m saves it as any bookmark, and Command-D starts from its title.
        (bookmark-set "Plain")
        (portal-web-test--type (key-binding (kbd "s-d")) "RET")
        (portal-fake-native-title target nil)
        (portal-web-test--type (key-binding (kbd "s-d")) "C-a D o c s SPC RET")
        (should (equal (bookmark-all-names) '("Docs example.com" "Example A" "Plain")))
        (dolist (name (bookmark-all-names))
          (should (equal (bookmark-location name) "https://example.com/a"))
          (should (equal (bookmark-type-from-full-record (bookmark-get-bookmark name)) "Web")))
        ;; A buffer without a page has nothing to bookmark, and nor does a hosted app.
        (with-temp-buffer
          (should-error (portal-web-bookmark-make-record) :type 'user-error))
        (cl-letf (((symbol-function 'portal-start-server) #'ignore)
                  ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token")))
          (portal-hello)
          (should-error (bookmark-set "Hello") :type 'user-error)
          (should-error (call-interactively #'portal-web-bookmark-set) :type 'user-error))
        (should-not (bookmark-get-bookmark "Hello" t))
        (should (buffer-live-p buffer))))))

(ert-deftest portal-web-bookmark-jumps-open-a-new-web-buffer-where-asked ()
  (portal-web-test--environment
    (portal-web-test--bookmarks
      (portal-open-url "https://example.com/a")
      (portal-fake-native-title (portal-view-target) "Example")
      (bookmark-set "Example")
      (let ((first (current-buffer)))
        ;; From any buffer, a jump opens a new web buffer, here.
        (switch-to-buffer "*scratch*")
        (setq portal-fake-native-log nil)
        (bookmark-jump "Example")
        (portal-view-sync)
        (should (eq major-mode 'portal-web-mode))
        (should-not (eq (current-buffer) first))
        (should (equal (buffer-name) "*portal: example.com*<2>"))
        (should (eq (window-buffer) (current-buffer)))
        (should (one-window-p))
        (should (equal (portal-fake-native-calls 'portal--web-load)
                       `((,(portal-view-target) "https://example.com/a"))))
        (should (plist-get (portal-web-test--state) :visible))
        ;; In another window, it leaves this one as it was.
        (switch-to-buffer "*scratch*")
        (let ((origin (selected-window)))
          (bookmark-jump-other-window "Example")
          (portal-view-sync)
          (should-not (eq (selected-window) origin))
          (should (eq (window-buffer origin) (get-buffer "*scratch*")))
          (should (equal (buffer-name (window-buffer)) "*portal: example.com*<3>"))
          (should (plist-get (portal-web-test--state) :visible)))
        (delete-other-windows)
        ;; Shift-B opens one from a web buffer, also in a new buffer.
        (switch-to-buffer first)
        (portal-web-test--type (key-binding "B") "E x a RET")
        (should (equal (buffer-name) "*portal: example.com*<4>"))
        (should (= (length (portal-view-buffers 'web)) 4))
        ;; A bookmark whose URL a web view cannot load opens nothing.
        (bookmark-store "Bad" '((location . "javascript:alert(1)")
                                (handler . portal-web-bookmark-jump))
                        nil)
        (should-error (bookmark-jump "Bad") :type 'user-error)
        (should (= (length (portal-view-buffers 'web)) 4))))))

(ert-deftest portal-web-bookmark-load-loads-in-this-buffer ()
  (portal-web-test--environment
    (portal-web-test--bookmarks
      (bookmark-store "Docs" '((location . "https://docs.example.org/guide")
                               (handler . portal-web-bookmark-jump))
                      nil)
      (bookmark-store "Notes" '((filename . "/tmp/notes.txt") (position . 1)) nil)
      (portal-open-url "https://example.com/a")
      (let ((buffer (current-buffer))
            (target (portal-view-target))
            shown)
        ;; The picker offers web pages' bookmarks only, as bookmarks.
        (cl-letf* ((read (symbol-function 'completing-read))
                   ((symbol-function 'completing-read)
                    (lambda (prompt table &rest arguments)
                      (setq shown (list (all-completions "" table)
                                        (completion-metadata-get
                                         (completion-metadata "" table nil) 'category)
                                        (funcall (completion-metadata-get
                                                  (completion-metadata "" table nil)
                                                  'annotation-function)
                                                 "Docs")))
                      (apply read prompt table arguments))))
          (setq portal-fake-native-log nil)
          (portal-web-test--type (key-binding "b") "d o c TAB RET"))
        (should (equal shown '(("Docs") bookmark "  https://docs.example.org/guide")))
        ;; The page loads in this buffer, which takes its name.
        (should (eq (current-buffer) buffer))
        (should (equal (portal-view-target) target))
        (should (equal (buffer-name) "*portal: docs.example.org*"))
        (should (equal (portal-fake-native-calls 'portal--web-load)
                       `((,target "https://docs.example.org/guide"))))
        (should (= (length (portal-view-buffers 'web)) 1))
        ;; A hosted app's buffer opens it in a new buffer instead.
        (cl-letf (((symbol-function 'portal-start-server) #'ignore)
                  ((symbol-function 'portal-server-url) (lambda () "http://127.0.0.1:1/token")))
          (portal-hello)
          (let ((hosted (current-buffer)))
            (portal-web-bookmark-load "Docs")
            (portal-view-sync)
            (should-not (eq (current-buffer) hosted))
            (should (equal (buffer-name) "*portal: docs.example.org*<2>"))
            (should (equal (plist-get (portal-web-test--state) :url)
                           "https://docs.example.org/guide"))))
        ;; With no web bookmarks, the picker says how to make one.
        (bookmark-delete "Docs")
        (should-error (portal-web-bookmark-open (portal-web-bookmark--read "Open: "))
                      :type 'user-error)))))

(ert-deftest portal-web-address-bar-suggests-bookmarks-by-title-or-url ()
  (portal-web-test--environment
    (portal-web-test--bookmarks
      (bookmark-store "Emacs manual" '((location . "https://www.gnu.org/software/emacs/manual/")
                                       (handler . portal-web-bookmark-jump))
                      nil)
      (bookmark-store "Notes" '((filename . "/tmp/notes.txt") (position . 1)) nil)
      (portal-open-url "https://example.com/")
      (let ((target (portal-view-target)))
        (dolist (keys '("m a n u a l TAB RET" "g n u . o r g TAB RET"))
          (setq portal-fake-native-log nil)
          (portal-web-test--type #'portal-web-load-url keys)
          (should (equal (portal-fake-native-calls 'portal--web-load)
                         `((,target "https://www.gnu.org/software/emacs/manual/")))))
        ;; Only web pages' bookmarks are suggestions, grouped as bookmarks.
        (let (table)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _)
                       (setq table collection)
                       "x")))
            (portal-web-read-url "URL: "))
          (let* ((candidates (all-completions "" table))
                 (metadata (completion-metadata "" table nil)))
            (should (equal (mapcar #'substring-no-properties candidates)
                           '("Emacs manual  https://www.gnu.org/software/emacs/manual/")))
            (should (equal (get-text-property 0 'portal-web-url (car candidates))
                           "https://www.gnu.org/software/emacs/manual/"))
            (should (eq (completion-metadata-get metadata 'category) 'portal-web-url))
            (should (equal (funcall (completion-metadata-get metadata 'group-function)
                                    (car candidates) nil)
                           "Bookmark"))
            (should (equal (funcall (completion-metadata-get metadata 'group-function)
                                    (car candidates) t)
                           (car candidates)))))))))

;; A fresh Emacs, with nothing to keep, is the only way to load less.
(ert-deftest portal-web-bookmarks-work-when-only-the-web-feature-loaded ()
  ;; An autoloaded command, such as `portal-open-url', loads `portal-web'
  ;; alone, not the package root that loads every feature.
  (let* ((root (file-name-directory (locate-library "portal")))
         (fake (symbol-file 'portal-fake-native-reset))
         (form
          `(progn
             (setq load-path (cons ,root load-path)
                   bookmark-default-file (make-temp-name
                                          (expand-file-name "portal-bookmarks-" temporary-file-directory))
                   bookmark-save-flag nil)
             (load ,fake nil t)
             (require 'portal-web)
             (cl-assert (not (featurep 'portal-web-bookmark)))
             (portal-open-url "https://example.com/a")
             (cl-assert (eq (keymap-lookup nil "s-d") 'portal-web-bookmark-set))
             (cl-assert (eq (keymap-lookup nil "b") 'portal-web-bookmark-load))
             (cl-assert (eq (keymap-lookup nil "B") 'portal-web-bookmark-open))
             (portal-web-bookmark-set "Saved")
             (cl-assert (equal (bookmark-location "Saved") "https://example.com/a"))
             (cl-assert (equal (cdr (assoc "Bookmark" (mapcar (lambda (source)
                                                                (cons (car source) (funcall (cdr source))))
                                                              portal-web-omnibox-sources)))
                               '(("Saved  https://example.com/a" . "https://example.com/a")))))))
    (with-temp-buffer
      (let ((status (call-process (expand-file-name invocation-name invocation-directory)
                                  nil t nil "--batch" "-Q" "--eval" (prin1-to-string form))))
        (ert-info ((buffer-string))
          (should (eq status 0)))))))

(provide 'portal-web-tests)
;;; portal-web-tests.el ends here
