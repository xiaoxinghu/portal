;;; portal-server-tests.el --- Compiled UI host integration -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'url)
(require 'portal-server)

(when-let* ((program (getenv "PORTAL_TEST_HOST")))
  (setq portal-server-program program))

(defun portal-server-test--wait (predicate)
  "Allow asynchronous process work until PREDICATE succeeds."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro portal-server-test--with-host (&rest body)
  (declare (indent 0))
  `(let ((portal-server-ready-hook nil))
     (unwind-protect (progn ,@body)
       (let ((process portal--server-process))
         (portal-stop-server)
         (when process
           (portal-server-test--wait (lambda () (not (process-live-p process)))))))))

(defun portal-server-test--get (path)
  "Fetch PATH from the real HTTP listener."
  (let* ((url-proxy-services nil)
         (buffer (url-retrieve-synchronously
                  (concat (portal-server-url) path) t t 3)))
    (should (buffer-live-p buffer))
    (unwind-protect
        (with-current-buffer buffer (buffer-string))
      (kill-buffer buffer))))

(ert-deftest portal-server-load-is-lazy ()
  (should-not (portal-server-url))
  (let ((before (process-list)))
    (load "portal-server" nil t)
    (should (equal before (process-list)))))

(ert-deftest portal-server-standalone-serves-without-bun-or-source-assets ()
  (let* ((directory (make-temp-file "portal-standalone-" t))
         (program (expand-file-name "host" directory)))
    (unwind-protect
        (progn
          (copy-file (portal-server-program-file) program)
          (let ((portal-server-program program)
                (process-environment (cons "PATH=/nonexistent" process-environment)))
            (portal-server-test--with-host
              (let ((process (portal-start-server)))
                ;; Two simultaneous startup requests must share one child.
                (should (eq process (portal-start-server)))
                (portal-server-test--wait #'portal-server-url)
                (should (eq process (portal-start-server)))
                (let ((page (portal-server-test--get "/hello")))
                  (should (string-match-p "HTTP/1.1 200" page))
                  (should (string-match-p "text/html; charset=utf-8" page))
                  (should (string-match-p "<h1>Hello, world!</h1>" page)))
                (should (string-match-p "<title>Dialogs</title>"
                                        (portal-server-test--get "/dialogs")))
                (let ((file (expand-file-name "note.md" directory)))
                  (with-temp-file file (insert "# Standalone Markdown\n"))
                  (let ((page (portal-server-test--get
                               (concat "/markdown?path=" (url-hexify-string file)))))
                    (should (string-match-p "Standalone Markdown</h1>" page))
                    (should (string-match-p "color-scheme: light dark" page))))
                (should (string-match-p "HTTP/1.1 404"
                                        (portal-server-test--get "/missing")))
                (let ((page (portal-server-test--get "/excalidraw/")))
                  (should (string-match-p "HTTP/1.1 200" page))
                  (should (string-match-p "[Cc]ontent-[Ss]ecurity-[Pp]olicy:" page))
                  (should (string-match-p "font-src 'self' data:" page)))
                (dolist (asset '("/excalidraw/assets/editor-bootstrap.js"
                                 "/excalidraw/assets/editor-bootstrap.css"
                                 "/excalidraw/assets/fonts/Excalifont/Excalifont-Regular-a88b72a24fb54c9f94e3b5fdaa7481c9.woff2"))
                  (should (string-match-p "HTTP/1.1 200" (portal-server-test--get asset))))
                (portal-stop-server)
                (portal-server-test--wait (lambda () (not (process-live-p process))))
                (should (= (process-exit-status process) 0))))))
      (delete-directory directory t))))

(ert-deftest portal-server-restarts-and-recovers-after-a-crash ()
  (portal-server-test--with-host
    (let ((first (portal-start-server)))
      (portal-server-test--wait #'portal-server-url)
      (let ((second (portal-restart-server)))
        (should-not (eq first second))
        (portal-server-test--wait #'portal-server-url)
        (portal-server-test--wait (lambda () (not (process-live-p first))))
        ;; The old child's exit must leave the replacement server usable.
        (should (string-match-p "Hello, world!" (portal-server-test--get "/hello")))
        (signal-process second 'SIGKILL)
        (portal-server-test--wait (lambda () (not (portal-server-url))))
        (should-not portal--server-process)
        (let ((third (portal-start-server)))
          (should-not (eq second third))
          (portal-server-test--wait #'portal-server-url)
          (should (string-match-p "Hello, world!" (portal-server-test--get "/hello"))))))))

(ert-deftest portal-server-markdown-renders-saved-files-and-rereads-changes ()
  (let* ((directory (make-temp-file "portal-markdown-" t))
         (file (expand-file-name "Résumé & <notes> #%?.md" directory))
         (path (concat "/markdown?path=" (url-hexify-string file))))
    (unwind-protect
        (portal-server-test--with-host
          (with-temp-file file
            (insert "# Preview\n\n**Bold** and ~~old~~.\n\n"
                    "| Name | Value |\n| --- | --- |\n| One | Two |\n\n"
                    "- [x] Done\n\n```js\nconst value = 1 < 2;\n```\n\n"
                    "<script>document.title = 'Injected';</script>\n\n"
                    "<img src=x onerror=alert(1)>\n"))
          (portal-start-server)
          (portal-server-test--wait #'portal-server-url)
          (let ((page (portal-server-test--get path)))
            (dolist (text '("HTTP/1.1 200" "text/html; charset=utf-8"
                            "<h1 id=\"preview\">Preview</h1>" "<strong>Bold</strong>"
                            "<del>old</del>" "<table>" "type=\"checkbox\""
                            "<pre><code" "1 &lt; 2" "&amp; &lt;notes&gt;"
                            "&lt;script&gt;" "&lt;img"))
              (should (string-match-p (regexp-quote text) page)))
            (should-not (string-match-p "<script>" page))
            (should-not (string-match-p "<img src=x" page))
            (let ((case-fold-search t))
              (should (string-match-p "content-security-policy:.*default-src 'none'" page))
              (should (string-match-p "referrer-policy: no-referrer" page))
              (should (string-match-p "cache-control: no-store" page))))
          (with-temp-file file (insert "# Updated on disk\n"))
          (let ((page (portal-server-test--get path)))
            (should (string-match-p "Updated on disk</h1>" page))
            (should-not (string-match-p "<strong>Bold</strong>" page))))
      (delete-directory directory t))))

(defun portal-server-test--href (page text)
  "Return the href of the link with TEXT in Markdown PAGE."
  (should (string-match (format "<a href=\"\\([^\"]*\\)\"[^>]*>%s</a>" (regexp-quote text)) page))
  (match-string 1 page))

(ert-deftest portal-server-markdown-rewrites-local-links ()
  (let* ((directory (make-temp-file "portal-markdown-" t))
         (docs (expand-file-name "docs é" directory))
         (file (expand-file-name "Guide.md" docs))
         (preview (lambda (path)
                    (concat "markdown?path=" (url-hexify-string (expand-file-name path docs)))))
         (visit (lambda (path)
                  (concat "file://" (url-hexify-string (expand-file-name path docs)
                                                       (cons ?/ url-unreserved-chars))))))
    (unwind-protect
        (portal-server-test--with-host
          (make-directory docs)
          (with-temp-file file
            (insert "# Top\n\n[same](#top) [other](other%20file.md#next-steps) "
                    "[up](../README.MD) [résumé](résumé.md) [amp](a&b.md) [missing](gone.md) "
                    "[code](<src/main file.ts#L42-L50>) [image](img/pic.png) [dir](src/) "
                    "[absolute](/tmp/abs.markdown#x) [file](file:///tmp/x%20y.ts#L3) "
                    "[web](https://example.com/a.md) [mail](mailto:a@example.com)\n"))
          (portal-start-server)
          (portal-server-test--wait #'portal-server-url)
          (let ((page (decode-coding-string
                       (portal-server-test--get (concat "/markdown?path=" (url-hexify-string file)))
                       'utf-8)))
            (dolist (link `(("same" . "#top")
                            ("other" . ,(concat (funcall preview "other file.md") "#next-steps"))
                            ("up" . ,(funcall preview "../README.MD"))
                            ("résumé" . ,(funcall preview "résumé.md"))
                            ("amp" . ,(funcall preview "a&b.md"))
                            ("missing" . ,(funcall preview "gone.md"))
                            ("code" . ,(concat (funcall visit "src/main file.ts") "#L42-L50"))
                            ("image" . ,(funcall visit "img/pic.png"))
                            ("dir" . ,(funcall visit "src/"))
                            ("absolute" . "markdown?path=%2Ftmp%2Fabs.markdown#x")
                            ("file" . "file:///tmp/x%20y.ts#L3")
                            ("web" . "https://example.com/a.md")
                            ("mail" . "mailto:a@example.com")))
              (ert-info ((car link))
                (should (equal (portal-server-test--href page (car link)) (cdr link)))))))
      (delete-directory directory t))))

