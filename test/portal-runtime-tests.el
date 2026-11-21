;;; portal-runtime-tests.el --- Downloading and installing the native runtime -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run in batch with the package directory on `load-path'.  The tests
;; publish fixture releases from a source tree of their own, pack them with
;; scripts/runtime-archive.py and serve them over HTTPS from 127.0.0.1 with
;; test/runtime-assets.py, under a certificate authority made for the run.
;; Nothing reaches the network or the user's runtimes.  A fixture runtime's
;; module is the C core's test module, PORTAL_TEST_MODULE, so the installs
;; need it, Python 3 and openssl, and a system that has a runtime to
;; download; the checks that need no install run anywhere.

(require 'ert)
(require 'cl-lib)
(require 'gnutls)
(require 'nsm)
(require 'portal-build)
(require 'portal-runtime)

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

(defun portal-runtime-test--release (&optional module)
  "Publish a release of the source tree as it is, and return its identity.
Its runtime is built from the test module, or from MODULE, a file's
contents, and packed by scripts/runtime-archive.py under the tag of the
tree's version."
  (let* ((identity (portal-build-source-identity))
         (version (portal-build-version))
         (build (portal-runtime-test--file (format "builds/%s/" version))))
    (dolist (file portal-build--artifacts)
      (portal-runtime-test--write (expand-file-name file build) file))
    (if module
        (portal-runtime-test--write (expand-file-name portal-build--module build) module)
      (copy-file (getenv "PORTAL_TEST_MODULE") (expand-file-name portal-build--module build) t))
    (when portal-build--host
      (portal-runtime-test--write
       (expand-file-name portal-build--host build)
       "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"ready\",\"protocol\":3,\"port\":4242,\
\"token\":\"0123456789abcdef0123456789abcdef\"}'\nexec cat >/dev/null\n"
       #o755))
    (portal-runtime-test--write (expand-file-name "portal.bundle/Contents/Info.plist" build)
                                "<plist/>")
    ;; A link within the runtime, as bundles have.
    (make-symbolic-link "../Info.plist"
                        (expand-file-name "portal.bundle/Contents/Resources/Info-link" build) t)
    (dolist (file '("licenses/LICENSE" "licenses/README.md"))
      (portal-runtime-test--write (expand-file-name file build) file))
    (portal-runtime-test--write (expand-file-name portal-build--record build)
                                (prin1-to-string (list :identity identity :version version)))
    (portal-runtime-test--run (expand-file-name "scripts/runtime-archive.py"
                                                portal-runtime-test--checkout)
                              "pack" "--tag" (concat "v" version)
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
                    :stderr (get-buffer-create " *portal-runtime-assets errors*")
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
            (error "The asset server did not start"))
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
  (file-symlink-p (expand-file-name "current" (portal-runtime--target-directory))))

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
  (let ((system-type 'gnu/linux) (system-configuration "aarch64-unknown-linux-gnu"))
    (should-not (portal-runtime--target))))

(ert-deftest portal-runtime-problem-says-what-it-cannot-serve ()
  (portal-runtime-test--with-world
    (cl-letf (((symbol-function 'portal-runtime--target) (lambda () "macos-arm64")))
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
    (cl-letf (((symbol-function 'portal-runtime--target) #'ignore))
      (should (string-match-p "no runtime to download for .*M-x portal-build"
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

;;; Installing

(ert-deftest portal-runtime-installs-and-reuses-offline ()
  (skip-unless (portal-runtime-test--can-install))
  (portal-runtime-test--with-world
    (let ((identity (portal-runtime-test--release)))
      (should-not (portal-runtime-installed))
      (should (string-match-p "runtime of v1\\.2\\.3 is installed" (portal-runtime-test--install)))
      (should (equal (portal-runtime-test--requests)
                     '("/v1.2.3/portal-runtime-v1.2.3-macos-arm64.json"
                       "/v1.2.3/portal-runtime-v1.2.3-macos-arm64.tar.gz")))
      (let ((runtime (portal-runtime-installed)))
        (should (equal runtime (file-name-as-directory
                                (expand-file-name identity (portal-runtime--target-directory)))))
        (should (equal (portal-runtime-test--current) identity))
        (should (file-executable-p (expand-file-name "portal-host" runtime)))
        (should (equal (file-symlink-p (expand-file-name "portal.bundle/Contents/Resources/Info-link"
                                                         runtime))
                       "../Info.plist"))
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
  ;; Activation changes two links, then prunes.  Cut short at either
  ;; point, the next install, even a reuse, leaves two runtimes.
  (skip-unless (portal-runtime-test--can-install))
  (dolist (stop '(pruning current))
    (ert-info ((symbol-name stop))
      (portal-runtime-test--with-world
        (let (identities)
          (dolist (version '("1.2.3" "1.2.4" "1.2.5"))
            (portal-runtime-test--version version)
            (portal-runtime-test--native-change version)
            (push (portal-runtime-test--release) identities)
            (if (equal version "1.2.5")
                (cl-letf* ((link (symbol-function 'portal-runtime--link))
                           ((symbol-function 'portal-runtime--delete)
                            (lambda (&rest _) (when (eq stop 'pruning) (error "Interrupted"))))
                           ((symbol-function 'portal-runtime--link)
                            (lambda (place name target)
                              (if (and (eq stop 'current) (equal name "current"))
                                  (error "Interrupted")
                                (funcall link place name target)))))
                  (should-error (portal-runtime-test--install)))
              (portal-runtime-test--install)))
          (should (= 3 (length (portal-runtime-test--runtimes))))
          (should (portal-runtime-test--install))
          (should (equal (portal-runtime-test--current) (car identities)))
          (should (equal (portal-runtime-test--runtimes)
                         (sort (seq-take identities 2) #'string<))))))))

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
                     '("/plain-redirect/v1.2.3/portal-runtime-v1.2.3-macos-arm64.json"))))))

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
                   '("/v1.2.3/portal-runtime-v1.2.3-macos-arm64.json")))
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
                     '(("parent" . "not a plain path")
                       ("absolute" . "not a plain path")
                       ("foreign" . "extra, which is not of the runtime")
                       ("duplicate" . "licenses/LICENSE twice")
                       ("link-out" . "links licenses/out to \\.\\./\\.\\./\\.\\./outside, outside")
                       ("link-absolute" . "links licenses/out to /etc, outside")
                       ("through-link" . "licenses/via")
                       ("hardlink" . "licenses/hard, which is neither")
                       ("fifo" . "licenses/fifo, which is neither")
                       ("missing" . "holds licenses, portal-build.eld, portal.bundle, not")))
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
    (let ((old (portal-runtime-test--release))
          outcomes)
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
                                  "pack" "--tag" tag
                                  "--commit" "0123456789abcdef0123456789abcdef01234567"
                                  build (portal-runtime-test--file (concat "site/" tag)))
        (should (string-match-p "is installed" (portal-runtime-test--install)))
        (let ((portal-build-directory (portal-runtime-installed)))
          (should-not (portal-build-problem)))
        ;; The same files, modes and links as the reference unpacking.
        (let ((unpacked (portal-runtime-test--file "unpacked")))
          (portal-runtime-test--run (expand-file-name "scripts/runtime-archive.py"
                                                      portal-build-root)
                                    "unpack" (portal-runtime-test--manifest) unpacked)
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

(provide 'portal-runtime-tests)
;;; portal-runtime-tests.el ends here
