;; orgnote.el --- Package for synchronization with orgnote           -*- lexical-binding: t; -*-

;; Copyright (C) 2022 Artur Yaroshenko

;; Author: Artur Yaroshenko <artawower@protonmail.com>
;; URL: https://github.com/Artawower/orgnote.el
;; Package-Requires: ((emacs "27.1"))
;; Version: v0.10.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; This package provides functionality for syncing org roam notes with external service - Org Note
;; For more detail check https://github.com/Artawower/orgnote project.
;; This is an early alpha version of this app, it may have many bugs and problems, try to back up your notes before using it.
;;; Code:

(require 'json)
(require 'cl)

(defcustom orgnote-execution-script "orgnote-cli"
  "Bin command from cli to execute external script."
  :group 'orgnote
  :type 'string)

(defcustom orgnote-debug-p nil
  "Enable debug mode for better logging."
  :group 'orgnote
  :type 'boolean)

(defcustom orgnote-configuration-file-path "~/.config/orgnote/config.json"
  "Path to configuration file for Org Note."
  :group 'orgnote
  :type 'string)

(defconst orgnote--orgnote-log-buffer "*Orgnote. Org Note log*"
  "The name of Org Note buffer that run in background.")

(defconst orgnote--available-commands '("publish" "publish-all" "load" "sync")
  "Available commands for Org Note.")

(defvar orgnote-note-received-hook nil
  "Hook run after note received from remote server.")

(defun orgnote--normalize-path (path)
  "Normalize file PATH.  Shield spaces."
  (replace-regexp-in-string " " "\  " path))

(defun orgnote--pretty-log (format-text &rest args)
  "Pretty print FORMAT-TEXT with ARGS."
  (message (concat "[orgnote.el] " format-text) args))

(defun orgnote--handle-cmd-result (process signal &optional cmd callback)
  "Handle result from shell stdout by PROCESS and SIGNAL.

CMD - optional external command for logging.
CALLBACK - optional callback function."
  (when (memq (process-status process) '(exit signal))
    (orgnote--pretty-log "Completely done.")
    (shell-command-sentinel process signal)
    (when callback
      (funcall callback))
    (when cmd
      (with-current-buffer orgnote--orgnote-log-buffer
        (setq buffer-read-only nil)
        (goto-char (point-max))
        (insert "last command: " cmd)
        (setq buffer-read-only t)))))

(defun orgnote--execute-async-cmd (cmd &optional callback)
  "Execute async CMD.
Run CALLBACK after command execution."
  (add-to-list 'display-buffer-alist
               `(,orgnote--orgnote-log-buffer display-buffer-no-window))

  (let* ((output-buffer (get-buffer-create orgnote--orgnote-log-buffer))
         (final-cmd (if orgnote-debug-p (concat cmd " --debug") cmd))
         (proc (progn
                 (async-shell-command cmd output-buffer output-buffer)
                 (get-buffer-process output-buffer))))
    
    (when (process-live-p proc)
      (lexical-let ((fcmd final-cmd))
        (set-process-sentinel proc (lambda (process event)
                                     (orgnote--handle-cmd-result process event fcmd callback)))))))

(defun orgnote--org-file-p ()
  "Return t when current FILE-NAME is org file."
  (and (buffer-file-name)
       (equal (file-name-extension (buffer-file-name)) "org")))

(defun orgnote--read-configurations (cmd)
  "Read config files for CMD to remote server.
The default config file path is ~/.config/orgnote/config.json.
With next schema:
[
  {
    \"name\": \"any alias for pretty output\",
    \"remoteAddress\": \"server address\",
    \"token\": \"token (should be generated by remote server)\"
  }
Also you are free to use array of such objects instead of single object."
  (let* ((json-object-type 'hash-table)
         (json-array-type 'list)
         (json-key-type 'string)
         (json (json-read-file orgnote-configuration-file-path))
         (name-to-config (make-hash-table :test 'equal))
         (server-names '()))

    (if (= (length json) 1)
        (car json)
      (dolist (conf json)
        (puthash (gethash "name" conf) conf name-to-config)
        (push (gethash "name" conf) server-names))

      (gethash (completing-read (format "Choose server for %s: " cmd) server-names) name-to-config))))

(defun orgnote--execute-command (cmd &optional args callback)
  "Execute command CMD via string ARGS.
CALLBACK - optional callback function.
Will be called after command execution."

  (unless (member cmd orgnote--available-commands)
    (error (format "[orgnote.el] Unknown command %s" cmd)))

  (unless (file-exists-p orgnote-configuration-file-path)
    (orgnote--pretty-log "Configuration file %s not found" orgnote-configuration-file-path))

  (let* ((config (orgnote--read-configurations cmd))
         (account-name (gethash "name" config))
         (args (or args ""))
         (args (if (eq args "") "" (concat args " "))))
    (orgnote--execute-async-cmd
     (concat orgnote-execution-script
             (format " %s --accountName \"%s\" %s"
                     cmd
                     account-name
                     args))
     callback)))

(defun orgnote--after-receive-notes ()
  "Run hook after receive notes from remote server."
  (when (fboundp 'org-roam-db-sync)
    (org-roam-db-sync))
  (run-hooks 'orgnote-note-received-hook))

;;;###autoload
(defun orgnote-install-dependencies ()
  "Install necessary dependencies for Org Note.
Node js 14+ version is required."
  (interactive)
  (orgnote--execute-async-cmd "npm install -g orgnote-cli"))

;;;###autoload
(defun orgnote-publish-file ()
  "Publish current opened file to Org Note service."
  (interactive)
  (when (orgnote--org-file-p)
    (orgnote--execute-command "publish" (orgnote--normalize-path (buffer-file-name)))))

;;;###autoload
(defun orgnote-publish-all ()
  "Publish all files to Org Note service."
  (interactive)
  (orgnote--execute-command "publish-all"))

;;;###autoload
(defun orgnote-load ()
  "Load notes from remote."
  (interactive)
  (orgnote--execute-command "load" nil #'orgnote--after-receive-notes))

;;;###autoload
(defun orgnote-sync ()
  "Sync all files with Org Note service."
  (interactive)
  (orgnote--execute-command "sync" nil #'orgnote--after-receive-notes))

;;;###autoload
(define-minor-mode orgnote-sync-mode
  "Orgnote syncing mode.
Interactively with no argument, this command toggles the mode.
A positive prefix argument enables the mode, any other prefix
argument disables it.  From Lisp, argument omitted or nil enables
the mode, `toggle' toggles the state.

When `orgnote-sync-mode' is enabled, after save org mode files will
be synced with remote service."
  :init-value nil
  :global nil
  :lighter nil
  :group 'orgnote
  (if orgnote-sync-mode
      (when (orgnote--org-file-p)
        (add-hook 'before-save-hook #'orgnote-publish-file nil t))
    (remove-hook 'before-save-hook #'orgnote-publish-file t)))

(provide 'orgnote)
;;; orgnote.el ends here
