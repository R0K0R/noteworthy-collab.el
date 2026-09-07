;;; noteworthy-collab-layout.el --- Workspace layout for Noteworthy Collab -*- lexical-binding: t; -*-

;; Adapted from noteworthy-layout.el for remote collaborative editing.

;;; Code:

(require 'treemacs)
(require 'pdf-tools)
(require 'vterm)
;; cl-find-if below is not autoloaded.
(require 'cl-lib)

;;; ============================================================
;;; Variables
;;; ============================================================

(defvar noteworthy-collab-project-root nil
  "TRAMP path to the current project root.")

(defvar noteworthy-collab-master-file nil
  "Path to the master file (parser.typ).")

(defvar noteworthy-collab-preview-width nil
  "Width of the preview window in columns.
If nil, defaults to 35% of the frame width.")

(defvar noteworthy-collab-pdf-width nil
  "Width of the PDF window in columns.
If nil, defaults to 35% of the frame width.")

(defvar noteworthy-collab-terminal-shell nil
  "Shell command for the terminal.
If nil, uses default shell.")

(defvar noteworthy-collab-preview-url nil
  "URL for tinymist preview (port-forwarded).
If nil, preview is skipped.")

(defvar noteworthy-collab-settings-file
  (expand-file-name "noteworthy-collab-settings.el" user-emacs-directory)
  "File to store layout settings.")

(defvar noteworthy-collab--editor-window nil
  "Reference to the main editor window.")

;;; ============================================================
;;; Treemacs Enforcement
;;; ============================================================

(defun noteworthy-collab--enforce-treemacs-root ()
  "Force Treemacs to display `noteworthy-collab-project-root` exclusively.
Call this after any operation that might cause Treemacs to switch roots."
  (when (and (bound-and-true-p noteworthy-collab-project-root)
             (treemacs-get-local-window))
    (let ((default-directory noteworthy-collab-project-root))
      (treemacs-add-and-display-current-project-exclusively))))

;;; ============================================================
;;; PDF Window Setup
;;; ============================================================

(defun noteworthy-collab--setup-pdf-window (editor-window pdf-file)
  "Setup the PDF window next to EDITOR-WINDOW displaying PDF-FILE."
  (when (and pdf-file
             (stringp pdf-file)
             (not (string-empty-p pdf-file))
             (not (file-directory-p pdf-file)))
    ;; Ensure pdf-tools is ready
    (unless (bound-and-true-p pdf-view-mode)
      (if (fboundp 'pdf-tools-install)
          (pdf-tools-install)
        (message "Noteworthy: pdf-tools not found!")))

    (when (window-live-p editor-window)
      (select-window editor-window)
      (let* ((pdf-window (split-window editor-window nil 'right))
             (target-width (or noteworthy-collab-pdf-width
                               (round (* 0.35 (frame-width)))))
             (current-width (window-total-width pdf-window))
             (delta (- target-width current-width)))
        (set-window-parameter pdf-window 'noteworthy-pdf t)
        (when (/= delta 0)
          (ignore-errors (window-resize pdf-window delta t)))
        (select-window pdf-window)
        (find-file pdf-file)
        ;; Only fit zoom to width, do not resize window
        (when (bound-and-true-p pdf-view-mode)
          (run-with-timer 0.1 nil
                          (lambda (win)
                            (when (window-live-p win)
                              (with-selected-window win
                                (pdf-view-fit-width-to-window))))
                          pdf-window))))))

;;; ============================================================
;;; Preview Window Setup
;;; ============================================================

(defun noteworthy-collab--setup-preview-window (editor-window)
  "Setup xwidget preview window next to EDITOR-WINDOW.
If `noteworthy-collab-preview-url` is nil, creates a placeholder buffer."
  (message "DEBUG: setup-preview-window called. URL: %s, xwidgets: %s"
           noteworthy-collab-preview-url (featurep 'xwidget-internal))
  (when (window-live-p editor-window)
    (select-window editor-window)
    (let* ((preview-window (split-window editor-window nil 'right))
           (target-width (or noteworthy-collab-preview-width
                             (round (* 0.35 (frame-width)))))
           (current-width (window-total-width preview-window))
           (delta (- target-width current-width)))
      (set-window-parameter preview-window 'noteworthy-preview t)
      (when (/= delta 0)
        (ignore-errors (window-resize preview-window delta t)))
      (select-window preview-window)
      
      (if (and noteworthy-collab-preview-url (featurep 'xwidget-internal))
          (xwidget-webkit-browse-url noteworthy-collab-preview-url)
        ;; Placeholder buffer if URL not ready
        (let ((buf (get-buffer-create "*noteworthy-preview-placeholder*")))
          (with-current-buffer buf
            (erase-buffer)
            (insert "\n\n  Waiting for preview URL...\n")
            (read-only-mode 1))
          (switch-to-buffer buf)))
      
      (set-window-dedicated-p preview-window t))))

(defun noteworthy-collab-refresh-preview ()
  "Refresh the preview window with `noteworthy-collab-preview-url`."
  (interactive)
  (message "Refreshing preview. URL: %s" noteworthy-collab-preview-url)
  (when (and noteworthy-collab-preview-url (featurep 'xwidget-internal))
    (when-let ((win (cl-find-if (lambda (w) (window-parameter w 'noteworthy-preview)) (window-list))))
      (select-window win)
      (xwidget-webkit-browse-url noteworthy-collab-preview-url))))

;;; ============================================================
;;; Main Layout Initialization
;;; ============================================================

(defun noteworthy-collab-layout-init (project-dir &optional pdf-path-arg)
  "Initialize Noteworthy collaborative workspace with PROJECT-DIR.
PROJECT-DIR should be a TRAMP path for remote projects.
Optional PDF-PATH-ARG specifies a PDF file to display."
  (interactive
   (let ((dir (read-directory-name "Noteworthy project: " "/ssh:")))
     (list dir
           (read-file-name "Secondary PDF (optional): " dir nil nil))))

    (let* ((dir (expand-file-name (or project-dir default-directory)))
           (pdf-file (cond
                      ((and pdf-path-arg (stringp pdf-path-arg) (file-exists-p pdf-path-arg)) pdf-path-arg)
                      ((and (stringp pdf-path-arg) (string-empty-p pdf-path-arg)) nil)
                      (t nil))))

    (delete-other-windows)
    
    ;; Set global project variables
    (setq-default noteworthy-collab-project-root dir)
    (setq noteworthy-collab-project-root dir)

    ;; Load project-specific settings (if any)
    (noteworthy-collab-load-settings dir)

    ;; Find master file
    (let ((master-path
           (let ((core-parser (expand-file-name "templates/core/parser.typ" dir))
                 (old-parser (expand-file-name "templates/parser.typ" dir)))
             (cond
              ((file-exists-p core-parser) core-parser)
              ((file-exists-p old-parser) old-parser)
              (t
               (let ((typ-files (directory-files-recursively dir "\\.typ$")))
                 (if typ-files
                     (car typ-files)
                   (expand-file-name "main.typ" dir))))))))
      
      (setq-default noteworthy-collab-master-file master-path)
      (setq noteworthy-collab-master-file master-path)
      (find-file master-path))

    (let ((editor-window (selected-window)))
      (set-window-parameter editor-window 'noteworthy-editor t)
      (setq noteworthy-collab--editor-window editor-window)

      ;; 1. Setup Treemacs (Left)
      (treemacs)
      (let ((default-directory dir))
        (treemacs-add-and-display-current-project-exclusively))
      
      ;; 2. Setup Preview (if URL configured)
      ;; Moved before terminal to ensure it gets full height/side layout first
      (when noteworthy-collab-preview-url
        (noteworthy-collab--setup-preview-window editor-window)
        (select-window editor-window))

      ;; 3. Setup Terminal (Bottom of Editor)
      (select-window editor-window)
      (let ((term-window (split-window-below (floor (* 0.75 (window-height))))))
        (select-window term-window)
        (let ((default-directory dir)
              (shell-cmd (or noteworthy-collab-terminal-shell
                             (executable-find "bash")
                             (getenv "SHELL"))))
          ;; Configure vterm to run our specific command
          (let ((cmd (if (listp shell-cmd)
                         (mapconcat #'identity shell-cmd " ")
                       shell-cmd))
                (old-shell (if (boundp 'vterm-shell) vterm-shell nil)))
            (setq vterm-shell cmd)
            (unwind-protect
                (let ((display-buffer-alist nil))
                  (vterm))
              (when old-shell (setq vterm-shell old-shell))))))

      (select-window editor-window)
      
      ;; 4. Setup PDF (if provided)
      (when pdf-file
        (noteworthy-collab--setup-pdf-window editor-window pdf-file)
        (select-window editor-window))
      
      ;; Re-enforce Treemacs root after all windows loaded
      (run-with-timer 0.1 nil #'noteworthy-collab--enforce-treemacs-root)
      
      ;; Final: Restore focus to editor
      (select-window editor-window)

      (message "Noteworthy Collab initialized: %s" dir))))

;;; ============================================================
;;; Window Size Tracking
;;; ============================================================

(defun noteworthy-collab-track-window-sizes (&optional frame)
  "Track size changes for Noteworthy windows and update variables."
  (when (bound-and-true-p noteworthy-collab-project-root)
    (let ((wins (window-list frame)))
      (dolist (w wins)
        (cond
         ((window-parameter w 'noteworthy-pdf)
          (setq noteworthy-collab-pdf-width (window-total-width w)))
         ((window-parameter w 'noteworthy-preview)
          (setq noteworthy-collab-preview-width (window-total-width w))))))))

(add-hook 'window-size-change-functions #'noteworthy-collab-track-window-sizes)

;;; ============================================================
;;; Settings Persistence
;;; ============================================================

(defun noteworthy-collab-load-settings (&optional root)
  "Load settings from project ROOT or fallback to global settings file."
  (let* ((root-file (and root (expand-file-name ".noteworthy-layout" root)))
         (file (if (and root-file (file-exists-p root-file))
                   root-file
                 noteworthy-collab-settings-file)))
    (when (and file (file-exists-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case nil
            (let ((settings (read (current-buffer))))
              (when (plist-get settings :pdf-width)
                (setq noteworthy-collab-pdf-width (plist-get settings :pdf-width)))
              (when (plist-get settings :preview-width)
                (setq noteworthy-collab-preview-width (plist-get settings :preview-width)))
              (message "Noteworthy: Loaded layout from %s" file))
          (error (message "Error loading noteworthy settings from %s" file)))))))

(defun noteworthy-collab-save-settings ()
  "Save Noteworthy configuration variables.
Saves to BOTH global settings file AND project root (if active)."
  (let ((settings (list :preview-width (or noteworthy-collab-preview-width
                                           (round (* 0.35 (frame-width))))
                        :pdf-width (or noteworthy-collab-pdf-width
                                       (round (* 0.35 (frame-width)))))))
    
    ;; 1. Save Global Fallback
    (with-temp-file noteworthy-collab-settings-file
      (insert ";; Noteworthy collab global settings - fallback\n")
      (let ((print-length nil) (print-level nil))
        (prin1 settings (current-buffer)))
      (insert "\n"))

    ;; 2. Save Project Local (if active and writable)
    (when (and (bound-and-true-p noteworthy-collab-project-root)
               (file-directory-p noteworthy-collab-project-root)
               (file-writable-p noteworthy-collab-project-root))
      (let ((local-file (expand-file-name ".noteworthy-layout" noteworthy-collab-project-root)))
        (condition-case nil
            (with-temp-file local-file
              (insert ";; Noteworthy collab project settings\n")
              (let ((print-length nil) (print-level nil))
                (prin1 settings (current-buffer)))
              (insert "\n"))
          (error nil))))))  ;; Silently fail for remote paths that can't write

;; Load global settings immediately on startup
(noteworthy-collab-load-settings)

;; Save config on Emacs exit
(add-hook 'kill-emacs-hook #'noteworthy-collab-save-settings)

;;; ============================================================
;;; Window Navigation & Utilities
;;; ============================================================

(defun noteworthy-collab-select-editor ()
  "Select the editor window."
  (interactive)
  (when (and noteworthy-collab--editor-window
             (window-live-p noteworthy-collab--editor-window))
    (select-window noteworthy-collab--editor-window)))

(defun noteworthy-collab-select-preview ()
  "Select the preview window."
  (interactive)
  (when-let ((win (cl-find-if (lambda (w)
                                (window-parameter w 'noteworthy-preview))
                              (window-list))))
    (select-window win)))

(defun noteworthy-collab-select-pdf ()
  "Select the PDF window."
  (interactive)
  (when-let ((win (cl-find-if (lambda (w)
                                (window-parameter w 'noteworthy-pdf))
                              (window-list))))
    (select-window win)))

(provide 'noteworthy-collab-layout)

;;; noteworthy-collab-layout.el ends here
