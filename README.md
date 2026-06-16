# svg-margin

[![CI](https://github.com/chiply/svg-margin/actions/workflows/ci.yml/badge.svg)](https://github.com/chiply/svg-margin/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL%203.0-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

Turn the window margins into a flexible, multi-column gutter that many
independent sources ("providers") can draw into, with their indicators packed
side by side on the same line. Supports Emacs 29.1+ (graphical only).

## Overview

Unlike the fringe — which renders only monochrome bitmaps and shows a single
bitmap per line per side — a margin can display arbitrary SVG. svg-margin
composites *every* indicator for a line/side into **one** SVG image at exact
pixel coordinates, on either the left or the right margin:

- **Multi-column packing** — several indicators on the same line stack side by
  side into columns; the margin grows to the widest line.
- **Decoupled providers** — independent packages can each contribute to the
  same gutter without knowing about one another.
- **Any drawing** — built-in shapes (dot, ring, bar, box, triangle), centred
  text/glyphs (e.g. a Nerd Font icon), or a fully custom `:draw` function.
- **Interactive indicators** — per-indicator hover help, a left-click action,
  and a right-click context menu.
- **No jitter** — margin/fringe widths are reserved buffer-locally so switching
  to a buffer doesn't shift its text as indicators render in.

svg-margin is the rendering **engine** only: it ships no providers and no
colours. You (or a small adapter) supply providers.

## Installation

### With elpaca (use-package)

```elisp
(use-package svg-margin
  :ensure (:host github :repo "chiply/svg-margin"))
```

### With straight.el (use-package)

```elisp
(use-package svg-margin
  :straight (:host github :repo "chiply/svg-margin"))
```

### Manual

```elisp
(add-to-list 'load-path "/path/to/svg-margin")
(require 'svg-margin)
```

## Quick start

A **provider** is just a function of one argument BUFFER that returns a list of
indicator plists. Register one, then enable the mode:

```elisp
(svg-margin-register-provider 'todo
  (lambda (_buffer)
    (list (list :line 10 :shape 'dot  :color "#cc3333")
          (list :line 10 :shape 'bar  :color "#3333cc" :column 1)
          (list :line 25 :text "!"    :side 'left :face 'warning))))

(svg-margin-mode 1)            ; or (global-svg-margin-mode 1)
```

Indicators sharing a `(line, side)` are packed into columns and drawn into a
single composite image; the margin width on that side grows to the widest line.

`global-svg-margin-mode` enables the mode in file-visiting buffers by default;
set `svg-margin-global-predicate` to a function of your own to change which
buffers qualify.

## Indicator plists

An indicator plist recognises:

| Key            | Meaning                                                              |
|----------------|---------------------------------------------------------------------|
| `:pos`/`:line` | buffer position or 1-based line (one is required)                    |
| `:side`        | `left` (default `svg-margin-default-side`) or `right`               |
| `:column`      | explicit slot (0 = nearest the text); else auto-packed              |
| `:priority`    | higher is packed first (default 0)                                  |
| `:shape`       | a registered shape symbol (see `svg-margin-define-shape`)           |
| `:text`        | a short string drawn centred (e.g. an icon glyph or mark letter)    |
| `:font`        | font family for `:text` (e.g. a Nerd Font); defaults to `default`  |
| `:scale`       | multiplies the glyph height fraction (raise for icon glyphs)        |
| `:weight`      | font weight for `:text` (default `"bold"`)                          |
| `:draw`        | a function `(SVG X Y W H COLOR)` for full control                   |
| `:color`/`:face` | fill colour, or a face whose foreground is used                  |
| `:help`        | tooltip string (shown when hovering just this indicator)            |
| `:action`      | a command run on left/middle click (also gives a hand pointer)      |
| `:action-help` | a short verb phrase, e.g. `"jump"`; tooltip reads "… click to jump" |
| `:menu`        | an alist of `(LABEL . COMMAND)`; right-click pops up a context menu |

## Built-in shapes

`dot`, `circle` (hollow ring), `bar`, `box`, `triangle`. Register your own with
`svg-margin-define-shape`:

```elisp
(svg-margin-define-shape 'diamond
  (lambda (svg x y w h color)
    (let ((cx (+ x (/ w 2.0))) (cy (+ y (/ h 2.0))) (r (* (min w h) 0.34)))
      (svg-polygon svg (list (cons cx (- cy r)) (cons (+ cx r) cy)
                             (cons cx (+ cy r)) (cons (- cx r) cy))
                   :fill color))))
```

## Per-provider defaults

A provider can set defaults so it need not stamp every indicator, and users can
relocate any provider's margin declaratively (without editing it):

```elisp
(svg-margin-register-provider 'marks #'my-marks-fn :side 'right :priority 5)

;; Move a third-party provider to the other margin, no source edit:
(setq svg-margin-provider-sides '((some-other-provider . right)))
```

## Reclaiming the fringe

To move what a package draws in the fringe into the margin, write a provider
that reads that package's data and set `svg-margin-disable-fringe` to reclaim
the fringe space:

```elisp
;; A provider that mirrors evil's marks into the left margin.
(svg-margin-register-provider 'evil-marks
  (lambda (buffer)
    (with-current-buffer buffer
      (cl-loop for (ch . m) in (bound-and-true-p evil-markers-alist)
               when (markerp m)
               collect (list :pos (marker-position m)
                             :text (char-to-string ch)
                             :side 'left :face 'font-lock-keyword-face))))
  :side 'left)

(setq svg-margin-disable-fringe 'left)   ; reclaim the left fringe
```

## Hover highlight (opt-in)

A margin only delivers mouse enter/leave through the help-echo machinery, so the
hover highlight needs a `show-help-function` hook. The easy way is the global
minor mode — it installs that hook (chaining any existing one) and sets
`svg-margin-hover-highlight`:

```elisp
(svg-margin-hover-mode 1)
```

A `svg-margin-hover-color` background is then drawn behind the indicator under
the mouse. (Clicks and tooltips work regardless of this mode.)

If you already maintain your own `show-help-function` wrapper, call the public
`svg-margin-note-help` from it and set `svg-margin-hover-highlight` yourself
instead of enabling the mode:

```elisp
(setq svg-margin-hover-highlight t)
(let ((orig show-help-function))
  (setq show-help-function
        (lambda (help)
          (svg-margin-note-help help)
          (when orig (funcall orig help)))))
```

## License

GPL-3.0. See [LICENSE](LICENSE).
