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

(defmacro portal-rex-gui-tests--showing (server &rest body)
  "Connect to SERVER, show its block in the selected window, and run BODY.
BODY runs with `target' bound to the block's terminal once it is live,
and the buffer current."
  (declare (indent 1))
  `(let ((portal-rex-socket (portal-fake-rex-socket ,server)))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (portal-rex-connect)
           (switch-to-buffer "*rex: fake/shell*")
           (redisplay t)
           (let ((target portal-view--target))
             (should target)
             (portal-rex-gui-tests--wait
              (lambda () (equal (portal-rex-gui-tests--state target) "live")))
             ,@body))
       (mapc #'portal-rex-disconnect (portal-rex-connections)))))

(ert-deftest portal-rex-gui-shows-a-block-in-its-buffer ()
  :tags '(:gui)
  (portal-fake-rex-with (server)
    ;; The screen the block had before Emacs came, in two parts.
    (portal-fake-rex-command server :screen '(:block:fake-1 "\e[H\e[2Jbefore Emacs\r\n$ "))
    (portal-fake-rex-command server :paint_part 10)
    (portal-rex-gui-tests--showing server
      ;; The sequence: attach, claim, size to the pane, stream, paint.
      (should (equal (plist-get (portal-fake-rex-request server "session.attach") :payload)
                     '(:session_id "session:fake-1")))
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
      (should (equal (plist-get (plist-get (plist-get (portal-fake-rex-request
                                                       server "com.superlogical.terminal.format")
                                                      :payload)
                                           :args)
                                :format)
                     "vt"))
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

(provide 'portal-rex-gui-tests)
;;; portal-rex-gui-tests.el ends here
