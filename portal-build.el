;;; portal-build.el --- Build and check Portal's native installation -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Portal's native module, and on macOS its app host, are built from this
;; package's sources by build.sh, which `portal-build' runs in the background.  Before Portal
;; loads its module, `portal-build-ensure' checks that the build is complete
;; and comes from the current sources.  When it is not, a runtime that
;; portal-runtime.el downloaded for the same sources serves instead; when
;; there is none either, the first native command offers to download one,
;; to build here, or neither, as `portal-build-on-first-use' says.
;; Loading this file, compiling it and generating autoloads need no native
;; code and never start a build, a download or a question.
;;
;; Each build starts by removing the record of the last one and noting the
;; identity of its sources: a hash of the files it reads.  It ends by loading
;; the new module and starting the new host, where there is one, in a
;; disposable batch Emacs, then records that identity, unless the sources
;; changed meanwhile.  So a failed,
;; partial or overtaken build never looks ready.

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defvar portal-server-program)
(declare-function portal-start-server "portal-server" ())
(declare-function portal-stop-server "portal-server" ())
(declare-function portal-server-url "portal-server" ())
(declare-function lm-header "lisp-mnt" (header))
(declare-function portal-runtime-installed "portal-runtime" (&optional identity))
(declare-function portal-runtime-superseded "portal-runtime" (identity))
(declare-function portal-runtime-problem "portal-runtime" ())
(declare-function portal-runtime-release "portal-runtime" ())
(declare-function portal-download-runtime "portal-runtime" ())
(declare-function portal-runtime-offer-build "portal-runtime" (text))
(defvar portal-runtime--process)

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
builds, or else a runtime downloaded for these sources.  Set it to use a
build made elsewhere, such as a distribution's: Portal then reports a
missing or stale build instead of offering to download or build one."
  :type '(choice (const :tag "Portal's own build" nil) directory))