;; A pixel PNG, as written to disk and as served.
(defconst portal-server-test--png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII="))

(defun portal-server-test--src (page alt)
  "Return the src of the image with ALT in Markdown PAGE."
  (should (string-match (format "<img src=\"\\([^\"]*\\)\" alt=\"%s\"" (regexp-quote alt)) page))
  (match-string 1 page))

(ert-deftest portal-server-markdown-serves-local-images ()
  (let* ((directory (make-temp-file "portal-markdown-" t))
         (docs (expand-file-name "docs é" directory))
         (file (expand-file-name "Guide.md" docs))
         (pic (expand-file-name "img/a&b pic.PNG" docs))
         (source (lambda (path)
                   (concat "image?path=" (url-hexify-string (expand-file-name path docs))))))
    (unwind-protect
        (portal-server-test--with-host
          (make-directory (file-name-directory pic) t)
          (let ((coding-system-for-write 'binary))
            (write-region portal-server-test--png nil pic))
          (with-temp-file file
            (insert "# Pictures\n\n![relative](<img/a&b pic.PNG>) ![encoded](img/a%26b%20pic.PNG#x) "
                    "![up](../top.svg) ![absolute](/tmp/abs.gif) ![file](file:///tmp/x%20y.jpg) "
                    "![web](https://example.com/a.png) ![data](data:image/png;base64,AAAA)\n"))
          (portal-start-server)
          (portal-server-test--wait #'portal-server-url)
          (let ((page (decode-coding-string
                       (portal-server-test--get (concat "/markdown?path=" (url-hexify-string file)))
                       'utf-8)))
            (dolist (image `(("relative" . ,(funcall source "img/a&b pic.PNG"))
                             ("encoded" . ,(concat (funcall source "img/a&b pic.PNG") "#x"))
                             ("up" . ,(funcall source "../top.svg"))
                             ("absolute" . "image?path=%2Ftmp%2Fabs.gif")
                             ("file" . "image?path=%2Ftmp%2Fx%20y.jpg")
                             ("web" . "https://example.com/a.png")
                             ("data" . "data:image/png;base64,AAAA")))
              (ert-info ((car image))
                (should (equal (portal-server-test--src page (car image)) (cdr image)))))
            (let ((case-fold-search t))
              (should (string-match-p "content-security-policy:.*img-src 'self'" page))))
          ;; The page loads its images relative to itself, from the host.
          (let ((response (portal-server-test--get
                           (concat "/" (funcall source "img/a&b pic.PNG")))))
            (should (string-match-p "HTTP/1.1 200" response))
            (let ((case-fold-search t))
              (should (string-match-p "content-type: image/png" response))
              (should (string-match-p "content-security-policy:.*sandbox" response)))
            (should (string-suffix-p portal-server-test--png response)))
          ;; Only absolute paths to image files, never other files.
          (dolist (path (list "image" "image?path=relative.png"
                              "image?path=%2Ftmp%2Fbad%00.png"
                              (concat "image?path=" (url-hexify-string file))
                              (concat "image?path=" (url-hexify-string
                                                     (file-name-directory pic)))))
            (ert-info (path)
              (should (string-match-p "HTTP/1.1 400"
                                      (portal-server-test--get (concat "/" path))))))
          (should (string-match-p "HTTP/1.1 404"
                                  (portal-server-test--get
                                   (concat "/" (funcall source "missing.png")))))
          (set-file-modes pic 0)
          (should (string-match-p "HTTP/1.1 403"
                                  (portal-server-test--get
                                   (concat "/" (funcall source "img/a&b pic.PNG"))))))
      (delete-directory directory t))))

(ert-deftest portal-server-markdown-rejects-invalid-requests ()
  (let ((directory (make-temp-file "portal-markdown-" t)))
    (unwind-protect
        (portal-server-test--with-host
          (portal-start-server)
          (portal-server-test--wait #'portal-server-url)
          (dolist (path (list "/markdown" "/markdown?path=relative.md"
                             "/markdown?path=%2Ftmp%2Fbad%00.md"
                             (concat "/markdown?path=" (url-hexify-string directory))))
            (let ((page (portal-server-test--get path)))
              (should (string-match-p "HTTP/1.1 400" page))
              (should (string-match-p "Cannot preview this file" page))))
          (should (string-match-p
                   "HTTP/1.1 404"
                   (portal-server-test--get
                    (concat "/markdown?path="
                            (url-hexify-string (expand-file-name "missing.md" directory))))))
          (let ((url-request-method "POST"))
            (should (string-match-p "HTTP/1.1 405"
                                    (portal-server-test--get "/markdown"))))
          (let ((url-request-method "HEAD"))
            (let ((page (portal-server-test--get "/hello")))
              (should (string-match-p "HTTP/1.1 200" page))
              (should-not (string-match-p "Hello, world!" page))))
          ;; Changing the capability or Host header must never reach file reads.
          (let ((base (portal-server-url)))
            (cl-letf (((symbol-function 'portal-server-url)
                       (lambda () (concat base "wrong"))))
              (should (string-match-p "HTTP/1.1 404"
                                      (portal-server-test--get "/markdown")))))
          (let ((url-request-extra-headers '(("Host" . "example.invalid"))))
            (should (string-match-p "HTTP/1.1 404"
                                    (portal-server-test--get "/markdown")))))
      (delete-directory directory t))))

(ert-deftest portal-server-about-names-versions-as-text ()
  (portal-server-test--with-host
    (portal-start-server)
    (portal-server-test--wait #'portal-server-url)
    (let ((page (portal-server-test--get
                 (concat "/about?portal=1.2.3&emacs="
                         (url-hexify-string "31.1<script>alert(1)</script>")))))
      (should (string-match-p "HTTP/1.1 200" page))
      (should (string-match-p "text/html; charset=utf-8" page))
      (should (string-match-p "[Cc]ontent-[Ss]ecurity-[Pp]olicy: default-src 'none'" page))
      (should (string-match-p "portal \\.+ 1\\.2\\.3<" page))
      ;; Emacs supplies the versions; the page shows them, never runs them.
      (should (string-match-p "emacs \\.+ 31\\.1&lt;script&gt;" page))
      (should-not (string-match-p "<script>alert" page))
      (should (string-match-p "bun \\.+ [0-9]+\\.[0-9]+\\.[0-9]+<" page))
      (should-not (string-match-p "{{" page)))
    (let ((page (portal-server-test--get "/about")))
      (should (string-match-p "portal \\.+ unknown<" page))
      (should (string-match-p "emacs \\.+ unknown<" page)))))

(ert-deftest portal-server-startup-timeout-cleans-up ()
  (let ((portal-server-program "/bin/cat")
        (portal-server-start-timeout 0.05))
    (portal-server-test--with-host
      (let ((process (portal-start-server)))
        (portal-server-test--wait (lambda () (not (process-live-p process))))
        (should-not (portal-server-url))
        (should-not portal--server-process)))))

(ert-deftest portal-server-early-exit-clears-startup ()
  (let ((portal-server-program "/usr/bin/false"))
    (portal-server-test--with-host
      (let ((process (portal-start-server)))
        ;; The sentinel runs after the process is seen to exit.
        (portal-server-test--wait (lambda () (not (process-live-p process))))
        (portal-server-test--wait (lambda () (not portal--server-process)))
        (should-not (portal-server-url))))))

(ert-deftest portal-server-readiness-can-arrive-in-pieces ()
  (let ((program (make-temp-file "portal-handshake-")))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\nprintf '%s' '{\"type\":\"ready\",'\nsleep 0.05\n"
                    "printf '%s\\n' '\"protocol\":3,\"port\":12345,\"token\":\"0123456789abcdef0123456789abcdef\"}'\ncat >/dev/null\n"))
          (set-file-modes program #o700)
          (let ((portal-server-program program))
            (portal-server-test--with-host
              (portal-start-server)
              (portal-server-test--wait #'portal-server-url)
              (should (equal (portal-server-url)
                             "http://127.0.0.1:12345/0123456789abcdef0123456789abcdef")))))
      (delete-file program))))

(ert-deftest portal-server-rejects-incompatible-handshake ()
  (let ((program (make-temp-file "portal-handshake-")))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"ready\",\"protocol\":1,\"port\":12345}'\n"
                    "exec cat >/dev/null\n"))
          (set-file-modes program #o700)
          (let ((portal-server-program program))
            (portal-server-test--with-host
              (let ((process (portal-start-server)))
                (portal-server-test--wait (lambda () (not (process-live-p process))))
                (should-not (portal-server-url))))))
      (delete-file program))))

;;; portal-server-tests.el ends here
