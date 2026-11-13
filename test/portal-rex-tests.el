;;; portal-rex-tests.el --- Rex connections against the fake server -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Runs portal-rex.el on the real native module, whose message sockets need
;; no window, against test/fake-rex-server.py on sockets of its own: never
;; the user's Rex server.  PORTAL_TEST_BUILD names the build directory.
;; Batch Emacs runs no main run loop, so the module's "rex ID" record never
;; comes: these tests take messages by waiting, as `portal-rex-call' does.
;; test/portal-rex-gui-tests.el covers the record, and
;; test/portal-rex-tests.c the core's own rules.  The real-server tier,
;; test/rex-server-gui.sh, runs the parity checks against a real server.

(require 'ert)
(require 'portal-fake-rex
         (expand-file-name "portal-fake-rex.el" (file-name-directory load-file-name)))

(let ((build (getenv "PORTAL_TEST_BUILD")))
  (unless build (error "Set PORTAL_TEST_BUILD to the build directory"))
  (module-load (expand-file-name "portal.bundle/Contents/MacOS/portal.dylib" build)))

(require 'portal-rex)
(require 'portal-rex-parity
         (expand-file-name "portal-rex-parity.el" (file-name-directory load-file-name)))

(defmacro portal-rex-tests--with (servers &rest body)
  "Run BODY with each symbol in SERVERS bound to a new fake Rex server.
Connections that BODY leaves are closed, and none may remain."
  (declare (indent 1))
  `(portal-fake-rex-with ,servers
     (let ((portal-rex-timeout 2)
           (portal-rex-event-functions nil))
       (should-not portal-rex--connections)
       (cl-letf (((symbol-function 'portal-view--load) #'ignore))
         (unwind-protect (progn ,@body)
           (mapc #'portal-rex-disconnect (copy-sequence portal-rex--connections))))
       (should-not portal-rex--connections)
       ;; No block's buffer outlives its connection.
       (should-not (cl-remove-if-not
                    (lambda (buffer) (buffer-local-value 'portal-rex-block-id buffer))
                    (buffer-list)))
       (should-not (memq #'portal-rex--disconnect-all kill-emacs-hook)))))

(defun portal-rex-tests--connect (server)
  "Connect to the fake SERVER and return the connection."
  (portal-rex-connect (portal-fake-rex-socket server)))

(defun portal-rex-tests--until (connection done)
  "Handle CONNECTION's messages until DONE returns non-nil; fail after 2 seconds."
  (should (portal-rex--await connection done 2)))

(defmacro portal-rex-tests--messages (&rest body)
  "Run BODY and return what it added to *Messages*."
  (declare (indent 0))
  `(let ((start (with-current-buffer (messages-buffer) (point-max)))
         (inhibit-message t))
     ,@body
     (with-current-buffer (messages-buffer)
       (buffer-substring-no-properties start (point-max)))))

(defun portal-rex-tests--failure (form)
  "Return the error plist of the `portal-rex-error' that calling FORM signals."
  (let ((data (should-error (funcall form) :type 'portal-rex-error)))
    (nth 2 data)))

(defun portal-rex-tests--event (name)
  "Return the fake's event NAME, as a command's argument."
  (list :type "session_created"
        :payload (list :session (list :session_id (concat "session:" name) :label name))))

(defun portal-rex-tests--labels (events)
  "Return the session labels of the session_created EVENTS, in order."
  (mapcar (lambda (event)
            (plist-get (plist-get (plist-get (plist-get event :payload) :payload) :session)
                       :label))
          events))

(ert-deftest portal-rex-connect-says-hello-and-attaches ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                               (:session_id "session:b" :label "çé 🚀")])
    (let ((connection (portal-rex-tests--connect server)))
      ;; One API revision, as both the oldest and the newest Portal speaks.
      (let ((hello (plist-get (portal-fake-rex-take server :hello) :hello)))
        (should (equal (plist-get hello :api_revision) 12))
        (should (equal (plist-get hello :api_min_revision) 12))
        (should (equal (plist-get (plist-get hello :client) :name) "Portal"))
        (should (stringp (plist-get (plist-get hello :client) :version))))
      (should (equal (portal-fake-rex-request server "session.attach_all")
                     '(:type "request" :id "1" :method "session.attach_all"
                       :payload (:event_scope "session"))))
      (should (portal-rex-live-p connection))
      (should (equal (portal-rex-connections) (list connection)))
      (should (equal (plist-get (portal-rex-connection-welcome connection) :api_revision) 12))
      (should (equal (portal-rex-connection-sessions connection)
                     [(:session_id "session:a" :label "work")
                      (:session_id "session:b" :label "çé 🚀")]))
      ;; Connecting again to the same server makes no second connection.
      (should (eq (portal-rex-tests--connect server) connection))
      (should (eq (portal-rex-connect (concat (portal-fake-rex-directory server) "/./s"))
                  connection))
      (portal-rex-disconnect connection)
      (should (equal (plist-get (portal-fake-rex-take server :disconnected) :code) 1000))
      (should-not (portal-rex-live-p connection))
      (should-not (portal-rex-connections))
      ;; Disconnecting twice is nothing.
      (portal-rex-disconnect connection))))

(ert-deftest portal-rex-a-block-whose-view-cannot-open-says-why ()
  ;; A window shows the buffer; graphical Emacs opens its terminal view
  ;; there (test/portal-rex-gui-tests.el).  Here no view can open.
  (portal-rex-tests--with (server)
    (portal-rex-tests--connect server)
    (save-window-excursion
      (let (opened)
        (cl-letf (((symbol-function 'portal--open)
                   (lambda (kind options)
                     (push (cons kind options) opened)
                     (error "No views here"))))
          (switch-to-buffer "*rex: fake/shell*")
          (with-current-buffer (get-buffer-create "*rex-tests-plain*")
            (switch-to-buffer-other-window (current-buffer)))
          (let ((said (portal-rex-tests--messages (portal-rex--show-shown))))
            (should (equal said "Cannot show Rex block shell: No views here\n")))
          ;; One fed terminal was asked for, for the block's buffer alone.
          (should (equal (mapcar #'car opened) '("terminal")))
          (should (eq (plist-get (cdar opened) :fed) t))
          (with-current-buffer "*rex: fake/shell*"
            (should-not portal-view--target)
            (should (string-search "Its screen could not be shown: No views here" (buffer-string)))
            (should (string-search "Showing the buffer again tries again." (buffer-string))))
          ;; Not again while a window still shows it.
          (portal-rex--show-shown)
          (should (= (length opened) 1))
          ;; Shown again later, it tries again.
          (set-window-buffer (get-buffer-window "*rex: fake/shell*") "*rex-tests-plain*")
          (portal-rex--show-shown)
          (set-window-buffer (selected-window) "*rex: fake/shell*")
          (ignore (portal-rex-tests--messages (portal-rex--show-shown)))
          (should (= (length opened) 2))))
      (kill-buffer "*rex-tests-plain*"))))

(ert-deftest portal-rex-fake-matches-a-real-server ()
  ;; The same checks run against a real server in the real-server tier.
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :screen '(:block:fake-1 "\e[H\e[2J$ fake screen, long enough"))
    (let ((connection (portal-rex-tests--connect server)))
      (portal-rex-parity-check connection)
      (portal-rex-parity-check-block connection "session:fake-1" "block:fake-1")
      (portal-rex-parity-check-owners connection (portal-fake-rex-socket server)
                                      "session:fake-1" "block:fake-1")
      (portal-rex-tests--idle server "block:fake-1")
      (portal-rex-parity-check-kill connection "session:fake-1" "block:fake-1"))))

(ert-deftest portal-rex-call-returns-the-result ()
  (portal-rex-tests--with (server)
    (let ((connection (portal-rex-tests--connect server)))
      (should (equal (portal-rex-call connection "session.list")
                     '(:sessions [(:session_id "session:fake-1" :label "fake")])))
      ;; nil names the one connection.
      (should (equal (plist-get (portal-rex-call nil "server.version") :rex_version)
                     "0.0.0-fake"))
      ;; Arguments reach the server as JSON, and every JSON value comes back.
      (portal-fake-rex-command server :result "session.set_label"
                               :payload '(:revision 42 :none :null :off :false :on t
                                          :empty [] :object nil :ratio 1.5
                                          :list [1 "two" (:three 3)]))
      (should (equal (portal-rex-call connection "session.set_label"
                                      '(:session_id "session:a" :label "naïve \"api\" 🚀"))
                     '(:revision 42 :none :null :off :false :on t :empty [] :object nil
                       :ratio 1.5 :list [1 "two" (:three 3)])))
      (should (equal (plist-get (portal-fake-rex-request server "session.set_label") :payload)
                     '(:session_id "session:a" :label "naïve \"api\" 🚀"))))))

(ert-deftest portal-rex-call-signals-the-servers-error ()
  (portal-rex-tests--with (server)
    (let ((connection (portal-rex-tests--connect server))
          (portal-rex-timeout 30)
          (started (float-time)))
      ;; A method the server lacks is an error from the server, not a wait.
      (should (equal (portal-rex-tests--failure
                      (lambda () (portal-rex-call connection "no.such_method")))
                     '(:code "method_not_found"
                       :message "netapi: no handler for method \"no.such_method\""
                       :status 404)))
      (should (equal (portal-rex-tests--failure
                      (lambda () (portal-rex-call connection "session.attach_all"
                                                  '(:event_scope "bogus"))))
                     '(:code "bad_request"
                       :message "session.attach_all request: event_scope must be \"all\" or \"session\""
                       :status 400)))
      (should (< (- (float-time) started) 5))
      (should (equal (cadr (should-error (portal-rex-call connection "no.such_method")
                                         :type 'portal-rex-error))
                     "no.such_method: netapi: no handler for method \"no.such_method\""))
      ;; The connection is as good as before.
      (should (portal-rex-call connection "session.list")))))

(ert-deftest portal-rex-call-async-answers-in-order ()
  (portal-rex-tests--with (server)
    (let ((connection (portal-rex-tests--connect server)) answers)
      (dolist (method '("session.list" "no.such_method" "server.version"))
        (should-not (portal-rex-call-async connection method nil
                                           (lambda (result failure)
                                             (push (list method result failure) answers)))))
      (should-not answers)
      (portal-rex-tests--until connection (lambda () (= (length answers) 3)))
      (pcase-let ((`((,first ,sessions nil) (,second nil ,failure) (,third ,version nil))
                   (reverse answers)))
        (should (equal (list first second third)
                       '("session.list" "no.such_method" "server.version")))
        (should (plist-get sessions :sessions))
        (should (equal (plist-get failure :code) "method_not_found"))
        (should (plist-get version :rex_version)))
      ;; A callback that fails stops nothing after it.
      (let (reached)
        (portal-rex-call-async connection "session.list" nil (lambda (&rest _) (error "Boom")))
        (portal-rex-call-async connection "session.list" nil (lambda (&rest _) (setq reached t)))
        (let ((inhibit-message t))
          (portal-rex-tests--until connection (lambda () reached)))))))

(ert-deftest portal-rex-call-gives-up-after-its-timeout ()
  (portal-rex-tests--with (server)
    (let ((connection (portal-rex-tests--connect server))
          (started (float-time))
          late)
      (portal-fake-rex-command server :silent "session.view")
      (should (equal (portal-rex-tests--failure
                      (lambda () (portal-rex-call connection "session.view" nil 0.2)))
                     '(:code "portal_timeout" :message "no answer within 0.2 seconds")))
      (should (< 0.15 (- (float-time) started) 1.5))
      ;; An answer that comes after the caller gave up reaches no one, and
      ;; later calls get their own.
      (portal-fake-rex-command server :hold "session.list_blocks")
      (should-error (portal-rex-call connection "session.list_blocks" nil 0.1)
                    :type 'portal-rex-error)
      (portal-rex-call-async connection "session.list" nil (lambda (&rest _) (setq late t)))
      (portal-fake-rex-command server :release "session.list_blocks")
      (portal-rex-tests--until connection (lambda () late))
      (should (portal-rex-call connection "session.list"))
      (should-not (portal-rex-connection-calls connection))
      ;; A quit while it waits leaves no one waiting either.
      (cl-letf (((symbol-function 'portal--rex-wait) (lambda (&rest _) (signal 'quit nil))))
        (should (eq (condition-case nil (portal-rex-call connection "session.view")
                      (quit 'quit))
                    'quit)))
      (should-not (portal-rex-connection-calls connection))
      (should (portal-rex-call connection "session.list")))))

(ert-deftest portal-rex-events-reach-the-hook-in-order ()
  (portal-rex-tests--with (server)
    (let* ((connection (portal-rex-tests--connect server))
           seen
           (portal-rex-event-functions
            (list (lambda (from event) (push (cons from event) seen)))))
      (dolist (name '("one" "two" "three"))
        (portal-fake-rex-command server :event (portal-rex-tests--event name)))
      (portal-rex-tests--until connection (lambda () (= (length seen) 3)))
      (let ((events (mapcar #'cdr (reverse seen))))
        (should (equal (mapcar #'car seen) (list connection connection connection)))
        (should (equal (mapcar (lambda (event) (plist-get event :seq)) events) '(1 2 3)))
        (should (equal (portal-rex-tests--labels events) '("one" "two" "three")))
        (should (equal (car events)
                       '(:type "event" :seq 1
                         :payload (:type "session_created"
                                   :payload (:session (:session_id "session:one"
                                                       :label "one")))))))
      ;; Events that arrive while a call waits run before its answer, and
      ;; the call's response says how far the server had got.
      (setq seen nil)
      (portal-fake-rex-command server :hold "session.list")
      (portal-fake-rex-command server :after "session.list"
                               :then [(:event (:type "four" :payload nil))
                                      (:event (:type "five" :payload nil))
                                      (:release "session.list")])
      (let ((order nil))
        (setq portal-rex-event-functions
              (list (lambda (_from event)
                      (push (plist-get (plist-get event :payload) :type) order))))
        (should (portal-rex-call connection "session.list"))
        (push "answered" order)
        (should (equal (reverse order) '("four" "five" "answered"))))
      ;; A hook function that fails loses its event and no other.
      (let (after)
        (setq portal-rex-event-functions
              (list (lambda (_from event)
                      (if (equal (plist-get (plist-get event :payload) :type) "bad")
                          (error "Boom")
                        (setq after t)))))
        (portal-fake-rex-command server :event '(:type "bad"))
        (portal-fake-rex-command server :event '(:type "good"))
        (let ((inhibit-message t))
          (portal-rex-tests--until connection (lambda () after)))))))

(ert-deftest portal-rex-connect-orders-events-around-the-sessions ()
  ;; The sessions a connection starts with are as they were at the seq of the
  ;; server's answer.  An event up to that seq is in them already; a later
  ;; one counts even when it arrived before the answer.
  (portal-rex-tests--with (server)
    (let* (seen
           (portal-rex-event-functions (list (lambda (_from event) (push event seen)))))
      (portal-fake-rex-command server :hold "session.attach_all")
      (portal-fake-rex-command server :after "session.attach_all"
                               :then (vector (list :event (portal-rex-tests--event "before"))
                                             '(:stamp "session.attach_all")
                                             (list :event (portal-rex-tests--event "between"))
                                             '(:release "session.attach_all")))
      (let ((connection (portal-rex-tests--connect server)))
        (should (equal (portal-rex-tests--labels (reverse seen)) '("between")))
        (portal-fake-rex-command server :event (portal-rex-tests--event "after"))
        (portal-rex-tests--until connection (lambda () (= (length seen) 2)))
        (should (equal (portal-rex-tests--labels (reverse seen)) '("between" "after")))
        (should (equal (mapcar (lambda (event) (plist-get event :seq)) (reverse seen))
                       '(2 3)))))))

(ert-deftest portal-rex-connect-keeps-order-when-a-handler-calls ()
  ;; A handler of the first event that overtook the sessions calls the server
  ;; and waits; an event arrives meanwhile.  The second overtaking event
  ;; still comes before it.
  (portal-rex-tests--with (server)
    (let* (seen
           (portal-rex-event-functions
            (list (lambda (from event)
                    (push (plist-get (plist-get event :payload) :type) seen)
                    (when (equal (car seen) "first")
                      (should (portal-rex-call from "session.list")))))))
      (portal-fake-rex-command server :hold "session.attach_all")
      (portal-fake-rex-command server :after "session.attach_all"
                               :then [(:event (:type "first")) (:event (:type "second"))
                                      (:release "session.attach_all")])
      (portal-fake-rex-command server :hold "session.list")
      (portal-fake-rex-command server :after "session.list"
                               :then [(:event (:type "third")) (:release "session.list")])
      (let ((connection (portal-rex-tests--connect server)))
        (portal-rex-tests--until connection (lambda () (= (length seen) 3)))
        (should (equal (reverse seen) '("first" "second" "third")))))))

(ert-deftest portal-rex-every-hook-function-sees-events-in-order ()
  ;; The first function waits for the server while it handles an event, and
  ;; the next events arrive before the answer.  The second function still
  ;; sees the first event first, and the waiting call gets its answer.
  (portal-rex-tests--with (server)
    (let* ((connection (portal-rex-tests--connect server))
           first second answered
           (type (lambda (event) (plist-get (plist-get event :payload) :type)))
           (portal-rex-event-functions
            (list (lambda (from event)
                    (push (funcall type event) first)
                    (when (equal (car first) "one")
                      (portal-rex-call-async from "server.version" nil
                                             (lambda (&rest _) (push "version" first)))
                      (setq answered (portal-rex-call from "session.list"))
                      (push "returned" first)))
                  (lambda (_from event) (push (funcall type event) second)))))
      (portal-fake-rex-command server :hold "session.list")
      (portal-fake-rex-command server :after "session.list"
                               :then [(:event (:type "two")) (:event (:type "three"))
                                      (:release "session.list")])
      (portal-fake-rex-command server :event '(:type "one"))
      (portal-rex-tests--until connection (lambda () (= (length second) 3)))
      (should (plist-get answered :sessions))
      ;; Answers reach a function that waits; events wait for it to return.
      (should (equal (reverse first) '("one" "version" "returned" "two" "three")))
      (should (equal (reverse second) '("one" "two" "three")))
      ;; A function that fails leaves the next event to run as usual.
      (setq portal-rex-event-functions
            (list (lambda (_from event)
                    (push (funcall type event) first)
                    (when (equal (car first) "bad") (error "Boom")))))
      (portal-fake-rex-command server :event '(:type "bad"))
      (portal-fake-rex-command server :event '(:type "good"))
      (let ((inhibit-message t))
        (portal-rex-tests--until connection (lambda () (equal (car first) "good"))))
      (should-not (portal-rex-connection-handling connection)))))

(ert-deftest portal-rex-events-before-the-end-run-after-a-waiting-function ()
  ;; A hook function waits for the server, more events arrive, and the
  ;; connection ends.  The function's call returns, the events that had
  ;; arrived still run, in order, and only then is the connection lost.
  (dolist (case '((:silent [(:event (:type "two")) (:event (:type "three")) (:drop t)]
                   "portal_disconnected" "The connection to the server was lost")
                  ;; The same when the server answers first, then closes.
                  (:result [(:event (:type "two")) (:event (:type "three")) (:close 1000)]
                   answered "The server closed the connection (1000)")))
    (portal-rex-tests--with (server)
      (let* ((connection (portal-rex-tests--connect server))
             seen outcome live
             (portal-rex-event-functions
              (list (lambda (from event)
                      (push (plist-get (plist-get event :payload) :type) seen)
                      (when (equal (car seen) "one")
                        (setq outcome (condition-case failure
                                          (and (portal-rex-call from "session.view") 'answered)
                                        (portal-rex-error (plist-get (nth 2 failure) :code)))
                              live (portal-rex-live-p from))
                        (push "returned" seen))))))
        (portal-fake-rex-command server (nth 0 case) "session.view" :payload '(:ok t))
        (portal-fake-rex-command server :after "session.view" :then (nth 1 case))
        (portal-fake-rex-command server :event '(:type "one"))
        (should (equal (portal-rex-tests--messages
                         (portal-rex-tests--until
                          connection
                          (lambda () (eq (portal-rex-connection-state connection) 'closed))))
                       (format "Lost the Rex server at %s: %s\n"
                               (abbreviate-file-name (portal-fake-rex-socket server))
                               (nth 3 case))))
        (should (equal outcome (nth 2 case)))
        (should (equal (reverse seen) '("one" "returned" "two" "three")))
        ;; Once its call has failed, the function sees that the connection is gone.
        (when (stringp outcome) (should-not live))
        (should-not (portal-rex-connection-calls connection))))))

(ert-deftest portal-rex-quit-in-a-hook-function-strands-nothing ()
  ;; Events and the connection's end are in Emacs when a hook function
  ;; leaves non-locally, here by signalling quit itself, as leaving the
  ;; debugger would.  That goes on up; the rest is handled as soon as Emacs
  ;; is idle, though nothing will ask for this connection again.
  (portal-rex-tests--with (server)
    (let* ((connection (portal-rex-tests--connect server))
           seen answers
           (portal-rex-event-functions
            (list (lambda (_from event)
                    (push (plist-get (plist-get event :payload) :type) seen)
                    (when (equal (car seen) "one") (signal 'quit nil))))))
      (portal-fake-rex-command server :silent "session.view")
      (dolist (tag '(first second))
        (portal-rex-call-async connection "session.view" nil
                               (lambda (_result failure)
                                 (push (list tag (plist-get failure :code)) answers)
                                 (when (eq tag 'first) (signal 'quit nil)))))
      (portal-fake-rex-request server "session.view")
      (portal-fake-rex-request server "session.view")
      (dolist (name '("one" "two" "three"))
        (portal-fake-rex-command server :event (list :type name)))
      (portal-fake-rex-command server :drop t)
      (portal-fake-rex-take server :disconnected)
      (sleep-for 0.2)
      (should (eq (condition-case nil (progn (portal-rex--pump connection) nil) (quit 'quit))
                  'quit))
      (should (equal seen '("one")))
      (let ((said (portal-rex-tests--messages
                    (let ((deadline (+ (float-time) 2)))
                      (while (and (< (length answers) 2) (< (float-time) deadline))
                        ;; The first request's function quits too, out of the timer.
                        (condition-case nil (accept-process-output nil 0.05) (quit nil)))))))
        (should (equal said
                       (format "Lost the Rex server at %s: The connection to the server was lost\n"
                               (abbreviate-file-name (portal-fake-rex-socket server))))))
      (should (equal (reverse seen) '("one" "two" "three")))
      (should (equal (reverse answers)
                     '((first "portal_disconnected") (second "portal_disconnected"))))
      (should (eq (portal-rex-connection-state connection) 'closed))
      (should-not (portal-rex-connection-resume connection)))))

(ert-deftest portal-rex-quit-while-a-call-waits-loses-no-message ()
  ;; The user quits a waiting call just as messages come out of the module.
  ;; The call quits, and what had arrived is handled all the same.
  (portal-rex-tests--with (server)
    (let* ((connection (portal-rex-tests--connect server))
           seen
           (portal-rex-event-functions
            (list (lambda (_from event)
                    (push (plist-get (plist-get event :payload) :type) seen))))
           (parse (symbol-function 'portal-rex--parse))
           (quits 0))
      (portal-fake-rex-command server :hold "session.list")
      (portal-fake-rex-command server :after "session.list"
                               :then [(:event (:type "one")) (:event (:type "two"))
                                      (:release "session.list")])
      (cl-letf (((symbol-function 'portal-rex--parse)
                 (lambda (text)
                   ;; As C-g does, at the worst moment: the messages are out
                   ;; of the module and not yet in the connection's queue.
                   (when (= (cl-incf quits) 1) (setq quit-flag t))
                   (funcall parse text))))
        (should (eq (condition-case nil (progn (portal-rex-call connection "session.list") nil)
                      (quit 'quit))
                    'quit)))
      (should-not (portal-rex-connection-calls connection))
      (portal-rex-tests--until connection (lambda () (= (length seen) 2)))
      (should (equal (reverse seen) '("one" "two")))
      (should (portal-rex-call connection "session.list")))))

(defun portal-rex-tests--quitting (native function)
  "Call FUNCTION with a quit arriving inside the module's function NATIVE.
Return `quit' if FUNCTION quit, and what it returned otherwise.  The quit
arrives as C-g does, by `quit-flag', the first time NATIVE is called."
  (let ((original (symbol-function native))
        (arrived nil))
    (cl-letf (((symbol-function native)
               (lambda (&rest arguments)
                 (unless arrived (setq arrived t quit-flag t))
                 (apply original arguments))))
      (condition-case nil (funcall function) (quit 'quit)))))

(ert-deftest portal-rex-quit-at-any-step-leaves-nothing-half-done ()
  ;; A quit that arrives while a connection is made, a request sent or a
  ;; connection closed waits for that step, and what the step began is undone
  ;; or finished: no connection half made, no request with no one waiting,
  ;; no connection half closed.
  (portal-rex-tests--with (server)
    (let ((socket (portal-fake-rex-socket server)))
      (should (eq (portal-rex-tests--quitting 'portal--rex-open
                                              (lambda () (portal-rex-connect socket)))
                  'quit))
      ;; The server may never have seen that one: it was closed as it dialed.
      (should-not portal-rex--connections)
      (let ((connection (portal-rex-connect socket)))
        (portal-fake-rex-command server :silent "session.view")
        (should (eq (portal-rex-tests--quitting
                     'portal--rex-request
                     (lambda () (portal-rex-call connection "session.view")))
                    'quit))
        (should (portal-fake-rex-request server "session.view"))
        (should-not (portal-rex-connection-calls connection))
        (should (portal-rex-call connection "session.list"))
        (should (eq (portal-rex-tests--quitting
                     'portal--rex-close (lambda () (portal-rex-disconnect connection)))
                    'quit))
        (should (eq (portal-rex-connection-state connection) 'closed))
        (should-not portal-rex--connections)
        (should (portal-fake-rex-take
                 server (lambda (report) (equal (plist-get report :code) 1000))))))))

(ert-deftest portal-rex-lost-connection-is-reported-once ()
  (portal-rex-tests--with (server)
    (let ((connection (portal-rex-tests--connect server))
          (name (abbreviate-file-name (portal-fake-rex-socket server)))
          answers)
      (portal-fake-rex-command server :silent "session.view")
      (dolist (tag '(first second))
        (portal-rex-call-async connection "session.view" nil
                               (lambda (result failure) (push (list tag result failure) answers))))
      (portal-fake-rex-command server :drop t)
      (should (equal (portal-rex-tests--messages
                       (portal-rex-tests--until
                        connection (lambda () (not (portal-rex-connection-id connection))))
                       ;; Handling it again, as a late record would, says nothing more.
                       (portal-rex--pump connection))
                     (format "Lost the Rex server at %s: The connection to the server was lost\n"
                             name)))
      ;; Every waiting request fails, oldest first.
      (should (equal (reverse answers)
                     '((first nil (:code "portal_disconnected"
                                   :message "The connection to the server was lost"))
                       (second nil (:code "portal_disconnected"
                                    :message "The connection to the server was lost")))))
      (should-not (portal-rex-live-p connection))
      (should-not (portal-rex-connections))
      (should (equal (portal-rex-connection-reason connection)
                     "The connection to the server was lost"))
      ;; Emacs is usable: calls say there is no connection, and a new one works.
      (should (equal (plist-get (portal-rex-tests--failure
                                 (lambda () (portal-rex-call connection "session.list")))
                                :code)
                     "portal_disconnected"))
      (should-error (portal-rex-call nil "session.list") :type 'user-error)
      (let ((again (portal-rex-tests--connect server)))
        (should-not (eq again connection))
        (should (portal-rex-call again "session.list"))
        ;; A server that says goodbye gives its reason.
        (portal-fake-rex-command server :close 1001 :reason "going away")
        (portal-fake-rex-take server :disconnected)
        (should (equal (portal-rex-tests--messages
                         (portal-rex-tests--until
                          again (lambda () (not (portal-rex-connection-id again)))))
                       (format "Lost the Rex server at %s: The server closed the connection (1001: going away)\n"
                               name)))
        ;; The server's goodbye is answered before the line goes.
        (should (equal (plist-get (portal-fake-rex-take server :disconnected) :code) 1001))))))

(ert-deftest portal-rex-waiting-call-ends-with-its-connection ()
  (portal-rex-tests--with (server)
    (let ((connection (portal-rex-tests--connect server))
          (portal-rex-timeout 30)
          (started (float-time)))
      (portal-fake-rex-command server :silent "session.view")
      (portal-fake-rex-command server :after "session.view" :then [(:drop t)])
      (let ((inhibit-message t))
        (should (equal (portal-rex-tests--failure
                        (lambda () (portal-rex-call connection "session.view")))
                       '(:code "portal_disconnected"
                         :message "The connection to the server was lost"))))
      (should (< (- (float-time) started) 5)))))

(ert-deftest portal-rex-connect-says-why-it-cannot ()
  (portal-rex-tests--with (server)
    (let* ((socket (portal-fake-rex-socket server))
           (name (abbreviate-file-name socket))
           (portal-rex-timeout 0.3)
           (try (lambda (expected)
                  (should (equal (cadr (should-error (portal-rex-connect socket)
                                                     :type 'user-error))
                                 (format expected name)))
                  (should-not portal-rex--connections))))
      ;; No server: no socket, or a socket nothing listens on.
      (let ((missing (expand-file-name "none" (portal-fake-rex-directory server))))
        (should (equal (cadr (should-error (portal-rex-connect missing) :type 'user-error))
                       (format "No Rex server is running: there is no socket at %s"
                               (abbreviate-file-name missing)))))
      (let ((stale (expand-file-name "stale" (portal-fake-rex-directory server))))
        (delete-process (make-network-process :name "stale" :server t :family 'local
                                              :service stale :noquery t))
        (should (file-exists-p stale))
        (should (equal (cadr (should-error (portal-rex-connect stale) :type 'user-error))
                       (format "Cannot connect to the Rex server at %s: Nothing is listening on that socket"
                               (abbreviate-file-name stale)))))
      ;; A server that is not Rex's.
      (portal-fake-rex-command server :upgrade "refuse")
      (funcall try "Cannot connect to the Rex server at %s: The server refused the connection: HTTP/1.1 400 Bad Request")
      (portal-fake-rex-command server :upgrade "no-protocol")
      (funcall try "Cannot connect to the Rex server at %s: The server does not speak rex.control.v1")
      (portal-fake-rex-command server :upgrade "bad-accept")
      (funcall try "Cannot connect to the Rex server at %s: The server's answer is not a WebSocket's")
      ;; A server that says nothing, to the upgrade or to the hello.
      (portal-fake-rex-command server :upgrade "silent")
      (funcall try "The Rex server at %s did not answer within 0.3 seconds")
      (portal-fake-rex-command server :upgrade "ok")
      (portal-fake-rex-command server :welcome :false)
      (funcall try "The Rex server at %s did not answer within 0.3 seconds")
      (portal-fake-rex-command server :welcome t)
      ;; A server that sends no events.
      (portal-fake-rex-command server :error "session.attach_all" :code "not_supported"
                               :message "no events here" :status 400)
      (funcall try "Cannot connect to the Rex server at %s: The server sends no events: no events here")
      ;; A quit while it waits leaves no connection, here or on the server.
      (portal-fake-rex-command server :welcome :false)
      (cl-letf (((symbol-function 'portal--rex-wait) (lambda (&rest _) (signal 'quit nil))))
        (should (eq (condition-case nil (portal-rex-connect socket) (quit 'quit)) 'quit)))
      (should-not portal-rex--connections)
      (should (portal-fake-rex-take server :disconnected))
      (portal-fake-rex-command server :welcome t)
      ;; A path no socket address holds.
      (let ((long (expand-file-name (make-string 120 ?a) (portal-fake-rex-directory server))))
        (write-region "" nil long nil 'silent)
        (should (string-prefix-p "A socket's path is at most 103 bytes"
                                 (cadr (should-error (portal-rex-connect long)))))
        (should-not portal-rex--connections))
      ;; And then one that works.
      (portal-fake-rex-command server :result "session.attach_all" :payload '(:sessions []))
      (should (portal-rex-live-p (portal-rex-connect socket))))))

(ert-deftest portal-rex-messages-cross-the-socket-whole ()
  (portal-rex-tests--with (server)
    (let* ((connection (portal-rex-tests--connect server))
           (long (concat (make-string 70000 ?x) "é🚀")))
      ;; Frames with 16-bit and 64-bit lengths, each way.
      (dolist (text (list (make-string 200 ?y) long))
        (portal-fake-rex-command server :result "echo" :payload (list :text text))
        (should (equal (portal-rex-call connection "echo" (list :text text)) (list :text text)))
        (should (equal (plist-get (portal-fake-rex-request server "echo") :payload)
                       (list :text text))))
      ;; A message in fragments, which may split a character, is one message.
      (portal-fake-rex-command server :fragment 7)
      (should (equal (portal-rex-call connection "echo") (list :text long)))
      (portal-fake-rex-command server :fragment 0)
      ;; A ping is answered, and is no message.
      (portal-fake-rex-command server :ping t)
      (should (portal-rex-call connection "session.list"))
      (should (equal (plist-get (portal-fake-rex-take server :pong) :pong) 1))
      ;; A message of a kind a newer server might send is ignored.
      (portal-fake-rex-command server :send "{\"type\":\"novelty\",\"x\":1}")
      (should (portal-rex-call connection "session.list"))
      (should (portal-rex-live-p connection)))))

(ert-deftest portal-rex-server-that-breaks-the-protocol-is-lost ()
  (dolist (case '((:send "this is not JSON" "The server sent a message that is not JSON")
                  (:send "[1,2]" "The server sent a message that is not JSON")
                  (:binary "bytes" "The server sent a message that is not text")))
    (portal-rex-tests--with (server)
      (let ((connection (portal-rex-tests--connect server)))
        (portal-fake-rex-command server (nth 0 case) (nth 1 case))
        (should (equal (portal-rex-tests--messages
                         (portal-rex-tests--until
                          connection (lambda () (not (portal-rex-connection-id connection)))))
                       (format "Lost the Rex server at %s: %s\n"
                               (abbreviate-file-name (portal-fake-rex-socket server))
                               (nth 2 case))))
        (should (equal (portal-rex-connection-state connection) 'closed))
        (should (portal-fake-rex-take server :disconnected))))))

(ert-deftest portal-rex-two-servers-side-by-side ()
  (portal-rex-tests--with (left right)
    (portal-fake-rex-command left :sessions [(:session_id "session:l" :label "left")])
    (portal-fake-rex-command right :sessions [(:session_id "session:r" :label "right")])
    (let* (seen
           (portal-rex-event-functions (list (lambda (from event) (push (cons from event) seen))))
           (first (portal-rex-tests--connect left))
           (second (portal-rex-tests--connect right))
           (label (lambda (connection)
                    (plist-get (aref (plist-get (portal-rex-call connection "session.list")
                                                :sessions)
                                     0)
                               :label))))
      (should-not (eq first second))
      (should (equal (portal-rex-connections) (list first second)))
      (should (equal (funcall label first) "left"))
      (should (equal (funcall label second) "right"))
      ;; With two connected, a call has to say which.
      (should-error (portal-rex-call nil "session.list"))
      ;; Each numbers its own requests, and answers its own callers.
      (let (answers)
        (dolist (connection (list first second first))
          (portal-rex-call-async connection "session.list" nil
                                 (lambda (result _failure)
                                   (push (plist-get (aref (plist-get result :sessions) 0) :label)
                                         answers))))
        (portal-rex-tests--until first (lambda () (= (length answers) 2)))
        (portal-rex-tests--until second (lambda () (= (length answers) 3)))
        (should (equal (sort answers #'string<) '("left" "left" "right"))))
      ;; An event reaches the hook with the connection it came on.
      (portal-fake-rex-command right :event (portal-rex-tests--event "from-right"))
      (portal-fake-rex-command left :event (portal-rex-tests--event "from-left"))
      (portal-rex-tests--until first (lambda () (assq first seen)))
      (portal-rex-tests--until second (lambda () (assq second seen)))
      (should (equal (portal-rex-tests--labels (list (cdr (assq first seen)))) '("from-left")))
      (should (equal (portal-rex-tests--labels (list (cdr (assq second seen)))) '("from-right")))
      ;; One going leaves the other.
      (portal-fake-rex-command left :drop t)
      (let ((inhibit-message t))
        (portal-rex-tests--until first (lambda () (not (portal-rex-connection-id first)))))
      (should (equal (portal-rex-connections) (list second)))
      (should (equal (funcall label second) "right"))
      (should (equal (plist-get (portal-rex-call nil "server.version") :rex_version)
                     "0.0.0-fake")))))

;;; Blocks' buffers

(defun portal-rex-tests--block (name &optional label placement)
  "Return the block NAME as the fake lists it, called LABEL, by default NAME."
  (list :block_id (concat "block:" name) :label (or label name)
        :placement (or placement "placed")))

(defun portal-rex-tests--blocks (server session &rest blocks)
  "Make the fake SERVER list BLOCKS as the blocks of SESSION from now on."
  (portal-fake-rex-command server :blocks (list (intern (concat ":session:" session))
                                                (vconcat blocks))))

(defun portal-rex-tests--session-event (server session type &rest fields)
  "Make the fake SERVER send the event TYPE of SESSION, with FIELDS."
  (portal-fake-rex-command
   server :event (list :type "session_event"
                       :payload (list :session_id (concat "session:" session)
                                      :event (list :type type :payload fields)))))

(defun portal-rex-tests--settle (connection)
  "Handle what CONNECTION's server has sent, and the lists of blocks that asks for."
  (portal-rex-call connection "server.version")
  (portal-rex-tests--until connection
                           (lambda () (null (portal-rex-connection-lists connection)))))

(defun portal-rex-tests--names (&optional connection session)
  "Return the names of the blocks' buffers of CONNECTION and SESSION, sorted."
  (sort (mapcar #'buffer-name
                (portal-rex-buffers connection (and session (concat "session:" session))))
        #'string<))

(defun portal-rex-tests--asked (server connection)
  "Return the methods that CONNECTION has asked the fake SERVER for, in order.
Each is returned once: a later call returns those asked for since."
  ;; Requests are answered in order, and reports written in order.
  (portal-rex-call connection "server.version")
  (portal-fake-rex-command server :fragment 0)
  (let ((requests (cl-remove-if-not (lambda (report) (plist-member report :request))
                                    (portal-fake-rex-reports server))))
    (setf (portal-fake-rex-reports server)
          (cl-set-difference (portal-fake-rex-reports server) requests))
    (remove "server.version"
            (mapcar (lambda (report) (plist-get (plist-get report :request) :method))
                    requests))))

(defun portal-rex-tests--shell (pid &optional depth)
  "Return a process reply for a zsh block under login, its shell PID.
DEPTH programs run under the shell, the last in the foreground: each a
list (NAME ARGV0 . MORE), MORE more of the process's fields."
  (let* ((login (list :pid (1- pid) :user_id 0 :user "root" :name "login" :path "/usr/bin/login"))
         (shell (list :pid pid :user_id 501 :name "zsh" :path "/bin/zsh" :argv0 "-zsh"
                      :cwd "/Users/someone"))
         (chain (cons shell (cl-loop for (name argv0 . more) in depth
                                     for number from (1+ pid)
                                     collect (append (list :pid number :user_id 501 :name name
                                                           :argv0 argv0)
                                                     more)))))
    (list :child login :foreground (car (last chain))
          :ancestors (vconcat (cdr (reverse chain)) (list login))
          :home "/Users/someone" :last_exit :null)))

(defconst portal-rex-tests--raw '(:echo :false :canonical :false :signals t)
  "The input mode of a line editor at a prompt.")

(defconst portal-rex-tests--cooked '(:echo t :canonical t :signals t)
  "The input mode of a shell running a program, or its own code.")

(defun portal-rex-tests--terminal (server block mode process)
  "Make the fake SERVER's BLOCK answer `input_mode' with MODE, `process' with PROCESS."
  (portal-fake-rex-command server :terminal block :input_mode mode :process process))

(defun portal-rex-tests--idle (server block)
  "Make the fake SERVER say that BLOCK's zsh waits at its prompt."
  (portal-rex-tests--terminal server block portal-rex-tests--raw (portal-rex-tests--shell 40)))

(defun portal-rex-tests--sleeping (server block)
  "Make the fake SERVER say that BLOCK's shell runs sleep."
  (portal-rex-tests--terminal server block portal-rex-tests--cooked
                              (portal-rex-tests--shell 40 '(("sleep" "sleep")))))

(defmacro portal-rex-tests--asking (answers &rest body)
  "Run BODY with `y-or-n-p' giving ANSWERS, in turn, and return its prompts.
With no answer left, a question fails the test."
  (declare (indent 1))
  `(let ((answers ,answers) asked)
     (cl-letf (((symbol-function 'y-or-n-p)
                (lambda (prompt)
                  (push prompt asked)
                  (if answers (pop answers) (ert-fail (list "Asked once too often" prompt))))))
       ,@body)
     (nreverse asked)))

(defconst portal-rex-tests--asks
  '("com.superlogical.terminal.input_mode" "com.superlogical.terminal.process")
  "What a kill asks the server, in order.")

(ert-deftest portal-rex-connect-makes-a-buffer-for-every-block ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                               (:session_id "session:b" :label "play")
                                               (:session_id "session:c" :label "empty")])
    ;; Detached blocks, and one placed in a way a newer server invented, are
    ;; blocks like any other.
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                              (portal-rex-tests--block "2" "logs" "detached")
                              (portal-rex-tests--block "3" "odd" "somewhere-new"))
    (portal-rex-tests--blocks server "b" (portal-rex-tests--block "4" "shell")
                              (portal-rex-tests--block "5" "shell"))
    (let ((connection (portal-rex-tests--connect server)))
      ;; They are there when connecting returns, named from both labels and
      ;; made unique as Emacs does.
      (should (equal (portal-rex-tests--names)
                     '("*rex: play/shell*" "*rex: play/shell*<2>" "*rex: work/api*"
                       "*rex: work/logs*" "*rex: work/odd*")))
      (should (equal (portal-rex-tests--names connection "a")
                     '("*rex: work/api*" "*rex: work/logs*" "*rex: work/odd*")))
      (should-not (portal-rex-buffers connection "session:c"))
      (should (equal (sort (portal-rex-tests--asked server connection) #'string<)
                     '("session.attach_all" "session.list_blocks" "session.list_blocks"
                       "session.list_blocks")))
      ;; Each knows its connection, its block and its session.
      (dolist (block '(("1" "session:a" "*rex: work/api*") ("2" "session:a" "*rex: work/logs*")
                       ("4" "session:b" "*rex: play/shell*")
                       ("5" "session:b" "*rex: play/shell*<2>")))
        (let ((buffer (portal-rex-block-buffer connection (concat "block:" (car block)))))
          (should (equal (buffer-name buffer) (nth 2 block)))
          (with-current-buffer buffer
            (should (eq portal-rex-block-connection connection))
            (should (equal portal-rex-block-id (concat "block:" (car block))))
            (should (equal portal-rex-session-id (nth 1 block))))))
      (should-not (portal-rex-block-buffer connection "block:none"))
      (with-current-buffer "*rex: work/api*"
        (should (equal (portal-rex-session-label) "work"))
        ;; It says which block it is, and that its screen comes when shown.
        (should (string-match-p "\\`Rex block api, in session work\\.\nblock:1 on the server at "
                                (buffer-string)))
        (should (string-search "once a window shows this buffer" (buffer-string)))
        ;; Killing it ends its block, after the server says whether it is busy.
        (should (memq #'portal-rex--kill-query kill-buffer-query-functions))
        (should (eq portal-terminal--closer #'portal-rex--close))
        (should buffer-read-only)
        (should-not (buffer-modified-p))
        (should (equal default-directory (expand-file-name "~/"))))
      (should-not (portal-rex-session-label (get-buffer-create "*scratch*"))))))

(ert-deftest portal-rex-buffer-is-a-terminal-before-its-view-opens ()
  ;; The mode is the one a terminal view lives in, and Portal's terminal
  ;; commands take the buffer for a terminal whose details are not known
  ;; yet: its view, and with it the block's details, come once a window
  ;; shows it.
  (portal-rex-tests--with (server)
    (let* ((connection (portal-rex-tests--connect server))
           (buffer (portal-rex-block-buffer connection "block:fake-1")))
      (should (equal (buffer-name buffer) "*rex: fake/shell*"))
      (with-current-buffer buffer
        (should (eq major-mode 'portal-terminal-mode))
        (should-not portal-view--target)
        (should (equal (portal-terminal-metadata)
                       '(:name "*rex: fake/shell*" :project nil :directory nil :title nil
                         :program nil :progress nil :exited nil :quick nil)))
        (should (memq buffer (portal-terminal-buffers)))
        (should-not (memq buffer (portal-terminal-buffers default-directory)))
        (should-not (memq buffer (portal-view-buffers)))
        (should-not portal-rex-block-directory)
        ;; No window shows it, so it has no view to focus.
        (should-error (portal-terminal-focus) :type 'user-error)
        (should-error (portal-input-focus) :type 'user-error)
        ;; It can belong to a project, and to none.
        (let ((root (file-name-as-directory (make-temp-file "rex-project" t))))
          (unwind-protect
              (progn
                (make-directory (expand-file-name ".git" root))
                (let ((inhibit-message t)) (portal-terminal-set-project root))
                (should (equal (plist-get (portal-terminal-metadata) :project)
                               (file-truename root)))
                (should (memq buffer (portal-terminal-buffers root)))
                (let ((inhibit-message t)) (portal-terminal-set-project nil))
                (should-not (plist-get (portal-terminal-metadata) :project)))
            (delete-directory root t)))
        ;; Its candidate has no directory yet, and no program to annotate.
        (should (string-prefix-p "*rex: fake/shell*  -"
                                 (substring-no-properties
                                  (caar (portal-terminal--candidates (list buffer))))))
        (should-not (portal-terminal--annotation buffer))
        ;; Its own question is the block's, not a local terminal's.
        (should (portal-terminal--kill-query))
        ;; Closing the terminal ends the block, asking first as killing the
        ;; buffer does: the fake says nothing of its program, so it may be
        ;; busy.  Kept, it stays.
        (should (equal (portal-rex-tests--asking '(nil) (portal-terminal-close))
                       '("Rex block fake/shell may be busy; end it? ")))
        (should (buffer-live-p buffer))
        ;; Another mode leaves it the block's buffer, but not a terminal.
        (fundamental-mode)
        (should (equal portal-rex-block-id "block:fake-1"))
        (should (eq portal-rex-block-connection connection))
        (should-not (portal-terminal-metadata))
        (should-not (memq buffer (portal-terminal-buffers))))
      (portal-rex-disconnect connection)
      (should-not (buffer-live-p buffer)))))

(ert-deftest portal-rex-buffer-takes-its-blocks-details-as-a-terminals ()
  ;; The native module describes the block's details as a terminal's; the
  ;; graphical suite drives them from the fake server's events.  Here the
  ;; description is given.
  (portal-rex-tests--with (server)
    (let* ((connection (portal-rex-tests--connect server))
           (buffer (portal-rex-block-buffer connection "block:fake-1"))
           (directory (file-name-as-directory (file-truename (make-temp-file "rex-block" t))))
           (state (list :title "vim notes" :pwd (directory-file-name directory)
                        :program "vim" :exited nil
                        :rex (list :state "live" :directory (directory-file-name directory)))))
      (unwind-protect
          (with-current-buffer buffer
            (setq portal-view--target "terminal:99")
            (cl-letf (((symbol-function 'portal--inspect) (lambda (_target) state)))
              (portal-terminal--changed "terminal:99"))
            (should (equal (portal-terminal-metadata)
                           (list :name "*rex: fake/shell*" :project nil :directory directory
                                 :title "vim notes" :program "vim" :progress nil
                                 :exited nil :quick nil)))
            ;; A directory of this Mac becomes the buffer's, and the block's.
            (should (equal default-directory directory))
            (should (equal portal-rex-block-directory (directory-file-name directory)))
            (should (equal (portal-terminal--annotation buffer)
                           (propertize "  vim" 'face 'completions-annotations)))
            ;; Once its view closes, what it reported goes stale, but for
            ;; its directory.
            (setq portal-view--target nil)
            (run-hooks 'portal-view-close-hook)
            (should (equal (portal-terminal-metadata)
                           (list :name "*rex: fake/shell*" :project nil :directory directory
                                 :title nil :program nil :progress nil :exited nil :quick nil))))
        (delete-directory directory t)))))

(ert-deftest portal-rex-buffers-follow-blocks ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
    (let* ((connection (portal-rex-tests--connect server))
           (first (portal-rex-block-buffer connection "block:1"))
           (refuse (lambda () (not portal-rex-block-id)))
           second)
      (should (equal (portal-rex-tests--asked server connection)
                     '("session.attach_all" "session.list_blocks")))
      ;; A block made elsewhere gets a buffer.  Its event has only its ID, so
      ;; the session is asked for its blocks.
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                                (portal-rex-tests--block "2" "shell" "detached"))
      (portal-rex-tests--session-event server "a" "block_created" :block_id "block:2")
      (portal-rex-tests--until connection
                               (lambda () (portal-rex-block-buffer connection "block:2")))
      (setq second (portal-rex-block-buffer connection "block:2"))
      (should (equal (portal-rex-tests--names) '("*rex: work/api*" "*rex: work/shell*")))
      (with-current-buffer second
        (should (eq portal-rex-block-connection connection))
        (should (equal portal-rex-block-id "block:2"))
        (should (equal portal-rex-session-id "session:a")))
      ;; A new label arrives as a change of the session's view.  The buffer
      ;; is renamed, and is the same buffer.
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "server")
                                (portal-rex-tests--block "2" "shell" "detached"))
      (portal-rex-tests--session-event server "a" "session_view_changed" :revision 2)
      (portal-rex-tests--until connection
                               (lambda () (equal (buffer-name first) "*rex: work/server*")))
      (should (eq (portal-rex-block-buffer connection "block:1") first))
      (should (string-match-p "\\`Rex block server, in session work\\."
                              (with-current-buffer first (buffer-string))))
      (with-current-buffer first
        (should (eq portal-rex-block-connection connection))
        (should (equal portal-rex-block-id "block:1"))
        (should (equal portal-rex-session-id "session:a")))
      (should (equal (buffer-name second) "*rex: work/shell*"))
      ;; A name another buffer has is made unique.
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "shell")
                                (portal-rex-tests--block "2" "shell" "detached"))
      (portal-rex-tests--session-event server "a" "session_view_changed" :revision 3)
      (portal-rex-tests--until connection
                               (lambda () (equal (buffer-name first) "*rex: work/shell*<2>")))
      ;; A view that changes without a label changing renames nothing.
      (portal-rex-tests--session-event server "a" "session_view_changed" :revision 4)
      (portal-rex-tests--settle connection)
      (should (equal (portal-rex-tests--names) '("*rex: work/shell*" "*rex: work/shell*<2>")))
      ;; Events that are not about blocks or labels ask the server nothing.
      (portal-rex-tests--asked server connection)
      (portal-rex-tests--session-event server "a" "window_created" :window_id "window:1")
      (portal-rex-tests--session-event server "a" "client_connected" :client_id "client:1")
      (portal-fake-rex-command server :event '(:type "tailscale_status_changed"))
      (should-not (portal-rex-tests--asked server connection))
      ;; A closed block's buffer is killed.  Nothing asks, whatever would,
      ;; and the server is told nothing.
      (let ((kill-buffer-query-functions (list refuse)))
        (should-not (kill-buffer second))
        (portal-rex-tests--session-event server "a" "block_closed" :block_id "block:2")
        (portal-rex-tests--until connection (lambda () (not (buffer-live-p second)))))
      (should (equal (portal-rex-tests--names) '("*rex: work/shell*<2>")))
      (should-not (portal-rex-block-buffer connection "block:2"))
      (should-not (portal-rex-tests--asked server connection))
      ;; A block that the server no longer lists has closed, whether or not
      ;; its event came.
      (portal-rex-tests--blocks server "a")
      (portal-rex-tests--session-event server "a" "session_view_changed" :revision 5)
      (portal-rex-tests--until connection (lambda () (not (buffer-live-p first))))
      (should-not (portal-rex-buffers))
      ;; Events for blocks and sessions it never heard of harm nothing.
      (portal-rex-tests--session-event server "a" "block_closed" :block_id "block:nine")
      (portal-rex-tests--session-event server "zz" "block_created" :block_id "block:ten")
      (portal-rex-tests--session-event server "zz" "session_label_changed" :label "new")
      (portal-fake-rex-command server :event '(:type "session_destroyed"
                                               :payload (:session_id "session:zz")))
      (portal-rex-tests--settle connection)
      (should-not (portal-rex-buffers))
      (should (equal (portal-rex-connection-sessions connection)
                     [(:session_id "session:a" :label "work")])))))

(ert-deftest portal-rex-buffers-and-sessions-follow-sessions ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                              (portal-rex-tests--block "2" "shell"))
    (let* ((connection (portal-rex-tests--connect server))
           (api (portal-rex-block-buffer connection "block:1"))
           seen
           (portal-rex-event-functions
            (list (lambda (from event)
                    ;; The hook finds the sessions as the event left them.
                    (push (list (plist-get (plist-get event :payload) :type)
                                (mapcar (lambda (session) (plist-get session :label))
                                        (portal-rex-connection-sessions from)))
                          seen)))))
      ;; A new session joins the connection's sessions, and its blocks get
      ;; buffers, though no event names them.
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                                 (:session_id "session:b" :label "play")])
      (portal-rex-tests--blocks server "b" (portal-rex-tests--block "3" "shell"))
      (portal-fake-rex-command server :event '(:type "session_created"
                                               :payload (:session (:session_id "session:b"
                                                                   :label "play"))))
      (portal-rex-tests--until connection
                               (lambda () (portal-rex-block-buffer connection "block:3")))
      (should (equal (portal-rex-connection-sessions connection)
                     [(:session_id "session:a" :label "work")
                      (:session_id "session:b" :label "play")]))
      (should (equal (portal-rex-tests--names connection "b") '("*rex: play/shell*")))
      (with-current-buffer "*rex: play/shell*"
        (should (equal portal-rex-session-id "session:b")))
      ;; A renamed session renames its buffers, and no other's.
      (portal-rex-tests--session-event server "a" "session_label_changed" :label "play")
      (portal-rex-tests--until connection
                               (lambda () (equal (buffer-name api) "*rex: play/api*")))
      (should (equal (portal-rex-connection-sessions connection)
                     [(:session_id "session:a" :label "play")
                      (:session_id "session:b" :label "play")]))
      (should (equal (portal-rex-tests--names connection "a")
                     '("*rex: play/api*" "*rex: play/shell*<2>")))
      (should (equal (portal-rex-tests--names connection "b") '("*rex: play/shell*")))
      (with-current-buffer api
        (should (equal (portal-rex-session-label) "play"))
        (should (string-match-p "\\`Rex block api, in session play\\." (buffer-string)))
        (should (equal portal-rex-session-id "session:a")))
      ;; A moved session moves in the connection's sessions.
      (portal-fake-rex-command server :event '(:type "session_moved"
                                               :payload (:session_id "session:b"
                                                         :before_session_id "session:a")))
      (portal-rex-tests--settle connection)
      (should (equal (mapcar (lambda (session) (plist-get session :session_id))
                             (portal-rex-connection-sessions connection))
                     '("session:b" "session:a")))
      (portal-fake-rex-command server :event '(:type "session_moved"
                                               :payload (:session_id "session:b")))
      (portal-rex-tests--settle connection)
      (should (equal (mapcar (lambda (session) (plist-get session :session_id))
                             (portal-rex-connection-sessions connection))
                     '("session:a" "session:b")))
      ;; A destroyed session takes its buffers with it, and asks nothing.
      (portal-rex-tests--asked server connection)
      (portal-fake-rex-command server :event '(:type "session_destroyed"
                                               :payload (:session_id "session:a")))
      (portal-rex-tests--until connection (lambda () (not (buffer-live-p api))))
      (should (equal (portal-rex-tests--names) '("*rex: play/shell*")))
      (should (equal (portal-rex-connection-sessions connection)
                     [(:session_id "session:b" :label "play")]))
      (should-not (portal-rex-tests--asked server connection))
      (should (equal (reverse seen)
                     '(("session_created" ("work" "play")) ("session_event" ("play" "play"))
                       ("session_moved" ("play" "play")) ("session_moved" ("play" "play"))
                       ("session_destroyed" ("play"))))))))

(ert-deftest portal-rex-answers-that-are-late-make-no-buffer-for-what-has-gone ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                               (:session_id "session:b" :label "play")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
    (portal-rex-tests--blocks server "b" (portal-rex-tests--block "9" "shell"))
    (let ((connection (portal-rex-tests--connect server)))
      (portal-rex-tests--asked server connection)
      ;; A block made and closed while the server is asked: the answer, from
      ;; before it closed, lists it, and it gets no buffer.
      (portal-fake-rex-command server :hold "session.list_blocks")
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                                (portal-rex-tests--block "2" "gone")
                                (portal-rex-tests--block "3" "stays"))
      (portal-rex-tests--session-event server "a" "block_created" :block_id "block:2")
      (portal-rex-call connection "server.version")
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                                (portal-rex-tests--block "3" "stays"))
      (portal-rex-tests--session-event server "a" "block_closed" :block_id "block:2")
      (portal-rex-call connection "server.version")
      (portal-fake-rex-command server :release "session.list_blocks")
      (portal-rex-tests--settle connection)
      (should (equal (portal-rex-tests--names connection "a")
                     '("*rex: work/api*" "*rex: work/stays*")))
      ;; No second answer put that right: the server was asked once.
      (should (equal (portal-rex-tests--asked server connection) '("session.list_blocks")))
      ;; A label that changes while the server is asked is the one that
      ;; stays, and one question is out for a session at a time: however
      ;; many changes there were, it is asked once more when the answer comes.
      (portal-fake-rex-command server :hold "session.list_blocks")
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "second")
                                (portal-rex-tests--block "3" "stays"))
      (portal-rex-tests--session-event server "a" "session_view_changed" :revision 2)
      (portal-rex-call connection "server.version")
      (dolist (label '("third" "fourth" "fifth"))
        (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" label)
                                  (portal-rex-tests--block "3" "stays"))
        (portal-rex-tests--session-event server "a" "session_view_changed" :revision 3))
      (portal-rex-call connection "server.version")
      (portal-fake-rex-command server :release "session.list_blocks")
      (portal-rex-tests--settle connection)
      (should (equal (portal-rex-tests--names connection "a")
                     '("*rex: work/fifth*" "*rex: work/stays*")))
      (should (equal (portal-rex-tests--asked server connection)
                     '("session.list_blocks" "session.list_blocks")))
      ;; A session destroyed while the server is asked: the answer makes
      ;; nothing, and neither does one that says the session is not there.
      (portal-fake-rex-command server :hold "session.list_blocks")
      (portal-rex-tests--blocks server "b" (portal-rex-tests--block "9" "shell")
                                (portal-rex-tests--block "8" "late"))
      (portal-rex-tests--session-event server "b" "block_created" :block_id "block:8")
      (portal-rex-call connection "server.version")
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
      (portal-fake-rex-command server :event '(:type "session_destroyed"
                                               :payload (:session_id "session:b")))
      (portal-rex-call connection "server.version")
      (portal-fake-rex-command server :release "session.list_blocks")
      (portal-rex-tests--settle connection)
      (should (equal (portal-rex-tests--names)
                     '("*rex: work/fifth*" "*rex: work/stays*")))
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                                 (:session_id "session:c" :label "brief")])
      (portal-fake-rex-command server :event '(:type "session_created"
                                               :payload (:session (:session_id "session:c"
                                                                   :label "brief"))))
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
      (should-not (string-search "Cannot list"
                                 (portal-rex-tests--messages
                                   (portal-rex-tests--settle connection))))
      ;; Any other failure is said, and the connection carries on.
      (portal-fake-rex-command server :error "session.list_blocks" :code "internal"
                               :message "out of sorts" :status 500)
      (portal-rex-tests--session-event server "a" "session_view_changed" :revision 4)
      (should (equal (portal-rex-tests--messages (portal-rex-tests--settle connection))
                     "Cannot list the blocks of Rex session work: out of sorts\n"))
      (should (portal-rex-live-p connection))
      (should (equal (portal-rex-tests--names)
                     '("*rex: work/fifth*" "*rex: work/stays*"))))))

(ert-deftest portal-rex-disconnecting-kills-the-buffers-and-ends-nothing ()
  (portal-rex-tests--with (left right)
    (portal-fake-rex-command left :sessions [(:session_id "session:l" :label "left")])
    (portal-rex-tests--blocks left "l" (portal-rex-tests--block "1" "one")
                              (portal-rex-tests--block "2" "two"))
    (portal-fake-rex-command right :sessions [(:session_id "session:r" :label "right")])
    (portal-rex-tests--blocks right "r" (portal-rex-tests--block "1" "one"))
    (let* ((first (portal-rex-tests--connect left))
           (second (portal-rex-tests--connect right))
           (refuse (lambda () (not portal-rex-block-id)))
           (requests (lambda (server)
                       (mapcar (lambda (report)
                                 (plist-get (plist-get report :request) :method))
                               (cl-remove-if-not (lambda (report) (plist-member report :request))
                                                 (portal-fake-rex-reports server))))))
      ;; Two servers may both have a block:1.
      (should (equal (portal-rex-tests--names first) '("*rex: left/one*" "*rex: left/two*")))
      (should (equal (portal-rex-tests--names second) '("*rex: right/one*")))
      (should-not (eq (portal-rex-block-buffer first "block:1")
                      (portal-rex-block-buffer second "block:1")))
      ;; Disconnecting kills that connection's buffers, without asking, and
      ;; asks the server for nothing.
      (let ((kill-buffer-query-functions (list refuse)))
        (portal-rex-disconnect first))
      (should-not (portal-rex-buffers first))
      (should (equal (portal-rex-tests--names) '("*rex: right/one*")))
      (portal-fake-rex-take left :disconnected)
      (should (equal (funcall requests left) '("session.attach_all" "session.list_blocks")))
      ;; So does losing the connection.
      (portal-fake-rex-command right :drop t)
      (let ((inhibit-message t)
            (kill-buffer-query-functions (list refuse)))
        (portal-rex-tests--until second
                                 (lambda () (not (portal-rex-connection-id second)))))
      (should-not (portal-rex-buffers))
      (should-not (get-buffer "*rex: right/one*"))
      (portal-fake-rex-take right :disconnected)
      (should (equal (funcall requests right) '("session.attach_all" "session.list_blocks")))
      ;; Connecting again makes them again.
      (let ((again (portal-rex-tests--connect left)))
        (should (equal (portal-rex-tests--names again)
                       '("*rex: left/one*" "*rex: left/two*")))))))

(ert-deftest portal-rex-killing-a-buffer-asking-nothing-leaves-its-block ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                              (portal-rex-tests--block "2" "logs"))
    (let* ((connection (portal-rex-tests--connect server))
           (buffer (portal-rex-block-buffer connection "block:1")))
      (portal-rex-tests--asked server connection)
      ;; A kill that runs no question, as when a caller binds the questions
      ;; away, cannot know the block is idle: it only kills the buffer, and
      ;; says so.
      (should (equal (portal-rex-tests--messages
                       (with-current-buffer buffer
                         (let ((kill-buffer-query-functions nil))
                           (should (kill-buffer buffer)))))
                     "Killed only the buffer: block api still runs on its Rex server, and gets a buffer again when Emacs next connects\n"))
      (should-not (portal-rex-block-buffer connection "block:1"))
      (should-not (portal-rex-tests--asked server connection))
      ;; The block gets no second buffer while Emacs stays connected.
      (portal-rex-tests--session-event server "a" "session_view_changed" :revision 2)
      (portal-rex-tests--settle connection)
      (should (equal (portal-rex-tests--names) '("*rex: work/logs*")))
      ;; Its closing later is nothing.
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "2" "logs"))
      (portal-rex-tests--session-event server "a" "block_closed" :block_id "block:1")
      (portal-rex-tests--settle connection)
      (should (equal (portal-rex-tests--names) '("*rex: work/logs*")))
      ;; Portal's own kills say nothing.
      (should (equal (portal-rex-tests--messages
                       (portal-rex-tests--session-event server "a" "block_closed"
                                                        :block_id "block:2")
                       (portal-rex-tests--settle connection))
                     ""))
      (should-not (portal-rex-buffers))
      ;; The next connection has a buffer for every block again.
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
      (portal-rex-disconnect connection)
      (should (equal (portal-rex-tests--names (portal-rex-tests--connect server))
                     '("*rex: work/api*"))))))

;;; Ending a block by killing its buffer

(ert-deftest portal-rex-idle-is-a-shell-at-its-prompt ()
  ;; The cases the idle spike tried (portal/rex-block-idle-detection.md in
  ;; the notes): only a block's own shell, reading with its line editor,
  ;; is idle.
  (let ((login (lambda (&rest depth) (portal-rex-tests--shell 40 depth)))
        (alone (lambda (name argv0)
                 (let ((child (list :pid 7 :user_id 501 :name name :argv0 argv0)))
                   (list :child child :foreground child :last_exit :null))))
        (raw portal-rex-tests--raw)
        (cooked portal-rex-tests--cooked)
        (pager '(:echo :false :canonical :false :signals t))
        (editor '(:echo :false :canonical :false :signals :false)))
    (dolist (case `((t ,raw ,(funcall login))
                    ;; A shell with jobs, which neither reply shows.
                    (t ,raw ,(funcall login))
                    ;; A login shell started with no login above it.
                    (t ,raw ,(funcall alone "zsh" "-zsh"))
                    ;; A program, or the shell busy with its own code.
                    (nil ,cooked ,(funcall login '("sleep" "sleep")))
                    (nil ,cooked ,(funcall login))
                    (nil ,editor ,(funcall login '("vim" "vim")))
                    (nil ,pager ,(funcall login '("git" "git") '("less" "less")))
                    ;; A nested shell and a subshell, deeper than the shell.
                    (nil ,raw ,(funcall login '("zsh" "/bin/zsh")))
                    (nil ,cooked ,(funcall login '("zsh" "-zsh")))
                    ;; A program the shell exec'd: login in the foreground.
                    (nil ,cooked ,(let ((reply (funcall login)))
                                    (plist-put (plist-put reply :foreground (plist-get reply :child))
                                               :ancestors nil)))
                    ;; A block started with a command, and a shell not a login one.
                    (nil ,editor ,(funcall alone "nvim" "nvim"))
                    (nil ,raw ,(funcall alone "zsh" "zsh"))
                    ;; A block starting, or between programs: no foreground.
                    (nil ,raw (:child (:pid 3 :user_id 0 :name "login") :foreground :null
                               :last_exit :null))
                    (nil ,raw (:child :null :foreground :null :last_exit :null))
                    ;; Replies without what the test needs.
                    (nil nil ,(funcall login))
                    (nil ,raw nil)))
      (should (eq (and (portal-rex--idle-p (nth 1 case) (nth 2 case)) t) (car case)))))
  ;; A program is named as Rex labels it.
  (should (equal (portal-rex--program (portal-rex-tests--shell 40)) "zsh"))
  (should (equal (portal-rex--program (portal-rex-tests--shell 40 '(("vim" "/usr/bin/vim"))))
                 "vim"))
  (should (equal (portal-rex--program (portal-rex-tests--shell
                                       40 '(("node" "node" :script "/work/agent.js"))))
                 "agent.js"))
  ;; Root's login, in the foreground while a block starts or for a program
  ;; the shell exec'd, names nothing.
  (should-not (portal-rex--program '(:foreground (:pid 1 :user_id 0 :name "login"))))
  (should (equal (portal-rex--program '(:foreground (:pid 1 :user_id 501 :name "login"))) "login"))
  (should-not (portal-rex--program '(:foreground :null))))

(ert-deftest portal-rex-killing-an-idle-blocks-buffer-ends-it ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a"
                              (append (portal-rex-tests--block "1" "api") '(:window_id "window:1"))
                              (portal-rex-tests--block "2" "logs")
                              (portal-rex-tests--block "3" "done"))
    (let* ((connection (portal-rex-tests--connect server))
           (api (portal-rex-block-buffer connection "block:1"))
           (done (portal-rex-block-buffer connection "block:3"))
           (blocks (portal-rex-connection-blocks connection)))
      (portal-rex-tests--idle server "block:1")
      (portal-rex-tests--asked server connection)
      ;; At its prompt, it ends at once: no question, and nothing said.
      (should (equal (portal-rex-tests--messages
                       (should-not (portal-rex-tests--asking nil (should (kill-buffer api)))))
                     ""))
      (should-not (buffer-live-p api))
      (should (equal (portal-rex-tests--request server "block.close")
                     '(:session_id "session:a" :block_id "block:1")))
      ;; Its block_closed, and the change to the session's windows, find
      ;; nothing to do.
      (portal-rex-tests--until connection (lambda () (not (gethash "block:1" blocks))))
      (portal-rex-tests--settle connection)
      (should (equal (portal-rex-tests--names) '("*rex: work/done*" "*rex: work/logs*")))
      (should (equal (portal-rex-tests--asked server connection)
                     (append portal-rex-tests--asks '("session.list_blocks"))))
      ;; A block whose program has exited ends without a question too, the
      ;; option set to always ask included.
      (portal-rex-tests--terminal server "block:3" portal-rex-tests--cooked
                                  '(:child :null :foreground :null :last_exit (:exit_code 0)))
      (let ((portal-terminal-confirm-kill 'always))
        (should-not (portal-rex-tests--asking nil (should (kill-buffer done)))))
      (should (equal (portal-rex-tests--request server "block.close")
                     '(:session_id "session:a" :block_id "block:3")))
      (portal-rex-tests--until connection (lambda () (not (gethash "block:3" blocks))))
      (should (equal (portal-rex-tests--names) '("*rex: work/logs*"))))))

(ert-deftest portal-rex-killing-a-busy-blocks-buffer-asks-first ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                              (portal-rex-tests--block "2" "agent"))
    (let* ((connection (portal-rex-tests--connect server))
           (api (portal-rex-block-buffer connection "block:1"))
           (agent (portal-rex-block-buffer connection "block:2")))
      (portal-rex-tests--sleeping server "block:1")
      (portal-rex-tests--terminal server "block:2" '(:echo :false :canonical :false :signals :false)
                                  (portal-rex-tests--shell
                                   40 '(("node" "node" :script "/work/agent.js"))))
      (portal-rex-tests--asked server connection)
      ;; Asked, naming the block and its program; no keeps both.
      (should (equal (portal-rex-tests--asking '(nil) (should-not (kill-buffer api)))
                     '("Rex block work/api is running sleep; end it? ")))
      (should (buffer-live-p api))
      (should (equal (portal-rex-tests--asked server connection) portal-rex-tests--asks))
      ;; Yes ends it.
      (should (equal (portal-rex-tests--asking '(t) (should (kill-buffer api)))
                     '("Rex block work/api is running sleep; end it? ")))
      (should-not (buffer-live-p api))
      (should (equal (portal-rex-tests--asked server connection)
                     (append portal-rex-tests--asks '("block.close"))))
      ;; An agent is named by its script.
      (should (equal (portal-rex-tests--asking '(nil) (kill-buffer agent))
                     '("Rex block work/agent is running agent.js; end it? ")))
      (should (buffer-live-p agent)))))

(ert-deftest portal-rex-killing-asks-when-the-server-cannot-say ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
    (let* ((connection (portal-rex-tests--connect server))
           (api (portal-rex-block-buffer connection "block:1"))
           (portal-rex--busy-timeout 0.2))
      (portal-rex-tests--idle server "block:1")
      (portal-rex-tests--asked server connection)
      ;; No answer in time: it may be busy, so it asks, saying why, after
      ;; waiting no longer than the timeout.
      (portal-fake-rex-command server :silent "com.superlogical.terminal.process")
      (let ((start (float-time)))
        (should (equal (portal-rex-tests--asking '(nil) (should-not (kill-buffer api)))
                       '("Rex block work/api may be busy (no answer within 0.2 seconds); end it? ")))
        (should (< (- (float-time) start) 1)))
      (should (buffer-live-p api))
      ;; The answer that comes too late is forgotten.
      (should-not (portal-rex-connection-calls connection))
      (should (equal (portal-rex-tests--asked server connection) portal-rex-tests--asks))
      ;; An error: the same, in the server's words.
      (portal-fake-rex-command server :result "com.superlogical.terminal.process"
                               :payload (portal-rex-tests--shell 40))
      (portal-fake-rex-command server :error "com.superlogical.terminal.input_mode"
                               :code "method_not_found" :message "no handler for input_mode"
                               :status 404)
      (should (equal (portal-rex-tests--asking '(nil) (should-not (kill-buffer api)))
                     '("Rex block work/api is running zsh; end it? ")))
      ;; Named, when the process is known; otherwise by the error.
      (portal-fake-rex-command server :error "com.superlogical.terminal.process"
                               :code "not_found" :message "block is gone" :status 404)
      (should (equal (portal-rex-tests--asking '(nil) (should-not (kill-buffer api)))
                     '("Rex block work/api may be busy (no handler for input_mode); end it? ")))
      (should (buffer-live-p api))
      (should (equal (portal-rex-tests--asked server connection)
                     (append portal-rex-tests--asks portal-rex-tests--asks)))
      ;; Yes ends it all the same.
      (portal-rex-tests--asking '(t) (should (kill-buffer api)))
      (should (equal (portal-rex-tests--request server "block.close")
                     '(:session_id "session:a" :block_id "block:1"))))))

(ert-deftest portal-rex-killing-follows-the-option ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "idle")
                              (portal-rex-tests--block "2" "busy"))
    (let* ((connection (portal-rex-tests--connect server))
           (idle (portal-rex-block-buffer connection "block:1"))
           (busy (portal-rex-block-buffer connection "block:2")))
      (portal-rex-tests--idle server "block:1")
      (portal-rex-tests--sleeping server "block:2")
      (portal-rex-tests--asked server connection)
      ;; always: an idle block asks too.
      (let ((portal-terminal-confirm-kill 'always))
        (should (equal (portal-rex-tests--asking '(nil) (should-not (kill-buffer idle)))
                       '("End Rex block work/idle, zsh at its prompt? ")))
        (should (equal (portal-rex-tests--asking '(nil) (should-not (kill-buffer busy)))
                       '("Rex block work/busy is running sleep; end it? "))))
      (should (equal (portal-rex-tests--asked server connection)
                     (append portal-rex-tests--asks portal-rex-tests--asks)))
      ;; nil: nothing asks, and the server is not asked whether it is busy.
      (let ((portal-terminal-confirm-kill nil))
        (should-not (portal-rex-tests--asking nil (should (kill-buffer busy)))))
      (should (equal (portal-rex-tests--asked server connection) '("block.close")))
      (should-not (buffer-live-p busy)))))

(ert-deftest portal-rex-killing-ends-nothing-once-the-server-goes ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
    ;; The server goes while Emacs waits for it to say whether the block is
    ;; busy: the kill returns, and the buffer has gone with its server.
    (let* ((connection (portal-rex-tests--connect server))
           (api (portal-rex-block-buffer connection "block:1"))
           (portal-rex--busy-timeout 2)
           (start (float-time)))
      (portal-fake-rex-command server :hold "com.superlogical.terminal.process")
      (portal-fake-rex-command server :after "com.superlogical.terminal.process"
                               :then [(:drop t)])
      (should (string-match-p
               "\\`Lost the Rex server at .*\n\\'"
               (portal-rex-tests--messages
                 (should-not (portal-rex-tests--asking nil (should-not (kill-buffer api)))))))
      (should (< (- (float-time) start) 1.5))
      (should-not (buffer-live-p api))
      (should-not (portal-rex-live-p connection)))
    ;; It goes while the question waits for an answer: yes ends nothing,
    ;; as there is no buffer left and no server to tell.
    (portal-fake-rex-command server :release "com.superlogical.terminal.process")
    (portal-fake-rex-take server :disconnected)
    (let* ((connection (portal-rex-tests--connect server))
           (api (portal-rex-block-buffer connection "block:1")))
      (portal-rex-tests--sleeping server "block:1")
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_prompt)
                   (portal-fake-rex-command server :drop t)
                   (let ((inhibit-message t))
                     (portal-rex-tests--until
                      connection (lambda () (not (portal-rex-connection-id connection)))))
                   t)))
        (should-not (kill-buffer api)))
      (should-not (buffer-live-p api))
      (portal-fake-rex-take server :disconnected)
      (should-not (cl-find-if (lambda (report)
                                (equal (plist-get (plist-get report :request) :method) "block.close"))
                              (portal-fake-rex-reports server))))
    ;; A server that takes the end and never answers costs no wait.
    (portal-fake-rex-command server :silent "block.close")
    (let* ((connection (portal-rex-tests--connect server))
           (api (portal-rex-block-buffer connection "block:1"))
           (start (float-time)))
      (portal-rex-tests--idle server "block:1")
      (should (kill-buffer api))
      (should (< (- (float-time) start) 1))
      (should (equal (portal-rex-tests--request server "block.close")
                     '(:session_id "session:a" :block_id "block:1")))
      ;; Disconnecting before it answers leaves the end in doubt, and says so.
      (should (equal (portal-rex-tests--messages (portal-rex-disconnect connection))
                     "Rex block api may still run: the connection ended before the server said it had closed it\n")))
    ;; One that refuses it says so, and the block keeps running.  (The
    ;; silent close above closed the block, as a server that never answers
    ;; might.)
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
    (portal-fake-rex-command server :error "block.close" :code "conflict"
                             :message "the block is busy placing" :status 409)
    (let* ((connection (portal-rex-tests--connect server))
           (api (portal-rex-block-buffer connection "block:1")))
      (should api)
      (should (equal (portal-rex-tests--messages
                       (should (kill-buffer api))
                       (portal-rex-tests--settle connection))
                     "Cannot end Rex block api: the block is busy placing; it still runs, and gets a buffer again when Emacs next connects\n")))))

(ert-deftest portal-rex-kills-the-server-makes-end-nothing ()
  ;; The buffers Portal kills because a block, a session or a server went
  ;; ask nothing and end nothing, whatever the option says.
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                               (:session_id "session:b" :label "play")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "closed")
                              (portal-rex-tests--block "2" "unlisted")
                              (portal-rex-tests--block "3" "kept"))
    (portal-rex-tests--blocks server "b" (portal-rex-tests--block "4" "destroyed"))
    (dolist (block '("block:1" "block:2" "block:3" "block:4"))
      (portal-rex-tests--sleeping server block))
    (let ((portal-terminal-confirm-kill 'always)
          (connection (portal-rex-tests--connect server)))
      (portal-rex-tests--asked server connection)
      (should-not
       (portal-rex-tests--asking nil
         (portal-rex-tests--session-event server "a" "block_closed" :block_id "block:1")
         (portal-rex-tests--blocks server "a" (portal-rex-tests--block "3" "kept"))
         (portal-rex-tests--session-event server "a" "session_view_changed" :revision 2)
         (portal-fake-rex-command server :event '(:type "session_destroyed"
                                                  :payload (:session_id "session:b")))
         (portal-rex-tests--settle connection)
         (should (equal (portal-rex-tests--names) '("*rex: work/kept*")))
         (portal-rex-disconnect connection)
         (should-not (portal-rex-buffers))
         ;; A lost connection too.
         (setq connection (portal-rex-tests--connect server))
         (portal-fake-rex-command server :drop t)
         (let ((inhibit-message t))
           (portal-rex-tests--until connection
                                    (lambda () (not (portal-rex-connection-id connection)))))
         (should-not (portal-rex-buffers))))
      (should-not (cl-intersection (cons "block.close" portal-rex-tests--asks)
                                   (mapcar (lambda (report)
                                             (plist-get (plist-get report :request) :method))
                                           (portal-fake-rex-reports server))
                                   :test #'equal)))))

(ert-deftest portal-rex-every-way-of-killing-asks-the-same ()
  (require 'ibuf-ext)
  (require 'portal-terminal-embark)
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "one")
                              (portal-rex-tests--block "2" "two")
                              (portal-rex-tests--block "3" "three")
                              (portal-rex-tests--block "4" "four"))
    (let* ((connection (portal-rex-tests--connect server))
           (buffers (mapcar (lambda (n) (portal-rex-block-buffer connection (format "block:%d" n)))
                            '(1 2 3 4)))
           (ask (lambda (name) (format "Rex block work/%s is running sleep; end it? " name)))
           ;; The blocks it was asked to close since last asked, sorted.
           (closed (lambda ()
                     (portal-rex-tests--settle connection)
                     (let (ids)
                       (while (cl-find-if (lambda (report)
                                            (equal (plist-get (plist-get report :request) :method)
                                                   "block.close"))
                                          (progn (portal-fake-rex-command server :fragment 0)
                                                 (portal-fake-rex-reports server)))
                         (push (plist-get (plist-get (portal-fake-rex-request server "block.close")
                                                     :payload)
                                          :block_id)
                               ids))
                       (sort ids #'string<)))))
      (dolist (block '("block:1" "block:2" "block:3" "block:4"))
        (portal-rex-tests--sleeping server block))
      ;; Each command asks, naming its block, and no keeps it.
      (save-window-excursion
        (switch-to-buffer (nth 0 buffers))
        (should (equal (portal-rex-tests--asking '(nil) (portal-terminal-close))
                       (list (funcall ask "one"))))
        (should (equal (portal-rex-tests--asking '(nil) (portal-terminal-kill-pane))
                       (list (funcall ask "one"))))
        (should (equal (portal-rex-tests--asking '(nil)
                         (portal-terminal-embark-kill (buffer-name (nth 0 buffers))))
                       (list (funcall ask "one")))))
      (should (cl-every #'buffer-live-p buffers))
      (should-not (funcall closed))
      ;; Several at once, as Ibuffer kills its marked buffers, ask about
      ;; each busy one by name; an idle one ends without a question.
      (portal-rex-tests--idle server "block:4")
      (save-window-excursion
        (ibuffer nil "*portal-rex-ibuffer*")
        (unwind-protect
            (let ((ibuffer-expert t))
              (ibuffer-mark-on-buffer (lambda (buffer) (memq buffer (cdr buffers))) ?D)
              (should (equal (portal-rex-tests--asking '(t nil)
                               (ibuffer-do-kill-on-deletion-marks))
                             (list (funcall ask "two") (funcall ask "three")))))
          (kill-buffer "*portal-rex-ibuffer*")))
      (should (equal (mapcar #'buffer-live-p buffers) '(t nil t nil)))
      (should (equal (funcall closed) '("block:2" "block:4")))
      ;; Closing every terminal: those with views, which a graphical Emacs
      ;; opens as windows show them, the same way.
      (portal-rex-tests--idle server "block:3")
      (cl-letf (((symbol-function 'portal-view-buffers)
                 (lambda (&optional _kind) (list (nth 0 buffers) (nth 2 buffers)))))
        (should (equal (portal-rex-tests--asking '(t) (portal-terminal-close-all))
                       (list (funcall ask "one")))))
      (should-not (cl-some #'buffer-live-p buffers))
      (should (equal (funcall closed) '("block:1" "block:3"))))))

(ert-deftest portal-rex-connect-does-not-wait-for-ever-for-the-blocks ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :hold "session.list_blocks")
    (let* ((portal-rex-timeout 0.3)
           (connection (portal-rex-tests--connect server)))
      ;; A server that is slow to list its blocks is connected all the same,
      ;; and the buffers come when its answer does.
      (should (portal-rex-live-p connection))
      (should-not (portal-rex-buffers))
      (portal-fake-rex-command server :release "session.list_blocks")
      (portal-rex-tests--settle connection)
      (should (equal (portal-rex-tests--names) '("*rex: fake/shell*")))
      (portal-rex-disconnect connection))
    ;; A quit while connecting waits for the blocks leaves no connection, and
    ;; no buffer.
    (portal-fake-rex-command server :hold "session.list_blocks")
    (let ((wait (symbol-function 'portal--rex-wait))
          (portal-rex-timeout 30))
      (cl-letf (((symbol-function 'portal--rex-wait)
                 (lambda (&rest arguments)
                   (when (cl-some #'portal-rex-connection-lists portal-rex--connections)
                     (setq quit-flag t))
                   (apply wait arguments))))
        (should (eq (condition-case nil (portal-rex-tests--connect server) (quit 'quit))
                    'quit))))
    (should-not portal-rex--connections)
    (should-not (portal-rex-buffers))))

(ert-deftest portal-rex-ibuffer-filters-by-session ()
  (require 'ibuf-ext)
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                               (:session_id "session:b" :label "play")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                              (portal-rex-tests--block "2" "logs"))
    (portal-rex-tests--blocks server "b" (portal-rex-tests--block "3" "shell"))
    (let ((connection (portal-rex-tests--connect server))
          (listed (lambda (filter)
                    (save-window-excursion
                      (ibuffer nil "*portal-rex-ibuffer*" (list filter))
                      (unwind-protect
                          (let (names)
                            (ibuffer-map-lines-nomodify
                             (lambda (buffer _mark) (push (buffer-name buffer) names)))
                            (sort names #'string<))
                        (kill-buffer "*portal-rex-ibuffer*"))))))
      (should (equal (funcall listed '(portal-rex-session . "work"))
                     '("*rex: work/api*" "*rex: work/logs*")))
      (should (equal (funcall listed '(portal-rex-session . "play")) '("*rex: play/shell*")))
      (should-not (funcall listed '(portal-rex-session . "none")))
      ;; The filter goes by what the session is called now.
      (portal-rex-tests--session-event server "b" "session_label_changed" :label "work")
      (portal-rex-tests--settle connection)
      (should (equal (funcall listed '(portal-rex-session . "work"))
                     '("*rex: work/api*" "*rex: work/logs*" "*rex: work/shell*")))
      ;; The command reads a label, completing over the servers' sessions.
      (should (commandp 'ibuffer-filter-by-portal-rex-session))
      (should (equal (portal-rex--session-labels) '("work"))))))

;;; Sessions and terminals from Emacs

(defmacro portal-rex-tests--answering (answers &rest body)
  "Run BODY with the minibuffer giving ANSWERS, in turn, and return what it asked.
Each answer goes to the next `read-string', `completing-read' or
`yes-or-no-p'.  The value is a list of (PROMPT CHOICES START) for each
question, in order, CHOICES being the names a completion offered and
START the text a `read-string' starts with.  As in the minibuffer, an
empty answer to `read-string' gives its default."
  (declare (indent 1))
  `(let ((answers ,answers) asked)
     (cl-letf (((symbol-function 'read-string)
                (lambda (prompt &optional initial _history default &rest _)
                  (push (list prompt nil initial) asked)
                  (let ((answer (pop answers)))
                    (if (and (equal answer "") default) default answer))))
               ((symbol-function 'completing-read)
                (lambda (prompt collection &optional _predicate _require _initial _history default
                                &rest _)
                  (push (list prompt (all-completions "" collection) default) asked)
                  (pop answers)))
               ((symbol-function 'yes-or-no-p)
                (lambda (prompt) (push (list prompt nil nil) asked) (pop answers))))
       ,@body)
     (nreverse asked)))

(defun portal-rex-tests--session-ids (connection)
  "Return the IDs of CONNECTION's sessions, in order."
  (mapcar (lambda (session) (plist-get session :session_id))
          (portal-rex-connection-sessions connection)))

(defun portal-rex-tests--request (server method)
  "Return the payload of the last request for METHOD that SERVER had.
It and those before it are taken: a later call finds only newer ones."
  ;; The server reports in order, so once it has finished a command, every
  ;; request made before has been reported.
  (portal-fake-rex-command server :fragment 0)
  (let* ((asked (lambda (report) (equal (plist-get (plist-get report :request) :method) method)))
         (last (plist-get (portal-fake-rex-request server method) :payload)))
    (while (cl-find-if asked (portal-fake-rex-reports server))
      (setq last (plist-get (portal-fake-rex-request server method) :payload)))
    last))

(ert-deftest portal-rex-fake-changes-sessions-as-a-real-server ()
  ;; The same checks run against a real server in the real-server tier.
  (portal-rex-tests--with (server)
    (portal-rex-parity-check-sessions (portal-rex-tests--connect server)
                                      temporary-file-directory)))

(ert-deftest portal-rex-session-create-makes-a-session ()
  (portal-rex-tests--with (server)
    (let* ((connection (portal-rex-tests--connect server))
           (made (portal-rex-session-create nil "work")))
      ;; Asked with the label, and known when it returns.
      (should (equal (portal-rex-tests--request server "session.create") '(:label "work")))
      (should (equal (portal-rex--session-label connection made) "work"))
      (should (equal (portal-rex-find-session connection "work") made))
      (should-not (portal-rex-buffers connection made))
      ;; Without a label, the server chooses one.
      (let ((chosen (portal-rex-session-create connection "  ")))
        (should (equal (portal-rex-tests--request server "session.create") nil))
        (should (string-prefix-p "fake-meadow-" (portal-rex--session-label connection chosen))))
      ;; Interactively, it reads the label and says what it made.
      (let (id)
        (should (equal (mapcar #'car (portal-rex-tests--answering '("play")
                                       (should (equal (portal-rex-tests--messages
                                                        (setq id (call-interactively
                                                                  #'portal-rex-session-create)))
                                                      "Created Rex session play\n"))))
                       '("New Rex session's label (empty for one the server chooses): ")))
        (should (equal (portal-rex--session-label connection id) "play")))
      ;; A refusal is the server's, in its own words.
      (portal-fake-rex-command server :error "session.create" :code "conflict"
                               :message "too many sessions" :status 409)
      (should (equal (cadr (should-error (portal-rex-session-create connection "more")
                                         :type 'user-error))
                     "Cannot create a Rex session: too many sessions"))
      (should (= (length (portal-rex-connection-sessions connection)) 4))
      ;; A session whose event is late is known all the same.
      (portal-fake-rex-command server :result "session.create"
                               :payload '(:session_id "session:quiet"))
      (let ((portal-rex-timeout 0.2))
        (should (equal (portal-rex-session-create connection "quiet") "session:quiet")))
      (should (equal (portal-rex--session-label connection "session:quiet") "quiet")))))

(ert-deftest portal-rex-session-rename-renames-its-buffers ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                               (:session_id "session:b" :label "play")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
    (portal-rex-tests--blocks server "b" (portal-rex-tests--block "2" "shell"))
    (let ((connection (portal-rex-tests--connect server)))
      (portal-rex-session-rename connection "session:a" "server")
      (should (equal (portal-rex-tests--request server "session.set_label")
                     '(:session_id "session:a" :label "server")))
      ;; The event came before the answer: renamed when it returns.
      (should (equal (portal-rex-tests--names) '("*rex: play/shell*" "*rex: server/api*")))
      ;; Interactively, from a block's buffer: its session is the default,
      ;; and its label the text to edit.
      (with-current-buffer "*rex: play/shell*"
        (should (equal (portal-rex-tests--answering '("play" "games")
                         (call-interactively #'portal-rex-session-rename))
                       '(("Rename Rex session (default play): " ("server" "play") "play")
                         ("Rename Rex session play to: " nil "play")))))
      (should (equal (portal-rex-tests--names) '("*rex: games/shell*" "*rex: server/api*")))
      ;; Elsewhere, there is no default.
      (with-temp-buffer
        (should (equal (portal-rex-tests--answering '("server" "work")
                         (call-interactively #'portal-rex-session-rename))
                       '(("Rename Rex session: " ("server" "games") nil)
                         ("Rename Rex session server to: " nil "server")))))
      (should (equal (portal-rex-tests--names) '("*rex: games/shell*" "*rex: work/api*")))
      ;; An emptied label is sent empty, which the server takes as asking
      ;; for the label it chose.
      (with-current-buffer "*rex: games/shell*"
        (portal-rex-tests--answering '("games" "")
          (call-interactively #'portal-rex-session-rename)))
      (should (equal (portal-rex-tests--request server "session.set_label")
                     '(:session_id "session:b" :label "")))
      ;; A label the server refuses.
      (should (equal (cadr (should-error (portal-rex-session-rename connection "session:a"
                                                                    (make-string 129 ?x))
                                         :type 'user-error))
                     "Cannot rename Rex session work: session.set_label: label must be at most 128 characters without control characters")))))

(ert-deftest portal-rex-session-destroy-asks-naming-the-blocks ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                               (:session_id "session:b" :label "play")
                                               (:session_id "session:c" :label "empty")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                              (portal-rex-tests--block "2" "logs"))
    (portal-rex-tests--blocks server "b" (portal-rex-tests--block "3" "shell"))
    (let ((connection (portal-rex-tests--connect server)))
      (portal-rex-tests--asked server connection)
      (with-current-buffer "*rex: work/api*"
        ;; Answered no, nothing ends: the server was only asked how many
        ;; blocks the session has.
        (should (equal (portal-rex-tests--answering '("work" nil)
                         (should-not (call-interactively #'portal-rex-session-destroy)))
                       '(("Destroy Rex session (default work): " ("work" "play" "empty") "work")
                         ("Destroy Rex session work and end its 2 blocks? " nil nil))))
        (should (equal (portal-rex-tests--asked server connection) '("session.list_blocks")))
        (should (equal (portal-rex-tests--names connection "a")
                       '("*rex: work/api*" "*rex: work/logs*")))
        ;; Answered yes, it ends, and its buffers with it, when it returns.
        (let ((buffer (current-buffer)))
          (should (equal (portal-rex-tests--messages
                           (should (equal (portal-rex-tests--answering '("work" t)
                                            (should (call-interactively
                                                     #'portal-rex-session-destroy)))
                                          '(("Destroy Rex session (default work): "
                                             ("work" "play" "empty") "work")
                                            ("Destroy Rex session work and end its 2 blocks? "
                                             nil nil)))))
                         "Destroyed Rex session work\n"))
          (should-not (buffer-live-p buffer))))
      (should (equal (portal-rex-tests--request server "session.destroy") '(:session_id "session:a")))
      (should (equal (portal-rex-tests--names) '("*rex: play/shell*")))
      (should (equal (portal-rex-tests--session-ids connection) '("session:b" "session:c")))
      ;; One block, and none, are said as such.
      (should (equal (car (cadr (portal-rex-tests--answering '("play" nil)
                                  (call-interactively #'portal-rex-session-destroy))))
                     "Destroy Rex session play and end its one block? "))
      (should (equal (car (cadr (portal-rex-tests--answering '("empty" nil)
                                  (call-interactively #'portal-rex-session-destroy))))
                     "Destroy Rex session empty, which has no blocks? "))
      ;; From Lisp, without CONFIRM, nothing asks.
      (should (equal (portal-rex-tests--answering nil
                       (should (portal-rex-session-destroy connection "session:c")))
                     nil))
      (should (equal (portal-rex-tests--session-ids connection) '("session:b"))))))

(ert-deftest portal-rex-new-terminal-starts-a-shell-in-a-session ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a")
    (let* ((connection (portal-rex-tests--connect server))
           (directory (file-name-as-directory (make-temp-file "rex-cwd" t))))
      (unwind-protect
          (save-window-excursion
            (let ((buffer (let ((default-directory directory))
                            (portal-rex-new-terminal connection "session:a"))))
              ;; One window of one shell, in the directory, not made active.
              (should (equal (portal-rex-tests--request server "session.new_window")
                             `(:session_id "session:a"
                               :layout (:block (:flavor "com.superlogical.terminal.shell"
                                                :options (:cwd ,(directory-file-name directory))))
                               :focus :false)))
              ;; Its buffer, as the server listed it, shown and returned.
              (should (eq (window-buffer (selected-window)) buffer))
              (should (equal (buffer-name buffer) "*rex: work/shell*"))
              (with-current-buffer buffer
                (should (eq portal-rex-block-connection connection))
                (should (equal portal-rex-session-id "session:a"))
                (should (string-prefix-p "block:made-" portal-rex-block-id))
                (should (equal default-directory directory))
                ;; It is a terminal in that directory, and in no project,
                ;; as the directory is in none.
                (should (equal (plist-get (portal-terminal-metadata) :directory) directory))
                (should-not (plist-get (portal-terminal-metadata) :project))
                ;; A second from there joins its session, by default.
                (let ((second (call-interactively #'portal-rex-new-terminal)))
                  (should (equal (buffer-local-value 'portal-rex-session-id second) "session:a"))
                  (should (equal (buffer-local-value 'default-directory second) directory))
                  (should (eq (window-buffer (selected-window)) second)))))
            (should (equal (portal-rex-tests--names) '("*rex: work/shell*" "*rex: work/shell*<2>")))
            ;; At a limit, the server's own message, and no buffer.
            (portal-fake-rex-command server :error "session.new_window" :code "conflict"
                                     :message "session has too many windows" :status 409)
            (should (equal (cadr (should-error (portal-rex-new-terminal connection "session:a")
                                               :type 'user-error))
                           "Cannot start a terminal in Rex session work: session has too many windows"))
            (should (= (length (portal-rex-buffers)) 2))
            ;; A remote directory is refused before the server is asked.
            (should-error (portal-rex-new-terminal connection "session:a" "/ssh:elsewhere:/tmp/")
                          :type 'user-error)
            ;; A session the server does not have.
            (portal-fake-rex-command server :result "session.new_window" :payload nil)
            (should (string-prefix-p "Started a terminal in Rex session session:none, but"
                                     (cadr (should-error
                                            (portal-rex-new-terminal connection "session:none")
                                            :type 'user-error)))))
        (delete-directory directory t)))))

(ert-deftest portal-rex-session-default-in-each-case ()
  (portal-rex-tests--with (server other)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                               (:session_id "session:b" :label "play")
                                               (:session_id "session:c" :label "play")])
    (portal-rex-tests--blocks server "b" (portal-rex-tests--block "1" "shell"))
    (let ((connection (portal-rex-tests--connect server))
          (prompt "Rex session for the terminal (a new name creates one): "))
      ;; In a block's buffer, its session, without a question.
      (with-current-buffer "*rex: play/shell*"
        (should-not (portal-rex-tests--answering nil
                      (should (equal (portal-rex-session-default connection) "session:b")))))
      (with-temp-buffer
        ;; Elsewhere, a question, completing over the sessions, a label
        ;; that two share told apart by their IDs.
        (should (equal (portal-rex-tests--answering '("work")
                         (should (equal (portal-rex-session-default connection) "session:a")))
                       `((,prompt ("work" "play (session:b)" "play (session:c)") nil))))
        (should (equal (portal-rex-tests--answering '("play (session:c)")
                         (should (equal (portal-rex-session-default connection) "session:c")))
                       `((,prompt ("work" "play (session:b)" "play (session:c)") nil))))
        ;; A label that reads like another's name is told apart too.
        (portal-fake-rex-command server :event '(:type "session_created"
                                                 :payload (:session (:session_id "session:d"
                                                                     :label "play (session:b)"))))
        (portal-rex-tests--settle connection)
        (let ((choices (portal-rex--session-choices connection)))
          (should (equal (mapcar #'car choices)
                         '("work" "play (session:b)" "play (session:c)" "play (session:b) (session:d)")))
          (should (equal (mapcar #'cdr choices)
                         '("session:a" "session:b" "session:c" "session:d"))))
        (portal-fake-rex-command server :event '(:type "session_destroyed"
                                                 :payload (:session_id "session:d")))
        (portal-rex-tests--settle connection)
        ;; A shared label typed as it is takes the first.
        (portal-rex-tests--answering '("play")
          (should (equal (portal-rex-session-default connection) "session:b")))
        ;; A new name makes a session of it.
        (let ((made (portal-rex-tests--answering '(" docs ")
                      (portal-rex-session-default connection))))
          (should (equal (length made) 1)))
        (should (equal (portal-rex--session-label connection (car (last (portal-rex-tests--session-ids connection))))
                       "docs"))
        (should (equal (portal-rex-tests--request server "session.create") '(:label "docs")))
        ;; No name is refused.
        (portal-rex-tests--answering '("")
          (should-error (portal-rex-session-default connection) :type 'user-error)))
      ;; With two servers, a command takes the current buffer's, and asks
      ;; elsewhere.
      (let ((second (portal-rex-tests--connect other)))
        (with-current-buffer "*rex: play/shell*"
          (should-not (portal-rex-tests--answering nil
                        (should (eq (portal-rex--command-connection) connection)))))
        (with-temp-buffer
          (should (equal (portal-rex-tests--answering (list (portal-rex--named second))
                           (should (eq (portal-rex--command-connection) second)))
                         `(("Rex server: " ,(mapcar #'portal-rex--named (list connection second))
                            nil)))))
        (portal-rex-disconnect second))
      ;; With none, a command says to connect.
      (portal-rex-disconnect connection)
      (with-temp-buffer
        (should (string-match-p "portal-rex-connect"
                                (cadr (should-error (portal-rex--command-connection)
                                                    :type 'user-error))))))))

(ert-deftest portal-rex-renaming-a-block-sets-its-label ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "shell")
                              (portal-rex-tests--block "2" "logs" "detached")
                              (portal-rex-tests--block "3" "shell"))
    (let ((connection (portal-rex-tests--connect server)))
      (should (equal (portal-rex-tests--names)
                     '("*rex: work/logs*" "*rex: work/shell*" "*rex: work/shell*<2>")))
      (with-current-buffer "*rex: work/shell*"
        ;; Portal's rename command starts from the block's label, and sets it.
        (should (equal (portal-rex-tests--answering '("api")
                         (call-interactively #'portal-terminal-rename))
                       '(("Terminal name: " nil "shell"))))
        (should (equal (portal-rex-tests--request server "session.set_block_label")
                       '(:session_id "session:a" :block_id "block:1" :label "api")))
        ;; The buffer's name follows the block's.
        (should (equal (buffer-name) "*rex: work/api*"))
        (should (equal portal-rex--block-label "api")))
      ;; The other shell's buffer, named apart from this one's, takes the
      ;; plain name once it is free.
      (should (equal (buffer-name (portal-rex-block-buffer connection "block:3"))
                     "*rex: work/shell*"))
      ;; A detached block sends no event, and is renamed all the same.
      (with-current-buffer "*rex: work/logs*"
        (portal-terminal-rename "errors")
        (should (equal (buffer-name) "*rex: work/errors*")))
      ;; The server's refusal, in its words, and the name stays.
      (with-current-buffer "*rex: work/api*"
        (should (equal (cadr (should-error (portal-rex-block-rename "a\tb") :type 'user-error))
                       "Cannot rename Rex block api: session.set_block_label: label must be at most 128 characters without control characters"))
        (should (equal (buffer-name) "*rex: work/api*")))
      ;; Only a block's buffer has a block to rename.
      (with-temp-buffer
        (should-error (portal-rex-block-rename "x") :type 'user-error))
      ;; Other terminals' buffers are renamed as ever.
      (with-temp-buffer
        (portal-terminal-mode)
        (portal-terminal-rename "portal-rex-tests-plain")
        (should (equal (buffer-name) "portal-rex-tests-plain")))
      ;; A name given by hand stays while the labels do.
      (with-current-buffer (portal-rex-block-buffer connection "block:3")
        (rename-buffer "my shell"))
      (portal-rex-tests--session-event server "a" "session_view_changed" :revision 9)
      (portal-rex-tests--settle connection)
      (should (equal (portal-rex-tests--names connection)
                     '("*rex: work/api*" "*rex: work/errors*" "my shell"))))))

(defconst portal-rex-tests--guide
  (expand-file-name "../docs/rex.md" (file-name-directory (or load-file-name buffer-file-name)))
  "The Rex guide, whose examples tests run.")

(defun portal-rex-tests--example (name)
  "Return the Rex guide's example NAME, the Emacs Lisp block after its marker."
  (with-temp-buffer
    (insert-file-contents portal-rex-tests--guide)
    (unless (re-search-forward (format "^<!-- example: %s -->\n```elisp\n" (regexp-quote name)) nil t)
      (error "docs/rex.md has no example %s" name))
    (let ((start (point)))
      (re-search-forward "^```$")
      (car (read-from-string (concat "(progn\n" (buffer-substring-no-properties
                                                  start (match-beginning 0))
                                     ")"))))))

(ert-deftest portal-rex-project-recipe-gives-each-project-a-session ()
  ;; The recipe in docs/rex.md, as the guide has it.
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (let* ((connection (portal-rex-tests--connect server))
           (root (file-name-as-directory (make-temp-file "rex-projects" t)))
           (alpha (expand-file-name "alpha/" root))
           (beta (expand-file-name "beta/" root))
           (project-find-functions
            (list (lambda (directory)
                    (seq-some (lambda (project)
                                (and (string-prefix-p project (expand-file-name directory))
                                     (cons 'transient project)))
                              (list alpha beta)))))
           (portal-rex-session-function portal-rex-session-function))
      (make-directory (expand-file-name "src" alpha) t)
      (make-directory beta t)
      (unwind-protect
          (save-window-excursion
            (eval (portal-rex-tests--example "rex-project-session") t)
            (with-temp-buffer
              ;; A terminal in each of two projects: two sessions, named
              ;; after them, made without a question.
              (should-not (portal-rex-tests--answering nil
                            (let ((default-directory alpha))
                              (call-interactively #'portal-rex-new-terminal))
                            (let ((default-directory beta))
                              (call-interactively #'portal-rex-new-terminal)))))
            (should (equal (mapcar (lambda (session) (plist-get session :label))
                                   (portal-rex-connection-sessions connection))
                           '("work" "alpha" "beta")))
            ;; A third, from deeper in a project, joins its session.
            (with-temp-buffer
              (let ((default-directory (expand-file-name "src/" alpha)))
                (call-interactively #'portal-rex-new-terminal)))
            (should (equal (mapcar (lambda (session) (plist-get session :label))
                                   (portal-rex-connection-sessions connection))
                           '("work" "alpha" "beta")))
            (should (equal (portal-rex-tests--names)
                           '("*rex: alpha/shell*" "*rex: alpha/shell*<2>" "*rex: beta/shell*")))
            ;; Outside any project, the default's question.
            (with-temp-buffer
              (let ((default-directory root))
                (should (equal (caar (portal-rex-tests--answering '("work")
                                       (call-interactively #'portal-rex-new-terminal)))
                               "Rex session for the terminal (a new name creates one): ")))))
        (delete-directory root t)))))

;;; Restoring the arrangement

(defmacro portal-rex-tests--restoring (&rest body)
  "Run BODY with nothing to restore or say, and leave nothing behind.
The placeholders BODY leaves are killed, and the timers it arms cancelled."
  (declare (indent 0))
  `(let ((portal-rex--unrestored nil)
         (portal-rex-connect-at-startup nil))
     (unwind-protect (progn ,@body)
       (mapc #'kill-buffer (portal-rex--placeholders))
       (dolist (timer '(portal-rex--restore-timer portal-rex--report-timer))
         (when (timerp (symbol-value timer)) (cancel-timer (symbol-value timer)))
         (set timer nil)))))

(defun portal-rex-tests--said ()
  "Return what Portal says, now, about what it could not restore."
  (string-trim-right (portal-rex-tests--messages (portal-rex--report-unrestored))))

(defun portal-rex-tests--restore ()
  "Start restoring, as Emacs does once idle, and wait until every connection has opened."
  (portal-rex--restore)
  (dolist (connection (copy-sequence portal-rex--connections))
    (portal-rex-tests--until connection
                             (lambda () (not (portal-rex-connection-opening connection))))))

(defun portal-rex-tests--record (server block session &optional block-label session-label)
  "Return the record of BLOCK, in SESSION on SERVER, a socket or a host."
  `((server . ,server) (block . ,(concat "block:" block)) (session . ,(concat "session:" session))
    (block-label . ,(or block-label block)) (session-label . ,(or session-label session))))

(ert-deftest portal-rex-fake-reattaches-as-a-real-server ()
  ;; The same check runs against a real server in the real-server tier.
  (portal-rex-tests--with (server)
    (portal-rex-tests--restoring
      (let ((connection (portal-rex-tests--connect server)))
        (portal-rex-parity-check-reattach connection "block:fake-1")))))

(ert-deftest portal-rex-bookmark-names-the-block-and-jumps-to-it ()
  (portal-rex-tests--with (server)
    (portal-rex-tests--restoring
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                                (portal-rex-tests--block "2" "logs"))
      (let* ((socket (portal-fake-rex-socket server))
             (bookmark-alist nil)
             (bookmark-save-flag nil)
             (bookmark-default-file (expand-file-name "bookmarks" (portal-fake-rex-directory server)))
             (connection (portal-rex-tests--connect server))
             (jump (lambda (name)
                     (let (shown)
                       (save-current-buffer
                         (bookmark-jump name (lambda (buffer) (setq shown buffer))))
                       shown))))
        (with-current-buffer "*rex: work/api*"
          ;; A bookmark records the server and the block's ID; the labels
          ;; are there to read.
          (should (equal (portal-rex-bookmark-make-record)
                         `("rex: work/api"
                           (server . ,(abbreviate-file-name socket))
                           (block . "block:1") (session . "session:a")
                           (block-label . "api") (session-label . "work")
                           (handler . portal-rex-bookmark-jump))))
          (bookmark-set "api"))
        (with-current-buffer "*rex: work/logs*" (bookmark-set "logs"))
        (with-temp-buffer
          (should-error (portal-rex-bookmark-make-record) :type 'user-error))
        ;; Emacs connected, the jump shows the block's buffer.
        (should (eq (funcall jump "api") (portal-rex-block-buffer connection "block:1")))
        ;; Disconnected, it connects first.
        (portal-rex-disconnect connection)
        (should-not (portal-rex-buffers))
        (let ((shown (funcall jump "logs")))
          (should (equal (buffer-name shown) "*rex: work/logs*"))
          (should (eq shown (portal-rex-block-buffer (car (portal-rex-connections)) "block:2"))))
        ;; A block that has closed is gone, and the jump says so.
        (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
        (portal-rex-disconnect (car (portal-rex-connections)))
        (should (equal (cadr (should-error (funcall jump "logs") :type 'user-error))
                       (format "Rex block work/logs has closed: it is gone from the server at %s"
                               (abbreviate-file-name socket))))
        ;; So does one whose buffer alone was killed, by a kill that asked
        ;; nothing, while Emacs stays connected.
        (with-current-buffer "*rex: work/api*"
          (let ((inhibit-message t)
                (kill-buffer-query-functions nil))
            (kill-buffer)))
        (should (string-prefix-p "Rex block work/api still runs, but its buffer was killed"
                                 (cadr (should-error (funcall jump "api") :type 'user-error))))
        (portal-rex-disconnect (car (portal-rex-connections)))
        ;; No server, and a server on another machine: each says why.
        (portal-fake-rex-command server :upgrade "refuse")
        (should (string-prefix-p (format "Cannot connect to the Rex server at %s: The server refused"
                                         (abbreviate-file-name socket))
                                 (cadr (should-error (funcall jump "api") :type 'user-error))))
        (should-not portal-rex--connections)
        (portal-fake-rex-command server :upgrade "ok")
        (bookmark-prop-set "api" 'server "studio")
        (should (equal (cadr (should-error (funcall jump "api") :type 'user-error))
                       "Cannot reach the Rex host studio: Portal connects only to the Rex server on this Mac"))
        (should-not portal-rex--connections)))))

(defvar desktop-buffer-ok-count)
(defvar desktop-buffer-fail-count)
(defvar desktop-first-buffer)
(defvar desktop-delay-hook)

(defun portal-rex-tests--read-desktop (directory &optional tabs)
  "Restore the buffers of the desktop saved in DIRECTORY, and the frame's TABS.
`desktop-read' does nothing in batch Emacs; this evaluates the desktop
file, which restores each buffer, and runs the hooks `desktop-read' runs,
in its order, giving the frame TABS where its frameset would."
  (let ((inhibit-message t)
        (desktop-buffer-ok-count 0)
        (desktop-buffer-fail-count 0)
        (desktop-first-buffer nil))
    (load (desktop-full-file-name directory) nil t t)
    (run-hooks 'desktop-delay-hook)
    (setq desktop-delay-hook nil)
    (when tabs (set-frame-parameter nil 'tabs tabs))
    (run-hooks 'desktop-after-read-hook)))

(ert-deftest portal-rex-desktop-restores-each-block-into-its-buffer ()
  (require 'desktop)
  (portal-rex-tests--with (server)
    (portal-rex-tests--restoring
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                                 (:session_id "session:b" :label "play")])
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                                (portal-rex-tests--block "2" "logs"))
      (portal-rex-tests--blocks server "b" (portal-rex-tests--block "3" "shell")
                                (portal-rex-tests--block "4" "shell"))
      (let* ((directory (portal-fake-rex-directory server))
             (desktop-globals-to-save nil)
             (desktop-locals-to-save nil)
             (desktop-restore-frames nil)
             (desktop-load-locked-desktop t)
             (desktop-dirname nil)
             (desktop-base-file-name "rex-desktop")
             (desktop-base-lock-name "rex-desktop.lock")
             (desktop-buffer-mode-handlers desktop-buffer-mode-handlers)
             (connection (portal-rex-tests--connect server))
             (api (portal-rex-block-buffer connection "block:1"))
             (shell (portal-rex-block-buffer connection "block:4")))
        ;; Plain buffers are not part of this.
        (cl-letf (((symbol-function 'desktop-save-buffer-p)
                   (lambda (_file name &rest _)
                     (string-prefix-p "*rex: " name))))
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer api)
            (let ((other (split-window)))
              (set-window-buffer other shell)
              ;; A tab not selected names its windows' buffers.
              (let* ((saved (window-state-get (frame-root-window) t))
                     (tabs `((current-tab (name . "here")) (tab (name . "there") (ws . ,saved))))
                     (old-tabs (frame-parameter nil 'tabs)))
                (desktop-save directory t)
                (desktop-release-lock directory)
                ;; Emacs quits; the block whose buffer is api is relabelled,
                ;; and logs closes, meanwhile.
                (portal-rex-disconnect connection)
                (should-not (portal-rex-buffers))
                (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api-2"))
                (unwind-protect
                    (progn
                      (portal-rex-tests--read-desktop directory tabs)
                      ;; At once, without the server: a placeholder of each, under
                      ;; its old name, which says what it waits for.
                      (should-not portal-rex--connections)
                      (should (equal (sort (mapcar #'buffer-name (portal-rex--placeholders)) #'string<)
                                     '("*rex: play/shell*" "*rex: play/shell*<2>"
                                       "*rex: work/api*" "*rex: work/logs*")))
                      (with-current-buffer "*rex: play/shell*<2>"
                        (should (eq major-mode 'portal-rex-placeholder-mode))
                        (should (string-search "block:4 on the server at" (buffer-string)))
                        (should (string-search "Emacs has not connected to its server yet."
                                               (buffer-string)))
                        (should buffer-read-only)
                        (should-not portal-input-mode))
                      ;; Emacs connects once idle, and asks for no answer meanwhile.
                      (should (timerp portal-rex--restore-timer))
                      (let ((placeholders (mapcar (lambda (name) (cons name (get-buffer name)))
                                                  '("*rex: work/api*" "*rex: play/shell*"
                                                    "*rex: play/shell*<2>"))))
                        (portal-rex-tests--restore)
                        (setq connection (car (portal-rex-connections)))
                        ;; Each placeholder is its block's buffer now; the
                        ;; relabelled one takes its new name.
                        (should (eq (portal-rex-block-buffer connection "block:1")
                                    (cdr (assoc "*rex: work/api*" placeholders))))
                        (should (eq (portal-rex-block-buffer connection "block:3")
                                    (cdr (assoc "*rex: play/shell*" placeholders))))
                        (should (eq (portal-rex-block-buffer connection "block:4")
                                    (cdr (assoc "*rex: play/shell*<2>" placeholders))))
                        (should (equal (portal-rex-tests--names)
                                       '("*rex: play/shell*" "*rex: play/shell*<2>"
                                         "*rex: work/api-2*")))
                        (with-current-buffer (portal-rex-block-buffer connection "block:4")
                          (should (eq major-mode 'portal-terminal-mode))
                          (should (equal portal-rex-session-id "session:b"))
                          (should (string-search "once a window shows this buffer" (buffer-string))))
                        ;; The tab not yet selected finds its buffers by the
                        ;; names they were saved with, as a file's: shell's,
                        ;; but not the block relabelled meanwhile, as a file
                        ;; renamed meanwhile.
                        (let ((state (alist-get 'ws (cdr (nth 1 (frame-parameter nil 'tabs))))))
                          (window-state-put state (frame-root-window))
                          (let ((shown (mapcar #'window-buffer (window-list nil 'nomini))))
                            (should (memq (portal-rex-block-buffer connection "block:4") shown))
                            (should-not (memq (portal-rex-block-buffer connection "block:1")
                                              shown)))))
                      ;; The closed block's placeholder has gone, and Emacs says so once.
                      (should-not (portal-rex--placeholders))
                      (should-not (get-buffer "*rex: work/logs*"))
                      (should (equal (portal-rex-tests--said)
                                     "Could not restore Rex block work/logs: it has closed"))
                      (should (equal (portal-rex-tests--said) ""))
                      ;; Reading the desktop while connected gives the blocks' buffers.
                      (portal-rex-tests--read-desktop directory)
                      (should-not (portal-rex--placeholders))
                      (should (equal (portal-rex-tests--names)
                                     '("*rex: play/shell*" "*rex: play/shell*<2>"
                                       "*rex: work/api-2*"))))
                  (set-frame-parameter nil 'tabs old-tabs))))))))))

(ert-deftest portal-rex-restored-blocks-that-swapped-labels-take-their-names ()
  ;; Two blocks swap labels while Emacs is not running: each placeholder
  ;; meets the other's name as it becomes its block's buffer, and each
  ;; ends with its own block's name.
  (portal-rex-tests--with (server)
    (portal-rex-tests--restoring
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "b")
                                (portal-rex-tests--block "2" "a"))
      (let* ((socket (abbreviate-file-name (portal-fake-rex-socket server)))
             (first (portal-rex-desktop-restore
                     nil "*rex: work/a*" (portal-rex-tests--record socket "1" "a" "a" "work")))
             (second (portal-rex-desktop-restore
                      nil "*rex: work/b*" (portal-rex-tests--record socket "2" "a" "b" "work"))))
        (portal-rex-tests--restore)
        (let ((connection (car (portal-rex-connections))))
          (should (eq (portal-rex-block-buffer connection "block:1") first))
          (should (eq (portal-rex-block-buffer connection "block:2") second)))
        (should (equal (buffer-name first) "*rex: work/b*"))
        (should (equal (buffer-name second) "*rex: work/a*"))))))

(ert-deftest portal-rex-exiting-disconnects-after-what-saves-the-arrangement ()
  ;; desktop-save-mode saves from `kill-emacs-query-functions', before this
  ;; hook; a configuration that saves from the hook itself, added before or
  ;; after Emacs connects, still runs while the blocks have buffers.
  (portal-rex-tests--with (server)
    (let* ((kill-emacs-hook nil)
           seen
           (save (lambda () (push (length (portal-rex-buffers)) seen))))
      (add-hook 'kill-emacs-hook save)
      (portal-rex-tests--connect server)
      (add-hook 'kill-emacs-hook (lambda () (funcall save)))
      (run-hooks 'kill-emacs-hook)
      (should (equal seen '(1 1)))
      (should-not (portal-rex-buffers)))))

(ert-deftest portal-rex-connect-at-startup-needs-only-the-autoloads ()
  ;; A fresh Emacs with Portal's autoloads alone: the option set, it
  ;; connects once started; not set, Portal is not even loaded.
  (let* ((root (file-name-directory (locate-library "portal-rex")))
         (directory (make-temp-file "rex-autoloads" t))
         (autoloads (expand-file-name "rex-autoloads.el" directory))
         (run (lambda (option)
                (with-temp-buffer
                  (call-process
                   (expand-file-name invocation-name invocation-directory) nil t nil
                   "-Q" "--batch" "-L" root "-l" autoloads
                   "--eval"
                   (format "(progn (setq portal-rex-connect-at-startup %s
                                          portal-rex-socket %S)
                                   (run-hooks 'emacs-startup-hook)
                                   (prin1 (list (featurep 'portal-rex)
                                                (and (boundp 'portal-rex--restore-timer)
                                                     (timerp portal-rex--restore-timer)))))"
                           option (expand-file-name "none" directory)))
                  (car (read-from-string
                        (buffer-substring (line-beginning-position) (point-max))))))))
    (unwind-protect
        (progn
          (let ((inhibit-message t))
            (loaddefs-generate root autoloads))
          (should (equal (funcall run "nil") '(nil nil)))
          (should (equal (funcall run "t") '(t t))))
      (delete-directory directory t))))

(ert-deftest portal-rex-desktop-read-while-connected-gives-the-blocks-names ()
  ;; The same swap, with the desktop read while Emacs is connected: the
  ;; desktop names each block's buffer as it was saved, which is now the
  ;; other's name; then each takes its own block's name back.
  (require 'desktop)
  (portal-rex-tests--with (server)
    (portal-rex-tests--restoring
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "a")
                                (portal-rex-tests--block "2" "b"))
      (let* ((directory (portal-fake-rex-directory server))
             (desktop-globals-to-save nil)
             (desktop-locals-to-save nil)
             (desktop-restore-frames nil)
             (desktop-base-file-name "rex-desktop")
             (desktop-base-lock-name "rex-desktop.lock")
             (connection (portal-rex-tests--connect server))
             (first (portal-rex-block-buffer connection "block:1"))
             (second (portal-rex-block-buffer connection "block:2")))
        (cl-letf (((symbol-function 'desktop-save-buffer-p)
                   (lambda (_file name &rest _) (string-prefix-p "*rex: " name))))
          (desktop-save directory t)
          (desktop-release-lock directory)
          (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "b")
                                    (portal-rex-tests--block "2" "a"))
          (portal-rex-tests--session-event server "a" "session_view_changed" :revision 2)
          (portal-rex-tests--settle connection)
          (portal-rex-tests--read-desktop directory)
          (should-not (portal-rex--placeholders))
          (should (eq (portal-rex-block-buffer connection "block:1") first))
          (should (equal (list (buffer-name first) (buffer-name second))
                         '("*rex: work/b*" "*rex: work/a*"))))))))

(ert-deftest portal-rex-desktop-restoring-lazily-while-connected-keeps-names ()
  ;; A desktop that restores its buffers lazily, from an idle timer after
  ;; it has been read, while Emacs is connected.
  (require 'desktop)
  (portal-rex-tests--with (server)
    (portal-rex-tests--restoring
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "a")
                                (portal-rex-tests--block "2" "b"))
      (let* ((directory (portal-fake-rex-directory server))
             (desktop-globals-to-save nil)
             (desktop-locals-to-save nil)
             (desktop-restore-frames nil)
             (desktop-restore-eager 0)
             (desktop-base-file-name "rex-desktop")
             (desktop-base-lock-name "rex-desktop.lock")
             (desktop-buffer-args-list nil)
             (connection (portal-rex-tests--connect server)))
        (cl-letf (((symbol-function 'desktop-save-buffer-p)
                   (lambda (_file name &rest _) (equal name "*rex: work/a*"))))
          (desktop-save directory t)
          (desktop-release-lock directory)
          ;; Relabelled since: the desktop will give it its old name.
          (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "c")
                                    (portal-rex-tests--block "2" "b"))
          (portal-rex-tests--session-event server "a" "session_view_changed" :revision 2)
          (portal-rex-tests--settle connection)
          (portal-rex-tests--read-desktop directory)
          ;; Nothing yet: the buffer waits to be restored.
          (should desktop-buffer-args-list)
          (let ((inhibit-message t))
            (desktop-lazy-complete))
          ;; Restored, it has its own name back.
          (should (equal (portal-rex-tests--names connection)
                         '("*rex: work/b*" "*rex: work/c*"))))))))

(ert-deftest portal-rex-desktop-clear-ends-no-block ()
  ;; `desktop-revert' and `desktop-change-dir' clear the desktop first,
  ;; killing every buffer; killing a block's buffer would end the block.
  (require 'desktop)
  (portal-rex-tests--with (server)
    (portal-rex-tests--restoring
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
      (let* ((connection (portal-rex-tests--connect server))
             (buffer (portal-rex-block-buffer connection "block:1"))
             (record (portal-rex-tests--record "studio" "9" "z" "far" "home"))
             (placeholder (portal-rex-desktop-restore nil "*rex: home/far*" record))
             (other (get-buffer-create "*rex-tests-other*"))
             (desktop-clear-preserve-buffers
              (append desktop-clear-preserve-buffers
                      (list (regexp-quote (buffer-name (messages-buffer)))
                            "\\*fake-rex-server.*"))))
        (portal-rex-tests--asked server connection)
        (save-window-excursion
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&rest _) (list buffer placeholder other))))
            (desktop-clear)))
        (should-not (buffer-live-p other))
        (should (eq (portal-rex-block-buffer connection "block:1") buffer))
        (should (buffer-live-p placeholder))
        (should-not (member "block.close" (portal-rex-tests--asked server connection)))
        ;; The desktop read after finds the placeholder, makes no other, and
        ;; tries its server again.
        (when (timerp portal-rex--restore-timer) (cancel-timer portal-rex--restore-timer))
        (setq portal-rex--restore-timer nil)
        (should (eq (portal-rex-desktop-restore nil "*rex: home/far*" record) placeholder))
        (should (timerp portal-rex--restore-timer))
        (should (equal (mapcar #'buffer-name (portal-rex--placeholders)) '("*rex: home/far*")))))))

(ert-deftest portal-rex-desktop-read-while-listing-waits-only-for-its-session ()
  ;; Connected, with another session's blocks still being listed: a block
  ;; whose own session was listed without it has closed, and says so; one
  ;; whose session is still being listed waits for the answer.
  (portal-rex-tests--with (server)
    (portal-rex-tests--restoring
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")
                                                 (:session_id "session:b" :label "play")])
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
      (portal-rex-tests--blocks server "b" (portal-rex-tests--block "2" "shell"))
      (let* ((connection (portal-rex-tests--connect server))
             (socket (abbreviate-file-name (portal-fake-rex-socket server))))
        (portal-fake-rex-command server :hold "session.list_blocks")
        (portal-rex-tests--session-event server "b" "session_view_changed" :revision 2)
        (portal-rex-tests--until connection
                                 (lambda () (assoc "session:b" (portal-rex-connection-lists connection))))
        (should-not (portal-rex-desktop-restore
                     nil "*rex: work/old*" (portal-rex-tests--record socket "9" "a" "old" "work")))
        (should (equal (portal-rex-tests--said) "Could not restore Rex block work/old: it has closed"))
        (let ((waiting (portal-rex-desktop-restore
                        nil "*rex: play/new*" (portal-rex-tests--record socket "3" "b" "new" "play"))))
          (should (eq (buffer-local-value 'major-mode waiting) 'portal-rex-placeholder-mode))
          ;; The answer lists no such block: the placeholder goes, said once.
          (portal-fake-rex-command server :release "session.list_blocks")
          (portal-rex-tests--settle connection)
          (should-not (buffer-live-p waiting))
          (should (equal (portal-rex-tests--said)
                         "Could not restore Rex block play/new: it has closed")))))))

(ert-deftest portal-rex-restore-says-once-what-it-could-not-restore ()
  (portal-rex-tests--with (server)
    (portal-rex-tests--restoring
      (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
      (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api"))
      (let* ((socket (abbreviate-file-name (portal-fake-rex-socket server)))
             (missing (abbreviate-file-name
                       (expand-file-name "none" (portal-fake-rex-directory server))))
             (make (lambda (name record)
                     (with-current-buffer (portal-rex-desktop-restore nil name record)
                       (current-buffer)))))
        ;; A stopped server, a host Portal cannot reach, a block that has
        ;; closed, and a server that is not answering yet.
        (funcall make "gone" (portal-rex-tests--record missing "9" "z"))
        (funcall make "far" (portal-rex-tests--record "studio" "8" "y" "far" "home"))
        (funcall make "*rex: work/old*" (portal-rex-tests--record socket "7" "a" "old" "work"))
        (funcall make "*rex: work/api*" (portal-rex-tests--record socket "1" "a" "api" "work"))
        (portal-fake-rex-command server :upgrade "refuse")
        (let ((portal-rex-timeout 0.3))
          (portal-rex-tests--restore))
        ;; Nothing connected; each waits and says why.
        (should-not portal-rex--connections)
        (with-current-buffer "far"
          (should (string-search "Cannot reach the Rex host studio" (buffer-string))))
        (with-current-buffer "gone"
          (should (string-search "No Rex server is running: there is no socket at" (buffer-string))))
        (should (equal (portal-rex-tests--said)
                       (concat
                        (format "Could not restore Rex block z/9: No Rex server is running: there is no socket at %s; " missing)
                        "Could not restore Rex block home/far: Cannot reach the Rex host studio: Portal connects only to the Rex server on this Mac; "
                        (format "Could not restore Rex blocks work/old, work/api: Cannot connect to the Rex server at %s: The server refused the connection: HTTP/1.1 400 Bad Request" socket))))
        ;; Once the server takes connections, connecting restores what it
        ;; can, and says what has closed.
        (portal-fake-rex-command server :upgrade "ok")
        (let ((connection (portal-rex-tests--connect server)))
          (should (eq (portal-rex-block-buffer connection "block:1") (get-buffer "*rex: work/api*")))
          (should-not (get-buffer "*rex: work/old*"))
          (should (equal (portal-rex-tests--said)
                         "Could not restore Rex block work/old: it has closed"))
          (should (equal (sort (mapcar #'buffer-name (portal-rex--placeholders)) #'string<)
                         '("far" "gone"))))))))

(ert-deftest portal-rex-connect-at-startup-waits-for-nothing ()
  (portal-rex-tests--with (server)
    (portal-rex-tests--restoring
      ;; Off, as by default: nothing.
      (portal-rex-at-startup)
      (should-not portal-rex--restore-timer)
      (let ((portal-rex-connect-at-startup t)
            (portal-rex-socket (portal-fake-rex-socket server)))
        (portal-rex-at-startup)
        (should (timerp portal-rex--restore-timer))
        ;; It returns before the server has answered.
        (portal-fake-rex-command server :hold "session.attach_all")
        (portal-rex--restore)
        (let ((connection (car portal-rex--connections)))
          (should connection)
          (should-not (portal-rex-live-p connection))
          (portal-fake-rex-command server :release "session.attach_all")
          (portal-rex-tests--until connection
                                   (lambda () (not (portal-rex-connection-opening connection))))
          (should (portal-rex-live-p connection))
          (should (equal (portal-rex-tests--names) '("*rex: fake/shell*")))
          (should (equal (portal-rex-tests--said) ""))
          (portal-rex-disconnect connection))
        ;; A server that never answers is given up after the timeout, and
        ;; one that is stopped at once; each is said once.
        (portal-fake-rex-command server :welcome :false)
        (should (equal (string-trim-right
                        (portal-rex-tests--messages
                          (let ((portal-rex-timeout 0.3))
                            (portal-rex--restore)
                            (let ((connection (car portal-rex--connections)))
                              ;; Its timer gives up, and the next says why.
                              (while (or (portal-rex-connection-opening connection)
                                         portal-rex--report-timer)
                                (accept-process-output nil 0.05))))))
                       (format "The Rex server at %s did not answer within 0.3 seconds"
                               (abbreviate-file-name (portal-fake-rex-socket server)))))
        (should-not portal-rex--connections)
        (portal-fake-rex-command server :welcome t)
        (let ((portal-rex-socket (expand-file-name "none" (portal-fake-rex-directory server))))
          (portal-rex--restore))
        (should-not portal-rex--connections)
        (should (string-prefix-p "No Rex server is running" (portal-rex-tests--said)))))))

(provide 'portal-rex-tests)
;;; portal-rex-tests.el ends here