(defcustom portal-build-on-first-use 'ask
  "What the first native command does without a usable native part.
That is when Portal's native part is missing, or older than its sources.
`ask' offers to download it, to build it here, or neither.
`download' downloads it without asking: the runtime of this Portal's
  release, when that release was built from these native sources.  When
  it cannot, Portal says why and that `portal-build' can build it here; it
  never builds instead.
`build' builds it here without asking.  `always', its former name, still
  means the same: it never downloads.
`never' only reports it; `portal-download-runtime' and `portal-build'
  remain.
Batch Emacs never downloads, builds or asks, nor does Portal when
`portal-build-directory' names a build made elsewhere."
  :type '(choice (const :tag "Offer to download or build" ask)
                 (const :tag "Download without asking" download)
                 (const :tag "Build without asking" build)
                 (const :tag "Build without asking (former name)" always)
                 (const :tag "Only report" never)))

(defcustom portal-build-bun nil
  "Absolute file name of the Bun that builds Portal's app host, or nil.
nil uses Portal's pinned Bun, the one tools/bun.manifest names, cached in
`portal-build-tools-directory': the host contains the Bun that compiled
it, and a bun on `exec-path' is not used.  A Bun named here that is
missing or incompatible fails the build rather than being replaced.
Only macOS builds the host: a Linux build, which has no web views yet,
needs no Bun."
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
  (if (eq system-type 'darwin)
      '("portal.bundle/Contents/Info.plist"
        "portal.bundle/Contents/MacOS/portal.dylib"
        "portal.bundle/Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/Contents/Resources/terminfo/78/xterm-ghostty"
        "portal.bundle/Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/Contents/Resources/Ghostty/shell-integration"
        "portal-host")
    '("portal.so"
      "ghostty-linux/lib/libghostty.so"
      "ghostty-linux/share/ghostty/shell-integration"
      "ghostty-linux/share/terminfo/x/xterm-ghostty"))
  "Files of a complete build, relative to the build directory.
macOS builds a bundle that holds the module and Ghostty's resources, and
the app host; Linux builds the module and keeps Ghostty's library and
resources in ghostty-linux beside it, and no host, having no web views.")

(defconst portal-build--host
  (and (member "portal-host" portal-build--artifacts) "portal-host")
  "The app host in the build directory, or nil where the build makes none.")

(defconst portal-build--module
  (if (eq system-type 'darwin) "portal.bundle/Contents/MacOS/portal.dylib" "portal.so")
  "The single native module used by all Portal features.
It is relative to the build directory.")

(defconst portal-build--tools
  (if (eq system-type 'darwin)
      '("cmake" "ninja" "xcrun")
    '("cmake" "ninja" "cc" "pkg-config" "tic"))
  "The programs a build needs before it can start, besides Emacs and Bun.
On Linux, Zig too, which `portal-build--ghostty-problem' checks.")

(defconst portal-build--record "portal-build.eld"
  "The file in which a successful build records its identity.")

(defconst portal-build--start "portal-build-start.eld"
  "The file in which a running build notes the identity it builds.")

(defvar portal-build--process nil "The running build, or nil.")
(defvar portal-build--loaded nil
  "Identity of the build whose module this Emacs loaded, or nil.")
(defvar portal-build--ready nil
  "Non-nil once this Lisp found Portal's build ready.")
(defvar portal-build--runtime nil
  "Directory of the downloaded runtime Portal uses, or nil for its build.
`portal-build-ensure' sets it when it finds a runtime ready in place of
Portal's own build.")
;; Check again when this file is reloaded, as a package upgrade does.
(setq portal-build--ready nil
      portal-build--runtime nil)

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
  "Return the absolute name of NAME in Portal's build directory.
That is `portal-build-directory', or the build directory in
`portal-build-root', where `portal-build' builds."
  (expand-file-name name (or portal-build-directory
                             (expand-file-name "build" portal-build-root))))

(defun portal-build-native-file (name)
  "Return the absolute name of NAME in the native part Portal uses.
That is Portal's build directory, or the downloaded runtime that
`portal-build-ensure' chose in its place."
  (if (and portal-build--runtime (not portal-build-directory))
      (expand-file-name name portal-build--runtime)
    (portal-build-file name)))

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

(defun portal-build--git (&rest arguments)
  "Run git with ARGUMENTS in `portal-build-root'; return (STATUS . OUTPUT).
OUTPUT is standard output, trimmed.  Return nil when `portal-build-root'
is not itself a Git checkout, as for a supplied build, or Git is missing."
  (when (file-exists-p (expand-file-name ".git" portal-build-root))
    (with-temp-buffer
      (let ((default-directory portal-build-root))
        (when-let* ((status (ignore-errors
                              (apply #'call-process "git" nil '(t nil) nil arguments))))
          (cons status (string-trim (buffer-string))))))))

(defun portal-build--detached-p ()
  "Return non-nil when Portal's Git checkout has no branch checked out.
`package-vc-upgrade' pulls, which Git refuses on such a checkout."
  (eql 1 (car (portal-build--git "symbolic-ref" "-q" "HEAD"))))

(defun portal-build--detached-advice ()
  "Return a sentence to add to a build's message when the checkout cannot upgrade.
It is empty unless `portal-build--detached-p'; otherwise it starts with the
period that ends the message before it."
  (if (portal-build--detached-p)
      (format-message ".  This Portal is not on a branch, so `package-vc-upgrade' \
cannot upgrade it: run `git fetch' and `git switch stable' in %s"
                      (abbreviate-file-name portal-build-root))
    ""))

;;;###autoload
(defun portal-version (&optional show)
  "Return which Portal this is, and show it in the echo area when SHOW.
That is the version in portal.el's header and, in a Git checkout, how far
past the last release tag it is and the branch, such as
\"Portal 0.2.0 (stable)\" or \"Portal 0.2.0, 41 commits on, 077a551 (main)\".
Interactively, SHOW is t."
  (interactive (list t))
  (let* ((version (or (portal-build-version) "unknown"))
         (branch (portal-build--git "symbolic-ref" "--short" "-q" "HEAD"))
         (describe (portal-build--git "describe" "--tags" "--long" "--match" "v[0-9]*"))
         (place
          (cond ((null branch) nil)
                ((and (eql 0 (car describe))
                      (string-match "\\`\\(.+\\)-\\([0-9]+\\)-g\\([0-9a-f]+\\)\\'" (cdr describe)))
                 (let ((tag (match-string 1 (cdr describe)))
                       (count (string-to-number (match-string 2 (cdr describe))))
                       (commit (match-string 3 (cdr describe))))
                   (cond ((and (zerop count) (equal tag (concat "v" version))) nil)
                         ((zerop count) (format "at %s" tag))
                         (t (format "%d commit%s on%s, %s" count (if (= count 1) "" "s")
                                    (if (equal tag (concat "v" version)) "" (concat " " tag))
                                    commit)))))
                (t (cdr (portal-build--git "rev-parse" "--short" "HEAD")))))
         (text (concat "Portal " version
                       (and place (concat ", " place))
                       (pcase (car branch)
                         ('nil "")
                         (0 (format " (%s)" (cdr branch)))
                         (_ " (not on a branch)")))))
    (when show
      (message "%s" text))
    text))

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

