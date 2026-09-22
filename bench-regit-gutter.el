;;; bench-regit-gutter.el --- Reproducible workload benchmark -*- lexical-binding: t; -*-
(require 'regit-gutter)
(require 'json)
(require 'benchmark)
(setq native-comp-jit-compilation nil)

(defun regit-bench--git (root &rest args)
  (let ((default-directory root))
    (unless (zerop (apply #'process-file "git" nil nil nil args))
      (error "Git failed: %S" args))))

(defun regit-bench--case (lines &optional sparse)
  (let* ((root (make-temp-file "regit-bench-" t))
         (file (expand-file-name "file.txt" root))
         (vc-handled-backends nil)
         (regit-gutter-delay 0)
         buffer)
    (unwind-protect
        (progn
          (regit-bench--git root "init" "--quiet")
          (with-temp-file file
            (dotimes (i lines) (insert (format "old-%06d\n" i))))
          (regit-bench--git root "add" "file.txt")
          (with-temp-file file
            (dotimes (i lines)
              (insert (format "%s-%06d\n"
                              (if (and sparse (/= (% i 10) 0)) "old" "new") i))))
          (setq buffer (find-file-noselect file))
          (save-window-excursion
            (switch-to-buffer buffer)
            (goto-char (point-min))
            (set-window-start (selected-window) (point-min))
            ;; Batch has no reliable redisplay: explicitly simulate 40 lines.
            (cl-letf (((symbol-function 'window-body-height) (lambda (&rest _) 40))
                      ((symbol-function 'window-end)
                       (lambda (window &optional _update)
                         (save-excursion
                           (goto-char (window-start window))
                           (forward-line 40) (point)))))
              (garbage-collect)
              (let* ((start (float-time))
                     (enable (progn (regit-gutter-mode 1) (- (float-time) start)))
                     (deadline (+ start 30)))
                (while (and (or regit-gutter--timer regit-gutter--process)
                            (< (float-time) deadline))
                  (accept-process-output nil 0.001))
                (when (or regit-gutter--timer regit-gutter--process regit-gutter--error)
                  (error "Diff failed or timed out: %S" regit-gutter--error))
                (let ((ready (- (float-time) start))
                      (overlays (hash-table-count regit-gutter--overlays))
                      (cached (benchmark-run 1000 (regit-gutter--render)))
                      (scroll (benchmark-run 1
                                (dotimes (i 50)
                                  (goto-char (point-min))
                                  (forward-line (* i 10))
                                  (set-window-start (selected-window) (point))
                                  (regit-gutter--render)))))
                  `((lines . ,lines) (sparse . ,(if sparse t :json-false))
                    (hunks . ,(length regit-gutter--hunks))
                    (enable_seconds . ,enable) (diff_ready_seconds . ,ready)
                    (visible_overlays . ,overlays)
                    (cached_render_1000_seconds . ,(car cached))
                    (scroll_50_seconds . ,(car scroll))))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

;; One untimed workload warm-up; this does not measure cold require.
(regit-bench--case 100)
(princ (json-encode `((emacs . ,emacs-version)
                       (git . ,(string-trim (shell-command-to-string "git --version")))
                       (window_lines . 40) (prefetch_lines . ,regit-gutter-prefetch-lines)
                       (runs . ,(vconcat
                                 (cl-loop repeat 3 append
                                          (list (regit-bench--case 1000)
                                                (regit-bench--case 100000)
                                                (regit-bench--case 100000 t))))))))
(terpri)
