;;; portal-build-tests.el --- Native build checks and first-use setup -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in batch with the package directory on `load-path'.  Builds here run a
;; stand-in build.sh, never the real one.  With PORTAL_TEST_BUILD set to a
;; real build directory, one test also checks that build's record.

(require 'ert)
(require 'cl-lib)
(require 'portal-build)
(require 'portal-server)

(defvar compilation-finish-functions)

(defmacro portal-build-test--with-root (&rest body)
  "Run BODY with `portal-build-root' a new source tree, then delete it.
The tree's name contains a space.  It has native and host sources, a
stand-in build.sh, Lisp and a node_modules directory.  No build is running,
and no ZIG names the Zig, which would hide the tests' stand-ins."
  (declare (indent 0))
  `(let* ((portal-build-root (file-name-as-directory (make-temp-file "portal build " t)))
          (process-environment (cons "ZIG" process-environment))
          (portal-build-directory nil)
          (portal-build--ready nil)
          (portal-build--loaded nil)
          (portal-build--process nil)
          (portal-build-on-first-use 'ask))
     (unwind-protect
         (progn
           (dolist (file '("native/Package.swift" "native/Core/emacs.c" "host/server.ts"
                           "host/node_modules/dependency/index.js" "host/.generated/asset.js"
                           "tools/bun.manifest" "CMakeLists.txt"))
             (portal-build-test--write file file))
           (portal-build-test--write "native/ghostty.json" "{\"zig\": \"9.8.7\"}\n")
           (portal-build-test--write "portal.el" ";; Version: 1.0\n")
           (portal-build-test--write "build.sh" "echo built")
           ,@body)
       (when (process-live-p portal-build--process) (delete-process portal-build--process))
       (when (get-buffer "*portal-build*") (kill-buffer "*portal-build*"))
       (delete-directory portal-build-root t))))

(defun portal-build-test--write (file text)
  "Write TEXT to FILE in `portal-build-root', creating its directories."
  (let ((file (expand-file-name file portal-build-root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))))

(defun portal-build-test--complete (&optional identity)
  "Make the tree's build complete, recording IDENTITY or the sources' identity."
  (dolist (file portal-build--artifacts)
    (portal-build-test--write (concat "build/" file) ""))
  (portal-build-test--write "build/portal-build.eld"
                            (prin1-to-string
                             (list :identity (or identity (portal-build-source-identity))
                                   :version (portal-build-version)))))

