;;; regit-gutter-interactive-smoke.el --- Real display/operation smoke -*- lexical-binding: t; -*-
;; emacs -Q [-nw] -L . -l test/regit-gutter-interactive-smoke.el
(load (expand-file-name "regit-gutter-test.el" (file-name-directory load-file-name))
      nil t)
(require 'json)

(run-with-timer
 0.2 nil
 (lambda ()
   (let ((result (getenv "REGIT_SMOKE_RESULT")))
     (condition-case err
         (progn
           (regit-test--repo "file.txt"
             (switch-to-buffer buffer)
             (delete-other-windows)
             (goto-char (point-min))
             (redisplay t)
             (regit-gutter--windows)
             (should (= 1 (car (window-margins))))
             (should (> (hash-table-count regit-gutter--overlays) 0))
             (regit-gutter-next-hunk)
             (should (= 3 (line-number-at-pos)))
             (regit-gutter-stage-hunk) (regit-test--wait)
             (should (= 1 (length regit-gutter--hunks)))
             (regit-gutter-next-hunk)
             (recenter) (redisplay t)
             (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
               (regit-gutter-revert-hunk))
             (regit-test--wait)
             (should (= 0 (length regit-gutter--hunks)))
             (should (equal (buffer-string) (regit-test--text '(3))))
             (regit-gutter-mode -1)
             (should-not (car (window-margins))))
           (when result
             (with-temp-file result
               (insert (json-encode `((passed . t) (graphic . ,(if (display-graphic-p)
                                                                   t :json-false))
                                      (emacs . ,emacs-version))))))
           (kill-emacs 0))
       (error
        (when result
          (with-temp-file result
            (insert (json-encode `((error . ,(error-message-string err)))))))
        (kill-emacs 1))))))
