;;; vellum.el --- A native PDF view for macOS, with SyncTeX -*- lexical-binding: t; -*-

;; Author: Daniel Gomez
;; Version: 0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: files, tex, multimedia
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Vellum shows a PDF in an Emacs window through a WebKit view laid over it.
;; Scrolling and pinch-zoom are the system's own; the keyboard never leaves
;; Emacs, so the PDF buffer has ordinary keys.
;;
;; A dynamic module (vellum-module.dylib, built with `make') owns the view.
;; The viewer inside it is pdf.js, in web/.  This file is the mode: it keeps
;; the view over its window, speaks to the viewer, and runs SyncTeX.
;;
;;   (add-to-list 'auto-mode-alist '("\\.pdf\\'" . vellum-mode))
;;   (with-eval-after-load 'tex (vellum-auctex-setup))
;;
;; From a TeX buffer, `vellum-forward-search' shows where point is in the
;; PDF.  In the PDF, a double click or a command-click goes to the source.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'filenotify)
(require 'subr-x)
(require 'imenu)

(defgroup vellum nil
  "A native PDF view for macOS, with SyncTeX."
  :group 'files)

(defconst vellum-directory
  (let* ((loaded (or load-file-name buffer-file-name))
         (source (concat (file-name-sans-extension loaded) ".el")))
    ;; A package manager may load a compiled copy from a build directory
    ;; holding only a link to this file; follow it back to the checkout.
    (file-name-directory
     (file-truename (if (file-exists-p source) source loaded))))
  "Where Vellum lives: the module and the viewer are found from here.")

(defcustom vellum-synctex-program "synctex"
  "The SyncTeX command-line tool."
  :type 'string)

(defcustom vellum-default-scale "page-width"
  "The scale a PDF opens at: page-width, page-fit, auto, or a number."
  :type 'string)

(defcustom vellum-places-file (locate-user-emacs-file "vellum-places.eld")
  "Where the place last read in each PDF is remembered."
  :type 'file)

(defcustom vellum-display-buffer-action
  '((display-buffer-reuse-window display-buffer-in-direction)
    (direction . right)
    (window-width . 0.5)
    (inhibit-same-window . t))
  "How `vellum-forward-search' shows a PDF that is not yet on screen."
  :type 'sexp)

(defcustom vellum-pdf-function #'vellum-pdf-for-buffer
  "Function returning the PDF built from the current source buffer."
  :type 'function)

(defvar vellum-after-load-hook nil
  "Run in a PDF's buffer each time the viewer has shown the file anew.")

(defvar-local vellum-pdf-file nil
  "The PDF this source buffer builds, when it can't be guessed.")
(put 'vellum-pdf-file 'safe-local-variable #'stringp)


;;; The module and its channel

(defvar vellum--views (make-hash-table :test #'equal)
  "The live views: id to buffer.")
(defvar vellum--counter 0)
(defvar vellum--channel nil
  "The pipe the viewers write their messages to.")

(defvar-local vellum--id nil)
(defvar-local vellum--ready nil "Non-nil once the viewer page has started.")
(defvar-local vellum--queue nil "JavaScript waiting for the viewer to start.")
(defvar-local vellum--place nil "The viewer's last report of where it is.")
(defvar-local vellum--loaded nil "Non-nil once the PDF has been shown.")
(defvar-local vellum--after-load nil "Functions to call once the PDF is shown.")
(defvar-local vellum--watch nil)
(defvar-local vellum--reload-timer nil)
(defvar-local vellum--retries 0)
(defvar-local vellum--outline nil)
(defvar-local vellum--query nil)

(declare-function vellum-module-create "vellum-module")
(declare-function vellum-module-place "vellum-module")
(declare-function vellum-module-hide "vellum-module")
(declare-function vellum-module-destroy "vellum-module")
(declare-function vellum-module-eval "vellum-module")
(declare-function vellum-module-snapshot "vellum-module")

(defun vellum--module-file ()
  (expand-file-name "vellum-module.dylib" vellum-directory))

(defun vellum--ensure-module ()
  "Load the module, building it first if it has never been built."
  (unless (featurep 'vellum-module)
    (unless (eq window-system 'ns)
      (user-error "Vellum needs a graphical Emacs on macOS"))
    (let ((module (vellum--module-file)))
      (unless (file-exists-p module)
        (message "Vellum: building the module...")
        (let ((default-directory vellum-directory))
          (unless (zerop (call-process "make" nil "*vellum-build*" nil))
            (pop-to-buffer "*vellum-build*")
            (error "Vellum: the module failed to build"))))
      (module-load module))))

(defun vellum--channel ()
  (if (process-live-p vellum--channel)
      vellum--channel
    (setq vellum--channel
          (make-pipe-process :name "vellum"
                             :buffer nil
                             :noquery t
                             :coding 'utf-8
                             :filter #'vellum--filter))))

(defvar vellum--partial "")

(defun vellum--filter (_process output)
  (let* ((lines (split-string (concat vellum--partial output) "\n"))
         (complete (butlast lines)))
    (setq vellum--partial (car (last lines)))
    (dolist (line complete)
      (unless (string-empty-p line)
        (condition-case err
            (let* ((message (json-parse-string line :object-type 'alist
                                               :array-type 'list
                                               :null-object nil
                                               :false-object nil))
                   (buffer (gethash (alist-get 'id message) vellum--views)))
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (vellum--receive (intern (alist-get 'type message)) message))))
          (error (message "Vellum: %s" (error-message-string err))))))))

(defun vellum--js (function &rest args)
  "Call the viewer's FUNCTION with ARGS in the current PDF buffer."
  (let ((script (format "vellum.%s(%s);0" function
                        (mapconcat #'json-encode args ","))))
    (if vellum--ready
        (vellum-module-eval vellum--id script)
      (setq vellum--queue (append vellum--queue (list script))))))


;;; Keeping the view over its window

(defun vellum--window (buffer)
  "The window BUFFER's view belongs over, if any."
  (let ((selected (selected-window)))
    (if (eq (window-buffer selected) buffer)
        selected
      (get-buffer-window buffer 'visible))))

(defun vellum--sync-view (id buffer)
  (let ((window (vellum--window buffer)))
    (if (not (and window (display-graphic-p (window-frame window))))
        (vellum-module-hide id)
      (pcase-let* ((frame (window-frame window))
                   (`(,fl ,ft ,fr ,fb) (frame-edges frame 'outer-edges))
                   (`(,l ,top ,r ,b) (window-body-pixel-edges window)))
        (unless (vellum-module-place id fl ft (- fr fl) (- fb ft)
                                     l top (- r l) (- b top))
          (vellum-module-hide id))))))

(defun vellum--sync-views (&rest _)
  "Put every view over the window showing its buffer; hide the rest."
  (maphash (lambda (id buffer)
             (if (buffer-live-p buffer)
                 (vellum--sync-view id buffer)
               (vellum-module-destroy id)
               (remhash id vellum--views)))
           vellum--views))

(defun vellum--watch-windows ()
  (if (zerop (hash-table-count vellum--views))
      (progn
        (remove-hook 'window-state-change-hook #'vellum--sync-views)
        (remove-hook 'window-size-change-functions #'vellum--sync-views)
        (remove-hook 'enable-theme-functions #'vellum--retheme))
    (add-hook 'window-state-change-hook #'vellum--sync-views)
    (add-hook 'window-size-change-functions #'vellum--sync-views)
    (add-hook 'enable-theme-functions #'vellum--retheme)))


;;; Paper

(defun vellum--blend (a b f)
  "The colour F of the way from colour A to colour B."
  (apply #'format "#%02x%02x%02x"
         (cl-mapcar (lambda (x y) (round (* 255 (+ x (* f (- y x))))))
                    (color-name-to-rgb a) (color-name-to-rgb b))))

(defun vellum--colours ()
  "The page's colours, taken from the faces Emacs is drawing with."
  (let* ((paper (face-background 'default nil t))
         (ink (face-foreground 'default nil t))
         (faded (or (face-foreground 'shadow nil t) ink))
         (rgb (mapcar (lambda (c) (round (* 255 c))) (color-name-to-rgb ink))))
    `((paper . ,(vellum--blend paper paper 0))
      (ink . ,(vellum--blend ink ink 0))
      (faded . ,(vellum--blend faded faded 0))
      (rule . ,(vellum--blend paper ink 0.1))
      (mark . ,(format "rgba(%d,%d,%d,0.14)" (nth 0 rgb) (nth 1 rgb) (nth 2 rgb))))))

(defun vellum--retheme (&rest _)
  (maphash (lambda (_id buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (vellum--js "theme" (vellum--colours)))))
           vellum--views))


;;; Remembering places

(defvar vellum--places nil
  "Hash table of file to the place last read in it, once loaded.")

(defun vellum--places ()
  (or vellum--places
      (setq vellum--places
            (or (ignore-errors
                  (with-temp-buffer
                    (insert-file-contents vellum-places-file)
                    (let ((table (make-hash-table :test #'equal)))
                      (pcase-dolist (`(,file . ,place) (read (current-buffer)))
                        (puthash file place table))
                      table)))
                (make-hash-table :test #'equal)))))

(defun vellum--remember-place ()
  (when (and buffer-file-name vellum--place)
    (puthash buffer-file-name
             (cl-loop for key in '(page top left scale)
                      collect (cons key (alist-get key vellum--place)))
             (vellum--places))))

(defun vellum--save-places ()
  (maphash (lambda (_id buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer (vellum--remember-place))))
           vellum--views)
  (when vellum--places
    (let (alist)
      (maphash (lambda (file place)
                 (when (file-exists-p file) (push (cons file place) alist)))
               vellum--places)
      (with-temp-file vellum-places-file
        (let ((print-length nil) (print-level nil))
          (prin1 alist (current-buffer)))))))


;;; Messages from the viewer

(defun vellum--receive (type message)
  (let-alist message
    (pcase type
      ('ready
       (setq vellum--ready t)
       (let ((queue vellum--queue))
         (setq vellum--queue nil)
         (dolist (script queue)
           (vellum-module-eval vellum--id script))))
      ('loaded
       (setq vellum--loaded t
             vellum--retries 0)
       (vellum--js "outline")
       (let ((pending vellum--after-load))
         (setq vellum--after-load nil)
         (mapc #'funcall pending))
       (run-hooks 'vellum-after-load-hook))
      ('place
       (setq vellum--place message)
       (force-mode-line-update))
      ('failed
       ;; Most often the compiler is still writing the file: look again.
       (when (< vellum--retries 8)
         (cl-incf vellum--retries)
         (vellum--reload-soon 0.4)))
      ('focus
       (let ((window (vellum--window (current-buffer))))
         (when (and window (not (eq window (selected-window)))
                    (not (minibuffer-window-active-p (minibuffer-window))))
           (select-window window))))
      ('inverse (vellum--inverse-search .page .x .y .word))
      ('link (browse-url .url))
      ('outline
       (setq vellum--outline .items
             imenu--index-alist nil))
      ('selection
       (if (string-empty-p .text)
           (message "Nothing is selected in the PDF")
         (kill-new .text)
         (message "Copied: %s" (truncate-string-to-width
                                (string-replace "\n" " " .text) 60 nil nil t))))
      ('find
       (pcase .state
         ("missing" (message "No match for \"%s\"" vellum--query))
         ((or "found" "wrapped" "count")
          (when (and .total (> .total 0))
            (message "\"%s\": %d of %d%s" vellum--query .current .total
                     (if (equal .state "wrapped") " (wrapped)" ""))))))
      ('crashed
       (message "Vellum: the viewer stopped; reopening %s" (buffer-name))
       (vellum--start))
      ('error (message "Vellum: %s %s" .message (or .detail ""))))))


;;; The mode

(defun vellum--start ()
  "Create the view for the current buffer and show its file in it."
  (vellum--ensure-module)
  (when vellum--id
    (vellum-module-destroy vellum--id)
    (remhash vellum--id vellum--views))
  (setq vellum--id (format "v%d" (cl-incf vellum--counter))
        vellum--ready nil
        vellum--loaded nil
        vellum--queue nil)
  (puthash vellum--id (current-buffer) vellum--views)
  (vellum-module-create vellum--id
                        (expand-file-name "web" vellum-directory)
                        "vellum://app/index.html"
                        (vellum--channel))
  (vellum--js "theme" (vellum--colours))
  (vellum--js "load" buffer-file-name
              (or (gethash buffer-file-name (vellum--places))
                  `((page . 1) (top . 0) (scale . ,vellum-default-scale))))
  (vellum--watch-windows)
  (vellum--sync-views))

(defun vellum--stop ()
  (when vellum--id
    (vellum--remember-place)
    (when vellum--watch (file-notify-rm-watch vellum--watch))
    (when vellum--reload-timer (cancel-timer vellum--reload-timer))
    (vellum-module-destroy vellum--id)
    (remhash vellum--id vellum--views)
    (setq vellum--id nil
          vellum--watch nil
          vellum--reload-timer nil)
    (vellum--watch-windows)))

(defun vellum--reload-soon (&optional delay)
  "Show the file again once it has stopped changing."
  (when vellum--reload-timer (cancel-timer vellum--reload-timer))
  (setq vellum--reload-timer
        (run-with-timer (or delay 0.1) nil
                        (lambda (buffer)
                          (when (buffer-live-p buffer)
                            (with-current-buffer buffer
                              (setq vellum--reload-timer nil)
                              (when (and vellum--id (file-exists-p buffer-file-name))
                                (set-visited-file-modtime)
                                (vellum--js "load" buffer-file-name)))))
                        (current-buffer))))

(defun vellum--watch-file ()
  "Reload when the compiler writes the PDF again."
  (let ((buffer (current-buffer))
        (name (file-name-nondirectory buffer-file-name)))
    (setq vellum--watch
          (ignore-errors
            (file-notify-add-watch
             (file-name-directory buffer-file-name) '(change)
             (lambda (event)
               (pcase-let ((`(,_ ,action ,file . ,rest) event))
                 (when (and (buffer-live-p buffer)
                            (memq action '(created changed renamed))
                            (member name (mapcar #'file-name-nondirectory
                                                 (cons file (delq nil rest)))))
                   (with-current-buffer buffer
                     (setq vellum--retries 0)
                     (vellum--reload-soon))))))))))

(defun vellum-revert (&rest _)
  "Show the PDF as it now is on disk, keeping the place."
  (interactive)
  (setq vellum--retries 0)
  (vellum--reload-soon 0))

(defun vellum--mode-line ()
  (if vellum--place
      (let-alist vellum--place
        (format "%d/%d  %d%%" .current .pages (round (* 100 (or .zoom 1)))))
    ""))

(defun vellum-position ()
  "Where the reader is, for a mode or header line: page, pages, zoom."
  (vellum--mode-line))

(defvar-keymap vellum-mode-map
  :doc "Keys for reading a PDF."
  "<remap> <next-line>" #'vellum-scroll-down-line
  "<remap> <previous-line>" #'vellum-scroll-up-line
  "<remap> <scroll-up-command>" #'vellum-scroll-down
  "<remap> <scroll-down-command>" #'vellum-scroll-up
  "<remap> <forward-char>" #'vellum-scroll-right
  "<remap> <backward-char>" #'vellum-scroll-left
  "<remap> <beginning-of-buffer>" #'vellum-first-page
  "<remap> <end-of-buffer>" #'vellum-last-page
  "<remap> <goto-line>" #'vellum-goto-page
  "<remap> <consult-goto-line>" #'vellum-goto-page
  "<remap> <kill-ring-save>" #'vellum-copy
  "<remap> <copy-region-as-kill>" #'vellum-copy
  "<remap> <ns-copy-including-secondary>" #'vellum-copy
  "<remap> <kill-region>" #'vellum-copy
  "<remap> <isearch-forward>" #'vellum-search
  "<remap> <isearch-backward>" #'vellum-search-backward
  "<remap> <keyboard-quit>" #'vellum-quit
  "<remap> <revert-buffer>" #'vellum-revert
  "SPC" #'vellum-scroll-down
  "S-SPC" #'vellum-scroll-up
  "DEL" #'vellum-scroll-up
  "j" #'vellum-scroll-down-line
  "k" #'vellum-scroll-up-line
  "d" #'vellum-scroll-down-half
  "u" #'vellum-scroll-up-half
  "n" #'vellum-next-page
  "p" #'vellum-previous-page
  "<" #'vellum-first-page
  ">" #'vellum-last-page
  "+" #'vellum-zoom-in
  "=" #'vellum-zoom-in
  "-" #'vellum-zoom-out
  "0" #'vellum-fit-width
  "w" #'vellum-fit-width
  "f" #'vellum-fit-page
  "1" #'vellum-actual-size
  "s" #'vellum-search
  "r" #'vellum-search-backward
  "o" #'imenu
  "g" #'vellum-revert)

;;;###autoload
(define-derived-mode vellum-mode special-mode "PDF"
  "Read a PDF in a native view laid over this window.

The view scrolls and zooms by trackpad.  A double click, or a click
with the command key held, goes to the TeX source of that spot.

\\{vellum-mode-map}"
  :interactive nil
  (unless buffer-file-name
    (user-error "Vellum shows PDF files; this buffer has none"))
  ;; The file's bytes are of no use as text: the view reads the file itself.
  (let ((inhibit-read-only t))
    (erase-buffer))
  (set-buffer-modified-p nil)
  (setq buffer-undo-list t
        buffer-read-only t
        cursor-type nil
        truncate-lines t
        mode-line-position '((:eval (vellum--mode-line))))
  (setq-local revert-buffer-function #'vellum-revert
              buffer-stale-function (lambda (&rest _) nil)
              left-margin-width 0
              right-margin-width 0
              imenu-create-index-function #'vellum--imenu-index
              imenu-default-goto-function #'vellum--imenu-goto
              imenu-auto-rescan t)
  (add-hook 'kill-buffer-hook #'vellum--stop nil t)
  (add-hook 'change-major-mode-hook #'vellum--stop nil t)
  (add-hook 'write-contents-functions #'always nil t)
  (add-hook 'kill-emacs-hook #'vellum--save-places)
  (vellum--start)
  (vellum--watch-file))


;;; Commands

(defun vellum-scroll-down-line (&optional n)
  "Move N lines further into the PDF."
  (interactive "p")
  (vellum--js "scroll" "line" (or n 1)))

(defun vellum-scroll-up-line (&optional n)
  "Move N lines back in the PDF."
  (interactive "p")
  (vellum--js "scroll" "line" (- (or n 1))))

(defun vellum-scroll-down (&optional _)
  "Move a screen further into the PDF."
  (interactive)
  (vellum--js "scroll" "screen" 1))

(defun vellum-scroll-up (&optional _)
  "Move a screen back in the PDF."
  (interactive)
  (vellum--js "scroll" "screen" -1))

(defun vellum-scroll-down-half ()
  "Move half a screen further into the PDF."
  (interactive)
  (vellum--js "scroll" "half" 1))

(defun vellum-scroll-up-half ()
  "Move half a screen back in the PDF."
  (interactive)
  (vellum--js "scroll" "half" -1))

(defun vellum-scroll-right (&optional n)
  "Move the view N steps to the right."
  (interactive "p")
  (vellum--js "scroll" "right" (or n 1)))

(defun vellum-scroll-left (&optional n)
  "Move the view N steps to the left."
  (interactive "p")
  (vellum--js "scroll" "left" (or n 1)))

(defun vellum-next-page (&optional n)
  "Go N pages forward."
  (interactive "p")
  (vellum--js "page" (or n 1) t))

(defun vellum-previous-page (&optional n)
  "Go N pages back."
  (interactive "p")
  (vellum--js "page" (- (or n 1)) t))

(defun vellum-first-page ()
  "Go to the start of the PDF."
  (interactive)
  (vellum--js "edge" "start"))

(defun vellum-last-page ()
  "Go to the end of the PDF."
  (interactive)
  (vellum--js "edge" "end"))

(defun vellum-goto-page (page)
  "Go to PAGE."
  (interactive
   (list (or (and current-prefix-arg (prefix-numeric-value current-prefix-arg))
             (read-number (format "Page (1-%s): "
                                  (or (alist-get 'pages vellum--place) "?"))))))
  (vellum--js "page" page))

(defun vellum-zoom-in () "Enlarge the PDF." (interactive) (vellum--js "zoom" "in"))
(defun vellum-zoom-out () "Shrink the PDF." (interactive) (vellum--js "zoom" "out"))
(defun vellum-fit-width () "Fit pages to the window's width." (interactive)
       (vellum--js "zoom" "page-width"))
(defun vellum-fit-page () "Fit a whole page in the window." (interactive)
       (vellum--js "zoom" "page-fit"))
(defun vellum-actual-size () "Show the PDF at its printed size." (interactive)
       (vellum--js "zoom" "1"))

(defun vellum-copy ()
  "Copy the text selected in the PDF."
  (interactive)
  (vellum--js "selection"))

(defun vellum-search (&optional backward)
  "Search the PDF.  Repeat to go to the next match; BACKWARD for the last.
An empty answer searches again for the previous query."
  (interactive)
  (let ((query (if (and vellum--query
                        (memq last-command '(vellum-search vellum-search-backward)))
                   vellum--query
                 (read-string (if vellum--query
                                  (format "Search PDF (default %s): " vellum--query)
                                "Search PDF: ")
                              nil 'vellum-search-history vellum--query))))
    (unless (string-empty-p (or query ""))
      (setq vellum--query query)
      (vellum--js "find" query (and backward t)))))

(defun vellum-search-backward ()
  "Search the PDF backward."
  (interactive)
  (vellum-search t))

(defun vellum-quit ()
  "Clear the search highlights."
  (interactive)
  (vellum--js "findClose")
  (setq this-command 'keyboard-quit)
  (message "Quit"))

(defun vellum--imenu-index ()
  (cl-loop for item in vellum--outline
           collect (cons (concat (make-string (* 2 (alist-get 'depth item)) ?\s)
                                 (alist-get 'title item)
                                 (if-let* ((page (alist-get 'page item)))
                                     (format "  %d" page)
                                   ""))
                         (or (alist-get 'page item) 1))))

(defun vellum--imenu-goto (_name page &rest _)
  (vellum--js "page" page))


;;; SyncTeX

(defun vellum--synctex (&rest args)
  "Run synctex with ARGS and return its output as an alist per record.
Each record starts at a Page or Input line."
  (with-temp-buffer
    (let ((status (apply #'call-process vellum-synctex-program nil t nil args))
          records record)
      (unless (eql status 0)
        (error "SyncTeX failed: %s" (string-trim (buffer-string))))
      (goto-char (point-min))
      (while (re-search-forward "^\\([A-Za-z]+\\):\\(.*\\)$" nil t)
        (let ((key (match-string 1))
              (value (match-string 2)))
          (when (member key '("Page" "Input"))
            (when record (push (nreverse record) records))
            (setq record nil))
          (when (or record (member key '("Page" "Input")))
            (push (cons key value) record))))
      (when record (push (nreverse record) records))
      (nreverse records))))

(defun vellum-synctex-forward (pdf source line &optional column)
  "Where LINE (and COLUMN) of SOURCE landed in PDF, as a list of boxes."
  (let ((default-directory (file-name-directory pdf)))
    (cl-loop for record in (vellum--synctex
                            "view" "-i" (format "%d:%d:%s" line (or column 0) source)
                            "-o" pdf)
             when (assoc "Page" record)
             collect (cl-flet ((n (key) (string-to-number
                                         (or (cdr (assoc key record)) "0"))))
                       `((page . ,(n "Page")) (h . ,(n "h")) (v . ,(n "v"))
                         (W . ,(n "W")) (H . ,(n "H")))))))

(defun vellum-synctex-inverse (pdf page x y)
  "The (FILE LINE COLUMN) that set the point X, Y on PAGE of PDF."
  (let* ((default-directory (file-name-directory pdf))
         (record (car (vellum--synctex
                       "edit" "-o" (format "%d:%.2f:%.2f:%s" page x y pdf)))))
    (when-let* ((input (cdr (assoc "Input" record))))
      (list (expand-file-name input)
            (string-to-number (or (cdr (assoc "Line" record)) "1"))
            (string-to-number (or (cdr (assoc "Column" record)) "-1"))))))

(defun vellum--inverse-search (page x y word)
  (pcase (condition-case err
             (vellum-synctex-inverse buffer-file-name page x y)
           (error (message "%s" (error-message-string err)) nil))
    (`(,file ,line ,column)
     (if (not (file-exists-p file))
         (message "SyncTeX points to %s, which is not there" file)
       (let ((buffer (find-file-noselect file)))
         (pop-to-buffer buffer '((display-buffer-reuse-window
                                  display-buffer-use-some-window)
                                 (inhibit-same-window . t)))
         (push-mark nil t)
         (goto-char (point-min))
         (forward-line (1- line))
         ;; SyncTeX knows the line; the word under the click finds the spot.
         (cond ((and (> column 0)) (move-to-column column))
               ((and word (not (string-empty-p word))
                     (search-forward word (line-end-position 3) t))
                (goto-char (match-beginning 0)))
               (t (back-to-indentation)))
         (when (fboundp 'pulse-momentary-highlight-one-line)
           (pulse-momentary-highlight-one-line)))))
    (_ (message "SyncTeX has no source for that spot"))))

(defun vellum-pdf-for-buffer ()
  "The PDF built from the current buffer.
Honours `vellum-pdf-file', then AUCTeX's master file, then the file's
own name."
  (cond (vellum-pdf-file (expand-file-name vellum-pdf-file))
        ((and (bound-and-true-p TeX-mode-p) (fboundp 'TeX-active-master))
         (expand-file-name (funcall 'TeX-active-master "pdf")
                           (and (fboundp 'TeX-master-directory)
                                (funcall 'TeX-master-directory))))
        (buffer-file-name
         (concat (file-name-sans-extension buffer-file-name) ".pdf"))))

;;;###autoload
(defun vellum-show (pdf)
  "Show PDF beside the current window without leaving it.  Return its buffer."
  (interactive "fPDF: ")
  (let ((buffer (find-file-noselect pdf)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vellum-mode) (vellum-mode)))
    (display-buffer buffer vellum-display-buffer-action)
    buffer))

;;;###autoload
(defun vellum-forward-search ()
  "Show in the PDF the place that point's line was set."
  (interactive)
  (let ((pdf (funcall vellum-pdf-function))
        (source buffer-file-name)
        (line (line-number-at-pos nil t))
        (column (current-column)))
    (unless (and pdf (file-exists-p pdf))
      (user-error "No PDF yet%s" (if pdf (format ": %s" pdf) "")))
    (unless source (user-error "This buffer has no file"))
    (with-current-buffer (vellum-show pdf)
      (let ((jump (lambda ()
                    (if-let* ((boxes (vellum-synctex-forward pdf source line column)))
                        (vellum--js "sync" boxes)
                      (message "SyncTeX has no place for line %d" line)))))
        (if vellum--loaded
            (funcall jump)
          (push jump vellum--after-load))))))


;;; AUCTeX

(defvar TeX-view-program-list)
(defvar TeX-view-program-selection)
(defvar TeX-source-correlate-mode)
(defvar TeX-source-correlate-method)
(defvar TeX-source-correlate-start-server)

;;;###autoload
(defun vellum-auctex-view ()
  "View the current document's PDF in Vellum, at point's line."
  (vellum-forward-search))

;;;###autoload
(defun vellum-auctex-setup ()
  "Make Vellum the viewer AUCTeX uses for PDFs, with SyncTeX on."
  (add-to-list 'TeX-view-program-list '("Vellum" vellum-auctex-view))
  (setf (alist-get 'output-pdf TeX-view-program-selection) '("Vellum"))
  (setq TeX-source-correlate-method 'synctex
        TeX-source-correlate-start-server nil)
  (when (fboundp 'TeX-source-correlate-mode)
    (funcall 'TeX-source-correlate-mode 1)))

(provide 'vellum)
;;; vellum.el ends here
