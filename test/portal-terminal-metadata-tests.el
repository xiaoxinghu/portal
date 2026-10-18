;;; portal-terminal-metadata-tests.el --- Terminal names, projects and reports -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'portal-fake-native
         (expand-file-name "portal-fake-native"
                           (file-name-directory
                            (or load-file-name
                                (bound-and-true-p byte-compile-current-file)
                                buffer-file-name))))
(require 'portal-terminal)

;; Tests kill live shells without asking; the prompt has its own tests.
(setq portal-terminal-confirm-kill nil)

;; Real buffers, project detection and completion drive `portal-terminal.el'
;; against the fake native module, which sends the `terminal' records a real
;; terminal sends when its title, directory or process changes.  The GUI
;; suite checks that real shells send them.

(defvar portal-metadata-test--directory nil "This test's temporary directory.")

(defmacro portal-metadata-test--environment (&rest body)
  "Run BODY in one window, then kill its buffers and delete its directory.
The directory holds two projects both named app, one/app and two/app, and
a folder, loose, in no project."
  (declare (indent 0))
  `(let* ((portal-metadata-test--directory (file-truename (make-temp-file "portal-metadata-" t)))
          (context (frame-parameter nil 'portal-project-context))
          (initial-buffers (buffer-list)))
     (portal-fake-native-reset)
     (dolist (folder '("one/app/.git" "one/app/src" "two/app/.git" "loose"))
       (make-directory (portal-metadata-test--path folder) t))
     (save-window-excursion
       (unwind-protect
           (progn (delete-other-windows)
                  (switch-to-buffer (get-buffer-create "*scratch*"))
                  ,@body)
         (portal-terminal-quick-dismiss)
         (dolist (buffer (cl-set-difference (buffer-list) initial-buffers))
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (set-frame-parameter nil 'portal-project-context context)
         (delete-directory portal-metadata-test--directory t)))
     (should-not (portal-view-buffers))))

(defun portal-metadata-test--path (name)
  "Return NAME in this test's directory, as a directory name if it ends in /."
  (expand-file-name name portal-metadata-test--directory))

(defun portal-metadata-test--open (folder)
  "Start a terminal from a file buffer in FOLDER and return its buffer."
  (let ((default-directory (file-name-as-directory (portal-metadata-test--path folder))))
    (portal-terminal-new)
    (current-buffer)))

(defun portal-metadata-test--get (buffer key)
  "Return KEY of BUFFER's terminal metadata."
  (plist-get (portal-terminal-metadata buffer) key))

(defun portal-metadata-test--report (buffer &rest facts)
  "Have BUFFER's terminal report FACTS, such as :title, :pwd and :exited."
  (apply #'portal-fake-native-report (buffer-local-value 'portal-view--target buffer) facts))

(ert-deftest portal-terminal-metadata-names-and-projects ()
  (portal-metadata-test--environment
    (let* ((one (portal-metadata-test--path "one/app/"))
           (two (portal-metadata-test--path "two/app/"))
           (loose (portal-metadata-test--path "loose/"))
           (first (portal-metadata-test--open "one/app/src"))
           (second (portal-metadata-test--open "one/app"))
           (other (portal-metadata-test--open "two/app"))
           (outside (portal-metadata-test--open "loose")))
      ;; Several terminals in one project, and projects named alike, read apart.
      (should (equal (buffer-name first) "*terminal: app*"))
      (should (equal (buffer-name second) "*terminal: app*<2>"))
      (should (equal (buffer-name other) "*terminal: two/app*"))
      (should (equal (buffer-name outside)
                     (format "*terminal: %s*" (abbreviate-file-name (directory-file-name loose)))))
      (should (equal (portal-terminal-metadata first)
                     (list :name "*terminal: app*" :project one
                           :directory (portal-metadata-test--path "one/app/src/")
                           :title nil :progress nil :exited nil :quick nil)))
      (should (equal (portal-metadata-test--get other :project) two))
      (should-not (portal-metadata-test--get outside :project))
      (should (equal (buffer-local-value 'list-buffers-directory outside) loose))
      ;; Lookup uses the full root, never a name.
      (should (equal (portal-terminal-buffers one) (list first second)))
      (should (equal (portal-terminal-buffers two) (list other)))
      (should (equal (portal-terminal-buffers (portal-metadata-test--path "one/app"))
                     (list first second)))
      (should (equal (portal-terminal-buffers) (list first second other outside)))
      (with-current-buffer second (portal-terminal-rename "*terminal: two/app*<2>"))
      (should (equal (portal-terminal-buffers two) (list other)))
      (should (equal (portal-metadata-test--get second :name) "*terminal: two/app*<2>"))
      ;; A program's file name labels it; an explicit name is used as given.
      (let ((launched (portal-terminal-start one "/opt/tools/claude" '("implement"))))
        (should (equal (buffer-name launched) "*claude: one/app*"))
        (should (equal (portal-metadata-test--get launched :project) one)))
      (should (equal (buffer-name (portal-terminal-start two "claude" nil "*claude: fix-search*"))
                     "*claude: fix-search*"))
      ;; A resolver other than project.el, such as Projectile's, decides roots.
      (let ((portal-project-function (lambda (directory) (and (string-search "loose" directory) loose))))
        (should (equal (portal-metadata-test--get (portal-metadata-test--open "loose") :project)
                       loose))
        (should-not (portal-metadata-test--get (portal-metadata-test--open "one/app") :project))))))

(ert-deftest portal-terminal-metadata-follows-reports ()
  (portal-metadata-test--environment
    (let* ((one (portal-metadata-test--path "one/app/"))
           (src (portal-metadata-test--path "one/app/src/"))
           (terminal (portal-metadata-test--open "one/app"))
           (other (portal-metadata-test--open "two/app")))
      (portal-metadata-test--report terminal :title "vim notes.md" :pwd (directory-file-name src))
      (should (equal (portal-metadata-test--get terminal :title) "vim notes.md"))
      (should (equal (portal-metadata-test--get terminal :directory) src))
      (should (equal (buffer-local-value 'default-directory terminal) src))
      (should (equal (buffer-local-value 'list-buffers-directory terminal) src))
      ;; Titles never rename, even a buffer the user renamed, nor while hidden.
      (with-current-buffer terminal (portal-terminal-rename "server"))
      (switch-to-buffer other)
      (portal-view-sync)
      (should-not (plist-get (portal--inspect (buffer-local-value 'portal-view--target terminal))
                             :visible))
      (portal-metadata-test--report terminal :title "npm run dev" :progress "indeterminate")
      (should (equal (portal-metadata-test--get terminal :progress) "indeterminate"))
      (should (equal (portal-metadata-test--get terminal :title) "npm run dev"))
      (should (equal (buffer-name terminal) "server"))
      ;; The assigned project stays wherever the shell goes.
      (portal-metadata-test--report terminal :pwd temporary-file-directory)
      (should (equal (portal-metadata-test--get terminal :directory)
                     (file-name-as-directory temporary-file-directory)))
      (should (equal (portal-metadata-test--get terminal :project) one))
      (should (equal (portal-terminal-buffers one) (list terminal)))
      ;; Reports that are not an existing local directory are ignored.
      (let ((file (portal-metadata-test--path "one/app/README")))
        (write-region "" nil file)
        (dolist (pwd (list "" "relative/dir" "~/" "/ssh:example.com:/tmp/" "/no/such/portal/dir"
                           file nil))
          (portal-metadata-test--report terminal :pwd pwd)
          (should (equal (portal-metadata-test--get terminal :directory)
                         (file-name-as-directory temporary-file-directory)))
          (should (equal (buffer-local-value 'default-directory terminal)
                         (file-name-as-directory temporary-file-directory)))))
      (portal-metadata-test--report terminal :title "")
      (should-not (portal-metadata-test--get terminal :title))
      ;; An exited program is not a closed buffer, and affects no other shell.
      (portal-metadata-test--report terminal :exited t)
      (should (eq (portal-metadata-test--get terminal :exited) t))
      (should (equal (buffer-local-value 'mode-line-process terminal)
                     '("" portal-input-mode-line-process (portal-terminal--exited ":exited"))))
      (should (memq terminal (portal-terminal-buffers)))
      (should-not (portal-metadata-test--get other :exited))
      (let ((target (buffer-local-value 'portal-view--target terminal)))
        (kill-buffer terminal)
        (should-not (portal-terminal-metadata terminal))
        (should-not (member target (portal-fake-native-targets))))
      (should (equal (portal-terminal-buffers) (list other)))
      (should (portal-metadata-test--get other :project))
      ;; Closing the shell but keeping the buffer ends its session too.
      (with-current-buffer other (portal-terminal-close))
      (should (buffer-live-p other))
      (should-not (portal-terminal-metadata other))
      (should-not (portal-terminal-buffers))
      ;; A buffer with another kind of view has no terminal either.
      (let ((web (get-buffer-create "*portal-metadata-web*")))
        (with-current-buffer web (portal-view-open 'web nil))
        (should (memq web (portal-view-buffers 'web)))
        (should-not (portal-terminal-metadata web))
        (kill-buffer web)))))

(ert-deftest portal-terminal-metadata-normalizes-unset-progress ()
  (portal-metadata-test--environment
    (let ((terminal (portal-metadata-test--open "one/app")))
      ;; Native terminals initially report the empty string, not nil.
      (portal-metadata-test--report terminal :progress "")
      (should-not (portal-metadata-test--get terminal :progress))
      (dolist (unset '(nil "" 42))
        (portal-metadata-test--report terminal :progress "indeterminate")
        (should (equal (portal-metadata-test--get terminal :progress) "indeterminate"))
        (portal-metadata-test--report terminal :progress unset)
        (should-not (portal-metadata-test--get terminal :progress)))
      ;; Explicit OSC removal is still a reported state.
      (portal-metadata-test--report terminal :progress "remove")
      (should (equal (portal-metadata-test--get terminal :progress) "remove")))))

(ert-deftest portal-terminal-metadata-reads-changes-made-while-opening ()
  (portal-metadata-test--environment
    ;; The native module drops a record sent before its target is open, so a
    ;; terminal whose program changes something while it opens sends none.
    (let* ((src (portal-metadata-test--path "one/app/src/"))
           (terminal
            (cl-letf* ((open (symbol-function 'portal--open))
                       ((symbol-function 'portal--open)
                        (lambda (kind options)
                          (let ((target (funcall open kind options)))
                            (puthash target
                                     (append (list :title "true" :pwd src :exited t)
                                             (gethash target portal-fake-native--views))
                                     portal-fake-native--views)
                            target))))
              (portal-metadata-test--open "one/app"))))
      (should (eq (portal-metadata-test--get terminal :exited) t))
      (should (equal (portal-metadata-test--get terminal :title) "true"))
      (should (equal (portal-metadata-test--get terminal :directory) src))
      (should (equal (buffer-local-value 'default-directory terminal) src)))))

(ert-deftest portal-terminal-metadata-reassigns-projects ()
  (portal-metadata-test--environment
    (let ((one (portal-metadata-test--path "one/app/"))
          (two (portal-metadata-test--path "two/app/"))
          (terminal (portal-metadata-test--open "one/app/src")))
      (with-current-buffer terminal
        (portal-terminal-set-project (portal-metadata-test--path "two/app/.git"))
        (should (equal (portal-metadata-test--get terminal :project) two))
        (should (equal (buffer-name) "*terminal: app*"))
        (should-not (portal-terminal-buffers one))
        (should (equal (portal-terminal-buffers two) (list terminal)))
        (should-error (portal-terminal-set-project (portal-metadata-test--path "loose"))
                      :type 'user-error)
        (should (equal (portal-metadata-test--get terminal :project) two))
        (portal-terminal-set-project nil)
        (should-not (portal-metadata-test--get terminal :project))
        (should (equal (portal-terminal-buffers) (list terminal)))
        ;; A new terminal started from a terminal starts where its shell is.
        (portal-metadata-test--report terminal :pwd (portal-metadata-test--path "one/app"))
        (portal-terminal-new)
        (should (equal (portal-metadata-test--get (current-buffer) :project) one))
        (should (equal (portal-metadata-test--get (current-buffer) :directory) one))))
    (should-error (with-temp-buffer (portal-terminal-set-project nil)) :type 'user-error)))

(defun portal-metadata-test--matches (query collection &optional styles)
  "Return COLLECTION's terminal completions of QUERY with completion STYLES.
By default, use Emacs's own styles and category defaults, with no packages.
The New entries, which carry no terminal, are left out."
  (let* ((completion-styles (or styles (default-toplevel-value 'completion-styles)))
         (completion-category-overrides nil)
         (matches (completion-all-completions query collection nil (length query))))
    (when (consp matches) (setcdr (last matches) nil))
    (seq-filter (lambda (match) (get-text-property 0 'portal-terminal match)) matches)))

(ert-deftest portal-terminal-metadata-completion-matches-context ()
  (portal-metadata-test--environment
    (let* ((server (portal-metadata-test--open "one/app"))
           (tests (portal-metadata-test--open "one/app/src"))
           (worktree (portal-metadata-test--open "two/app"))
           (outside (portal-metadata-test--open "loose"))
           (asked 0) answer)
      (with-current-buffer server (portal-terminal-rename "server"))
      (portal-metadata-test--report server :title "npm run dev")
      (portal-metadata-test--report tests :title "bun test" :exited t)
      (portal-metadata-test--report worktree :pwd (portal-metadata-test--path "two/app/.git"))
      (let ((quick (let ((default-directory (portal-metadata-test--path "one/app/")))
                     (portal-terminal-quick--show (file-truename default-directory))
                     (portal-terminal-quick-dismiss)
                     (portal-terminal-quick--buffer (file-truename default-directory)))))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt collection &rest _)
                     (cl-incf asked)
                     (should (equal prompt "Terminal: "))
                     (let ((metadata (completion-metadata "" collection nil)))
                       (should (eq (completion-metadata-get metadata 'category) 'portal-terminal))
                       (let ((all (portal-metadata-test--matches "" collection))
                             (annotate (completion-metadata-get metadata 'annotation-function)))
                         ;; Quick terminals keep out of ordinary selection.
                         (should (= (length all) 4))
                         (should-not (cl-some (lambda (candidate) (string-search "portal-quick" candidate))
                                              all))
                         (should (equal (delq nil (mapcar annotate all)) '("  exited")))))
                     ;; Name, project, directory and title all match.
                     (dolist (case `(("server" ,server) ("npm" ,server) ("bun" ,tests)
                                     ("two/app" ,worktree) (".git" ,worktree) ("loose" ,outside)
                                     ("<2>" ,tests)))
                       (let ((matches (portal-metadata-test--matches (car case) collection)))
                         (should (= (length matches) 1))
                         (should (string-prefix-p (buffer-name (cadr case)) (car matches)))))
                     (should (= (length (portal-metadata-test--matches "one/app" collection)) 2))
                     (should (= (length (portal-metadata-test--matches "ser" collection '(basic))) 1))
                     (car (portal-metadata-test--matches answer collection)))))
          ;; The choice resolves to its buffer, whatever the names look like.
          (with-current-buffer outside (portal-terminal-rename "*terminal: app*"))
          (dolist (choice `(("bun" ,tests) ("npm" ,server) ("loose" ,outside)))
            (setq answer (car choice))
            (portal-terminal-choose)
            (should (eq (current-buffer) (cadr choice))))
          (should (= asked 3))
          (should (memq quick (portal-terminal-buffers (portal-metadata-test--path "one/app") t)))
          ;; A terminal closed during completion is reported, not guessed.
          (setq answer "npm")
          (cl-letf* ((read (symbol-function 'completing-read))
                     ((symbol-function 'completing-read)
                      (lambda (&rest arguments)
                        (prog1 (apply read arguments) (kill-buffer server)))))
            (should-error (portal-terminal-choose) :type 'user-error)))))))

(ert-deftest portal-terminal-metadata-quick-terminals-keep-their-identity ()
  (portal-metadata-test--environment
    (let ((root (portal-metadata-test--path "one/app/"))
          (loose (portal-metadata-test--path "loose/")))
      (switch-to-buffer (generate-new-buffer "metadata-source"))
      (setq buffer-file-name (portal-metadata-test--path "one/app/src/file.el")
            default-directory (portal-metadata-test--path "one/app/src/"))
      (portal-terminal-toggle)
      (let ((quick (current-buffer)))
        (should (equal (buffer-name) (format "*portal-quick:%s*" (abbreviate-file-name root))))
        (should (equal (portal-terminal-metadata)
                       (list :name (buffer-name) :project root :directory root
                             :title nil :progress nil :exited nil :quick t)))
        (should-error (portal-terminal-set-project loose) :type 'user-error)
        ;; Its shell's reports update it, but never its project or name.
        (portal-metadata-test--report quick :pwd loose :title "zsh")
        (should (equal (portal-metadata-test--get quick :directory) loose))
        (should (equal (portal-metadata-test--get quick :project) root))
        (should (equal (portal-terminal-quick--buffer root) quick))
        (should-not (portal-terminal-buffers))
        (should-not (portal-terminal-buffers root))
        (should (equal (portal-terminal-buffers root t) (list quick)))
        (portal-terminal-quick-dismiss))
      ;; Outside a project the quick terminal's directory stands in for its root.
      (setq buffer-file-name (portal-metadata-test--path "loose/file.el")
            default-directory loose)
      (portal-terminal-toggle)
      (should (equal (portal-metadata-test--get (current-buffer) :project) loose)))))

;;; portal-terminal-metadata-tests.el ends here
