;;; svg-margin.el --- Multi-provider SVG indicators in the window margins -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Charlie Holland

;; Author: Charlie Holland <mister.chiply@gmail.com>
;; Maintainer: Charlie Holland <mister.chiply@gmail.com>
;; URL: https://github.com/chiply/svg-margin
;; x-release-please-start-version
;; Version: 0.1.3
;; x-release-please-end
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, faces, frames

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; svg-margin turns the window margins into a flexible, multi-column gutter
;; that many independent sources ("providers") can draw into, with their
;; indicators packed side by side on the same line.  Unlike the fringe --
;; which renders only monochrome bitmaps and shows a single bitmap per line
;; per side -- a margin can display arbitrary SVG, and svg-margin composites
;; every indicator for a line/side into ONE SVG image at exact pixel
;; coordinates.  Both the left and right margins are supported.
;;
;; This is the rendering ENGINE only.  It ships no providers; you (or a
;; small adapter) supply them.  A provider is just a function of one
;; argument BUFFER that returns a list of indicator plists:
;;
;;   (svg-margin-register-provider 'todo
;;     (lambda (_buffer)
;;       (list (list :line 10 :shape 'dot   :color "#cc3333")
;;             (list :line 10 :shape 'bar   :color "#3333cc" :column 1)
;;             (list :line 25 :text "a"     :side 'left :face 'warning))))
;;   (svg-margin-mode 1)
;;
;; An indicator plist recognises:
;;   :pos / :line  buffer position or 1-based line (one is required)
;;   :side         `left' (default `svg-margin-default-side') or `right'
;;   :column       explicit slot (0 = nearest the text); else auto-packed
;;   :priority     higher is packed first (default 0)
;;   :shape        a registered shape symbol (see `svg-margin-define-shape')
;;   :text         a short string drawn centred (e.g. an evil mark letter)
;;   :draw         a function (SVG X Y W H COLOR) for full control
;;   :color/:face  fill colour, or a face whose foreground is used
;;   :help         tooltip string (shown when hovering just this indicator)
;;   :action       a command (symbol or interactive lambda) run when the
;;                 indicator is left/middle-clicked; also gives it a hand pointer.
;;   :action-help  a short verb phrase for the click, e.g. \"jump\"; the hover
;;                 tooltip then reads \"...  click to jump\".
;;   :menu         an alist of (LABEL . COMMAND); right-click (mouse-3) pops up
;;                 a context menu of these and runs the chosen command.
;;   :background   non-nil makes this a BACKGROUND indicator: it claims no
;;                 column and is drawn first, spanning the side's full
;;                 reserved width behind the packed cells (e.g. a scrollbar
;;                 thumb or a line tint).  Drawn as a filled rectangle of
;;                 :color/:face, or via :draw called as (FN SVG 0 0 W H
;;                 COLOR) with W the full image width.  It contributes no
;;                 width of its own, so the side needs width from regular
;;                 indicators or `svg-margin-min-*-columns' to be visible;
;;                 :action/:menu are not supported on backgrounds.
;;   :opacity      fill opacity 0.0-1.0 for the default background rectangle.
;;
;; Indicators sharing a (line, side) are packed into columns and drawn into
;; a single composite SVG; the margin width on that side grows to the widest
;; line.  Providers are decoupled, so several packages can contribute to the
;; same gutter and stack on one line.
;;
;; A provider may set per-provider defaults so it need not stamp every
;; indicator: (svg-margin-register-provider NAME FN :side 'right :priority 5).
;; Users can relocate any provider's margin declaratively, without editing it,
;; via `svg-margin-provider-sides'.
;;
;; To move what a package draws in the fringe into the margin instead, write
;; a provider that reads that package's data (e.g. evil's `evil-markers-alist')
;; and set `svg-margin-disable-fringe' to reclaim the fringe space.  See the
;; README for worked provider examples.

;;; Code:

(require 'svg)
(require 'cl-lib)
(require 'color)
(require 'subr-x)

(defgroup svg-margin nil
  "Multi-provider SVG indicators in the window margins."
  :group 'convenience
  :prefix "svg-margin-")

(defcustom svg-margin-column-width 1
  "Width of one indicator column, in character cells.
The reserved margin width (in columns, as `set-window-margins' measures it)
is this value times the number of indicator columns on the widest line."
  :type 'integer)

(defcustom svg-margin-default-side 'left
  "Default margin side for indicators that do not specify `:side'."
  :type '(choice (const left) (const right)))

(defcustom svg-margin-min-left-columns 0
  "Minimum number of columns to always reserve in the left margin.
The left margin still grows past this when a line needs more columns, but
never shrinks below it -- so reserving a baseline keeps buffer text from
shifting left/right as indicators come and go (up to this width)."
  :type 'integer)

(defcustom svg-margin-min-right-columns 0
  "Minimum number of columns to always reserve in the right margin.
See `svg-margin-min-left-columns'."
  :type 'integer)

(defcustom svg-margin-disable-fringe nil
  "Which window fringe(s) svg-margin collapses to 0 while active.
nil leaves the fringe alone; `left', `right', `both' (or t) zero the
named fringe(s) so the margin reclaims the space.  Restored on mode exit.
Note: zeroing a fringe also hides its truncation/continuation arrows."
  :type '(choice (const :tag "Leave fringe alone" nil)
                 (const left) (const right)
                 (const :tag "Both" both) (const :tag "Both (t)" t)))

(defcustom svg-margin-idle-delay 0.1
  "Idle seconds to coalesce changes before re-rendering a buffer."
  :type 'number)

(defcustom svg-margin-provider-sides nil
  "Alist of (PROVIDER-NAME . SIDE) overriding where a provider draws.
SIDE is `left' or `right'.  An entry here forces every indicator from that
provider onto SIDE, even one that stamps its own `:side' -- so you can move
any provider (including a third-party one) to the other margin declaratively,
without editing its source.  See also the `:side' argument to
`svg-margin-register-provider'."
  :type '(alist :key-type symbol :value-type (choice (const left) (const right))))

(defcustom svg-margin-debug nil
  "When non-nil, report indicators that are dropped for lack of a position.
A provider whose indicator has no `:pos'/`:line' (or an out-of-range one) has
that indicator silently skipped; enable this to get a message naming the
provider, which helps when writing one."
  :type 'boolean)

(defface svg-margin-help '((t :inherit highlight))
  "Face for an indicator's hover help (its `help-echo').
With tooltips off the help shows in the echo area, where this contrasting
background makes the cue stand out; the face is carried into the echo area,
so it works there as well as in a tooltip.")

(defface svg-margin-cell
  '((t :inherit default :overline nil :underline nil :box nil
       :strike-through nil :extend nil))
  "Face for svg-margin's margin cell (the overlay string carrying the image).
It inherits `default' but explicitly clears the line decorations so a heading
or line face -- e.g. an `:overline' on `org-level-N' -- does not bleed across
the margin.  This is why it is applied to every margin string, not just org's.")

(defcustom svg-margin-help-face 'svg-margin-help
  "Face applied to the indicator hover help, or nil to leave it unstyled."
  :type '(choice (const :tag "No face" nil) face))

(defcustom svg-margin-hover-highlight nil
  "When non-nil, draw a background behind the indicator under the mouse.
This needs `show-help-function' wired to call `svg-margin--note-help' (the
package cannot change that global on its own -- see the README), since
the mouse-enter/leave signal comes through the help-echo machinery."
  :type 'boolean)

(defcustom svg-margin-hover-color nil
  "Background colour drawn behind the hovered indicator.
nil uses the `highlight' face background."
  :type '(choice (const :tag "highlight face" nil) color))

(defvar svg-margin--hovered nil
  "The cell under the mouse as (BUFFER POS SIDE COLUMN), or nil.
Set by `svg-margin--note-help' from the help-echo of the indicator the mouse
is over; consumed by the renderer to draw `svg-margin-hover-color' behind it.")

;;;; Colour
;; ----------------------------------------------------------------

(defun svg-margin--color (c)
  "Normalise colour C to a 6-digit \"#RRGGBB\" string for SVG, else nil.
Names and the 12-digit \"#RRRRGGGGBBBB\" form are resolved via `color.el';
6-digit hex passes through; nil returns nil."
  (cond
   ((null c) nil)
   ((not (stringp c)) c)
   ((string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" c) c)
   (t (let ((rgb (ignore-errors (color-name-to-rgb c))))
        (if rgb (apply #'color-rgb-to-hex (append rgb '(2))) c)))))

;;;; Shape registry
;; ----------------------------------------------------------------
;; The SVG analogue of `define-fringe-bitmap': a named drawing function
;; (SVG X Y W H COLOR) that fills the cell rectangle [X,X+W] x [Y,Y+H].

(defvar svg-margin--shapes (make-hash-table :test 'eq)
  "Map of shape NAME symbol -> drawing function (SVG X Y W H COLOR).")

;;;###autoload
(defun svg-margin-define-shape (name fn)
  "Register drawing FN under shape NAME (a symbol).
FN is called as (FN SVG X Y W H COLOR) and should draw within the cell
rectangle whose top-left is (X, Y) and size is W by H pixels."
  (puthash name fn svg-margin--shapes))

(defun svg-margin--shape-dot (svg x y w h color)
  "Draw a filled dot of COLOR centred in the (X Y W H) cell of SVG."
  (svg-circle svg (+ x (/ w 2.0)) (+ y (/ h 2.0)) (* (min w h) 0.30)
              :fill (svg-margin--color color)))

(defun svg-margin--shape-circle (svg x y w h color)
  "Draw a hollow ring of COLOR centred in the (X Y W H) cell of SVG."
  (let ((c (svg-margin--color color)))
    (svg-circle svg (+ x (/ w 2.0)) (+ y (/ h 2.0)) (* (min w h) 0.30)
                :fill "none" :stroke c :stroke-width (max 1 (round (* (min w h) 0.12))))))

(defun svg-margin--shape-bar (svg x y w h color)
  "Draw a vertical bar of COLOR spanning the height of the (X Y W H) cell of SVG."
  (svg-rectangle svg (+ x (round (* w 0.12))) y (max 2 (round (* w 0.34))) h
                 :rx 1 :fill (svg-margin--color color)))

(defun svg-margin--shape-box (svg x y w h color)
  "Draw a rounded filled box of COLOR centred in the (X Y W H) cell of SVG."
  (let ((s (* (min w h) 0.6)))
    (svg-rectangle svg (+ x (/ (- w s) 2.0)) (+ y (/ (- h s) 2.0)) s s
                   :rx 2 :fill (svg-margin--color color))))

(defun svg-margin--shape-triangle (svg x y w h color)
  "Draw a right-pointing triangle of COLOR centred in the (X Y W H) cell of SVG."
  (let* ((cx (+ x (/ w 2.0))) (cy (+ y (/ h 2.0))) (r (* (min w h) 0.34)))
    (svg-polygon svg (list (cons (- cx r) (- cy r))
                           (cons (+ cx r) cy)
                           (cons (- cx r) (+ cy r)))
                 :fill (svg-margin--color color))))

(dolist (s '((dot . svg-margin--shape-dot)
             (circle . svg-margin--shape-circle)
             (bar . svg-margin--shape-bar)
             (box . svg-margin--shape-box)
             (triangle . svg-margin--shape-triangle)))
  (svg-margin-define-shape (car s) (cdr s)))

;;;; Providers
;; ----------------------------------------------------------------

(defvar svg-margin--providers nil
  "Alist of (NAME . PLIST); PLIST has :fn and optional :side/:priority/:column.
The optional values are per-provider DEFAULTS applied to any indicator that
omits the corresponding key (see `svg-margin--apply-provider-defaults').")

;;;###autoload
(cl-defun svg-margin-register-provider (name fn &key side priority column)
  "Register provider FN under NAME (a symbol), replacing any prior one.
FN is called with one argument, the buffer, and returns a list of indicator
plists (see Commentary).  The optional keywords set per-provider DEFAULTS:
SIDE (`left'/`right'), PRIORITY, and COLUMN are applied to any indicator this
provider emits that does not specify them itself, so a provider need not stamp
every indicator.  `svg-margin-provider-sides' can override SIDE per provider.
Registered buffers are re-rendered."
  (setf (alist-get name svg-margin--providers)
        (list :fn fn :side side :priority priority :column column))
  (svg-margin-refresh-all))

;;;###autoload
(defun svg-margin-unregister-provider (name)
  "Remove the provider registered under NAME and re-render."
  (setq svg-margin--providers (assq-delete-all name svg-margin--providers))
  (svg-margin-refresh-all))

(defun svg-margin--apply-provider-defaults (ind props override-side)
  "Fill IND's missing :side/:priority/:column from provider PROPS.
OVERRIDE-SIDE, when non-nil, forces `:side' regardless of what IND carries."
  (let ((ind (copy-sequence ind)))
    (when (and (plist-get props :side) (not (plist-member ind :side)))
      (setq ind (plist-put ind :side (plist-get props :side))))
    (when (and (plist-get props :priority) (not (plist-member ind :priority)))
      (setq ind (plist-put ind :priority (plist-get props :priority))))
    (when (and (plist-get props :column) (not (plist-member ind :column)))
      (setq ind (plist-put ind :column (plist-get props :column))))
    (when override-side
      (setq ind (plist-put ind :side override-side)))
    ind))

;;;; Collection, normalisation, grouping
;; ----------------------------------------------------------------

(defun svg-margin--normalize (ind)
  "Return a normalised copy of indicator IND, or nil if it has no position.
The result carries a `:pos' at beginning-of-line and a `:side' of `left'
or `right'.  `:line' and `:pos' are resolved against the WHOLE buffer (the
position math widens), so line numbers are absolute regardless of narrowing."
  (save-restriction
    (widen)
    (let* ((pos (or (plist-get ind :pos)
                    (and (plist-get ind :line)
                         (save-excursion
                           (goto-char (point-min))
                           (forward-line (1- (plist-get ind :line)))
                           (point)))))
           (side (or (plist-get ind :side) svg-margin-default-side)))
      (when (and pos (<= (point-min) pos (point-max)))
        (let ((bol (save-excursion (goto-char pos) (line-beginning-position))))
          (append (list :pos bol :side (if (memq side '(right right-margin)) 'right 'left))
                  ind))))))

(defun svg-margin--collect ()
  "Run every provider against the current buffer and return all indicators.
Per-provider defaults and `svg-margin-provider-sides' overrides are applied,
and (when `svg-margin-debug') position-less indicators are reported."
  (let ((buf (current-buffer)) (out nil))
    (dolist (p svg-margin--providers)
      (let* ((name (car p)) (props (cdr p)) (fn (plist-get props :fn))
             (override (alist-get name svg-margin-provider-sides)))
        (condition-case err
            (dolist (ind (funcall fn buf))
              (let* ((ind (svg-margin--apply-provider-defaults ind props override))
                     (n (svg-margin--normalize ind)))
                (if n
                    (push n out)
                  (when svg-margin-debug
                    (message "svg-margin: provider %s dropped an indicator (no/out-of-range :pos/:line): %S"
                             name ind)))))
          (error (message "svg-margin: provider %s failed: %s"
                          name (error-message-string err))))))
    out))

(defun svg-margin--group (indicators)
  "Group INDICATORS into a hash keyed by (POS . SIDE) -> list of indicators."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (ind indicators)
      (push ind (gethash (cons (plist-get ind :pos) (plist-get ind :side)) h)))
    h))

(defun svg-margin--pack-columns (indicators)
  "Assign each of INDICATORS a column, packing them side by side.
Higher `:priority' is placed first.  An explicit free `:column' is
honoured; otherwise the lowest unoccupied column is used.  A `:background'
indicator is not packed: its cell carries a nil `:column' -- it claims no
slot and is drawn behind the packed cells, spanning the full image width.
Returns a list of (:indicator IND :column N-or-nil)."
  (let ((sorted (sort (copy-sequence indicators)
                      (lambda (a b) (> (or (plist-get a :priority) 0)
                                       (or (plist-get b :priority) 0)))))
        (used nil) (result nil))
    (dolist (ind sorted)
      (if (plist-get ind :background)
          (push (list :indicator ind :column nil) result)
        (let ((col (plist-get ind :column)))
          (when (or (null col) (memq col used))
            (setq col 0)
            (while (memq col used) (setq col (1+ col))))
          (push col used)
          (push (list :indicator ind :column col) result))))
    (nreverse result)))

(defun svg-margin--max-column (packed)
  "Return the number of columns occupied by PACKED (max column + 1).
A background cell (nil `:column') occupies no column."
  (1+ (apply #'max -1 (mapcar (lambda (c) (or (plist-get c :column) -1))
                              packed))))

;;;; Drawing
;; ----------------------------------------------------------------

(defun svg-margin--indicator-color (ind)
  "Return the fill colour for indicator IND from `:color' or `:face'."
  (or (plist-get ind :color)
      (let ((f (plist-get ind :face)))
        (and f (face-foreground f nil 'default)))
      (face-foreground 'default nil 'default)
      "#000000"))

(defun svg-margin--draw-text (svg text x y w h color &optional font scale)
  "Draw TEXT centred in the (X Y W H) cell of SVG in COLOR.
FONT overrides the font family (e.g. a Nerd Font for an icon glyph; defaults to
the `default' face family).  SCALE multiplies the glyph height fraction (default
0.7) -- raise it for icon glyphs whose ink is smaller than their em box."
  (let ((fs (max 6 (round (* h 0.7 (or scale 1.0))))))
    (svg-text svg text
              :x (+ x (/ w 2.0))
              :y (+ y (/ h 2.0) (* fs 0.35))
              :font-size fs
              :font-family (or font (face-attribute 'default :family nil t))
              :font-weight "bold"
              :text-anchor "middle"
              :fill (svg-margin--color color))))

(defun svg-margin--draw (ind svg x y w h)
  "Draw indicator IND into the (X Y W H) cell of SVG.
A non-function `:draw' is ignored (falls through to `:text'/`:shape')."
  (let ((color (svg-margin--indicator-color ind)))
    (cond
     ((functionp (plist-get ind :draw)) (funcall (plist-get ind :draw) svg x y w h color))
     ((plist-get ind :text)
      (svg-margin--draw-text svg (plist-get ind :text) x y w h color
                             (plist-get ind :font) (plist-get ind :scale)))
     ((gethash (plist-get ind :shape) svg-margin--shapes)
      (funcall (gethash (plist-get ind :shape) svg-margin--shapes) svg x y w h color))
     (t (svg-margin--shape-dot svg x y w h color)))))

(defun svg-margin--hover-color ()
  "Return the background colour for the hovered indicator."
  (svg-margin--color (or svg-margin-hover-color
                         (face-background 'highlight nil 'default)
                         "#444466")))

(defun svg-margin--image (packed pos side rcols cw lh hovered-col)
  "Build the composite margin image for PACKED cells on SIDE.
POS is the line's buffer position (for tagging each hot-spot's help with its
cell identity).  RCOLS is the SIDE's reserved column count (>= this line's own
column count), so the image fills the whole margin and column 0 lands nearest
the buffer text (rightmost on the left margin, leftmost on the right).  CW is
one column's pixel width and LH the line height (both passed in so they track
the displaying window's frame, not just the selected one).  When HOVERED-COL is
the column of a cell, a `svg-margin-hover-color' background is drawn behind it.
A cell whose draw signals is skipped so one bad indicator cannot blank the line."
  (let* ((h (max 1 lh))
         (w (max 1 (* rcols cw)))
         (svg (svg-create w h))
         (map nil))
    ;; Background cells first (nil column): full-width, behind everything.
    (dolist (cell packed)
      (let ((ind (plist-get cell :indicator)))
        (when (null (plist-get cell :column))
          (condition-case err
              (let ((color (svg-margin--indicator-color ind)))
                (if (functionp (plist-get ind :draw))
                    (funcall (plist-get ind :draw) svg 0 0 w h color)
                  (svg-rectangle svg 0 0 w h
                                 :fill (svg-margin--color color)
                                 :fill-opacity (or (plist-get ind :opacity) 1.0))))
            (error (message "svg-margin: drawing a background failed: %s"
                            (error-message-string err)))))))
    (dolist (cell packed)
      (let* ((col (plist-get cell :column))
             (ind (plist-get cell :indicator)))
        (when col
          (let ((x (if (eq side 'left) (* (- rcols 1 col) cw) (* col cw))))
            ;; Hover background (drawn first, behind the indicator).
            (when (and hovered-col (eql col hovered-col))
              (svg-rectangle svg x 0 cw h :fill (svg-margin--hover-color)))
            (condition-case err
                (svg-margin--draw ind svg x 0 cw h)
              (error (message "svg-margin: drawing an indicator failed: %s"
                              (error-message-string err))))
            ;; Per-cell image-map hot-spot: own help-echo (tagged with the cell
            ;; identity for hover tracking), hand pointer, and the click keymap.
            (let ((area (svg-margin--cell-area ind x cw h pos side col)))
              (when area (push area map)))))))
    (let ((props (list :ascent 'center :scale 1.0)))
      (when map (setq props (append props (list :map (nreverse map)))))
      (apply #'svg-image svg props))))

(defun svg-margin--area-help (ind)
  "Compose IND's hover tooltip: its `:help', the click action, and a menu hint."
  (let ((parts (delq nil
                     (list (plist-get ind :help)
                           (and (plist-get ind :action) (plist-get ind :action-help)
                                (concat "click to " (plist-get ind :action-help)))
                           (and (plist-get ind :menu) "right-click for menu")))))
    (and parts (string-join parts "  ·  "))))

(defun svg-margin--cell-area (ind x cw h pos side col)
  "Return an image map hot-spot for IND drawn at X (width CW, height H).
POS, SIDE and COL identify the cell; its `help-echo' is tagged with
\(BUFFER POS SIDE COL) in the `svg-margin-cell' text property so that
`show-help-function' (via `svg-margin--note-help') can track the hovered
indicator.  Returns nil unless IND has a `:help' or an `:action'; carries the
composed help and a hand `pointer' when clickable.  The click itself is
dispatched by the overlay keymap, not here -- in a margin the area keymap is
not consulted (the area id becomes an event prefix)."
  (let ((action (or (plist-get ind :action) (plist-get ind :menu)))
        (eh (svg-margin--area-help ind))
        (props nil))
    (when action (setq props (list 'pointer 'hand)))
    (when (and eh (> (length eh) 0))
      ;; Face the per-area help too (not just the string-level help in
      ;; `svg-margin--place'): a margin honours image-map area help-echo when
      ;; the pointer is directly over the indicator, and that path would
      ;; otherwise show the help without the contrasting background.
      (setq eh (copy-sequence eh))
      (when svg-margin-help-face (put-text-property 0 (length eh) 'face svg-margin-help-face eh))
      (put-text-property 0 (length eh) 'svg-margin-cell (list (current-buffer) pos side col) eh)
      (setq props (append props (list 'help-echo eh))))
    (when props
      ;; A GLOBALLY-unique area id (per pos/side/col).  If two hot-spots in
      ;; different line images shared an id (e.g. same-type indicators sit in
      ;; the same column), Emacs's mouse-highlight would treat them as one and
      ;; not re-fire help-echo when moving between them -- breaking hover
      ;; tracking.  Uninterned so it does not accumulate in the obarray.
      (list (cons 'rect (cons (cons x 0) (cons (+ x cw) h)))
            (make-symbol (format "svg-margin-area-%d-%s-%d" pos side col))
            props))))

;;;; Overlays
;; ----------------------------------------------------------------

(defvar-local svg-margin--overlays nil
  "List of overlays this buffer uses to carry margin images.")

(defun svg-margin--clear ()
  "Delete all svg-margin overlays in the current buffer.
Deletes by the overlay's `svg-margin' property over the WIDENED buffer, not
by walking `svg-margin--overlays': that list is a plain buffer-local, so
`kill-all-local-variables' (a major-mode change, `revert-buffer', ...) wipes
it while the overlays themselves survive -- and a list-based clear would
leave those orphans showing a stale image beside every fresh one (invisible
while the sizes match, but obvious once `text-scale-mode' makes them
diverge)."
  (save-restriction
    (widen)
    (remove-overlays (point-min) (point-max) 'svg-margin t))
  (setq svg-margin--overlays nil))

(defun svg-margin--click-column (posn side rcols cw)
  "Return the indicator column clicked at POSN, given SIDE, RCOLS and CW.
Uses the click's pixel x within the image; column 0 is nearest the text."
  (let* ((xy (posn-object-x-y posn))
         (x (and xy (car xy))))
    (when (and x (> cw 0))
      (let ((raw (/ x cw)))
        (if (eq side 'left) (- rcols 1 raw) raw)))))

(defun svg-margin--popup-menu (title items)
  "Pop up a menu of ITEMS at the current event and run the chosen command.
ITEMS is an alist of (LABEL . COMMAND); TITLE labels the menu."
  (let ((choice (x-popup-menu last-input-event
                              (list (or title "svg-margin")
                                    (cons "" items)))))
    (when choice
      (if (commandp choice) (call-interactively choice) (funcall choice)))))

(defun svg-margin--make-click-map (clickables side rcols cw)
  "Build a keymap dispatching a margin click to one of CLICKABLES.
CLICKABLES is an alist of (COLUMN . INDICATOR).  Left/middle click runs the
indicator's `:action'; right click (`down-mouse-3') pops up a menu of its
`:menu' items.  SIDE, RCOLS and CW locate the clicked column.  A default
\(catch-all) binding absorbs the image map area-id prefix that a margin click
prepends; the click position then selects the indicator."
  (let* ((at (lambda ()
               (let ((col (svg-margin--click-column
                           (event-start last-input-event) side rcols cw)))
                 (and col (cdr (assq col clickables))))))
         (run (lambda ()
                (interactive)
                (let* ((ind (funcall at)) (cmd (and ind (plist-get ind :action))))
                  (when cmd (call-interactively cmd)))))
         (menu (lambda ()
                 (interactive)
                 (let* ((ind (funcall at)) (items (and ind (plist-get ind :menu))))
                   (when items (svg-margin--popup-menu (plist-get ind :help) items)))))
         (sub (make-sparse-keymap))
         (km (make-sparse-keymap)))
    (define-key sub [mouse-1] run)
    (define-key sub [mouse-2] run)
    (define-key sub [down-mouse-3] menu)
    (define-key sub [down-mouse-1] #'ignore)
    (define-key sub [down-mouse-2] #'ignore)
    (define-key sub [mouse-3] #'ignore)
    (define-key km [t] sub)
    km))

(defun svg-margin--place (pos side packed rcols cw lh)
  "Create an overlay at POS carrying the composite SIDE image for PACKED.
RCOLS is the SIDE's reserved column count the image spans; CW and LH are the
column pixel width and line height for the image."
  (let* ((hovered-col (and svg-margin-hover-highlight svg-margin--hovered
                           (eq (nth 0 svg-margin--hovered) (current-buffer))
                           (eql (nth 1 svg-margin--hovered) pos)
                           (eq (nth 2 svg-margin--hovered) side)
                           (nth 3 svg-margin--hovered)))
         (img (svg-margin--image packed pos side rcols cw lh hovered-col))
         (marg (if (eq side 'left) 'left-margin 'right-margin))
         ;; Compose the line's tooltip from each indicator's full hint (label +
         ;; "click to ..." + menu).  Done at the STRING level because a margin
         ;; honours the string `help-echo' but not image-map area properties.
         (help (string-join
                (delq nil (mapcar (lambda (c) (svg-margin--area-help (plist-get c :indicator)))
                                  packed))
                "\n"))
         ;; Put the image descriptor DIRECTLY as the margin spec's element;
         ;; wrapping it in a string (((margin SIDE) STRING)) reserves the
         ;; margin space but does not render the nested image.
         ;; Face neutralises line decorations (overline/underline/box/...) so a
         ;; heading or line face does not bleed across the margin (see
         ;; `svg-margin-cell').
         (str (propertize " " 'display (list (list 'margin marg) img)
                          'face 'svg-margin-cell))
         ;; (COLUMN . INDICATOR) for indicators that are clickable (left-click
         ;; `:action' and/or right-click `:menu').
         (clickables (delq nil (mapcar (lambda (c)
                                         (let ((ind (plist-get c :indicator)))
                                           (and (or (plist-get ind :action)
                                                    (plist-get ind :menu))
                                                (cons (plist-get c :column) ind))))
                                       packed)))
         (ov (make-overlay pos pos)))
    (when (> (length help) 0)
      (when svg-margin-help-face
        (setq help (propertize help 'face svg-margin-help-face)))
      (setq str (propertize str 'help-echo help)))
    ;; A margin click on an image-map area arrives as [AREA-ID mouse-1] looked
    ;; up in the active keymaps (the area's own keymap is NOT consulted), so we
    ;; put a keymap on the string with a t-default that catches the area
    ;; prefix and dispatches by click position -> column -> indicator.
    ;; NB: a margin honours `help-echo' and click keymaps but NOT `pointer' or
    ;; `mouse-face' (verified) -- so the only hover affordance here is the
    ;; tooltip; the cursor shape cannot be changed over margin content.
    (when clickables
      (setq str (propertize str 'keymap (svg-margin--make-click-map clickables side rcols cw))))
    (overlay-put ov 'svg-margin t)
    (overlay-put ov 'before-string str)
    ;; NB: do NOT set `evaporate' -- these overlays are zero-length, and an
    ;; evaporate overlay is auto-deleted the instant it is empty, so it would
    ;; vanish before display.  `svg-margin--clear' rebuilds them each render.
    (push ov svg-margin--overlays)))

;;;; Window geometry (margins + fringes)
;; ----------------------------------------------------------------

(defun svg-margin--windows ()
  "Return the GRAPHICAL windows currently displaying the current buffer.
Margins/fringes are only meaningful where the SVG can render, so terminal
windows showing the same buffer are excluded (they would otherwise reserve
dead gutter space)."
  (cl-remove-if-not (lambda (w) (display-graphic-p (window-frame w)))
                    (get-buffer-window-list (current-buffer) nil t)))

(defvar-local svg-margin--saved-display nil
  "Originals of the display vars svg-margin overrides, to restore on mode off.
Alist of (VAR LOCAL-P . VALUE): LOCAL-P records whether VAR was already
buffer-local, so a user's (or another package's) own
`left-margin-width'/`left-fringe-width' etc. is restored exactly rather than
clobbered to the global default.")

(defun svg-margin--save-display-var (var)
  "Record VAR's current value and locality once, before svg-margin overrides it."
  (unless (assq var svg-margin--saved-display)
    (push (cons var (cons (local-variable-p var)
                          (and (boundp var) (symbol-value var))))
          svg-margin--saved-display)))

(defun svg-margin--restore-display-var (var)
  "Restore VAR to the value/locality saved by `svg-margin--save-display-var'."
  (let ((entry (assq var svg-margin--saved-display)))
    (when entry
      (if (cadr entry)
          (set (make-local-variable var) (cddr entry))
        (kill-local-variable var))
      (setq svg-margin--saved-display (assq-delete-all var svg-margin--saved-display)))))

(defvar-local svg-margin--last-scale 1.0
  "Text-scale factor (window font width / frame char width) from last render.
Window margins are reserved in units of the frame's canonical character width,
which does not track `text-scale-mode'; the reservation is multiplied by this
factor so a scaled-up indicator image still fits its margin.  See
`svg-margin--apply-margins' and `svg-margin--render'.")

(defun svg-margin--apply-margins (left right)
  "Reserve LEFT and RIGHT indicator columns for the buffer and its windows.
Sets the BUFFER-LOCAL `left-margin-width'/`right-margin-width' so Emacs reserves
the columns ATOMICALLY whenever the buffer is displayed -- no pop-in/jitter when
switching to the buffer (`set-window-buffer' otherwise paints one frame at the
buffer's own margin width before any hook can correct it).  The originals are
saved (see `svg-margin--save-display-var') for restore on mode off.  Also writes
any live window whose margins differ, so the change shows immediately without
inducing a redundant `window-configuration-change-hook'."
  (let ((lw (ceiling (* left svg-margin-column-width svg-margin--last-scale)))
        (rw (ceiling (* right svg-margin-column-width svg-margin--last-scale))))
    (svg-margin--save-display-var 'left-margin-width)
    (svg-margin--save-display-var 'right-margin-width)
    (unless (and (eql left-margin-width lw) (eql right-margin-width rw))
      (setq-local left-margin-width lw right-margin-width rw))
    (dolist (win (svg-margin--windows))
      (let* ((cur (window-margins win))
             (cl (or (car cur) 0))
             (cr (or (cdr cur) 0)))
        (unless (and (= cl lw) (= cr rw))
          (set-window-margins win lw rw))))))

(defun svg-margin--restore-margins ()
  "Restore the margins svg-margin reserved (buffer-local widths and live windows)."
  (svg-margin--restore-display-var 'left-margin-width)
  (svg-margin--restore-display-var 'right-margin-width)
  (dolist (win (svg-margin--windows))
    (set-window-margins win (or left-margin-width 0) (or right-margin-width 0))))

(defun svg-margin--fringe-sides ()
  "Return the list of fringe sides to zero per `svg-margin-disable-fringe'."
  (pcase svg-margin-disable-fringe
    ((or 't 'both) '(left right))
    ('left '(left))
    ('right '(right))
    (_ nil)))

(defun svg-margin--apply-fringes ()
  "Zero the configured fringe side(s) for the buffer.
Sets the BUFFER-LOCAL `left-fringe-width'/`right-fringe-width' so the fringe is
reserved ATOMICALLY when the buffer is displayed -- no pop-in/jitter on buffer
switch (the same fix as `svg-margin--apply-margins'; per-window
`set-window-fringes' alone resets to the buffer's default on `set-window-buffer'
and only re-zeros after the debounced render).  Live windows are written to
match so the change shows immediately."
  (let ((sides (svg-margin--fringe-sides)))
    (when (memq 'left sides)
      (svg-margin--save-display-var 'left-fringe-width)
      (unless (eql left-fringe-width 0) (setq-local left-fringe-width 0)))
    (when (memq 'right sides)
      (svg-margin--save-display-var 'right-fringe-width)
      (unless (eql right-fringe-width 0) (setq-local right-fringe-width 0)))
    (dolist (win (svg-margin--windows))
      (let* ((fr (window-fringes win)) (l (nth 0 fr)) (r (nth 1 fr))
             (nl (if (memq 'left sides) 0 l))
             (nr (if (memq 'right sides) 0 r)))
        (unless (and (= l nl) (= r nr))
          (set-window-fringes win nl nr))))))

(defun svg-margin--restore-fringes ()
  "Restore the fringe widths svg-margin zeroed (buffer-local and live windows)."
  (svg-margin--restore-display-var 'left-fringe-width)
  (svg-margin--restore-display-var 'right-fringe-width)
  (dolist (win (svg-margin--windows))
    (set-window-fringes win nil nil)))

;;;; Render
;; ----------------------------------------------------------------

(defvar-local svg-margin--render-cache nil
  "Cached content + geometry from this buffer's last full render.
Plist `(:content HASH :cw CW :lh LH :left N :right N)' where HASH maps a
buffer position to `(LEFT-PACKED . RIGHT-PACKED)'.  An external scroll layer
re-composites visible lines from this without re-running providers.")

(defvar-local svg-margin--last-cols nil
  "Cons (LEFT . RIGHT) reserved columns from this buffer's last render.
Applied synchronously when the buffer is (re)displayed (see
`svg-margin--apply-cached-margins') so the margin width is correct
immediately, instead of popping in -- and shifting the text -- after the
debounced re-render.")

(defun svg-margin--render (&optional buffer)
  "Re-render all svg-margin indicators in BUFFER (default current)."
  (let ((buffer (or buffer (current-buffer))))
    (when (and (buffer-live-p buffer) (display-graphic-p))
      (with-current-buffer buffer
        (when (bound-and-true-p svg-margin-mode)
          ;; Widen so providers see -- and `:line'/`:pos' resolve against -- the
          ;; whole buffer (absolute positions); overlays outside a narrowing
          ;; simply will not display.
          (save-restriction
            (widen)
            (svg-margin--clear)
            ;; Size cells from the DISPLAYING WINDOW's font rather than the
            ;; frame's canonical font, so indicators track `text-scale-mode' (a
            ;; buffer-local face remap the frame metrics do not see); fall back
            ;; to the selected frame when the buffer is off-screen.
            (let* ((win (car (svg-margin--windows)))
                   (frame (if win (window-frame win) (selected-frame)))
                   (fcw (max 1 (frame-char-width frame)))
                   (cw (* svg-margin-column-width
                          (if win (window-font-width win) fcw)))
                   (lh (max 1 (if win (window-font-height win)
                                (default-line-height))))
                   ;; Margins are reserved in frame-char-width units, which do
                   ;; not scale with text-scale; widen the reservation by the
                   ;; same factor so the larger image is not clipped.
                   (scale (if win (/ (float (window-font-width win)) fcw) 1.0))
                   (groups (svg-margin--group (svg-margin--collect)))
                   (max-left (max 0 svg-margin-min-left-columns))
                   (max-right (max 0 svg-margin-min-right-columns))
                   (cells nil))
              ;; Pass 1: pack each line and find the reserved width per side
              ;; (at least the configured minimum).  Background-only lines
              ;; (ncols 0) still get a cell -- they paint the width others
              ;; reserve -- but contribute no width of their own.
              (maphash
               (lambda (key inds)
                 (let* ((pos (car key)) (side (cdr key))
                        (packed (svg-margin--pack-columns inds))
                        (ncols (svg-margin--max-column packed)))
                   (when (> ncols 0)
                     (if (eq side 'left)
                         (setq max-left (max max-left ncols))
                       (setq max-right (max max-right ncols))))
                   (when packed
                     (push (list pos side packed) cells))))
               groups)
              ;; Pass 2: place each line filling its side's reserved width, so
              ;; indicators align to the text regardless of per-line variation.
              (dolist (c cells)
                (cl-destructuring-bind (pos side packed) c
                  (svg-margin--place pos side packed
                                     (if (eq side 'left) max-left max-right)
                                     cw lh)))
              (setq svg-margin--last-cols (cons max-left max-right)
                    svg-margin--last-scale scale)
              ;; Cache this render's per-position content + geometry so an
              ;; external scroll layer can re-composite visible lines cheaply
              ;; (without re-running providers) on every scroll.  Hash maps a
              ;; buffer position to (LEFT-PACKED . RIGHT-PACKED).
              (let ((cache (make-hash-table :test 'eq)))
                (dolist (c cells)
                  (cl-destructuring-bind (pos side packed) c
                    (let ((cell (or (gethash pos cache) (cons nil nil))))
                      (if (eq side 'left) (setcar cell packed) (setcdr cell packed))
                      (puthash pos cell cache))))
                (setq svg-margin--render-cache
                      (list :content cache :cw cw :lh lh
                            :left max-left :right max-right)))
              (svg-margin--apply-margins max-left max-right)
              (svg-margin--apply-fringes))))))))

(defvar-local svg-margin--timer nil
  "Idle timer coalescing re-renders for this buffer.")

(defun svg-margin--apply-cached-margins ()
  "Reserve this buffer's last-known margin width in its windows, now.
Cheap (just `set-window-margins'); keeps the text from shifting when the
buffer is displayed while the debounced re-render recomputes indicators.
Falls back to the configured minimum columns before the first render."
  (when (bound-and-true-p svg-margin-mode)
    (svg-margin--apply-margins
     (or (car svg-margin--last-cols) (max 0 svg-margin-min-left-columns))
     (or (cdr svg-margin--last-cols) (max 0 svg-margin-min-right-columns)))))

(defun svg-margin--schedule (&optional buffer)
  "Schedule a debounced re-render of BUFFER (default current)."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (timerp svg-margin--timer) (cancel-timer svg-margin--timer))
        (setq svg-margin--timer
              (run-with-idle-timer svg-margin-idle-delay nil
                                   #'svg-margin--render buf))))))

(defun svg-margin--note-help (help)
  "Update the hovered cell from HELP and re-render if it changed.
Wire `show-help-function' to call this (then display HELP as usual): it fires
on mouse enter, move AND leave (leave calls it with nil), so the hovered cell
can be tracked and `svg-margin-hover-highlight' drawn behind it.  HELP carries
the cell identity in its `svg-margin-cell' text property (see
`svg-margin--cell-area')."
  (when svg-margin-hover-highlight
    (let ((cell (and (stringp help) (> (length help) 0)
                     (get-text-property 0 'svg-margin-cell help))))
      (unless (equal cell svg-margin--hovered)
        (let ((old svg-margin--hovered))
          (setq svg-margin--hovered cell)
          (dolist (c (delq nil (list (car-safe old) (car-safe cell))))
            (when (buffer-live-p c) (svg-margin--schedule c))))))))

(defun svg-margin--after-change (&rest _)
  "Schedule a re-render after a buffer change."
  (svg-margin--schedule))

(defun svg-margin--text-scale ()
  "Re-render synchronously after a text-scale change.
The face remap installed by `text-scale-mode' resizes the buffer text on the
very next redisplay; going through the debounced idle timer would resize the
margin a beat later, snapping the text sideways.  This hook runs inside the
text-scale command, before that redisplay, and `window-font-width' already
reflects the new remap -- so rendering here lands the new margin width and
cell images in the same frame as the resized text.  Any pending debounced
render is dropped, as this render supersedes it."
  (when (timerp svg-margin--timer) (cancel-timer svg-margin--timer))
  (svg-margin--render (current-buffer)))

(defun svg-margin--window-config ()
  "Apply the cached margin width immediately, then schedule a re-render.
Applying the cached width synchronously (rather than waiting for the debounced
render) stops the margin -- and the buffer text -- from shifting when the buffer
is freshly displayed in a window."
  (svg-margin--apply-cached-margins)
  (svg-margin--schedule))

;;;; Public commands + mode
;; ----------------------------------------------------------------

;;;###autoload
(defun svg-margin-refresh (&optional buffer)
  "Re-render svg-margin indicators in BUFFER (default current)."
  (interactive)
  (svg-margin--schedule buffer))

(defun svg-margin-refresh-all ()
  "Re-render every buffer in which `svg-margin-mode' is enabled."
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'svg-margin-mode buf)
      (svg-margin--schedule buf))))

;;;###autoload
(define-minor-mode svg-margin-mode
  "Display SVG indicators from registered providers in the window margins.
Providers are registered globally with `svg-margin-register-provider'; this
buffer-local mode renders whatever they contribute for the current buffer.

svg-margin draws SVG images, so it only shows anything in a GRAPHICAL frame;
in a terminal (`emacs -nw') it does nothing."
  :lighter " SVGm"
  (if svg-margin-mode
      (progn
        (unless (display-graphic-p)
          (message "svg-margin-mode: needs a graphical frame; nothing will show in a terminal"))
        (add-hook 'after-change-functions #'svg-margin--after-change nil t)
        (add-hook 'window-configuration-change-hook #'svg-margin--window-config nil t)
        ;; A major-mode change kills the buffer-local state (including the
        ;; mode itself) WITHOUT running the mode-off body, but the overlays
        ;; survive -- delete them while they are still tracked, or they
        ;; linger as untracked stale images.
        (add-hook 'change-major-mode-hook #'svg-margin--clear nil t)
        ;; Re-render when the buffer's text scale changes so indicator cells are
        ;; resized to match (see the window-font metrics in `svg-margin--render').
        ;; Synchronous (not debounced) so the margin resizes in the same
        ;; redisplay as the text, with no sideways snap.
        (add-hook 'text-scale-mode-hook #'svg-margin--text-scale nil t)
        (svg-margin--render (current-buffer)))
    (remove-hook 'after-change-functions #'svg-margin--after-change t)
    (remove-hook 'window-configuration-change-hook #'svg-margin--window-config t)
    (remove-hook 'change-major-mode-hook #'svg-margin--clear t)
    (remove-hook 'text-scale-mode-hook #'svg-margin--text-scale t)
    (when (timerp svg-margin--timer) (cancel-timer svg-margin--timer))
    (svg-margin--clear)
    (svg-margin--restore-fringes)
    (svg-margin--restore-margins)))

(defun svg-margin--maybe-enable ()
  "Turn on `svg-margin-mode' in an ordinary file buffer."
  (when (and (not (minibufferp)) buffer-file-name)
    (svg-margin-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-svg-margin-mode
  svg-margin-mode svg-margin--maybe-enable)

(provide 'svg-margin)
;;; svg-margin.el ends here
