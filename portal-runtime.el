;;; portal-runtime.el --- Download and install Portal's native runtime -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; A runtime is what a build of Portal's native part leaves for Emacs to
;; use, packed by scripts/runtime-archive.py as an archive that a release
;; attaches beside its manifest.  `portal-runtime-install' fetches the one
;; that this Portal's native sources need, checks it and keeps it in
;; `portal-runtime-directory', in a batch Emacs of its own.  Nothing here
;; runs on loading, compiling or generating autoloads.
;;
;; The runtime comes from the release tag of this Portal's version, and
;; only when that release's native identity is this checkout's: a version
;; alone, or the newest release, never decides.  Portal trusts it as it
;; trusts its Lisp, GitHub over TLS and pinned to a tag; nothing is signed.
;; So a certificate that does not verify stops the download, with no
;; question to answer, and the manifest's size and SHA-256 catch a
;; truncated or corrupted download, not an attacker.
;;
;; The cache keeps runtimes by native identity, so a release that changed
;; only Lisp finds its runtime there and downloads nothing.  A runtime is
;; unpacked into a staging directory, checked file by file, then loaded in
;; a disposable Emacs by `portal-build--probe-batch'; only then does it
;; take its identity's name, in one rename.  An install that fails or is
;; interrupted leaves every runtime there as it was.  One install runs at
;; a time, under a lock the system releases when its process ends.  A
;; successful one keeps the runtime it replaced, which a running Emacs may
;; have loaded, and deletes any older.

(require 'cl-lib)
(require 'subr-x)
(require 'portal-build)

(defvar gnutls-verify-error)
(defvar gnutls-trustfiles)
(defvar nsm-noninteractive)
(defvar nsm-settings-file)
(defvar nsm-permanent-host-settings)
(defvar nsm-temporary-host-settings)
(defvar network-security-level)
(declare-function gnutls-trustfiles "gnutls" ())
(declare-function url-generic-parse-url "url-parse" (url))
(declare-function url-type "url-parse" (cl-x))
(declare-function url-host "url-parse" (cl-x))
(declare-function url-port "url-parse" (cl-x))
(declare-function url-filename "url-parse" (cl-x))

(defcustom portal-runtime-directory
  (expand-file-name "portal/runtime/" user-emacs-directory)
  "Directory where Portal keeps the native runtimes it downloads.
It is outside the package, so upgrades and reinstalls reuse its contents.
Each system's runtimes are in a directory of their own, one per native
source identity."
  :type 'directory
  :group 'portal)

(defvar portal-runtime--releases "https://github.com/xiaoxinghu/portal/releases/download/"
  "Where Portal's release assets are: each tag's are in a directory below it.
Only an https URL is accepted.  Tests serve their own assets here.")

(defconst portal-runtime--targets
  '(("macos-arm64"
     :floor ((macos . "13.0"))
     :entries ("licenses" "portal-build.eld" "portal-host" "portal.bundle")))
  "The runtimes a release can hold, by target, as scripts/runtime-archive.py
packs them: the oldest system each claims, and the entries at its top.")

(defconst portal-runtime--manifest-limit 65536
  "The most bytes a manifest may have.")

(defconst portal-runtime--idle-timeout 60
  "Seconds a download may go without receiving anything before it fails.")

(defconst portal-runtime--probe-timeout 120
  "Seconds the disposable Emacs may take to check a runtime.")

(defconst portal-runtime--busy 75
  "The exit status of an install that found another one running.
It is what lockf(1) and `flock -E' report for a lock already held.")

(defvar portal-runtime--process nil "The running install, or nil.")

;;; Choosing the runtime