(defun portal-build--problem-in (current)
  "Return why the build in Portal's build directory cannot be used, or nil.
CURRENT is the identity of Portal's native sources, or nil without them.
The values are those of `portal-build-problem'."
  (let* ((record (portal-build--read portal-build--record))
         (recorded (plist-get record :identity)))
    (cond ((not (and recorded
                     (cl-every (lambda (file) (file-exists-p (portal-build-file file)))
                               portal-build--artifacts)))
           'missing)
          ((if current
               (not (equal current recorded))
             (not (equal (portal-build-version) (plist-get record :version))))
           'stale)
          ((and portal-build--loaded (not (equal portal-build--loaded recorded))) 'restart))))

(defun portal-build--state ()
  "Return (PROBLEM . RUNTIME): what `portal-build-problem' says, and where.
RUNTIME is the directory of a downloaded runtime to use in place of
Portal's own build, or nil for that build.  Portal's own build comes
first; when it cannot be used, a runtime downloaded for these native
sources can, unless `portal-build-directory' names a build made
elsewhere.  Without either, the problem is the build's, or `stale' when
the runtime downloaded last was for other sources."
  (let* ((current (portal-build-source-identity))
         (own (portal-build--problem-in current)))
    (if (or (memq own '(nil restart)) portal-build-directory (not current))
        (cons own nil)
      (require 'portal-runtime)
      (let* ((runtime (portal-runtime-installed current))
             (problem (and runtime (let ((portal-build-directory runtime))
                                     (portal-build--problem-in current)))))
        (cond ((and runtime (memq problem '(nil restart))) (cons problem runtime))
              ((and (eq own 'missing) (portal-runtime-superseded current)) (cons 'stale nil))
              (t (cons own nil)))))))

(defun portal-build-problem ()
  "Return why Portal's native part cannot be used now, or nil when it can.
The native part is Portal's build or, when that cannot be used, a
runtime downloaded for the same native sources.  The result is `missing'
for an absent or incomplete build, `stale' for one built from other
sources, or `restart' when this Emacs loaded the module of another build.
Without native sources, as for a supplied build, a build from another
version of Portal is stale."
  (car (portal-build--state)))

(defun portal-build--describe (problem)
  "Return a sentence about PROBLEM, a value of `portal-build-problem'."
  (pcase problem
    ('missing (if portal-build--host
                  "Portal's native module and app host are not built"
                "Portal's native module is not built"))
    ('stale "Portal's native part is older than its sources")
    ('restart "Portal's native module changed after Emacs loaded it")))

(defun portal-build--exec-path ()
  "Return the directories a build searches for its tools, in order.
They are `exec-path', which a build gets as PATH, then the
`portal-build--tool-directories' that build.sh adds."
  (append exec-path (seq-difference portal-build--tool-directories exec-path)))

(defun portal-build--zig-release (version)
  "Return VERSION, a Zig version, as a list of three integers, or nil.
A development build counts by its release, as Ghostty's build counts it."
  (when (string-match "\\`\\([0-9]+\\)\\.\\([0-9]+\\)\\.\\([0-9]+\\)\\(?:[-+]\\|\\'\\)"
                      version)
    (mapcar (lambda (group) (string-to-number (match-string group version))) '(1 2 3))))

(defun portal-build--ghostty-problem ()
  "Return why a Linux build cannot build Ghostty's library, or nil.
It needs the Zig that native/ghostty.json names, or a later patch release
of it, as Ghostty's build itself requires: `zig' where the build finds its
tools, or the program the ZIG environment variable names.  And EGL to link
against, which pkg-config finds."
  (let* ((pin (with-temp-buffer
                (insert-file-contents (expand-file-name "native/ghostty.json" portal-build-root))
                (json-parse-buffer)))
         (needs (gethash "zig" pin))
         (exec-path (portal-build--exec-path))
         (zig (executable-find (or (getenv "ZIG") "zig")))
         (has (and zig (with-temp-buffer
                         (and (eql 0 (ignore-errors (call-process zig nil '(t nil) nil "version")))
                              (string-trim (buffer-string))))))
         (wanted (portal-build--zig-release needs))
         (found (and has (portal-build--zig-release has))))
    (cond ((not zig)
           (format "Zig %s, which builds Ghostty's library: install it, or name it \
with the ZIG environment variable" needs))
          ((not (and found (= (nth 0 found) (nth 0 wanted)) (= (nth 1 found) (nth 1 wanted))
                     (>= (nth 2 found) (nth 2 wanted))))
           (format "Zig %s or a later %s patch release, which builds Ghostty's library: \
%s is Zig %s" needs needs zig (or has "of an unknown version")))
          ((not (and (executable-find "pkg-config")
                     (eql 0 (ignore-errors (call-process "pkg-config" nil nil nil
                                                         "--exists" "egl")))))
           "EGL's development files, which Ghostty's library links against: \
install pkg-config's egl, such as libglvnd's"))))

(defun portal-build--check-prerequisites ()
  "Signal a `user-error' if `portal-build' cannot succeed, saying why."
  (let ((build (portal-build-file "")))
    (cond (portal-build-directory
           (user-error "Portal uses the build in %s (`portal-build-directory'), \
which `portal-build' does not make" portal-build-directory))
          ((not (file-exists-p (expand-file-name "build.sh" portal-build-root)))
           (user-error "Portal's sources in %s lack build.sh" portal-build-root))
          ((not (and (memq system-type '(darwin gnu/linux)) module-file-suffix))
           (user-error "Portal needs Emacs with module support, on macOS or Linux"))
          ((not (file-writable-p (if (file-exists-p build) build portal-build-root)))
           (user-error "Portal cannot build in %s: it is not writable.  \
Build Portal elsewhere and set `portal-build-directory'" build)))
    (when-let* ((missing (let ((exec-path (portal-build--exec-path)))
                           (seq-remove #'executable-find portal-build--tools))))
      (user-error "Portal's build needs %s: %s.  If they are installed elsewhere, \
add their directory to `exec-path'"
                  (string-join missing ", ")
                  (if (eq system-type 'darwin)
                      (format-message "install CMake and Ninja, for example \
with `brew install cmake ninja', and Xcode")
                    "install CMake, Ninja, a C compiler, pkg-config and ncurses' tic, \
with the development files of GTK 3 and Wayland")))
    (when-let* (((eq system-type 'gnu/linux))
                (problem (portal-build--ghostty-problem)))
      (user-error "Portal's build needs %s" problem))))

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
  "Build Portal's native module, and on macOS its app host, in the background.
The build shows its progress in *portal-build*, uses this Emacs and its
module header, and finds tools on `exec-path', then where Homebrew and
MacPorts install them.  The first build downloads dependencies, and on
macOS Portal's pinned Bun, unless `portal-build-bun' names another.  The
build keeps only what Portal runs and deletes
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
    (if (not (string-prefix-p "finished" status))
        (message "Portal's build failed: see %s" (buffer-name buffer))
      (message "%s%s"
               (cond ((eq problem 'restart)
                      "Portal is built: restart Emacs to load its new native module")
                     (problem
                      (concat "Portal's build finished, but "
                              (downcase (portal-build--describe problem))))
                     (t "Portal is ready: retry your command"))
               (portal-build--detached-advice)))))

(defun portal-build-ensure ()
  "Signal a `user-error' unless Portal's native part can be loaded now.
That is Portal's build or a runtime downloaded for its sources.  When
neither is ready, download or build one as `portal-build-on-first-use'
says.  Either runs in the background, so the command that needed it stops
either way and can be retried after."
  (unless portal-build--ready
    (pcase-let ((`(,problem . ,runtime) (portal-build--state)))
      (if (null problem)
          (setq portal-build--ready t
                portal-build--runtime runtime)
        (let ((description (portal-build--describe problem)))
          (cond ((eq problem 'restart)
                 (user-error "%s: restart Emacs to use it" description))
                ((process-live-p portal-build--process)
                 (user-error "%s yet: retry when the build in *portal-build* finishes"
                             description))
                ((and (boundp 'portal-runtime--process)
                      (process-live-p portal-runtime--process))
                 (user-error "%s yet: retry when the download in *portal-runtime* finishes"
                             description))
                (portal-build-directory
                 (user-error "%s in %s" description portal-build-directory))
                (t (portal-build--first-use description))))))))

(defun portal-build--first-use (description)
  "Download or build Portal's native part, as `portal-build-on-first-use' says.
DESCRIPTION says what is wrong with it.  Always signal a `user-error':
the command that needed the native part stops, and a download or build
it started runs in the background."
  (let ((choice (if (eq portal-build-on-first-use 'always) 'build portal-build-on-first-use)))
    (when (or noninteractive (eq choice 'never)
              (not (or this-command (memq choice '(build download)))))
      (user-error "%s: %s" description (portal-build--routes)))
    (pcase choice
      ('build (portal-build--start))
      ('download
       (when-let* ((reason (portal-build--download-problem)))
         (user-error "%s, and Portal cannot download it: %s" description
                     (portal-runtime-offer-build reason)))
       (portal-build--download))
      (_
       (let ((download (portal-build--download-problem))
             (build (condition-case err (progn (portal-build--check-prerequisites) nil)
                      (user-error (cadr err)))))
         (when (and download build)
           (user-error "%s, and Portal can neither download it nor build it here.  %s.  %s"
                       description download build))
         (pcase (car (read-multiple-choice
                      (concat description "." (if download (format "  %s." download) "")
                              "  Get it now?")
                      (append
                       (unless download
                         `((?d "download"
                               ,(format "Download the runtime of Portal's release %s \
from GitHub, check it and keep it in `portal-runtime-directory'"
                                        (portal-runtime-release)))))
                       (unless build
                         '((?b "build here"
                               "Build it from these sources with M-x portal-build.  \
The first build downloads its dependencies and takes several minutes")))
                       '((?n "not now"
                             "Do neither.  M-x portal-download-runtime and \
M-x portal-build remain")))))
           (?d (portal-build--download))
           (?b (portal-build--start))
           (_ (user-error "%s: %s" description (portal-build--routes)))))))))

(defun portal-build--download-problem ()
  "Return why Portal cannot download its native part here, or nil.
It asks no network: only a download can tell whether a release holds
the runtime these sources need."
  (require 'portal-runtime)
  (portal-runtime-problem))

(defun portal-build--routes ()
  "Return what the user can run to get Portal's native part, as a sentence."
  (if (portal-build--download-problem)
      "run M-x portal-build"
    "run M-x portal-build to build it here, or M-x portal-download-runtime to \
download it"))

(defun portal-build--start ()
  "Start `portal-build' and stop the command that needed it."
  (portal-build--check-prerequisites)
  (portal-build)
  (user-error "Building Portal in *portal-build*: retry when it finishes"))

(defun portal-build--download ()
  "Start `portal-download-runtime' and stop the command that needed it."
  (portal-download-runtime)
  (user-error "Downloading Portal's runtime in *portal-runtime*: retry when it finishes"))

(defun portal-build-load-module ()
  "Load Portal's native module, once `portal-build-ensure' finds it ready."
  (portal-build-ensure)
  (let* ((portal-build-directory (file-name-as-directory (portal-build-native-file "")))
         (identity (portal-build--recorded-identity)))
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

(defun portal-build--check-artifacts ()
  "Signal an error naming the first file of a complete build that is missing."
  (dolist (file portal-build--artifacts)
    (unless (file-exists-p (portal-build-file file))
      (error "Portal's build lacks %s" (portal-build-file file)))))

(defun portal-build--check-runs ()
  "Load the build's module and start its host, or signal an error.
Only a disposable batch Emacs may: the module stays loaded."
  (module-load (portal-build-file portal-build--module))
  (unless (fboundp 'portal--web-load)
    (error "Portal's native module lacks its functions"))
  ;; On Linux, start Ghostty's library from the module's own place, with
  ;; the resources beside it.
  (when (fboundp 'portal--terminal-engine)
    (portal--terminal-engine))
  (when portal-build--host
    (portal-build--probe-host (portal-build-file portal-build--host))))

(defun portal-build--finish-batch ()
  "Check a finished build and record its identity, in a disposable batch Emacs.
The argument after this function's name on the command line is the build
directory.  The build runs this last: loading the new module anywhere else
could replace one that Emacs already uses."
  (let ((portal-build-directory (file-name-as-directory (pop command-line-args-left))))
    (portal-build--check-artifacts)
    (portal-build--check-runs)
    (portal-build--record-identity)
    (message "The Portal build is complete")))

(defun portal-build--probe-batch ()
  "Check a build made elsewhere in a disposable batch Emacs.
The argument after this function's name on the command line is its
directory, such as that of an unpacked runtime archive.  It must be
ready for this Lisp as `portal-build-directory': complete, and recorded
from these sources, or without them this version.  Its module must load
from there and its host start."
  (let ((portal-build-directory (file-name-as-directory
                                 (expand-file-name (pop command-line-args-left)))))
    (portal-build--check-artifacts)
    (when-let* ((problem (portal-build-problem)))
      (error "%s in %s" (portal-build--describe problem) portal-build-directory))
    (portal-build--check-runs)
    (message "The Portal build in %s is ready" portal-build-directory)))

(provide 'portal-build)
;;; portal-build.el ends here