(defmacro portal-build-test--interactive (&rest body)
  "Run BODY as if from an interactive command in a graphical session."
  (declare (indent 0))
  `(let ((noninteractive nil) (this-command 'portal-terminal))
     ,@body))

(ert-deftest portal-build-problem-follows-the-record-and-sources ()
  (portal-build-test--with-root
    (should (eq (portal-build-problem) 'missing))
    (portal-build-test--complete)
    (should-not (portal-build-problem))
    ;; Each part of the build is required, not just the module.
    (delete-file (portal-build-file (car (last portal-build--artifacts))))
    (should (eq (portal-build-problem) 'missing))
    (portal-build-test--complete)
    (delete-file (portal-build-file "portal-build.eld"))
    (should (eq (portal-build-problem) 'missing))
    (portal-build-test--complete)
    (portal-build-test--write "native/Core/emacs.c" "changed")
    (should (eq (portal-build-problem) 'stale))
    (portal-build-test--complete)
    (let ((portal-build--loaded "an older build"))
      (should (eq (portal-build-problem) 'restart)))))

(ert-deftest portal-build-identity-covers-only-native-inputs ()
  (portal-build-test--with-root
    (should (equal (portal-build--input-files)
                   '("CMakeLists.txt" "build.sh" "host/server.ts" "native/Core/emacs.c"
                     "native/Package.swift" "native/ghostty.json" "tools/bun.manifest")))
    (let ((identity (portal-build-source-identity)))
      ;; Lisp, installed packages and generated files need no rebuild.
      (portal-build-test--write "portal.el" ";; Version: 1.0\n;; changed\n")
      (portal-build-test--write "host/node_modules/dependency/index.js" "changed")
      (portal-build-test--write "host/.generated/asset.js" "changed")
      (should (equal (portal-build-source-identity) identity))
      ;; Nor do scripts the build never reads, such as the Ghostty version
      ;; report and the test VM's recipes, or the tests.
      (portal-build-test--write "scripts/ghostty-version.py" "changed")
      (portal-build-test--write "scripts/tart/recipe.conf" "changed")
      (portal-build-test--write "test/test_tools.py" "changed")
      (should (equal (portal-build-source-identity) identity))
      (portal-build-test--write "tools/bun.manifest" "changed")
      (should-not (equal (portal-build-source-identity) identity)))
    ;; Supplied builds come without native sources: only the record counts.
    (delete-file (expand-file-name "native/Package.swift" portal-build-root))
    (should-not (portal-build-source-identity))))

(ert-deftest portal-build-supplied-builds-match-portal-version ()
  ;; A build shipped without native sources is identified by Portal's version.
  (portal-build-test--with-root
    (portal-build-test--complete)
    (delete-file (expand-file-name "native/Package.swift" portal-build-root))
    (should-not (portal-build-problem))
    ;; Upgrading only the Lisp leaves the supplied build behind.
    (portal-build-test--write "portal.el" ";; Version: 1.1\n")
    (should (eq (portal-build-problem) 'stale))
    ;; A record from before versions were recorded cannot be trusted either.
    (portal-build-test--write "build/portal-build.eld" (prin1-to-string '(:identity "old")))
    (should (eq (portal-build-problem) 'stale))))

(ert-deftest portal-build-ensure-never-builds-or-asks-in-batch ()
  (portal-build-test--with-root
    (dolist (portal-build-on-first-use '(ask always build download))
      (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) (ert-fail "Asked")))
                ((symbol-function 'portal-build) (lambda () (ert-fail "Built")))
                ((symbol-function 'portal-download-runtime)
                 (lambda () (ert-fail "Downloaded"))))
        (should (string-match-p "not built: run M-x portal-build"
                                (cadr (should-error (portal-build-ensure)
                                                    :type 'user-error))))))))

(defun portal-build-test--answer (key &optional record)
  "Return a `read-multiple-choice' that answers KEY.
It calls RECORD, if any, with the prompt and the choices it offered."
  (lambda (prompt choices &rest _)
    (when record (funcall record prompt choices))
    (or (assq key choices) (ert-fail (format "Not offered: %c" key)))))

