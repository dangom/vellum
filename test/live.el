;;; live.el --- a scratch Emacs for trying Vellum by hand -*- lexical-binding: t; -*-
;; /Applications/Emacs.app/Contents/MacOS/Emacs -Q -l /full/path/to/test/live.el FILE.tex
;; (a graphical Emacs does not start in the shell's directory: give full paths)
(add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name)))
(require 'vellum)
(require 'server)
(setq server-name "vellum-live")
(server-start)
(add-to-list 'auto-mode-alist '("\\.pdf\\'" . vellum-mode))
(setq inhibit-startup-screen t)
(global-set-key (kbd "C-c C-v") #'vellum-forward-search)
