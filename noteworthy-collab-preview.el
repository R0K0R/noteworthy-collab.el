;;; noteworthy-collab-preview.el --- Drive a standalone tinymist preview -*- lexical-binding: t; -*-

;; Author: r0k0r
;; Keywords: typst, collaboration, preview

;;; Commentary:
;; Talks to a tinymist preview server that runs *independently* of the
;; Noteworthy GUI server -- started by hand on the machine that holds the
;; project, not through /api/tinymist/start.  That matters: the GUI server
;; owns a single process shared by every client, so pushing one editor's
;; buffer into it would show your unsaved text to everyone.  A session you
;; started is yours.
;;
;; Such a session sees the project two ways at once:
;;
;;   * the filesystem, for every file you do not have open -- including the
;;     CRDT room's debounced writes from other peers, and
;;   * memory overlays pushed over its control plane, for the buffers you do
;;     have open.
;;
;; The overlay is always the CRDT-merged text, so it cannot diverge from what
;; the room will write; it just arrives sooner.  Verified against tinymist
;; 0.15.2: an overlay shadows the file on disk until `removeMemoryFiles',
;; which is why `noteworthy-collab-preview-drop' matters on leave/kill.
;;
;; Start the server yourself, e.g. over TRAMP from the project root:
;;
;;   tinymist preview --no-open --root . \
;;     --data-plane-host 127.0.0.1:23625 --control-plane-host 127.0.0.1:23626 \
;;     templates/core/parser.typ
;;
;; then forward both ports and point this at the control plane:
;;
;;   ssh -L 23625:localhost:23625 -L 23626:localhost:23626 yourserver

;;; Code:

