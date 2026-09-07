;;; noteworthy-collab-keys.el --- Collab bindings for noteworthy-typst-mode -*- lexical-binding: t; -*-

;; Author: r0k0r
;; Keywords: typst, collaboration, tools

;;; Commentary:
;; The collab commands used to be bound from a forked copy of
;; `noteworthy-evil.el'.  That forked the whole file — and its feature name —
;; away from the noteworthy.el package, so whichever loaded last silently won.
;; The bindings live here instead, and noteworthy.el keeps ownership of
;; `noteworthy-typst-mode-map' and `noteworthy-evil-setup'.

;;; Code:

(require 'noteworthy-typst)

(defun noteworthy-collab-keys-setup ()
  "Bind collab commands in `noteworthy-typst-mode-map'."
  (define-key noteworthy-typst-mode-map (kbd "M-t u") #'noteworthy-collab-track-user)
  (define-key noteworthy-typst-mode-map (kbd "M-t t") #'noteworthy-collab-show-terminal)
  (define-key noteworthy-typst-mode-map (kbd "M-t d") #'noteworthy-collab-show-debug)
  (define-key noteworthy-typst-mode-map (kbd "M-t c") #'noteworthy-collab-show-chat)
  (define-key noteworthy-typst-mode-map (kbd "M-t l") #'noteworthy-collab-show-typst-log)
  (when (fboundp 'evil-normalize-keymaps)
    (evil-normalize-keymaps)))

;; Depth 90 so this runs after noteworthy.el's own hooks and wins any conflict.
(add-hook 'noteworthy-typst-mode-hook #'noteworthy-collab-keys-setup 90)

(provide 'noteworthy-collab-keys)
;;; noteworthy-collab-keys.el ends here
