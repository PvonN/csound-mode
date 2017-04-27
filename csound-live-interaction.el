;;; csound-interaction.el

;; Copyright (C) 2017  Hlöðver Sigurðsson

;; Author: Hlöðver Sigurðsson <hlolli@gmail.com>

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


(require 'comint)
(require 'csound-font-lock)
(require 'csound-opcodes)
(require 'font-lock)

(setq csound-shared-library-loaded?
      (ignore-errors (module-load "emacscsnd.so")))

(defcustom csound-mode--message-buffer-name "*Csound REPL*"
  "Buffer name given to the csound-mode repl."
  :group 'csound-mode
  :type 'constant)


(defun csound-mode--message-buffer-already-exists? ()
  (progn (setq indx 0
	       exists? nil)
	 (while (and (< indx (length (buffer-list)))
		     (not exists?))
	   (if (string-match
		csound-mode--message-buffer-name
		(buffer-name (nth indx (buffer-list))))
	       (setq exists? t)
	     (setq indx (1+ indx))))
	 exists?))

(defun csound-mode--message-buffer-create ()
  (when (not (csound-mode--message-buffer-already-exists?))
    (let ((prev-buffer (buffer-name)))
      (save-excursion
	(generate-new-buffer
	 csound-mode--message-buffer-name)
	(split-window-sensibly)
	(switch-to-buffer-other-window csound-mode--message-buffer-name)
	(with-current-buffer (buffer-name) (funcall 'csound-interactive-mode))
	(switch-to-buffer-other-window prev-buffer)))))

;; (csound-mode--message-buffer-create)

(defun generate-random-uuid ()
  "Insert a random UUID.
Example of a UUID: 1df63142-a513-c850-31a3-535fc3520c3d
WARNING: this is a simple implementation. 
The chance of generating the same UUID is much higher than a robust algorithm.."
  (format "%04x%04x-%04x-%04x-%04x-%06x%06x"
	  (random (expt 16 4))
	  (random (expt 16 4))
	  (random (expt 16 4))
	  (random (expt 16 4))
	  (random (expt 16 4))
	  (random (expt 16 6))
	  (random (expt 16 6))))

(defconst csound-live-interaction-prompt
  (let ((prompt "csnd> ")) 
    (put-text-property 0 (length prompt) 'read-only t prompt)
    prompt))

(defvar csound-live-interaction--input nil)

(defvar csound-live-interaction--input-history (make-hash-table :test 'equal))

(defun csound-live-interaction--input-sender (proc input)
  (unless (eq 0 (length input)) 
    (let ((id (generate-random-uuid))
	  (buffer-read-only nil)
	  (lb (- (line-beginning-position) 5))
	  (return-val (-> input read eval)))
      (comint-output-filter proc (format "%s\n" return-val))
      (push (cons id input) csound-live-interaction--input)
      (message "%s" input)
      (puthash id (process-buffer proc) csound-live-interaction--input-history)))
  (comint-output-filter proc csound-live-interaction-prompt))


(setq csound-interactive--welcome-message
      (let ((s (concat ";; Welcome to Csound interactive message buffer.\n\n")))
	(put-text-property 0 (length s) 'face 'font-lock-comment-face s)
	s))

(defvar csound-interactive-mode-hook nil)

;; https://github.com/jorgenschaefer/comint-scroll-to-bottom

(defun comint-add-scroll-to-bottom ()
  "Activate `comint-scroll-to-bottom'.
This should be put in `comint-mode-hook' or any derived mode."
  (add-hook 'window-scroll-functions 'comint-scroll-to-bottom nil t))


(defun comint-scroll-to-bottom (window display-start)
  "Recenter WINDOW so that point is on the last line.
This is added to `window-scroll-functions' by
`comint-add-scroll-to-bottom'.
The code is shamelessly taken (but adapted) from ERC."
  (let ((proc (get-buffer-process (current-buffer))))
    (when (and proc
               window
               (window-live-p window))
      (let ((resize-mini-windows nil))
        (save-selected-window
          (select-window window)
          (save-restriction
            (widen)
            (when (>= (point) (process-mark proc))
              (save-excursion
                (goto-char (point-max))
                (recenter -1)
                (sit-for 0)))))))))


(defun csound-live-interaction--boot-instance (tty-name)
  (csoundInitialize (logior CSOUNDINIT_NO_ATEXIT
			    CSOUNDINIT_NO_SIGNAL_HANDLER))
  (if (boundp 'csound)
      (progn
	(csoundStop csound)
	(sleep-for 0.1)
      	(csoundReset csound) 
      	(csoundCleanup csound))
    (setq csound (csoundCreate))) 
  (when (boundp 'tty-name)
    (csoundMessageTty csound tty-name))
  (csoundSetOption csound "-odac") 
  ;; TODO make this customizeable or automatic
  (csoundCompileOrc csound "sr=44100\nksmps=32\nnchnls=2\n0dbfs=1")
  ;; (csoundReadScore csound "e 0 3600")
  (csoundInputMessage csound "e 0 3600")
  (csoundStart csound)
  (csoundAsyncPerform csound))

(defmacro csound-live-interaction--restart (tty-name)
  `(if (boundp 'csound)
       (progn
	 (csoundStop csound)
	 (sleep-for 0.1)
	 (csoundReset csound) 
	 (csoundCleanup csound) 
	 (csoundMessageTty csound tty-name)
	 (csoundSetOption csound "-odac")
	 (csoundReadScore csound "e 0 360000")
	 ;; TODO make this customizeable or automatic
	 (csoundCompileOrc csound "sr=44100\nksmps=32\nnchnls=2\n0dbfs=1")
	 (csoundStart csound)
	 (csoundAsyncPerform csound))))

(defun csound--expression ()
  (save-excursion 
    (end-of-line) 
    (let* ((beg (search-backward-regexp "^\\s-*\\<instr\\>\\|^\\s-*\\<opcode\\>" nil t))
	   (end (search-forward-regexp "^\\s-*\\<endin\\>\\|^\\s-*\\<endop\\>" nil t)))
      (if (and beg end)
	  (list beg end)
	(throw 'no-expression
	       "No instrument or opcode expression was found.")))))

(defun csound-live-interaction--newline-seperated-score-block ()
  (let ((beg-block (save-excursion
		     (end-of-line 0)
		     (while (search-backward-regexp
			     "\\(^\\s-*\\|^\\t-*\\)i+[0-9\\\".*]*\\b"
			     (line-beginning-position 1) t 1)
		       (end-of-line 0))
		     (line-beginning-position 2)))
	(end-block (save-excursion
		     (end-of-line 1)
		     (while (search-backward-regexp
			     "\\(^\\s-*\\|^\\t-*\\)i+[0-9\\\".*]*\\b"
			     (line-beginning-position 1) t 1)
		       (end-of-line 2))
		     (line-end-position 0))))
    (list beg-block end-block)))


(defun csound-live-interaction--insert-message (msg)
  (save-current-buffer
    (set-buffer csound-mode--message-buffer-name)
    (goto-char (buffer-size))
    ;; (comint-next-prompt 1)
    ;; (switch-to-prev-buffer)
    (if (prog2 (beginning-of-line)
	    (search-forward csound-live-interaction-prompt nil t 1))
	(progn 
	  (beginning-of-line)
	  (end-of-line 0)
	  (insert (concat "\n" msg )))
      (progn 
	(goto-char (buffer-size))
	(end-of-line 1)
	(insert (concat "\n" msg))))))

(defun csound-live-interaction--errorp (pre-eval-size)
  (save-current-buffer
    (set-buffer csound-mode--message-buffer-name)
    (goto-char pre-eval-size)
    (if (search-forward-regexp "error: " nil t 1)
	t nil)))

(defun csound-live-interaction--flash-region (start end errorp)
  (setq flash-start start
	flash-end end)
  (if errorp
      (hlt-highlight-region flash-start flash-end 'csound-eval-flash-error)
    (hlt-highlight-region flash-start flash-end 'csound-eval-flash))
  (run-with-idle-timer 0.15 nil
		       (lambda ()
			 (hlt-unhighlight-region flash-start flash-end))))

(defun csound-live-interaction-evaluate-region (start end)
  (interactive "r\nP")
  (setq expression-string (buffer-substring start end)
	message-buffer-size (buffer-size
			     (get-buffer csound-mode--message-buffer-name))
	reg-start start reg-end end)
  (csoundCompileOrc csound expression-string)
  (run-with-idle-timer
   0.02 nil
   (lambda ()
     (if (csound-live-interaction--errorp message-buffer-size)
	 (prog2
	     (csound-live-interaction--flash-region reg-start reg-end t)
	     (message "The expression is invalid"))
       (prog2
	   (csound-live-interaction--flash-region reg-start reg-end nil)
	   (csound-live-interaction--insert-message
	    (concat ";; Evaluated: "
		    (buffer-substring reg-start (save-excursion
						  (goto-char reg-start)
						  (line-end-position))))))))))

(defun csound-live-interaction-play-region (start end)
  (interactive "r\nP")
  ;; (message "%s" (buffer-substring start end))
  (setq expression-string (buffer-substring start end)
	message-buffer-size (buffer-size
			     (get-buffer csound-mode--message-buffer-name))
	reg-start start reg-end end)
  (csoundInputMessage csound expression-string)
  (run-with-idle-timer
   0.02 nil
   (lambda ()
     (if (csound-live-interaction--errorp message-buffer-size)
	 (csound-live-interaction--flash-region reg-start reg-end t)
       (csound-live-interaction--flash-region reg-start reg-end nil)))))

(defun csound-evaluate ()
  (interactive)
  (if (save-excursion
	(search-backward-regexp "<CsScore>" nil t 1))
      (if (region-active-p)
	  (prog2
	      (csound-live-interaction-play-region
	       (region-beginning)
	       (region-end))
	      (deactivate-mark))
	(apply 'csound-live-interaction-play-region
	       (csound-live-interaction--newline-seperated-score-block)))
    (if (region-active-p)
	(prog2
	    (csound-live-interaction-evaluate-region
	     (region-beginning)
	     (region-end))
	    (deactivate-mark))
      (apply 'csound-live-interaction-evaluate-region (csound--expression)))))

(defun csound-evaluate-line ()
  (interactive)
  (if (save-excursion
	(search-backward-regexp "<CsScore>" nil t 1))
      (csound-live-interaction-play-region
       (line-beginning-position)
       (line-end-position)) 
    (csound-live-interaction-evaluate-region
     (line-beginning-position)
     (line-end-position))))


(define-derived-mode
  csound-interactive-mode comint-mode "CsoundInteractive"
  "Csound Interactive Message Buffer and REPL."
  :syntax-table csound-mode-syntax-table
  ;;(setq comint-prompt-regexp (concat "^" (regexp-quote elnode-ijs-prompt)))
  (setq comint-input-sender 'csound-live-interaction--input-sender)  
  (unless (comint-check-proc (current-buffer))
    ;; Was cat, but on non-Unix platforms that might not exist, so
    ;; use hexl instead, which is part of the Emacs distribution.
    (let ((csnd-proc (start-process "csnd" (current-buffer) "hexl")))
      (setq csound-live-interaction--process-tty-name
	    (process-tty-name csnd-proc))
      (set-process-query-on-exit-flag csnd-proc nil)
      (setq-local font-lock-defaults '(csound-font-lock-list))
      (insert csound-interactive--welcome-message)
      (set-marker
       (process-mark csnd-proc) (point))
      (comint-output-filter csnd-proc csound-live-interaction-prompt)
      (csound-mode--message-buffer-create)
      (csound-live-interaction--boot-instance
       csound-live-interaction--process-tty-name)))
  (add-hook 'csound-interactive-mode-hook 'comint-add-scroll-to-bottom)
  ;;(add-hook 'csound-interactive-mode-hook (lambda () (csound-mode--message-buffer-create)))
  )

;; (list-processes)
;; (test-csoundAPI)
(defun test-csoundAPI ()
  (csoundInitialize (logior CSOUNDINIT_NO_ATEXIT
			    CSOUNDINIT_NO_SIGNAL_HANDLER))
  (setq csound (csoundCreate)) 
  ;; (csoundMessageTty csound csound-live-interaction--process-tty-name)
  ;; (csoundCreateMessageBuffer csound 0)
  ;; (csound-mode--message-buffer-create)  
  (csoundSetOption csound "-odac")  
  (setq orc "
sr=44100
ksmps=32
nchnls=2
0dbfs=1
instr 1 
aout vco2 0.1, 240
outs aout, aout
endin") ;;(csoundInputMessage)  
  (csoundCompileOrc csound orc)
  ;; (csoundEvalCode csound orc)
  
  (setq sco "i 1 0 1")
  ;; (csoundDestroyMessageBuffer csound)
  (csoundReadScore csound sco)
  ;; (csoundInputMessage csound sco)
  (csoundStart csound)
  ;; (while (eq 0 (csoundPerformKsmps csound)))
  ;; (csoundStop csound)
  ;; (csoundCleanup csound)
  (csoundPerform csound)
  (csoundAsyncPerform csound)
  (csoundReset csound)
  )

;; (defcustom csound-manual-html-directory
;;   (expand-file-name "~/csound/manual/html/")
;;   "Root directory of the csound manual,
;;    download here:
;;    https://github.com/csound/manual"
;;   :group 'csound-mode
;;   :type 'file)

;; (defun csound-thing-at-point-doc ()
;;   (interactive)
;;   (message
;;    (gethash (thing-at-point 'symbol)
;; 	    csdoc-opcode-database)))

;; (async-start
;;  `(lambda ()
;;     (while ,(csoundGetFirstMessage csound)
;;       (print ,(csoundGetFirstMessage csound))
;;       ,(csoundPopFirstMessage csound)))
;;  'ignore)

;; (shell-command-to-string "/bin/echo hello")

;; (csoundGetFirstMessage csound)

(provide 'csound-live-interaction)

;;; csound-interaction.el ends here