(require 'websocket)
(require 'json)
;; cl-pushnew and seq-filter below are not autoloaded.
(require 'cl-lib)
(require 'seq)

(defcustom noteworthy-collab-preview-control-url "ws://localhost:23626"
  "Control-plane WebSocket URL of a standalone tinymist preview session."
  :type 'string
  :group 'noteworthy-collab)

(defcustom noteworthy-collab-preview-push-delay 0.15
  "Idle seconds before pushing a changed buffer to the preview."
  :type 'number
  :group 'noteworthy-collab)

(defvar noteworthy-collab-preview--socket nil)
(defvar noteworthy-collab-preview--timer nil)
(defvar noteworthy-collab-preview--pending nil
  "Buffers whose content still needs pushing.")
(defvar noteworthy-collab-preview--overlaid nil
  "Server-side paths we currently shadow with a memory overlay.")

(defun noteworthy-collab-preview-connected-p ()
  "Return non-nil when the control plane is connected."
  (and noteworthy-collab-preview--socket
       (websocket-openp noteworthy-collab-preview--socket)))

(defun noteworthy-collab-preview--server-path (file)
  "Return FILE as tinymist sees it, i.e. without any TRAMP prefix."
  (when file
    (or (file-remote-p file 'localname) (expand-file-name file))))

(defun noteworthy-collab-preview--buffer-text ()
  (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))

(defun noteworthy-collab-preview--send (payload)
  (when (noteworthy-collab-preview-connected-p)
    (condition-case err
        (websocket-send-text noteworthy-collab-preview--socket (json-encode payload))
      (error (noteworthy-collab--log 'warn "Preview send failed: %s"
                                     (error-message-string err))))))

(defun noteworthy-collab-preview--push-buffers (buffers)
  "Send an updateMemoryFiles overlay for BUFFERS."
  (let (files)
    (dolist (buf buffers)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((path (noteworthy-collab-preview--server-path buffer-file-name)))
            (when path
              (push (cons path (noteworthy-collab-preview--buffer-text)) files)
              (cl-pushnew path noteworthy-collab-preview--overlaid :test #'equal))))))
    (when files
      (noteworthy-collab-preview--send `(("event" . "updateMemoryFiles")
                                         ("files" . ,files))))))

(defun noteworthy-collab-preview--flush ()
  (setq noteworthy-collab-preview--timer nil)
  (let ((buffers noteworthy-collab-preview--pending))
    (setq noteworthy-collab-preview--pending nil)
    (noteworthy-collab-preview--push-buffers buffers)))

(defun noteworthy-collab-preview-push (&optional buffer)
  "Queue BUFFER (default current) for a debounced overlay push."
  (let ((buf (or buffer (current-buffer))))
    (when (and (noteworthy-collab-preview-connected-p) (buffer-file-name buf))
      (cl-pushnew buf noteworthy-collab-preview--pending)
      (when noteworthy-collab-preview--timer
        (cancel-timer noteworthy-collab-preview--timer))
      (setq noteworthy-collab-preview--timer
            (run-with-idle-timer noteworthy-collab-preview-push-delay nil
                                 #'noteworthy-collab-preview--flush)))))

(defun noteworthy-collab-preview-drop (&optional file)
  "Drop the memory overlay for FILE so tinymist reads it from disk again."
  (let ((path (noteworthy-collab-preview--server-path (or file (buffer-file-name)))))
    (when (and path (member path noteworthy-collab-preview--overlaid))
      (setq noteworthy-collab-preview--overlaid
            (delete path noteworthy-collab-preview--overlaid))
      (noteworthy-collab-preview--send `(("event" . "removeMemoryFiles")
                                         ("files" . [,path]))))))

(defun noteworthy-collab-preview--sync-all ()
  "Answer tinymist's syncEditorChanges with every joined buffer."
  (noteworthy-collab-preview--push-buffers
   (seq-filter (lambda (buf)
                 (with-current-buffer buf
                   (and (bound-and-true-p noteworthy-collab--file-path)
                        buffer-file-name)))
               (buffer-list))))

(defun noteworthy-collab-preview--on-message (_ws frame)
  (let* ((payload (ignore-errors (json-read-from-string (websocket-frame-text frame))))
         (event (alist-get 'event payload)))
    (pcase event
      ("syncEditorChanges" (noteworthy-collab-preview--sync-all))
      ("compileStatus"
       (let ((kind (alist-get 'kind payload)))
         (unless (equal kind "Compiling")
           (noteworthy-collab--log 'info "[preview] %s" kind)))))))

;;;###autoload
(defun noteworthy-collab-preview-connect (&optional url)
  "Connect to a standalone tinymist preview control plane at URL."
  (interactive (list (read-string "Control plane: " noteworthy-collab-preview-control-url)))
  (let ((target (or url noteworthy-collab-preview-control-url)))
    (noteworthy-collab-preview-disconnect)
    (setq noteworthy-collab-preview--overlaid nil)
    (condition-case err
        (setq noteworthy-collab-preview--socket
              (websocket-open
               target
               ;; tinymist warns on a missing Origin and calls it a future
               ;; hard error.
               :custom-header-alist '(("Origin" . "http://localhost"))
               :on-message #'noteworthy-collab-preview--on-message
               :on-close (lambda (_ws)
                           (setq noteworthy-collab-preview--socket nil
                                 noteworthy-collab-preview--overlaid nil)
                           (noteworthy-collab--log 'warn "Preview control plane closed"))))
      (error
       (noteworthy-collab--log 'error "Preview connect failed: %s" (error-message-string err))
       nil))
    (when (noteworthy-collab-preview-connected-p)
      (noteworthy-collab--log 'info "Preview control plane: %s" target)
      (noteworthy-collab-preview--sync-all)
      t)))

;;;###autoload
(defun noteworthy-collab-preview-disconnect ()
  "Close the control-plane connection, dropping every overlay first."
  (interactive)
  (when (noteworthy-collab-preview-connected-p)
    (dolist (path (copy-sequence noteworthy-collab-preview--overlaid))
      (noteworthy-collab-preview--send `(("event" . "removeMemoryFiles")
                                         ("files" . [,path]))))
    (ignore-errors (websocket-close noteworthy-collab-preview--socket)))
  (setq noteworthy-collab-preview--socket nil
        noteworthy-collab-preview--overlaid nil))

(provide 'noteworthy-collab-preview)
;;; noteworthy-collab-preview.el ends here
