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
      (portal-rex-parity-check-block connection "session:fake-1" "block:fake-1"))))

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
        ;; Killing it ends no program, so nothing asks.
        (should-not portal-terminal-confirm-kill)
        (should buffer-read-only)
        (should-not (buffer-modified-p))
        (should (equal default-directory (expand-file-name "~/"))))
      (should-not (portal-rex-session-label (get-buffer-create "*scratch*"))))))

(ert-deftest portal-rex-buffer-is-a-terminal-buffer-without-a-view ()
  ;; The mode is the one a terminal view lives in, and Portal's terminal
  ;; commands take a buffer that has no view yet for what it is.
  (portal-rex-tests--with (server)
    (let* ((connection (portal-rex-tests--connect server))
           (buffer (portal-rex-block-buffer connection "block:fake-1")))
      (should (equal (buffer-name buffer) "*rex: fake/shell*"))
      (with-current-buffer buffer
        (should (eq major-mode 'portal-terminal-mode))
        (should-not portal-view--target)
        (should-not (portal-terminal-metadata))
        (should-not (memq buffer (portal-terminal-buffers)))
        (should-not (memq buffer (portal-view-buffers)))
        (should-error (portal-terminal-focus) :type 'user-error)
        (should-error (portal-input-focus) :type 'user-error)
        (should-error (portal-terminal-set-project nil) :type 'user-error)
        (should-error (portal-terminal-next) :type 'user-error)
        (should (portal-terminal--kill-query))
        ;; Closing the terminal there is none of ends nothing.
        (portal-terminal-close)
        (should (buffer-live-p buffer))
        ;; Another mode leaves it the block's buffer.
        (fundamental-mode)
        (should (equal portal-rex-block-id "block:fake-1"))
        (should (eq portal-rex-block-connection connection)))
      (portal-rex-disconnect connection)
      (should-not (buffer-live-p buffer)))))

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

(ert-deftest portal-rex-killing-a-buffer-by-hand-leaves-its-block ()
  (portal-rex-tests--with (server)
    (portal-fake-rex-command server :sessions [(:session_id "session:a" :label "work")])
    (portal-rex-tests--blocks server "a" (portal-rex-tests--block "1" "api")
                              (portal-rex-tests--block "2" "logs"))
    (let* ((connection (portal-rex-tests--connect server))
           (buffer (portal-rex-block-buffer connection "block:1")))
      (portal-rex-tests--asked server connection)
      ;; It only kills the buffer, and says so.
      (should (equal (portal-rex-tests--messages (should (kill-buffer buffer)))
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

(provide 'portal-rex-tests)
;;; portal-rex-tests.el ends here
