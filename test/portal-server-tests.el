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
          (copy-file portal-server-program program)
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
        ;; The URL goes as soon as the process dies; its sentinel, which runs
        ;; later, forgets the process.
        (portal-server-test--wait (lambda () (not portal--server-process)))
        (should-not (portal-server-url))
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

;; Task browser.

(defun portal-server-test--write (directory name &rest text)
  "Write TEXT to file NAME in DIRECTORY, creating its folders."
  (let ((file (expand-file-name name directory)))
    (make-directory (file-name-directory file) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file file (apply #'insert text)))
    file))

(defun portal-server-test--tasks (root &optional query)
  "Fetch the task browser page for ROOT with extra QUERY, as decoded text."
  (decode-coding-string
   (portal-server-test--get (concat "/tasks?root=" (url-hexify-string root) query))
   'utf-8))

(defun portal-server-test--rows (page)
  "Return the (TITLE HREF) of each task row in PAGE, in order."
  (let ((start 0) rows)
    (while (string-match "<a class=\"row\\(?: blocked\\)?\\(?: done\\)?\" href=\"\\([^\"]*\\)\">\\(?:<span class=\"rank\">[0-9]+</span>\\)?\\(?:<span class=\"status status-done\">done</span>\\)?<span class=\"title\">\\([^<]*\\)</span>"
                         page start)
      (push (list (match-string 2 page) (match-string 1 page)) rows)
      (setq start (match-end 0)))
    (nreverse rows)))

(defun portal-server-test--part (page open close)
  "Return the text of PAGE between OPEN and the next CLOSE, or nil."
  (when (string-match (concat (regexp-quote open) "\\(\\(?:.\\|\n\\)*?\\)" (regexp-quote close)) page)
    (match-string 1 page)))

(defun portal-server-test--tree (page)
  "Return PAGE's tree view as an outline, one line per row.
A group is its name and a slash; a task is its title, then its rank as
#N when it has one, and (done) when it is done.  Rows it holds follow,
indented by two spaces."
  (let ((start (string-search "<ul class=\"tree\">" page))
        (depth -1)
        lines)
    (while (and start
                (string-match (concat "\\(<ul class=\"tree\">\\)\\|\\(</ul>\\)"
                                      "\\|<span class=\"name\">\\([^<]*\\)</span>"
                                      "\\|<a class=\"row[^\"]*\"[^>]*>\\(?:<span class=\"rank\">\\([0-9]+\\)</span>\\)?"
                                      "\\(?:<span class=\"status status-\\([a-z]+\\)\">[a-z]+</span>\\)?"
                                      "<span class=\"title\">\\([^<]*\\)</span>")
                              page start))
      (setq start (match-end 0))
      (let ((indent (make-string (* 2 (max depth 0)) ?\s)))
        (cond ((match-beginning 1) (setq depth (1+ depth)))
              ((match-beginning 2) (setq depth (1- depth))
               (when (< depth 0) (setq start nil)))
              ((match-beginning 3) (push (concat indent (match-string 3 page) "/") lines))
              (t (push (concat indent (match-string 6 page)
                               (if (match-beginning 4) (concat " #" (match-string 4 page)) "")
                               (if (equal (match-string 5 page) "done") " (done)" ""))
                       lines)))))
    (nreverse lines)))

(defun portal-server-test--order (page)
  "Return the titles of PAGE's ordered unfinished tasks, in order."
  (mapcar #'car (portal-server-test--rows
                 (or (portal-server-test--part page "<ol class=\"tasks\">" "</ol>") ""))))

(defun portal-server-test--stuck (page)
  "Return the titles of PAGE's tasks blocked by dependency problems."
  (mapcar #'car (portal-server-test--rows
                 (or (portal-server-test--part page "<section class=\"stuck\">" "</section>") ""))))

(defun portal-server-test--completed (page)
  "Return the titles of PAGE's completed section."
  (mapcar #'car (portal-server-test--rows
                 (or (portal-server-test--part page "<section class=\"completed\">" "</section>") ""))))

(defun portal-server-test--waits (page title)
  "Return what the row titled TITLE in PAGE waits for, \"\" when ready, or nil."
  (when (string-match (concat "<span class=\"title\">" (regexp-quote title)
                              "</span>\\(?:<span class=\"folder\">[^<]*</span>\\)?"
                              "\\(?:<span class=\"waits[^\"]*\">\\([^<]*\\)</span>\\)?</a>")
                      page)
    (or (match-string 1 page) "")))

(defmacro portal-server-test--with-tasks (&rest body)
  "Run BODY with the host started and ROOT a fresh, real task folder."
  (declare (indent 0))
  `(let* ((directory (file-truename (make-temp-file "portal-tasks-" t)))
          (root (expand-file-name "tasks é" directory)))
     (unwind-protect
         (portal-server-test--with-host
           (make-directory root)
           (portal-start-server)
           (portal-server-test--wait #'portal-server-url)
           ,@body)
       (delete-directory directory t))))

(ert-deftest portal-server-tasks-discover-a-mixed-root-recursively ()
  (portal-server-test--with-tasks
    (let ((hex (url-hexify-string root)))
      (portal-server-test--write root "fix-search.md" "---\nstatus: todo\n---\n\n# Fix *search* & <more>\n")
      (portal-server-test--write root "B-upper.md" "---\nstatus: todo\ntitle: \"  From front matter  \"\n---\n# Ignored\n")
      (portal-server-test--write root "no-heading.md" "---\nstatus: todo\nlabels: [x]\n---\nJust text.\n")
      (portal-server-test--write root "fenced.md" "---\nstatus: todo\n---\n```\n# Not a title\n```\n\nSetext title\n============\n")
      (portal-server-test--write root "crlf.md" "\uFEFF---\r\nstatus: done\r\n---\r\n# Windows\r\n")
      (portal-server-test--write root "markdown-navigation/content.md" "---\nstatus: done\n---\n# Navigation\n")
      (portal-server-test--write root "markdown-navigation/implementation-notes.md" "---\nstatus: todo\n---\n# Supporting\n")
      (portal-server-test--write root "markdown-navigation/deeper/content.md" "---\nstatus: todo\n---\n# Deeper\n")
      (portal-server-test--write root "no-content/other.md" "---\nstatus: todo\n---\n# Other\n")
      (portal-server-test--write root "Content-case/Content.md" "---\nstatus: todo\n---\n# Case\n")
      (portal-server-test--write root "README.md" "# Read me\n")
      (portal-server-test--write root "empty-matter.md" "---\n---\n# Empty\n")
      (portal-server-test--write root "notes.txt" "---\nstatus: todo\n---\n")
      (portal-server-test--write root "body-status.md" "# Status\n\nstatus: todo\n")
      (portal-server-test--write root "content.md" "---\nstatus: todo\n---\n# Root content\n")
      (make-symbolic-link (expand-file-name "fix-search.md" root) (expand-file-name "alias.md" root))
      (make-symbolic-link (expand-file-name "markdown-navigation" root) (expand-file-name "alias-folder" root))
      (let ((page (portal-server-test--tasks root)))
        (should (string-match-p "HTTP/1.1 200" page))
        (let ((case-fold-search t))
          (should (string-match-p "cache-control: no-store" page)))
        ;; Supporting Markdown with a status is a task at any depth.
        (should (equal (portal-server-test--tree page)
                       '("From front matter #1"
                         "Content-case/" "  Case #2"
                         "Root content #3"
                         "Setext title #4"
                         "Fix search &amp; &lt;more&gt; #5"
                         "Navigation (done)" "  Deeper #6" "  Supporting #7"
                         "no-content/" "  Other #8"
                         "no-heading #9")))
        (should (equal (cl-subseq (portal-server-test--rows page) 0 2)
                       `(("From front matter" ,(concat "tasks?root=" hex "&amp;task=B-upper"))
                         ("Case" ,(concat "tasks?root=" hex "&amp;task=Content-case%2FContent")))))
        (should (string-match-p (regexp-quote (concat "tasks?root=" hex "&amp;show=all\">Show completed")) page))
        (should (string-match-p (regexp-quote (concat "<span aria-current=\"page\">Tree</span><a href=\"tasks?root="
                                                      hex "&amp;view=execution\">Execution</a>"))
                                page))
        (should-not (string-match-p "<h2>Problems" page)))
      ;; Completed tasks follow the unfinished ones, in their own section.
      (let ((page (portal-server-test--tasks root "&view=execution&show=all")))
        (should (equal (portal-server-test--order page)
                       '("From front matter" "Case" "Root content" "Setext title" "Fix search &amp; &lt;more&gt;"
                         "Deeper" "Supporting" "Other" "no-heading")))
        (should (equal (portal-server-test--completed page) '("Windows" "Navigation"))))
      (should (string-match-p "Hide completed" (portal-server-test--tasks root "&show=all"))))))

(ert-deftest portal-server-tasks-report-problems-without-hiding-tasks ()
  (portal-server-test--with-tasks
    (portal-server-test--write root "good.md" "---\nstatus: todo\n---\n# Good\n")
    (dolist (bad '(("unclosed.md" . "---\nstatus: todo\n# Never closed\n")
                   ("yaml.md" . "---\nstatus: [todo\n---\n")
                   ("list.md" . "---\n- status\n---\n")
                   ("capital.md" . "---\nstatus: Todo\n---\n")
                   ("empty.md" . "---\nstatus:\n---\n")
                   ("blank-title.md" . "---\nstatus: todo\ntitle: \"\"\n---\n")
                   ("number-title.md" . "---\nstatus: todo\ntitle: 3\n---\n")
                   ("unreadable.md" . "---\nstatus: todo\n---\n")
                   (".md" . "---\nstatus: todo\n---\n")
                   ("..md" . "---\nstatus: todo\n---\n")
                   ("...md" . "---\nstatus: todo\n---\n")))
      (portal-server-test--write root (car bad) (cdr bad)))
    (set-file-modes (expand-file-name "unreadable.md" root) 0)
    ;; Duplicates are found before the completed filter hides one of them.
    (portal-server-test--write root "twice.md" "---\nstatus: done\n---\n# Twice\n")
    (portal-server-test--write root "twice/content.md" "---\nstatus: todo\n---\n# Twice\n")
    (let ((page (portal-server-test--tasks root)))
      (should (equal (mapcar #'car (portal-server-test--rows page)) '("Good")))
      (should (string-match-p "<h2>Problems</h2>" page))
      (dolist (problem '(("unclosed.md" . "no closing --- line")
                         ("yaml.md" . "not valid YAML")
                         ("list.md" . "not a YAML mapping")
                         ("capital.md" . "Invalid status &quot;Todo&quot;")
                         ("empty.md" . "Invalid status null")
                         ("blank-title.md" . "Invalid title")
                         ("number-title.md" . "Invalid title")
                         ("unreadable.md" . "could not be read")
                         (".md" . "empty or reserved")
                         ("..md" . "empty or reserved")
                         ("...md" . "empty or reserved")))
        (ert-info ((car problem))
          (should (string-match-p (concat (regexp-quote (expand-file-name (car problem) root))
                                          "</code>: [^<]*" (regexp-quote (cdr problem)))
                                  page))))
      (should (string-match-p (concat "twice</a> is defined more than once: <code>"
                                      (regexp-quote (expand-file-name "twice.md" root)) "</code> and <code>"
                                      (regexp-quote (expand-file-name "twice/content.md" root)))
                              page))
      (let ((case-fold-search nil))
        (should-not (string-match-p "Twice" (portal-server-test--tasks root "&show=all")))))
    (let ((page (portal-server-test--tasks root "&task=twice")))
      (should (string-match-p "HTTP/1.1 409" page))
      (should (string-match-p "defined more than once" page))
      (should (string-match-p (regexp-quote (format "<a href=\"tasks?root=%s\">Tasks</a>" (url-hexify-string root)))
                              page)))
    (let ((page (portal-server-test--tasks root "&task=capital&show=all")))
      (should (string-match-p "HTTP/1.1 422" page))
      (should (string-match-p "Invalid status" page))
      (should (string-match-p (regexp-quote "&amp;show=all\">Tasks</a>") page)))
    (set-file-modes (expand-file-name "unreadable.md" root) #o600)))

(ert-deftest portal-server-tasks-keep-their-id-and-reflect-saved-changes ()
  (portal-server-test--with-tasks
    (let* ((file (portal-server-test--write root "Fix search é.md" "---\nstatus: todo\n---\n# Fix\n\nFirst.\n"))
           (query (concat "&task=" (url-hexify-string "Fix search é"))))
      (should (string-match-p "First\\." (portal-server-test--tasks root query)))
      ;; Converting to a folder keeps the ID and the detail URL.
      (make-directory (expand-file-name "Fix search é" root))
      (rename-file file (expand-file-name "Fix search é/content.md" root))
      (portal-server-test--write root "Fix search é/content.md" "---\nstatus: todo\n---\n# Fix\n\nMoved.\n")
      (should (string-match-p "Moved\\." (portal-server-test--tasks root query)))
      ;; Completing it hides it from the default list only.
      (portal-server-test--write root "Fix search é/content.md" "---\nstatus: done\n---\n# Fix\n\nMoved.\n")
      (should-not (portal-server-test--rows (portal-server-test--tasks root)))
      (should (string-match-p "No unfinished tasks" (portal-server-test--tasks root)))
      (should (portal-server-test--rows (portal-server-test--tasks root "&show=all")))
      (let ((page (portal-server-test--tasks root query)))
        (should (string-match-p "HTTP/1.1 200" page))
        (should (string-match-p "status-done" page)))
      (should (file-exists-p (expand-file-name "Fix search é/content.md" root)))
      ;; Additions and removals show on the next request.
      (portal-server-test--write root "new.md" "---\nstatus: todo\n---\n# New\n")
      (should (equal (mapcar #'car (portal-server-test--rows (portal-server-test--tasks root))) '("New")))
      (delete-file (expand-file-name "new.md" root))
      (should (string-match-p "HTTP/1.1 404" (portal-server-test--tasks root "&task=new")))
      (should (string-match-p "There is no task" (portal-server-test--tasks root "&task=new"))))))

(ert-deftest portal-server-tasks-render-details-and-links ()
  (portal-server-test--with-tasks
    (let* ((hex (url-hexify-string root))
           (visit (lambda (path) (concat "file://" (url-hexify-string (expand-file-name path root)
                                                                     (cons ?/ url-unreserved-chars))))))
      (portal-server-test--write
       root "fix-search.md"
       "---\nstatus: todo\n---\n\n# Fix search\n\nBody text.\n\n"
       "[folder task](markdown-navigation/content.md#next-steps) [done](done.md) [same](#fix-search) "
       "[readme](README.md) [asset](assets/log%20file.txt) [outside](../outside.txt) [missing](gone.txt) "
       "[web](https://example.com/a.md)\n\n"
       "![shot](assets/search.png) ![remote](https://example.com/x.png)\n\n"
       "<script>alert(1)</script> <img src=x onerror=alert(1)>\n")
      (portal-server-test--write
       root "markdown-navigation/content.md"
       "---\nstatus: todo\ntitle: Navigation & links\n---\n# Body heading\n\n"
       "[notes](implementation-notes.md) [prototype](prototype/index.html) [back](../fix-search.md#x) "
       "[root file](../README.md) ![mockup](mockup.png)\n")
      (portal-server-test--write root "done.md" "---\nstatus: done\n---\nNo heading.\n")
      (portal-server-test--write root "README.md" "# Read me\n")
      (portal-server-test--write root "assets/log file.txt" "log\n")
      (portal-server-test--write directory "outside.txt" "outside\n")
      (let ((page (portal-server-test--tasks root "&task=fix-search")))
        (should (string-match-p "HTTP/1.1 200" page))
        (should (string-match-p (regexp-quote (format "<span class=\"breadcrumbs\"><a href=\"tasks?root=%s\">Tasks</a></span><span class=\"task-state\"><span class=\"status status-todo\">todo</span><span class=\"readiness readiness-ready\">ready</span>" hex)) page))
        ;; The heading supplies the title once, and front matter is gone.
        (should (= (length (split-string page "<h1")) 2))
        (should (string-match-p "<h1 id=\"fix-search\">Fix search</h1>" page))
        (should-not (string-match-p "status: todo" page))
        (should (string-match-p "&lt;script&gt;" page))
        ;; The task's content runs nothing; the page runs only its own script.
        (should-not (string-match-p "<script>\\|<img src=x"
                                    (portal-server-test--part page "<body>" "</body>")))
        (should (= (length (split-string page "<script>")) 2))
        (should (string-match-p "script-src 'sha256-[^']+'; connect-src 'self'" page))
        (let ((case-fold-search t))
          (should (string-match-p "content-security-policy:.*default-src 'none'" page)))
        (dolist (link `(("folder task" . ,(concat "tasks?root=" hex "&task=markdown-navigation#next-steps"))
                        ("done" . ,(concat "tasks?root=" hex "&task=done"))
                        ("same" . "#fix-search")
                        ("readme" . ,(funcall visit "README.md"))
                        ("asset" . ,(funcall visit "assets/log file.txt"))
                        ("web" . "https://example.com/a.md")))
          (ert-info ((car link))
            (should (equal (replace-regexp-in-string "&amp;" "&" (portal-server-test--href page (car link)))
                           (cdr link)))))
        (dolist (broken '(("outside" . "outside this task") ("missing" . "does not exist")))
          (should (string-match-p (format "<a class=\"broken-link\" title=\"[^\"]*%s[^\"]*\">%s</a>"
                                          (cdr broken) (car broken))
                                  page)))
        (should (string-match-p (regexp-quote (format "src=\"tasks/file?root=%s&amp;task=fix-search&amp;path=%s\""
                                                      hex (url-hexify-string (expand-file-name "assets/search.png" root))))
                                page))
        (should (string-match-p (regexp-quote "src=\"https://example.com/x.png\"") page)))
      ;; A folder task's links resolve from its folder; show=all is kept.
      (portal-server-test--write root "markdown-navigation/implementation-notes.md" "# Notes\n")
      (portal-server-test--write root "markdown-navigation/prototype/index.html" "<script>alert(1)</script>")
      (let ((page (portal-server-test--tasks root "&task=markdown-navigation&show=all")))
        (should (string-match-p "<h1>Navigation &amp; links</h1><h1 id=\"body-heading\">Body heading</h1>" page))
        (dolist (link `(("notes" . ,(funcall visit "markdown-navigation/implementation-notes.md"))
                        ("prototype" . ,(funcall visit "markdown-navigation/prototype/index.html"))
                        ("back" . ,(concat "tasks?root=" hex "&task=fix-search&show=all#x"))))
          (ert-info ((car link))
            (should (equal (replace-regexp-in-string "&amp;" "&" (portal-server-test--href page (car link)))
                           (cdr link)))))
        (should (string-match-p "class=\"broken-link\"[^>]*>root file</a>" page)))
      ;; A done task needs no filter, and its title is its ID.
      (let ((page (portal-server-test--tasks root "&task=done")))
        (should (string-match-p "HTTP/1.1 200" page))
        (should (string-match-p "<h1>done</h1>" page)))
      (dolist (id '("" "." ".." "../fix-search" "/fix-search" "a/" "a//b" "a/./b" "a/../fix-search"))
        (ert-info (id)
          (should (string-match-p "HTTP/1.1 400"
                                  (portal-server-test--tasks root (concat "&task=" (url-hexify-string id)))))))
      (should (string-match-p "HTTP/1.1 404" (portal-server-test--tasks root "&task=a%2Fb"))))))

(ert-deftest portal-server-tasks-serve-only-images-in-the-attachment-folder ()
  (portal-server-test--with-tasks
    (let ((png "\211PNG\r\n\032\n"))
      (portal-server-test--write root "standalone.md" "---\nstatus: todo\n---\n")
      (portal-server-test--write root "folder/content.md" "---\nstatus: todo\n---\n")
      (portal-server-test--write root "assets/search.PNG" png)
      (portal-server-test--write root "folder/mockup.png" png)
      (portal-server-test--write root "folder/drawing.svg" "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>")
      (portal-server-test--write root "folder/notes.txt" "text")
      (portal-server-test--write directory "outside.png" png)
      (make-symbolic-link (expand-file-name "outside.png" directory) (expand-file-name "folder/escape.png" root))
      (let ((file (lambda (task path)
                    (portal-server-test--get
                     (format "/tasks/file?root=%s&task=%s&path=%s" (url-hexify-string root) task
                             (url-hexify-string (concat root "/" path)))))))
        (dolist (case '(("standalone" "assets/search.PNG" "200" "image/png")
                        ("standalone" "folder/mockup.png" "200" "image/png")
                        ("folder" "folder/mockup.png" "200" "image/png")
                        ("folder" "folder/drawing.svg" "200" "image/svg\\+xml")
                        ("folder" "assets/search.PNG" "403")
                        ("folder" "folder/escape.png" "403")
                        ("folder" "folder/../../outside.png" "403")
                        ("standalone" "../outside.png" "403")
                        ("folder" "folder/notes.txt" "415")
                        ("folder" "folder/missing.png" "404")
                        ("missing" "folder/mockup.png" "404")))
          (ert-info ((format "%S" case))
            (let ((response (funcall file (nth 0 case) (nth 1 case))))
              (should (string-match-p (concat "HTTP/1.1 " (nth 2 case)) response))
              (when (nth 3 case)
                (let ((case-fold-search t))
                  (should (string-match-p (concat "content-type: " (nth 3 case)) response))
                  (should (string-match-p "content-security-policy: [^\n]*sandbox" response)))))))
        (should (string-match-p "HTTP/1.1 400" (portal-server-test--get "/tasks/file?root=relative&task=x&path=%2Fx.png")))
        ;; The access token and Host checks apply to the new routes.
        (let ((base (portal-server-url)))
          (cl-letf (((symbol-function 'portal-server-url) (lambda () (concat base "wrong"))))
            (should (string-match-p "HTTP/1.1 404" (funcall file "folder" "folder/mockup.png")))
            (should (string-match-p "HTTP/1.1 404" (portal-server-test--tasks root)))))
        (let ((url-request-extra-headers '(("Host" . "example.invalid"))))
          (should (string-match-p "HTTP/1.1 404" (funcall file "folder" "folder/mockup.png")))
          (should (string-match-p "HTTP/1.1 404" (portal-server-test--tasks root))))
        (let ((url-request-method "POST"))
          (should (string-match-p "HTTP/1.1 405" (portal-server-test--tasks root))))))))

(ert-deftest portal-server-tasks-explain-missing-empty-and-invalid-roots ()
  (portal-server-test--with-tasks
    (let ((page (portal-server-test--tasks (expand-file-name "missing" root))))
      (should (string-match-p "HTTP/1.1 200" page))
      (should (string-match-p "does not exist yet" page))
      (should-not (file-exists-p (expand-file-name "missing" root))))
    (should (string-match-p "No tasks" (portal-server-test--tasks root)))
    (portal-server-test--write root "done.md" "---\nstatus: done\n---\n")
    (let ((page (portal-server-test--tasks root)))
      (should (string-match-p "No unfinished tasks" page))
      (should (string-match-p (regexp-quote "&amp;show=all\">Show completed</a></p></main>") page)))
    (let ((page (portal-server-test--tasks (expand-file-name "done.md" root))))
      (should (string-match-p "HTTP/1.1 400" page))
      (should (string-match-p "is a file, not a folder" page)))
    (set-file-modes root 0)
    (unwind-protect
        (let ((page (portal-server-test--tasks root)))
          (should (string-match-p "HTTP/1.1 403" page))
          (should (string-match-p "not readable" page)))
      (set-file-modes root #o700))
    (dolist (query '("/tasks" "/tasks?root=relative" "/tasks?root=%2Ftmp%00x"))
      (should (string-match-p "HTTP/1.1 400" (portal-server-test--get query))))))

(defun portal-server-test--task (root name &rest front-matter)
  "Write task NAME in ROOT with FRONT-MATTER lines and no heading.
Its title is then its ID."
  (portal-server-test--write root name "---\n" (mapconcat (lambda (line) (concat line "\n")) front-matter "") "---\n"))

(ert-deftest portal-server-tasks-parse-ids-and-dependency-metadata ()
  (portal-server-test--with-tasks
    (let ((task (lambda (name &rest lines) (apply #'portal-server-test--task root name lines))))
      (portal-server-test--write root "file-name.md"
                                 "---\nid: implement-c-adapter\nstatus: todo\ndepends_on:\n  - extract-c-interface\n---\n\n# Implement the C adapter\n")
      (funcall task "extract.md" "id: extract-c-interface" "status: done" "depends_on: []")
      (dolist (bad '("Upper" "3" "" "-a" "a--b" "a_b" "[a]"))
        (funcall task (format "id %s.md" bad) (concat "id: " bad) "status: todo"))
      ;; Invalid dependency metadata leaves the task and its body readable.
      (portal-server-test--write root "null-list.md" "---\nstatus: todo\ndepends_on:\n---\nStill readable.\n")
      (dolist (bad '("scalar" "[1]" "[\"\"]" "{a: b}" "[[a]]"))
        (funcall task (format "list %s.md" (md5 bad)) (concat "depends_on: " bad) "status: todo"))
      ;; An explicit ID shares one namespace with fallback IDs.
      (funcall task "alpha.md" "status: todo")
      (funcall task "claims-alpha.md" "id: alpha" "status: todo")
      ;; Explicit duplicates never pick a source, whatever their status.
      (funcall task "dup-one.md" "id: dup" "status: todo")
      (funcall task "dup-two.md" "id: dup" "status: done")
      ;; One location is one task, even under two IDs.
      (funcall task "place.md" "id: place-one" "status: todo")
      (funcall task "place/content.md" "id: place-two" "status: done")
      (let ((page (portal-server-test--tasks root "&view=execution")))
        (should (equal (portal-server-test--order page) '("Implement the C adapter")))
        (should (equal (portal-server-test--waits page "Implement the C adapter") ""))
        (should (equal (portal-server-test--stuck page)
                       (sort (cons "null-list"
                                   (mapcar (lambda (bad) (concat "list " (md5 bad)))
                                           '("scalar" "[1]" "[\"\"]" "{a: b}" "[[a]]")))
                             #'string<)))
        (dolist (bad '("Upper" "3" "" "-a" "a--b" "a_b" "[a]"))
          (ert-info (bad)
            (should (string-match-p (concat (regexp-quote (expand-file-name (format "id %s.md" bad) root))
                                            "</code>: Invalid id")
                                    page))))
        (should (string-match-p (concat (regexp-quote (expand-file-name "null-list.md" root))
                                        "</code> ([^)]*null-list</a>): Invalid depends_on")
                                page))
        (should (string-match-p (concat "alpha</a> is defined more than once: <code>"
                                        (regexp-quote (expand-file-name "alpha.md" root)) "</code> and <code>"
                                        (regexp-quote (expand-file-name "claims-alpha.md" root)))
                                page))
        (should (string-match-p (concat "dup</a> is defined more than once: <code>"
                                        (regexp-quote (expand-file-name "dup-one.md" root)))
                                page))
        (should (string-match-p (concat "place-one</a> and <a [^>]*>place-two</a> conflict: <code>"
                                        (regexp-quote (expand-file-name "place.md" root)) "</code> and <code>"
                                        (regexp-quote (expand-file-name "place/content.md" root)))
                                page)))
      ;; No conflicting source is shown, with either filter.
      (should-not (cl-intersection (mapcar #'car (portal-server-test--rows (portal-server-test--tasks root "&show=all")))
                                   '("alpha" "dup" "place-one" "place-two")
                                   :test #'equal))
      (dolist (id '("alpha" "dup" "place-one" "place-two"))
        (ert-info (id)
          (let ((page (portal-server-test--tasks root (concat "&task=" id))))
            (should (string-match-p "HTTP/1.1 409" page))
            (should (string-match-p "defined more than once" page)))))
      (let ((page (portal-server-test--tasks root "&task=place-two")))
        (should (string-match-p (regexp-quote (expand-file-name "place.md" root)) page))
        (should (string-match-p (regexp-quote (expand-file-name "place/content.md" root)) page)))
      (let ((page (portal-server-test--tasks root "&task=null-list")))
        (should (string-match-p "HTTP/1.1 200" page))
        (should (string-match-p "Still readable\\." page))
        (should (string-match-p "readiness-blocked" page))
        (should (string-match-p "<code>depends_on</code> is invalid" page)))
      ;; An invalid ID is reported at the task's location.
      (let ((page (portal-server-test--tasks root (concat "&task=" (url-hexify-string "id Upper")))))
        (should (string-match-p "HTTP/1.1 422" page))
        (should (string-match-p "Invalid id &quot;Upper&quot;" page))))))

(ert-deftest portal-server-tasks-order-unfinished-work-by-dependencies ()
  (portal-server-test--with-tasks
    (let ((task (lambda (name &rest lines) (apply #'portal-server-test--task root name lines))))
      ;; Independent tasks, a chain, and a diamond with a repeated reference.
      (funcall task "z-free.md" "status: todo")
      (funcall task "b-free.md" "status: todo")
      (funcall task "c3.md" "status: todo" "depends_on: [c2]")
      (funcall task "c2.md" "status: todo" "depends_on: [c1]")
      (funcall task "c1.md" "status: todo")
      (funcall task "d-top.md" "status: todo")
      (funcall task "d-left.md" "status: todo" "depends_on: [d-top]")
      (funcall task "d-right.md" "status: todo" "depends_on: [d-top]")
      (funcall task "d-bottom.md" "status: todo" "depends_on: [d-right, d-left, d-right]")
      (funcall task "wide.md" "status: todo" "depends_on: [d-top, b-free, c2, c1]")
      ;; Broken subgraphs, and the work waiting on them.
      (funcall task "self.md" "status: todo" "depends_on: [self]")
      (funcall task "loop-a.md" "status: todo" "depends_on: [loop-c]")
      (funcall task "loop-b.md" "status: todo" "depends_on: [loop-a]")
      (funcall task "loop-c.md" "status: todo" "depends_on: [loop-b]")
      (funcall task "after-loop.md" "status: todo" "depends_on: [loop-a]")
      (funcall task "missing.md" "status: todo" "depends_on: [ghost]")
      (funcall task "bad-list.md" "status: todo" "depends_on: ghost")
      (funcall task "invalid.md" "status: Todo")
      (funcall task "to-invalid.md" "status: todo" "depends_on: [invalid]")
      (funcall task "twice.md" "status: todo")
      (funcall task "twice/content.md" "status: done")
      (funcall task "to-twice.md" "status: todo" "depends_on: [twice]")
      (funcall task "downstream.md" "status: todo" "depends_on: [c1, missing]")
      ;; A done prerequisite counts, whatever its own history.
      (funcall task "old.md" "status: done" "depends_on: [ghost-old, c3]")
      (funcall task "uses-old.md" "status: todo" "depends_on: [old]")
      (let* ((page (portal-server-test--tasks root "&view=execution"))
             (order '("b-free" "c1" "c2" "c3" "d-top" "d-left" "d-right" "d-bottom" "uses-old" "wide"
                     "z-free")))
        (should (equal (portal-server-test--order page) order))
        (should (string-match-p "<li><a [^>]*><span class=\"rank\">1</span><span class=\"title\">b-free</span></a>" page))
        ;; A blocked row is dimmed and names earlier rows by rank, nearest first.
        (should (string-match-p "<li><a class=\"row blocked\" [^>]*><span class=\"rank\">3</span><span class=\"title\">c2</span><span class=\"waits\">after 2</span>" page))
        (should (equal (portal-server-test--stuck page)
                       '("after-loop" "bad-list" "downstream" "loop-a" "loop-b" "loop-c" "missing" "self"
                         "to-invalid" "to-twice")))
        ;; Unranked prerequisites go by ID, after ranked ones.
        (dolist (expected '(("b-free" . "") ("c1" . "") ("uses-old" . "")
                            ("c2" . "after 2") ("d-bottom" . "after 7, 6") ("wide" . "after 5, 3, 2 +1")
                            ("missing" . "ghost (does not exist)")
                            ("to-invalid" . "invalid (is not a valid task)")
                            ("to-twice" . "twice (is defined more than once)")
                            ("bad-list" . "invalid depends_on")
                            ("self" . "a cycle on itself")
                            ("loop-a" . "a cycle with loop-b and loop-c")
                            ("after-loop" . "after loop-a")
                            ("downstream" . "after 2, missing")))
          (ert-info ((car expected))
            (should (equal (portal-server-test--waits page (car expected)) (cdr expected)))))
        ;; Only a task's own dependency problems are marked as problems.
        (should (string-match-p "<span class=\"waits dependency-problem\">ghost (does not exist)</span>" page))
        (should (string-match-p "<span class=\"waits\">after loop-a</span>" page))
        ;; Problems name the sources and IDs, including a done task's history.
        (dolist (problem `(("missing.md" . "It depends on <code>ghost</code>, which does not exist")
                           ("old.md" . "It depends on <code>ghost-old</code>, which does not exist")
                           ("self.md" . "It depends on itself")
                           ("bad-list.md" . "Invalid depends_on")))
          (ert-info ((car problem))
            (should (string-match-p (concat (regexp-quote (expand-file-name (car problem) root))
                                            "</code> ([^)]*</a>): " (regexp-quote (cdr problem)))
                                    page))))
        (should (string-match-p "loop-a</a>, <a [^>]*>loop-b</a>, and <a [^>]*>loop-c</a> depend on each other in a cycle"
                                page))
        (should-not (string-match-p "No tasks\\|No unfinished" page))
        ;; Showing completed work adds a section and changes no rank.
        (let ((all (portal-server-test--tasks root "&view=execution&show=all")))
          (should (equal (portal-server-test--order all) order))
          (should (equal (portal-server-test--completed all) '("old")))))
      ;; Detail pages show the ID, prerequisites, and what the task blocks.
      (let ((hex (url-hexify-string root))
            (page (portal-server-test--tasks root "&task=d-bottom&show=all")))
        (should (string-match-p "<dt>ID</dt><dd><code>d-bottom</code></dd>" page))
        (should (string-match-p "readiness-blocked\">blocked<" page))
        (should (string-match-p
                 (regexp-quote (format (concat "<dt>Depends on</dt><dd><ul class=\"references\">"
                                               "<li><a href=\"tasks?root=%s&amp;task=d-right&amp;show=all\">d-right</a> <code>d-right</code> <span class=\"status status-todo\">todo</span></li>"
                                               "<li><a href=\"tasks?root=%s&amp;task=d-left&amp;show=all\">d-left</a> ")
                                       hex hex))
                 page))
        (should-not (string-match-p "<dt>Blocks" page))
        (setq page (portal-server-test--tasks root "&task=d-top"))
        (should (string-match-p "readiness-ready\">ready<" page))
        (should (string-match-p (concat "<dt>Blocks</dt><dd><ul class=\"references\"><li><a [^>]*task=d-left\">d-left</a>"
                                        ".*task=d-right\">d-right</a>")
                                page))
        ;; A done prerequisite stays linked with the completed filter off.
        (setq page (portal-server-test--tasks root "&task=uses-old"))
        (should (string-match-p (regexp-quote (format "<a href=\"tasks?root=%s&amp;task=old\">old</a> <code>old</code> <span class=\"status status-done\">done</span>" hex))
                                page))
        ;; A done task keeps its dependencies and has no readiness.
        (setq page (portal-server-test--tasks root "&task=old"))
        (should (string-match-p "status-done" page))
        (should-not (string-match-p "class=\"readiness" page))
        (should (string-match-p "<code>ghost-old</code> <span class=\"dependency-problem\">This task does not exist\\.</span>" page))
        (should (string-match-p "task=c3\">c3</a>" page))
        (should (string-match-p "<dt>Blocks</dt>.*task=uses-old\">uses-old</a>" page))
        (setq page (portal-server-test--tasks root "&task=loop-b"))
        (should (string-match-p "<dt>Cycle</dt><dd class=\"dependency-problem\">It depends on itself through <a [^>]*>loop-a</a> and <a [^>]*>loop-c</a>" page)))
      ;; Completing and reopening work shows on reload.
      (funcall task "c1.md" "status: done")
      (let ((page (portal-server-test--tasks root "&view=execution")))
        (should (equal (car (portal-server-test--order page)) "b-free"))
        (should-not (member "c1" (portal-server-test--order page)))
        (should (equal (portal-server-test--waits page "c2") "")))
      (funcall task "old.md" "status: todo" "depends_on: [ghost-old, c3]")
      (let ((page (portal-server-test--tasks root "&view=execution")))
        (should-not (member "uses-old" (portal-server-test--order page)))
        (should (member "uses-old" (portal-server-test--stuck page)))
        (should (equal (portal-server-test--waits page "uses-old") "after old"))))))

(ert-deftest portal-server-tasks-never-call-blocked-work-no-tasks ()
  (portal-server-test--with-tasks
    (portal-server-test--task root "one.md" "status: todo" "depends_on: [two]")
    (portal-server-test--task root "two.md" "status: todo" "depends_on: [one]")
    (let ((page (portal-server-test--tasks root "&view=execution")))
      (should-not (string-match-p "No tasks\\|No unfinished" page))
      (should (string-match-p "No task can be ordered until its dependency problems are fixed" page))
      (should (equal (portal-server-test--stuck page) '("one" "two"))))))

(ert-deftest portal-server-tasks-follow-explicit-ids-across-moves ()
  (portal-server-test--with-tasks
    (let ((hex (url-hexify-string root))
          (png "\211PNG\r\n\032\n")
          (image (lambda (path)
                   (portal-server-test--get
                    (format "/tasks/file?root=%s&task=moving&path=%s" (url-hexify-string root)
                            (url-hexify-string (expand-file-name path root)))))))
      (portal-server-test--write root "first-name.md" "---\nid: moving\nstatus: todo\n---\n# Moving\n")
      (portal-server-test--write root "assets/pic.png" png)
      (portal-server-test--write root "legacy.md" "---\nstatus: todo\n---\n# Legacy\n")
      (portal-server-test--write root "waiter.md"
                                 "---\nstatus: todo\ndepends_on: [moving, legacy]\n---\n# Waiter\n\n"
                                 "[old](first-name.md#x) [new](second-name.md) [folder](second-name/content.md)\n")
      (let ((page (portal-server-test--tasks root "&task=waiter")))
        (should (string-match-p "task=moving\">Moving</a> <code>moving</code>" page))
        (should (string-match-p "task=legacy\">Legacy</a> <code>legacy</code>" page))
        (should (equal (replace-regexp-in-string "&amp;" "&" (portal-server-test--href page "old"))
                       (concat "tasks?root=" hex "&task=moving#x"))))
      (should (string-match-p "HTTP/1.1 200" (funcall image "assets/pic.png")))
      ;; Renaming the file keeps the ID, its URL, and dependencies on it.
      (rename-file (expand-file-name "first-name.md" root) (expand-file-name "second-name.md" root))
      (should (string-match-p "HTTP/1.1 200" (portal-server-test--tasks root "&task=moving")))
      (should (string-match-p "HTTP/1.1 404" (portal-server-test--tasks root "&task=second-name")))
      (should (string-match-p "HTTP/1.1 200" (funcall image "assets/pic.png")))
      (let ((page (portal-server-test--tasks root "&task=waiter")))
        (should (string-match-p "task=moving\">Moving</a>" page))
        (should (equal (replace-regexp-in-string "&amp;" "&" (portal-server-test--href page "new"))
                       (concat "tasks?root=" hex "&task=moving")))
        ;; A prose link to the old place needs updating; the dependency does not.
        (should (string-match-p "class=\"broken-link\"[^>]*>old</a>" page)))
      (should (equal (portal-server-test--waits (portal-server-test--tasks root) "Waiter")
                     "after 2, 1"))
      ;; So does converting it to a folder, whose attachments move with it.
      (make-directory (expand-file-name "second-name" root))
      (rename-file (expand-file-name "second-name.md" root) (expand-file-name "second-name/content.md" root))
      (portal-server-test--write root "second-name/pic.png" png)
      (should (string-match-p "HTTP/1.1 200" (funcall image "second-name/pic.png")))
      (should (string-match-p "HTTP/1.1 403" (funcall image "assets/pic.png")))
      (let ((page (portal-server-test--tasks root "&task=waiter&show=all")))
        (should (string-match-p "task=moving&amp;show=all\">Moving</a>" page))
        (should (equal (replace-regexp-in-string "&amp;" "&" (portal-server-test--href page "folder"))
                       (concat "tasks?root=" hex "&task=moving&show=all")))))))

(ert-deftest portal-server-tasks-show-nested-folders-as-a-tree ()
  (portal-server-test--with-tasks
    (let ((hex (url-hexify-string root)))
      ;; A grouping folder holding a task file and a task folder.
      (portal-server-test--write root "big refactor/extract something in c.md"
                                 "---\nstatus: todo\n---\n# extract something in c\n")
      (portal-server-test--write root "big refactor/implement something/content.md"
                                 "---\nstatus: todo\n---\n# implement something\n")
      (portal-server-test--write root "big refactor/implement something/notes.md" "# Notes\n")
      (portal-server-test--write root "big refactor/implement something/mockup.png" "png")
      (let ((page (portal-server-test--tasks root)))
        (should (equal (portal-server-test--tree page)
                       '("big refactor/" "  extract something in c #1" "  implement something #2")))
        (should (string-match-p "Browsing by folder" page))
        (should (string-search (concat "<a class=\"row\" href=\"tasks?root=" hex
                                       "&amp;task=big%20refactor%2Fimplement%20something\">")
                               page)))
      ;; Deeper levels, a parent task, a content.md without status, and
      ;; folders of attachments and documents, which show no rows.
      (portal-server-test--write root "one/content.md" "---\nstatus: todo\n---\n# One\n")
      (portal-server-test--write root "one/two/content.md" "# Just notes\n")
      (portal-server-test--write root "one/two/three/leaf.md" "---\nstatus: todo\n---\n# Leaf\n")
      (portal-server-test--write root "one/two/three/deeper/content.md" "---\nstatus: todo\n---\n# Deeper\n")
      (portal-server-test--write root "one/assets/pic.png" "png")
      (portal-server-test--write root "one/assets/read-me.md" "# Read me\n")
      (make-directory (expand-file-name "empty/nothing" root) t)
      (let ((page (portal-server-test--tasks root)))
        (should (equal (portal-server-test--tree page)
                       '("big refactor/" "  extract something in c #1" "  implement something #2"
                         "One #3" "  two/" "    three/" "      Deeper #4" "      Leaf #5")))
        (should-not (string-match-p "<h2>Problems\\|Just notes\\|Read me\\|>assets<\\|>empty<" page)))
      ;; A task's page leads back through its folders.
      (let ((page (portal-server-test--tasks root "&task=one%2Ftwo%2Fthree%2Fleaf&view=execution")))
        (should (string-search
                 (format (concat "<span class=\"breadcrumbs\"><a href=\"tasks?root=%s&amp;view=execution\">Tasks</a>"
                                 " › <a href=\"tasks?root=%s&amp;task=one&amp;view=execution\">One</a>"
                                 " › <a href=\"tasks?root=%s&amp;view=execution\">two</a>"
                                 " › <a href=\"tasks?root=%s&amp;view=execution\">three</a></span>")
                         hex hex hex hex)
                 page))
        (should-not (string-search "#folder-" page)))
      ;; In the tree view, a group's breadcrumb leads to its row.
      (let ((page (portal-server-test--tasks root "&task=one%2Ftwo%2Fthree%2Fleaf")))
        (should (string-search
                 (format (concat " › <a href=\"tasks?root=%s&amp;task=one\">One</a>"
                                 " › <a href=\"tasks?root=%s#folder-one%%2Ftwo\">two</a>"
                                 " › <a href=\"tasks?root=%s#folder-one%%2Ftwo%%2Fthree\">three</a></span>")
                         hex hex hex)
                 page))
        (should (string-match-p "<dt>ID</dt><dd><code>one/two/three/leaf</code>" page)))
      ;; The tree marks each folder for those links.
      (should (string-search "<li class=\"group\" id=\"folder-one%2Ftwo\">"
                             (portal-server-test--tasks root)))
      ;; The execution view shows the folders holding each task.
      (let ((page (portal-server-test--tasks root "&view=execution")))
        (should (equal (portal-server-test--order page)
                       '("extract something in c" "implement something" "One" "Deeper" "Leaf")))
        (should (string-search "<span class=\"title\">Deeper</span><span class=\"folder\">One › two › three</span>" page))
        (should (string-search "<span class=\"title\">One</span></a>" page))))))

(ert-deftest portal-server-tasks-keep-parents-and-children-independent ()
  (portal-server-test--with-tasks
    (let ((task (lambda (name title &rest lines)
                  (portal-server-test--write root name "---\n" (mapconcat (lambda (line) (concat line "\n")) lines "")
                                             "---\n# " title "\n"))))
      ;; A completed parent keeps its unfinished tasks in view.
      (funcall task "p/content.md" "P" "status: done")
      (funcall task "p/child.md" "Child" "status: todo")
      ;; A parent's dependencies and status are its own.
      (funcall task "q/content.md" "Q" "status: todo" "depends_on: [ghost]")
      (funcall task "q/kid.md" "Kid" "status: todo")
      (funcall task "waits-on-q.md" "Waits on q" "status: todo" "depends_on: [q]")
      (funcall task "r/content.md" "R" "status: todo")
      (funcall task "r/done-kid.md" "Done kid" "status: done")
      (funcall task "waits-on-r.md" "Waits on r" "status: todo" "depends_on: [r]")
      (funcall task "s/content.md" "S" "status: done")
      (funcall task "s/todo-kid.md" "Todo kid" "status: todo")
      (funcall task "waits-on-s.md" "Waits on s" "status: todo" "depends_on: [s]")
      ;; An invalid parent is a problem, and its folder still holds its tasks.
      (funcall task "bad/content.md" "Bad" "status: Todo")
      (funcall task "bad/ok.md" "Ok" "status: todo")
      ;; A grouping folder is no task to depend on.
      (funcall task "grp/x.md" "X" "status: todo")
      (funcall task "waits-on-group.md" "Waits on group" "status: todo" "depends_on: [grp]")
      ;; A folder of completed work shows only with them.
      (funcall task "finished/a.md" "A" "status: done")
      (funcall task "finished/b/content.md" "B" "status: done")
      (let ((page (portal-server-test--tasks root))
            (ranked '("Ok #1" "X #2" "Child #3" "Kid #4" "R #5" "Todo kid #6" "Waits on r #7" "Waits on s #8")))
        (should (equal (portal-server-test--tree page)
                       '("bad/" "  Ok #1" "grp/" "  X #2" "P (done)" "  Child #3" "Q" "  Kid #4" "R #5"
                         "S (done)" "  Todo kid #6" "Waits on r #7" "Waits on s #8" "Waits on group" "Waits on q")))
        (dolist (expected '(("Kid" . "") ("Child" . "") ("Ok" . "")
                            ("Q" . "ghost (does not exist)")
                            ("Waits on q" . "after q")
                            ("Waits on r" . "after 5")
                            ("Waits on s" . "")
                            ("Waits on group" . "grp (does not exist)")))
          (ert-info ((car expected))
            (should (equal (portal-server-test--waits page (car expected)) (cdr expected)))))
        (should (string-match-p (concat (regexp-quote (expand-file-name "bad/content.md" root))
                                        "</code>: Invalid status")
                                page))
        (should-not (string-match-p "No unfinished" page))
        ;; Showing completed tasks reveals the whole tree and moves no rank.
        (let ((all (portal-server-test--tasks root "&show=all")))
          (should (equal (portal-server-test--tree all)
                         '("bad/" "  Ok #1" "grp/" "  X #2" "P (done)" "  Child #3" "Q" "  Kid #4"
                           "R #5" "  Done kid (done)" "S (done)" "  Todo kid #6" "Waits on r #7" "Waits on s #8"
                           "finished/" "  A (done)" "  B (done)" "Waits on group" "Waits on q")))
          (should (equal (seq-filter (lambda (line) (string-match-p "#" line))
                                     (mapcar #'string-trim (portal-server-test--tree all)))
                         (seq-filter (lambda (line) (string-match-p "#" line))
                                     (mapcar #'string-trim (portal-server-test--tree page)))))
          (should (equal (sort (seq-filter (lambda (line) (string-match-p "#" line))
                                           (mapcar #'string-trim (portal-server-test--tree all)))
                               (lambda (a b) (< (string-to-number (substring a (1+ (string-search "#" a))))
                                                (string-to-number (substring b (1+ (string-search "#" b)))))))
                         ranked))))
      ;; The contextual parent's page is its own.
      (should (string-match-p "HTTP/1.1 200" (portal-server-test--tasks root "&task=p")))
      ;; Finishing a parent's tasks finishes nothing else.
      (funcall task "q/kid.md" "Kid" "status: done")
      (let ((page (portal-server-test--tasks root)))
        (should (member "Q" (portal-server-test--tree page)))
        (should (equal (portal-server-test--waits page "Waits on q") "after q"))))))

(ert-deftest portal-server-tasks-identify-nested-tasks-by-path-or-id ()
  (portal-server-test--with-tasks
    (let ((hex (url-hexify-string root)))
      ;; One name in two folders is two tasks.
      (portal-server-test--task root "a/fix.md" "status: todo")
      (portal-server-test--task root "b/fix.md" "status: todo")
      ;; Names are NFC, however they are saved, and IDs are URL-encoded.
      (portal-server-test--task root "é folder/new task.md" "status: todo")
      ;; A task file and a grouping folder of the same name are both shown.
      (portal-server-test--task root "g/fix.md" "status: done")
      (portal-server-test--task root "g/fix/sub.md" "status: done")
      (let ((page (portal-server-test--tasks root)))
        (should (equal (portal-server-test--tree page)
                       '("a/" "  a/fix #1" "b/" "  b/fix #2" "é folder/" "  é folder/new task #3")))
        (should (string-search (concat "href=\"tasks?root=" hex "&amp;task=%C3%A9%20folder%2Fnew%20task\"") page)))
      (dolist (id '("é folder/new task" "é folder/new task"))
        (should (string-match-p "HTTP/1.1 200" (portal-server-test--tasks root (concat "&task=" (url-hexify-string id))))))
      (should (equal (portal-server-test--tree (portal-server-test--tasks root "&show=all"))
                     '("a/" "  a/fix #1" "b/" "  b/fix #2" "é folder/" "  é folder/new task #3"
                       "g/" "  fix/" "    g/fix/sub (done)" "  g/fix (done)")))
      ;; A task file and its folder's content.md are one location, whatever their IDs.
      (portal-server-test--task root "dup/fix.md" "id: one" "status: todo")
      (portal-server-test--task root "dup/fix/content.md" "id: two" "status: todo")
      ;; Explicit IDs are unique in the whole root.
      (portal-server-test--task root "x/a.md" "id: same" "status: todo")
      (portal-server-test--task root "y/b.md" "id: same" "status: done")
      (let ((page (portal-server-test--tasks root "&show=all")))
        (should (string-match-p (concat "one</a> and <a [^>]*>two</a> conflict: <code>"
                                        (regexp-quote (expand-file-name "dup/fix.md" root)) "</code> and <code>"
                                        (regexp-quote (expand-file-name "dup/fix/content.md" root)))
                                page))
        (should (string-match-p (concat "same</a> is defined more than once: <code>"
                                        (regexp-quote (expand-file-name "x/a.md" root)))
                                page))
        (should-not (cl-intersection (mapcar #'car (portal-server-test--rows page)) '("one" "two" "same")
                                     :test #'equal))
        ;; The folder whose task conflicts is a group, like any other.
        (should-not (string-match-p "id=\"folder-dup%2Ffix\"" page)))
      (should (string-match-p "HTTP/1.1 409" (portal-server-test--tasks root "&task=two")))
      ;; An explicit ID keeps its URL and dependencies across groups.
      (portal-server-test--task root "first group/mover.md" "id: mover" "status: todo")
      (portal-server-test--task root "waiter.md" "status: todo" "depends_on: [mover, a/fix]")
      (let ((before (portal-server-test--waits (portal-server-test--tasks root) "waiter")))
        (make-directory (expand-file-name "second group/deeper" root) t)
        (rename-file (expand-file-name "first group/mover.md" root)
                     (expand-file-name "second group/deeper/mover.md" root))
        (let ((page (portal-server-test--tasks root)))
          (should (equal before "after 3, 1"))
          (should (equal (portal-server-test--waits page "waiter") before))
          (should (member "second group/" (portal-server-test--tree page)))
          (should-not (member "first group/" (portal-server-test--tree page))))
        (should (string-match-p "<dt>Depends on</dt><dd><ul class=\"references\"><li><a [^>]*task=mover\">mover</a>"
                                (portal-server-test--tasks root "&task=waiter"))))
      ;; Converting a fallback ID's storage form keeps its location and URL.
      (make-directory (expand-file-name "a/fix" root))
      (rename-file (expand-file-name "a/fix.md" root) (expand-file-name "a/fix/content.md" root))
      (should (string-match-p "HTTP/1.1 200" (portal-server-test--tasks root "&task=a%2Ffix")))
      (should (string-match-p "task=a%2Ffix\">a/fix</a> <code>a/fix</code>"
                              (portal-server-test--tasks root "&task=waiter"))))))

(ert-deftest portal-server-tasks-survive-unreadable-folders-symlinks-and-escapes ()
  (portal-server-test--with-tasks
    (let ((outside (expand-file-name "outside" directory))
          (png "\211PNG\r\n\032\n"))
      (portal-server-test--task root "kept/one.md" "status: todo")
      (portal-server-test--task root "locked/hidden.md" "status: todo")
      (portal-server-test--task root "locked-sibling/two.md" "status: todo")
      (portal-server-test--task outside "elsewhere.md" "status: todo")
      (portal-server-test--write outside "outside.png" png)
      (portal-server-test--write root "kept/pic.png" png)
      ;; Symbolic links are never followed, in or out of the root.
      (make-symbolic-link outside (expand-file-name "kept/out-link" root))
      (make-symbolic-link (expand-file-name "locked-sibling" root) (expand-file-name "kept/in-link" root))
      (make-symbolic-link (expand-file-name "kept/one.md" root) (expand-file-name "kept/alias.md" root))
      (make-symbolic-link (expand-file-name "outside.png" outside) (expand-file-name "kept/escape.png" root))
      (set-file-modes (expand-file-name "locked" root) 0)
      (unwind-protect
          (let ((page (portal-server-test--tasks root)))
            (should (equal (portal-server-test--tree page)
                           '("kept/" "  kept/one #1" "locked-sibling/" "  locked-sibling/two #2")))
            (should (string-match-p (concat (regexp-quote (expand-file-name "locked" root))
                                            "</code>: The folder could not be read (EACCES)")
                                    page))
            (should-not (string-match-p "elsewhere\\|alias" page))
            (dolist (id '("kept/../locked-sibling/two" "../outside/elsewhere" "kept/out-link/elsewhere"))
              (ert-info (id)
                (should (string-match-p "HTTP/1.1 \\(400\\|404\\)"
                                        (portal-server-test--tasks root (concat "&task=" (url-hexify-string id)))))))
            (let ((file (lambda (path)
                          (portal-server-test--get
                           (format "/tasks/file?root=%s&task=kept%%2Fone&path=%s" (url-hexify-string root)
                                   (url-hexify-string (expand-file-name path root)))))))
              (should (string-match-p "HTTP/1.1 200" (funcall file "kept/pic.png")))
              (dolist (path '("kept/escape.png" "kept/../../outside/outside.png" "kept/out-link/outside.png"))
                (ert-info (path)
                  (should (string-match-p "HTTP/1.1 403" (funcall file path)))))))
        (set-file-modes (expand-file-name "locked" root) #o700)))))

(ert-deftest portal-server-tasks-resolve-nested-links-from-their-folder ()
  (portal-server-test--with-tasks
    (let* ((hex (url-hexify-string root))
           (png "\211PNG\r\n\032\n")
           (visit (lambda (path) (concat "file://" (url-hexify-string (expand-file-name path root)
                                                                     (cons ?/ url-unreserved-chars))))))
      (portal-server-test--write root "g/content.md" "---\nstatus: todo\n---\n# G\n\n"
                                 "[kid](sub/task.md#part) [kid notes](sub/notes.txt)\n")
      (portal-server-test--write root "g/sub/task.md" "---\nstatus: todo\n---\n# Sub task\n\n"
                                 "[sibling](sibling.md) [parent](../content.md) [old](../../old.md#x) "
                                 "[notes](notes.txt) [uncle](../other.txt) [root file](../../README.md)\n\n"
                                 "![pic](pic.png) ![root pic](../../assets/root.png)\n")
      (portal-server-test--write root "g/sub/sibling.md" "---\nstatus: todo\n---\n# Sibling\n")
      (portal-server-test--write root "g/sub/notes.txt" "notes\n")
      (portal-server-test--write root "g/sub/pic.png" png)
      (portal-server-test--write root "g/other.txt" "other\n")
      (portal-server-test--write root "old.md" "---\nstatus: done\n---\n# Old\n")
      (portal-server-test--write root "README.md" "# Read me\n")
      (portal-server-test--write root "assets/root.png" png)
      ;; A nested task file's attachments are in its own folder.
      (let ((page (portal-server-test--tasks root "&task=g%2Fsub%2Ftask&view=execution&show=all")))
        (dolist (link `(("sibling" . ,(concat "tasks?root=" hex "&task=g%2Fsub%2Fsibling&view=execution&show=all"))
                        ("parent" . ,(concat "tasks?root=" hex "&task=g&view=execution&show=all"))
                        ("old" . ,(concat "tasks?root=" hex "&task=old&view=execution&show=all#x"))
                        ("notes" . ,(funcall visit "g/sub/notes.txt"))))
          (ert-info ((car link))
            (should (equal (replace-regexp-in-string "&amp;" "&" (portal-server-test--href page (car link)))
                           (cdr link)))))
        (dolist (broken '("uncle" "root file"))
          (should (string-match-p (format "class=\"broken-link\"[^>]*>%s</a>" broken) page)))
        (should (string-search (format "src=\"tasks/file?root=%s&amp;task=g%%2Fsub%%2Ftask&amp;path=%s\""
                                       hex (url-hexify-string (expand-file-name "g/sub/pic.png" root)))
                               page))
        (should (string-search (format "<a href=\"tasks?root=%s&amp;task=g&amp;view=execution&amp;show=all\">G</a> › <a href=\"tasks?root=%s&amp;view=execution&amp;show=all\">sub</a>"
                                       hex hex)
                               page)))
      (let ((file (lambda (path)
                    (portal-server-test--get
                     (format "/tasks/file?root=%s&task=g%%2Fsub%%2Ftask&path=%s" (url-hexify-string root)
                             (url-hexify-string (expand-file-name path root)))))))
        (should (string-match-p "HTTP/1.1 200" (funcall file "g/sub/pic.png")))
        (should (string-match-p "HTTP/1.1 403" (funcall file "assets/root.png"))))
      ;; A folder task's attachments include its subfolders.
      (let ((page (portal-server-test--tasks root "&task=g")))
        (should (equal (replace-regexp-in-string "&amp;" "&" (portal-server-test--href page "kid"))
                       (concat "tasks?root=" hex "&task=g%2Fsub%2Ftask#part")))
        (should (equal (portal-server-test--href page "kid notes") (funcall visit "g/sub/notes.txt")))))))

(ert-deftest portal-server-tasks-order-across-folders-in-both-views ()
  (portal-server-test--with-tasks
    (let ((task (lambda (name &rest lines) (apply #'portal-server-test--task root name lines))))
      ;; Execution must leave folder a and come back to it.
      (funcall task "a/first.md" "status: todo")
      (funcall task "b/middle.md" "status: todo" "depends_on: [a/first]")
      (funcall task "a/last.md" "status: todo" "depends_on: [b/middle]")
      (funcall task "c/loop-1.md" "status: todo" "depends_on: [c/loop-2]")
      (funcall task "c/loop-2.md" "status: todo" "depends_on: [c/loop-1]")
      (funcall task "d/missing.md" "status: todo" "depends_on: [ghost]")
      (funcall task "d/after.md" "status: todo" "depends_on: [d/missing]")
      (let ((tree (portal-server-test--tasks root))
            (execution (portal-server-test--tasks root "&view=execution")))
        (should (equal (portal-server-test--tree tree)
                       '("a/" "  a/first #1" "  a/last #3" "b/" "  b/middle #2"
                         "c/" "  c/loop-1" "  c/loop-2" "d/" "  d/after" "  d/missing")))
        (should (equal (portal-server-test--order execution) '("a/first" "b/middle" "a/last")))
        (should (equal (portal-server-test--stuck execution) '("c/loop-1" "c/loop-2" "d/after" "d/missing")))
        (should (string-search "<span class=\"title\">a/last</span><span class=\"folder\">a</span>" execution))
        ;; Both views share one graph: the same waits and problems.
        (dolist (title '("a/first" "b/middle" "a/last" "c/loop-1" "c/loop-2" "d/after" "d/missing"))
          (ert-info (title)
            (should (portal-server-test--waits tree title))
            (should (equal (portal-server-test--waits tree title)
                           (portal-server-test--waits execution title)))))
        (should (equal (portal-server-test--waits tree "c/loop-1") "a cycle with c/loop-2"))
        (should (equal (portal-server-test--waits tree "d/after") "after d/missing"))
        (should (equal (portal-server-test--part tree "<section class=\"problems\">" "</section>")
                       (string-replace "&amp;view=execution" ""
                                       (portal-server-test--part execution "<section class=\"problems\">" "</section>"))))))))

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
