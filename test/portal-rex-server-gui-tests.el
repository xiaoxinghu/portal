;;; portal-rex-server-gui-tests.el --- Portal against a real Rex server -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The real-server tier, run by test/rex-server-gui.sh in graphical Emacs:
;; what the fake cannot prove, that Portal and a real Rex server understand
;; each other.  Each test starts a throwaway server of its own through
;; test/portal-real-rex.el and stops it; none touches another server.  A
;; task that builds on a real server's behaviour adds its check here.

(require 'ert)
(require 'portal-rex)
(require 'portal-real-rex)
(require 'portal-rex-parity)

(defun portal-rex-server-gui-tests--wait (done)
  "Let Emacs idle until DONE returns non-nil, and fail after 10 seconds.
Messages arrive by the module's record, as between commands."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall done)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall done))))

(defun portal-rex-server-gui-tests--new-session (server label)
  "Create a session called LABEL on SERVER with rex, and return its ID.
Its one block runs cat, without a login shell."
  (plist-get (portal-real-rex-cli server "new" label "--shell" "none" "--json" "--" "/bin/cat")
             :session_id))

(ert-deftest portal-rex-server-gui-matches-the-fake ()
  :tags '(:gui)
  ;; The same checks run against the fake in the `rex' suite.
  (portal-real-rex-with (server)
    (let ((session (portal-rex-server-gui-tests--new-session server "parity"))
          (connection (portal-rex-connect (portal-real-rex-socket server))))
      (unwind-protect
          (progn
            (portal-rex-parity-check connection)
            (portal-rex-parity-check-block
             connection session
             (with-current-buffer (car (portal-rex-buffers connection session))
               portal-rex-block-id))
            (portal-rex-parity-check-sessions connection (portal-real-rex-directory server)))
        (portal-rex-disconnect connection)))))

(ert-deftest portal-rex-server-gui-sees-a-session-made-elsewhere ()
  :tags '(:gui)
  (portal-real-rex-with (server)
    (let* (events
           (portal-rex-event-functions
            (list (lambda (_connection event) (push (plist-get event :payload) events))))
           (connection (portal-rex-connect (portal-real-rex-socket server))))
      (unwind-protect
          (progn
            (should (equal (portal-rex-connection-sessions connection) []))
            (should (equal (portal-rex-call connection "session.list") '(:sessions [])))
            ;; Another client makes a session; its event reaches an idle Emacs.
            (let* ((id (portal-rex-server-gui-tests--new-session server "elsewhere"))
                   (created
                    (lambda ()
                      (cl-find-if (lambda (event)
                                    (and (equal (plist-get event :type) "session_created")
                                         (equal (plist-get (plist-get (plist-get event :payload)
                                                                      :session)
                                                           :session_id)
                                                id)))
                                  events))))
              (portal-rex-server-gui-tests--wait created)
              (should (equal (plist-get (plist-get (plist-get (funcall created) :payload) :session)
                                        :label)
                             "elsewhere"))
              (should (equal (portal-rex-call connection "session.list")
                             `(:sessions [(:session_id ,id :label "elsewhere")])))
              ;; Disconnecting ends nothing on the server.
              (portal-rex-disconnect connection)
              (should-not (portal-rex-live-p connection))
              (should-not (portal-rex-connections))
              (should (equal (plist-get (portal-real-rex-cli server "ls" "--json") :sessions)
                             `[(:session_id ,id :label "elsewhere")]))))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(defun portal-rex-server-gui-tests--api (server method &rest payload)
  "Call METHOD with PAYLOAD on SERVER as another client, and return its result."
  (json-parse-string (portal-real-rex-cli server "api" "call" method (json-serialize payload))
                     :object-type 'plist))

(ert-deftest portal-rex-server-gui-buffers-follow-the-server ()
  :tags '(:gui)
  ;; What only a real server can show: which events it sends when another
  ;; client makes, relabels, detaches and closes blocks, and that the
  ;; buffers follow them.
  (portal-real-rex-with (server)
    (let* ((session (portal-rex-server-gui-tests--new-session server "work"))
           (connection (portal-rex-connect (portal-real-rex-socket server)))
           (names (lambda ()
                    (sort (mapcar #'buffer-name (portal-rex-buffers connection)) #'string<)))
           (named (lambda (&rest wanted)
                    (portal-rex-server-gui-tests--wait
                     (lambda () (equal (funcall names) wanted)))))
           (listed (lambda (session)
                     (mapcar (lambda (block)
                               (list (plist-get block :label) (plist-get block :placement)))
                             (plist-get (portal-rex-server-gui-tests--api
                                         server "session.list_blocks" :session_id session)
                                        :blocks)))))
      (unwind-protect
          (progn
            ;; The block the session started with, under the label the
            ;; server gave it.
            (should (equal (funcall names) '("*rex: work/shell*")))
            ;; Another client opens a window with one block.
            (let* ((made (portal-real-rex-cli server "run" "-s" "work" "--shell" "none"
                                              "--focus=false" "--label" "api" "--json"
                                              "--" "/bin/cat"))
                   (block (aref (plist-get made :block_ids) 0))
                   buffer)
              (funcall named "*rex: work/api*" "*rex: work/shell*")
              (setq buffer (portal-rex-block-buffer connection block))
              (should (equal (buffer-name buffer) "*rex: work/api*"))
              (with-current-buffer buffer
                (should (eq portal-rex-block-connection connection))
                (should (equal portal-rex-block-id block))
                (should (equal portal-rex-session-id session)))
              ;; It relabels the block in its window.
              (portal-rex-server-gui-tests--api server "session.set_block_label" :session_id session
                                                :block_id block :label "logs")
              (funcall named "*rex: work/logs*" "*rex: work/shell*")
              (should (eq (portal-rex-block-buffer connection block) buffer))
              ;; A detached block keeps its buffer.
              (portal-rex-server-gui-tests--api server "session.detach_block" :session_id session
                                                :block_id block)
              (should (equal (funcall listed session)
                             '(("shell" "placed") ("logs" "detached"))))
              (portal-rex-server-gui-tests--wait
               (lambda () (null (portal-rex-connection-lists connection))))
              (funcall named "*rex: work/logs*" "*rex: work/shell*")
              ;; Its new label sends no event: the buffer has it once
              ;; something else makes Portal ask, as renaming the session does.
              (portal-rex-server-gui-tests--api server "session.set_block_label" :session_id session
                                                :block_id block :label "hidden")
              (portal-rex-server-gui-tests--api server "session.set_label" :session_id session
                                                :label "play")
              (funcall named "*rex: play/hidden*" "*rex: play/shell*")
              (should (eq (portal-rex-block-buffer connection block) buffer))
              (should (equal (portal-rex-connection-sessions connection)
                             `[(:session_id ,session :label "play")]))
              ;; Closed, it loses its buffer.
              (portal-rex-server-gui-tests--api server "block.close" :session_id session
                                                :block_id block)
              (funcall named "*rex: play/shell*")
              (should-not (buffer-live-p buffer)))
            ;; A second session, with the same label as the first, and its
            ;; end.
            (let ((second (portal-rex-server-gui-tests--new-session server "play")))
              (funcall named "*rex: play/shell*" "*rex: play/shell*<2>")
              (should (equal (portal-rex-connection-sessions connection)
                             `[(:session_id ,session :label "play")
                               (:session_id ,second :label "play")]))
              (portal-rex-server-gui-tests--api server "session.destroy" :session_id session)
              (portal-rex-server-gui-tests--wait
               (lambda () (null (portal-rex-buffers connection session))))
              (should (equal (mapcar (lambda (buffer)
                                       (buffer-local-value 'portal-rex-session-id buffer))
                                     (portal-rex-buffers connection))
                             (list second)))
              (should (equal (portal-rex-connection-sessions connection)
                             `[(:session_id ,second :label "play")]))
              ;; Disconnecting kills the buffers and ends nothing.
              (portal-rex-disconnect connection)
              (should-not (portal-rex-buffers))
              (should (equal (funcall listed second) '(("shell" "placed"))))))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(ert-deftest portal-rex-server-gui-makes-sessions-and-terminals ()
  :tags '(:gui)
  ;; What only a real server shows: a session and terminals made from
  ;; Emacs, as rex, another client, then lists them, each terminal a
  ;; window of its own, its shell in the directory it was started in.
  (portal-real-rex-with (server)
    (let* ((connection (portal-rex-connect (portal-real-rex-socket server)))
           (directory (file-name-as-directory
                       (make-temp-file (expand-file-name "cwd-check-" (portal-real-rex-directory server))
                                       t)))
           (blocks (lambda (session)
                     (mapcar (lambda (block)
                               (list (plist-get block :label) (plist-get block :placement)
                                     (stringp (plist-get block :window_id))))
                             (plist-get (portal-real-rex-cli server "block" "ls" "-s" session "--json")
                                        :blocks)))))
      (unwind-protect
          (save-window-excursion
            (let* ((session (portal-rex-session-create connection "made"))
                   (first (portal-rex-new-terminal connection session directory))
                   (second (portal-rex-new-terminal connection session directory)))
              (should (equal (plist-get (portal-real-rex-cli server "ls" "--json") :sessions)
                             `[(:session_id ,session :label "made")]))
              (with-current-buffer first (portal-terminal-rename "api"))
              (should (equal (funcall blocks session) '(("api" "placed" t) ("shell" "placed" t))))
              (should (equal (sort (mapcar #'buffer-name (list first second)) #'string<)
                             '("*rex: made/api*" "*rex: made/shell*")))
              ;; Two windows: a tab each in Rex's app.
              (let ((listed (plist-get (portal-real-rex-cli server "block" "ls" "-s" session "--json")
                                       :blocks)))
                (should-not (equal (plist-get (aref listed 0) :window_id)
                                   (plist-get (aref listed 1) :window_id))))
              ;; The shell started in the directory.
              (let ((block (buffer-local-value 'portal-rex-block-id second)))
                (portal-rex-server-gui-tests--api server "com.superlogical.terminal.write"
                                                  :session_id session :block_id block
                                                  :args '(:data "pwd\r"))
                (portal-rex-server-gui-tests--wait
                 (lambda () (string-search (file-name-nondirectory (directory-file-name directory))
                                           (portal-rex-server-gui-tests--screen server session block)))))
              ;; Destroyed from Emacs: gone from the server, and its buffers.
              (should (portal-rex-session-destroy connection session))
              (should-not (buffer-live-p first))
              (should-not (buffer-live-p second))
              (should (equal (plist-get (portal-real-rex-cli server "ls" "--json") :sessions) []))))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(declare-function portal--terminal-text "portal-terminal" (target))
(declare-function portal--terminal-paste "portal-terminal" (target text &optional enter))
(declare-function portal-test-native-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal-test-native-focus-target "test-terminal-input" ())

(defun portal-rex-server-gui-tests--screen (server session block)
  "Return the screen and history of BLOCK in SESSION as SERVER has them, as text."
  (plist-get (portal-rex-server-gui-tests--api server "com.superlogical.terminal.format"
                                               :session_id session :block_id block
                                               :args '(:format "text"))
             :content))

(defun portal-rex-server-gui-tests--keys (&rest keys)
  "Type KEYS, each (CODE FLAGS TEXT), into the view with the keyboard."
  (dolist (key keys)
    (should (apply #'portal-test-native-key key))
    (accept-process-output nil 0.03)))

(ert-deftest portal-rex-server-gui-shows-a-block-and-types-in-it ()
  :tags '(:gui)
  ;; What only a real server shows: its first paint of a block that ran
  ;; before Emacs came, typing at its shell, and its answers to a program's
  ;; queries, which the terminal leaves to it, so the program gets one.
  (portal-real-rex-with (server)
    (let* ((session (plist-get (portal-real-rex-cli server "new" "shown" "--shell" "none" "--json"
                                                    "--" "/bin/sh")
                               :session_id))
           (connection (portal-rex-connect (portal-real-rex-socket server)))
           (buffer (car (portal-rex-buffers connection session)))
           (block (buffer-local-value 'portal-rex-block-id buffer))
           (screen (lambda () (portal-rex-server-gui-tests--screen server session block))))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            ;; Another client types into the block before Emacs shows it.
            (portal-rex-server-gui-tests--api server "com.superlogical.terminal.write"
                                              :session_id session :block_id block
                                              :args '(:data "echo before-$((6*7))\r"))
            (portal-rex-server-gui-tests--wait (lambda () (string-search "before-42" (funcall screen))))
            (switch-to-buffer buffer)
            (redisplay t)
            (let ((target portal-view--target)
                  (shows (lambda (text)
                           (portal-rex-server-gui-tests--wait
                            (lambda () (string-search text (portal--terminal-text portal-view--target)))))))
              (should target)
              (portal-rex-server-gui-tests--wait
               (lambda () (equal (plist-get (plist-get (portal--inspect target) :rex) :state) "live")))
              ;; The first paint has what the block showed, and the block has
              ;; the pane's size.
              (funcall shows "before-42")
              (let ((state (portal--inspect target))
                    (size (portal-rex-server-gui-tests--api
                           server "com.superlogical.terminal.size" :session_id session :block_id block)))
                (should (equal (list (plist-get size :columns) (plist-get size :rows))
                               (list (plist-get state :columns) (plist-get state :rows)))))
              ;; Typed in Emacs, it reaches the shell, and its output Emacs.
              (select-frame-set-input-focus (selected-frame))
              ;; Keys go to this frame by name: the VM's desktop may take
              ;; activation back from a test's Emacs at any moment.
              (should (portal-view--with-frame-title (selected-frame)
                                                     #'portal-test-native-target-frame))
              (portal-test-native-focus-target)
              (portal-terminal-focus)
              (portal-rex-server-gui-tests--keys '(14 0 "e") '(8 0 "c") '(4 0 "h") '(31 0 "o")
                                                 '(49 0 " ") '(17 0 "t") '(16 0 "y")
                                                 '(35 0 "p") '(14 0 "e") '(2 0 "d") '(36 0 "\r"))
              (portal-rex-server-gui-tests--wait
               (lambda () (string-match-p "^typed$" (funcall screen))))
              (funcall shows "\ntyped\n")
              ;; A query: the server answers it, and the terminal does not.
              (portal--terminal-paste target "printf '\\033[c'; read -r a; printf 'got:%s:\\n' \"$a\" | cat -v" t)
              (funcall shows "^[[?")
              (portal--terminal-paste target " " t)
              (portal-rex-server-gui-tests--wait
               (lambda () (string-match-p "^got:" (funcall screen))))
              (should (string-match-p "^got:\\^\\[\\[\\?[0-9;]*c:$" (funcall screen)))
              ;; vim opens and quits, and leaves nothing behind for the shell.
              (portal--terminal-paste target "vim -u NONE -N" t)
              (portal-rex-server-gui-tests--wait
               (lambda () (string-match-p "^~" (funcall screen))))
              (funcall shows "\n~")
              (portal-rex-server-gui-tests--keys '(53 0 "\e") (list 41 (ash 1 17) ":") '(12 0 "q")
                                                 (list 18 (ash 1 17) "!") '(36 0 "\r"))
              (portal--terminal-paste target "echo after-vim" t)
              (portal-rex-server-gui-tests--wait
               (lambda () (string-match-p "^after-vim$" (funcall screen))))
              (should (string-match-p "\\$ echo after-vim$" (funcall screen)))
              (funcall shows "after-vim\n")
              ;; Emacs's screen is the server's.
              (let ((ours (portal--terminal-text target)))
                (dolist (line '("before-42" "typed" "after-vim"))
                  (should (string-match-p (format "^%s$" line) ours))))))
        (portal-test-native-target-frame nil)
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(ert-deftest portal-rex-server-gui-a-blocks-details-reach-its-buffer ()
  :tags '(:gui)
  ;; What only a real server shows: the events its terminal sends as a
  ;; shell sets a title, changes directory and runs a program, reaching the
  ;; block's buffer as a terminal's details, and the block closing, and its
  ;; buffer going, when the shell exits.
  (portal-real-rex-with (server)
    (let* ((session (plist-get (portal-real-rex-cli server "new" "details" "--shell" "none" "--json"
                                                    "--" "/bin/sh")
                               :session_id))
           (connection (portal-rex-connect (portal-real-rex-socket server)))
           (buffer (car (portal-rex-buffers connection session)))
           (here (file-name-as-directory (file-truename (portal-real-rex-directory server))))
           (fact (lambda (key) (plist-get (portal-terminal-metadata buffer) key)))
           (until (lambda (key wanted)
                    (portal-rex-server-gui-tests--wait
                     (lambda () (equal (funcall fact key) wanted)))))
           exits
           (watcher (lambda (_symbol value operation where)
                      (when (and (eq operation 'set) (eq where buffer) value)
                        (push value exits)))))
      (add-variable-watcher 'portal-terminal--exited watcher)
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer buffer)
            (redisplay t)
            (let ((target portal-view--target)
                  (type (lambda (line) (portal--terminal-paste portal-view--target line t))))
              (should target)
              (portal-rex-server-gui-tests--wait
               (lambda () (equal (plist-get (plist-get (portal--inspect target) :rex) :state) "live")))
              ;; The shell, by Rex's label for it, from the first answer.
              (portal-rex-server-gui-tests--wait
               (lambda () (equal (file-name-nondirectory (or (funcall fact :program) "")) "sh")))
              ;; A title a program sets.
              (funcall type "printf '\\033]2;%s\\007' rex-title")
              (funcall until :title "rex-title")
              ;; A change of directory with no report of it: the shell's
              ;; own directory stands in.
              (funcall type (format "cd %s" (shell-quote-argument (directory-file-name here))))
              (funcall until :directory here)
              (should (equal (buffer-local-value 'default-directory buffer) here))
              (should (equal (buffer-local-value 'portal-rex-block-directory buffer)
                             (directory-file-name here)))
              ;; A directory the shell reports, as shell integration does,
              ;; wins from then on.
              (funcall type "mkdir -p 'a b' && printf '\\033]7;file://%s%s/a%%20b\\007' \"$(hostname)\" \"$PWD\"")
              (funcall until :directory (file-name-as-directory (expand-file-name "a b" here)))
              ;; A program in the foreground, and the shell after it.
              (funcall type "vim -u NONE -N")
              (portal-rex-server-gui-tests--wait
               (lambda () (equal (file-name-nondirectory (or (funcall fact :program) "")) "vim")))
              (should (string-search "vim" (portal-terminal--annotation buffer)))
              (select-frame-set-input-focus (selected-frame))
              (portal-terminal-focus)
              (portal-rex-server-gui-tests--keys '(53 0 "\e") (list 41 (ash 1 17) ":") '(12 0 "q")
                                                 (list 18 (ash 1 17) "!") '(36 0 "\r"))
              (portal-rex-server-gui-tests--wait
               (lambda () (equal (file-name-nondirectory (or (funcall fact :program) "")) "sh")))
              ;; The shell exits: the block closes and takes its buffer, which
              ;; never said the program exited.
              (funcall type "exit")
              (portal-rex-server-gui-tests--wait (lambda () (not (buffer-live-p buffer))))
              (should-not exits)
              (should-not (portal-rex-buffers connection session))))
        (remove-variable-watcher 'portal-terminal--exited watcher)
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(ert-deftest portal-rex-server-gui-killing-a-blocks-buffer-ends-it ()
  :tags '(:gui)
  ;; What only a real server shows: that its replies read as idle for a
  ;; shell at its prompt, so killing its buffer ends the block without a
  ;; question, and as busy while the shell runs a program, so it asks.
  ;; The shells are the account's, started as Portal starts a terminal,
  ;; under login.
  (portal-real-rex-with (server)
    (let* ((home (expand-file-name "home" (portal-real-rex-directory server)))
           (connection (portal-rex-connect (portal-real-rex-socket server)))
           (session (portal-rex-session-create connection "kill"))
           (state (lambda (buffer)
                    (portal-rex--block-state connection session
                                             (buffer-local-value 'portal-rex-block-id buffer))))
           (listed (lambda ()
                     (mapcar (lambda (block) (plist-get block :block_id))
                             (plist-get (portal-rex-server-gui-tests--api
                                         server "session.list_blocks" :session_id session)
                                        :blocks))))
           (prompt (lambda ()
                     (save-window-excursion
                       (let ((buffer (portal-rex-new-terminal connection session home)))
                         ;; A block that is starting reads as busy.
                         (portal-rex-server-gui-tests--wait
                          (lambda () (eq (plist-get (funcall state buffer) :state) 'idle)))
                         buffer))))
           idle busy block asked)
      ;; No startup files would start zsh's questions for a new user.
      (with-temp-file (expand-file-name ".zshrc" home) (insert "PS1='%# '\n"))
      (unwind-protect
          (progn
            (setq idle (funcall prompt))
            (portal-rex-parity-check-kill connection session
                                          (buffer-local-value 'portal-rex-block-id idle))
            ;; Its window went with it: the session has none left.
            (should-not (funcall listed))
            ;; Another, running sleep.
            (setq busy (funcall prompt)
                  block (buffer-local-value 'portal-rex-block-id busy))
            (portal-rex-server-gui-tests--api server "com.superlogical.terminal.write"
                                              :session_id session :block_id block
                                              :args '(:data "sleep 600\r"))
            (portal-rex-server-gui-tests--wait
             (lambda () (equal (funcall state busy) '(:state busy :program "sleep"))))
            ;; Asked, naming it; no keeps the buffer and the block.
            (let ((answers (list nil t))
                  (question (format "Rex block kill/%s is running sleep; end it? "
                                    (buffer-local-value 'portal-rex--block-label busy))))
              (cl-letf (((symbol-function 'y-or-n-p)
                         (lambda (prompt) (push prompt asked) (pop answers))))
                (should-not (kill-buffer busy))
                (should (buffer-live-p busy))
                (should (equal (funcall listed) (list block)))
                ;; Yes ends it.
                (should (kill-buffer busy)))
              (should (equal asked (list question question))))
            (portal-rex-server-gui-tests--wait (lambda () (null (funcall listed))))
            (should-not (portal-rex-buffers connection session)))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(provide 'portal-rex-server-gui-tests)
;;; portal-rex-server-gui-tests.el ends here
