;;;; SPDX-FileCopyrightText: Atlas Engineer LLC
;;;; SPDX-License-Identifier: BSD-3-Clause

(in-package :nyxt)

(setf +renderer+ "GTK")

(define-class gtk-browser ()
  (#+darwin
   (modifiers '()
              :documentation "On macOS some modifiers like Super and Meta are
seen like regular keys.
To work around this issue, we store them in this list while they are pressed.
See `push-modifiers', `pop-modifiers' and `key-event-modifiers'.")
   (modifier-translator #'translate-modifiers
                        :documentation "Function that returns a list of
modifiers understood by `keymap:make-key'.  You can customize this slot if you
want to change the behaviour of modifiers, for instance swap 'control' and
'meta':

\(defun my-translate-modifiers (modifier-state &optional event)
  \"Swap control and meta.\"
  (declare (ignore event))
  (let ((plist '(:control-mask \"meta\"
                 :mod1-mask \"control\" ;; Usually it is Alt.
                 :mod5-mask nil         ;; See your config for what mod1-5 mean.
                 :shift-mask \"shift\"
                 :super-mask \"super\"
                 :hyper-mask \"hyper\"
                 :meta-mask nil         ;; Meta.
                 :lock-mask nil)))
    (delete nil (mapcar (lambda (mod) (getf plist mod)) modifier-state))))

\(define-configuration browser
  ((modifier-translator #'my-translate-modifiers)))")
   (web-contexts (make-hash-table :test 'equal)
                 :documentation "Persistent `nyxt::webkit-web-context's
Keyed by strings as they must be backed to unique folders
See also the `ephemeral-web-contexts' slot.")
   (ephemeral-web-contexts (make-hash-table :test 'equal)
                           :documentation "Ephemeral `nyxt::webkit-web-context's.
See also the `web-contexts' slot."))
  (:export-class-name-p t)
  (:export-accessor-names-p t)
  (:accessor-name-transformer (class*:make-name-transformer name)))
(define-user-class browser (gtk-browser))

(alex:define-constant +internal+ "internal" :test 'equal)
(alex:define-constant +default+ "default" :test 'equal)

(defmethod get-context ((browser gtk-browser) name buffer &key ephemeral-p)
  (alexandria:ensure-gethash name
                             (if ephemeral-p
                                 (ephemeral-web-contexts browser)
                                 (web-contexts browser))
                             (make-context name buffer :ephemeral-p ephemeral-p)))

(define-class gtk-window ()
  ((gtk-object)
   (handler-ids
    :documentation "See `gtk-buffer' slot of the same name.")
   (root-box-layout)
   (horizontal-box-layout)
   (panel-buffer-container-left)
   (panel-buffer-container-right)
   (panel-buffers-left)
   (panel-buffers-right)
   (main-buffer-container)
   (prompt-buffer-container)
   (prompt-buffer-view
    :documentation "Shared web view between all prompt buffers of this window.")
   (status-container)
   (message-container)
   (message-view)
   (key-string-buffer))
  (:export-class-name-p t)
  (:export-accessor-names-p t)
  (:accessor-name-transformer (class*:make-name-transformer name)))
(define-user-class window (gtk-window))

(define-class gtk-buffer ()
  ((gtk-object)
   (context-name
    +default+
    :type string
    :documentation "Name of the WebKit context.
When given the same context, multiple buffers share their internal browsing data.
`+default+' is the default context.
`+internal+' is a context that's not persisted to disk.")
   (handler-ids
    :documentation "Store all GObject signal handler IDs so that we can disconnect the signal handler when the object is finalised.
See https://developer.gnome.org/gobject/stable/gobject-Signals.html#signal-memory-management.")
   (gtk-proxy-url (quri:uri ""))
   (proxy-ignored-hosts '())
   (loading-webkit-history-p nil
                             :type boolean
                             :export nil
                             :documentation "Internal hack, do not use me!
WebKitGTK may trigger 'load-failed' when loading a page from the WebKit-history
cache.  Upstream bug?  We use this slot to know when to ignore these load
failures."))
  (:export-class-name-p t)
  (:export-accessor-names-p t)
  (:accessor-name-transformer (class*:make-name-transformer name)))
(define-user-class buffer (gtk-buffer))

(defclass webkit-web-context (webkit:webkit-web-context) ()
  (:metaclass gobject:gobject-class))

(defmethod initialize-instance :after ((web-context webkit-web-context) &key)
  #+webkit2-sandboxing
  (webkit:webkit-web-context-set-sandbox-enabled web-context t)
  web-context)

(defmethod data-directory ((web-context webkit-web-context))
  "Directly returns the CFFI object's `base-data-directory'"
  (webkit:webkit-website-data-manager-base-data-directory (webkit:webkit-web-context-website-data-manager web-context)))

(defmethod cache-directory ((web-context webkit-web-context))
  "Directly returns the CFFI object's `base-cache-directory'"
  (webkit:webkit-website-data-manager-base-cache-directory (webkit:webkit-web-context-website-data-manager web-context)))

(defclass webkit-web-context-ephemeral (webkit-web-context) ()
  (:metaclass gobject:gobject-class))

(defmethod initialize-instance :after ((web-context webkit-web-context-ephemeral) &key)
  (unless (webkit:webkit-web-context-is-ephemeral web-context)
    (error 'nyxt-web-context-condition :context web-context
                                       :message "Web Contexts of class webkit-web-context-ephemeral must be ephemeral")))

(defclass webkit-website-data-manager (webkit:webkit-website-data-manager) ()
  (:metaclass gobject:gobject-class))

;; `gobject::create-gobject-from-class' directly reads the initargs to
;; `make-instance', so this cannot be used to enforce ephemerality (or anything
;; else that needs to happen in the CFFI constructor).
(defmethod initialize-instance :after ((data-manager webkit-website-data-manager) &key)
  #+webkit2-tracking
  (webkit:webkit-website-data-manager-set-itp-enabled data-manager t)
  data-manager)

(defclass webkit-website-data-manager-ephemeral (webkit-website-data-manager) ()
  (:metaclass gobject:gobject-class))

(defmethod initialize-instance :after ((data-manager webkit-website-data-manager-ephemeral) &key)
  (unless (webkit:webkit-website-data-manager-is-ephemeral data-manager)
    (error 'nyxt-web-context-condition :context data-manager
                                       :message "Data Managers of class webkit-website-data-manager-ephemeral must be ephemeral")))

(defvar gtk-running-p nil
  "Non-nil if the GTK main loop is running.
See `ffi-initialize' and `ffi-kill-browser'.

Restarting GTK within the same Lisp image breaks WebKitGTK.
As a workaround, we never leave the GTK main loop when running from a REPL.

See https://github.com/atlas-engineer/nyxt/issues/740")

(defun renderer-thread-p ()
  #+darwin
  (string= "main thread" (bt:thread-name (bt:current-thread)))
  #-darwin
  (string= "cl-cffi-gtk main thread" (bt:thread-name (bt:current-thread))))

(defmacro within-gtk-thread (&body body)
  "Protected `gtk:within-gtk-thread'."
  `(gtk:within-gtk-thread
     (with-protect ("Error on GTK thread: ~a" :condition)
       ,@body)))

(defmethod ffi-within-renderer-thread ((browser gtk-browser) thunk)
  (declare (ignore browser))
  (within-gtk-thread
    (funcall thunk)))

(defun %within-renderer-thread (thunk)
  "If the current thread is the renderer thread, execute THUNK with `funcall'.
Otherwise run the THUNK on the renderer thread by passing it a channel and wait on the channel's result."
  (if (renderer-thread-p)
      (funcall thunk)
      (let ((channel (make-channel 1)))
        (within-gtk-thread
          (funcall thunk channel))
        (calispel:? channel))))

(defun %within-renderer-thread-async (thunk)
  "Same as `%within-renderer-thread' but THUNK is not blocking and does
not return."
  (if (renderer-thread-p)
      (funcall thunk)
      (within-gtk-thread
        (funcall thunk))))

(defmacro define-ffi-method (name args &body body)
  "Define an FFI method to run in the renderer thread.

Always returns a value retrieved from the renderer thread, using Calispel
channels if the current thread is not the renderer one.

It's a `defmethod' wrapper. If you don't need the body of the method to execute in
the renderer thread, use `defmethod' instead."
  (multiple-value-bind (forms declares docstring)
      (alex:parse-body body :documentation t)
    `(defmethod ,name ,args
       ,@(sera:unsplice docstring)
       ,@declares
       (if (renderer-thread-p)
           (progn
             ,@forms)
           (let ((channel (make-channel 1)))
             (within-gtk-thread
               (calispel:!
                channel
                (progn
                  ,@forms)))
             (calispel:? channel))))))

(defmethod ffi-initialize ((browser gtk-browser) urls startup-timestamp)
  "gtk:within-main-loop handles all the GTK initialization. On
   GNU/Linux, Nyxt could hang after 10 minutes if it's not
   used. Conversely, on Darwin, if gtk:within-main-loop is used, no
   drawing happens. Drawing operations on Darwin MUST originate from
   the main thread, which the GTK main loop is not guaranteed to be
   on."
  (log:debug "Initializing GTK Interface")
  (setf (uiop:getenv "WEBKIT_FORCE_SANDBOX") "0")
  (if gtk-running-p
      (within-gtk-thread
        (finalize browser urls startup-timestamp))
      #-darwin
      (progn
        (setf gtk-running-p t)
        (glib:g-set-prgname "nyxt")
        (gdk:gdk-set-program-class "Nyxt")
        (gtk:within-main-loop
          (with-protect ("Error on GTK thread: ~a" :condition)
            (finalize browser urls startup-timestamp)))
        (unless *run-from-repl-p*
          (gtk:join-gtk-main)))
      #+darwin
      (progn
        (setf gtk-running-p t)
        (glib:g-set-prgname "nyxt")
        (gdk:gdk-set-program-class "Nyxt")
        (finalize browser urls startup-timestamp)
        (gtk:gtk-main))))

(define-ffi-method ffi-kill-browser ((browser gtk-browser))
  ;; TODO: Terminating the GTK thread from the REPL seems to prevent Nyxt from
  ;; starting again.
  (unless *run-from-repl-p*
    (gtk:leave-gtk-main)))

(define-class data-manager-file (nyxt-file)
  ((context-name (error "Context name required."))
   (nfiles:name "web-context"))
  (:export-class-name-p t)
  (:accessor-name-transformer (class*:make-name-transformer name)))

(defmethod nfiles:resolve :around ((profile nosave-profile) (file data-manager-file))
  "We shouldn't store any `data-manager' data for `nosave-profile'."
  #p"")

(define-class data-manager-data-directory (nfiles:data-file data-manager-file)
  ()
  (:export-class-name-p t)
  (:accessor-name-transformer (class*:make-name-transformer name)))

(defmethod nfiles:resolve ((profile nyxt-profile) (file data-manager-data-directory))
  (sera:path-join
   (call-next-method)
   (pathname (str:concat (context-name file) "-web-context/"))))

(define-class data-manager-cache-directory (nfiles:cache-file data-manager-file)
  ()
  (:export-class-name-p t)
  (:accessor-name-transformer (class*:make-name-transformer name)))

(defmethod nfiles:resolve ((profile nyxt-profile) (file data-manager-cache-directory))
  (sera:path-join
   (call-next-method)
   (pathname (str:concat (context-name file) "-web-context/"))))

(define-class gtk-extensions-directory (nfiles:data-file data-manager-file)
  ((nfiles:name "gtk-extensions"))
  (:export-class-name-p t)
  (:accessor-name-transformer (class*:make-name-transformer name)))

(defmethod nfiles:resolve ((profile nyxt-profile) (file gtk-extensions-directory))
  (sera:path-join
   (call-next-method)
   (pathname (str:concat (context-name file) "-gtk-extensions/"))))

(define-class cookies-file (nfiles:data-file data-manager-file)
  ((nfiles:name "cookies"))
  (:export-class-name-p t)
  (:accessor-name-transformer (class*:make-name-transformer name)))

(defmethod nfiles:resolve ((profile nyxt-profile) (file cookies-file))
  (sera:path-join
   (call-next-method)
   (pathname (str:concat (context-name file) "-cookies"))))

(define-class gtk-download (download)
  ((gtk-object)
   (handler-ids
    :documentation "See `gtk-buffer' slot of the same name."))
  (:accessor-name-transformer (class*:make-name-transformer name)))
(define-user-class download (gtk-download))

(defclass webkit-web-view-ephemeral (webkit:webkit-web-view) ()
  (:metaclass gobject:gobject-class))

(defmethod initialize-instance :after ((web-view webkit-web-view-ephemeral) &key web-context)
  (unless (webkit:webkit-web-view-is-ephemeral web-view)
    (error 'nyxt-web-context-condition :context web-context
                                       :message "Tried to make an ephemeral web-view in a non-ephemeral context")))

(defun make-web-view (&key buffer ephemeral-p)
  "Return a web view instance.

If passed a context-name, a `nyxt:webkit-web-context' with that name is used for
the `webkit:webkit-web-view'.  If :buffer is an internal-buffer or is
not set, the browser's `+internal+' `nyxt:webkit-web-context' is
used.  Otherwise (such as an external web buffer), the `+default+'
webkit-web-context is used.

If ephemeral-p is set, the buffer is a nosave-buffer, or the current
`protife' is a `nosave-profile', then an ephemeral context is used, with
the same naming rules as above."
  (let ((internal-p (or (not buffer)
                        (internal-buffer-p buffer)))
        (ephemeral-p (or ephemeral-p
                         (when buffer (typep (profile buffer) 'nosave-profile))
                         (typep buffer 'nosave-buffer))))
    (make-instance (if ephemeral-p
                       'webkit-web-view-ephemeral
                       'webkit:webkit-web-view)
                   :web-context (get-context *browser* (if internal-p +internal+ (context-name buffer))
                                             buffer
                                             :ephemeral-p ephemeral-p))))

(defun make-decide-policy-handler (buffer)
  (lambda (web-view response-policy-decision policy-decision-type-response)
    (declare (ignore web-view))
    ;; Even if errors are caught with `with-protect', we must ignore the policy
    ;; decision on error, lest we load a web page in an internal buffer for
    ;; instance.
    (g:g-object-ref (g:pointer response-policy-decision))
    (run-thread "asynchronous decide-policy processing"
      (handler-bind ((error (lambda (c)
                              (echo-warning "decide policy error: ~a" c)
                              ;; TODO: Don't automatically call the restart when from the REPL?
                              ;; (unless *run-from-repl-p*
                              ;;   (invoke-restart 'ignore-policy-decision))
                              (invoke-restart 'ignore-policy-decision))))
        (restart-case (on-signal-decide-policy buffer response-policy-decision policy-decision-type-response)
          (ignore-policy-decision ()
            (webkit:webkit-policy-decision-ignore response-policy-decision)))))
    t))


(defmacro connect-signal-function (object signal fn)
  "Connect SIGNAL to OBJECT with a function FN.
OBJECT must have the `gtk-object' and `handler-ids' slots.
See also `connect-signal'."
  `(let ((handler-id (gobject:g-signal-connect
                      (gtk-object ,object) ,signal ,fn)))
     (push handler-id (handler-ids ,object))))

(defmacro connect-signal (object signal new-thread-p (&rest args) &body body)
  "Connect SIGNAL to OBJECT with a lambda that takes ARGS.
OBJECT must have the `gtk-object' and `handler-ids' slots. If
`new-thread-p' is non-nil, then a new thread will be launched for the
response.  The BODY is wrapped with `with-protect'."
  (multiple-value-bind (forms declares documentation)
      (alex:parse-body body :documentation t)
    `(let ((handler-id (gobject:g-signal-connect
                        (gtk-object ,object) ,signal
                        (lambda (,@args)
                          ,@(sera:unsplice documentation)
                          ,@declares
                          ,(if new-thread-p
                               `(run-thread "renderer signal handler"
                                    ,@forms)
                               `(with-protect ("Error in signal on renderer thread: ~a" :condition)
                                  ,@forms))))))
       (push handler-id (handler-ids ,object)))))

(defmethod initialize-instance :after ((buffer status-buffer) &key)
  (%within-renderer-thread-async
   (lambda ()
     (with-slots (gtk-object) buffer
       (setf gtk-object (make-web-view :buffer buffer))
       (connect-signal-function
        buffer "decide-policy"
        (make-decide-policy-handler buffer))))))

(defmethod initialize-instance :after ((window gtk-window) &key)
  (%within-renderer-thread-async
   (lambda ()
     (with-slots (gtk-object root-box-layout horizontal-box-layout
                  panel-buffer-container-left
                  panel-buffer-container-right
                  main-buffer-container
                  active-buffer prompt-buffer-container
                  prompt-buffer-view
                  status-buffer status-container
                  message-container message-view
                  id key-string-buffer) window
       (setf id (get-unique-identifier *browser*))
       (setf gtk-object (make-instance 'gtk:gtk-window
                                       :type :toplevel
                                       :default-width 1024
                                       :default-height 768))
       (setf root-box-layout (make-instance 'gtk:gtk-box
                                            :orientation :vertical
                                            :spacing 0))
       (setf horizontal-box-layout (make-instance 'gtk:gtk-box
                                                  :orientation :horizontal
                                                  :spacing 0))
       (setf panel-buffer-container-left (make-instance 'gtk:gtk-box
                                                        :orientation :horizontal
                                                        :spacing 0))
       (setf panel-buffer-container-right (make-instance 'gtk:gtk-box
                                                         :orientation :horizontal
                                                         :spacing 0))
       (setf main-buffer-container (make-instance 'gtk:gtk-box
                                                  :orientation :vertical
                                                  :spacing 0))
       (setf prompt-buffer-container (make-instance 'gtk:gtk-box
                                                    :orientation :vertical
                                                    :spacing 0))
       (setf message-container (make-instance 'gtk:gtk-box
                                              :orientation :vertical
                                              :spacing 0))
       (setf status-container (make-instance 'gtk:gtk-box
                                             :orientation :vertical
                                             :spacing 0))
       (setf key-string-buffer (make-instance 'gtk:gtk-entry))
       (setf active-buffer (make-instance 'dummy-buffer))

       ;; Add the views to the box layout and to the window
       (gtk:gtk-box-pack-start main-buffer-container (gtk-object active-buffer) :expand t :fill t)
       (gtk:gtk-box-pack-start horizontal-box-layout panel-buffer-container-left :expand nil)
       (gtk:gtk-box-pack-start horizontal-box-layout main-buffer-container :expand t :fill t)
       (gtk:gtk-box-pack-start horizontal-box-layout panel-buffer-container-right :expand nil)
       (gtk:gtk-box-pack-start root-box-layout horizontal-box-layout :expand t :fill t)

       (setf message-view (make-web-view))
       (gtk:gtk-box-pack-end root-box-layout message-container :expand nil)
       (gtk:gtk-box-pack-start message-container message-view :expand t)
       (setf (gtk:gtk-widget-size-request message-container)
             (list -1 (message-buffer-height window)))

       (setf status-buffer (make-instance 'user-status-buffer))
       (gtk:gtk-box-pack-end root-box-layout status-container :expand nil)
       (gtk:gtk-box-pack-start status-container (gtk-object status-buffer) :expand t)
       (setf (gtk:gtk-widget-size-request status-container)
             (list -1 (height status-buffer)))

       (setf prompt-buffer-view (make-web-view))
       (gtk:gtk-box-pack-end root-box-layout prompt-buffer-container :expand nil)
       (gtk:gtk-box-pack-start prompt-buffer-container prompt-buffer-view :expand t)
       (setf (gtk:gtk-widget-size-request prompt-buffer-container)
             (list -1 0))

       (gtk:gtk-container-add gtk-object root-box-layout)
       (setf (slot-value *browser* 'last-active-window) window)
       (unless *headless-p*
         (gtk:gtk-widget-show-all gtk-object))
       (connect-signal window "key_press_event" nil (widget event)
         (declare (ignore widget))
         #+darwin
         (push-modifier *browser* event)
         (on-signal-key-press-event window event))
       (connect-signal window "key_release_event" nil (widget event)
         (declare (ignore widget))
         #+darwin
         (pop-modifier *browser* event)
         (on-signal-key-release-event window event))
       (connect-signal window "destroy" nil (widget)
         (declare (ignore widget))
         (on-signal-destroy window))
       (connect-signal window "window-state-event" nil (widget event)
         (declare (ignore widget))
         (setf (fullscreen-p window)
               (find :fullscreen
                     (gdk:gdk-event-window-state-new-window-state event)))
         nil)))))

(define-ffi-method on-signal-destroy ((window gtk-window))
  ;; remove buffer from window to avoid corruption of buffer
  (gtk:gtk-container-remove (root-box-layout window) (gtk-object (active-buffer window)))
  (window-delete window))

(define-ffi-method ffi-window-delete ((window gtk-window))
  (gtk:gtk-widget-destroy (gtk-object window)))

(define-ffi-method ffi-window-fullscreen ((window gtk-window))
  (gtk:gtk-window-fullscreen (gtk-object window)))

(define-ffi-method ffi-window-unfullscreen ((window gtk-window))
  (gtk:gtk-window-unfullscreen (gtk-object window)))

(defun derive-key-string (keyval character)
  "Return string representation of a keyval.
Return nil when key must be discarded, e.g. for modifiers."
  (let ((result
          (match keyval
            ((or "Alt_L" "Super_L" "Control_L" "Shift_L"
                 "Alt_R" "Super_R" "Control_R" "Shift_R"
                 "ISO_Level3_Shift" "Arabic_switch")
             ;; Discard modifiers (they usually have a null character).
             nil)
            ((guard s (str:contains? "KP_" s))
             (str:replace-all "KP_" "keypad" s))
            ;; With a modifier, "-" does not print, so we me must translate it
            ;; to "hyphen" just like in `printable-p'.
            ("minus" "hyphen")
            ;; In most cases, return character and not keyval for punctuation.
            ;; For instance, C-[ is not printable but the keyval is "bracketleft".
            ;; ASCII control characters like Escape, Delete or BackSpace have a
            ;; non-printable character (usually beneath #\space), so we use the
            ;; keyval in this case.
            ;; Even if space in printable, C-space is not so we return the
            ;; keyval in this case.
            (_ (if (or (char<= character #\space)
                       (char= character #\Del))
                   keyval
                   (string character))))))
    (if (< 1 (length result))
        (str:replace-all "_" "" (string-downcase result))
        result)))

#+darwin
(defmethod push-modifier ((browser gtk-browser) event)
  (let* ((modifier-state (gdk:gdk-event-key-state event))
         (key-value (gdk:gdk-event-key-keyval event))
         (key-value-name (gdk:gdk-keyval-name key-value)))
    (when (member :control-mask modifier-state)
      (push :control-mask (modifiers browser)))
    (when (member :shift-mask modifier-state)
      (push :shift-mask (modifiers browser)))
    (when (or (string= key-value-name "Arabic_switch")
              (string= key-value-name "Alt_L")
              (string= key-value-name "Alt_R"))
      (push :mod1-mask (modifiers browser)))
    (when (and (member :mod2-mask modifier-state)
               (member :meta-mask modifier-state))
      (push :super-mask (modifiers browser))))
  (setf (modifiers browser) (delete-duplicates (modifiers browser))))

#+darwin
(defmethod pop-modifier ((browser gtk-browser) event)
  (let* ((modifier-state (gdk:gdk-event-key-state event))
         (key-value (gdk:gdk-event-key-keyval event))
         (key-value-name (gdk:gdk-keyval-name key-value)))
    (when (member :control-mask modifier-state)
      (alex:deletef (modifiers browser) :control-mask))
    (when (member :shift-mask modifier-state)
      (alex:deletef (modifiers browser) :shift-mask))
    (when (or (string= key-value-name "Arabic_switch")
              (string= key-value-name "Alt_L")
              (string= key-value-name "Alt_R"))
      (alex:deletef (modifiers browser) :mod1-mask))
    (when (and (member :mod2-mask modifier-state)
               (member :meta-mask modifier-state))
      (alex:deletef (modifiers browser) :super-mask))))

(-> translate-modifiers (list &optional gdk:gdk-event) list)
(defun translate-modifiers (modifier-state &optional event)
  "Return list of modifiers fit for `keymap:make-key'.
See `gtk-browser's `modifier-translator' slot."
  (declare (ignore event))
  (let ((plist '(:control-mask "control"
                 :mod1-mask "meta"
                 :mod5-mask nil
                 :shift-mask "shift"
                 :super-mask "super"
                 :hyper-mask "hyper"
                 :meta-mask nil
                 :lock-mask nil)))
    (delete nil (mapcar (lambda (mod) (getf plist mod)) modifier-state))))

#+darwin
(defun key-event-modifiers (key-event)
  (declare (ignore key-event))
  (modifiers *browser*))

#-darwin
(defun key-event-modifiers (key-event)
  (gdk:gdk-event-key-state key-event))

;; REVIEW: Remove after upstream fix is merged in Quicklisp, see https://github.com/crategus/cl-cffi-gtk/issues/74.
;; Wait for https://github.com/Ferada/cl-cffi-gtk/issues/new.
(defun gdk-event-button-state (button-event)
  "Return BUTTON-EVENT modifiers as a `gdk-modifier-type', i.e. a list of keywords."
  (let ((state (gdk:gdk-event-button-state button-event)))
    (if (listp state)
        state
        (cffi:with-foreign-objects ((modifiers 'gdk:gdk-modifier-type))
          (setf (cffi:mem-ref modifiers 'gdk:gdk-modifier-type) state)
          (cffi:mem-ref modifiers 'gdk:gdk-modifier-type)))))

#+darwin
(defun button-event-modifiers (button-event)
  (declare (ignore button-event))
  (modifiers *browser*))

#-darwin
(defun button-event-modifiers (button-event)
  (gdk-event-button-state button-event))

#+darwin
(defun scroll-event-modifiers (scroll-event)
  (declare (ignore scroll-event))
  (modifiers *browser*))

#-darwin
(defun scroll-event-modifiers (scroll-event)
  (gdk:gdk-event-scroll-state scroll-event))

(defmethod printable-p ((window gtk-window) event)
  "Return the printable value of EVENT."
  ;; Generate the result of the current keypress into the dummy
  ;; key-string-buffer (a GtkEntry that's never shown on screen) so that we
  ;; can collect the printed representation of composed keypress, such as dead
  ;; keys.
  (gtk:gtk-entry-im-context-filter-keypress (key-string-buffer window) event)
  (when (<= 1 (gtk:gtk-entry-text-length (key-string-buffer window)))
    (prog1
        (match (gtk:gtk-entry-text (key-string-buffer window))
          ;; Special cases: these characters are not supported as is for keyspecs.
          ;; See `self-insert' for the reverse translation.
          (" " "space")
          ("-" "hyphen")
          (character character))
      (setf (gtk:gtk-entry-text (key-string-buffer window)) ""))))

(defun update-prompt (buffer)
  (run-thread "Prompt updater"
    ;; Rebind prompt-buffer to ensure the watcher does not mix up the
    ;; different prompt-buffers.
    (let ((prompt-buffer buffer))
      (update-prompt-input prompt-buffer))))

(define-ffi-method on-signal-key-press-event ((sender gtk-window) event)
  (let* ((keycode (gdk:gdk-event-key-hardware-keycode event))
         (keyval (gdk:gdk-event-key-keyval event))
         (keyval-name (gdk:gdk-keyval-name keyval))
         (character (gdk:gdk-keyval-to-unicode keyval))
         (printable-value (printable-p sender event))
         (key-string (or printable-value
                         (derive-key-string keyval-name character)))
         (modifiers (funcall (modifier-translator *browser*)
                             (key-event-modifiers event)
                             event))
         (buffer (or (current-prompt-buffer)
                     (active-buffer sender))))
    (if modifiers
        (log:debug key-string keycode character keyval-name modifiers)
        (log:debug key-string keycode character keyval-name))
    (when (prompt-buffer-p buffer)
      (update-prompt buffer))
    (if key-string
        (progn
          (alex:appendf (key-stack sender)
                        (list (keymap:make-key :code keycode
                                               :value key-string
                                               :modifiers modifiers
                                               :status :pressed)))
          (funcall (input-dispatcher sender) event
                   buffer
                   sender printable-value))
        ;; Do not forward modifier-only to renderer.
        t)))

(defmethod gtk-object ((prompt-buffer prompt-buffer))
  (prompt-buffer-view (window prompt-buffer)))

(define-ffi-method on-signal-key-release-event ((sender gtk-window) event)
  (declare (ignore sender event))
  ;; REVIEW: Is there any use for handling release events?
  nil)

(defun sender-window (sender)
  (or (find sender (window-list) :key #'active-prompt-buffers)
      (find sender (window-list) :key #'active-buffer)
      (current-window)))

(define-ffi-method on-signal-button-press-event ((sender gtk-buffer) event)
  (let* ((button (gdk:gdk-event-button-button event))
         ;; REVIEW: No need to store X and Y?
         ;; (x (gdk:gdk-event-button-x event))
         ;; (y (gdk:gdk-event-button-y event))
         (window (sender-window sender))
         (key-string (format nil "button~s" button))
         (modifiers (funcall (modifier-translator *browser*)
                             (button-event-modifiers event)
                             event))
         (buffer (or (current-prompt-buffer)
                     sender)))
    (when (prompt-buffer-p buffer)
      (update-prompt buffer))
    (when key-string
      (alex:appendf (key-stack window)
                    (list (keymap:make-key
                           :value key-string
                           :modifiers modifiers
                           :status :pressed)))
      (funcall (input-dispatcher window) event sender window nil))))

(define-ffi-method on-signal-scroll-event ((sender gtk-buffer) event)
  (let* ((button (match (gdk:gdk-event-scroll-direction event)
                   (:up 4)
                   (:down 5)
                   (:left 6)
                   (:right 7)
                   (:smooth
                    (cond
                      ((>= 0 (gdk:gdk-event-scroll-delta-y event))
                       4)
                      ((< 0 (gdk:gdk-event-scroll-delta-y event))
                       5)
                      ((>= 0 (gdk:gdk-event-scroll-delta-x event))
                       6)
                      ((< 0 (gdk:gdk-event-scroll-delta-x event))
                       7)))))
         (window (sender-window sender))
         (key-string (format nil "button~s" button))
         (modifiers (funcall (modifier-translator *browser*)
                             (scroll-event-modifiers event)
                             event)))
    (when key-string
      (alex:appendf (key-stack window)
                    (list (keymap:make-key
                           :value key-string
                           :modifiers modifiers
                           :status :pressed)))
      (funcall (input-dispatcher window) event sender window nil))))

(define-class gtk-scheme ()
  ((display-isolated-p
    nil
    :documentation "Display isolated schemes cannot be displayed (in iframes, for example) by other schemes.")
   (empty-document-p
    nil
    :documentation "Empty document schemes can be loaded synchronously by websites referring to them."))
  (:export-class-name-p t)
  (:export-accessor-names-p t)
  (:accessor-name-transformer (class*:make-name-transformer name)))
(define-user-class scheme (gtk-scheme))

(defun make-context (name buffer &key ephemeral-p)
  (let* ((context
           (if ephemeral-p
               ;; An ephemeral data-manager cannot be given any directories, even if they are set to nil.
               (make-instance 'webkit-web-context-ephemeral
                              :website-data-manager
                              (make-instance 'webkit-website-data-manager-ephemeral
                                             :is-ephemeral t))
               (let ((data-manager-data-directory (make-instance 'data-manager-data-directory :context-name name))
                     (data-manager-cache-directory (make-instance 'data-manager-cache-directory :context-name name)))
                 (make-instance 'webkit-web-context
                                :website-data-manager
                                (make-instance 'webkit-website-data-manager
                                               :base-data-directory (uiop:native-namestring
                                                                     (nfiles:expand data-manager-data-directory))
                                               :base-cache-directory (uiop:native-namestring
                                                                      (nfiles:expand data-manager-cache-directory)))))))
         (gtk-extensions-path (nfiles:expand (make-instance 'gtk-extensions-directory :context-name name)))
         (cookie-manager (webkit:webkit-web-context-get-cookie-manager context)))
    (webkit:webkit-web-context-add-path-to-sandbox
     context (namestring (asdf:system-relative-pathname :nyxt "libraries/web-extensions/")) t)
    (unless (uiop:emptyp gtk-extensions-path)
      ;; TODO: Should we also use `connect-signal' here?  Does this yield a memory leak?
      (gobject:g-signal-connect
       context "initialize-web-extensions"
       (lambda (context)
         (with-protect ("Error in signal thread: ~a" :condition)
           (webkit:webkit-web-context-set-web-extensions-directory
            context
            (uiop:native-namestring gtk-extensions-path))
           (webkit:webkit-web-context-set-web-extensions-initialization-user-data
            context (glib:g-variant-new-string
                     (flet ((describe-extension (extension &key privileged-p)
                              (cons (nyxt/web-extensions::name extension)
                                    (vector (id extension)
                                            (nyxt/web-extensions::manifest extension)
                                            (if privileged-p 1 0)
                                            (nyxt/web-extensions::extension-files extension)
                                            (id buffer)))))
                       (let ((extensions
                               (when buffer
                                 (sera:filter #'nyxt/web-extensions::extension-p (modes buffer)))))
                         (encode-json
                          (if (or (background-buffer-p buffer)
                                  (panel-buffer-p buffer))
                              (alex:when-let* ((extension
                                                (or (find buffer extensions :key #'background-buffer)
                                                    (find buffer extensions :key #'nyxt/web-extensions:popup-buffer))))
                                (list (describe-extension extension :privileged-p t)))
                              (mapcar #'describe-extension extensions)))))))))))
    (maphash
     (lambda (scheme scheme-object)
       (webkit:webkit-web-context-register-uri-scheme-callback
        context scheme
        (lambda (request)
          (funcall* (callback scheme-object)
                    (webkit:webkit-uri-scheme-request-get-uri request)
                    (find (webkit:webkit-uri-scheme-request-get-web-view request)
                          (delete nil
                                  (append (list (status-buffer (current-window)))
                                          (active-prompt-buffers (current-window))
                                          (panel-buffers (current-window))
                                          (buffer-list))) :key #'gtk-object)))
        (or (error-callback scheme-object)
            (lambda (condition)
              (echo-warning "Error while routing ~s resource: ~a" scheme condition))))
       ;; We err on the side of caution, assigning the most restrictive policy
       ;; out of those provided. Should it be the other way around?
       (let ((manager (webkit:webkit-web-context-get-security-manager context)))
         (cond
           ((local-p scheme-object)
            (webkit:webkit-security-manager-register-uri-scheme-as-local
             manager scheme))
           ((no-access-p scheme-object)
            (webkit:webkit-security-manager-register-uri-scheme-as-no-access
             manager scheme))
           ((display-isolated-p scheme-object)
            (webkit:webkit-security-manager-register-uri-scheme-as-display-isolated
             manager scheme))
           ((secure-p scheme-object)
            (webkit:webkit-security-manager-register-uri-scheme-as-secure
             manager scheme))
           ((cors-enabled-p scheme-object)
            (webkit:webkit-security-manager-register-uri-scheme-as-cors-enabled
             manager scheme))
           ((empty-document-p scheme-object)
            (webkit:webkit-security-manager-register-uri-scheme-as-empty-document
             manager scheme)))))
     nyxt::*schemes*)
    (unless (or ephemeral-p
                (internal-context-p name))
      (let ((cookies-path (nfiles:expand (make-instance 'cookies-file :context-name name))))
        (webkit:webkit-cookie-manager-set-persistent-storage
         cookie-manager
         (uiop:native-namestring cookies-path)
         :webkit-cookie-persistent-storage-text))
      (set-cookie-policy cookie-manager (default-cookie-policy *browser*)))
    context))

(defun internal-context-p (name)
  (equal name +internal+))

(defmethod initialize-instance :after ((buffer gtk-buffer) &key extra-modes
                                                             no-hook-p
                                       &allow-other-keys)
  "Make BUFFER with EXTRA-MODES.
See `finalize-buffer'."
  (ffi-buffer-make buffer)
  (finalize-buffer buffer :extra-modes extra-modes :no-hook-p no-hook-p))

(define-ffi-method ffi-buffer-url ((buffer gtk-buffer))
  (quri:uri (webkit:webkit-web-view-uri (gtk-object buffer))))

(define-ffi-method ffi-buffer-title ((buffer gtk-buffer))
  (or (webkit:webkit-web-view-title (gtk-object buffer)) ""))

(define-ffi-method on-signal-load-failed-with-tls-errors ((buffer gtk-buffer) certificate url)
  "Return nil to propagate further (i.e. raise load-failed signal), T otherwise."
  (let* ((context (webkit:webkit-web-view-web-context (gtk-object buffer)))
         (host (quri:uri-host url)))
    (if (and (certificate-exceptions buffer)
             (member host (certificate-exceptions buffer) :test #'string=))
        (progn
          (webkit:webkit-web-context-allow-tls-certificate-for-host
           context
           (gobject:pointer certificate)
           host)
          (buffer-load url :buffer buffer)
          t)
        (progn
          (tls-help buffer url)
          t))))

(define-ffi-method on-signal-decide-policy ((buffer gtk-buffer) response-policy-decision policy-decision-type-response)
  (let ((is-new-window nil) (is-known-type t) (event-type :other)
        (navigation-action nil) (navigation-type nil)
        (mouse-button nil) (modifiers ())
        (url nil) (request nil))
    (match policy-decision-type-response
      (:webkit-policy-decision-type-navigation-action
       (setf navigation-type (webkit:webkit-navigation-policy-decision-navigation-type response-policy-decision)))
      (:webkit-policy-decision-type-new-window-action
       (setf navigation-type (webkit:webkit-navigation-policy-decision-navigation-type response-policy-decision))
       (setf is-new-window t))
      (:webkit-policy-decision-type-response
       (setf request (webkit:webkit-response-policy-decision-request response-policy-decision))
       (setf is-known-type
             (webkit:webkit-response-policy-decision-is-mime-type-supported
              response-policy-decision))))
    ;; Set Event-Type
    (setf event-type
          (match navigation-type
            (:webkit-navigation-type-link-clicked :link-click)
            (:webkit-navigation-type-form-submitted :form-submission)
            (:webkit-navigation-type-back-forward :backward-or-forward)
            (:webkit-navigation-type-reload :reload)
            (:webkit-navigation-type-form-resubmitted :form-resubmission)
            (_ :other)))
    ;; Get Navigation Parameters from WebKitNavigationAction object
    (when navigation-type
      (setf navigation-action (webkit:webkit-navigation-policy-decision-get-navigation-action
                               response-policy-decision))
      (setf request (webkit:webkit-navigation-action-get-request navigation-action))
      (setf mouse-button (format nil "button~d"
                                 (webkit:webkit-navigation-action-get-mouse-button
                                  navigation-action)))
      (setf modifiers (funcall (modifier-translator *browser*)
                               (webkit:webkit-navigation-action-get-modifiers navigation-action))))
    (setf url (quri:uri (webkit:webkit-uri-request-uri request)))
    (let ((request-data (preprocess-request
                         (make-instance 'request-data
                                        :buffer buffer
                                        :url (quri:copy-uri url)
                                        :keys (unless (uiop:emptyp mouse-button)
                                                (list (keymap:make-key
                                                       :value mouse-button
                                                       :modifiers modifiers)))
                                        :event-type event-type
                                        :new-window-p is-new-window
                                        :known-type-p is-known-type))))
      (if request-data
          (if (null (hooks:handlers (request-resource-hook buffer)))
              (progn
                (log:debug "Forward to ~s's renderer (no request-resource-hook handlers)."
                           buffer)
                (webkit:webkit-policy-decision-use response-policy-decision))
              (let ((request-data
                      (hooks:run-hook
                       (request-resource-hook buffer)
                       (hooks:run-hook (pre-request-hook buffer)
                                       request-data))))
                (cond
                  ((not (typep request-data 'request-data))
                   (log:debug "Don't forward to ~s's renderer (non request data)."
                              buffer)
                   (webkit:webkit-policy-decision-ignore response-policy-decision))
                  ((quri:uri= url (url request-data))
                   (log:debug "Forward to ~s's renderer (unchanged URL)."
                              buffer)
                   (webkit:webkit-policy-decision-use response-policy-decision))
                  ((and (quri:uri= (url buffer) (quri:uri (webkit:webkit-uri-request-uri request)))
                        (not (quri:uri= (quri:uri (webkit:webkit-uri-request-uri request))
                                        (url request-data))))
                   ;; Low-level URL string, we must not render the puni codes so use
                   ;; `quri:render-uri'.
                   (setf (webkit:webkit-uri-request-uri request) (quri:render-uri (url request-data)))
                   (log:debug "Don't forward to ~s's renderer (resource request replaced with ~s)."
                              buffer
                              (render-url (url request-data)))
                   ;; Warning: We must ignore the policy decision _before_ we
                   ;; start the new load request, or else WebKit will be
                   ;; confused about which URL to load.
                   (webkit:webkit-policy-decision-ignore response-policy-decision)
                   (webkit:webkit-web-view-load-request (gtk-object buffer) request))
                  (t
                   (log:info "Cannot redirect to ~a in an iframe, forwarding to the original URL (~a)."
                             (render-url (url request-data))
                             (webkit:webkit-uri-request-uri request))
                   (webkit:webkit-policy-decision-use response-policy-decision)))))
          (progn
            (log:debug "Don't forward to ~s's renderer (non request data)."
                       buffer)
            (webkit:webkit-policy-decision-ignore response-policy-decision))))))

;; See https://webkitgtk.org/reference/webkit2gtk/stable/WebKitWebView.html#WebKitLoadEvent
(defmethod on-signal-load-changed ((buffer gtk-buffer) load-event)
  ;; `url' can be nil if buffer didn't have any URL associated
  ;; to the web view, e.g. the start page, or if the load failed.
  (when (web-buffer-p buffer)
    (let* ((url (ignore-errors
                 (quri:uri (webkit:webkit-web-view-uri (gtk-object buffer)))))
           (url (if (url-empty-p url)
                    (url buffer)
                    url)))
      (cond ((eq load-event :webkit-load-started)
             (setf (slot-value buffer 'status) :loading)
             (nyxt/web-extensions::tabs-on-updated buffer '(("status" . "loading")))
             (nyxt/web-extensions::tabs-on-updated buffer `(("url" . ,(render-url url))))
             (print-status nil (get-containing-window-for-buffer buffer *browser*))
             (on-signal-load-started buffer url)
             (unless (internal-url-p url)
               (echo "Loading ~s." (render-url url))))
            ((eq load-event :webkit-load-redirected)
             (setf (url buffer) url)
             (nyxt/web-extensions::tabs-on-updated buffer '(("status" . "loading")))
             (nyxt/web-extensions::tabs-on-updated buffer `(("url" . ,(render-url url))))
             (on-signal-load-redirected buffer url))
            ((eq load-event :webkit-load-committed)
             (nyxt/web-extensions::tabs-on-updated buffer '(("status" . "loading")))
             (nyxt/web-extensions::tabs-on-updated buffer `(("url" . ,(render-url url))))
             (on-signal-load-committed buffer url))
            ((eq load-event :webkit-load-finished)
             (setf (loading-webkit-history-p buffer) nil)
             (unless (eq (slot-value buffer 'status) :failed)
               (setf (slot-value buffer 'status) :finished))
             (nyxt/web-extensions::tabs-on-updated buffer '(("status" . "complete")))
             (nyxt/web-extensions::tabs-on-updated buffer `(("url" . ,(render-url url))))
             (on-signal-load-finished buffer url)
             (print-status nil (get-containing-window-for-buffer buffer *browser*))
             (unless (internal-url-p url)
               (echo "Finished loading ~s." (render-url url))))))))

(define-ffi-method on-signal-mouse-target-changed ((buffer gtk-buffer) hit-test-result modifiers)
  (declare (ignore modifiers))
  (alex:if-let ((url (or (webkit:webkit-hit-test-result-link-uri hit-test-result)
                         (webkit:webkit-hit-test-result-image-uri hit-test-result)
                         (webkit:webkit-hit-test-result-media-uri hit-test-result))))
    (progn
      (print-message (str:concat "→ " (quri:url-decode url :lenient t)))
      (setf (url-at-point buffer) (quri:uri url)))
    (progn
      (print-message "")
      (setf (url-at-point buffer) (quri:uri "")))))

(define-ffi-method ffi-window-make ((browser gtk-browser))
  "Make a window."
  (make-instance 'user-window))

(define-ffi-method ffi-window-to-foreground ((window gtk-window))
  "Show window in foreground."
  (unless *headless-p*
    (gtk:gtk-window-present (gtk-object window)))
  (setf (slot-value *browser* 'last-active-window) window))

(define-ffi-method ffi-window-set-title ((window gtk-window) title)
  "Set the title for a window."
  (setf (gtk:gtk-window-title (gtk-object window)) title))

(define-ffi-method ffi-window-active ((browser gtk-browser))
  "Return the window object for the current window."
  (setf (slot-value browser 'last-active-window)
        (or (find-if #'gtk:gtk-window-is-active (window-list) :key #'gtk-object)
            (slot-value browser 'last-active-window)
            (first (window-list)))))

(define-ffi-method ffi-window-set-buffer ((window gtk-window) (buffer gtk-buffer) &key (focus t))
  "Set BROWSER's WINDOW buffer to BUFFER."
  (let ((old-buffer (active-buffer window)))
    (gtk:gtk-container-remove (main-buffer-container window) (gtk-object old-buffer))
    (gtk:gtk-box-pack-start (main-buffer-container window) (gtk-object buffer) :expand t :fill t)
    (unless *headless-p*
      (gtk:gtk-widget-show (gtk-object buffer)))
    (when focus
      (gtk:gtk-widget-grab-focus (gtk-object buffer)))
    (nyxt/web-extensions::tabs-on-activated old-buffer buffer)
    (nyxt/web-extensions::tabs-on-updated buffer `(("attention" . t)))
    (nyxt/web-extensions::tabs-on-updated
     old-buffer (alex:alist-hash-table `(("attention" . nil))))
    buffer))

(define-ffi-method ffi-window-add-panel-buffer ((window gtk-window) (buffer panel-buffer) side)
  "Add a panel buffer to a window."
  (match side
    (:left (gtk:gtk-box-pack-start (panel-buffer-container-left window) (gtk-object buffer))
           (push buffer (panel-buffers-left window)))
    (:right (gtk:gtk-box-pack-end (panel-buffer-container-right window) (gtk-object buffer))
            (push buffer (panel-buffers-right window))))
  (setf (gtk:gtk-widget-size-request (gtk-object buffer))
        (list (width buffer) -1))
  (unless *headless-p*
    (gtk:gtk-widget-show (gtk-object buffer))))

(define-ffi-method ffi-window-set-panel-buffer-width ((window gtk-window) (buffer panel-buffer) width)
  "Set the width of a panel buffer."
  (setf (gtk:gtk-widget-size-request (gtk-object buffer))
        (list width -1)))

(define-ffi-method ffi-window-delete-panel-buffer ((window gtk-window) (buffer panel-buffer))
  "Remove a panel buffer from a window."
  (cond ((find buffer (panel-buffers-left window))
         (setf (panel-buffers-left window) (remove buffer (panel-buffers-left window)))
         (gtk:gtk-container-remove (panel-buffer-container-left window) (gtk-object buffer)))
        ((find buffer (panel-buffers-right window))
         (setf (panel-buffers-right window) (remove buffer (panel-buffers-right window)))
         (gtk:gtk-container-remove (panel-buffer-container-right window) (gtk-object buffer)))))

(define-ffi-method ffi-window-set-prompt-buffer-height ((window gtk-window) height)
  (setf (gtk:gtk-widget-size-request (prompt-buffer-container window))
        (list -1 height))
  (if (eql 0 height)
      (gtk:gtk-widget-grab-focus (gtk-object (active-buffer window)))
      (gtk:gtk-widget-grab-focus (prompt-buffer-view window))))

(define-ffi-method ffi-window-get-prompt-buffer-height ((window gtk-window))
  (nth-value 1 (gtk:gtk-widget-size-request (prompt-buffer-container window))))

(define-ffi-method ffi-window-get-status-buffer-height ((window gtk-window))
  (nth-value 1 (gtk:gtk-widget-size-request (status-container window))))

(define-ffi-method ffi-window-set-status-buffer-height ((window gtk-window) height)
  (setf (gtk:gtk-widget-size-request (status-container window))
        (list -1 height)))

(define-ffi-method ffi-window-get-message-buffer-height ((window gtk-window))
  (nth-value 1 (gtk:gtk-widget-size-request (message-container window))))

(define-ffi-method ffi-window-set-message-buffer-height ((window gtk-window) height)
  (setf (gtk:gtk-widget-size-request (message-container window))
        (list -1 height)))

(defun process-file-chooser-request (web-view file-chooser-request)
  (declare (ignore web-view))
  (with-protect ("Failed to process file chooser request: ~a" :condition)
    (when (native-dialogs *browser*)
      (gobject:g-object-ref (gobject:pointer file-chooser-request))
      (run-thread "file chooser"
        (let ((files (mapcar
                      #'uiop:native-namestring
                      (handler-case
                          (prompt :prompt (format
                                           nil "File~@[s~*~] to input"
                                           (webkit:webkit-file-chooser-request-select-multiple
                                            file-chooser-request))
                                  :input (or
                                          (and
                                           (webkit:webkit-file-chooser-request-selected-files
                                            file-chooser-request)
                                           (first
                                            (webkit:webkit-file-chooser-request-selected-files
                                             file-chooser-request)))
                                          (uiop:native-namestring (uiop:getcwd)))
                                  :extra-modes '(nyxt/file-manager-mode:file-manager-mode)
                                  :sources (list (make-instance 'nyxt/file-manager-mode:user-file-source)))
                        (nyxt-prompt-buffer-canceled ()
                          nil)))))
          (if files
              (webkit:webkit-file-chooser-request-select-files
               file-chooser-request
               (cffi:foreign-alloc :string
                                   :initial-contents (if (webkit:webkit-file-chooser-request-select-multiple
                                                          file-chooser-request)
                                                         (mapcar #'cffi:foreign-string-alloc files)
                                                         (list (cffi:foreign-string-alloc (first files))))
                                   :count (if (webkit:webkit-file-chooser-request-select-multiple
                                               file-chooser-request)
                                              (length files)
                                              1)
                                   :null-terminated-p t))
              (webkit:webkit-file-chooser-request-cancel file-chooser-request))))
      t)))

(defvar *css-colors*
  '("AliceBlue" "AntiqueWhite" "Aqua" "Aquamarine" "Azure" "Beige" "Bisque" "Black" "BlanchedAlmond"
    "Blue" "BlueViolet" "Brown" "BurlyWood" "CadetBlue" "Chartreuse" "Chocolate" "Coral"
    "CornflowerBlue" "Cornsilk" "Crimson" "Cyan" "DarkBlue" "DarkCyan" "DarkGoldenRod" "DarkGray"
    "DarkGrey" "DarkGreen" "DarkKhaki" "DarkMagenta" "DarkOliveGreen" "DarkOrange" "DarkOrchid"
    "DarkRed" "DarkSalmon" "DarkSeaGreen" "DarkSlateBlue" "DarkSlateGray" "DarkSlateGrey"
    "DarkTurquoise" "DarkViolet" "DeepPink" "DeepSkyBlue" "DimGray" "DimGrey" "DodgerBlue"
    "FireBrick" "FloralWhite" "ForestGreen" "Fuchsia" "Gainsboro" "GhostWhite" "Gold" "GoldenRod"
    "Gray" "Grey" "Green" "GreenYellow" "HoneyDew" "HotPink" "IndianRed" "Indigo" "Ivory" "Khaki"
    "Lavender" "LavenderBlush" "LawnGreen" "LemonChiffon" "LightBlue" "LightCoral" "LightCyan"
    "LightGoldenRodYellow" "LightGray" "LightGrey" "LightGreen" "LightPink" "LightSalmon"
    "LightSeaGreen" "LightSkyBlue" "LightSlateGray" "LightSlateGrey" "LightSteelBlue" "LightYellow"
    "Lime" "LimeGreen" "Linen" "Magenta" "Maroon" "MediumAquaMarine" "MediumBlue" "MediumOrchid"
    "MediumPurple" "MediumSeaGreen" "MediumSlateBlue" "MediumSpringGreen" "MediumTurquoise"
    "MediumVioletRed" "MidnightBlue" "MintCream" "MistyRose" "Moccasin" "NavajoWhite" "Navy"
    "OldLace" "Olive" "OliveDrab" "Orange" "OrangeRed" "Orchid" "PaleGoldenRod" "PaleGreen"
    "PaleTurquoise" "PaleVioletRed" "PapayaWhip" "PeachPuff" "Peru" "Pink" "Plum" "PowderBlue"
    "Purple" "RebeccaPurple" "Red" "RosyBrown" "RoyalBlue" "SaddleBrown" "Salmon" "SandyBrown"
    "SeaGreen" "SeaShell" "Sienna" "Silver" "SkyBlue" "SlateBlue" "SlateGray" "SlateGrey" "Snow"
    "SpringGreen" "SteelBlue" "Tan" "Teal" "Thistle" "Tomato" "Turquoise" "Violet" "Wheat" "White"
    "WhiteSmoke" "Yellow" "YellowGreen")
  "All the named CSS colors to construct `color-source' from.")

(defstruct color
  name)

(define-class color-source (prompter:source)
  ((prompter:name "Color")
   (prompter:constructor (mapcar (alex:curry #'make-color :name) *css-colors*))
   (prompter:filter-preprocessor
    (lambda (suggestions source input)
      (declare (ignore source))
      (let ((input-color (make-color :name input)))
        (cons (make-instance 'prompter:suggestion
                             :value input-color
                             :attributes (prompter:object-attributes input-color))
              suggestions))))
   (prompter:follow-p t)
   (prompter:follow-mode-functions
    (lambda (color)
      (pflet ((color-input-area
               (color)
               (setf (ps:chain (nyxt/ps:qs document "#input") style background-color)
                     (ps:lisp color))))
        (with-current-buffer (current-prompt-buffer)
          (color-input-area (color-name color)))))))
  (:accessor-name-transformer (class*:make-name-transformer name)))

(defmethod prompter:object-attributes ((color color))
  `(("Color" ,(color-name color))))

(defun process-color-chooser-request (web-view color-chooser-request)
  (declare (ignore web-view))
  (with-protect ("Failed to process file chooser request: ~a" :condition)
    (when (native-dialogs *browser*)
      (gobject:g-object-ref (gobject:pointer color-chooser-request))
      (run-thread
          "color chooser"
        (pflet ((get-rgba (color)
                          (let ((div (ps:chain document (create-element "div"))))
                            (setf (ps:chain div style color)
                                  (ps:lisp color))
                            (ps:chain document body (append-child div))
                            (ps:stringify (ps:chain window (get-computed-style div) color))))
                (get-opacity (color)
                             (let ((div (ps:chain document (create-element "div"))))
                               (setf (ps:chain div style color)
                                     (ps:lisp color))
                               (ps:chain document body (append-child div))
                               (ps:stringify (ps:chain window (get-computed-style div) opacity)))))
          (let* ((rgba (cffi:foreign-alloc :double :count 4))
                 (rgba (progn (webkit:webkit-color-chooser-request-get-rgba
                               color-chooser-request rgba)
                              rgba))
                 (color-name (color-name
                              (prompt1 :prompt "Color"
                                :input (format nil "rgba(~d, ~d, ~d, ~d)"
                                               (round (* 255 (cffi:mem-aref rgba :double 0)))
                                               (round (* 255 (cffi:mem-aref rgba :double 1)))
                                               (round (* 255 (cffi:mem-aref rgba :double 2)))
                                               (round (* 255 (cffi:mem-aref rgba :double 3))))
                                :sources (list (make-instance 'color-source)))))
                 (color (get-rgba color-name))
                 (opacity (sera:parse-float (get-opacity color-name)))
                 (rgba (progn
                         (cffi:foreign-free rgba)
                         (gdk:gdk-rgba-parse color))))
            (unless (uiop:emptyp color)
              (webkit:webkit-color-chooser-request-set-rgba
               color-chooser-request
               (cffi:foreign-alloc
                :double
                :count 4
                :initial-contents (list (gdk:gdk-rgba-red rgba) (gdk:gdk-rgba-green rgba)
                                        (gdk:gdk-rgba-blue rgba) (coerce opacity 'double-float))))
              (webkit:webkit-color-chooser-request-finish (g:pointer color-chooser-request))))))
      t)))

(defun process-script-dialog (web-view dialog)
  (declare (ignore web-view))
  (with-protect ("Failed to process dialog: ~a" :condition)
    (when (native-dialogs *browser*)
      (let ((dialog (gobject:pointer dialog)))
        (webkit:webkit-script-dialog-ref dialog)
        (run-thread "script dialog"
          (case (webkit:webkit-script-dialog-get-dialog-type dialog)
            (:webkit-script-dialog-alert (echo (webkit:webkit-script-dialog-get-message dialog)))
            (:webkit-script-dialog-prompt
             (let ((text (first (handler-case
                                    (prompt
                                     :input (webkit:webkit-script-dialog-prompt-get-default-text dialog)
                                     :prompt (webkit:webkit-script-dialog-get-message dialog)
                                     :sources (list (make-instance 'prompter:raw-source)))
                                  (nyxt-prompt-buffer-canceled (c) (declare (ignore c)) nil)))))
               (if text
                   (webkit:webkit-script-dialog-prompt-set-text dialog text)
                   (progn
                     (webkit:webkit-script-dialog-prompt-set-text dialog (cffi:null-pointer))
                     (webkit:webkit-script-dialog-close dialog)))))
            (:webkit-script-dialog-confirm
             (webkit:webkit-script-dialog-confirm-set-confirmed
              dialog (if-confirm
                      ((webkit:webkit-script-dialog-get-message dialog))
                      t nil)))
            (:webkit-script-dialog-before-unload-confirm
             (webkit:webkit-script-dialog-confirm-set-confirmed
              dialog (if-confirm
                      ;; FIXME: This asks for keyword override in if-confirm.
                      ((format nil "~a ['yes' = leave, 'no' = stay]" (webkit:webkit-script-dialog-get-message dialog)))
                      t nil))))
          (webkit:webkit-script-dialog-close dialog)
          (webkit:webkit-script-dialog-unref dialog))
        t))))

(defun process-permission-request (web-view request)
  (g:g-object-ref (g:pointer request))
  (run-thread "permission requester"
   (if-confirm ((format
                 nil "[~a] ~a"
                 (webkit:webkit-web-view-uri web-view)
                 (etypecase request
                   (webkit:webkit-geolocation-permission-request
                    "Grant this website geolocation access?")
                   (webkit:webkit-notification-permission-request
                    "Grant this website notifications access?")
                   (webkit:webkit-pointer-lock-permission-request
                    "Grant this website pointer access?")
                   (webkit:webkit-device-info-permission-request
                    "Grant this website device info access?")
                   (webkit:webkit-install-missing-media-plugins-permission-request
                    (format nil "Grant this website a media install permission for ~s?"
                            (webkit:webkit-install-missing-media-plugins-permission-request-get-description
                             request)))
                   (webkit:webkit-media-key-system-permission-request
                    (format nil "Grant this website an EME ~a key access?"
                            (webkit:webkit-media-key-system-permission-get-name request)))
                   (webkit:webkit-user-media-permission-request
                    (format nil "Grant this website a~@[~*n audio~]~@[~* video~] access?"
                            (webkit:webkit-user-media-permission-is-for-audio-device request)
                            (webkit:webkit-user-media-permission-is-for-video-device request)))
                   (webkit:webkit-website-data-access-permission-request
                    (format nil "Grant ~a an access to ~a data?"
                            (webkit:webkit-website-data-access-permission-request-get-requesting-domain
                             request)
                            (webkit:webkit-website-data-access-permission-request-get-current-domain
                             request))))))
                (webkit:webkit-permission-request-allow request)
                (webkit:webkit-permission-request-deny request))))

(defun process-notification (web-view notification)
  (when (native-dialogs *browser*)
    (let* ((title (webkit:webkit-notification-get-title notification))
           (body (webkit:webkit-notification-get-body notification)))
      (echo "[~a] ~a: ~a" (webkit:webkit-web-view-uri web-view) title body)
      t)))

(define-ffi-method ffi-buffer-make ((buffer gtk-buffer))
  "Initialize BUFFER's GTK web view."
  (unless (gtk-object buffer) ; Buffer may already have a view, e.g. the prompt-buffer.
    (setf (gtk-object buffer) (make-web-view :buffer buffer)))
  (if (smooth-scrolling buffer)
      (ffi-buffer-enable-smooth-scrolling buffer t)
      (ffi-buffer-enable-smooth-scrolling buffer nil))
  (connect-signal-function buffer "decide-policy" (make-decide-policy-handler buffer))
  (connect-signal buffer "load-changed" t (web-view load-event)
    (declare (ignore web-view))
    (on-signal-load-changed buffer load-event))
  (connect-signal buffer "focus-out-event" t (web-view event)
    (declare (ignore web-view event))
    (when (fullscreen-p (current-window))
      (ffi-window-unfullscreen (current-window)))
    nil)
  (connect-signal buffer "mouse-target-changed" nil (web-view hit-test-result modifiers)
    (declare (ignore web-view))
    (on-signal-mouse-target-changed buffer hit-test-result modifiers))
  ;; Mouse events are captured by the web view first, so we must intercept them here.
  (connect-signal buffer "button-press-event" nil (web-view event)
    (declare (ignore web-view))
    (on-signal-button-press-event buffer event))
  (connect-signal buffer "scroll-event" nil (web-view event)
    (declare (ignore web-view))
    (on-signal-scroll-event buffer event))
  (connect-signal-function buffer "script-dialog" #'process-script-dialog)
  (connect-signal-function buffer "run-file-chooser" #'process-file-chooser-request)
  (connect-signal-function buffer "run-color-chooser" #'process-color-chooser-request)
  (connect-signal-function buffer "permission-request" #'process-permission-request)
  (connect-signal-function buffer "show-notification" #'process-notification)
  ;; TLS certificate handling
  (connect-signal buffer "load-failed-with-tls-errors" nil (web-view failing-url certificate errors)
    (declare (ignore web-view errors))
    (on-signal-load-failed-with-tls-errors buffer certificate (quri:uri failing-url)))
  (connect-signal buffer "notify::uri" nil (web-view param-spec)
    (declare (ignore param-spec))
    (nyxt/web-extensions::tabs-on-updated
     buffer `(("url" . ,(webkit:webkit-web-view-uri web-view))))
    (on-signal-notify-uri buffer nil))
  (connect-signal buffer "notify::title" nil (web-view param-spec)
    (declare (ignore  param-spec))
    (nyxt/web-extensions::tabs-on-updated
     buffer `(("title" . ,(webkit:webkit-web-view-title web-view))))
    (on-signal-notify-title buffer nil))
  (connect-signal buffer "web-process-terminated" nil (web-view reason)
    ;; TODO: Bind WebKitWebProcessTerminationReason in cl-webkit.
    (echo-warning
     "Web process terminated for buffer ~a (opening ~a) because ~[it crashed~;of memory exhaustion~;we had to close it~]"
     (id buffer)
     (url buffer)
     (cffi:foreign-enum-value 'webkit:webkit-web-process-termination-reason reason))
    (log:debug
     "Web process terminated for web view ~a because of ~[WEBKIT_WEB_PROCESS_CRASHED~;WEBKIT_WEB_PROCESS_EXCEEDED_MEMORY_LIMIT~;WEBKIT_WEB_PROCESS_TERMINATED_BY_API~]"
     web-view
     (cffi:foreign-enum-value 'webkit:webkit-web-process-termination-reason reason))
    (buffer-delete buffer))
  (connect-signal buffer "close" nil (web-view)
    (mapc (lambda (handler-id)
            (gobject:g-signal-handler-disconnect web-view handler-id))
          (handler-ids buffer))
    (nyxt/web-extensions::tabs-on-removed buffer)
    (buffer-hide buffer)
    (gtk:gtk-widget-destroy web-view)
    (setf (gtk-object buffer) nil))
  (connect-signal buffer "load-failed" nil (web-view load-event failing-url error)
    (declare (ignore load-event web-view))
    ;; TODO: WebKitGTK sometimes (when?) triggers "load-failed" when loading a
    ;; page from the webkit-history cache.  Upstream bug?  Anyways, we should
    ;; ignore these.
    (if (loading-webkit-history-p buffer)
        (setf (loading-webkit-history-p buffer) nil)
        (unless (or (member (slot-value buffer 'status) '(:finished :failed))
                    ;; WebKitGTK emits the WEBKIT_PLUGIN_ERROR_WILL_HANDLE_LOAD
                    ;; (204) if the plugin will handle loading content of the
                    ;; URL. This often happens with videos. The only thing we
                    ;; can do is ignore it.
                    ;;
                    ;; TODO: Use cl-webkit provided error types. How
                    ;; do we use it, actually?
                    (= 204 (webkit::g-error-code error))
                    (= 302 (webkit::g-error-code error)))
          (echo "Failed to load URL ~a in buffer ~a." failing-url (id buffer))
          (setf (slot-value buffer 'status) :failed)
          (html-set
           (spinneret:with-html-string
             (:h1 "Page could not be loaded.")
             (:h2 "URL: " failing-url)
             (:ul
              (:li "Try again in a moment, maybe the site will be available again.")
              (:li "If the problem persists for every site, check your Internet connection.")
              (:li "Make sure the URL is valid."
                   (when (quri:uri-https-p (quri:uri failing-url))
                     "If this site does not support HTTPS, try with HTTP (insecure)."))))
           buffer)))
    t)
  (connect-signal buffer "create" nil (web-view navigation-action)
    (declare (ignore web-view))
    (let ((new-buffer (make-instance 'user-web-buffer :parent-buffer (current-buffer)))
          (url (webkit:webkit-uri-request-uri
                (webkit:webkit-navigation-action-get-request
                 (gobject:pointer navigation-action)))))
      (ffi-buffer-load new-buffer (quri:uri url))
      (window-set-buffer (current-window) new-buffer)
      (gtk-object new-buffer)))
  ;; Remove "download to disk" from the right click context menu because it
  ;; bypasses request resource signal
  (connect-signal buffer "context-menu" nil (web-view context-menu event hit-test-result)
    (declare (ignore web-view event hit-test-result))
    (let ((length (webkit:webkit-context-menu-get-n-items context-menu)))
      (dotimes (i length)
        (let ((item (webkit:webkit-context-menu-get-item-at-position context-menu i)))
          (match (webkit:webkit-context-menu-item-get-stock-action item)
            (:webkit-context-menu-action-download-link-to-disk
             (webkit:webkit-context-menu-remove context-menu item))))))
    nil)
  (connect-signal buffer "enter-fullscreen" nil (web-view)
    (declare (ignore web-view))
    (hooks:run-hook toggle-fullscreen-before-hook)
    (toggle-status-buffer :show-p nil)
    (toggle-message-buffer :show-p nil)
    (hooks:run-hook toggle-fullscreen-after-hook)
    nil)
  (connect-signal buffer "leave-fullscreen" nil (web-view)
    (declare (ignore web-view))
    (hooks:run-hook toggle-fullscreen-before-hook)
    (toggle-status-buffer :show-p t)
    (toggle-message-buffer :show-p t)
    (hooks:run-hook toggle-fullscreen-after-hook)
    nil)
  (connect-signal buffer "user-message-received" nil (view message)
    (declare (ignorable view))
    (g:g-object-ref (g:pointer message))
    (run-thread
      "Process user messsage"
      (nyxt/web-extensions:process-user-message buffer message))
    (sleep 0.01)
    (run-thread
      "Reply user message"
      (nyxt/web-extensions:reply-user-message buffer message))
    t)
  (nyxt/web-extensions::tabs-on-created buffer)
  buffer)

(define-ffi-method ffi-buffer-delete ((buffer gtk-buffer))
  (if (slot-value buffer 'gtk-object) ; Not all buffers have their own web view, e.g. prompt buffers.
      (webkit:webkit-web-view-try-close (gtk-object buffer))
      (buffer-hide buffer)))

(define-ffi-method ffi-buffer-load ((buffer gtk-buffer) url)
  "Load URL in BUFFER.
An optimization technique is to make use of the renderer history cache.
For WebKit, if the URL matches an entry in the webkit-history then we fetch the
page from the cache.

We don't use the cache if URL matches BUFFER's URL since this means the user
requested a reload.

Note that we don't use the cache for internal pages (say nyxt:help) since it's
local anyways, and it's better to refresh it if a load was queried."
  (declare (type quri:uri url))
  (let* ((history (webkit-history buffer))
         (entry (or (find url history :test #'quri:uri= :key #'webkit-history-entry-url)
                    (find url history :test #'quri:uri= :key #'webkit-history-entry-original-url))))
    ;; Mark buffer as :loading right away so functions like `window-set-buffer'
    ;; don't try to reload if they are called before the "load-changed" signal
    ;; is emitted.
    (when (web-buffer-p buffer)
      (setf (slot-value buffer 'status) :loading))
    (if (and entry
             (not (internal-url-p url))
             (not (quri:uri= url (url buffer))))
        (progn
          (log:debug "Load URL from history entry ~a" entry)
          (load-webkit-history-entry buffer entry))
        (webkit:webkit-web-view-load-uri (gtk-object buffer) (quri:render-uri url)))))

(defmethod ffi-buffer-evaluate-javascript ((buffer gtk-buffer) javascript &optional world-name)
  (%within-renderer-thread
   (lambda (&optional channel)
     (when (gtk-object buffer)
       (webkit2:webkit-web-view-evaluate-javascript
        (gtk-object buffer)
        javascript
        (if channel
            (lambda (result jsc-result)
              (declare (ignore jsc-result))
              (calispel:! channel result))
          (lambda (result jsc-result)
            (declare (ignore jsc-result))
            result))
        (lambda (condition)
          (javascript-error-handler condition)
          ;; Notify the listener that we are done.
          (when channel
            (calispel:! channel nil)))
        world-name)))))

(defmethod ffi-buffer-evaluate-javascript-async ((buffer gtk-buffer) javascript &optional world-name)
  (%within-renderer-thread-async
   (lambda ()
     (when (gtk-object buffer)
       (webkit2:webkit-web-view-evaluate-javascript
        (gtk-object buffer)
        javascript
        nil
        #'javascript-error-handler
        world-name)))))

(defun list-of-string-to-foreign (list)
  (if list
      (cffi:foreign-alloc :string
                          :count (length list)
                          :initial-contents list
                          :null-terminated-p t)
      (cffi:null-pointer)))

(define-ffi-method ffi-buffer-add-user-style ((buffer gtk-buffer) css &key
                                              world-name all-frames-p inject-as-author-p
                                              allow-list block-list)
  (let* ((content-manager
           (webkit:webkit-web-view-get-user-content-manager
            (gtk-object buffer)))
         (frames (if all-frames-p
                     :webkit-user-content-inject-all-frames
                     :webkit-user-content-inject-top-frame))
         (style-level (if inject-as-author-p
                          :webkit-user-style-level-author
                          :webkit-user-style-level-user))
         (style-sheet
           (if world-name
               (webkit:webkit-user-style-sheet-new-for-world
                css frames style-level world-name
                (list-of-string-to-foreign allow-list)
                (list-of-string-to-foreign block-list))
               (webkit:webkit-user-style-sheet-new
                css frames style-level
                (list-of-string-to-foreign allow-list)
                (list-of-string-to-foreign block-list)))))
    (webkit:webkit-user-content-manager-add-style-sheet
     content-manager style-sheet)
    style-sheet))

(define-ffi-method ffi-buffer-remove-user-style ((buffer gtk-buffer) style-sheet)
  (let ((content-manager
          (webkit:webkit-web-view-get-user-content-manager
           (gtk-object buffer))))
    (when style-sheet
      (webkit:webkit-user-content-manager-remove-style-sheet
       content-manager style-sheet))))

(define-ffi-method ffi-buffer-add-user-script ((buffer gtk-buffer) javascript &key
                                               world-name all-frames-p
                                               at-document-start-p run-now-p
                                               allow-list block-list)
  (let* ((content-manager
           (webkit:webkit-web-view-get-user-content-manager
            (gtk-object buffer)))
         (frames (if all-frames-p
                     :webkit-user-content-inject-all-frames
                     :webkit-user-content-inject-top-frame))
         (inject-time (if at-document-start-p
                          :webkit-user-script-inject-at-document-start
                          :webkit-user-script-inject-at-document-end))
         (allow-list (if allow-list
                         (list-of-string-to-foreign allow-list)
                         '("http://*/*" "https://*/*")))
         (block-list (list-of-string-to-foreign block-list))
         (script (if world-name
                     (webkit:webkit-user-script-new-for-world
                      javascript frames inject-time world-name allow-list block-list)
                     (webkit:webkit-user-script-new
                      javascript frames inject-time allow-list block-list))))
    (webkit:webkit-user-content-manager-add-script
     content-manager script)
    (when (and run-now-p
               (member (slot-value buffer 'status)
                       '(:finished :failed)))
      (reload-buffers (list buffer)))
    script))

(define-ffi-method ffi-buffer-remove-user-script ((buffer gtk-buffer) script)
  (let ((content-manager
          (webkit:webkit-web-view-get-user-content-manager
           (gtk-object buffer))))
    (when script
      (webkit:webkit-user-content-manager-remove-script
       content-manager script))))

(define-ffi-method ffi-buffer-enable-javascript ((buffer gtk-buffer) value)
  (setf (webkit:webkit-settings-enable-javascript
         (webkit:webkit-web-view-get-settings (gtk-object buffer)))
        value))

(define-ffi-method ffi-buffer-enable-javascript-markup ((buffer gtk-buffer) value)
  (setf (webkit:webkit-settings-enable-javascript-markup
         (webkit:webkit-web-view-get-settings (gtk-object buffer)))
        value))

(define-ffi-method ffi-buffer-enable-smooth-scrolling ((buffer gtk-buffer) value)
  (setf (webkit:webkit-settings-enable-smooth-scrolling
         (webkit:webkit-web-view-get-settings (gtk-object buffer)))
        value))

#+webkit2-media
(define-ffi-method ffi-buffer-enable-media ((buffer gtk-buffer) value)
  (setf (webkit:webkit-settings-enable-media
         (webkit:webkit-web-view-get-settings (gtk-object buffer)))
        value))

(define-ffi-method ffi-buffer-auto-load-image ((buffer gtk-buffer) value)
  (setf (webkit:webkit-settings-auto-load-images
         (webkit:webkit-web-view-get-settings (gtk-object buffer)))
        value))

#+webkit2-mute
(defmethod ffi-buffer-enable-sound ((buffer gtk-buffer) value)
  (nyxt/web-extensions::tabs-on-updated
   buffer (alex:alist-hash-table `(("audible" . ,value))))
  (webkit:webkit-web-view-set-is-muted (gtk-object buffer) (not value)))

(defmethod ffi-buffer-download ((buffer gtk-buffer) url)
  (let* ((webkit-download (webkit:webkit-web-view-download-uri (gtk-object buffer) url))
         (download (make-instance 'user-download
                                  :url url
                                  :gtk-object webkit-download)))
    (hooks:run-hook (before-download-hook *browser*) url)
    (setf (cancel-function download)
          #'(lambda ()
              (setf (status download) :canceled)
              (webkit:webkit-download-cancel webkit-download)))
    (push download (downloads *browser*))
    (connect-signal download "received-data" nil (webkit-download data-length)
      (declare (ignore data-length))
      (setf (bytes-downloaded download)
            (webkit:webkit-download-get-received-data-length webkit-download))
      (setf (completion-percentage download)
            (* 100 (webkit:webkit-download-estimated-progress webkit-download))))
    (connect-signal download "decide-destination" nil (webkit-download suggested-file-name)
      (alex:when-let* ((download-dir (download-directory buffer))
                       (download-directory (nfiles:expand download-dir))
                       (native-download-directory (unless (nfiles:nil-pathname-p download-directory)
                                                    (uiop:native-namestring download-directory)))
                       (path (str:concat native-download-directory suggested-file-name))
                       (unique-path (download-manager::ensure-unique-file path))
                       (file-path (format nil "file://~a" unique-path)))
        (if (string= path unique-path)
            (log:debug "Downloading file to ~s." unique-path)
            (echo "Destination ~s exists, saving as ~s." path unique-path))
        (webkit:webkit-download-set-destination webkit-download file-path)))
    (connect-signal download "created-destination" nil (webkit-download destination)
      (declare (ignore destination))
      (setf (destination-path download)
            (uiop:ensure-pathname
             (quri:uri-path (quri:uri
                             (webkit:webkit-download-destination webkit-download)))))
      ;; TODO: We should not have to update the buffer, button actions should be
      ;; dynamic.  Bug in `user-interface'?
      (reload-buffers (list (find-if
                             (lambda (b)
                               (and (string= (title b) "*Downloads*")
                                    (find-mode b 'download-mode)))
                             (buffer-list)))))
    (connect-signal download "failed" nil (webkit-download error)
      (declare (ignore error))
      (unless (eq (status download) :canceled)
        (setf (status download) :failed))
      (echo "Download failed for ~s."
            (webkit:webkit-uri-request-uri
             (webkit:webkit-download-get-request webkit-download))))
    (connect-signal download "finished" nil (webkit-download)
      (declare (ignore webkit-download))
      (unless (member (status download) '(:canceled :failed))
        (setf (status download) :finished)
        ;; If download was too small, it may not have been updated.
        (setf (completion-percentage download) 100)
        (hooks:run-hook (after-download-hook *browser*) download)))
    download))

(define-ffi-method ffi-buffer-user-agent ((buffer gtk-buffer) &optional value)
  (alex:when-let ((settings (webkit:webkit-web-view-get-settings (gtk-object buffer))))
    (if value
        (setf (webkit:webkit-settings-user-agent settings) value)
        (webkit:webkit-settings-user-agent settings))))

(define-ffi-method ffi-buffer-webgl-enabled-p ((buffer gtk-buffer))
  (webkit:webkit-settings-enable-webgl
   (webkit:webkit-web-view-get-settings (gtk-object buffer))))

(define-ffi-method ffi-buffer-enable-webgl ((buffer gtk-buffer) value)
  (setf (webkit:webkit-settings-enable-webgl
         (webkit:webkit-web-view-get-settings (gtk-object buffer)))
        value))

(define-ffi-method ffi-buffer-set-proxy ((buffer gtk-buffer)
                                         &optional (proxy-url (quri:uri ""))
                                         (ignore-hosts (list nil)))
  "Redirect network connections of BUFFER to proxy server PROXY-URL.
Hosts in IGNORE-HOSTS (a list of strings) ignore the proxy.
For the user-level interface, see `proxy-mode'.

Note: WebKit supports three proxy 'modes': default (the system proxy),
custom (the specified proxy) and none."
  (declare (type quri:uri proxy-url))
  (setf (gtk-proxy-url buffer) proxy-url)
  (setf (proxy-ignored-hosts buffer) ignore-hosts)
  (let* ((context (webkit:webkit-web-view-web-context (gtk-object buffer)))
         (settings (cffi:null-pointer))
         (mode :webkit-network-proxy-mode-no-proxy)
         (ignore-hosts (cffi:foreign-alloc :string
                                           :initial-contents ignore-hosts
                                           :null-terminated-p t)))
    (unless (url-empty-p proxy-url)
      (setf mode :webkit-network-proxy-mode-custom)
      (setf settings
            (webkit:webkit-network-proxy-settings-new
             (render-url proxy-url)
             ignore-hosts)))
    (cffi:foreign-free ignore-hosts)
    (webkit:webkit-web-context-set-network-proxy-settings
     context mode settings)))

(define-ffi-method ffi-buffer-get-proxy ((buffer gtk-buffer))
  "Return the proxy URL and list of ignored hosts (a list of strings) as second value."
  (the (values (or quri:uri null) list-of-strings)
       (values (gtk-proxy-url buffer)
               (proxy-ignored-hosts buffer))))

(define-ffi-method ffi-buffer-set-zoom-level ((buffer gtk-buffer) value)
  (when (and (floatp value) (>= value 0))
    (setf (webkit:webkit-web-view-zoom-level (gtk-object buffer)) value)))

(define-ffi-method ffi-generate-input-event ((window gtk-window) event)
  (when event
    ;; The "send_event" field is used to mark the event as an "unconsumed"
    ;; keypress.  The distinction allows us to avoid looping indefinitely.
    (etypecase event
      (gdk:gdk-event-button
       (setf (gdk:gdk-event-button-send-event event) t))
      (gdk:gdk-event-key
       (setf (gdk:gdk-event-key-send-event event) t))
      (gdk:gdk-event-scroll
       (setf (gdk:gdk-event-scroll-send-event event) t)))
    (gtk:gtk-main-do-event event)))

(define-ffi-method ffi-generated-input-event-p ((window gtk-window) event)
  (gdk:gdk-event-send-event event))

(define-ffi-method ffi-inspector-show ((buffer gtk-buffer))
  (setf (webkit:webkit-settings-enable-developer-extras
         (webkit:webkit-web-view-get-settings (gtk-object buffer)))
        t)
  (webkit:webkit-web-inspector-show
   (webkit:webkit-web-view-get-inspector (gtk-object buffer))))

(define-ffi-method ffi-print-status ((window gtk-window) text)
  (let ((text (spinneret:with-html-string
               (:head (:style (style (status-buffer window))))
               (:body (:raw text)))))
    (with-slots (status-buffer) window
      (webkit2:webkit-web-view-evaluate-javascript
       (gtk-object (status-buffer window))
       (ps:ps (setf (ps:@ document body |innerHTML|)
                    (ps:lisp text)))))))

(define-ffi-method ffi-print-message ((window gtk-window) text)
  (let ((text (spinneret:with-html-string
               (:head (:style (message-buffer-style window)))
               (:body (:raw text)))))
    (with-slots (message-view) window
      (webkit2:webkit-web-view-evaluate-javascript
       (message-view window)
       (ps:ps (setf (ps:@ document body |innerHTML|)
                    (ps:lisp text)))))))

;; This method does not need a renderer, so no need to use `define-ffi-method'
;; which is prone to race conditions.
(defmethod ffi-display-url (text)
  (webkit:webkit-uri-for-display text))

(-> set-cookie-policy (webkit:webkit-cookie-manager cookie-policy) *)
(defun set-cookie-policy (cookie-manager cookie-policy)
  (webkit:webkit-cookie-manager-set-accept-policy
   cookie-manager
   (match cookie-policy
     (:accept :webkit-cookie-policy-accept-always)
     (:never :webkit-cookie-policy-accept-never)
     (:no-third-party :webkit-cookie-policy-accept-no-third-party))))

(define-ffi-method ffi-buffer-cookie-policy ((buffer gtk-buffer) value)
  "VALUE is one of`:always', `:never' or `:no-third-party'."
  (let* ((context (webkit:webkit-web-view-web-context (gtk-object buffer)))
         (cookie-manager (webkit:webkit-web-context-get-cookie-manager context)))
    (set-cookie-policy cookie-manager value)
    buffer))

(defmethod ffi-set-preferred-languages ((buffer gtk-buffer)
                                        language-list)
  "Set the list of preferred languages in the HTTP header \"Accept-Language:\".
LANGUAGE is a list of strings like '(\"en_US\" \"fr_FR\")."
  (let ((langs (cffi:foreign-alloc :string
                                   :initial-contents language-list
                                   :null-terminated-p t)))
    (webkit:webkit-web-context-set-preferred-languages
     (webkit:webkit-web-view-web-context (gtk-object buffer))
     langs)))

(defstruct webkit-history-entry
  title
  url
  original-url
  gtk-object)

(define-ffi-method webkit-history ((buffer gtk-buffer))
  "Return a list of `webkit-history-entry's for the current buffer.
Oldest entries come last.

This represents the history as remembered by WebKit.  Note that it is linear so
it does not map 1:1 with Nyxt's history tree.  Nonetheless it allows us to make
use of the WebKit history case for the current branch.  See `ffi-buffer-load'.

As a second value, return the current buffer index starting from 0."
  (let* ((bf-list (webkit:webkit-web-view-get-back-forward-list (gtk-object buffer)))
         (length (webkit:webkit-back-forward-list-get-length bf-list))
         (current (webkit:webkit-back-forward-list-get-current-item bf-list))
         (history-list nil)
         (current-index 0))
    ;; The back-forward list is both negatively and positively indexed.  Seems
    ;; that we can't easily know the first index nor the last one.  So let's
    ;; iterate over the length backwards and forwards to make sure we get all
    ;; elements in order.
    (loop for i from (- length) to length
          for item = (webkit:webkit-back-forward-list-get-nth-item bf-list i)
          when (eq item current)
          do (setf current-index (- length (length history-list))) ; Index from 0.
          when item
          do (push (make-webkit-history-entry
                    :title (webkit:webkit-back-forward-list-item-get-title item)
                    :url (quri:uri (webkit:webkit-back-forward-list-item-get-uri item))
                    :original-url (quri:uri (webkit:webkit-back-forward-list-item-get-original-uri item))
                    :gtk-object item)
                   history-list))
    (values history-list current-index)))

(defmethod load-webkit-history-entry ((buffer gtk-buffer) history-entry)
  (setf (loading-webkit-history-p buffer) t)
  (webkit:webkit-web-view-go-to-back-forward-list-item
   (gtk-object buffer)
   (webkit-history-entry-gtk-object history-entry)))

(define-ffi-method ffi-focused-p ((buffer gtk-buffer))
  (gtk:gtk-widget-is-focus (gtk-object buffer)))

;; Working with clipboard
(define-ffi-method (setf clipboard-text) (text (gtk-browser gtk-browser))
  (gtk:gtk-clipboard-set-text
   (gtk:gtk-clipboard-get "CLIPBOARD")
   text))

(define-ffi-method clipboard-text ((gtk-browser gtk-browser))
  (gtk:gtk-clipboard-wait-for-text
   (gtk:gtk-clipboard-get "CLIPBOARD")))

(define-ffi-method ffi-set-tracking-prevention ((buffer gtk-buffer) value)
  #+webkit2-tracking
  (webkit:webkit-website-data-manager-set-itp-enabled
   (webkit:webkit-web-context-website-data-manager
    (webkit:webkit-web-view-web-context (gtk-object buffer)))
   value))

(defmethod ffi-buffer-copy ((gtk-buffer gtk-buffer))
  (webkit:webkit-web-view-can-execute-editing-command
   (gtk-object gtk-buffer) webkit2:+webkit-editing-command-copy+
   (lambda (can-execute?)
     (when can-execute?
       (webkit:webkit-web-view-execute-editing-command
        (gtk-object gtk-buffer) webkit2:+webkit-editing-command-copy+)))
   (lambda (e) (echo-warning "Cannot copy: ~a" e))))

(defmethod ffi-buffer-paste ((gtk-buffer gtk-buffer))
  (webkit:webkit-web-view-can-execute-editing-command
   (gtk-object gtk-buffer) webkit2:+webkit-editing-command-paste+
   (lambda (can-execute?)
     (when can-execute?
       (webkit:webkit-web-view-execute-editing-command
        (gtk-object gtk-buffer) webkit2:+webkit-editing-command-paste+)))
   (lambda (e) (echo-warning "Cannot paste: ~a" e))))

(defmethod ffi-buffer-cut ((gtk-buffer gtk-buffer))
  (webkit:webkit-web-view-can-execute-editing-command
   (gtk-object gtk-buffer) webkit2:+webkit-editing-command-cut+
   (lambda (can-execute?)
     (when can-execute?
       (webkit:webkit-web-view-execute-editing-command
        (gtk-object gtk-buffer) webkit2:+webkit-editing-command-cut+)))
   (lambda (e) (echo-warning "Cannot cut: ~a" e))))

(defmethod ffi-buffer-select-all ((gtk-buffer gtk-buffer))
  (webkit:webkit-web-view-can-execute-editing-command
   (gtk-object gtk-buffer) webkit2:+webkit-editing-command-select-all+
   (lambda (can-execute?)
     (when can-execute?
       (webkit:webkit-web-view-execute-editing-command
        (gtk-object gtk-buffer) webkit2:+webkit-editing-command-select-all+)))
   (lambda (e) (echo-warning "Cannot select all: ~a" e))))

(defmethod ffi-buffer-undo ((gtk-buffer gtk-buffer))
  (webkit:webkit-web-view-can-execute-editing-command
   (gtk-object gtk-buffer) webkit2:+webkit-editing-command-undo+
   (lambda (can-execute?)
     (when can-execute?
       (webkit:webkit-web-view-execute-editing-command
        (gtk-object gtk-buffer) webkit2:+webkit-editing-command-undo+)))
   (lambda (e) (echo-warning "Cannot undo: ~a" e))))

(defmethod ffi-buffer-redo ((gtk-buffer gtk-buffer))
  (webkit:webkit-web-view-can-execute-editing-command
   (gtk-object gtk-buffer) webkit2:+webkit-editing-command-redo+
   (lambda (can-execute?)
     (when can-execute?
       (webkit:webkit-web-view-execute-editing-command
        (gtk-object gtk-buffer) webkit2:+webkit-editing-command-redo+)))
   (lambda (e) (echo-warning "Cannot redo: ~a" e))))

(define-class context-source (prompter:source)
  ((prompter:name "Context list")
   (prompter:constructor (sort (delete-duplicates (append (mapcar #'context-name (buffer-list))
                                                          (list +internal+ +default+))
                                                  :test 'equal)
                               'string<)))
  (:export-class-name-p t))

(define-command make-buffer-with-context (&rest args
                                          &key title modes url load-url-p
                                          context-name)
  "Create a new buffer with a given context.
See the `context-name' documention.
See `make-buffer' for a description of the other arguments."
  (declare (ignorable title modes url load-url-p))
  (setf (getf args :context-name)
        (or context-name
            (prompt1
             :prompt "Choose context"
             :sources (list (make-instance 'prompter:raw-source :name "New context")
                            'context-source))))
  (apply #'make-buffer (append (list :buffer-class 'user-buffer)
                               args)))
