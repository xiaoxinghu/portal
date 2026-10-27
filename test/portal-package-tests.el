;;; portal-package-tests.el --- Installing Portal as a package -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in batch.  Each test installs a copy of this checkout, including
;; uncommitted files, through docs/install.md's own examples, in a child Emacs
;; whose HOME, `user-emacs-directory' and package directory are new and empty.
;; Nothing is downloaded and nothing native is built.  PORTAL_TEST_ELPA lists
;; package directories that include Consult and Embark, separated by colons,
;; for the test of the optional integrations.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(defconst portal-package-test--checkout
  (file-name-as-directory
   (expand-file-name ".." (file-name-directory (or (macroexp-file-name) buffer-file-name)))))

(defun portal-package-test--example (name)
  "Return docs/install.md's example NAME as text."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "docs/install.md" portal-package-test--checkout))
    (unless (re-search-forward
             (format "^<!-- example: %s -->\n```elisp\n" (regexp-quote name)) nil t)
      (error "docs/install.md has no example %s" name))
    (let ((start (point)))
      (re-search-forward "^```$")
      (buffer-substring-no-properties start (match-beginning 0)))))

(defun portal-package-test--git (directory &rest arguments)
  "Run git with ARGUMENTS in DIRECTORY and return its output, or fail."
  (with-temp-buffer
    (unless (zerop (apply #'call-process "git" nil t nil "-C" directory arguments))
      (error "git %s failed: %s" (string-join arguments " ") (buffer-string)))
    (buffer-string)))

(defun portal-package-test--copy (source)
  "Copy this checkout's files into SOURCE, replacing files already there.
Ignored files, such as build outputs, stay behind."
  (dolist (file (split-string (portal-package-test--git
                               portal-package-test--checkout
                               "ls-files" "-z" "--cached" "--others" "--exclude-standard")
                              "\0" t))
    (let ((from (expand-file-name file portal-package-test--checkout))
          (to (expand-file-name file source)))
      (when (file-regular-p from)
        (make-directory (file-name-directory to) t)
        (copy-file from to t t)))))

(defun portal-package-test--commit (source message)
  "Commit every file in SOURCE with MESSAGE."
  (portal-package-test--git source "add" "-A")
  (portal-package-test--git source "-c" "user.name=Portal tests"
                            "-c" "user.email=tests@example.invalid"
                            "commit" "-q" "--no-gpg-sign" "-m" message))

(defun portal-package-test--source (root &optional change)
  "Copy this checkout's files into a new Git repository in ROOT; return it.
CHANGE, if non-nil, is called with the copy's directory before the commit."
  (let ((source (expand-file-name "portal source/" root)))
    (portal-package-test--copy source)
    (when change (funcall change source))
    (portal-package-test--git source "init" "-q")
    (portal-package-test--commit source "Source")
    source))

(defun portal-package-test--append (source file text)
  "Append TEXT to FILE in SOURCE."
  (write-region text nil (expand-file-name file source) t 'silent))

(defun portal-package-test--emacs (home init &rest forms)
  "Run batch Emacs with HOME, loading INIT text first, then evaluating FORMS.
Return (STATUS . OUTPUT).  FORMS print their results."
  (let ((file (expand-file-name ".emacs.d/init.el" home)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";;; init.el -*- lexical-binding: t; -*-\n"
              ;; Never contact a package archive, so never check one's
              ;; signatures: importing package.el's keyring into a new
              ;; HOME took gpg 20 seconds on GitHub's macOS runners.
              "(setq package-archives nil package-check-signature nil)\n"
              init "\n"))
    (with-temp-buffer
      (let* ((process-environment (append (list (concat "HOME=" home)
                                                "XDG_CONFIG_HOME" "EMACSLOADPATH")
                                          process-environment))
             ;; Not abbreviated with the old HOME.
             (default-directory home)
             (status (apply #'call-process
                            (expand-file-name invocation-name invocation-directory)
                            nil t nil "--batch" "-l" file
                            (mapcan (lambda (form) (list "--eval" (prin1-to-string form)))
                                    forms))))
        (cons status (buffer-string))))))

(defun portal-package-test--compile-problems (output)
  "Return the lines of OUTPUT that report a problem compiling Portal."
  (seq-filter (lambda (line)
                (string-match-p "\\(Error\\|Warning\\)\\( (bytecomp)\\)?:" line))
              (split-string output "\n")))

(defmacro portal-package-test--with-home (&rest body)
  "Run BODY with ROOT a new temporary directory and HOME an empty one in it."
  (declare (indent 0))
  `(let* ((root (make-temp-file "portal package " t))
          (home (expand-file-name "home/" root)))
     (unwind-protect (progn (make-directory home) ,@body)
       (delete-directory root t))))

(defun portal-package-test--install-from (source home init &optional example)
  "Install Portal from SOURCE in HOME through EXAMPLE after INIT.
EXAMPLE names docs/install.md's example and defaults to use-package-vc.
Return (STATUS . OUTPUT)."
  (portal-package-test--emacs
   home (concat init "\n"
                (string-replace "\"https://github.com/xiaoxinghu/portal\""
                                (prin1-to-string (directory-file-name source))
                                (portal-package-test--example
                                 (or example "use-package-vc"))))))

(defun portal-package-test--check-install (install home)
  "Check INSTALL, a result of `portal-package-test--install-from' in HOME.
Return the package directory."
  (let ((package (expand-file-name ".emacs.d/elpa/portal/" home)))
    (unless (zerop (car install))
      (ert-fail (list "Installation failed" (cdr install))))
    ;; package-vc reports success even when files fail to compile.
    (should-not (portal-package-test--compile-problems (cdr install)))
    (should (file-exists-p (expand-file-name "portal.elc" package)))
    (should (file-exists-p (expand-file-name "portal-build.elc" package)))
    (should (file-exists-p (expand-file-name "portal-autoloads.el" package)))
    ;; Development tests are not compiled; native sources ship for the build.
    (should-not (directory-files-recursively (expand-file-name "test" package) "\\.elc\\'"))
    (should (file-exists-p (expand-file-name "native/Package.swift" package)))
    (should (file-exists-p (expand-file-name "tools/resolve-bun.sh" package)))
    ;; Installing started no build.
    (should-not (file-exists-p (expand-file-name "build" package)))
    package))

(defun portal-package-test--install (root home init)
  "Install Portal in HOME through the use-package-vc example after INIT.
The source is a copy of this checkout in ROOT.  Return the package directory."
  (portal-package-test--check-install
   (portal-package-test--install-from (portal-package-test--source root) home init)
   home))

(defun portal-package-test--read-result (output)
  "Return the last form printed in OUTPUT."
  (car (last (car (read-from-string (concat "(" output ")"))))))

(ert-deftest portal-package-installs-with-use-package-vc ()
  (portal-package-test--with-home
    (let ((package (portal-package-test--install root home "")))
      ;; A fresh Emacs: autoloads only, then the whole package, without native code.
      (pcase-let ((`(,status . ,output)
                   (portal-package-test--emacs
                    home "(package-initialize)"
                    '(prin1 (list (autoloadp (symbol-function 'portal-build))
                                  (autoloadp (symbol-function 'portal-terminal))
                                  (progn (require 'portal) (featurep 'portal-native-module))
                                  portal-build-root
                                  (portal-build-problem)
                                  (condition-case err (portal-build-ensure)
                                    (user-error (cadr err))))))))
        (should (zerop status))
        (pcase-let ((`(,autoloads ,command ,native ,root ,problem ,error)
                     (portal-package-test--read-result output)))
          (should (equal (list autoloads command native root problem)
                         (list t t nil (file-truename package) 'missing)))
          (should (string-match-p "not built: run M-x portal-build" error)))))))

(ert-deftest portal-package-installs-optional-integrations ()
  :tags '(:expensive)
  (let ((elpa (getenv "PORTAL_TEST_ELPA")))
    (skip-unless elpa)
    (portal-package-test--with-home
      (let ((init (mapconcat (lambda (directory)
                               (format "(add-to-list 'load-path %S)" directory))
                             (split-string elpa ":" t) "\n")))
        (portal-package-test--install root home init)
        (pcase-let ((`(,status . ,output)
                     (portal-package-test--emacs
                      home (concat "(package-initialize)\n" init)
                      '(progn
                         (require 'portal)
                         (require 'consult)
                         (portal-terminal-embark-mode 1)
                         (prin1 (list portal-terminal-consult-mode
                                      (eq (keymap-parent portal-terminal-embark-map)
                                          embark-buffer-map)))))))
          (should (zerop status))
          (should (equal (portal-package-test--read-result output) '(t t))))))))

;; The older Portal that the upgrade test starts from: other Lisp and other
;; native sources than this checkout's.
(defun portal-package-test--age (source)
  "Make the copy of Portal in SOURCE older."
  (portal-package-test--append source "portal.el" "\n(defvar portal-package-test-old t)\n")
  (portal-package-test--append source "native/Package.swift" "\n// Older\n"))

(ert-deftest portal-package-upgrades-with-package-vc ()
  :tags '(:expensive)
  (portal-package-test--with-home
    (let* ((source (portal-package-test--source root #'portal-package-test--age))
           (package (portal-package-test--check-install
                     (portal-package-test--install-from source home "") home)))
      ;; A complete build of the older sources, as M-x portal-build leaves it.
      (pcase-let ((`(,status . ,output)
                   (portal-package-test--emacs
                    home "(package-initialize)"
                    '(progn
                       (require 'portal-build)
                       (dolist (file portal-build--artifacts)
                         (make-directory (file-name-directory (portal-build-file file)) t)
                         (write-region "" nil (portal-build-file file)))
                       (write-region (prin1-to-string
                                      (list :identity (portal-build-source-identity)
                                            :version (portal-build-version)))
                                     nil (portal-build-file "portal-build.eld"))
                       (prin1 (portal-build-problem))))))
        (should (zerop status))
        (should-not (portal-package-test--read-result output)))
      (portal-package-test--copy source)
      (portal-package-test--commit source "Newer")
      ;; Upgrade from an Emacs that uses the older Portal, as M-x
      ;; package-vc-upgrade would.  The pull is asynchronous.
      (pcase-let ((`(,status . ,output)
                   (portal-package-test--emacs
                    home "(package-initialize)"
                    '(progn
                       (require 'portal)
                       (package-vc-upgrade (cadr (assq 'portal package-alist)))
                       (while (seq-some #'process-live-p (process-list))
                         (accept-process-output nil 0.1))))))
        (should (zerop status))
        (should-not (portal-package-test--compile-problems output))
        (should-not (string-match-p "^Failed to" output)))
      (should (equal (portal-package-test--git package "rev-parse" "HEAD")
                     (portal-package-test--git source "rev-parse" "HEAD")))
      ;; A fresh Emacs runs the newer Lisp and asks for a native rebuild.
      (pcase-let ((`(,status . ,output)
                   (portal-package-test--emacs
                    home "(package-initialize)"
                    '(progn (require 'portal)
                            (prin1 (list (boundp 'portal-package-test-old)
                                         (portal-build-problem)))))))
        (should (zerop status))
        (should (equal (portal-package-test--read-result output) '(nil stale)))))))

(ert-deftest portal-package-check-fails-on-compile-errors ()
  :tags '(:expensive)
  ;; package-vc reports success however Portal compiles: the check must not.
  (portal-package-test--with-home
    (let ((install (portal-package-test--install-from
                    (portal-package-test--source
                     root (lambda (source)
                            (portal-package-test--append
                             source "portal-build.el"
                             "\n(defun portal-package-test-broken () (let ((1 2)) nil))\n")))
                    home "")))
      (should (zerop (car install)))
      (should (portal-package-test--compile-problems (cdr install)))
      (should-error (portal-package-test--check-install install home)
                    :type 'ert-test-failed))))

(ert-deftest portal-package-failed-build-on-install-leaves-portal-unbuilt ()
  :tags '(:expensive)
  ;; package-vc only warns when the installation's build fails; Portal itself
  ;; must still report that it has no build.
  (portal-package-test--with-home
    (let ((install (portal-package-test--install-from
                    (portal-package-test--source
                     root (lambda (source)
                            (with-temp-file (expand-file-name "build.sh" source)
                              (insert "#!/bin/sh\nexit 1\n"))))
                    home "" "use-package-vc-build")))
      (should (zerop (car install)))
      ;; The build ran and failed, yet the installation succeeded.
      (should (string-search "Failed to run ./build.sh" (cdr install)))
      (pcase-let ((`(,status . ,output)
                   (portal-package-test--emacs
                    home "(package-initialize)"
                    '(progn (require 'portal-build) (prin1 (portal-build-problem))))))
        (should (zerop status))
        (should (eq (portal-package-test--read-result output) 'missing))))))

(ert-deftest portal-package-loads-from-a-clone ()
  (portal-package-test--with-home
    (let* ((source (portal-package-test--source root))
           (init (string-replace "\"~/src/portal\"" (prin1-to-string source)
                                 (portal-package-test--example "use-package-load-path"))))
      (pcase-let ((`(,status . ,output)
                   (portal-package-test--emacs
                    home init
                    '(prin1 (list (featurep 'portal) portal-build-root
                                  (featurep 'portal-native-module))))))
        (should (zerop status))
        (should (equal (portal-package-test--read-result output)
                       (list t (file-truename source) nil)))))))

(provide 'portal-package-tests)
;;; portal-package-tests.el ends here
