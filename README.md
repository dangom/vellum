# Vellum

A native PDF view for Emacs on macOS, made for writing LaTeX.

A PDF opens in an ordinary Emacs window, but what you see there is a WebKit
view laid over it. Scrolling and pinch-zoom are the system's own, with
momentum. The keyboard never leaves Emacs, so the PDF buffer has ordinary
Emacs keys and `C-M-v` scrolls it from the source window.

- **SyncTeX both ways.** `vellum-forward-search` shows where point's line was
  set, with a band that fades. A double click or a command-click in the PDF
  goes to the source, down to the word.
- **Recompiles without a flicker.** When the compiler rewrites the PDF, the
  new one is prepared out of sight and swapped in at the same place and zoom.
- **Search, outline, copy.** `C-s`, `imenu` (the PDF's table of contents), and
  `M-w` on a mouse selection.
- It remembers where you were in each file.

## Requirements

macOS, a graphical Emacs 29 or later built with dynamic modules (no xwidgets
needed), the Xcode Command Line Tools, and `synctex` from TeX Live.

## Install

Clone it, put it on the `load-path`, and:

    (autoload 'vellum-mode "vellum" nil t)
    (add-to-list 'auto-mode-alist '("\\.pdf\\'" . vellum-mode))
    (with-eval-after-load 'tex (vellum-auctex-setup))

The module is built the first time a PDF is opened; `make` builds it by hand.

With straight.el (or Doom's `package!`), the recipe needs nothing beyond the
repository: the module and the viewer are found in the checkout.

    (package! vellum :recipe (:host github :repo "dangom/vellum"))

`vellum-auctex-setup` makes Vellum AUCTeX's PDF viewer, so `C-c C-v` is a
forward search.

## Keys

| Key | |
|---|---|
| `C-n` `C-p` `j` `k` | a line down, up |
| `SPC` `DEL` `C-v` `M-v` | a screen down, up |
| `n` `p` | next, previous page |
| `M-<` `M->` | start, end |
| `M-g g` | go to a page |
| `+` `-` `w` `f` `1` | zoom in, out; fit width; fit page; actual size |
| `C-s` `C-r` | search, and again; `C-g` clears the marks |
| `o` | outline |
| `M-w` | copy the selection |
| `g` | reload |

## How it is put together

- `src/vellum-module.m`: the dynamic module. It owns `WKWebView`s, places them
  over rectangles of an Emacs frame, runs JavaScript in them, and passes their
  messages back through a pipe. It knows nothing about PDFs.
- `web/`: the viewer, which is [pdf.js](https://mozilla.github.io/pdf.js/)
  (vendored in `web/pdfjs`, version in `web/pdfjs/VERSION`) and `vellum.js`.
- `vellum.el`: the mode. It keeps each view over the window showing its
  buffer, talks to the viewer, and runs the `synctex` command-line tool.

## Limits

- One view per buffer: a PDF shown in two windows is drawn in one of them.
- WebKit does not paint a window that is entirely hidden behind others, so a
  PDF loaded in a covered frame appears when the frame is next seen.
- Pages are drawn on white whatever the theme; the space around them takes
  the theme's background.
- Very large documents are pdf.js's weak spot; PDFKit would be faster there.

## Licence

GPL-3.0-or-later. pdf.js is Apache-2.0; see `web/pdfjs/LICENSE`.
