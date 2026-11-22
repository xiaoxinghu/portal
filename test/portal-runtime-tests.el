;;; portal-runtime-tests.el --- Downloading and installing the native runtime -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in batch with the package directory on `load-path'.  The tests
;; publish fixture releases from a source tree of their own, pack them with
;; scripts/runtime-archive.py and serve them over HTTPS from 127.0.0.1 with
;; test/runtime-assets.py, under a certificate authority made for the run.
;; Nothing reaches the network or the user's runtimes.  A fixture runtime's
;; module is the C core's test module, PORTAL_TEST_MODULE, so the installs
;; need it, Python 3 and openssl, and a system that has a runtime to
;; download; the checks that need no install run anywhere.  The first
;; native command's choice, at the end, never builds: `portal-build' is a
;; stand-in there.

(require 'ert)
(require 'cl-lib)
(require 'gnutls)
(require 'nsm)
(require 'portal-build)
(require 'portal-runtime)
(require 'portal-server)

(defconst portal-runtime-test--checkout
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))
  "The Portal checkout these tests come from.")

(defconst portal-runtime-test--assets
  (expand-file-name "test/runtime-assets.py" portal-runtime-test--checkout))

(defvar portal-runtime-test--certificates nil
  "The run's directory of test certificates, made when first needed.")

(defvar portal-runtime-test--world nil
  "The current test's temporary directory.")

(defvar portal-runtime-test--servers nil
  "The current test's asset servers, by certificate.")

(defun portal-runtime-test--python ()
  "Return Python 3, or nil."
  (executable-find "python3"))

(defun portal-runtime-test--can-install ()
  "Return non-nil when this system can run a real install of a fixture."
  (and (portal-runtime--target) (getenv "PORTAL_TEST_MODULE")
       (portal-runtime-test--python) (executable-find "openssl")))

(defun portal-runtime-test--run (&rest arguments)
  "Run Python with ARGUMENTS; signal an error with its output unless it succeeds."
  (with-temp-buffer
    (unless (eql 0 (apply #'call-process (portal-runtime-test--python) nil t nil "-B" arguments))
      (error "%s failed: %s" arguments (buffer-string)))))

(defun portal-runtime-test--certificate-directory ()
  "Return the run's certificate directory, making it the first time."
  (unless portal-runtime-test--certificates
    (let ((directory (make-temp-file "portal runtime certificates " t)))
      (add-hook 'kill-emacs-hook (lambda () (delete-directory directory t)))
      (portal-runtime-test--run portal-runtime-test--assets "certs" directory)
      (setq portal-runtime-test--certificates (file-name-as-directory directory))))
  portal-runtime-test--certificates)

(defun portal-runtime-test--file (name)
  "Return NAME in the current test's world."
  (expand-file-name name portal-runtime-test--world))

(defun portal-runtime-test--write (file text &optional mode)
  "Write TEXT to FILE, making its directories, and give it MODE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text))
  (when mode (set-file-modes file mode)))

(defmacro portal-runtime-test--with-world (&rest body)
  "Run BODY with a source tree, a runtime cache and a release site of its own.
The tree holds copies of Portal's Lisp, not links, so that a separate
Emacs that loads them takes this tree as `portal-build-root'.  Its
version is 1.2.3.  Every name contains a space."
  (declare (indent 0))
  `(let* ((portal-runtime-test--world (file-name-as-directory
                                       (make-temp-file "portal runtime world " t)))
          (portal-runtime-test--servers nil)
          (portal-build-root (portal-runtime-test--file "source tree/"))
          (portal-build-directory nil)
          (portal-build--loaded nil)
          (portal-build--ready nil)
          (portal-build--runtime nil)
          (portal-build--process nil)
          (portal-build-on-first-use 'ask)
          (portal-runtime--process nil)
          (portal-runtime-directory (portal-runtime-test--file "runtime cache/"))
          (portal-runtime--releases "https://127.0.0.1:1/unused/")
          (gnutls-trustfiles nil))
     (unwind-protect
         (progn
           (make-directory portal-build-root t)
           (dolist (file '("portal-build.el" "portal-server.el" "portal-runtime.el"))
             (copy-file (expand-file-name file portal-runtime-test--checkout)
                        (expand-file-name file portal-build-root) t))
           (dolist (file '("native/Package.swift" "native/Core/emacs.c" "host/server.ts"
                           "tools/bun.manifest" "CMakeLists.txt" "build.sh"))
             (portal-runtime-test--write (expand-file-name file portal-build-root) file))
           (portal-runtime-test--version "1.2.3")
           ,@body)
       (when (process-live-p portal-runtime--process)
         (kill-process portal-runtime--process))
       (dolist (server portal-runtime-test--servers)
         (delete-process (cdr server)))
       (when (get-buffer "*portal-runtime*") (kill-buffer "*portal-runtime*"))
       (delete-directory portal-runtime-test--world t))))

(defun portal-runtime-test--version (version)
  "Make VERSION the source tree's version."
  (portal-runtime-test--write (expand-file-name "portal.el" portal-build-root)
                              (format ";;; portal.el --- Portal\n;; Version: %s\n" version)))

(defun portal-runtime-test--native-change (text)
  "Change the source tree's native sources, writing TEXT into one."
  (portal-runtime-test--write (expand-file-name "native/Core/emacs.c" portal-build-root) text))

(defun portal-runtime-test--release (&optional module target)
  "Publish a release of the source tree as it is, and return its identity.
Its runtime, for TARGET or this system's, is built from the test module,
or from MODULE: a file's contents, or (:file FILE) for a file's own.  It
is packed by scripts/runtime-archive.py under the tag of the tree's
version."
  (let* ((identity (portal-build-source-identity))
         (version (portal-build-version))
         (target (or target (portal-runtime--target)))
         (spec (cdr (assoc target portal-runtime--targets)))
         (linux (string-prefix-p "linux-" target))
         (build (portal-runtime-test--file (format "builds/%s %s/" target version)))
         (place (lambda (file) (expand-file-name file build)))
         (module-file (funcall place (if linux "portal.so"
                                       "portal.bundle/Contents/MacOS/portal.dylib"))))
    (dolist (file (plist-get spec :files))
      (portal-runtime-test--write (funcall place file) file))
    (pcase module
      ('nil (copy-file (getenv "PORTAL_TEST_MODULE") module-file t))
      (`(:file ,file) (copy-file file module-file t))
      (_ (portal-runtime-test--write module-file module)))
    (dolist (file (plist-get spec :executables))
      (portal-runtime-test--write
       (funcall place file)
       "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"ready\",\"protocol\":3,\"port\":4242,\
\"token\":\"0123456789abcdef0123456789abcdef\"}'\nexec cat >/dev/null\n"
       #o755))
    (if linux
        ;; Ghostty's library under its soname, a link, as a build leaves it.
        (let ((library (funcall place "ghostty-linux/lib/libghostty.so")))
          (portal-runtime-test--write (funcall place "ghostty-linux/lib/ghostty-internal.so")
                                      "Ghostty")
          (delete-file library)
          (make-symbolic-link "ghostty-internal.so" library))
      (portal-runtime-test--write (funcall place "portal.bundle/Contents/Info.plist") "<plist/>")
      ;; A link within the runtime, as bundles have.
      (make-symbolic-link "../Info.plist"
                          (funcall place "portal.bundle/Contents/Resources/Info-link") t))
    (portal-runtime-test--write (funcall place portal-build--record)
                                (prin1-to-string (list :identity identity :version version)))
    (portal-runtime-test--run (expand-file-name "scripts/runtime-archive.py"
                                                portal-runtime-test--checkout)
                              "pack" "--tag" (concat "v" version) "--target" target
                              "--commit" "0123456789abcdef0123456789abcdef01234567"
                              build (portal-runtime-test--file (format "site/v%s" version)))
    identity))

(defun portal-runtime-test--manifest (&optional version)
  "Return the file of the manifest of VERSION's release, the tree's by default."
  (portal-runtime-test--file
   (let ((tag (concat "v" (or version (portal-build-version)))))
     (format "site/%s/%s" tag (portal-runtime--asset tag (portal-runtime--target) ".json")))))

(defun portal-runtime-test--serve (&optional certificate)
  "Serve the release site with CERTIFICATE, `trusted' by default; return its URL.
Trust the run's certificate authority."
  (let* ((certificate (or certificate 'trusted))
         (server (cdr (assq certificate portal-runtime-test--servers))))
    (unless server
      (make-directory (portal-runtime-test--file "site") t)
      (setq server (make-process
                    :name "portal-runtime-assets" :connection-type 'pipe :noquery t
                    ;; Python's complaints of failed handshakes go apart.
                    :stderr (with-current-buffer (get-buffer-create
                                                  " *portal-runtime-assets errors*")
                              (erase-buffer)
                              (current-buffer))
                    :command (list (portal-runtime-test--python) "-B" portal-runtime-test--assets
                                   "serve" (portal-runtime-test--certificate-directory)
                                   (symbol-name certificate) (portal-runtime-test--file "site"))
                    :filter (lambda (process output)
                              (let ((pending (concat (process-get process 'pending) output)))
                                (while (string-match "\n" pending)
                                  (let ((record (ignore-errors
                                                  (json-parse-string
                                                   (substring pending 0 (match-beginning 0))
                                                   :object-type 'plist))))
                                    (cond
                                     ((not record))
                                     ((plist-get record :port)
                                      (process-put process 'port (plist-get record :port)))
                                     (t
                                      (process-put process 'paths
                                                   (append (process-get process 'paths)
                                                           (list (plist-get record :path)))))))
                                  (setq pending (substring pending (match-end 0))))
                                (process-put process 'pending pending)))))
      (push (cons certificate server) portal-runtime-test--servers)
      (let ((deadline (+ (float-time) 30)))
        (while (not (process-get server 'port))
          (unless (and (process-live-p server) (< (float-time) deadline))
            (error "The asset server did not start (%s): %s" (process-status server)
                   (with-current-buffer " *portal-runtime-assets errors*" (buffer-string))))
          (accept-process-output server 0.1))))
    (setq gnutls-trustfiles
          (list (expand-file-name "ca.pem" (portal-runtime-test--certificate-directory))))
    (format "https://127.0.0.1:%d/" (process-get server 'port))))

(defun portal-runtime-test--requests (&optional certificate)
  "Return the paths requested of the CERTIFICATE server so far, and forget them."
  (let ((server (cdr (assq (or certificate 'trusted) portal-runtime-test--servers))))
    (accept-process-output server 0.2)
    (prog1 (process-get server 'paths)
      (process-put server 'paths nil))))

(defun portal-runtime-test--install (&optional releases)
  "Install in this Emacs, from RELEASES or the trusted server's site."
  (portal-runtime--install
   (list :directory portal-runtime-directory
         :releases (or releases (portal-runtime-test--serve))
         :trustfiles gnutls-trustfiles)))

(defun portal-runtime-test--paths (directory &optional target)
  "Return the paths of the manifest and archive of TARGET in DIRECTORY.
TARGET defaults to this system's; DIRECTORY is a tag's, as requested."
  (let ((tag (car (last (split-string directory "/" t)))))
    (mapcar (lambda (extension)
              (concat directory (portal-runtime--asset tag (or target (portal-runtime--target))
                                                       extension)))
            '(".json" ".tar.gz"))))

(defun portal-runtime-test--cache ()
  "Return what the runtime cache holds: each path, with a link's target.
The lock is left out: it is the system's, not the cache's contents."
  (let ((place (portal-runtime--target-directory)))
    (and (file-directory-p place)
         (mapcar (lambda (file)
                   (cons (file-relative-name file place) (file-symlink-p file)))
                 (seq-remove (lambda (file) (equal (file-name-nondirectory file) "lock"))
                             (directory-files-recursively place "" t))))))

(defun portal-runtime-test--runtimes ()
  "Return the identities of the runtimes in the cache, sorted."
  (sort (directory-files (portal-runtime--target-directory) nil "\\`[0-9a-f]\\{64\\}\\'")
        #'string<))

(defun portal-runtime-test--current ()
  "Return the identity of the current runtime."
  (plist-get (portal-runtime--state (portal-runtime--target-directory)) :current))

(defun portal-runtime-test--refused (pattern &optional releases)
  "Install and expect a refusal matching PATTERN that leaves the cache as it was."
  (let ((before (portal-runtime-test--cache))
        (message (cadr (should-error (portal-runtime-test--install releases)))))
    (should (string-match-p pattern message))
    (should (equal (portal-runtime-test--cache) before))
    message))

(defun portal-runtime-test--wait (process)
  "Wait for PROCESS to end, for at most a minute."
  (let ((deadline (+ (float-time) 60)))
    (while (process-live-p process)
      (when (> (float-time) deadline) (error "%s did not end" process))
      (accept-process-output process 0.1))
    ;; Let its sentinel run.
    (accept-process-output nil 0.1)))

(defun portal-runtime-test--vary (kind)
  "Replace the tree's release by a copy whose archive is changed as KIND says.
The manifest gives the changed archive's size and SHA-256.  The release
as packed is kept aside, so that the next variant starts from it too."
  (let* ((manifest (portal-runtime-test--manifest))
         (release (file-name-directory manifest))
         (good (concat (directory-file-name release) " as packed/")))
    (unless (file-directory-p good)
      (rename-file (directory-file-name release) (directory-file-name good)))
    (when (file-directory-p release)
      (delete-directory release t))
    (portal-runtime-test--run portal-runtime-test--assets "variant" kind
                              (expand-file-name (file-name-nondirectory manifest) good)
                              release)))

;;; Without installing

(ert-deftest portal-runtime-chooses-by-the-emacs-process ()
  (let ((system-type 'darwin))
    (dolist (case '(("aarch64-apple-darwin25.6.0" . "macos-arm64")
                    ("arm64-apple-darwin24.1.0" . "macos-arm64")
                    ;; An Intel Emacs, under Rosetta or not.
                    ("x86_64-apple-darwin24.1.0" . nil)))
      (let ((system-configuration (car case)))
        (should (equal (portal-runtime--target) (cdr case))))))
  ;; On Linux by the CPU and the C library, one runtime for each CPU
  ;; whatever the distribution.
  (let ((system-type 'gnu/linux))
    (dolist (case '(("x86_64-pc-linux-gnu" . "linux-x86_64-gnu")
                    ("x86_64-linux-gnu" . "linux-x86_64-gnu")
                    ("aarch64-unknown-linux-gnu" . "linux-aarch64-gnu")
                    ("x86_64-alpine-linux-musl" . nil)
                    ("aarch64-unknown-linux-musl" . nil)
                    ("riscv64-unknown-linux-gnu" . nil)
                    ("i686-pc-linux-gnu" . nil)
                    ("arm-unknown-linux-gnueabihf" . nil)
                    ("x86_64-pc-linux-gnux32" . nil)))
      (let ((system-configuration (car case)))
        (should (equal (portal-runtime--target) (cdr case))))))
  (let ((system-type 'berkeley-unix) (system-configuration "x86_64-unknown-freebsd15.0"))
    (should-not (portal-runtime--target))))

(ert-deftest portal-runtime-describes-the-archives-runtime-archive-py-packs ()
  (skip-unless (portal-runtime-test--python))
  ;; The same targets, floors and entries as the script that packs them.
  (let ((packed (with-temp-buffer
                  (unless (eql 0 (call-process
                                  (portal-runtime-test--python) nil t nil "-B" "-c"
                                  "import json, runpy, sys
print(json.dumps(runpy.run_path(sys.argv[1])['TARGETS']))"
                                  (expand-file-name "scripts/runtime-archive.py"
                                                    portal-runtime-test--checkout)))
                    (error "%s" (buffer-string)))
                  (goto-char (point-min))
                  (json-parse-buffer :object-type 'alist :array-type 'list))))
    (should (equal (sort (mapcar #'car portal-runtime--targets) #'string<)
                   (sort (mapcar (lambda (pair) (symbol-name (car pair))) packed) #'string<)))
    (pcase-dolist (`(,target . ,spec) portal-runtime--targets)
      (let ((theirs (alist-get (intern target) packed)))
        (should (equal (plist-get spec :floor) (alist-get 'floor theirs)))
        (should (equal (plist-get spec :entries) (alist-get 'entries theirs)))
        (should (equal (plist-get spec :executables) (alist-get 'executables theirs)))
        (should-not (seq-difference (alist-get 'required theirs)
                                    (append (plist-get spec :files) '("portal-build.eld")
                                            (plist-get spec :executables)
                                            (list (if (string-prefix-p "linux-" target)
                                                      "portal.so"
                                                    "portal.bundle/Contents/MacOS/portal.dylib")))))))
    ;; A complete runtime is a complete build of its system.
    (when-let* ((spec (cdr (assoc (portal-runtime--target) portal-runtime--targets))))
      (should-not (seq-difference portal-build--artifacts (plist-get spec :files))))))

(ert-deftest portal-runtime-problem-says-what-it-cannot-serve ()
  ;; As an Apple Silicon Emacs, on whatever system the test runs.
  (portal-runtime-test--with-world
    (let ((system-type 'darwin) (system-configuration "aarch64-apple-darwin25.6.0"))
      (should-not (portal-runtime-problem))
      ;; Without its native sources Portal cannot tell which runtime it
      ;; needs: a version alone does not say.
      (rename-file (expand-file-name "native" portal-build-root)
                   (expand-file-name "native away" portal-build-root))
      (should (string-match-p "cannot tell which runtime" (portal-runtime-problem)))
      (rename-file (expand-file-name "native away" portal-build-root)
                   (expand-file-name "native" portal-build-root))
      (portal-runtime-test--version "1.2")
      (should (string-match-p "names no release" (portal-runtime-problem))))
    (let ((system-type 'darwin) (system-configuration "x86_64-apple-darwin24.1.0"))
      (should (string-match-p "no runtime to download for x86_64-apple-darwin24\\.1\\.0: \
build it with M-x portal-build\\'"
                              (portal-runtime-problem)))
      (should-error (portal-runtime-install) :type 'user-error))))

(ert-deftest portal-runtime-reads-only-the-manifest-it-asked-for ()
  ;; The example manifest, then one change each, as check_manifest refuses.
  (let* ((example (with-temp-buffer
                    (insert-file-contents (expand-file-name "test/fixtures/runtime-manifest.json"
                                                            portal-runtime-test--checkout))
                    (json-parse-buffer :object-type 'alist :array-type 'list :null-object nil)))
         (read (lambda (manifest tag)
                 (with-temp-buffer
                   (insert (json-serialize
                            (cons (cons 'archives (vconcat (alist-get 'archives manifest)))
                                  (assq-delete-all 'archives (copy-sequence manifest)))
                            :null-object nil))
                   (portal-runtime--manifest (current-buffer) tag "macos-arm64"))))
         (change (lambda (key value &optional archive-key)
                   (let ((manifest (copy-tree example)))
                     (if archive-key
                         (setf (alist-get archive-key (car (alist-get 'archives manifest))) value)
                       (setf (alist-get key manifest) value))
                     manifest))))
    (let ((entry (funcall read example "v0.3.0")))
      (should (equal (alist-get 'identity entry) (alist-get 'identity example)))
      (should (equal (alist-get 'size entry) 45749571)))
    (dolist (case `(("is not for v0.3.1" ,example "v0.3.1")
                    ("is not for v0.3.0" ,(funcall change 'tag nil) "v0.3.0")
                    ("is not of format 1" ,(funcall change 'format 2) "v0.3.0")
                    ("has no native identity" ,(funcall change 'identity "885c") "v0.3.0")
                    ("lists no runtime for macos-arm64"
                     ,(funcall change nil "linux-x86_64-gnu" 'target) "v0.3.0")
                    ("claims another oldest system"
                     ,(funcall change nil '((macos . "14.0")) 'floor) "v0.3.0")
                    ("names another archive"
                     ,(funcall change nil "portal-runtime-latest-macos-arm64.tar.gz" 'name)
                     "v0.3.0")
                    ("gives the archive no size" ,(funcall change nil 0 'size) "v0.3.0")
                    ("gives the archive no SHA-256" ,(funcall change nil "x" 'sha256) "v0.3.0")))
      (should (string-match-p (car case)
                              (cadr (should-error (funcall read (nth 1 case) (nth 2 case)))))))))

;;; Linux: which runtime, and what it cannot serve

(defun portal-runtime-test--libc (version)
  "Make the world's process map name a C library of VERSION, and return it.
VERSION is a glibc version, nil for a library that does not say, or
`none' for a process map that names none, as musl's would not."
  (let ((library (portal-runtime-test--file "lib dir/libc.so.6"))
        (maps (portal-runtime-test--file "maps")))
    (make-directory (file-name-directory library) t)
    (with-temp-file library
      (set-buffer-multibyte nil)
      (setq buffer-file-coding-system 'no-conversion)
      (insert "\177ELF\2\1\1\0" (make-string 4096 0))
      (when (stringp version)
        (insert (format "GNU C Library (Ubuntu GLIBC %s-2ubuntu2.7) stable release version %s.\n"
                        version version)))
      (insert (make-string 4096 0)))
    (with-temp-file maps
      (insert "aaaab4c10000-aaaab4c90000 r-xp 00000000 00:24 1951                       /usr/bin/emacs\n")
      (unless (eq version 'none)
        (insert (format "ffff87f60000-ffff88109000 r-xp 00000000 00:24 1954                       %s\n"
                        library)))
      (insert "ffff88140000-ffff88170000 r-xp 00000000 00:24 1963                       /usr/lib/ld-linux-aarch64.so.1\n"))
    maps))

(defmacro portal-runtime-test--as-linux (configuration glibc &rest body)
  "Run BODY in the world as a Linux Emacs built for CONFIGURATION, with GLIBC.
GLIBC is as `portal-runtime-test--libc' takes it.  The frame is a pgtk
frame on Wayland, whatever this Emacs is."
  (declare (indent 2))
  `(dlet ((features (cons 'pgtk (remq 'ns features))))
     (let ((system-type 'gnu/linux)
           (system-configuration ,configuration)
           (portal-runtime--maps (portal-runtime-test--libc ,glibc))
           (window-system 'pgtk))
       (cl-letf (((symbol-function 'pgtk-backend-display-class)
                  (lambda () "GdkWaylandDisplay")))
         ,@body))))

(ert-deftest portal-runtime-reads-the-glibc-of-the-emacs-process ()
  (portal-runtime-test--with-world
    (dolist (version '("2.43" "2.39" "2.44"))
      (let ((portal-runtime--maps (portal-runtime-test--libc version)))
        (should (equal (portal-runtime--glibc) version))))
    ;; What cannot be told is nil, not a guess.
    (let ((portal-runtime--maps (portal-runtime-test--libc nil)))
      (should-not (portal-runtime--glibc)))
    (let ((portal-runtime--maps (portal-runtime-test--libc 'none)))
      (should-not (portal-runtime--glibc)))
    (let ((portal-runtime--maps (portal-runtime-test--file "no such maps")))
      (should-not (portal-runtime--glibc))))
  ;; And this Emacs's own, where it runs with glibc.
  (when (equal (cdr (portal-runtime--linux-system)) "gnu")
    (should (string-match-p "\\`2\\.[0-9]+\\'" (portal-runtime--glibc)))))

(ert-deftest portal-runtime-refuses-what-no-linux-runtime-serves ()
  (portal-runtime-test--with-world
    ;; Served: either CPU with glibc at the floor or newer, or a glibc
    ;; whose version cannot be told, which the probe decides.
    (dolist (configuration '("x86_64-pc-linux-gnu" "aarch64-unknown-linux-gnu"))
      (dolist (glibc '("2.43" "2.44" nil none))
        (portal-runtime-test--as-linux configuration glibc
          (should-not (portal-runtime--refusal))
          (should-not (portal-runtime--display-problem)))))
    ;; Refused, each with its reason and a build on offer.
    (pcase-dolist (`(,configuration ,glibc ,pattern)
                   '(("x86_64-alpine-linux-musl" none
                      "Linux runtimes need glibc, and this Emacs uses musl: build it with M-x portal-build")
                     ("aarch64-unknown-linux-musl" none "uses musl")
                     ("x86_64-pc-linux-gnu" "2.39"
                      "runtime needs glibc 2\\.43 or newer, and this Emacs uses glibc 2\\.39: build it with M-x portal-build")
                     ("aarch64-unknown-linux-gnu" "2.42" "uses glibc 2\\.42: build it")
                     ("riscv64-unknown-linux-gnu" "2.43"
                      "are for x86-64 and aarch64, and this Emacs runs on riscv64: build it with M-x portal-build")
                     ("i686-pc-linux-gnu" "2.43" "runs on i686: build it")
                     ("x86_64-pc-linux-gnux32" "2.43"
                      "need glibc, and this Emacs, built for x86_64-pc-linux-gnux32, does not use it: build it")))
      (ert-info (configuration)
        (portal-runtime-test--as-linux configuration glibc
          (should (string-match-p pattern (portal-runtime-problem)))
          (should (equal (portal-runtime-problem) (portal-runtime--refusal)))
          (should-error (portal-runtime-install) :type 'user-error)
          (should-not portal-runtime--process))))
    ;; No runtime or build cures the display: say so, and offer neither.
    (pcase-dolist (`(,setting ,pattern)
                   '((no-pgtk "built with pure GTK, for Wayland")
                     (x11 "frame on Wayland; this frame's display is a GdkX11Display")
                     (text "this frame is a text terminal")))
      (ert-info ((symbol-name setting))
        ;; Before the CPU too: a build would not cure that either.
        (dolist (configuration '("x86_64-pc-linux-gnu" "riscv64-unknown-linux-gnu"))
          (portal-runtime-test--as-linux configuration "2.43"
            (dlet ((features (if (eq setting 'no-pgtk) (remq 'pgtk features) features))
                   (window-system (if (eq setting 'text) nil window-system)))
              (cl-letf (((symbol-function 'pgtk-backend-display-class)
                         (lambda () (if (eq setting 'x11) "GdkX11Display" "GdkWaylandDisplay"))))
                (let ((problem (portal-runtime-problem)))
                  (should (string-match-p pattern problem))
                  (should (string-match-p "which no runtime or build of Portal changes\\'"
                                          problem))
                  (should-not (string-match-p "portal-build" problem))
                  (should-error (portal-runtime-install) :type 'user-error))))))))))

(ert-deftest portal-runtime-refuses-an-old-glibc-before-any-download ()
  (portal-runtime-test--with-world
    (portal-runtime-test--as-linux "x86_64-pc-linux-gnu" "2.41"
      ;; The server is never asked: it cannot be reached.
      (portal-runtime-test--refused "needs glibc 2\\.43 or newer, and this Emacs uses glibc 2\\.41"
                                    "https://127.0.0.1:1/")
      (should-not (file-exists-p (portal-runtime--target-directory))))))

(ert-deftest portal-runtime-each-linux-cpu-takes-its-own-archive ()
  ;; Both archives are released; each CPU fetches its own, and keeps it in
  ;; a directory of its own.  The module load in a disposable Emacs is the
  ;; system's own, so it is left out here: other tests run it.
  (skip-unless (and (portal-runtime-test--python) (executable-find "openssl")))
  (portal-runtime-test--with-world
    (let ((identity (portal-build-source-identity)))
      (dolist (target '("linux-x86_64-gnu" "linux-aarch64-gnu"))
        (portal-runtime-test--release "not a module" target))
      (pcase-dolist (`(,configuration ,target)
                     '(("x86_64-pc-linux-gnu" "linux-x86_64-gnu")
                       ("aarch64-unknown-linux-gnu" "linux-aarch64-gnu")))
        (ert-info (target)
          (portal-runtime-test--as-linux configuration "2.43"
            (cl-letf (((symbol-function 'portal-runtime--probe) #'ignore))
              (should (string-match-p "runtime of v1\\.2\\.3 is installed"
                                      (portal-runtime-test--install))))
            (should (equal (portal-runtime-test--requests)
                           (portal-runtime-test--paths "/v1.2.3/" target)))
            (let ((runtime (portal-runtime-installed)))
              (should (equal runtime
                             (file-name-as-directory
                              (expand-file-name (concat target "/" identity)
                                                portal-runtime-directory))))
              (should (equal (file-symlink-p
                              (expand-file-name "ghostty-linux/lib/libghostty.so" runtime))
                             "ghostty-internal.so"))
              (should (equal (directory-files (expand-file-name "ghostty-linux" runtime) nil
                                              directory-files-no-dot-files-regexp)
                             '("lib" "share"))))))))))

(ert-deftest portal-runtime-a-misjudged-glibc-fails-at-the-probe ()
  ;; The check before the download says yes, but the runtime needs a
  ;; glibc this system lacks: as a Nix or Flatpak Emacs might, with a C
  ;; library that is not the one the check read.  The loader refuses the
  ;; module in the disposable Emacs, its message is shown, the build is
  ;; offered, and the runtime already in use stays as it was.
  (skip-unless (and (eq system-type 'gnu/linux) (portal-runtime-test--can-install)))
  (portal-runtime-test--with-world
    (let ((portal-runtime--maps (portal-runtime-test--libc "2.43"))
          (newer (portal-runtime-test--file "newer glibc module.so"))
          (working (portal-runtime-test--release)))
      (portal-runtime-test--install)
      ;; The test module, needing every glibc version it names as 9.x.
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally (getenv "PORTAL_TEST_MODULE"))
        (goto-char (point-min))
        (should (re-search-forward "GLIBC_2\\.[0-9]+" nil t))
        (goto-char (point-min))
        (while (re-search-forward "GLIBC_2\\.\\([0-9]+\\)" nil t)
          (replace-match (concat "GLIBC_9." (make-string (length (match-string 1)) ?9)) t t))
        (let ((coding-system-for-write 'no-conversion))
          (write-region nil nil newer nil 'silent)))
      (portal-runtime-test--version "1.2.4")
      (portal-runtime-test--native-change "1.2.4")
      (portal-runtime-test--release (list :file newer))
      (let ((message (portal-runtime-test--refused "failed its check in a separate Emacs")))
        (should (string-match-p "version `GLIBC_9\\.[0-9.]+' not found" message))
        (should (string-match-p
                 "\nPortal's runtime for linux-[a-z0-9_]+-gnu needs glibc 2\\.43 or newer, with \
the system's GTK 3, Wayland and EGL: build it with M-x portal-build\\'"
                 message)))
      (should (equal (portal-runtime-test--current) working))
      (should (equal (portal-runtime-test--runtimes) (list working))))))

;;; Installing

(ert-deftest portal-runtime-installs-and-reuses-offline ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (let ((identity (portal-runtime-test--release)))
      (should-not (portal-runtime-installed))
      (should (string-match-p "runtime of v1\\.2\\.3 is installed" (portal-runtime-test--install)))
      (should (equal (portal-runtime-test--requests)
                     (portal-runtime-test--paths "/v1.2.3/")))
      (let ((runtime (portal-runtime-installed)))
        (should (equal runtime (file-name-as-directory
                                (expand-file-name identity (portal-runtime--target-directory)))))
        (should (equal (portal-runtime-test--current) identity))
        (dolist (file (plist-get (cdr (assoc (portal-runtime--target) portal-runtime--targets))
                                 :executables))
          (should (file-executable-p (expand-file-name file runtime))))
        (if (eq system-type 'darwin)
            (should (equal (file-symlink-p
                            (expand-file-name "portal.bundle/Contents/Resources/Info-link" runtime))
                           "../Info.plist"))
          (should (equal (file-symlink-p
                          (expand-file-name "ghostty-linux/lib/libghostty.so" runtime))
                         "ghostty-internal.so")))
        ;; It is a runtime Portal can use as it is.
        (let ((portal-build-directory runtime))
          (should-not (portal-build-problem))))
      ;; Again, with no server to reach.
      (should (string-match-p "already in" (portal-runtime-test--install "https://127.0.0.1:1/")))
      (should (equal (portal-runtime-test--runtimes) (list identity))))))

(ert-deftest portal-runtime-a-lisp-only-release-downloads-nothing ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (let ((identity (portal-runtime-test--release)))
      (portal-runtime-test--install)
      (portal-runtime-test--requests)
      ;; The next tag changed only Lisp: same identity, nothing fetched.
      (portal-runtime-test--version "1.2.4")
      (should (equal (portal-runtime-test--release) identity))
      (should (string-match-p "already in" (portal-runtime-test--install)))
      (should-not (portal-runtime-test--requests))
      (should (equal (portal-runtime-test--runtimes) (list identity))))))

(ert-deftest portal-runtime-keeps-the-runtime-it-replaced ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (let (identities)
      (dolist (version '("1.2.3" "1.2.4" "1.2.5"))
        (portal-runtime-test--version version)
        (portal-runtime-test--native-change version)
        (push (portal-runtime-test--release) identities)
        (portal-runtime-test--install)
        (should (equal (portal-runtime-test--current) (car identities)))
        (should (equal (portal-runtime-test--runtimes)
                       (sort (seq-take identities 2) #'string<))))
      ;; Going back to the one it replaced reuses it, and keeps the newer.
      (portal-runtime-test--version "1.2.4")
      (portal-runtime-test--native-change "1.2.4")
      (should (string-match-p "already in" (portal-runtime-test--install)))
      (should (equal (portal-runtime-test--current) (nth 1 identities)))
      (should (equal (portal-runtime-test--runtimes) (sort (seq-take identities 2) #'string<)))
      (should-not (seq-filter (lambda (entry) (string-match-p "\\`\\(?:staging\\|trash\\)-"
                                                             (car entry)))
                              (portal-runtime-test--cache))))))

(ert-deftest portal-runtime-finishes-an-interrupted-activation ()
  ;; With A then B installed, installing C is cut short as it records C as
  ;; current, or as it prunes.  Either way the next install, even a reuse,
  ;; leaves the right two: B and A after going back to B, C and B after
  ;; taking up C again.
  (skip-unless (portal-runtime-test--can-install))
  (pcase-dolist (`(,stop ,back ,current ,kept)
                 '((record "1.2.4" 1 (1 2)) (pruning "1.2.5" 0 (0 1))))
    (ert-info ((symbol-name stop))
      (portal-runtime-test--with-world
        (let (identities)
          (dolist (version '("1.2.3" "1.2.4" "1.2.5"))
            (portal-runtime-test--version version)
            (portal-runtime-test--native-change version)
            (push (portal-runtime-test--release) identities)
            (if (equal version "1.2.5")
                (cl-letf* ((rename (symbol-function 'rename-file))
                           ((symbol-function 'rename-file)
                            (lambda (file newname &rest rest)
                              (if (and (eq stop 'record)
                                       (string-suffix-p "/active.eld" newname))
                                  (error "Interrupted")
                                (apply rename file newname rest))))
                           ((symbol-function 'portal-runtime--delete)
                            (lambda (&rest _) (error "Interrupted"))))
                  (should-error (portal-runtime-test--install)))
              (portal-runtime-test--install)))
          ;; identities is C, B, A.
          (should (= 3 (length (portal-runtime-test--runtimes))))
          (portal-runtime-test--version back)
          (portal-runtime-test--native-change back)
          (should (string-match-p "already in"
                                  (portal-runtime-test--install "https://127.0.0.1:1/")))
          (should (equal (portal-runtime-test--current) (nth current identities)))
          (should (equal (portal-runtime-test--runtimes)
                         (sort (mapcar (lambda (n) (nth n identities)) kept)
                               #'string<))))))))

(ert-deftest portal-runtime-a-slow-download-is-not-a-stalled-one ()
  ;; Half the archive in tiny chunks, whose framing decoding removes, then
  ;; the rest slowly but never idle for as long as the limit allows.
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (portal-runtime-test--release)
    (let ((portal-runtime--idle-timeout 2))
      (should (string-match-p "is installed"
                              (portal-runtime-test--install
                               (concat (portal-runtime-test--serve) "burst/")))))))

(ert-deftest portal-runtime-follows-redirects-over-https-only ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (portal-runtime-test--release)
    (let ((site (portal-runtime-test--serve)))
      ;; As GitHub redirects a release asset to its storage.
      ;; In chunks of 4 bytes, the framing outgrows the archive, which is
      ;; still within the manifest's size.
      (dolist (way '("redirect" "relative-redirect" "chunked" "tiny-chunks"))
        (should (portal-runtime-test--install (concat site way "/")))
        (delete-directory (portal-runtime--target-directory) t))
      (portal-runtime-test--requests)
      (portal-runtime-test--refused "refuses to follow a redirect to http://127\\.0\\.0\\.1"
                                    (concat site "plain-redirect/"))
      (should (equal (portal-runtime-test--requests)
                     (list (car (portal-runtime-test--paths "/plain-redirect/v1.2.3/"))))))))

(ert-deftest portal-runtime-refuses-certificates-it-cannot-verify ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (portal-runtime-test--release)
    (portal-runtime-test--install)
    (portal-runtime-test--version "1.2.4")
    (portal-runtime-test--native-change "1.2.4")
    (portal-runtime-test--release)
    ;; GnuTLS refuses the first two; it accepts the third, which Emacs's
    ;; Network Security Manager would ask a user about.
    (pcase-dolist (`(,certificate . ,pattern)
                   '((untrusted . "Certificate validation failed")
                     (other-name . "The x509 certificate does not match")
                     (same-name . "Emacs.s Network Security Manager refused")))
      (let ((site (portal-runtime-test--serve certificate))
            asked)
        ;; As if a user sat at an interactive Emacs that would accept the
        ;; certificate for good: no one is asked.
        (cl-letf (((symbol-function 'nsm-query-user)
                   (lambda (&rest _) (setq asked t) "always")))
          (let ((noninteractive nil) (gnutls-verify-error nil))
            (ert-info ((symbol-name certificate))
              (portal-runtime-test--refused
               (concat "Cannot reach 127\\.0\\.0\\.1 securely: " pattern) site))))
        (should-not asked)
        (should-not (portal-runtime-test--requests certificate))))
    ;; Without the run's authority, the trusted server's certificate fails too.
    (let ((site (portal-runtime-test--serve)))
      (setq gnutls-trustfiles nil)
      (portal-runtime-test--refused "Certificate" site))))

(ert-deftest portal-runtime-refuses-a-damaged-download ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (portal-runtime-test--release)
    (portal-runtime-test--install)
    (portal-runtime-test--version "1.2.4")
    (portal-runtime-test--native-change "1.2.4")
    (portal-runtime-test--release)
    (let* ((site (portal-runtime-test--serve))
           (manifest (portal-runtime-test--manifest))
           (good (with-temp-buffer (insert-file-contents manifest) (buffer-string)))
           (edit (lambda (key value)
                   (with-temp-file manifest
                     (insert good)
                     (goto-char (point-min))
                     (re-search-forward (format "\"%s\": \\([^,\n]+\\)" key))
                     (replace-match value t t nil 1)))))
      (portal-runtime-test--refused "cut short" (concat site "truncate/"))
      (funcall edit "sha256" (format "%S" (make-string 64 ?0)))
      (portal-runtime-test--refused "has SHA-256 [0-9a-f]+, not the manifest.s 0000")
      (funcall edit "size" "100")
      (portal-runtime-test--refused "more than the 100 expected")
      (funcall edit "size" "99999999")
      (portal-runtime-test--refused "cut short\\|bytes, not the manifest.s 99999999")
      (with-temp-file manifest (insert good))
      (should (portal-runtime-test--install)))))

(ert-deftest portal-runtime-refuses-other-native-sources ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (portal-runtime-test--release)
    (portal-runtime-test--install)
    (portal-runtime-test--requests)
    ;; A checkout past its release, with native changes: the tag's runtime
    ;; is not for it, and the archive is never fetched.
    (portal-runtime-test--native-change "unreleased")
    (portal-runtime-test--refused "built from other native sources than these.*M-x portal-build")
    (should (equal (portal-runtime-test--requests)
                   (list (car (portal-runtime-test--paths "/v1.2.3/")))))
    ;; An archive whose own record is of other sources than its manifest's.
    (portal-runtime-test--version "1.2.4")
    (portal-runtime-test--release)
    (portal-runtime-test--vary "record")
    (portal-runtime-test--refused "build record has identity 0000")))

(ert-deftest portal-runtime-refuses-unsafe-archives ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (portal-runtime-test--release)
    (portal-runtime-test--install)
    (portal-runtime-test--version "1.2.4")
    (portal-runtime-test--native-change "1.2.4")
    (portal-runtime-test--release)
    (let ((site (portal-runtime-test--serve)))
      (pcase-dolist (`(,kind . ,pattern)
                     `(("parent" . "not a plain path")
                       ("absolute" . "not a plain path")
                       ("foreign" . "extra, which is not of the runtime")
                       ("duplicate" . "licenses/LICENSE twice")
                       ("link-out" . "links licenses/out to \\.\\./\\.\\./\\.\\./outside, outside")
                       ("link-absolute" . "links licenses/out to /etc, outside")
                       ("reenter" . "links licenses/again to \\.\\./\\.\\./runtime/licenses/LICENSE, outside")
                       ("reenter-through-link" . "links licenses/sub/again to up/.*, outside")
                       ("through-link" . "licenses/via")
                       ("hardlink" . "licenses/hard, which is neither")
                       ("fifo" . "licenses/fifo, which is neither")
                       ("beside" . "ghostty-linux/include/ghostty\\.h, which is not of the runtime")
                       ("missing" . ,(if (eq system-type 'darwin)
                                         "holds licenses, portal-build.eld, portal.bundle, not"
                                       "holds ghostty-linux, licenses, portal-build.eld, not"))))
        (portal-runtime-test--vary kind)
        (ert-info (kind)
          (portal-runtime-test--refused pattern site)))
      ;; Nothing landed beside the cache or the world.
      (should-not (directory-files-recursively portal-runtime-test--world
                                               "\\`\\(?:escaped\\|outside\\)\\'"))
      (should-not (file-exists-p "/tmp/portal-runtime-escaped")))))

(ert-deftest portal-runtime-refuses-a-runtime-that-fails-its-probe ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (portal-runtime-test--release)
    (portal-runtime-test--install)
    (portal-runtime-test--version "1.2.4")
    (portal-runtime-test--native-change "1.2.4")
    (portal-runtime-test--release "not a module")
    (portal-runtime-test--refused "failed its check in a separate Emacs")))

(ert-deftest portal-runtime-interrupted-and-concurrent-installs-leave-the-old-one ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (cl-letf* (;; Batch Emacs's frame is a text terminal, which Linux refuses.
               ((symbol-function 'portal-runtime--display-problem) #'ignore)
               (old (portal-runtime-test--release))
               (outcomes nil))
      (setq portal-runtime--releases (portal-runtime-test--serve))
      ;; Through the batch Emacs and its lock, as a user's install runs.
      (portal-runtime-test--wait
       (portal-runtime-install (lambda (ok text) (push (list ok text) outcomes))))
      (should (car (pop outcomes)))
      (portal-runtime-test--requests)
      (portal-runtime-test--version "1.2.4")
      (portal-runtime-test--native-change "1.2.4")
      (portal-runtime-test--release)
      (let ((before (portal-runtime-test--cache))
            (stalled (progn
                       (setq portal-runtime--releases (concat (portal-runtime-test--serve) "stall/"))
                       (portal-runtime-install (lambda (ok text) (push (list ok text) outcomes)))))
            (deadline (+ (float-time) 60)))
        ;; Wait until it is downloading the archive, then start another.
        (while (not (seq-find (lambda (path) (string-suffix-p ".tar.gz" path))
                              (process-get (cdr (assq 'trusted portal-runtime-test--servers))
                                           'paths)))
          (when (> (float-time) deadline) (error "The install never fetched the archive"))
          (accept-process-output nil 0.1))
        (let ((portal-runtime--process nil))
          (portal-runtime-test--wait
           (portal-runtime-install (lambda (ok text) (push (list ok text) outcomes)))))
        (should (equal (pop outcomes)
                       '(nil "Another Portal runtime install is running: retry when it finishes")))
        ;; Interrupt the first mid-download.
        (kill-process stalled)
        (portal-runtime-test--wait stalled)
        (should (equal (pop outcomes) '(nil "Portal's runtime install was interrupted")))
        (should (equal (seq-remove (lambda (entry) (string-prefix-p "staging-" (car entry)))
                                   (portal-runtime-test--cache))
                       before))
        (should (equal (portal-runtime-test--current) old)))
      ;; The next install clears what the interrupted one left.
      (setq portal-runtime--releases (portal-runtime-test--serve))
      (portal-runtime-test--wait
       (portal-runtime-install (lambda (ok text) (push (list ok text) outcomes))))
      (should (car (pop outcomes)))
      (should-not (equal (portal-runtime-test--current) old))
      (should (= 2 (length (portal-runtime-test--runtimes))))
      (should-not (seq-find (lambda (entry) (string-prefix-p "staging-" (car entry)))
                            (portal-runtime-test--cache))))))

(ert-deftest portal-runtime-installs-the-real-build ()
  ;; The build CTest runs in, packed as Checks packs it, served, downloaded
  ;; and loaded in a disposable Emacs: its own module and host.
  :tags '(:expensive)
  (let ((build (getenv "PORTAL_TEST_BUILD")))
    (skip-unless (and build (portal-runtime-test--can-install)
                      (let ((portal-build-directory build)) (not (portal-build-problem)))))
    (portal-runtime-test--with-world
      (let* ((portal-build-root portal-runtime-test--checkout)
             (tag (concat "v" (portal-build-version))))
        (portal-runtime-test--run (expand-file-name "scripts/runtime-archive.py"
                                                    portal-build-root)
                                  "pack" "--tag" tag "--target" (portal-runtime--target)
                                  "--commit" "0123456789abcdef0123456789abcdef01234567"
                                  build (portal-runtime-test--file (concat "site/" tag)))
        (should (string-match-p "is installed" (portal-runtime-test--install)))
        (let ((portal-build-directory (portal-runtime-installed)))
          (should-not (portal-build-problem)))
        ;; The same files, modes and links as the reference extraction,
        ;; runtime-archive.py's own.  Not its unpack, which also audits the
        ;; binaries as Checks does when it packs: a developer's Linux build,
        ;; not built for the release's floor, fails that.
        (let ((unpacked (portal-runtime-test--file "unpacked"))
              (manifest (portal-runtime-test--manifest)))
          (make-directory unpacked)
          (portal-runtime-test--run
           "-c" "import runpy, sys, tarfile
from pathlib import Path
script = runpy.run_path(sys.argv[1])
with tarfile.open(sys.argv[2], 'r:gz') as tar:
    script['extract'](tar, tar.getmembers(), Path(sys.argv[3]).resolve())"
           (expand-file-name "scripts/runtime-archive.py" portal-build-root)
           (expand-file-name (portal-runtime--asset (concat "v" (portal-build-version))
                                                    (portal-runtime--target) ".tar.gz")
                             (file-name-directory manifest))
           unpacked)
          (let ((listing (lambda (directory)
                           (mapcar (lambda (file)
                                     (let ((attributes (file-attributes file)))
                                       (list (file-relative-name file directory)
                                             (file-attribute-modes attributes)
                                             (file-symlink-p file)
                                             (and (not (file-symlink-p file))
                                                  (file-regular-p file)
                                                  (with-temp-buffer
                                                    (set-buffer-multibyte nil)
                                                    (insert-file-contents-literally file)
                                                    (secure-hash 'sha256 (current-buffer)))))))
                                   (directory-files-recursively directory "" t)))))
            (should (equal (funcall listing (portal-runtime-installed))
                           (funcall listing unpacked)))))))))

;;; First use: Download, Build here or Not now

(defvar portal-runtime-test--built 0 "How many builds a first use started.")
(defvar portal-runtime-test--loaded nil "The modules a first use loaded, latest first.")

(defmacro portal-runtime-test--first-use (&rest body)
  "Run BODY as the first native command would, in a graphical Emacs.
Builds and module loads are recorded in `portal-runtime-test--built' and
`portal-runtime-test--loaded', not made; a build's prerequisites are met.
Batch Emacs's frame, a text terminal, which Linux refuses, is not one.
Messages keep their quotes as typed."
  (declare (indent 0))
  `(let ((noninteractive nil) (this-command 'portal-terminal) (text-quoting-style 'grave)
         (portal-runtime-test--built 0) (portal-runtime-test--loaded nil))
     (cl-letf (((symbol-function 'portal-build) (lambda () (cl-incf portal-runtime-test--built)))
               ((symbol-function 'portal-build--check-prerequisites) #'ignore)
               ((symbol-function 'module-load)
                (lambda (file) (push file portal-runtime-test--loaded)))
               ((symbol-function 'portal-runtime--display-problem) #'ignore))
       ,@body)))

(defun portal-runtime-test--ensure (&optional answer)
  "Run `portal-build-ensure' as a native command; return its user error, or nil.
ANSWER is the key that answers the question it asks, if it may ask one;
the question, (PROMPT KEYS DESCRIPTIONS), is in `portal-runtime-test--asked'."
  (setq portal-runtime-test--asked nil)
  (cl-letf (((symbol-function 'read-multiple-choice)
             (lambda (prompt choices &rest _)
               (unless answer (ert-fail (format "Asked: %s" prompt)))
               (setq portal-runtime-test--asked
                     (list prompt (mapcar #'car choices) (mapcar #'caddr choices)))
               (or (assq answer choices) (ert-fail (format "%c not offered: %s" answer prompt))))))
    (condition-case err
        (progn (portal-build-ensure) nil)
      (user-error (cadr err)))))

(defvar portal-runtime-test--asked nil "The question the last first use asked, or nil.")

(defun portal-runtime-test--finish ()
  "Wait for the running install; return what Portal said when it ended."
  (let ((process portal-runtime--process) said)
    (should (process-live-p process))
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest arguments)
                 (when format (push (apply #'format-message format arguments) said)))))
      (portal-runtime-test--wait process))
    (should-not portal-runtime--process)
    (car said)))

(defun portal-runtime-test--reload ()
  "Forget what this Emacs found, as reloading Portal's Lisp after an upgrade does."
  (setq portal-build--ready nil portal-build--runtime nil))

(defun portal-runtime-test--no-download ()
  "Fail the test if an install starts."
  (lambda (&rest _) (ert-fail "Downloaded")))

(ert-deftest portal-runtime-first-use-offers-the-three-choices ()
  ;; With no server: Build here and Not now need none, and Download is
  ;; seen starting.
  (portal-runtime-test--with-world
    (let ((system-type 'darwin) (system-configuration "aarch64-apple-darwin25.6.0")
          downloads)
      (cl-letf (((symbol-function 'portal-runtime-install)
                 (lambda (callback) (push callback downloads) nil)))
        (portal-runtime-test--first-use
          ;; Build here: the build starts, and nothing is downloaded.
          (should (equal (portal-runtime-test--ensure ?b)
                         "Building Portal in *portal-build*: retry when it finishes"))
          (pcase-let ((`(,prompt ,keys ,descriptions) portal-runtime-test--asked))
            (should (string-match-p "\\`Portal's native module.* not built\\.  Get it now\\?\\'"
                                    prompt))
            (should (equal keys '(?d ?b ?n)))
            (should (string-search "release v1.2.3 from GitHub" (nth 0 descriptions)))
            (should (string-search "takes several minutes" (nth 1 descriptions))))
          (should (= portal-runtime-test--built 1))
          (should-not downloads)
          ;; Not now: neither, and the two commands named.
          (should (string-match-p "not built: run M-x portal-build to build it here, or \
M-x portal-download-runtime to download it\\'"
                                  (portal-runtime-test--ensure ?n)))
          (should (= portal-runtime-test--built 1))
          (should-not downloads)
          ;; Download: the install starts, with the report of its end.
          (should (equal (portal-runtime-test--ensure ?d)
                         "Downloading Portal's runtime in *portal-runtime*: retry when \
it finishes"))
          (should (equal downloads (list #'portal-runtime--report)))
          (should (= portal-runtime-test--built 1))
          ;; While it runs, nothing is asked or started again.
          (let ((portal-runtime--process (make-process :name "portal-runtime-test"
                                                       :command '("sleep" "10") :noquery t)))
            (unwind-protect
                (progn
                  (should (string-match-p "yet: retry when the download in \\*portal-runtime\\*"
                                          (portal-runtime-test--ensure)))
                  (should (string-match-p "already being downloaded"
                                          (cadr (should-error (portal-download-runtime)
                                                              :type 'user-error)))))
              (delete-process portal-runtime--process)))
          (should (= (length downloads) 1)))))))

(ert-deftest portal-runtime-first-use-follows-each-value-of-the-option ()
  (portal-runtime-test--with-world
    (let ((system-type 'darwin) (system-configuration "aarch64-apple-darwin25.6.0")
          (downloads 0))
      (cl-letf (((symbol-function 'portal-runtime-install)
                 (lambda (_callback) (cl-incf downloads) nil)))
        (portal-runtime-test--first-use
          ;; `always', as it did, and `build', its new name: a build, never a
          ;; download, and no question.
          (dolist (value '(always build))
            (let ((portal-build-on-first-use value))
              (should (string-prefix-p "Building Portal" (portal-runtime-test--ensure)))))
          (should (= portal-runtime-test--built 2))
          (should (= downloads 0))
          ;; `download': a download, never a build, and no question.
          (let ((portal-build-on-first-use 'download))
            (should (string-prefix-p "Downloading Portal's runtime" (portal-runtime-test--ensure))))
          (should (= downloads 1))
          (should (= portal-runtime-test--built 2))
          ;; `never': only the report.
          (let ((portal-build-on-first-use 'never))
            (should (string-match-p "not built: run M-x portal-build to build it here, or \
M-x portal-download-runtime" (portal-runtime-test--ensure))))
          ;; Outside a command, as from a timer: only those that need no
          ;; question go on.
          (let ((this-command nil))
            (should (string-match-p "not built: run" (portal-runtime-test--ensure)))
            (let ((portal-build-on-first-use 'download))
              (should (string-prefix-p "Downloading" (portal-runtime-test--ensure))))
            (let ((portal-build-on-first-use 'always))
              (should (string-prefix-p "Building" (portal-runtime-test--ensure)))))
          (should (= downloads 2))
          (should (= portal-runtime-test--built 3))
          ;; Batch Emacs: never, whatever the value.
          (let ((noninteractive t))
            (dolist (portal-build-on-first-use '(ask always build download never))
              (should (string-match-p "not built: run M-x portal-build"
                                      (portal-runtime-test--ensure)))))
          (should (= downloads 2))
          (should (= portal-runtime-test--built 3)))))))

(ert-deftest portal-runtime-first-use-explains-what-it-cannot-download ()
  ;; Refused before any network: offered a build, never given one.
  (portal-runtime-test--with-world
    (cl-letf (((symbol-function 'portal-runtime-install) (portal-runtime-test--no-download)))
      (portal-runtime-test--first-use
        ;; An Intel Emacs, which no runtime fits.
        (let ((system-type 'darwin) (system-configuration "x86_64-apple-darwin24.1.0"))
          (let ((portal-build-on-first-use 'download))
            (should (string-match-p "not built, and Portal cannot download it: Portal has no \
runtime to download for x86_64-apple-darwin24\\.1\\.0: build it with M-x portal-build\\'"
                                    (portal-runtime-test--ensure))))
          (should (= portal-runtime-test--built 0))
          ;; Asked, it gives the reason and offers the rest.
          (should (string-prefix-p "Building" (portal-runtime-test--ensure ?b)))
          (should (equal (nth 1 portal-runtime-test--asked) '(?b ?n)))
          (should (string-search "no runtime to download for x86_64"
                                 (car portal-runtime-test--asked)))
          (should (string-match-p "not built: run M-x portal-build\\'"
                                  (let ((portal-build-on-first-use 'never))
                                    (portal-runtime-test--ensure))))
          (should (string-match-p "no runtime to download.*\\'"
                                  (cadr (should-error (portal-download-runtime)
                                                      :type 'user-error)))))
        ;; A version that names no release.
        (let ((system-type 'darwin) (system-configuration "aarch64-apple-darwin25.6.0")
              (portal-build-on-first-use 'download))
          (portal-runtime-test--version "1.2")
          (should (string-match-p "cannot download it: Portal's version names no release to \
download a runtime from\\.  To build it here instead, run M-x portal-build\\'"
                                  (portal-runtime-test--ensure))))
        (should (= portal-runtime-test--built 1))))))

(ert-deftest portal-runtime-first-use-a-failed-download-offers-a-build ()
  ;; What only the download finds: no release, no network, or a release
  ;; of other native sources, as on main past a release that changed them.
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (portal-runtime-test--first-use
      (let ((portal-build-on-first-use 'download))
        (setq portal-runtime--releases (portal-runtime-test--serve))
        (portal-runtime-test--ensure)
        (should (string-match-p "\\`Portal's runtime was not installed: 127\\.0\\.0\\.1 answered \
404 for .*: is it released\\?  To build it here instead, run M-x portal-build\\'"
                                (portal-runtime-test--finish)))
        (setq portal-runtime--releases "https://127.0.0.1:1/")
        (portal-runtime-test--ensure)
        (should (string-match-p "\\`Portal's runtime was not installed: Cannot reach 127\\.0\\.0\\.1 \
securely: .*  To build it here instead, run M-x portal-build\\'"
                                (portal-runtime-test--finish)))
        (setq portal-runtime--releases (portal-runtime-test--serve))
        (portal-runtime-test--release)
        (portal-runtime-test--native-change "unreleased")
        (portal-runtime-test--ensure)
        (should (string-match-p "built from other native sources than these .*: build it \
with M-x portal-build\\'"
                                (portal-runtime-test--finish)))
        ;; Nothing was built, and the command asks again next time.
        (should (= portal-runtime-test--built 0))
        (should-not (portal-runtime-test--runtimes))
        (should (string-prefix-p "Downloading" (portal-runtime-test--ensure)))
        (portal-runtime-test--finish)))))

(ert-deftest portal-runtime-first-use-downloads-and-uses-the-runtime ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (let ((identity (portal-runtime-test--release)))
      (setq portal-runtime--releases (portal-runtime-test--serve))
      (portal-runtime-test--first-use
        (should (string-prefix-p "Downloading" (portal-runtime-test--ensure ?d)))
        (should (equal (portal-runtime-test--finish)
                       "Portal's runtime is installed: retry your command"))
        (should (equal (portal-runtime-test--requests) (portal-runtime-test--paths "/v1.2.3/")))
        (should (= portal-runtime-test--built 0))
        ;; The retried command goes on, from the runtime: its module and
        ;; its host, never Portal's own build directory.
        (let ((runtime (portal-runtime-installed)))
          (should-not (portal-runtime-test--ensure))
          (should (equal portal-build--runtime runtime))
          (should (equal (portal-server-program-file) (expand-file-name "portal-host" runtime)))
          (portal-build-load-module)
          (should (equal portal-runtime-test--loaded
                         (list (expand-file-name portal-build--module runtime))))
          (should (equal portal-build--loaded identity))
          (should-not (file-exists-p (portal-build-file ""))))))))

(ert-deftest portal-runtime-first-use-reuses-it-after-a-lisp-only-update ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (let ((identity (portal-runtime-test--release)))
      (portal-runtime-test--install)
      (portal-runtime-test--requests)
      (cl-letf (((symbol-function 'portal-runtime-install) (portal-runtime-test--no-download)))
        (portal-runtime-test--first-use
          (should-not (portal-runtime-test--ensure))
          (portal-build-load-module)
          ;; An upgrade that changed only Lisp: the same runtime, with no
          ;; question, no network and no restart.
          (portal-runtime-test--version "1.2.4")
          (portal-runtime-test--reload)
          (should-not (portal-runtime-test--ensure))
          (should (equal portal-build--runtime (portal-runtime-installed identity)))
          (should-not (portal-runtime-test--requests))
          ;; Portal's own build, once complete for these sources, comes first.
          (let ((build (portal-build-file "")))
            (dolist (file portal-build--artifacts)
              (portal-runtime-test--write (expand-file-name file build) ""))
            (portal-runtime-test--write (expand-file-name portal-build--record build)
                                        (prin1-to-string (list :identity identity
                                                               :version "1.2.4"))))
          (portal-runtime-test--reload)
          (should-not (portal-runtime-test--ensure))
          (should-not portal-build--runtime)
          (should (equal (portal-server-program-file) (portal-build-file "portal-host")))
          (should (= portal-runtime-test--built 0)))))))

(ert-deftest portal-runtime-first-use-asks-for-a-restart-after-a-native-change ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (let ((old (portal-runtime-test--release)))
      (setq portal-runtime--releases (portal-runtime-test--serve))
      (portal-runtime-test--install)
      (portal-runtime-test--first-use
        (should-not (portal-runtime-test--ensure))
        (portal-build-load-module)
        (should (equal portal-build--loaded old))
        ;; An upgrade to a release that changed the native sources.
        (portal-runtime-test--version "1.2.4")
        (portal-runtime-test--native-change "1.2.4")
        (let ((new (portal-runtime-test--release)))
          (portal-runtime-test--reload)
          (should (string-prefix-p "Downloading" (portal-runtime-test--ensure ?d)))
          (should (string-match-p "\\`Portal's native part is older than its sources\\."
                                  (car portal-runtime-test--asked)))
          (should (equal (portal-runtime-test--finish)
                         "Portal's runtime is installed: restart Emacs to load its new \
native module"))
          ;; The loaded module stays where it is, and is not replaced.
          (should (equal (portal-runtime-test--runtimes) (sort (list old new) #'string<)))
          (should (equal (portal-runtime-test--ensure)
                         "Portal's native module changed after Emacs loaded it: restart \
Emacs to use it"))
          ;; After the restart, the new runtime.
          (setq portal-build--loaded nil portal-runtime-test--loaded nil)
          (portal-runtime-test--reload)
          (should-not (portal-runtime-test--ensure))
          (portal-build-load-module)
          (should (equal portal-runtime-test--loaded
                         (list (expand-file-name portal-build--module
                                                 (portal-runtime-installed new)))))
          (should (= portal-runtime-test--built 0)))))))

(ert-deftest portal-runtime-first-use-leaves-a-supplied-build-alone ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (portal-runtime-test--release)
    (portal-runtime-test--install)
    (portal-runtime-test--requests)
    (let ((portal-build-directory (portal-runtime-test--file "supplied/")))
      (cl-letf (((symbol-function 'portal-runtime-install) (portal-runtime-test--no-download)))
        (portal-runtime-test--first-use
          ;; A runtime for these sources is there, and not used: the build
          ;; named is reported, with nothing asked, downloaded or built.
          (dolist (portal-build-on-first-use '(ask download build))
            (should (equal (portal-runtime-test--ensure)
                           (format "%s in %s" (portal-build--describe 'missing)
                                   portal-build-directory))))
          (should (string-match-p "`portal-build-directory'), which a download does not replace"
                                  (cadr (should-error (portal-download-runtime)
                                                      :type 'user-error))))
          ;; Even after a runtime was chosen in its place.
          (setq portal-build--runtime (portal-runtime-installed))
          (should (equal (portal-server-program-file)
                         (expand-file-name "portal-host" portal-build-directory)))
          (should (= portal-runtime-test--built 0)))))))

(provide 'portal-runtime-tests)
;;; portal-runtime-tests.el ends here
