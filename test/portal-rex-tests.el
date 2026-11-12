;;; portal-rex-tests.el --- Rex connections against the fake server -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Runs portal-rex.el on the real native module, whose message sockets need
;; no window, against test/fake-rex-server.py on sockets of its own: never
;; the user's Rex server.  PORTAL_TEST_BUILD names the build directory.
;; Batch Emacs runs no main run loop, so the module's "rex ID" record never
;; comes: these tests take messages by waiting, as `portal-rex-call' does.
;; test/portal-rex-gui-tests.el covers the record, and
;; test/portal-rex-tests.c the core's own rules.

(require 'ert)
(require 'portal-fake-rex
         (expand-file-name "portal-fake-rex.el" (file-name-directory load-file-name)))

(let ((build (getenv "PORTAL_TEST_BUILD")))
  (unless build (error "Set PORTAL_TEST_BUILD to the build directory"))
  (module-load (expand-file-name "portal.bundle/Contents/MacOS/portal.dylib" build)))

(require 'portal-rex)

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
      (should-not (portal-rex-connection-calls connection)))))

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
        (should (equal (portal-rex-tests--messages
                         (portal-rex-tests--until
                          again (lambda () (not (portal-rex-connection-id again)))))
                       (format "Lost the Rex server at %s: The server closed the connection (1001: going away)\n"
                               name)))))))

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

(provide 'portal-rex-tests)
;;; portal-rex-tests.el ends here