(defun portal-runtime--target ()
  "Return the target of the runtime this Emacs process can load, or nil.
It is decided by the process, not the machine: an Intel Emacs under
Rosetta has none."
  (and (eq system-type 'darwin)
       (string-match-p "\\`\\(?:aarch64\\|arm64\\)-" system-configuration)
       "macos-arm64"))

(defun portal-runtime--tag ()
  "Return the release tag of this Portal's version, or nil."
  (when-let* ((version (portal-build-version))
              ((string-match-p "\\`[0-9]+\\.[0-9]+\\.[0-9]+\\'" version)))
    (concat "v" version)))

(defun portal-runtime--asset (tag target extension)
  "Return the name of TAG's asset for TARGET with EXTENSION."
  (format "portal-runtime-%s-%s%s" tag target extension))

(defun portal-runtime--target-directory (&optional directory)
  "Return the directory in DIRECTORY that holds this system's runtimes.
DIRECTORY defaults to `portal-runtime-directory'."
  (file-name-as-directory
   (expand-file-name (portal-runtime--target)
                     (or directory portal-runtime-directory))))

(defun portal-runtime-installed (&optional identity)
  "Return the directory of the installed runtime of IDENTITY, or nil.
IDENTITY defaults to that of this Portal's native sources.  Only a runtime
that was checked and loaded in full ever has such a directory."
  (when-let* (((portal-runtime--target))
              (identity (or identity (portal-build-source-identity)))
              (directory (expand-file-name identity (portal-runtime--target-directory)))
              ((file-directory-p directory)))
    (file-name-as-directory directory)))

(defun portal-runtime--lock-command ()
  "Return the command that runs an install under the system's lock, or nil.
A lock the kernel holds for the process is released when it ends,
however it ends, so an interrupted install never leaves one behind."
  (cond ((and (eq system-type 'darwin) (executable-find "lockf"))
         (list (executable-find "lockf") "-k" "-t" "0"))
        ((executable-find "flock")
         (list (executable-find "flock") "-n" "-E" (number-to-string portal-runtime--busy)))))

(defun portal-runtime-problem ()
  "Return why Portal cannot download its runtime here, or nil when it can.
The answer needs no network: whether a release holds the runtime that
these sources need is known only by asking."
  (cond ((not (portal-runtime--target))
         (format "Portal has no runtime to download for %s: build it with M-x portal-build"
                 system-configuration))
        ((not module-file-suffix)
         "Portal needs Emacs with module support")
        ((not (portal-build-source-identity))
         (format "Portal's native sources are not in %s, so it cannot tell which \
runtime it needs" (abbreviate-file-name portal-build-root)))
        ((not (portal-runtime--tag))
         "Portal's version names no release to download a runtime from")
        ((not (and (fboundp 'gnutls-available-p) (gnutls-available-p)))
         "Portal downloads its runtime over TLS, which this Emacs was built without: \
build it with M-x portal-build")
        ((not (portal-runtime--lock-command))
         "Portal needs lockf or flock to download its runtime")))

;;; HTTPS

(defun portal-runtime--parse-url (url)
  "Return URL parsed, or signal an error unless it is an https URL."
  (require 'url-parse)
  (let ((parsed (url-generic-parse-url url)))
    (unless (and (equal (url-type parsed) "https") (url-host parsed)
                 (not (string-empty-p (url-host parsed))))
      (error "Portal downloads only over HTTPS, not from %s" url))
    parsed))

(defun portal-runtime--headers ()
  "Parse the response at the start of the current buffer.
Return (STATUS HEADERS . BODY-START), HEADERS an alist with lower-case
names, or nil while the headers are incomplete."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((end (search-forward "\r\n\r\n" nil t)))
      (goto-char (point-min))
      (unless (looking-at "HTTP/1\\.[01] \\([0-9][0-9][0-9]\\)[^\r\n]*\r\n")
        (error "The server's answer is not HTTP"))
      (let ((status (string-to-number (match-string 1))) headers)
        (goto-char (match-end 0))
        (while (looking-at "\\([^:\r\n]+\\):[ \t]*\\([^\r\n]*\\)\r\n")
          (push (cons (downcase (match-string 1)) (string-trim (match-string 2))) headers)
          (goto-char (match-end 0)))
        (cons status (cons (nreverse headers) end))))))

(defun portal-runtime--dechunk (cursor room what)
  "Decode the complete chunks from CURSOR in the current buffer, in place.
Return (CURSOR . DONE): where the decoded body now ends, and whether the
last chunk came.  A chunk not yet all received waits for the next call.
ROOM is how many more bytes the body may have; a chunk larger than that
signals an error naming WHAT, as does a malformed chunk."
  (save-excursion
    (let ((done nil) (waiting nil))
      (while (not (or done waiting))
        (goto-char cursor)
        (cond
         ((looking-at "\\([[:xdigit:]]+\\)[^\r\n]*\r\n")
          (let ((size (string-to-number (match-string 1) 16))
                (data (match-end 0)))
            (cond ((zerop size)
                   (delete-region cursor (point-max))
                   (setq done t))
                  ((> size room)
                   (error "%s is larger than expected" what))
                  ((<= (+ data size 2) (point-max))
                   (unless (equal (buffer-substring-no-properties (+ data size) (+ data size 2))
                                  "\r\n")
                     (error "The chunks of %s are malformed" what))
                   (delete-region (+ data size) (+ data size 2))
                   (delete-region cursor data)
                   (setq cursor (+ cursor size) room (- room size)))
                  (t (setq waiting t)))))
         ((looking-at "[^\n]*\n") (error "The chunks of %s are malformed" what))
         (t (setq waiting t))))
      (cons cursor done))))

(defun portal-runtime--request (url limit what)
  "GET URL over verified TLS into a new unibyte buffer and return it.
The buffer holds the whole response, a chunked body decoded.  Signal
an error, killing the
buffer, if the server sends more than LIMIT bytes of body, or nothing for
`portal-runtime--idle-timeout' seconds.  WHAT names the download."
  (require 'gnutls)
  (require 'nsm)
  (let* ((parsed (portal-runtime--parse-url url))
         (host (url-host parsed))
         (port (url-port parsed))
         (path (let ((path (url-filename parsed)))
                 (if (string-empty-p path) "/" path)))
         (buffer (generate-new-buffer " *portal-runtime-download*" t))
         ;; Verify the certificate and the host name in GnuTLS, which fails
         ;; the connection, so the Network Security Manager never asks
         ;; whether to continue; and refuse whatever it would ask about.
         ;; Exceptions the user once accepted do not apply.
         (gnutls-verify-error t)
         (nsm-noninteractive t)
         (network-security-level (if (eq network-security-level 'low)
                                     'medium network-security-level))
         (nsm-settings-file (expand-file-name (make-temp-name "portal-no-nsm-settings-")
                                              temporary-file-directory))
         (nsm-permanent-host-settings nil)
         (nsm-temporary-host-settings nil)
         ;; A failed handshake kills its process buffer; do not ask about it.
         (kill-buffer-query-functions nil)
         (read-process-output-max (* 1024 1024))
         (done nil) process)
    (with-current-buffer buffer (set-buffer-multibyte nil))
    (unwind-protect
        (progn
          (setq process
                (condition-case err
                    (open-network-stream "portal-runtime-download" buffer host port
                                         :type 'tls :coding 'binary)
                  (error (error "Cannot reach %s securely: %s" host
                                (error-message-string err)))))
          ;; What GnuTLS accepted, the Network Security Manager may still
          ;; refuse: it then closes the connection and returns nothing.
          (unless process
            (error "Cannot reach %s securely: Emacs's Network Security Manager \
refused its certificate or connection" host))
          (set-process-query-on-exit-flag process nil)
          ;; The default sentinel would write the connection's end into the body.
          (set-process-sentinel process #'ignore)
          (process-send-string
           process
           (concat "GET " path " HTTP/1.1\r\n"
                   "Host: " host (if (eql port 443) "" (format ":%d" port)) "\r\n"
                   "User-Agent: portal-runtime\r\n"
                   "Accept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"))
          ;; A chunked body is decoded as it arrives, so that LIMIT bounds
          ;; the body's bytes, not the chunks' framing.  CHUNKS is then the
          ;; place where the decoded body ends, and LAST whether the last
          ;; chunk came.
          (let ((received 0) (heard (float-time)) (reported (float-time))
                headers chunks last)
            (cl-flet ((step ()
                        (with-current-buffer buffer
                          (unless headers
                            (setq headers (portal-runtime--headers))
                            (when-let* ((length (cdr (assoc "content-length" (cadr headers))))
                                        ((= (car headers) 200))
                                        ((> (string-to-number length) limit)))
                              (error "%s has %s bytes, more than the %d expected"
                                     what length limit))
                            (when (and headers (= (car headers) 200)
                                       (string-match-p "chunked"
                                                       (or (cdr (assoc "transfer-encoding"
                                                                       (cadr headers)))
                                                           "")))
                              (setq chunks (cddr headers))))
                          (when (and chunks (not last))
                            (let ((decoded (portal-runtime--dechunk
                                            chunks (- limit (- chunks (cddr headers))) what)))
                              (setq chunks (car decoded) last (cdr decoded))))
                          ;; What is not yet decoded is at most the chunk
                          ;; that is arriving, which fits in what is left.
                          (when (> (- (point-max) (or chunks (if headers (cddr headers) 1)))
                                   (+ (- limit (if chunks (- chunks (cddr headers)) 0)) 65536))
                            (error "%s is larger than the %d bytes expected" what limit)))))
              (while (process-live-p process)
                (accept-process-output process 1)
                (let ((size (buffer-size buffer)) (now (float-time)))
                  (if (> size received)
                      (setq received size heard now)
                    (when (> (- now heard) portal-runtime--idle-timeout)
                      (error "The download of %s from %s stopped" what host)))
                  (step)
                  (when (and headers (> (- now reported) 5) (> limit 1048576))
                    (setq reported now)
                    (message "Downloaded %.1f of %.1f MB of %s"
                             (/ (- (or chunks size) (cddr headers)) 1048576.0)
                             (/ limit 1048576.0) what))))
              (step))
            (when (and chunks (not last))
              (error "The download of %s was cut short" what))
            ;; What follows the last chunk: trailers, which Portal ignores.
            (when last
              (with-current-buffer buffer (delete-region chunks (point-max)))))
          (setq done t)
          buffer)
      (when (processp process) (delete-process process))
      (unless done (kill-buffer buffer)))))

(defun portal-runtime--fetch (url limit what)
  "Return a unibyte buffer holding the body of URL, following redirects.
Every place is fetched over HTTPS with its certificate verified.  Signal
an error, saying why, unless the final answer is 200 with at most LIMIT
bytes, all of them received.  WHAT names the download in messages."
  (let ((redirects 0) (buffer nil))
    (while (not buffer)
      (let* ((response (portal-runtime--request url limit what))
             (parsed (with-current-buffer response (portal-runtime--headers)))
             (status (car parsed))
             (headers (cadr parsed)))
        (unless parsed
          (kill-buffer response)
          (error "The download of %s was cut short" what))
        (cond
         ((memq status '(301 302 303 307 308))
          (kill-buffer response)
          (let ((location (cdr (assoc "location" headers))))
            (unless location
              (error "%s redirected the download of %s nowhere" url what))
            (when (string-prefix-p "//" location)
              (setq location (concat "https:" location)))
            (when (string-prefix-p "/" location)
              (let ((here (portal-runtime--parse-url url)))
                (setq location (format "https://%s%s%s" (url-host here)
                                       (if (eql (url-port here) 443) ""
                                         (format ":%d" (url-port here)))
                                       location))))
            (unless (string-prefix-p "https://" location)
              (error "Portal refuses to follow a redirect to %s: it downloads only over HTTPS"
                     location))
            (when (> (setq redirects (1+ redirects)) 5)
              (error "The download of %s redirects too often" what))
            (setq url location)))
         ((/= status 200)
          (kill-buffer response)
          (error "%s answered %d for %s" (url-host (portal-runtime--parse-url url)) status
                 (if (= status 404) (format "%s: is it released?" url) url)))
         (t
          (with-current-buffer response
            (let ((start (cddr parsed))
                  (length (cdr (assoc "content-length" headers))))
              (condition-case err
                  (progn
                    ;; A chunked body was decoded as it arrived.
                    (delete-region (point-min) start)
                    (when (and length (/= (buffer-size) (string-to-number length)))
                      (error "The download of %s was cut short: %d of %s bytes"
                             what (buffer-size) length))
                    (when (> (buffer-size) limit)
                      (error "%s is larger than the %d bytes expected" what limit)))
                (error (kill-buffer response)
                       (signal (car err) (cdr err))))))
          (setq buffer response)))))
    buffer))

;;; Manifests

(defun portal-runtime--manifest (buffer tag target)
  "Return the entry for TARGET of the manifest in BUFFER, checked for TAG.
The manifest is as scripts/runtime-archive.py's `check_manifest' defines
it.  The entry is an alist with the manifest's identity and version added.
Signal an error saying what is wrong."
  (let* ((manifest (condition-case nil
                       (with-current-buffer buffer
                         (goto-char (point-min))
                         (json-parse-buffer :object-type 'alist :array-type 'list
                                            :null-object nil :false-object nil))
                     (error (error "The manifest of %s is not JSON" tag))))
         (need (lambda (condition what)
                 (unless condition (error "The manifest of %s %s" tag what))))
         (hex (lambda (value digits)
                (and (stringp value)
                     (string-match-p (format "\\`[0-9a-f]\\{%d\\}\\'" digits) value)))))
    (funcall need (consp manifest) "is not an object")
    (funcall need (equal (sort (mapcar (lambda (pair) (symbol-name (car pair))) manifest)
                               #'string<)
                         '("archives" "commit" "format" "identity" "tag" "version"))
             "has other keys than format, tag, version, commit, identity and archives")
    (funcall need (eql (alist-get 'format manifest) 1) "is not of format 1")
    (funcall need (equal (alist-get 'tag manifest) tag) (format "is not for %s" tag))
    (funcall need (equal (concat "v" (alist-get 'version manifest)) tag)
             (format "has another version than %s" tag))
    (funcall need (funcall hex (alist-get 'commit manifest) 40) "has no commit")
    (funcall need (funcall hex (alist-get 'identity manifest) 64) "has no native identity")
    (let* ((archives (alist-get 'archives manifest))
           (ours (and (listp archives)
                      (seq-filter (lambda (archive)
                                    (and (consp archive)
                                         (equal (alist-get 'target archive) target)))
                                  archives)))
           (entry (car ours)))
      (funcall need ours (format "lists no runtime for %s" target))
      (funcall need (null (cdr ours)) (format "lists %s twice" target))
      (funcall need (equal (sort (mapcar (lambda (pair) (symbol-name (car pair))) entry)
                                 #'string<)
                           '("floor" "name" "sha256" "size" "target"))
               "has an archive without exactly target, floor, name, size and sha256")
      (funcall need (equal (alist-get 'floor entry)
                           (plist-get (cdr (assoc target portal-runtime--targets)) :floor))
               (format "claims another oldest system for %s" target))
      (funcall need (equal (alist-get 'name entry) (portal-runtime--asset tag target ".tar.gz"))
               (format "names another archive for %s" target))
      (funcall need (and (natnump (alist-get 'size entry)) (> (alist-get 'size entry) 0))
               "gives the archive no size")
      (funcall need (funcall hex (alist-get 'sha256 entry) 64) "gives the archive no SHA-256")
      (append `((identity . ,(alist-get 'identity manifest))
                (version . ,(alist-get 'version manifest)))
              entry))))

;;; Unpacking

(defun portal-runtime--octal (start length what)
  "Return the octal number in the LENGTH bytes at START, part of WHAT's header."
  (let ((text (string-trim (buffer-substring-no-properties start (+ start length))
                           "[ \0]*" "[ \0]*")))
    (unless (string-match-p "\\`[0-7]+\\'" text)
      (error "The archive's header of %s has a malformed number" what))
    (string-to-number text 8)))

(defun portal-runtime--field (start length)
  "Return the NUL-terminated field of LENGTH bytes at START."
  (let ((text (buffer-substring-no-properties start (+ start length))))
    (substring text 0 (string-search "\0" text))))

(defun portal-runtime--pax (start size)
  "Return the pax records in the SIZE bytes at START, as an alist."
  (let ((end (+ start size)) records)
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (unless (looking-at "\\([0-9]+\\) \\([^=\n]+\\)=")
          (error "The archive has a malformed extended header"))
        (let* ((record-end (+ (point) (string-to-number (match-string 1))))
               (key (match-string 2))
               (value (buffer-substring-no-properties (match-end 0) (1- record-end))))
          (unless (and (<= record-end end) (eq (char-before record-end) ?\n))
            (error "The archive has a malformed extended header"))
          (push (cons key value) records)
          (goto-char record-end))))
    records))

(defun portal-runtime--members ()
  "Return the members of the uncompressed tar archive in the current buffer.
Each is (NAME TYPE MODE START SIZE LINK), TYPE being `file', `directory'
or `link', START and SIZE the place of a file's contents.  Only what
scripts/runtime-archive.py writes is accepted: ustar or pax headers with
plain files, directories and symbolic links."
  (let ((position (point-min)) (pax nil) (members nil) (end nil))
    (while (not end)
      (when (> (+ position 512) (point-max))
        (error "The archive ends before its end marker"))
      (if (string-match-p "\\`\0*\\'" (buffer-substring-no-properties position (+ position 512)))
          (setq end t)
        (let* ((sum (let ((total 0))
                      (dotimes (i 512)
                        (setq total (+ total (if (<= 148 i 155) 32
                                               (char-after (+ position i))))))
                      total))
               (name (portal-runtime--field position 100))
               (flag (char-after (+ position 156)))
               (size (portal-runtime--octal (+ position 124) 12 name))
               (data (+ position 512)))
          (unless (= sum (portal-runtime--octal (+ position 148) 8 name))
            (error "The archive's header of %s is damaged" name))
          (unless (string-prefix-p "ustar" (buffer-substring-no-properties
                                            (+ position 257) (+ position 262)))
            (error "The archive is not a ustar or pax archive"))
          (let ((prefix (portal-runtime--field (+ position 345) 155)))
            (unless (string-empty-p prefix) (setq name (concat prefix "/" name))))
          (when-let* ((size-record (cdr (assoc "size" pax))))
            (unless (string-match-p "\\`[0-9]+\\'" size-record)
              (error "The archive's extended header of %s gives a malformed size" name))
            (setq size (string-to-number size-record)))
          (when (> (+ data size) (point-max))
            (error "The archive ends inside %s" name))
          (pcase flag
            (?x (when pax (error "The archive has two extended headers in a row"))
                (setq pax (portal-runtime--pax data size)))
            ((or ?0 0 ?5 ?2)
             (when-let* ((path (cdr (assoc "path" pax)))) (setq name path))
             (let ((link (or (cdr (assoc "linkpath" pax))
                             (portal-runtime--field (+ position 157) 100)))
                   (type (pcase flag (?5 'directory) (?2 'link) (_ 'file))))
               (when (and (eq type 'directory) (string-suffix-p "/" name))
                 (setq name (substring name 0 -1)))
               (push (list name type (portal-runtime--octal (+ position 100) 8 name)
                           data (if (eq type 'file) size 0) link)
                     members))
             (setq pax nil))
            (_ (error "The archive holds %s, which is neither a file, a directory \
nor a link" (if (string-empty-p name) "an entry" name))))
          (setq position (+ data (* 512 (/ (+ size 511) 512)))))))
    (when pax (error "The archive ends after an extended header"))
    (nreverse members)))

(defun portal-runtime--check-names (members entries)
  "Signal an error unless MEMBERS have plain, unique names under ENTRIES.
A name must be printable ASCII, relative, without empty, `.' or `..'
parts, and no part may start with ~; a link's target likewise, though
it may climb with `..'.  Where each lands is judged on disk as it is
unpacked."
  (let ((seen (make-hash-table :test #'equal)))
    (pcase-dolist (`(,name ,type ,_mode ,_start ,_size ,link) members)
      (let ((parts (split-string name "/")))
        (unless (and (string-match-p "\\`[ -~]+\\'" name)
                     (not (string-match-p "\\\\" name))
                     (not (string-prefix-p "/" name))
                     (cl-notany (lambda (part) (member part '("" "." ".."))) parts)
                     (cl-notany (lambda (part) (string-prefix-p "~" part)) parts))
          (error "The archive holds %S, which is not a plain path in the runtime" name))
        (when (gethash name seen)
          (error "The archive holds %s twice" name))
        (puthash name t seen)
        (unless (member (car parts) entries)
          (error "The archive holds %s, which is not of the runtime" name))
        (when (eq type 'link)
          (unless (and (string-match-p "\\`[ -~]+\\'" link)
                       (not (string-match-p "\\\\" link))
                       (not (string-prefix-p "/" link))
                       (not (string-prefix-p "~" link))
                       (cl-notany #'string-empty-p (split-string link "/")))
            (error "The archive links %s to %s, outside the runtime" name link)))))))

(defun portal-runtime--place (root name &optional directory)
  "Return where NAME goes in ROOT, after checking the disk on the way.
Every directory above it must be a real directory, as `file-attributes'
sees it without following links, which also catches a name that the
file system takes as another, such as A and a on macOS; missing ones are
made.  Its own place must be free, unless DIRECTORY and a directory is
there."
  (let ((path root) (parts (split-string name "/")))
    (dolist (part (butlast parts))
      (setq path (concat path "/" part))
      (pcase (file-attribute-type (file-attributes path))
        ('t nil)
        ('nil (if (file-attributes path)
                  (error "The archive's %s goes through %s, which is not a directory"
                         name (string-remove-prefix (concat root "/") path))
                (make-directory path)))
        (_ (error "The archive's %s goes through %s, which is not a directory"
                  name (string-remove-prefix (concat root "/") path)))))
    (setq path (concat path "/" (car (last parts))))
    (when-let* ((attributes (file-attributes path)))
      (unless (and directory (eq (file-attribute-type attributes) t))
        (error "The archive's %s is already there, under that name or another" name)))
    path))

(defun portal-runtime--extract (members root)
  "Write MEMBERS, from the archive in the current buffer, into ROOT.
ROOT is an existing directory's true name.  Files and directories go
first and links last, so nothing is written through a link of the
archive; then each link must lead to something in ROOT.  This follows
scripts/runtime-archive.py's `extract'."
  (let ((file-name-handler-alist nil)
        (coding-system-for-write 'no-conversion)
        (write-region-annotate-functions nil)
        (write-region-post-annotation-function nil)
        (directories nil))
    (pcase-dolist (`(,name ,type ,mode ,start ,size ,_link) members)
      (pcase type
        ('directory
         (let ((path (portal-runtime--place root name t)))
           (unless (file-attributes path) (make-directory path))
           (push (cons path mode) directories)))
        ('file
         (let ((path (portal-runtime--place root name)))
           (write-region start (+ start size) path nil 'silent nil 'excl)
           (set-file-modes path (logand mode #o777) 'nofollow)))))
    (pcase-dolist (`(,name ,type ,_mode ,_start ,_size ,link) members)
      (when (eq type 'link)
        (make-symbolic-link link (portal-runtime--place root name))))
    (pcase-dolist (`(,name ,type ,_mode ,_start ,_size ,link) members)
      (when (eq type 'link)
        (let ((path (concat root "/" name)))
          (unless (and (file-exists-p path)
                       (string-prefix-p (concat root "/") (file-truename path)))
            (error "The archive links %s to %s, outside the runtime or to nothing"
                   name link)))))
    ;; Deepest first.  The owner keeps every right, so that Portal can
    ;; delete the runtime when it is no longer needed.
    (dolist (directory directories)
      (set-file-modes (car directory) (logior (logand (cdr directory) #o777) #o700)
                      'nofollow))))

(defun portal-runtime--unpack (archive directory entry target)
  "Unpack the gzipped tar ARCHIVE, a buffer, into DIRECTORY, and check it.
DIRECTORY must not exist.  ENTRY is the archive's manifest entry, with
its identity and version.  The runtime must hold TARGET's entries and
nothing else, the files of a complete build, and a record of the
manifest's identity and version."
  (let ((entries (plist-get (cdr (assoc target portal-runtime--targets)) :entries)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-buffer-substring archive)
      (let ((coding-system-for-read 'no-conversion)
            (coding-system-for-write 'no-conversion))
        (unless (eql 0 (call-process-region (point-min) (point-max) "gzip" t '(t nil) nil "-dc"))
          (error "%s is not a gzipped archive" (alist-get 'name entry))))
      (let ((members (portal-runtime--members)))
        (portal-runtime--check-names members entries)
        (make-directory directory)
        (portal-runtime--extract members (directory-file-name (file-truename directory)))))
    (let ((portal-build-directory (file-name-as-directory directory)))
      (let ((tops (sort (directory-files directory nil directory-files-no-dot-files-regexp)
                        #'string<)))
        (unless (equal tops (sort (copy-sequence entries) #'string<))
          (error "%s holds %s, not %s" (alist-get 'name entry)
                 (string-join tops ", ") (string-join entries ", "))))
      (dolist (file (append '("licenses/LICENSE" "licenses/README.md") portal-build--artifacts))
        (unless (file-exists-p (portal-build-file file))
          (error "%s lacks %s" (alist-get 'name entry) file)))
      (let ((record (portal-build--read portal-build--record)))
        (dolist (key '(identity version))
          (let ((found (plist-get record (intern (format ":%s" key)))))
            (unless (equal found (alist-get key entry))
              (error "The archive's build record has %s %s, not the manifest's %s"
                     key found (alist-get key entry))))))
      (when (and portal-build--host
                 (not (file-executable-p (portal-build-file portal-build--host))))
        (error "The archive's %s is not executable" portal-build--host)))))

;;; Checking in a disposable Emacs

(defun portal-runtime--probe (directory)
  "Signal an error unless the runtime in DIRECTORY loads in a separate Emacs.
It runs `portal-build--probe-batch', which checks the runtime against
these sources, loads its module and starts its host."
  (let* ((output (generate-new-buffer " *portal-runtime-probe*" t))
         (process (make-process
                   :name "portal-runtime-probe" :buffer output :connection-type 'pipe
                   :noquery t
                   :command (list (expand-file-name invocation-name invocation-directory)
                                  "--batch" "-Q" "-l"
                                  (expand-file-name "portal-build.el" portal-build-root)
                                  "-f" "portal-build--probe-batch" directory)
                   :sentinel #'ignore))
         (deadline (+ (float-time) portal-runtime--probe-timeout)))
    (unwind-protect
        (progn
          (while (process-live-p process)
            (when (> (float-time) deadline)
              (error "The runtime's check in a separate Emacs took more than %d s"
                     portal-runtime--probe-timeout))
            (accept-process-output process 0.1))
          (unless (and (eq (process-status process) 'exit) (eql (process-exit-status process) 0))
            (error "The runtime failed its check in a separate Emacs:\n%s"
                   (with-current-buffer output (string-trim (buffer-string))))))
      (delete-process process)
      (kill-buffer output))))

;;; Installing

(defun portal-runtime--delete (directory place)
  "Delete DIRECTORY, a directory in PLACE, by first moving it aside there.
It vanishes in one step; an interrupted deletion leaves a trash
directory that the next install removes."
  (let ((trash (make-temp-name (expand-file-name "trash-" place))))
    (rename-file directory trash)
    (delete-directory trash t)))

(defun portal-runtime--link (place name target)
  "Point the link NAME in PLACE at TARGET, replacing it in one rename."
  (let ((new (expand-file-name (concat name ".new") place)))
    (when (file-symlink-p new) (delete-file new))
    (make-symbolic-link target new)
    (rename-file new (expand-file-name name place) t)))

(defun portal-runtime--activate (place identity)
  "Make IDENTITY's runtime in PLACE the current one, and prune the others.
The link `current' names it and `previous' the one it replaced, which a
running Emacs may have loaded; every other runtime is deleted.  Each link
changes in one step, and pruning runs on every activation, so one that
an interruption cut short is finished by the next, even a reuse."
  (let ((current (file-symlink-p (expand-file-name "current" place))))
    (unless (equal current identity)
      (when current (portal-runtime--link place "previous" current))
      (portal-runtime--link place "current" identity))
    (let ((previous (file-symlink-p (expand-file-name "previous" place))))
      (dolist (name (directory-files place nil "\\`[0-9a-f]\\{64\\}\\'"))
        (unless (member name (list identity previous))
          (portal-runtime--delete (expand-file-name name place) place))))))

(defun portal-runtime--install (options)
  "Install the runtime that this Portal's native sources need, and return a report.
Run only in a batch Emacs that holds the install lock.  OPTIONS is a
plist: :directory, the cache, `portal-runtime-directory' by default;
:releases, `portal-runtime--releases' by default; :trustfiles, the
certificate authorities to trust as well as the system's."
  (require 'gnutls)
  (let* ((target (or (portal-runtime--target)
                     (error "Portal has no runtime to download for %s" system-configuration)))
         (identity (or (portal-build-source-identity)
                       (error "Portal's native sources are not in %s" portal-build-root)))
         (tag (or (portal-runtime--tag)
                  (error "Portal's version names no release")))
         (place (portal-runtime--target-directory (plist-get options :directory)))
         (releases (or (plist-get options :releases) portal-runtime--releases))
         (gnutls-trustfiles (or (plist-get options :trustfiles) gnutls-trustfiles))
         (final (expand-file-name identity place)))
    (make-directory place t)
    ;; What an interrupted install left: no other install runs now.
    (dolist (name (directory-files place nil "\\`\\(?:staging\\|trash\\)-\\|\\`[a-z]+\\.new\\'"))
      (let ((path (expand-file-name name place)))
        (if (eq (file-attribute-type (file-attributes path)) t)
            (delete-directory path t)
          (delete-file path))))
    (if (file-directory-p final)
        (progn
          (portal-runtime--activate place identity)
          (format "Portal's runtime for these native sources is already in %s"
                  (abbreviate-file-name (file-name-as-directory final))))
      (let* ((base (concat (string-remove-suffix "/" releases) "/" tag "/"))
             (manifest-buffer (portal-runtime--fetch
                               (concat base (portal-runtime--asset tag target ".json"))
                               portal-runtime--manifest-limit
                               (format "the manifest of %s" tag)))
             (entry (unwind-protect (portal-runtime--manifest manifest-buffer tag target)
                      (kill-buffer manifest-buffer)))
             (name (alist-get 'name entry))
             staging)
        (unless (equal (alist-get 'identity entry) identity)
          (error "The runtime of %s was built from other native sources than these \
\(identity %s, not %s): build it with M-x portal-build"
                 tag (substring (alist-get 'identity entry) 0 12) (substring identity 0 12)))
        (setq staging (make-temp-file (expand-file-name "staging-" place) t))
        (unwind-protect
            (let ((archive (portal-runtime--fetch (concat base name) (alist-get 'size entry)
                                                  name))
                  (runtime (expand-file-name "runtime" staging)))
              (unwind-protect
                  (with-current-buffer archive
                    (unless (= (buffer-size) (alist-get 'size entry))
                      (error "%s has %d bytes, not the manifest's %d"
                             name (buffer-size) (alist-get 'size entry)))
                    (let ((digest (secure-hash 'sha256 archive)))
                      (unless (equal digest (alist-get 'sha256 entry))
                        (error "%s has SHA-256 %s, not the manifest's %s"
                               name digest (alist-get 'sha256 entry))))
                    (message "Downloaded %s, %d bytes, SHA-256 %s" name (buffer-size)
                             (alist-get 'sha256 entry))
                    (portal-runtime--unpack archive runtime entry target))
                (kill-buffer archive))
              (message "Checking the runtime in a separate Emacs")
              (portal-runtime--probe runtime)
              (rename-file runtime final)
              (portal-runtime--activate place identity)
              (format "Portal's runtime of %s is installed in %s" tag
                      (abbreviate-file-name (file-name-as-directory final))))
          (when (file-directory-p staging) (delete-directory staging t)))))))

(defun portal-runtime--install-batch ()
  "Install Portal's runtime in this batch Emacs, then exit.
The argument after this function's name on the command line is the
printed plist of options of `portal-runtime--install'.  Exit 0 after
installing, 1 after a refusal, which the last line explains."
  (let ((options (car (read-from-string (pop command-line-args-left)))))
    (condition-case err
        (message "%s" (portal-runtime--install options))
      (error (message "%s" (error-message-string err))
             (kill-emacs 1)))))

(defun portal-runtime--finished (process callback)
  "Report the end of the install PROCESS and call CALLBACK with its outcome."
  (let* ((status (process-exit-status process))
         (buffer (process-buffer process))
         (last (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (car (last (split-string (string-trim (buffer-string)) "\n"))))))
         (ok (and (eq (process-status process) 'exit) (eql status 0)))
         (text (cond (ok last)
                     ((eql status portal-runtime--busy)
                      "Another Portal runtime install is running: retry when it finishes")
                     ((eq (process-status process) 'signal)
                      "Portal's runtime install was interrupted")
                     (t (format "Portal's runtime was not installed: %s" (or last "see *portal-runtime*"))))))
    (when (eq portal-runtime--process process) (setq portal-runtime--process nil))
    (message "%s" text)
    (when callback (funcall callback ok text))))

(defun portal-runtime-install (&optional callback)
  "Download and install the runtime that this Portal's native sources need.
The install runs in a batch Emacs in the background and shows its progress
in *portal-runtime*.  It uses a runtime already in `portal-runtime-directory'
with no network.  Otherwise it fetches the manifest of the release tag of
this Portal's version, over HTTPS from GitHub, and proceeds only when that
release was built from these native sources.  It checks the archive's size
and SHA-256 against the manifest, unpacks and checks it, and loads it in a
disposable Emacs before using it.  Return the install's process.
When it ends, call CALLBACK, if any, with whether it succeeded and a
sentence saying what happened.  Signal a `user-error' if it cannot start."
  (when-let* ((problem (portal-runtime-problem)))
    (user-error "%s" problem))
  (when (process-live-p portal-runtime--process)
    (user-error "Portal's runtime is already being installed: see *portal-runtime*"))
  (require 'gnutls)
  (let* ((place (portal-runtime--target-directory))
         (buffer (get-buffer-create "*portal-runtime*"))
         (options (list :directory (expand-file-name portal-runtime-directory)
                        :releases portal-runtime--releases
                        :trustfiles (gnutls-trustfiles))))
    (make-directory place t)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer)))
    (setq portal-runtime--process
          (make-process
           :name "portal-runtime" :buffer buffer :connection-type 'pipe
           :command (append (portal-runtime--lock-command)
                            (list (expand-file-name "lock" place)
                                  (expand-file-name invocation-name invocation-directory)
                                  "--batch" "-Q"
                                  "-l" (expand-file-name "portal-build.el" portal-build-root)
                                  "-l" (expand-file-name "portal-runtime.el" portal-build-root)
                                  "-f" "portal-runtime--install-batch"
                                  (prin1-to-string options)))
           :sentinel (lambda (process _event)
                       (unless (process-live-p process)
                         (portal-runtime--finished process callback)))))
    ;; Nothing reads its input: a question it asked would get no answer.
    (process-send-eof portal-runtime--process)
    portal-runtime--process))

(provide 'portal-runtime)
;;; portal-runtime.el ends here
