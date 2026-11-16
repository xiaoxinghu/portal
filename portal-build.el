;;; portal-build.el --- Build and check Portal's native installation -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Portal's native module and app host are built from this package's sources
;; by build.sh, which `portal-build' runs in the background.  Before Portal
;; loads its module, `portal-build-ensure' checks that the build is complete
;; and comes from the current sources, and offers to build it when it is not.
;; Loading this file, compiling it and generating autoloads need no native
;; code and never start a build.
;;
;; Each build starts by removing the record of the last one and noting the
;; identity of its sources: a hash of the files it reads.  It ends by loading
;; the new module and starting the new host in a disposable batch Emacs, then
;; records that identity, unless the sources changed meanwhile.  So a failed,
;; partial or overtaken build never looks ready.

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defvar portal-server-program)
(declare-function portal-start-server "portal-server" ())
(declare-function portal-stop-server "portal-server" ())
(declare-function portal-server-url "portal-server" ())
(declare-function lm-header "lisp-mnt" (header))

(defgroup portal nil "Native views and hosted UIs in Emacs." :group 'applications)

(defconst portal-build-root
  (file-name-directory
   (file-truename (expand-file-name "portal-build.el"
                                    (file-name-directory
                                     (or (macroexp-file-name) buffer-file-name)))))
  "Portal's source directory, which holds build.sh.
Package managers that link the Lisp files into a separate directory, such
as straight.el and Elpaca, resolve to the linked sources.")

(defcustom portal-build-directory nil
  "Directory holding Portal's built native module and app host.
nil means the build directory in `portal-build-root', which `portal-build'
builds.  Set it to use a build made elsewhere, such as a distribution's:
Portal then reports a missing or stale build instead of offering to build."
  :type '(choice (const :tag "Portal's own build" nil) directory))

(defcustom portal-build-on-first-use 'ask
  "What the first native command does when Portal's build is missing or stale.
`ask' offers to build it, `always' builds without asking, and `never' only
reports it.  Batch Emacs never builds or asks."
  :type '(choice (const :tag "Offer to build" ask)
                 (const :tag "Build without asking" always)
                 (const :tag "Only report" never)))

(defcustom portal-build-bun nil
  "Absolute file name of the Bun that builds Portal's app host, or nil.
nil uses a compatible bun where the build finds its other tools, then
Portal's pinned Bun, cached in `portal-build-tools-directory'.  A Bun
named here that is missing or incompatible fails the build rather than
being replaced."
  :type '(choice (const :tag "Find or download" nil) file))

(defcustom portal-build-download-bun t
  "Whether a build may download Portal's pinned Bun when it finds no other.
The download comes from Bun's official releases and is checked against the
digest in tools/bun.manifest before it runs."
  :type 'boolean)

(defcustom portal-build-tools-directory
  (expand-file-name "portal/tools/" user-emacs-directory)
  "Directory where builds keep the tools they download, such as Bun.
It is outside the package, so upgrades and reinstalls reuse its contents."
  :type 'directory)

(defconst portal-build--tool-directories
  '("/opt/homebrew/bin" "/usr/local/bin" "/opt/local/bin")
  "Where Homebrew and MacPorts install tools; build.sh searches them after PATH.
Emacs started from the Dock or Finder does not see the shell's PATH, so its
`exec-path' often lacks them even when CMake and Ninja are installed there.
Keep this list the same as build.sh's.")

(defconst portal-build--artifacts
  '("portal.bundle/Contents/Info.plist"
    "portal.bundle/Contents/MacOS/portal.dylib"
    "portal.bundle/Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/Contents/Resources/terminfo/78/xterm-ghostty"
    "portal.bundle/Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/Contents/Resources/Ghostty/shell-integration"
    "portal-host")
  "Files of a complete build, relative to the build directory.")

(defconst portal-build--module "portal.bundle/Contents/MacOS/portal.dylib"
  "The single native module used by all Portal features.")

(defconst portal-build--record "portal-build.eld"
  "The file in which a successful build records its identity.")

(defconst portal-build--start "portal-build-start.eld"
  "The file in which a running build notes the identity it builds.")

(defvar portal-build--process nil "The running build, or nil.")
(defvar portal-build--loaded nil
  "Identity of the build whose module this Emacs loaded, or nil.")
(defvar portal-build--ready nil
  "Non-nil once this Lisp found Portal's build ready.")
;; Check again when this file is reloaded, as a package upgrade does.
(setq portal-build--ready nil)

(defun portal-build-check-loaded-module ()
  "Signal a `user-error' if Emacs needs a restart to use Portal's module.
That is when the loaded module comes from another build, or was loaded by
Portal Lisp from before build records, so its build is unknown."
  (cond (portal-build--loaded (portal-build-ensure))
        ((and (fboundp 'portal--web-load)
              (module-function-p (symbol-function 'portal--web-load)))
         (user-error "Portal's native module was loaded by an older Portal: \
restart Emacs to use it"))))

(defun portal-build-file (name)
  "Return the absolute name of NAME in Portal's build directory."
  (expand-file-name name (or portal-build-directory
                             (expand-file-name "build" portal-build-root))))

(defun portal-build--input-files ()
  "Return the files the native build reads, relative to `portal-build-root'.
They are sorted, and exclude Lisp, hidden files and installed packages."
  (let ((descend (lambda (directory)
                   (not (string-match-p "\\`\\.\\|\\`node_modules\\'"
                                        (file-name-nondirectory directory))))))
    (sort (append
           (seq-filter (lambda (file) (file-regular-p (expand-file-name file portal-build-root)))
                       '("CMakeLists.txt" "CMakePresets.json" "build.sh"))
           (mapcan (lambda (directory)
                     (let ((directory (expand-file-name directory portal-build-root)))
                       (and (file-directory-p directory)
                            (mapcar (lambda (file) (file-relative-name file portal-build-root))
                                    (directory-files-recursively
                                     directory "\\`[^.]" nil descend)))))
                   '("host" "native" "tools")))
          #'string<)))

(defun portal-build-source-identity ()
  "Return a hash of the sources the native build reads, or nil without them.
Lisp is not among them: changing only Lisp needs no native rebuild."
  (when (file-exists-p (expand-file-name "native/Package.swift" portal-build-root))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (dolist (file (portal-build--input-files))
        (insert file "\0"
                (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally (expand-file-name file portal-build-root))
                  (secure-hash 'sha256 (current-buffer)))
                "\n"))
      (secure-hash 'sha256 (current-buffer)))))

(defun portal-build-version ()
  "Return the version in portal.el's header, or nil without portal.el."
  (let ((file (expand-file-name "portal.el" portal-build-root)))
    (when (file-readable-p file)
      (require 'lisp-mnt)
      (with-temp-buffer
        (insert-file-contents file)
        (lm-header "version")))))

(defun portal-build--read (name)
  "Return the plist that NAME in the build directory holds, or nil."
  (let ((file (portal-build-file name)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (ignore-errors (read (current-buffer)))))))

(defun portal-build--recorded-identity ()
  "Return the identity the last successful build recorded, or nil."
  (plist-get (portal-build--read portal-build--record) :identity))

(defun portal-build-problem ()
  "Return why Portal's build cannot be used now, or nil when it can.
The result is `missing' for an absent or incomplete build, `stale' for one
built from other sources, or `restart' when this Emacs loaded the module of
another build.  Without native sources, as for a supplied build, a build
from another version of Portal is stale."
  (let* ((record (portal-build--read portal-build--record))
         (recorded (plist-get record :identity))
         (current (portal-build-source-identity)))
    (cond ((not (and recorded
                     (cl-every (lambda (file) (file-exists-p (portal-build-file file)))
                               portal-build--artifacts)))
           'missing)
          ((if current
               (not (equal current recorded))
             (not (equal (portal-build-version) (plist-get record :version))))
           'stale)
          ((and portal-build--loaded (not (equal portal-build--loaded recorded))) 'restart))))

(defun portal-build--describe (problem)
  "Return a sentence about PROBLEM, a value of `portal-build-problem'."
  (pcase problem
    ('missing "Portal's native module and app host are not built")
    ('stale "Portal's native build is older than its sources")
    ('restart "Portal's native module changed after Emacs loaded it")))

(defun portal-build--exec-path ()
  "Return the directories a build searches for its tools, in order.
They are `exec-path', which a build gets as PATH, then the
`portal-build--tool-directories' that build.sh adds."
  (append exec-path (seq-difference portal-build--tool-directories exec-path)))

(defun portal-build--check-prerequisites ()
  "Signal a `user-error' if `portal-build' cannot succeed, saying why."
  (let ((build (portal-build-file "")))
    (cond (portal-build-directory
           (user-error "Portal uses the build in %s (`portal-build-directory'), \
which `portal-build' does not make" portal-build-directory))
          ((not (file-exists-p (expand-file-name "build.sh" portal-build-root)))
           (user-error "Portal's sources in %s lack build.sh" portal-build-root))
          ((not (and (eq system-type 'darwin) module-file-suffix))
           (user-error "Portal needs macOS Emacs with module support"))
          ((not (file-writable-p (if (file-exists-p build) build portal-build-root)))
           (user-error "Portal cannot build in %s: it is not writable.  \
Build Portal elsewhere and set `portal-build-directory'" build)))
    (when-let* ((missing (let ((exec-path (portal-build--exec-path)))
                           (seq-remove #'executable-find '("cmake" "ninja" "xcrun")))))
      (user-error "Portal's build needs %s: install CMake and Ninja, for example \
with `brew install cmake ninja', and Xcode.  If they are installed elsewhere, \
add their directory to `exec-path'" (string-join missing ", ")))))

(defun portal-build--environment ()
  "Return the process environment for a build that this Emacs will load."
  (let ((include (expand-file-name "../include" data-directory)))
    (append
     (list (concat "PATH=" (string-join exec-path path-separator))
           (concat "EMACS=" (expand-file-name invocation-name invocation-directory))
           (concat "PORTAL_TOOLS_DIR=" (expand-file-name portal-build-tools-directory))
           (concat "PORTAL_BUN_DOWNLOAD=" (if portal-build-download-bun "1" "0")))
     (and (file-exists-p (expand-file-name "emacs-module.h" include))
          (list (concat "EMACS_INCLUDE=" include)))
     (and portal-build-bun (list (concat "BUN=" (expand-file-name portal-build-bun))))
     process-environment)))

;;;###autoload
(defun portal-build ()
  "Build Portal's native module and app host in the background.
The build shows its progress in *portal-build*, uses this Emacs and its
module header, and finds tools on `exec-path', then where Homebrew and
MacPorts install them.  The first build downloads dependencies, and
Portal's pinned Bun when it finds no compatible one: see
`portal-build-bun'.  The build keeps only what Portal runs and deletes
its intermediate files, so the next build starts afresh.  A finished
build's log is also kept in portal-build.log in the build directory.
When this Emacs has already loaded Portal's module, restart Emacs to use
the new one."
  (interactive)
  (if (process-live-p portal-build--process)
      (progn (display-buffer (process-buffer portal-build--process))
             (message "Portal is already building"))
    (portal-build--check-prerequisites)
    (require 'compile)
    (let* ((default-directory portal-build-root)
           (process-environment (portal-build--environment))
           (shell-file-name "/bin/sh")
           (buffer (compilation-start
                    (mapconcat #'shell-quote-argument
                               (list "/bin/sh" (expand-file-name "build.sh" portal-build-root)
                                     "--prune")
                               " ")
                    nil (lambda (_mode) "*portal-build*"))))
      (setq portal-build--process (get-buffer-process buffer))
      (with-current-buffer buffer
        (add-hook 'compilation-finish-functions #'portal-build--finished nil t))
      buffer)))

(defun portal-build--finished (buffer status)
  "Report the build in BUFFER, which ended with STATUS, and keep its log."
  (setq portal-build--process nil
        portal-build--ready nil)
  (ignore-errors
    (with-current-buffer buffer
      (write-region nil nil (portal-build-file "portal-build.log") nil 'silent)))
  (let ((problem (and (string-prefix-p "finished" status) (portal-build-problem))))
    (cond ((not (string-prefix-p "finished" status))
           (message "Portal's build failed: see %s" (buffer-name buffer)))
          ((eq problem 'restart)
           (message "Portal is built: restart Emacs to load its new native module"))
          (problem
           (message "Portal's build finished, but %s"
                    (downcase (portal-build--describe problem))))
          (t (message "Portal is ready: retry your command")))))

(defun portal-build-ensure ()
  "Signal a `user-error' unless Portal's build can be loaded now.
When the build is missing or stale, start `portal-build' as
`portal-build-on-first-use' says.  The build runs in the background, so
the command that needed it stops either way and can be retried after."
  (unless portal-build--ready
    (let ((problem (portal-build-problem)))
      (if (null problem)
          (setq portal-build--ready t)
        (let ((description (portal-build--describe problem)))
          (cond ((eq problem 'restart)
                 (user-error "%s: restart Emacs to use it" description))
                ((process-live-p portal-build--process)
                 (user-error "%s yet: retry when the build in *portal-build* finishes"
                             description))
                (portal-build-directory
                 (user-error "%s in %s" description portal-build-directory))
                ((or noninteractive (eq portal-build-on-first-use 'never)
                     (not (or this-command (eq portal-build-on-first-use 'always))))
                 (user-error "%s: run M-x portal-build" description))
                (t
                 (portal-build--check-prerequisites)
                 (unless (or (eq portal-build-on-first-use 'always)
                             (y-or-n-p (format "%s.  Build now?  The first build \
downloads its dependencies and takes several minutes " description)))
                   (user-error "%s: run M-x portal-build when ready" description))
                 (portal-build)
                 (user-error "Building Portal in *portal-build*: retry when it finishes"))))))))

(defun portal-build-load-module ()
  "Load Portal's native module, once `portal-build-ensure' finds it ready."
  (portal-build-ensure)
  (let ((identity (portal-build--recorded-identity)))
    (module-load (portal-build-file portal-build--module))
    (setq portal-build--loaded identity)))

(defun portal-build--probe-host (program)
  "Signal an error unless PROGRAM starts as Portal's app host.
It must report readiness through the protocol `portal-server' checks."
  (load (expand-file-name "portal-server" portal-build-root) nil t)
  (let* ((portal-server-program program)
         (process (portal-start-server))
         (deadline (+ (float-time) 10)))
    (unwind-protect
        (while (not (portal-server-url))
          (unless (and (process-live-p process) (< (float-time) deadline))
            (error "The app host %s did not become ready" program))
          (accept-process-output process 0.1))
      (portal-stop-server))))

(defun portal-build--write (name plist)
  "Write PLIST to NAME in the build directory, replacing it atomically."
  (let ((file (portal-build-file name)))
    (with-temp-file (concat file ".tmp")
      (prin1 plist (current-buffer)))
    (rename-file (concat file ".tmp") file t)))

(defun portal-build--start-batch ()
  "Begin a build: forget the last one and note the identity of the sources.
The argument after this function's name on the command line is the build
directory.  The build runs this, in batch, before replacing any output."
  (let ((portal-build-directory (file-name-as-directory (pop command-line-args-left))))
    (make-directory (portal-build-file "") t)
    (delete-file (portal-build-file portal-build--record))
    (portal-build--write portal-build--start (list :identity (portal-build-source-identity)))))

(defun portal-build--record-identity ()
  "Record the identity noted when the build started, now that it succeeded.
The record also names Portal's version, which identifies the build where
the sources do not.  Signal an error, recording nothing, if the sources
changed since the build started: the outputs may contain either version."
  (let ((started (plist-get (portal-build--read portal-build--start) :identity)))
    (unless (and started (equal started (portal-build-source-identity)))
      (error "Portal's sources changed during the build: build again"))
    (portal-build--write portal-build--record
                         (list :identity started :version (portal-build-version)))))

(defun portal-build--finish-batch ()
  "Check a finished build and record its identity, in a disposable batch Emacs.
The argument after this function's name on the command line is the build
directory.  The build runs this last: loading the new module anywhere else
could replace one that Emacs already uses."
  (let ((portal-build-directory (file-name-as-directory (pop command-line-args-left))))
    (dolist (file portal-build--artifacts)
      (unless (file-exists-p (portal-build-file file))
        (error "Portal's build lacks %s" (portal-build-file file))))
    (module-load (portal-build-file portal-build--module))
    (unless (fboundp 'portal--web-load)
      (error "Portal's native module lacks its functions"))
    (portal-build--probe-host (portal-build-file "portal-host"))
    (portal-build--record-identity)
    (message "The Portal build is complete")))

(provide 'portal-build)
;;; portal-build.el ends here
