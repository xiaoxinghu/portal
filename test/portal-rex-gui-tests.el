;;; portal-rex-gui-tests.el --- Rex connections in graphical Emacs -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The seam that batch Emacs cannot show: with nobody waiting on a
;; connection, the native module tells Emacs through the notification pipe
;; that messages wait, from the main run loop, so that blocks' buffers
;; follow a server while Emacs is idle.  The server is
;; test/fake-rex-server.py on a socket of its own, never the user's Rex
;; server; test/portal-rex-tests.el covers the client's behavior in batch.

(require 'ert)
(require 'portal-rex)
(require 'portal-fake-rex)

(defun portal-rex-gui-tests--wait (done)
  "Let Emacs idle, as between commands, until DONE returns non-nil.
Nothing here asks a connection for its messages: only the module's
record can bring them."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall done)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall done))))

(defun portal-rex-gui-tests--messages (function)
  "Call FUNCTION and return what it added to *Messages*."
  (let ((start (with-current-buffer (messages-buffer) (point-max))))
    (funcall function)
    (with-current-buffer (messages-buffer)
      (buffer-substring-no-properties start (point-max)))))

(ert-deftest portal-rex-gui-commands-connect-and-disconnect ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    (let* ((portal-rex-socket (portal-fake-rex-socket server))
           (name (abbreviate-file-name portal-rex-socket)))
      (unwind-protect
          (progn
            (should (equal (portal-rex-gui-tests--messages
                            (lambda () (call-interactively #'portal-rex-connect)))
                           (format "Connected to the Rex server at %s, which has 1 session\n"
                                   name)))
            (should (equal (plist-get (portal-rex-call nil "session.list") :sessions)
                           [(:session_id "session:fake-1" :label "fake")]))
            (should (equal (portal-rex-gui-tests--messages
                            (lambda () (call-interactively #'portal-rex-connect)))
                           (format "Already connected to the Rex server at %s\n" name)))
            (should (= (length (portal-rex-connections)) 1))
            (should (equal (portal-rex-gui-tests--messages
                            (lambda () (call-interactively #'portal-rex-disconnect)))
                           (format "Disconnected from the Rex server at %s\n" name)))
            (should (equal (plist-get (portal-fake-rex-take server :disconnected) :code) 1000))
            (should-not (portal-rex-connections))
            (should-error (call-interactively #'portal-rex-disconnect) :type 'user-error))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(ert-deftest portal-rex-gui-records-bring-messages-to-an-idle-emacs ()
  :tags '(:gui)
  (portal-fake-rex-with (left right)
    (let* (seen answers
           (portal-rex-event-functions
            (list (lambda (from event)
                    (push (cons from (plist-get (plist-get event :payload) :type)) seen))))
           (first (portal-rex-connect (portal-fake-rex-socket left)))
           (second (portal-rex-connect (portal-fake-rex-socket right))))
      (unwind-protect
          (progn
            ;; Events, from two servers, each with its connection, in order.
            (portal-fake-rex-command left :event '(:type "one"))
            (portal-fake-rex-command left :event '(:type "two"))
            (portal-fake-rex-command right :event '(:type "three"))
            (portal-rex-gui-tests--wait (lambda () (= (length seen) 3)))
            (should (equal (mapcar #'cdr (cl-remove second (reverse seen) :key #'car))
                           '("one" "two")))
            (should (equal (cl-remove first seen :key #'car) (list (cons second "three"))))
            ;; A call's answer runs its callback.
            (portal-rex-call-async first "session.list" nil
                                   (lambda (result failure) (push (list result failure) answers)))
            (portal-rex-call-async first "no.such_method" nil
                                   (lambda (result failure) (push (list result failure) answers)))
            (portal-rex-gui-tests--wait (lambda () (= (length answers) 2)))
            (should (plist-get (car (nth 1 answers)) :sessions))
            (should (equal (plist-get (cadr (nth 0 answers)) :code) "method_not_found"))
            ;; A waiting call takes its answer itself; the record that
            ;; follows it finds nothing and harms nothing.
            (should (portal-rex-call second "server.version"))
            (portal-rex-gui-tests--wait (lambda () t))
            (portal-fake-rex-command right :event '(:type "four"))
            (portal-rex-gui-tests--wait (lambda () (equal (cdar seen) "four")))
            ;; A server that goes is reported once, with Emacs idle, and the
            ;; other connection carries on.
            (let ((said (portal-rex-gui-tests--messages
                         (lambda ()
                           (portal-fake-rex-command left :drop t)
                           (portal-rex-gui-tests--wait
                            (lambda () (not (portal-rex-live-p first))))
                           (portal-rex-gui-tests--wait (lambda () t))))))
              (should (equal said
                             (format "Lost the Rex server at %s: The connection to the server was lost\n"
                                     (abbreviate-file-name (portal-fake-rex-socket left))))))
            (should (equal (portal-rex-connections) (list second)))
            (should (portal-rex-call second "session.list")))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

(ert-deftest portal-rex-gui-buffers-follow-the-server-with-emacs-idle ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    (let ((portal-rex-socket (portal-fake-rex-socket server))
          (session-event
           (lambda (type &rest fields)
             (portal-fake-rex-command
              server :event (list :type "session_event"
                                  :payload (list :session_id "session:fake-1"
                                                 :event (list :type type :payload fields))))))
          (completions (lambda ()
                         (sort (all-completions "*rex: " #'internal-complete-buffer) #'string<))))
      (unwind-protect
          (save-window-excursion
            (call-interactively #'portal-rex-connect)
            ;; What C-x b completes over: one buffer for each block.
            (should (equal (funcall completions) '("*rex: fake/shell*")))
            ;; Shown, a block's buffer gets its terminal view, and its text
            ;; is the view's placard.
            (switch-to-buffer "*rex: fake/shell*")
            (redisplay t)
            (should portal-view--target)
            (should (equal (portal-view-buffers 'terminal) (list (current-buffer))))
            (should (string-prefix-p "This terminal is showing in another pane." (buffer-string)))
            ;; A block made elsewhere, renamed and closed: its buffer comes,
            ;; is renamed and goes, with nothing asking the connection.
            (portal-fake-rex-command
             server :blocks '(:session:fake-1
                              [(:block_id "block:fake-1" :label "shell" :placement "placed")
                               (:block_id "block:fake-2" :label "logs" :placement "placed")]))
            (funcall session-event "block_created" :block_id "block:fake-2")
            (portal-rex-gui-tests--wait
             (lambda () (equal (funcall completions) '("*rex: fake/logs*" "*rex: fake/shell*"))))
            (portal-fake-rex-command
             server :blocks '(:session:fake-1
                              [(:block_id "block:fake-1" :label "shell" :placement "placed")
                               (:block_id "block:fake-2" :label "build" :placement "placed")]))
            (funcall session-event "session_view_changed" :revision 2)
            (portal-rex-gui-tests--wait
             (lambda () (equal (funcall completions) '("*rex: fake/build*" "*rex: fake/shell*"))))
            ;; The buffer on show is killed under its window.
            (let ((shown (current-buffer)))
              (funcall session-event "block_closed" :block_id "block:fake-1")
              (portal-rex-gui-tests--wait (lambda () (not (buffer-live-p shown))))
              (should (buffer-live-p (window-buffer))))
            (should (equal (funcall completions) '("*rex: fake/build*")))
            ;; A session renamed, then destroyed.
            (funcall session-event "session_label_changed" :label "real")
            (portal-rex-gui-tests--wait
             (lambda () (equal (funcall completions) '("*rex: real/build*"))))
            (portal-fake-rex-command server :event '(:type "session_destroyed"
                                                     :payload (:session_id "session:fake-1")))
            (portal-rex-gui-tests--wait (lambda () (null (funcall completions))))
            (should (equal (portal-rex-connection-sessions (car (portal-rex-connections))) []))
            ;; A lost server takes its buffers.
            (portal-fake-rex-command
             server :sessions [(:session_id "session:fake-1" :label "fake")])
            (portal-fake-rex-command server :event '(:type "session_created"
                                                     :payload (:session (:session_id "session:fake-1"
                                                                         :label "fake"))))
            (portal-rex-gui-tests--wait
             (lambda () (equal (funcall completions)
                               '("*rex: fake/build*" "*rex: fake/shell*"))))
            (switch-to-buffer "*rex: fake/build*")
            (let ((inhibit-message t))
              (portal-fake-rex-command server :drop t)
              (portal-rex-gui-tests--wait (lambda () (null (portal-rex-connections)))))
            (should-not (funcall completions)))
        (mapc #'portal-rex-disconnect (portal-rex-connections))))))

;;; A block's screen

(declare-function portal--terminal-text "portal-terminal" (target))
(declare-function portal-test-native-key "test-terminal-input" (code flags text &optional windowless))
(declare-function portal-test-native-target-frame "test-terminal-input" (title))
(declare-function portal-test-native-focus-target "test-terminal-input" ())

(defun portal-rex-gui-tests--state (target)
  "The state of the block shown in TARGET, as the native module reports it."
  (plist-get (plist-get (portal--inspect target) :rex) :state))

(defun portal-rex-gui-tests--shows (target text)
  "Wait until TARGET's terminal shows TEXT, in its screen or history."
  (portal-rex-gui-tests--wait (lambda () (string-search text (portal--terminal-text target)))))

(defun portal-rex-gui-tests--none (server method &optional seconds)
  "Fail if SERVER is sent a request for METHOD within SECONDS, by default 0.3."
  (should-error (portal-fake-rex-take
                 server (lambda (report)
                          (equal (plist-get (plist-get report :request) :method) method))
                 (or seconds 0.3))))

(defun portal-rex-gui-tests--written (server)
  "The data of the next write SERVER is asked for."
  (plist-get (plist-get (portal-fake-rex-request server "com.superlogical.terminal.write")
                        :payload)
             :args))

(defun portal-rex-gui-tests--focus (focused)
  "Have Emacs gain the keyboard, when FOCUSED, or lose it to another app.
A test can neither take the keyboard from Emacs nor keep it there, as the
VM's desktop may take it back at any moment, so the frames say what they
would, and `after-focus-change-function' runs as it would.
`portal-rex-gui-tests--unfocus' ends this."
  (advice-add 'frame-focus-state :override (if focused (lambda (&rest _) t) #'ignore)
              '((name . portal-rex-gui-tests)))
  (funcall after-focus-change-function)
  (redisplay t))

(defun portal-rex-gui-tests--unfocus ()
  "Let the frames say again whether they have the keyboard."
  (advice-remove 'frame-focus-state 'portal-rex-gui-tests))

(defmacro portal-rex-gui-tests--showing (server &rest body)
  "Connect to SERVER, show its block in the selected window, and run BODY.
BODY runs with `target' bound to the block's terminal once it is live,
and the buffer current."
  (declare (indent 1))
  `(let ((portal-rex-socket (portal-fake-rex-socket ,server)))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (portal-rex-gui-tests--focus t)
           (portal-rex-connect)
           (switch-to-buffer "*rex: fake/shell*")
           (redisplay t)
           (let ((target portal-view--target))
             (should target)
             (portal-rex-gui-tests--wait
              (lambda () (equal (portal-rex-gui-tests--state target) "live")))
             ,@body))
       (portal-rex-gui-tests--unfocus)
       (mapc #'portal-rex-disconnect (portal-rex-connections)))))

(ert-deftest portal-rex-gui-shows-a-block-in-its-buffer ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    ;; The screen the block had before Emacs came, in two parts.
    (portal-fake-rex-command server :screen '(:block:fake-1 "\e[H\e[2Jbefore Emacs\r\n$ "))
    (portal-fake-rex-command server :paint_part 10)
    (portal-rex-gui-tests--showing server
      ;; The sequence: attach, claim, take it as it is in the pane in use,
      ;; size it to the pane, stream, paint.
      (should (equal (plist-get (portal-fake-rex-request server "session.attach") :payload)
                     '(:session_id "session:fake-1")))
      (should (equal (plist-get (portal-fake-rex-request server "session.own_block") :payload)
                     '(:session_id "session:fake-1" :block_ids ["block:fake-1"] :mode "request")))
      (should (equal (plist-get (portal-fake-rex-request server "session.own_block") :payload)
                     '(:session_id "session:fake-1" :block_ids ["block:fake-1"] :mode "take")))
      (let ((args (plist-get (plist-get (portal-fake-rex-request
                                         server "com.superlogical.terminal.resize")
                                        :payload)
                             :args))
            (state (portal--inspect target)))
        (should (equal (list (plist-get args :columns) (plist-get args :rows))
                       (list (plist-get state :columns) (plist-get state :rows))))
        (should (> (plist-get args :cell_width_px) 0))
        (should (equal (plist-get (plist-get state :rex) :columns) (plist-get args :columns))))
      (portal-fake-rex-request server "data.connect")
      (should (equal (plist-get (portal-fake-rex-take server :stream) :stream) "block:fake-1"))
      (let ((args (plist-get (plist-get (portal-fake-rex-request
                                         server "com.superlogical.terminal.format")
                                        :payload)
                             :args)))
        (should (equal (plist-get args :format) "vt"))
        (should (eq (plist-get args :unwrap) t))
        ;; The terminal keeps its own theme's palette.
        (should-not (plist-member args :extra_palette)))
      (portal-fake-rex-request server "com.superlogical.terminal.blob_read")
      (portal-rex-gui-tests--shows target "before Emacs")
      ;; The program's output, split anywhere, with Rex's messages cut out.
      (portal-fake-rex-command server :output "block:fake-1" :data "from the stream" :split 3)
      (portal-fake-rex-command server :rex "block:fake-1" :message '(:type "theme"))
      (portal-fake-rex-command server :output "block:fake-1" :data ", still")
      (portal-rex-gui-tests--shows target "$ from the stream, still")
      ;; A narrower pane resizes the block.
      (let ((columns (plist-get (portal--inspect target) :columns)))
        (split-window-right)
        (redisplay t)
        (let ((args (plist-get (plist-get (portal-fake-rex-request
                                           server "com.superlogical.terminal.resize")
                                          :payload)
                               :args)))
          (should (< (plist-get args :columns) columns))
          (portal-rex-gui-tests--wait
           (lambda () (equal (plist-get (plist-get (portal--inspect target) :rex) :columns)
                             (plist-get args :columns))))))
      ;; Hidden, the block's terminal stays current, and showing it again
      ;; paints nothing anew.
      (delete-other-windows)
      (switch-to-buffer (get-buffer-create "*rex-gui-elsewhere*"))
      (redisplay t)
      (should-not (plist-get (portal--inspect target) :visible))
      (portal-fake-rex-command server :output "block:fake-1" :data "\r\nwhile hidden")
      (portal-rex-gui-tests--shows target "while hidden")
      (switch-to-buffer "*rex: fake/shell*")
      (redisplay t)
      (should (equal portal-view--target target))
      (should (plist-get (portal--inspect target) :visible))
      (portal-rex-gui-tests--none server "com.superlogical.terminal.format")
      (portal-rex-gui-tests--none server "data.connect" 0.01)
      (kill-buffer "*rex-gui-elsewhere*"))))

(ert-deftest portal-rex-gui-types-in-order-and-answers-no-query ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    (portal-rex-gui-tests--showing server
      (select-frame-set-input-focus (selected-frame))
      (portal-terminal-focus)
      (should (equal (plist-get (plist-get (portal-fake-rex-request server "block.event")
                                           :payload)
                                :event)
                     '(:type "focus" :payload (:action "in"))))
      ;; One write at a time: keys typed while one is out wait, and go
      ;; together, in order.
      (portal-fake-rex-command server :hold "com.superlogical.terminal.write")
      (should (portal-test-native-key 0 0 "a"))
      (should (equal (portal-rex-gui-tests--written server) '(:data "a")))
      (should (portal-test-native-key 11 0 "b"))
      (should (portal-test-native-key 8 0 "c"))
      (should (portal-test-native-key 2 0 "d"))
      (portal-rex-gui-tests--none server "com.superlogical.terminal.write")
      (portal-fake-rex-command server :release "com.superlogical.terminal.write")
      (should (equal (portal-rex-gui-tests--written server) '(:data "bcd")))
      ;; Queries in the block's output are the server's to answer: the
      ;; terminal answers none.  The key typed after them is all it writes.
      (portal-fake-rex-command server :output "block:fake-1"
                               :data "\e[c\e[>c\e[6n\e]11;?\a\e[?2004$p queried")
      (portal-rex-gui-tests--shows target "queried")
      (should (portal-test-native-key 7 0 "x"))
      (should (equal (portal-rex-gui-tests--written server) '(:data "x")))
      ;; Its own focus report too: the block hears of focus as an event.
      (portal-fake-rex-command server :output "block:fake-1" :data "\e[?1004h")
      (portal-fake-rex-command server :output "block:fake-1" :data "focus on")
      (portal-rex-gui-tests--shows target "focus on")
      (portal-input-unfocus)
      (should (equal (plist-get (plist-get (plist-get (portal-fake-rex-request server "block.event")
                                                      :payload)
                                           :event)
                                :payload)
                     '(:action "out")))
      (portal-rex-gui-tests--none server "com.superlogical.terminal.write"))))

;;; A block's details

(defun portal-rex-gui-tests--event (server name &rest payload)
  "Have SERVER's block report the terminal event NAME with PAYLOAD."
  (portal-fake-rex-command server :block_event "block:fake-1" :name name :payload payload))

(defun portal-rex-gui-tests--fact (key)
  "The fact KEY of the current buffer's terminal, as Portal has it."
  (plist-get (portal-terminal-metadata) key))

(ert-deftest portal-rex-gui-a-blocks-details-reach-its-buffer ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    (let* ((base (file-name-as-directory (file-truename (make-temp-file "rex-gui" t))))
           (start (file-name-as-directory (expand-file-name "start" base)))
           (spaced (file-name-as-directory (expand-file-name "a b" base))))
      (make-directory start)
      (make-directory spaced)
      (unwind-protect
          (progn
            ;; What the block's terminal says before Emacs shows it.
            (portal-fake-rex-command
             server :terminal "block:fake-1" :title "before"
             :process `(:foreground (:pid 7 :name "zsh" :argv0 "-zsh"
                                     :cwd ,(directory-file-name start))
                        :last_exit :null))
            (portal-rex-gui-tests--showing server
              (let ((buffer (current-buffer)))
                ;; Asked once, as the block is claimed.
                (portal-rex-gui-tests--wait
                 (lambda () (equal (portal-rex-gui-tests--fact :title) "before")))
                (should (equal (portal-rex-gui-tests--fact :program) "zsh"))
                (should (equal (portal-rex-gui-tests--fact :directory) start))
                (should (equal default-directory start))
                (should (equal portal-rex-block-directory (directory-file-name start)))
                ;; A program sets the title, and one starts.
                (portal-rex-gui-tests--event server "title_changed" :title "vim notes.txt"
                                             :owner '(:pid 9 :name "vim"))
                (portal-rex-gui-tests--event server "process_changed" :generation 3
                                             :foreground `(:pid 9 :name "vim" :argv0 "vim"
                                                           :cwd ,(directory-file-name start)))
                (portal-rex-gui-tests--wait
                 (lambda () (equal (portal-rex-gui-tests--fact :program) "vim")))
                (should (equal (portal-rex-gui-tests--fact :title) "vim notes.txt"))
                (should (equal (substring-no-properties (portal-terminal--annotation buffer))
                               "  vim"))
                ;; The shell reports a new directory: C-x C-f starts there.
                (portal-rex-gui-tests--event
                 server "pwd_changed"
                 :pwd (concat "file://localhost"
                             (string-replace " " "%20" (directory-file-name spaced))))
                (portal-rex-gui-tests--wait (lambda () (equal default-directory spaced)))
                (should (equal (portal-rex-gui-tests--fact :directory) spaced))
                (should (equal (car (portal-terminal--context)) nil))
                (should (equal (cdr (portal-terminal--context)) spaced))
                ;; One from another machine, as from ssh inside the block,
                ;; is not this Mac's.
                (portal-rex-gui-tests--event server "pwd_changed"
                                             :pwd "file://elsewhere.example/srv")
                (portal-rex-gui-tests--event server "title_changed" :title "after ssh")
                (portal-rex-gui-tests--wait
                 (lambda () (equal (portal-rex-gui-tests--fact :title) "after ssh")))
                (should (equal default-directory spaced))
                ;; The chooser lists it, by its title and directory.
                (should (memq buffer (portal-terminal-buffers)))
                (let ((candidate (car (rassq buffer (portal-terminal--candidates
                                                     (portal-terminal-buffers))))))
                  (should (string-search "after ssh" candidate))
                  (should (string-search (abbreviate-file-name (directory-file-name spaced))
                                         candidate)))
                ;; A block made to stay after its program ends says so.
                (portal-rex-gui-tests--event server "child_exited" :exit_code 0)
                (portal-rex-gui-tests--wait (lambda () (portal-rex-gui-tests--fact :exited)))
                (should-not (portal-rex-gui-tests--fact :program))
                (should (string-search ":exited" (format-mode-line mode-line-process)))
                (should (buffer-live-p buffer)))))
        (delete-directory base t)))))

(ert-deftest portal-rex-gui-a-block-whose-program-ends-takes-its-buffer ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    (portal-rex-gui-tests--showing server
      (let* ((buffer (current-buffer))
             exits
             (watcher (lambda (_symbol value operation where)
                        (when (and (eq operation 'set) (eq where buffer) value)
                          (push value exits)))))
        (add-variable-watcher 'portal-terminal--exited watcher)
        (unwind-protect
            (let ((said
                   (portal-rex-gui-tests--messages
                    (lambda ()
                      ;; The shell exits: the server says so, ends the
                      ;; block's stream and closes the block, as a real
                      ;; one was seen to, in that order.
                      (portal-rex-gui-tests--event server "child_exited" :exit_code 0)
                      (portal-fake-rex-command server :rex "block:fake-1"
                                               :message '(:type "child_exited" :exit_code 0))
                      (portal-fake-rex-command server :end_stream "block:fake-1" :code 4000
                                               :reason "block closed")
                      (portal-fake-rex-command server :blocks '(:session:fake-1 []))
                      (portal-fake-rex-command
                       server :event '(:type "session_event"
                                       :payload (:session_id "session:fake-1"
                                                 :event (:type "block_closed"
                                                         :payload (:block_id "block:fake-1")))))
                      (portal-rex-gui-tests--wait (lambda () (not (buffer-live-p buffer))))
                      ;; Long past the moment a block that stayed would say so.
                      (let ((deadline (+ (float-time) 0.5)))
                        (while (< (float-time) deadline) (accept-process-output nil 0.05)))))))
              ;; Its buffer went with it, never having shown that the program
              ;; exited, nor that the stream ended.
              (should-not exits)
              (should-not (string-search "Rex block" said)))
          (remove-variable-watcher 'portal-terminal--exited watcher))))))

;;; Who sizes a block

(defun portal-rex-gui-tests--claims (server)
  "The modes of the claims SERVER has been sent since the last look."
  (let (modes)
    (while (when-let* ((report (ignore-errors
                                 (portal-fake-rex-take
                                  server (lambda (report)
                                           (equal (plist-get (plist-get report :request) :method)
                                                  "session.own_block"))
                                  0.3))))
             (push (plist-get (plist-get (plist-get report :request) :payload) :mode) modes)))
    (nreverse modes)))

(defun portal-rex-gui-tests--sizes (server)
  "The grids SERVER has been asked to resize the block to since the last look."
  (let (sizes)
    (while (when-let* ((report (ignore-errors
                                 (portal-fake-rex-take
                                  server (lambda (report)
                                           (equal (plist-get (plist-get report :request) :method)
                                                  "com.superlogical.terminal.resize"))
                                  0.3))))
             (let ((args (plist-get (plist-get (plist-get report :request) :payload) :args)))
               (push (list (plist-get args :columns) (plist-get args :rows)) sizes))))
    (nreverse sizes)))

(defun portal-rex-gui-tests--grid (target)
  "The block's grid, as the stream last said, and the terminal's own."
  (let ((state (portal--inspect target)))
    (list (list (plist-get (plist-get state :rex) :columns) (plist-get (plist-get state :rex) :rows))
          (list (plist-get state :columns) (plist-get state :rows)))))

(defun portal-rex-gui-tests--mark (buffer)
  "What BUFFER's mode line says after its mode's name."
  (format-mode-line (buffer-local-value 'mode-line-process buffer) nil nil buffer))

(ert-deftest portal-rex-gui-the-client-last-used-sizes-a-block ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    ;; Rex's app has the block, at its size, when Emacs comes.
    (portal-fake-rex-command server :claim "block:fake-1" :client "client:app" :name "Rex.app"
                             :columns 60 :rows 15)
    (let ((portal-rex-socket (portal-fake-rex-socket server))
          (left (selected-window)))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (setq left (selected-window))
            (switch-to-buffer (get-buffer-create "*rex-gui-elsewhere*"))
            (portal-rex-gui-tests--focus t)
            (portal-rex-connect)
            ;; Placed in a pane that is not in use: Emacs requests the
            ;; block, sends its pane's size for later, and draws the block
            ;; at the app's size, saying so.
            (let* ((right (split-window-right))
                   (buffer (get-buffer "*rex: fake/shell*"))
                   target)
              (set-window-buffer right buffer)
              (redisplay t)
              (setq target (buffer-local-value 'portal-view--target buffer))
              (should target)
              (portal-rex-gui-tests--wait
               (lambda () (equal (portal-rex-gui-tests--state target) "live")))
              (should (equal (portal-rex-gui-tests--claims server) '("request")))
              (let ((wanted (car (portal-rex-gui-tests--sizes server))))
                (should wanted)
                (should-not (equal wanted '(60 15))))
              (portal-rex-gui-tests--wait
               (lambda () (equal (portal-rex-gui-tests--grid target) '((60 15) (60 15)))))
              (portal-rex-gui-tests--wait
               (lambda () (string-search ":sized by Rex.app" (portal-rex-gui-tests--mark buffer))))
              ;; Its pane resized: the new size goes for later, and the
              ;; block stays the app's.
              (with-selected-window right (enlarge-window-horizontally 8))
              (redisplay t)
              (should (portal-rex-gui-tests--sizes server))
              (should-not (portal-rex-gui-tests--claims server))
              (should (equal (portal-rex-gui-tests--grid target) '((60 15) (60 15))))
              ;; Its pane selected: Emacs takes the block, which takes the
              ;; pane's size, and the mark goes.
              (select-window right)
              (redisplay t)
              (should (equal (portal-rex-gui-tests--claims server) '("take")))
              (portal-rex-gui-tests--wait
               (lambda () (let ((grid (portal-rex-gui-tests--grid target)))
                            (and (not (equal (car grid) '(60 15))) (equal (car grid) (cadr grid))))))
              (portal-rex-gui-tests--wait
               (lambda () (not (string-search "sized" (portal-rex-gui-tests--mark buffer)))))
              ;; Selecting another pane claims nothing; coming back takes
              ;; the block again, which leaves it as it is.
              (select-window left)
              (redisplay t)
              (should-not (portal-rex-gui-tests--claims server))
              (select-window right)
              (redisplay t)
              (should (equal (portal-rex-gui-tests--claims server) '("take")))
              ;; Emacs loses the keyboard with the pane selected, and the app
              ;; takes the block: Emacs follows, and claims nothing.
              (portal-rex-gui-tests--focus nil)
              (portal-fake-rex-command server :claim "block:fake-1" :client "client:app"
                                       :name "Rex.app")
              (portal-rex-gui-tests--wait
               (lambda () (equal (portal-rex-gui-tests--grid target) '((60 15) (60 15)))))
              (portal-rex-gui-tests--wait
               (lambda () (string-search ":sized by Rex.app" (portal-rex-gui-tests--mark buffer))))
              (should-not (portal-rex-gui-tests--claims server))
              ;; Emacs gets the keyboard back with the pane selected: it
              ;; takes the block.
              (portal-rex-gui-tests--focus t)
              (should (equal (portal-rex-gui-tests--claims server) '("take")))
              (portal-rex-gui-tests--wait
               (lambda () (not (equal (car (portal-rex-gui-tests--grid target)) '(60 15)))))
              ;; The app takes it while Emacs is not using the block, which
              ;; is then switched into the pane in use: the view comes, and
              ;; Emacs takes the block.
              (select-window left)
              (redisplay t)
              (portal-fake-rex-command server :claim "block:fake-1" :client "client:app")
              (portal-rex-gui-tests--wait
               (lambda () (equal (car (portal-rex-gui-tests--grid target)) '(60 15))))
              (should-not (portal-rex-gui-tests--claims server))
              (switch-to-buffer buffer)
              (redisplay t)
              (should (eq (buffer-local-value 'portal-view--window buffer) left))
              (should (equal (portal-rex-gui-tests--claims server) '("take")))
              ;; The app takes it while Emacs keeps the keyboard, as a phone
              ;; would: a key typed takes it back before it is written.
              (portal-fake-rex-command server :claim "block:fake-1" :client "client:app")
              (portal-rex-gui-tests--wait
               (lambda () (string-search ":sized" (portal-rex-gui-tests--mark buffer))))
              ;; Keys go to this frame by name: the VM's desktop may take
              ;; activation back from a test's Emacs at any moment.
              (select-frame-set-input-focus (selected-frame))
              (should (portal-view--with-frame-title (selected-frame)
                                                     #'portal-test-native-target-frame))
              (portal-test-native-focus-target)
              (portal-terminal-focus)
              (should (portal-test-native-key 0 0 "a"))
              (should (equal (portal-rex-gui-tests--claims server) '("take")))
              (should (equal (portal-rex-gui-tests--written server) '(:data "a")))
              (portal-input-unfocus)))
        (portal-rex-gui-tests--unfocus)
        (portal-test-native-target-frame nil)
        (mapc #'portal-rex-disconnect (portal-rex-connections))
        (kill-buffer "*rex-gui-elsewhere*")))))

(ert-deftest portal-rex-gui-choosing-a-block-shows-it ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    (portal-fake-rex-command
     server :blocks '(:session:fake-1
                      [(:block_id "block:fake-1" :label "shell" :placement "placed")
                       (:block_id "block:fake-2" :label "logs" :placement "placed")]))
    (let ((portal-rex-socket (portal-fake-rex-socket server)))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer (get-buffer-create "*rex-gui-elsewhere*"))
            (portal-rex-connect)
            (let ((logs (get-buffer "*rex: fake/logs*")))
              ;; Listed among the terminals before any window shows it.
              (should (memq logs (portal-terminal-buffers)))
              (should-not (buffer-local-value 'portal-view--target logs))
              ;; Chosen, it is shown, and so opens its view.
              (portal-terminal--visit logs)
              (should (eq (window-buffer) logs))
              (redisplay t)
              (should (buffer-local-value 'portal-view--target logs))
              (should (equal (plist-get (portal-fake-rex-request server "session.own_block")
                                        :payload)
                             '(:session_id "session:fake-1" :block_ids ["block:fake-2"]
                               :mode "request")))
              ;; It is the terminal the chooser and next and previous go by.
              (should (memq logs (portal-terminal-buffers)))
              (portal-terminal-next)
              (should (equal (buffer-name) "*rex: fake/shell*"))))
        (mapc #'portal-rex-disconnect (portal-rex-connections))
        (kill-buffer "*rex-gui-elsewhere*")))))

(ert-deftest portal-rex-gui-desktop-puts-blocks-back-in-their-panes ()
  :tags '(:gui)
  ;; Three blocks across two tabs and a split; Emacs quits and starts
  ;; again with the desktop: the same blocks in the same panes, showing
  ;; their screens, with no command given.
  (require 'desktop)
  (require 'tab-bar)
  (portal-fake-rex-with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                               (:session_id "session:b" :label "play")])
    (portal-fake-rex-command server :blocks '(:session:a [(:block_id "block:1" :label "api")
                                                         (:block_id "block:2" :label "logs")]
                                              :session:b [(:block_id "block:3" :label "shell")]))
    (portal-fake-rex-command server :screen '(:block:1 "\e[H\e[2Japi screen"
                                              :block:2 "\e[H\e[2Jlogs screen"
                                              :block:3 "\e[H\e[2Jshell screen"))
    (let* ((directory (make-temp-file "rex-desktop" t))
           (desktop-globals-to-save nil)
           (desktop-load-locked-desktop t)
           (desktop-restore-frames t)
           (desktop-restore-eager t)
           (desktop-dirname nil)
           (desktop-buffers-not-to-save-function
            (lambda (_file name &rest _) (string-prefix-p "*rex: " name)))
           (portal-rex-socket (portal-fake-rex-socket server))
           (tabs (and (boundp 'tab-bar-mode) tab-bar-mode))
           (configuration (current-window-configuration))
           (shows (lambda (window text)
                    (portal-rex-gui-tests--wait
                     (lambda ()
                       (let ((target (buffer-local-value 'portal-view--target
                                                         (window-buffer window))))
                         (and target
                              (equal (portal-rex-gui-tests--state target) "live")
                              (string-search text (portal--terminal-text target)))))))))
      (unwind-protect
          (progn
            (portal-rex-connect)
            (tab-bar-mode 1)
            (tab-bar-close-other-tabs)
            (delete-other-windows)
            (switch-to-buffer "*rex: work/api*")
            (set-window-buffer (split-window-below) "*rex: work/logs*")
            (tab-bar-new-tab)
            (delete-other-windows)
            (switch-to-buffer "*rex: play/shell*")
            (redisplay t)
            (desktop-save directory t)
            ;; Emacs quits: its buffers go, and Rex keeps the blocks.
            (mapc #'portal-rex-disconnect (portal-rex-connections))
            (tab-bar-close-other-tabs)
            (delete-other-windows)
            (switch-to-buffer "*scratch*")
            ;; It starts again and reads the desktop, which waits for no server.
            (let ((inhibit-message t))
              (desktop-read directory))
            (should-not (portal-rex-connections))
            (should (equal (buffer-local-value 'major-mode (window-buffer))
                           'portal-rex-placeholder-mode))
            ;; Once idle, it connects, and each pane shows its block.
            (portal-rex-gui-tests--wait (lambda () (null (portal-rex--placeholders))))
            (should (equal (buffer-name (window-buffer)) "*rex: play/shell*"))
            (should (= (length (window-list nil 'nomini)) 1))
            (funcall shows (selected-window) "shell screen")
            (tab-bar-select-tab 1)
            (redisplay t)
            (let ((windows (window-list nil 'nomini (frame-first-window))))
              (should (equal (mapcar (lambda (window) (buffer-name (window-buffer window))) windows)
                             '("*rex: work/api*" "*rex: work/logs*")))
              (funcall shows (car windows) "api screen")
              (funcall shows (cadr windows) "logs screen")))
        (mapc #'portal-rex-disconnect (portal-rex-connections))
        (mapc #'kill-buffer (portal-rex--placeholders))
        (ignore-errors (desktop-release-lock directory))
        (setq desktop-dirname nil)
        (tab-bar-close-other-tabs)
        (tab-bar-mode (if tabs 1 -1))
        (set-window-configuration configuration)
        (delete-directory directory t)))))

(provide 'portal-rex-gui-tests)
;;; portal-rex-gui-tests.el ends here
