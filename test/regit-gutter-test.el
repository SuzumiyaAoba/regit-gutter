;;; regit-gutter-test.el --- Regression tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'regit-gutter)

(defun regit-test--git (root &rest args)
  (with-temp-buffer
    (let ((default-directory root)
          (process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null"
                                         "GIT_CONFIG_NOSYSTEM=1") process-environment)))
      (unless (zerop (apply #'process-file "git" nil t nil "--literal-pathspecs" args))
        (error "Git failed: %s %s" args (buffer-string)))
      (buffer-string))))

(defun regit-test--text (&optional changes)
  (mapconcat (lambda (i) (format "%s-%02d\n" (if (memq i changes) "new" "old") i))
             (number-sequence 1 30) ""))

(defun regit-test--wait ()
  (let ((deadline (+ (float-time) 10)))
    (while (and (< (float-time) deadline)
                (or regit-gutter--timer regit-gutter--operation
                    regit-gutter--process))
      (accept-process-output nil 0.01))
    (should-not regit-gutter--timer)
    (should-not regit-gutter--operation)
    (should-not regit-gutter--process)))

(defmacro regit-test--repo (name &rest body)
  (declare (indent 1))
  `(let* ((root (make-temp-file "regit-test-" t))
          (file (expand-file-name ,name root))
          (regit-gutter-delay 0.001)
          (vc-handled-backends nil)
          buffer)
     (unwind-protect
         (progn
           (regit-test--git root "init" "--quiet")
           (with-temp-file file (insert (regit-test--text)))
           (regit-test--git root "add" "--" ,name)
           (regit-test--git root "-c" "user.name=Test" "-c" "user.email=t@example.org"
                           "-c" "commit.gpgsign=false" "commit" "--quiet" "-m" "base")
           (with-temp-file file (insert (regit-test--text '(3 22))))
           (setq buffer (find-file-noselect file))
           (with-current-buffer buffer
             (regit-gutter-mode 1)
             (regit-test--wait)
             ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (regit-test--wait)
           (set-buffer-modified-p nil)
           (kill-buffer buffer)))
       (delete-directory root t))))

(ert-deftest regit-parse-preserves-patch ()
  (let* ((text "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1,2 @@ f\n-x\n+y\n+z\n@@ -4,2 +5,0 @@\n-a\n-b\n\\ No newline at end of file\n")
         (parsed (regit-gutter--parse text))
         (hunks (cdr parsed)))
    (should (= (length hunks) 2))
    (should (= (regit-gutter--hunk-old-count (aref hunks 0)) 1))
    (should (= (regit-gutter--hunk-new-count (aref hunks 1)) 0))
    (should (equal text (concat (car parsed)
                               (mapconcat #'regit-gutter--hunk-patch hunks ""))))))

(ert-deftest regit-binary-and-clean-diffs ()
  (should (= 0 (length (cdr (regit-gutter--parse "")))))
  (should (= 0 (length (cdr (regit-gutter--parse "Binary files differ\n"))))))

(ert-deftest regit-async-read-and-navigation ()
  (regit-test--repo "file.txt"
    (should (= 2 (length regit-gutter--hunks)))
    (goto-char (point-min))
    (regit-gutter-next-hunk)
    (should (= (line-number-at-pos) 3))
    (regit-gutter-next-hunk)
    (should (= (line-number-at-pos) 22))
    (regit-gutter-next-hunk)
    (should (= (line-number-at-pos) 3))
    (regit-gutter-previous-hunk)
    (should (= (line-number-at-pos) 22))))

(ert-deftest regit-stage-only-selected-hunk ()
  (regit-test--repo "file.txt"
    (goto-char (point-min)) (regit-gutter-next-hunk)
    (regit-gutter-stage-hunk) (regit-test--wait)
    (should-not regit-gutter--error)
    (should (equal (regit-test--git root "show" ":file.txt") (regit-test--text '(3))))
    (should (= 1 (length regit-gutter--hunks)))
    (should (equal (buffer-string) (regit-test--text '(3 22))))))

(ert-deftest regit-revert-only-selected-hunk ()
  (regit-test--repo "file.txt"
    (goto-char (point-min)) (regit-gutter-next-hunk)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (regit-gutter-revert-hunk))
    (regit-test--wait)
    (should-not regit-gutter--error)
    (should (equal (buffer-string) (regit-test--text '(22))))
    (should (equal (regit-test--git root "show" ":file.txt") (regit-test--text)))))

(ert-deftest regit-unsaved-edits-invalidate ()
  (regit-test--repo "file.txt"
    (goto-char (point-min)) (insert "unsaved\n")
    (should-not regit-gutter--diff)
    (should (= 0 (length regit-gutter--hunks)))
    (should-error (regit-gutter-stage-hunk) :type 'user-error)
    (save-buffer) (regit-test--wait)
    (should (> (length regit-gutter--hunks) 0))))

(ert-deftest regit-stale-index-refuses-stage ()
  (regit-test--repo "file.txt"
    (goto-char (point-min)) (regit-gutter-next-hunk)
    (regit-test--git root "add" "file.txt")
    (regit-gutter-stage-hunk) (regit-test--wait)
    (should (equal (regit-test--git root "show" ":file.txt") (regit-test--text '(3 22))))
    (should (= 0 (length regit-gutter--hunks)))))

(ert-deftest regit-path-is-literal-and-shell-free ()
  (regit-test--repo ":(glob) [x] ; 日本語.txt"
    (should (= 2 (length regit-gutter--hunks)))
    (goto-char (point-min)) (regit-gutter-next-hunk)
    (regit-gutter-stage-hunk) (regit-test--wait)
    (should-not regit-gutter--error)
    (should (= 1 (length regit-gutter--hunks)))))

(ert-deftest regit-newline-filename ()
  (regit-test--repo "odd\nfile.txt"
    (should (= 2 (length regit-gutter--hunks)))
    (goto-char (point-min)) (regit-gutter-next-hunk)
    (regit-gutter-stage-hunk) (regit-test--wait)
    (should-not regit-gutter--error)
    (should (= 1 (length regit-gutter--hunks)))))

(ert-deftest regit-no-final-newline-stage ()
  (regit-test--repo "file.txt"
    (erase-buffer) (insert "replacement without newline")
    (let ((require-final-newline nil)) (save-buffer))
    (regit-test--wait)
    (goto-char (point-min)) (regit-gutter-stage-hunk) (regit-test--wait)
    (should-not regit-gutter--error)
    (should (equal (regit-test--git root "show" ":file.txt")
                   "replacement without newline"))))

(ert-deftest regit-empty-file-deletion ()
  (regit-test--repo "file.txt"
    (erase-buffer) (save-buffer) (regit-test--wait)
    (should (= 1 (length regit-gutter--hunks)))
    (should (regit-gutter--current-hunk))
    (save-window-excursion
      (switch-to-buffer buffer) (regit-gutter--render)
      (should (= 1 (hash-table-count regit-gutter--overlays))))
    (regit-gutter-stage-hunk) (regit-test--wait)
    (should-not regit-gutter--error)
    (should (equal "" (regit-test--git root "show" ":file.txt")))))

(ert-deftest regit-visible-overlays-bounded-and-reused ()
  (regit-test--repo "file.txt"
    (erase-buffer)
    (dotimes (_ 10000) (insert "changed\n"))
    (save-buffer) (regit-test--wait)
    (save-window-excursion
      (switch-to-buffer buffer)
      (goto-char (point-min)) (set-window-start (selected-window) (point-min))
      (let ((end (save-excursion (forward-line 25) (point))))
        (cl-letf (((symbol-function 'window-end) (lambda (&rest _) end)))
          (setq regit-gutter--signature nil)
          (regit-gutter--render)
          (should (> (hash-table-count regit-gutter--overlays) 0))
          (should (<= (hash-table-count regit-gutter--overlays) 34))
          (let ((overlay (gethash (point-min) regit-gutter--overlays)))
            (regit-gutter--render)
            (should (eq overlay (gethash (point-min) regit-gutter--overlays)))))))))

(ert-deftest regit-coalesces-refreshes ()
  (regit-test--repo "file.txt"
    (let ((calls 0) (original (symbol-function 'regit-gutter--spawn)))
      (cl-letf (((symbol-function 'regit-gutter--spawn)
                 (lambda (&rest args) (cl-incf calls) (apply original args))))
        (dotimes (_ 50) (regit-gutter-refresh))
        (regit-test--wait)
        (should (= calls 1))))))

(ert-deftest regit-stale-response-cannot-publish ()
  (regit-test--repo "file.txt"
    (let (callback)
      (cl-letf (((symbol-function 'regit-gutter--spawn)
                 (lambda (_root _args fn &optional _input) (setq callback fn) nil)))
        (regit-gutter--start)
        (goto-char (point-min)) (insert "edit")
        (funcall callback 0 "@@ -1 +1 @@\n-a\n+b\n" "")
        (should-not regit-gutter--diff)))))

(ert-deftest regit-teardown-and-margin-ownership ()
  (regit-test--repo "file.txt"
    (save-window-excursion
      (switch-to-buffer buffer)
      (set-window-margins (selected-window) nil 2)
      (regit-gutter--windows)
      (should (= 1 (car (window-margins))))
      (should (= 2 (cdr (window-margins))))
      (regit-gutter-refresh)
      (regit-gutter-mode -1)
      (should-not (car (window-margins)))
      (should (= 2 (cdr (window-margins))))
      (should-not regit-gutter--timer)
      (should-not regit-gutter--process)
      (should (= 0 (hash-table-count regit-gutter--overlays)))
      (should-not (memq #'regit-gutter--changed after-change-functions)))))

(ert-deftest regit-no-remote-probe ()
  (with-temp-buffer
    (setq buffer-file-name "/ssh:example:/file")
    (cl-letf (((symbol-function 'locate-dominating-file)
               (lambda (&rest _) (ert-fail "Remote filesystem probed"))))
      (regit-gutter-mode 1)
      (should-not regit-gutter-mode))))

(ert-deftest regit-disable-before-callback ()
  (regit-test--repo "file.txt"
    (let (callback)
      (cl-letf (((symbol-function 'regit-gutter--spawn)
                 (lambda (_root _args fn &optional _input) (setq callback fn) nil)))
        (regit-gutter--start)
        (regit-gutter-mode -1)
        (funcall callback 0 "@@ -1 +1 @@\n-a\n+b\n" "")
        (should-not regit-gutter--diff)))))

(ert-deftest regit-insertion-before-first-line ()
  (regit-test--repo "file.txt"
    (erase-buffer) (insert "first\n" (regit-test--text))
    (save-buffer) (regit-test--wait)
    (goto-char (point-min))
    (should (= 0 (regit-gutter--hunk-old-count (regit-gutter--current-hunk))))
    (regit-gutter-stage-hunk) (regit-test--wait)
    (should-not regit-gutter--error)
    (should (equal (regit-test--git root "show" ":file.txt") (buffer-string)))))

(ert-deftest regit-revert-cancel-is-noop ()
  (regit-test--repo "file.txt"
    (goto-char (point-min)) (regit-gutter-next-hunk)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (regit-gutter-revert-hunk))
    (should-not regit-gutter--operation)
    (should (equal (buffer-string) (regit-test--text '(3 22))))))

(ert-deftest regit-edit-during-validation-aborts ()
  (regit-test--repo "file.txt"
    (let (callback (calls 0))
      (goto-char (point-min)) (regit-gutter-next-hunk)
      (let ((snapshot regit-gutter--diff))
        (cl-letf (((symbol-function 'regit-gutter--spawn)
                   (lambda (_root _args fn &optional _input)
                     (cl-incf calls) (setq callback fn) 'pending)))
          (regit-gutter-stage-hunk)
          (insert "unsaved")
          (funcall callback 0 snapshot "")
          (should (= calls 1))
          (should (buffer-modified-p)))))))

(ert-deftest regit-edit-during-revert-is-preserved ()
  (regit-test--repo "file.txt"
    (let (callback (calls 0))
      (goto-char (point-min)) (regit-gutter-next-hunk)
      (let ((snapshot regit-gutter--diff))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'regit-gutter--spawn)
                   (lambda (_root _args fn &optional _input)
                     (cl-incf calls) (setq callback fn) 'pending)))
          (regit-gutter-revert-hunk)
          (funcall callback 0 snapshot "")
          (should (= calls 2))
          (insert "unsaved")
          (funcall callback 0 "" "")
          (should (buffer-modified-p))
          (should (string-match-p "unsaved" (buffer-string))))))))

(ert-deftest regit-multiple-windows-and-narrowing ()
  (regit-test--repo "file.txt"
    (save-window-excursion
      (switch-to-buffer buffer)
      (delete-other-windows)
      (let ((other (split-window-below)))
        (set-window-buffer other buffer)
        (set-window-start (selected-window) (point-min))
        (set-window-start other (save-excursion (goto-char (point-min))
                                               (forward-line 20) (point)))
        (regit-gutter--windows)
        (should (gethash (regit-gutter--hunk-start (aref regit-gutter--hunks 0))
                         regit-gutter--overlays))
        (should (gethash (regit-gutter--hunk-start (aref regit-gutter--hunks 1))
                         regit-gutter--overlays))))
    (save-restriction
      (narrow-to-region (point-min) (save-excursion (goto-char (point-min))
                                                   (forward-line 10) (point)))
      (goto-char (point-min))
      (regit-gutter-next-hunk)
      (regit-gutter-next-hunk)
      (should (= 3 (line-number-at-pos))))))

(ert-deftest regit-major-mode-cleanup ()
  (regit-test--repo "file.txt"
    (fundamental-mode)
    (should-not (memq buffer regit-gutter--buffers))
    (should-not regit-gutter-mode)))

(ert-deftest regit-rename-updates-path ()
  (regit-test--repo "file.txt"
    (let ((new (expand-file-name "renamed.txt" root)))
      (rename-file file new)
      (set-visited-file-name new t)
      (regit-test--wait)
      (should (equal regit-gutter--path "renamed.txt")))))

(ert-deftest regit-git-failure-clears-signs-and-process-buffers ()
  (regit-test--repo "file.txt"
    (let ((regit-gutter-git-executable "false"))
      (regit-gutter-refresh) (regit-test--wait)
      (should-not regit-gutter--diff))
    (should-not (cl-find-if (lambda (b) (string-match-p " \\*regit-\\(output\\|error\\)"
                                                                     (buffer-name b)))
                           (buffer-list)))))

(ert-deftest regit-worktree-git-file ()
  (regit-test--repo "file.txt"
    (let ((worktree (make-temp-file "regit-worktree-" t)) wb)
      (unwind-protect
          (progn
            (regit-test--git root "worktree" "add" "--detach" worktree "HEAD")
            (with-temp-file (expand-file-name "file.txt" worktree)
              (insert (regit-test--text '(3))))
            (setq wb (find-file-noselect (expand-file-name "file.txt" worktree)))
            (with-current-buffer wb
              (regit-gutter-mode 1) (regit-test--wait)
              (should (= 1 (length regit-gutter--hunks)))
              (goto-char (point-min)) (regit-gutter-next-hunk)
              (regit-gutter-stage-hunk) (regit-test--wait)
              (should-not regit-gutter--error)
              (should (= 0 (length regit-gutter--hunks)))))
        (when (buffer-live-p wb) (kill-buffer wb))
        (regit-test--git root "worktree" "remove" "--force" worktree)))))

(ert-deftest regit-process-sentinel-runs-once ()
  (let ((calls 0)
        (default-directory temporary-file-directory)
        process)
    (setq process (regit-gutter--spawn default-directory '("--version")
                                      (lambda (&rest _) (cl-incf calls))))
    (let ((deadline (+ (float-time) 5)))
      (while (and (= calls 0) (< (float-time) deadline))
        (accept-process-output nil 0.01)))
    (should (= calls 1))
    (funcall (process-sentinel process) process "finished\n")
    (should (= calls 1))))

(ert-deftest regit-stale-window-end-is-bounded ()
  (regit-test--repo "file.txt"
    (erase-buffer) (dotimes (_ 10000) (insert "changed\n"))
    (save-buffer) (regit-test--wait)
    (save-window-excursion
      (switch-to-buffer buffer)
      (set-window-start (selected-window) (point-min))
      (cl-letf (((symbol-function 'window-end) (lambda (&rest _) (point-max))))
        (setq regit-gutter--signature nil)
        (regit-gutter--render)
        (should (<= (hash-table-count regit-gutter--overlays)
                    (+ (window-body-height) regit-gutter-prefetch-lines 1)))))))

(ert-deftest regit-stage-after-unstaged-line-offset ()
  (regit-test--repo "file.txt"
    (erase-buffer) (insert "inserted first\n" (regit-test--text '(22)))
    (save-buffer) (regit-test--wait)
    (goto-char (point-min)) (regit-gutter-next-hunk)
    (should (= 23 (line-number-at-pos)))
    (regit-gutter-stage-hunk) (regit-test--wait)
    (should-not regit-gutter--error)
    (should (equal (regit-test--git root "show" ":file.txt")
                   (regit-test--text '(22))))
    (should (= 1 (length regit-gutter--hunks)))))

(ert-deftest regit-intent-to-add ()
  (regit-test--repo "file.txt"
    (let* ((new (expand-file-name "new.txt" root))
           new-buffer)
      (unwind-protect
          (progn
            (with-temp-file new (insert "new file\n"))
            (regit-test--git root "add" "-N" "new.txt")
            (setq new-buffer (find-file-noselect new))
            (with-current-buffer new-buffer
              (regit-gutter-mode 1) (regit-test--wait)
              (should (= 1 (length regit-gutter--hunks)))
              (goto-char (point-min))
              (regit-gutter-stage-hunk) (regit-test--wait)
              (should (equal (regit-test--git root "show" ":new.txt") "new file\n"))))
        (when (buffer-live-p new-buffer) (kill-buffer new-buffer))))))

(ert-deftest regit-discard-intent-to-add ()
  (regit-test--repo "file.txt"
    (regit-test--git root "rm" "--cached" "file.txt")
    (regit-test--git root "add" "-N" "file.txt")
    (regit-gutter-refresh) (regit-test--wait)
    (goto-char (point-min))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (regit-gutter-revert-hunk))
    (regit-test--wait)
    (should-not (file-exists-p file))
    (should (= 0 (buffer-size)))
    (should-not (buffer-modified-p))))

(ert-deftest regit-stage-does-not-stage-unrelated-file-mode ()
  (regit-test--repo "file.txt"
    (regit-test--git root "config" "core.fileMode" "true")
    (set-file-modes file (logior (file-modes file) #o111))
    (regit-gutter-refresh) (regit-test--wait)
    (goto-char (point-min)) (regit-gutter-next-hunk)
    (regit-gutter-stage-hunk) (regit-test--wait)
    (should (string-prefix-p "100644" (regit-test--git root "ls-files" "--stage" "file.txt")))
    (should (string-match-p "new mode 100755" regit-gutter--diff))))

;;; regit-gutter-test.el ends here