(ert-deftest portal-build-ensure-offers-a-build-from-a-command ()
  ;; This tree's version names no release, so no download is offered:
  ;; the reason is given, and a build or nothing.
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools)) (asked nil) built)
      (cl-letf (((symbol-function 'read-multiple-choice)
                 (portal-build-test--answer ?b (lambda (&rest question) (push question asked))))
                ((symbol-function 'portal-build) (lambda () (push t built))))
        (portal-build-test--interactive
          ;; The command stops: the build runs in the background.
          (should (string-match-p "retry when it finishes"
                                  (cadr (should-error (portal-build-ensure)
                                                      :type 'user-error))))
          (should (equal built '(t)))
          (pcase-let ((`(,prompt ,choices) (car asked)))
            (should (string-match-p "not built\\.  Portal's version names no release" prompt))
            (should (equal (mapcar #'car choices) '(?b ?n)))
            (should (string-match-p "downloads its dependencies" (nth 2 (assq ?b choices)))))
          ;; Declining builds nothing.
          (cl-letf (((symbol-function 'read-multiple-choice) (portal-build-test--answer ?n)))
            (should (string-match-p "not built: run M-x portal-build\\'"
                                    (cadr (should-error (portal-build-ensure)
                                                        :type 'user-error)))))
          (should (equal built '(t)))
          ;; Unattended setups build without asking.
          (setq asked nil)
          (let ((portal-build-on-first-use 'always))
            (should-error (portal-build-ensure) :type 'user-error))
          (should-not asked)
          (should (equal built '(t t))))))))

(ert-deftest portal-build-ensure-only-reports-when-it-must-not-build ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools)))
      (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) (ert-fail "Asked")))
                ((symbol-function 'portal-build) (lambda () (ert-fail "Built")))
                ((symbol-function 'portal-download-runtime)
                 (lambda () (ert-fail "Downloaded"))))
        (portal-build-test--interactive
          (let ((portal-build-on-first-use 'never))
            (should-error (portal-build-ensure) :type 'user-error))
          ;; Outside a command, as in an init file or a timer.
          (let ((this-command nil))
            (should-error (portal-build-ensure) :type 'user-error))
          ;; A supplied build is reported where it is.
          (let ((portal-build-directory (expand-file-name "supplied/" portal-build-root)))
            (should (string-match-p "supplied"
                                    (cadr (should-error (portal-build-ensure)
                                                        :type 'user-error)))))
          ;; A running build is not started again.
          (let ((portal-build--process (make-process :name "portal-build-test"
                                                     :command '("sleep" "10") :noquery t)))
            (unwind-protect
                (should (string-match-p "yet: retry"
                                        (cadr (should-error (portal-build-ensure)
                                                            :type 'user-error))))
              (delete-process portal-build--process)))
          ;; A build that cannot succeed is explained, not offered; nor,
          ;; here, a download, whose reason is given too.
          (let ((exec-path nil) (portal-build--tool-directories nil))
            (let ((text (cadr (should-error (portal-build-ensure) :type 'user-error))))
              (should (string-search (string-join portal-build--tools ", ") text))
              (should (string-search "neither download it nor build it here" text))
              (should (string-search "names no release" text)))))))))

(ert-deftest portal-build-ensure-checks-once-until-reloaded ()
  (portal-build-test--with-root
    (portal-build-test--complete)
    (portal-build-ensure)
    (cl-letf (((symbol-function 'portal-build-problem) (lambda () (ert-fail "Checked again"))))
      (portal-build-ensure))
    ;; A loaded module from another build needs a restart, once the
    ;; reloaded Lisp checks again.
    (let ((portal-build--ready nil) (portal-build--loaded "an older build"))
      (should (string-match-p "restart Emacs"
                              (cadr (should-error (portal-build-ensure) :type 'user-error)))))))

(ert-deftest portal-build-load-module-records-the-loaded-build ()
  (portal-build-test--with-root
    (portal-build-test--complete "the build")
    (let ((portal-build--ready t) loaded)
      (cl-letf (((symbol-function 'module-load) (lambda (file) (push file loaded))))
        (portal-build-load-module))
      (should (equal loaded (list (portal-build-file portal-build--module))))
      (should (member portal-build--module portal-build--artifacts))
      (should (equal portal-build--loaded "the build")))))

(defun portal-build-test--tools (&optional zig)
  "Return an `exec-path' with stand-ins for the build's tools.
The stand-in Zig, which Linux's build checks, says it is ZIG, or the
version the tree's pin names.  The stand-in pkg-config finds everything."
  (let ((bin (expand-file-name "bin/" portal-build-root)))
    (dolist (tool (cons "pkg-config" portal-build--tools))
      (portal-build-test--write (concat "bin/" tool) "#!/bin/sh\n")
      (set-file-modes (expand-file-name tool bin) #o755))
    (portal-build-test--write "bin/zig" (format "#!/bin/sh\necho '%s'\n" (or zig "9.8.7")))
    (set-file-modes (expand-file-name "zig" bin) #o755)
    (list bin "/usr/bin" "/bin")))

(ert-deftest portal-build-ghostty-needs-the-pinned-zig-and-egl ()
  ;; Linux builds Ghostty's library: with the pin's Zig or a later patch
  ;; release of it, as Ghostty's own build requires.  The build also
  ;; searches Homebrew's and MacPorts' directories, where a Mac may have a
  ;; Zig of its own: the stand-ins alone are searched here.
  (portal-build-test--with-root
    (let ((portal-build--tool-directories nil))
      (dolist (version '("9.8.7" "9.8.10" "9.8.7-dev.3+abc"))
        (let ((exec-path (portal-build-test--tools version)))
          (should-not (portal-build--ghostty-problem))))
      (dolist (version '("9.8.6" "9.9.0" "10.8.7" "9.8" "unknown"))
        (let ((exec-path (portal-build-test--tools version)))
          (should (equal (portal-build--ghostty-problem)
                         (format "Zig 9.8.7 or a later 9.8.7 patch release, which builds \
Ghostty's library: %s is Zig %s"
                                 (expand-file-name "bin/zig" portal-build-root) version)))))
      (let ((exec-path (portal-build-test--tools)))
        (delete-file (expand-file-name "bin/zig" portal-build-root))
        (should (string-prefix-p "Zig 9.8.7, which builds Ghostty's library: install it"
                                 (portal-build--ghostty-problem)))
        ;; ZIG names another program.
        (portal-build-test--write "bin/zig-9.8" "#!/bin/sh\necho 9.8.7\n")
        (set-file-modes (expand-file-name "bin/zig-9.8" portal-build-root) #o755)
        (let ((process-environment (cons "ZIG=zig-9.8" process-environment)))
          (should-not (portal-build--ghostty-problem)))))
    ;; pkg-config finds no EGL.
    (let ((exec-path (portal-build-test--tools)))
      (portal-build-test--write "bin/pkg-config" "#!/bin/sh\nexit 1\n")
      (should (string-prefix-p "EGL's development files" (portal-build--ghostty-problem))))))

(ert-deftest portal-build-diagnoses-unusable-destinations ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools)))
      (let ((portal-build-directory "/supplied/"))
        (should-error (portal-build) :type 'user-error))
      (set-file-modes portal-build-root #o555)
      (unwind-protect
          (should (string-match-p "not writable"
                                  (cadr (should-error (portal-build) :type 'user-error))))
        (set-file-modes portal-build-root #o755))
      (delete-file (expand-file-name "build.sh" portal-build-root))
      (should (string-match-p "lack build.sh"
                              (cadr (should-error (portal-build) :type 'user-error)))))
    (should-not (get-buffer "*portal-build*"))))

(defun portal-build-test--run ()
  "Start `portal-build', wait for it to finish, and return Portal's messages."
  (let ((buffer (portal-build)) messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest arguments)
                 (when format (push (apply #'format-message format arguments) messages)))))
      (while (process-live-p (get-buffer-process buffer))
        (accept-process-output (get-buffer-process buffer) 0.05))
      ;; The finish functions run from the sentinel, after the process ends.
      (let ((deadline (+ (float-time) 5)))
        (while (and portal-build--process (< (float-time) deadline))
          (accept-process-output nil 0.05))))
    (string-join (seq-filter (lambda (text) (string-search "Portal" text)) messages) "\n")))

(ert-deftest portal-build-runs-build-sh-for-this-emacs ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools))
          (portal-build-bun "/opt/bun/bin/bun")
          (portal-build-download-bun nil)
          (portal-build-tools-directory "/tools cache/"))
      (portal-build-test--write
       "build.sh"
       "echo \"args: $*\"\necho \"PATH=$PATH\"\necho \"EMACS=$EMACS\"
echo \"BUN=$BUN\"\necho \"DOWNLOAD=$PORTAL_BUN_DOWNLOAD\"
echo \"TOOLS=$PORTAL_TOOLS_DIR\"\nmkdir -p build\n")
      (should (string-match-p "finished, but" (portal-build-test--run)))
      (with-current-buffer "*portal-build*"
        (let ((text (buffer-string)))
          (should (string-match-p "^args: --prune$" text))
          (should (string-search (concat "PATH=" (string-join exec-path ":")) text))
          (should (string-search (concat "EMACS=" (expand-file-name invocation-name
                                                                    invocation-directory))
                                 text))
          (should (string-search "BUN=/opt/bun/bin/bun" text))
          (should (string-search "DOWNLOAD=0" text))
          (should (string-search "TOOLS=/tools cache/" text))))
      ;; The log outlives the buffer.
      (should (string-search "--prune"
                             (with-temp-buffer
                               (insert-file-contents (portal-build-file "portal-build.log"))
                               (buffer-string)))))))

(ert-deftest portal-build-finds-tools-where-package-managers-install-them ()
  ;; Emacs started from the Dock lacks Homebrew's directory in `exec-path'.
  (portal-build-test--with-root
    (let* ((bin (car (portal-build-test--tools)))
           (portal-build--tool-directories (list "/bin" bin))
           (exec-path '("/usr/bin" "/bin")))
      (portal-build-test--write "build.sh" "echo started\n")
      (portal-build-test--run)
      (with-current-buffer "*portal-build*"
        (should (string-search "\nstarted\n" (buffer-string))))
      (should (equal exec-path '("/usr/bin" "/bin")))
      ;; Without them, the build names what `exec-path' lacks: on macOS CMake
      ;; and Ninja, as xcrun is the system's.  A Linux distribution may have
      ;; every tool in /usr/bin, and then nothing is missing.
      (let* ((portal-build--tool-directories nil)
             (missing (seq-remove #'executable-find portal-build--tools)))
        (when (eq system-type 'darwin)
          (should (equal missing '("cmake" "ninja"))))
        (when missing
          (should (string-match-p (format "needs %s: install CMake" (string-join missing ", "))
                                  (cadr (should-error (portal-build) :type 'user-error)))))))))

(ert-deftest portal-build-sh-searches-the-same-tool-directories ()
  ;; Outside the test macro, `portal-build-root' is this checkout.
  (should (string-search
           (concat "for dir in " (string-join portal-build--tool-directories " ") "; do")
           (with-temp-buffer
             (insert-file-contents (expand-file-name "build.sh" portal-build-root))
             (buffer-string)))))

(ert-deftest portal-build-reports-success-failure-and-restarts ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools)))
      (portal-build-test--write "build.sh" "echo failing\nexit 3\n")
      (should (string-match-p "build failed" (portal-build-test--run)))
      (should-not portal-build--ready)
      ;; Success is reported only for a complete build of these sources.
      (portal-build-test--write "build.sh" "exit 0\n")
      (portal-build-test--complete)
      (should (string-match-p "ready: retry" (portal-build-test--run)))
      (let ((portal-build--loaded "an older build"))
        (should (string-match-p "restart Emacs" (portal-build-test--run)))))))

;; The checkouts below are made with Git: `portal-build-root' is one.
(defun portal-build-test--git (&rest arguments)
  "Run git with ARGUMENTS in `portal-build-root'; return its output, or fail."
  (with-temp-buffer
    (unless (zerop (apply #'call-process "git" nil t nil "-C" portal-build-root
                          "-c" "user.name=Portal tests" "-c" "user.email=tests@example.invalid"
                          arguments))
      (error "git %s failed: %s" (string-join arguments " ") (buffer-string)))
    (string-trim (buffer-string))))

(defun portal-build-test--commit (message)
  "Commit every file in `portal-build-root' with MESSAGE."
  (portal-build-test--git "add" "-A")
  (portal-build-test--git "commit" "-q" "--no-gpg-sign" "--allow-empty" "-m" message))

(ert-deftest portal-build-says-once-when-the-checkout-cannot-upgrade ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools))
          (advice (format-message
                   "not on a branch, so `package-vc-upgrade' cannot upgrade it")))
      (portal-build-test--write "build.sh" "exit 0\n")
      (portal-build-test--complete)
      ;; A directory without Git, as for a supplied or copied Portal.
      (should (equal (portal-build-test--run) "Portal is ready: retry your command"))
      ;; A checkout on a branch, as `:rev "stable"' or `:rev :newest' leaves.
      (portal-build-test--git "init" "-q" "-b" "stable")
      (portal-build-test--commit "Release")
      (should (equal (portal-build-test--run) "Portal is ready: retry your command"))
      ;; A detached checkout, as a bare `:vc' or a tag leaves: once a build.
      (portal-build-test--git "checkout" "-q" "--detach")
      (let ((messages (portal-build-test--run)))
        (should (string-search advice messages))
        (should-not (string-search advice messages
                                   (1+ (string-search advice messages))))
        (should (string-prefix-p "Portal is ready: retry your command.  This Portal" messages))
        (should (string-search (format-message "`git switch stable' in %s"
                                               (abbreviate-file-name portal-build-root))
                               messages)))
      (let ((portal-build--loaded "an older build"))
        (should (string-search advice (portal-build-test--run))))
      ;; Not when Portal starts and finds its build ready, and not when a build fails.
      (cl-letf (((symbol-function 'message) (lambda (&rest _) (ert-fail "Messaged"))))
        (portal-build-ensure))
      (portal-build-test--write "build.sh" "exit 3\n")
      (let ((messages (portal-build-test--run)))
        (should (string-match-p "build failed" messages))
        (should-not (string-search advice messages))))))

(ert-deftest portal-version-names-the-release-and-the-branch ()
  (portal-build-test--with-root
    (should (equal (portal-version) "Portal 1.0"))
    (portal-build-test--git "init" "-q" "-b" "main")
    (portal-build-test--commit "First")
    ;; No release tag yet.
    (should (equal (portal-version)
                   (format "Portal 1.0, %s (main)"
                           (portal-build-test--git "rev-parse" "--short" "HEAD"))))
    (portal-build-test--git "tag" "-a" "-m" "Release" "v1.0")
    (portal-build-test--git "branch" "stable")
    (should (equal (portal-version) "Portal 1.0 (main)"))
    (portal-build-test--commit "Second")
    (should (equal (portal-version)
                   (format "Portal 1.0, 1 commit on, %s (main)"
                           (portal-build-test--git "rev-parse" "--short" "HEAD"))))
    (portal-build-test--commit "Third")
    (should (string-match-p "\\`Portal 1\\.0, 2 commits on, [0-9a-f]+ (main)\\'" (portal-version)))
    (portal-build-test--git "switch" "-q" "stable")
    (should (equal (portal-version) "Portal 1.0 (stable)"))
    (portal-build-test--git "checkout" "-q" "--detach" "main")
    (should (string-match-p "\\`Portal 1\\.0, 2 commits on, [0-9a-f]+ (not on a branch)\\'"
                            (portal-version)))
    ;; A header that does not match the tag names the tag.
    (portal-build-test--write "portal.el" ";; Version: 1.1\n")
    (should (string-match-p "\\`Portal 1\\.1, 2 commits on v1\\.0, " (portal-version)))
    ;; Shown when typed.
    (let (shown)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest arguments) (setq shown (apply #'format format arguments)))))
        (call-interactively #'portal-version))
      (should (string-prefix-p "Portal 1.1" shown)))))

(ert-deftest portal-build-starts-one-build-at-a-time ()
  (portal-build-test--with-root
    (let ((exec-path (portal-build-test--tools)))
      (portal-build-test--write "build.sh" "sleep 10\n")
      (let ((buffer (portal-build)))
        (should (process-live-p portal-build--process))
        (let ((process portal-build--process))
          (cl-letf (((symbol-function 'display-buffer) #'ignore))
            (portal-build))
          (should (eq portal-build--process process))
          (should (= 1 (seq-count (lambda (p) (eq (process-buffer p) buffer))
                                  (process-list)))))))))

(ert-deftest portal-build-server-offers-a-build-for-its-own-host ()
  ;; A build that makes a host, as the Mac's does, on any platform.
  (portal-build-test--with-root
    (let ((portal-build--host "portal-host")
          (portal-build--artifacts (cl-adjoin "portal-host" portal-build--artifacts
                                              :test #'equal))
          (portal-server-program nil) checked)
      ;; Tests and callers find the host to run without reading the option.
      (should (equal (portal-server-program-file) (portal-build-file "portal-host")))
      (let ((portal-server-program "/supplied/host"))
        (should (equal (portal-server-program-file) "/supplied/host")))
      (cl-letf (((symbol-function 'portal-build-ensure) (lambda () (setq checked t))))
        (should-error (portal-start-server) :type 'user-error))
      (should checked)
      ;; A host left by a stale or interrupted build is not started.
      (portal-build-test--complete)
      (portal-build-test--write "native/Core/emacs.c" "changed")
      (set-file-modes (portal-build-file "portal-host") #o755)
      (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Started"))))
        (should (string-match-p "older than its sources"
                                (cadr (should-error (portal-start-server) :type 'user-error)))))
      ;; A host chosen by the user is never built.
      (setq checked nil)
      (let ((portal-server-program "/missing/host"))
        (cl-letf (((symbol-function 'portal-build-ensure) (lambda () (setq checked t))))
          (should-error (portal-start-server) :type 'user-error)))
      (should-not checked))))

(ert-deftest portal-build-linux-has-no-host-to-offer ()
  ;; Linux builds no host: the module alone is a complete build, and the
  ;; host's absence is told as the want of web views, not as a build to make.
  (should (eq (null portal-build--host) (not (eq system-type 'darwin))))
  (portal-build-test--with-root
    (let ((portal-build--host nil)
          (portal-build--artifacts (remove "portal-host" portal-build--artifacts))
          (portal-server-program nil))
      (portal-build-test--complete)
      (should-not (portal-build-problem))
      (should-not (file-exists-p (portal-build-file "portal-host")))
      (cl-letf (((symbol-function 'portal-build-ensure) (lambda () (ert-fail "Ensured")))
                ((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Started"))))
        (should (string-match-p "no web views on .* yet, so it has no app host"
                                (cadr (should-error (portal-start-server)
                                                    :type 'user-error)))))
      (should (equal (portal-build--describe 'missing) "Portal's native module is not built"))
      ;; A host the user names still runs.
      (let ((portal-server-program "/missing/host"))
        (should (string-match-p "M-x portal-build: /missing/host"
                                (cadr (should-error (portal-start-server)
                                                    :type 'user-error))))))))

(ert-deftest portal-build-root-resolves-linked-packages ()
  ;; As straight.el and Elpaca do, link the Lisp into a separate directory.
  (let ((linked (make-temp-file "portal-linked " t)))
    (unwind-protect
        (progn
          (make-symbolic-link (expand-file-name "portal-build.el" portal-build-root)
                              (expand-file-name "portal-build.el" linked))
          (byte-compile-file (expand-file-name "portal-build.el" linked))
          (dolist (file '("portal-build.el" "portal-build.elc"))
            (should (equal (with-temp-buffer
                             (call-process (expand-file-name invocation-name invocation-directory)
                                           nil t nil "--batch" "-Q" "-l"
                                           (expand-file-name file linked)
                                           "--eval" "(princ portal-build-root)")
                             (buffer-string))
                           (file-truename portal-build-root)))))
      (delete-directory linked t))))

(ert-deftest portal-build-records-only-the-identity-it-started-with ()
  (portal-build-test--with-root
    (portal-build-test--complete "the last build")
    (let ((command-line-args-left (list (portal-build-file ""))))
      (portal-build--start-batch))
    ;; A running build is never taken as ready.
    (should (eq (portal-build-problem) 'missing))
    (portal-build--record-identity)
    (should-not (portal-build-problem))
    (should (equal (plist-get (portal-build--read "portal-build.eld") :version) "1.0"))
    ;; Sources edited while a build runs may be only partly in its outputs.
    (let ((command-line-args-left (list (portal-build-file ""))))
      (portal-build--start-batch))
    (portal-build-test--write "host/server.ts" "edited during the build")
    (should-error (portal-build--record-identity))
    (should (eq (portal-build-problem) 'missing))))

(ert-deftest portal-build-probes-a-build-made-elsewhere ()
  ;; An unpacked runtime: checked for this Lisp's sources, then loaded and
  ;; its host started from where it is, never from Portal's own build.
  (portal-build-test--with-root
    (portal-build-test--complete)
    (let* ((elsewhere (make-temp-file "portal runtime " t))
           (probe (lambda ()
                    (let ((command-line-args-left (list elsewhere)))
                      (portal-build--probe-batch))))
           loaded started)
      (unwind-protect
          (cl-letf (((symbol-function 'module-load) (lambda (file) (push file loaded)))
                    ((symbol-function 'portal--web-load) #'ignore)
                    ((symbol-function 'portal-build--probe-host)
                     (lambda (program) (push program started))))
            (copy-directory (portal-build-file "") (file-name-as-directory elsewhere) nil t t)
            (delete-directory (portal-build-file "") t)
            (funcall probe)
            (should (equal loaded (list (expand-file-name portal-build--module elsewhere))))
            (should (equal started (and portal-build--host
                                        (list (expand-file-name portal-build--host elsewhere)))))
            ;; A file of the runtime missing, then a build of other sources:
            ;; refused before anything loads.
            (setq loaded nil)
            (let ((resource (expand-file-name (car (last portal-build--artifacts
                                                         (if portal-build--host 2 1)))
                                              elsewhere)))
              (rename-file resource (concat resource ".away"))
              (should (string-match-p (regexp-quote resource)
                                      (cadr (should-error (funcall probe)))))
              (rename-file (concat resource ".away") resource))
            (portal-build-test--write "native/Core/emacs.c" "changed")
            (should (string-match-p "older than its sources"
                                    (cadr (should-error (funcall probe)))))
            (should-not loaded))
        (delete-directory elsewhere t)))))

(ert-deftest portal-build-rejects-a-module-of-unknown-build ()
  ;; A module that Portal Lisp from before build records loaded: the real
  ;; C core's test module provides the same native functions.
  (let ((module (getenv "PORTAL_TEST_MODULE")))
    (skip-unless module)
    (let ((portal-build--loaded nil))
      ;; Lisp stand-ins, such as the batch tests' fake backend, are not modules.
      (cl-letf (((symbol-function 'portal--web-load) #'ignore))
        (portal-build-check-loaded-module))
      (module-load module)
      (should (string-match-p "restart Emacs"
                              (cadr (should-error (portal-build-check-loaded-module)
                                                  :type 'user-error)))))))

(ert-deftest portal-build-real-build-is-ready ()
  ;; An unchanged installation must not ask for a rebuild.
  (let ((directory (getenv "PORTAL_TEST_BUILD")))
    (skip-unless directory)
    (let ((portal-build-directory directory) (portal-build--loaded nil))
      (should-not (portal-build-problem)))))

(provide 'portal-build-tests)
;;; portal-build-tests.el ends here
