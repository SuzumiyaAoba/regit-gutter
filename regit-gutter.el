;;; regit-gutter.el --- Asynchronous, visible-range Git gutter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 regit-gutter contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: vc, tools
;; URL: https://github.com/SuzumiyaAoba/regit-gutter

;;; Commentary:
;; Independent Git gutter implementation.  Compare the index with saved files,
;; asynchronously.  Unsaved edits invalidate indicators rather than displaying
;; misleading positions.  Git processes are file-scoped and coalesced.  Only
;; visible lines get overlays; no primitive advice, polling, or native compiler
;; dependency.  See README.md for supported operations and deliberate limits.

;;; Code:

(eval-when-compile (require 'cl-lib))

(defgroup regit-gutter nil "Asynchronous Git change indicators." :group 'vc)
(defcustom regit-gutter-git-executable "git"
  "Git executable." :type 'string)
(defcustom regit-gutter-delay 0.15
  "Seconds to debounce refresh requests." :type 'number)
(defcustom regit-gutter-prefetch-lines 8
  "Additional lines to render below each window." :type 'natnum)
(defcustom regit-gutter-added-sign "+"
  "One-column addition indicator." :type 'string)
(defcustom regit-gutter-modified-sign "~"
  "One-column modification indicator." :type 'string)
(defcustom regit-gutter-deleted-sign "-"
  "One-column deletion indicator (on the preceding surviving line)." :type 'string)
(defface regit-gutter-added '((t (:inherit success))) "Addition face.")
(defface regit-gutter-modified '((t (:inherit warning))) "Modification face.")
(defface regit-gutter-deleted '((t (:inherit error))) "Deletion face.")

(cl-defstruct (regit-gutter--hunk (:constructor regit-gutter--make-hunk))
  old-start old-count new-start new-count patch start end)

(defvar regit-gutter-mode)
(defvar regit-gutter--buffers nil)
(defvar-local regit-gutter--root nil)
(defvar-local regit-gutter--path nil)
(defvar-local regit-gutter--generation 0)
(defvar-local regit-gutter--process nil)
(defvar-local regit-gutter--operation nil)
(defvar-local regit-gutter--timer nil)
(defvar-local regit-gutter--diff nil)
(defvar-local regit-gutter--header nil)
(defvar-local regit-gutter--hunks [])
(defvar-local regit-gutter--overlays nil)
(defvar-local regit-gutter--signature nil)
(defvar-local regit-gutter--error nil)

(defun regit-gutter--parse (diff)
  "Return (HEADER . HUNKS) for a single-file unified DIFF.
HUNKS is a vector.  Preserve the raw patch, including no-newline markers."
  (let ((regexp "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? +\\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@.*$")
        (offset 0) header hunks previous)
    (while (string-match regexp diff offset)
      (let* ((start (match-beginning 0))
             (next (match-end 0))
             (hunk (regit-gutter--make-hunk
                    :old-start (string-to-number (match-string 1 diff))
                    :old-count (if (match-string 2 diff)
                                   (string-to-number (match-string 2 diff)) 1)
                    :new-start (string-to-number (match-string 3 diff))
                    :new-count (if (match-string 4 diff)
                                   (string-to-number (match-string 4 diff)) 1))))
        (if previous
            (setf (regit-gutter--hunk-patch (car hunks))
                  (substring diff previous start))
          (setq header (substring diff 0 start)))
        (push hunk hunks)
        (setq previous start offset next)))
    (when previous
      (setf (regit-gutter--hunk-patch (car hunks)) (substring diff previous)))
    (cons header (vconcat (nreverse hunks)))))

(defun regit-gutter--diff-args ()
  "Arguments for a deterministic, literal, single-file index/worktree diff."
  (list "--literal-pathspecs" "diff" "--no-ext-diff" "--no-textconv"
        "--no-color" "--no-renames" "--unified=0" "--inter-hunk-context=0"
        "--src-prefix=a/" "--dst-prefix=b/" "--" regit-gutter--path))

(defun regit-gutter--spawn (root args callback &optional input)
  "Run Git ARGS in ROOT, calling CALLBACK with (STATUS OUTPUT STDERR).
Send INPUT to stdin if non-nil.  Always release process buffers."
  (let ((out (generate-new-buffer " *regit-output*"))
        (err (generate-new-buffer " *regit-error*"))
        (default-directory root)
        (process-environment (cons "GIT_OPTIONAL_LOCKS=0" process-environment))
        process)
    (condition-case error-data
        (progn
          (setq process
                (make-process
                 :name "regit-gutter" :buffer out :stderr err
                 :command (cons regit-gutter-git-executable args)
                 :connection-type 'pipe :coding 'utf-8-unix :noquery t
                 :sentinel
                 (lambda (proc _event)
                   (when (and (memq (process-status proc) '(exit signal))
                              (not (process-get proc 'regit-finished)))
                     ;; Buffer cleanup can reenter process sentinels.
                     (process-put proc 'regit-finished t)
                     (let ((output (when (buffer-live-p out)
                                     (with-current-buffer out (buffer-string))))
                           (errors (when (buffer-live-p err)
                                     (with-current-buffer err (buffer-string)))))
                       (when (buffer-live-p out) (kill-buffer out))
                       (when (buffer-live-p err) (kill-buffer err))
                       (unless (process-get proc 'regit-cancelled)
                         (funcall callback (process-exit-status proc)
                                  output errors)))))))
          (when input (process-send-string process input))
          (process-send-eof process)
          process)
      (error
       (when (process-live-p process)
         (process-put process 'regit-cancelled t)
         (delete-process process))
       (when (buffer-live-p out) (kill-buffer out))
       (when (buffer-live-p err) (kill-buffer err))
       (signal (car error-data) (cdr error-data))))))

(defun regit-gutter--cancel-read ()
  "Cancel queued and in-flight read work, never a Git write."
  (when (timerp regit-gutter--timer) (cancel-timer regit-gutter--timer))
  (setq regit-gutter--timer nil)
  (when (process-live-p regit-gutter--process)
    (process-put regit-gutter--process 'regit-cancelled t)
    (delete-process regit-gutter--process))
  (setq regit-gutter--process nil))

(defun regit-gutter--clear ()
  "Remove derived state, including all owned overlays."
  (when regit-gutter--overlays
    (maphash (lambda (_ overlay) (delete-overlay overlay))
             regit-gutter--overlays)
    (clrhash regit-gutter--overlays))
  (setq regit-gutter--hunks [] regit-gutter--header nil
        regit-gutter--diff nil regit-gutter--signature nil))

(defun regit-gutter--valid-p (generation tick file)
  "Whether results from GENERATION, TICK and FILE still describe this buffer."
  (and regit-gutter-mode (= generation regit-gutter--generation)
       (= tick (buffer-chars-modified-tick))
       (equal file buffer-file-name) (not (buffer-modified-p))
       (verify-visited-file-modtime (current-buffer))))

(defun regit-gutter--positions ()
  "Compute hunk positions in one monotonically forward pass."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (let ((line 1))
        (cl-loop for hunk across regit-gutter--hunks do
          (let ((target (max 1 (regit-gutter--hunk-new-start hunk))))
            (forward-line (- target line))
            (setq line target)
            (setf (regit-gutter--hunk-start hunk) (point)
                  (regit-gutter--hunk-end hunk)
                  (save-excursion
                    (forward-line (max 1 (regit-gutter--hunk-new-count hunk)))
                    (max (point) (1+ (regit-gutter--hunk-start hunk)))))))))))

(defun regit-gutter--start ()
  "Launch one file-scoped diff if the buffer represents a saved file."
  (setq regit-gutter--timer nil)
  (when (and regit-gutter-mode (not regit-gutter--operation)
             (not (buffer-modified-p)) buffer-file-name
             (verify-visited-file-modtime (current-buffer)))
    (regit-gutter--cancel-read)
    (let ((buffer (current-buffer)) (generation regit-gutter--generation)
          (tick (buffer-chars-modified-tick)) (file buffer-file-name))
      (condition-case err
          (setq regit-gutter--process
                (regit-gutter--spawn
                 regit-gutter--root (regit-gutter--diff-args)
                 (lambda (status output errors)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (= generation regit-gutter--generation)
                         (setq regit-gutter--process nil))
                       (when (regit-gutter--valid-p generation tick file)
                         (setq regit-gutter--error (unless (zerop status) errors))
                         (if (not (zerop status))
                             (regit-gutter--clear)
                           (let ((parsed (regit-gutter--parse output)))
                             (setq regit-gutter--diff output
                                   regit-gutter--header (car parsed)
                                   regit-gutter--hunks (cdr parsed)
                                   regit-gutter--signature nil)
                             (regit-gutter--positions)
                             (regit-gutter--render)))))))))
        (error (setq regit-gutter--error (error-message-string err)))))))

;;;###autoload
(defun regit-gutter-refresh ()
  "Invalidate and schedule a fresh asynchronous diff.
Use after external index changes, such as a Magit stage or Git checkout."
  (interactive)
  (when regit-gutter-mode
    (cl-incf regit-gutter--generation)
    (regit-gutter--cancel-read)
    (regit-gutter--clear)
    (let ((buffer (current-buffer)))
      (setq regit-gutter--timer
            (run-with-timer
             regit-gutter-delay nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer (regit-gutter--start)))))))))

;;;###autoload
(defun regit-gutter-refresh-all ()
  "Refresh all enabled buffers, for example after an external Git operation."
  (interactive)
  (dolist (buffer regit-gutter--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (regit-gutter-refresh)))))

(defun regit-gutter--changed (&rest _)
  "Invalidate saved-file indicators at the first unsaved edit."
  (when (or regit-gutter--diff regit-gutter--process regit-gutter--timer)
    (cl-incf regit-gutter--generation)
    (regit-gutter--cancel-read)
    (regit-gutter--clear)))

(defun regit-gutter--first-hunk (position)
  "Binary-search the first hunk whose end exceeds POSITION."
  (let ((lo 0) (hi (length regit-gutter--hunks)))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (<= (regit-gutter--hunk-end (aref regit-gutter--hunks mid)) position)
            (setq lo (1+ mid))
          (setq hi mid))))
    lo))

(defun regit-gutter--sign (hunk)
  "Return a propertized margin string for HUNK."
  (let* ((type (cond ((zerop (regit-gutter--hunk-new-count hunk)) 'deleted)
                     ((zerop (regit-gutter--hunk-old-count hunk)) 'added)
                     (t 'modified)))
         (face (intern (format "regit-gutter-%s" type)))
         (sign (symbol-value (intern (format "regit-gutter-%s-sign" type)))))
    (propertize " " 'display
                `((margin left-margin) ,(propertize sign 'face face)))))

(defun regit-gutter--render (&rest _)
  "Render the visible ranges only, reusing overlays at unchanged positions."
  (when (and regit-gutter-mode regit-gutter--diff)
    (let ((ranges
           (mapcar
            (lambda (window)
              (cons (window-start window)
                    (save-excursion
                      ;; Before first redisplay, window-end can be stale and
                      ;; report point-max.  Always cap work by window height.
                      (goto-char (window-start window))
                      (forward-line (window-body-height window))
                      (goto-char (min (point) (or (window-end window t) (point))))
                      (forward-line regit-gutter-prefetch-lines)
                      (+ (point) (if (eobp) 1 0)))))
            (get-buffer-window-list (current-buffer) nil t))))
      (unless (equal ranges regit-gutter--signature)
        (setq regit-gutter--signature ranges)
        (let ((wanted (make-hash-table :test #'eql)))
          (save-excursion
            (dolist (range ranges)
              (let ((i (regit-gutter--first-hunk (car range))))
                (while (and (< i (length regit-gutter--hunks))
                            (< (regit-gutter--hunk-start
                                (aref regit-gutter--hunks i)) (cdr range)))
                  (let* ((hunk (aref regit-gutter--hunks i))
                         (end (min (cdr range) (regit-gutter--hunk-end hunk)))
                         (sign (regit-gutter--sign hunk)))
                    (goto-char (max (car range) (regit-gutter--hunk-start hunk)))
                    (beginning-of-line)
                    (while (< (point) end)
                      (puthash (point) sign wanted)
                      (if (eobp) (setq end (point)) (forward-line 1))))
                  (cl-incf i)))))
          (maphash (lambda (pos overlay)
                     (unless (gethash pos wanted)
                       (delete-overlay overlay)
                       (remhash pos regit-gutter--overlays)))
                   regit-gutter--overlays)
          (maphash
           (lambda (pos sign)
             (let ((overlay (or (gethash pos regit-gutter--overlays)
                                (let ((new (make-overlay pos pos)))
                                  (overlay-put new 'regit-gutter t)
                                  (puthash pos new regit-gutter--overlays)
                                  new))))
               (unless (equal sign (overlay-get overlay 'before-string))
                 (overlay-put overlay 'before-string sign))))
           wanted))))))

(defun regit-gutter--scroll (window _start)
  "Update icons for WINDOW, including nonselected windows."
  (with-current-buffer (window-buffer window) (regit-gutter--render)))

(defun regit-gutter--windows ()
  "Acquire/release margin space for visible gutter buffers.
Do not overwrite a margin width subsequently changed by another package."
  (walk-windows
   (lambda (window)
     (let* ((buffer (window-buffer window))
            (active (buffer-local-value 'regit-gutter-mode buffer))
            (owned (window-parameter window 'regit-gutter-margin))
            (left (car (window-margins window))))
       (when (and owned (not active))
         (when (= (or left 0) 1)
           (set-window-margins window (car owned) (cdr (window-margins window))))
         (set-window-parameter window 'regit-gutter-margin nil))
       (when active
         (when (< (or left 0) 1)
           (unless owned
             (set-window-parameter window 'regit-gutter-margin (list left)))
           (set-window-margins window 1 (cdr (window-margins window))))
         (with-current-buffer buffer (regit-gutter--render)))))
   'nomini t))

(defun regit-gutter--current-hunk ()
  "Return the hunk at point, or signal a user error."
  (unless (and regit-gutter-mode (not (buffer-modified-p))
               regit-gutter--diff (verify-visited-file-modtime (current-buffer)))
    (user-error "Save/revert the buffer and refresh the gutter first"))
  (let* ((position (line-beginning-position))
         (i (regit-gutter--first-hunk position))
         (hunk (and (< i (length regit-gutter--hunks))
                    (aref regit-gutter--hunks i))))
    (unless (and hunk (<= (regit-gutter--hunk-start hunk) position))
      (user-error "No change at point"))
    hunk))

(defun regit-gutter-next-hunk (&optional count)
  "Move COUNT hunks forward, wrapping within the buffer."
  (interactive "p")
  (unless (> (length regit-gutter--hunks) 0) (user-error "No changes"))
  (let* ((count (or count 1))
         (positions (cl-loop for hunk across regit-gutter--hunks
                             for pos = (regit-gutter--hunk-start hunk)
                             when (<= (point-min) pos (point-max)) collect pos))
         (position (line-beginning-position))
         (index (if (< count 0)
                    (1- (cl-loop for p in positions count (< p position)))
                  (cl-loop for p in positions count (<= p position)))))
    (unless positions (user-error "No changes in the accessible region"))
    (goto-char (nth (mod (+ index (if (< count 0) (1+ count) (1- count)))
                        (length positions)) positions))))

(defun regit-gutter-previous-hunk (&optional count)
  "Move COUNT hunks backward."
  (interactive "p")
  (regit-gutter-next-hunk (- (or count 1))))

(defun regit-gutter-popup-hunk ()
  "Display the raw patch for the change at point."
  (interactive)
  (let ((patch (regit-gutter--hunk-patch (regit-gutter--current-hunk))))
    (with-current-buffer (get-buffer-create "*regit-gutter hunk*")
      (let ((inhibit-read-only t))
        (erase-buffer) (insert patch) (goto-char (point-min)))
      (if (fboundp 'diff-mode) (diff-mode) (special-mode))
      (display-buffer (current-buffer)))))

(defun regit-gutter--operate (revert)
  "Asynchronously stage a hunk, or REVERT it in the saved file.
Revalidate the entire diff before mutation.  Git apply additionally validates
patch applicability.  Never overwrite unsaved buffer changes on completion."
  (when regit-gutter--operation (user-error "Git operation already running"))
  (let* ((hunk (regit-gutter--current-hunk))
         (snapshot regit-gutter--diff)
         ;; A text-hunk operation must not stage/revert unrelated chmod work.
         (patch (concat (replace-regexp-in-string
                         "^\\(?:old mode\\|new mode\\) [0-9]+\n" ""
                         regit-gutter--header)
                        (regit-gutter--hunk-patch hunk)))
         (buffer (current-buffer)) (file buffer-file-name)
         (root regit-gutter--root)
         (tick (buffer-chars-modified-tick))
         (generation regit-gutter--generation))
    (when (or (not revert)
              (yes-or-no-p
               (if (string-match-p "^new file mode " regit-gutter--header)
                   "Discard this hunk and delete the newly added file? "
                 "Discard this hunk from the saved file? ")))
      (regit-gutter--cancel-read)
      (setq regit-gutter--operation
            (regit-gutter--spawn
             root (regit-gutter--diff-args)
             (lambda (status output errors)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq regit-gutter--operation nil)
                   (if (not (and (zerop status) (equal snapshot output)
                                 (regit-gutter--valid-p generation tick file)))
                       (progn
                         (message "regit-gutter: stale hunk or Git error; not applied: %s"
                                  (or errors ""))
                         (regit-gutter-refresh))
                     (condition-case err
                         (setq regit-gutter--operation
                               (regit-gutter--spawn
                                root (append '("apply" "--unidiff-zero")
                                             (if revert '("--reverse") '("--cached"))
                                             '("-"))
                                (lambda (exit _text stderr)
                                  (when (buffer-live-p buffer)
                                    (with-current-buffer buffer
                                      (setq regit-gutter--operation nil
                                            regit-gutter--error
                                            (unless (zerop exit) stderr))
                                      (when (and (zerop exit) revert
                                                 (equal file buffer-file-name)
                                                 (= tick (buffer-chars-modified-tick))
                                                 (not (buffer-modified-p)))
                                        (if (file-exists-p file)
                                            (revert-buffer t t)
                                          ;; Reversing an intent-to-add patch
                                          ;; removes the newly created file.
                                          (let ((inhibit-read-only t)) (erase-buffer))
                                          (set-visited-file-modtime)
                                          (set-buffer-modified-p nil)))
                                      (regit-gutter-refresh)
                                      (message "regit-gutter: %s"
                                               (if (zerop exit) "hunk applied" stderr)))))
                                patch))
                       (error (setq regit-gutter--error (error-message-string err))
                              (message "regit-gutter: %s" regit-gutter--error))))))))))))

(defun regit-gutter-stage-hunk ()
  "Stage the saved hunk at point, leaving other hunks unstaged."
  (interactive) (regit-gutter--operate nil))

(defun regit-gutter-revert-hunk ()
  "Discard the saved hunk at point after confirmation."
  (interactive) (regit-gutter--operate t))

(defun regit-gutter--renamed ()
  "Rediscover the repository after changing the visited file name."
  (regit-gutter-mode -1)
  (regit-gutter-mode 1))

(defun regit-gutter--stop ()
  "Remove owned resources.  In-flight Git writes are allowed to finish."
  (setq regit-gutter-mode nil)
  (cl-incf regit-gutter--generation)
  (regit-gutter--cancel-read)
  (regit-gutter--clear)
  (dolist (pair '((after-save-hook . regit-gutter-refresh)
                  (after-revert-hook . regit-gutter-refresh)
                  (after-change-functions . regit-gutter--changed)
                  (window-scroll-functions . regit-gutter--scroll)
                  (kill-buffer-hook . regit-gutter--stop)
                  (change-major-mode-hook . regit-gutter--stop)
                  (after-set-visited-file-name-hook . regit-gutter--renamed)))
    (remove-hook (car pair) (cdr pair) t))
  (setq regit-gutter--buffers (delq (current-buffer) regit-gutter--buffers))
  (regit-gutter--windows)
  (unless regit-gutter--buffers
    (remove-hook 'window-configuration-change-hook #'regit-gutter--windows)))

;;;###autoload
(define-minor-mode regit-gutter-mode
  "Display saved, tracked Git changes relative to the index.
Only local, nonsymlink, UTF-8/ASCII files are supported.
There is no polling of external Git operations; use
`regit-gutter-refresh' after changing the index."
  :lighter " rG"
  (if (not regit-gutter-mode)
      (regit-gutter--stop)
    (let ((root (and buffer-file-name (not (buffer-base-buffer))
                     (memq (coding-system-base (or buffer-file-coding-system 'utf-8))
                           '(utf-8 utf-8-emacs undecided us-ascii))
                     (not (file-remote-p buffer-file-name))
                     (not (file-symlink-p buffer-file-name))
                     (locate-dominating-file buffer-file-name ".git"))))
      (if (not root)
          (setq regit-gutter-mode nil)
        (setq regit-gutter--root (expand-file-name root)
              regit-gutter--path (file-relative-name buffer-file-name root)
              regit-gutter--overlays (or regit-gutter--overlays
                                        (make-hash-table :test #'eql)))
        (cl-pushnew (current-buffer) regit-gutter--buffers)
        (add-hook 'window-configuration-change-hook #'regit-gutter--windows)
        (add-hook 'after-save-hook #'regit-gutter-refresh nil t)
        (add-hook 'after-revert-hook #'regit-gutter-refresh nil t)
        (add-hook 'after-change-functions #'regit-gutter--changed nil t)
        (add-hook 'window-scroll-functions #'regit-gutter--scroll nil t)
        (add-hook 'kill-buffer-hook #'regit-gutter--stop nil t)
        (add-hook 'change-major-mode-hook #'regit-gutter--stop nil t)
        (add-hook 'after-set-visited-file-name-hook #'regit-gutter--renamed nil t)
        (regit-gutter--windows)
        (regit-gutter-refresh)))))

(defun regit-gutter--turn-on ()
  "Enable the gutter in eligible file buffers."
  (when buffer-file-name (regit-gutter-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-regit-gutter-mode
  regit-gutter-mode regit-gutter--turn-on)

(provide 'regit-gutter)
;;; regit-gutter.el ends here
