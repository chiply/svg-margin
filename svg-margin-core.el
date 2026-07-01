;;; svg-margin-core.el --- Margin gutter compositor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Charlie Holland

;; Author: Charlie Holland <mister.chiply@gmail.com>
;; Maintainer: Charlie Holland <mister.chiply@gmail.com>
;; URL: https://github.com/chiply/svg-margin

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
;; This is the renderer-independent COMPOSITOR behind svg-margin: the part
;; that turns a set of margin indicators from many independent "providers"
;; into a per-line, multi-column layout, deciding which column each indicator
;; occupies and how wide each side's gutter must be.  It has no dependency on
;; SVG, images, overlays or window geometry -- a renderer (svg-margin.el is
;; one) consumes the layout it produces and draws it however it likes.
;;
;; A PROVIDER is a function of one argument BUFFER returning a list of
;; indicator plists (see `svg-margin-register-provider').  The compositor
;; reads only an indicator's POSITIONING keys and passes everything else
;; through opaquely for the renderer:
;;
;;   :pos / :line   buffer position or 1-based line (one is required)
;;   :side          `left' (default `svg-margin-default-side') or `right'
;;   :column        the indicator's column (see `svg-margin-arrangement')
;;   :priority      higher is arranged first (default 0)
;;   :background    non-nil claims no column (drawn behind the packed cells)
;;
;; The pipeline is: `svg-margin--collect' runs every provider and normalises
;; its output; `svg-margin--compose' groups the indicators by (POS . SIDE),
;; arranges each group into columns, and reserves each side's width.  Two
;; arrangements are offered via `svg-margin-arrangement':
;;
;;   `fill'   pack indicators densely from the column nearest the text,
;;            ordered by `:priority'; `:column' is a soft hint bumped aside on
;;            collision.  This is the default.
;;   `fixed'  treat `:column' as a DEDICATED lane kept on every line, so a
;;            given provider always sits in the same column and the eye can
;;            track it -- empty lanes stay empty, and indicators without a
;;            `:column' fill the free lanes by priority.  See also
;;            `svg-margin-provider-columns' to lane a provider declaratively.
;;
;; `svg-margin--compose' returns a plist (:left L :right R :lines ...) that is
;; the seam between this compositor and a renderer.

;;; Code:

(require 'cl-lib)

(defgroup svg-margin nil
  "Multi-provider SVG indicators in the window margins."
  :group 'convenience
  :prefix "svg-margin-")

(defvar svg-margin-refresh-function nil
  "Function of no arguments that re-renders every svg-margin buffer, or nil.
The provider-registry mutators and the refreshing defcustom `:set'
\(`svg-margin--custom-set') call this when non-nil, so a live change stays
visible while the compositor core stays independent of any particular renderer.
svg-margin.el sets it to `svg-margin-refresh-all'.")

(defun svg-margin--custom-set (symbol value)
  "Set SYMBOL to VALUE and re-render, as a defcustom `:set' function.
Used by the layout/rendering customs so a change through Customize or a setter
command is applied immediately, via `svg-margin-refresh-function'."
  (set-default symbol value)
  (when (functionp svg-margin-refresh-function)
    (funcall svg-margin-refresh-function)))

(defcustom svg-margin-default-side 'left
  "Default margin side for indicators that do not specify `:side'."
  :type '(choice (const left) (const right)))

(defcustom svg-margin-arrangement 'fill
  "How indicators are arranged into columns on a line.
`fill' (the default) packs indicators densely from the column nearest the
text, ordering them by `:priority'; an explicit `:column' is a soft hint that
is bumped aside on collision.  `fixed' instead treats `:column' as a dedicated
lane kept on every line: each indicator stays in its assigned column, columns
without an indicator are left empty, and indicators without a `:column' fill
the free lanes by priority.  Fixed lanes give each provider a stable column so
the eye can track it (see `svg-margin-provider-columns').

May also be an alist mapping a SIDE (`left'/`right') to its arrangement, e.g.
\((left . fixed) (right . fill)), to arrange the two margins differently."
  :type '(choice (const :tag "Fill (dense, priority-ordered)" fill)
                 (const :tag "Fixed (dedicated columns)" fixed)
                 (alist :key-type (choice (const left) (const right))
                        :value-type (choice (const fill) (const fixed))))
  :set #'svg-margin--custom-set)

(defcustom svg-margin-fixed-collision 'drop
  "What the `fixed' arrangement does when indicators claim the same column.
`drop' keeps the higher-`:priority' indicator in the lane and discards the
other (reported when `svg-margin-debug').  `float' keeps the winner in the lane
and re-flows the loser into the lowest free column instead of dropping it.
Only consulted for a `fixed' `svg-margin-arrangement'."
  :type '(choice (const :tag "Drop the loser" drop)
                 (const :tag "Re-flow the loser to a free lane" float))
  :set #'svg-margin--custom-set)

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

(defcustom svg-margin-provider-sides nil
  "Alist of (PROVIDER-NAME . SIDE) overriding where a provider draws.
SIDE is `left' or `right'.  An entry here forces every indicator from that
provider onto SIDE, even one that stamps its own `:side' -- so you can move
any provider (including a third-party one) to the other margin declaratively,
without editing its source.  See also the `:side' argument to
`svg-margin-register-provider'."
  :type '(alist :key-type symbol :value-type (choice (const left) (const right))))

(defcustom svg-margin-provider-columns nil
  "Alist of (PROVIDER-NAME . COLUMN) forcing a provider into a fixed lane.
COLUMN is a 0-based column index (0 nearest the text).  An entry here overrides
every indicator's own `:column', so you can arrange any provider (including a
third-party one) into a dedicated column declaratively, without editing its
source.  Most useful with a `fixed' `svg-margin-arrangement', where each column
is a dedicated lane.  See also `svg-margin-provider-sides'."
  :type '(alist :key-type symbol :value-type integer))

(defcustom svg-margin-debug nil
  "When non-nil, report indicators that are dropped.
A provider whose indicator has no `:pos'/`:line' (or an out-of-range one) has
that indicator silently skipped; likewise a `fixed'-arrangement indicator that
collides on an already-taken column.  Enable this to get a message naming the
provider or the collision, which helps when writing a provider."
  :type 'boolean)

;;;; Providers
;; ----------------------------------------------------------------

(defvar svg-margin--providers nil
  "Alist of (NAME . PLIST); PLIST has :fn and optional :side/:priority/:column.
The optional values are per-provider DEFAULTS applied to any indicator that
omits the corresponding key (see `svg-margin--apply-provider-defaults').")

(defun svg-margin--providers-changed ()
  "Notify the renderer that the provider set changed, if one is wired up.
Runs `svg-margin-refresh-function' when non-nil, keeping the compositor core
free of any reference to a renderer."
  (when (functionp svg-margin-refresh-function)
    (funcall svg-margin-refresh-function)))

;;;###autoload
(cl-defun svg-margin-register-provider (name fn &key side priority column)
  "Register provider FN under NAME (a symbol), replacing any prior one.
FN is called with one argument, the buffer, and returns a list of indicator
plists (see Commentary).  The optional keywords set per-provider DEFAULTS:
SIDE (`left'/`right'), PRIORITY, and COLUMN are applied to any indicator this
provider emits that does not specify them itself, so a provider need not stamp
every indicator.  `svg-margin-provider-sides' can override SIDE per provider
and `svg-margin-provider-columns' can override COLUMN.  Registered buffers are
re-rendered."
  (setf (alist-get name svg-margin--providers)
        (list :fn fn :side side :priority priority :column column))
  (svg-margin--providers-changed))

;;;###autoload
(defun svg-margin-unregister-provider (name)
  "Remove the provider registered under NAME and re-render."
  (setq svg-margin--providers (assq-delete-all name svg-margin--providers))
  (svg-margin--providers-changed))

(defun svg-margin--apply-provider-defaults (ind props override-side
                                                &optional override-column)
  "Fill IND's missing :side/:priority/:column from provider PROPS.
OVERRIDE-SIDE, when non-nil, forces `:side' regardless of what IND carries.
OVERRIDE-COLUMN, when non-nil, likewise forces `:column' (see
`svg-margin-provider-columns')."
  (let ((ind (copy-sequence ind)))
    (when (and (plist-get props :side) (not (plist-member ind :side)))
      (setq ind (plist-put ind :side (plist-get props :side))))
    (when (and (plist-get props :priority) (not (plist-member ind :priority)))
      (setq ind (plist-put ind :priority (plist-get props :priority))))
    (when (and (plist-get props :column) (not (plist-member ind :column)))
      (setq ind (plist-put ind :column (plist-get props :column))))
    (when override-side
      (setq ind (plist-put ind :side override-side)))
    (when override-column
      (setq ind (plist-put ind :column override-column)))
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
Per-provider defaults and the `svg-margin-provider-sides' /
`svg-margin-provider-columns' overrides are applied, and (when
`svg-margin-debug') position-less indicators are reported."
  (let ((buf (current-buffer)) (out nil))
    (dolist (p svg-margin--providers)
      (let* ((name (car p)) (props (cdr p)) (fn (plist-get props :fn))
             (override (alist-get name svg-margin-provider-sides))
             (override-col (alist-get name svg-margin-provider-columns)))
        (condition-case err
            (dolist (ind (funcall fn buf))
              (let* ((ind (svg-margin--apply-provider-defaults
                           ind props override override-col))
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

;;;; Arrangement
;; ----------------------------------------------------------------

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

(defun svg-margin--arrange-fixed (indicators)
  "Assign each of INDICATORS its dedicated `:column' as a fixed lane.
Unlike `svg-margin--pack-columns', an explicit `:column' is a HARD reservation
kept on every line, so a provider stays in the same lane and empty lanes are
left empty.  When two indicators claim the same column the higher `:priority'
keeps it and the other is dropped (reported when `svg-margin-debug'), so each
cell still holds a single indicator.  Indicators without a `:column' fill the
lowest free lanes, by priority, around the fixed ones.  A `:background'
indicator claims no column, exactly as in `svg-margin--pack-columns'.
Returns a list of (:indicator IND :column N-or-nil)."
  (let ((sorted (sort (copy-sequence indicators)
                      (lambda (a b) (> (or (plist-get a :priority) 0)
                                       (or (plist-get b :priority) 0)))))
        (backgrounds nil) (fixed nil) (floating nil)
        (used nil) (result nil))
    ;; Partition, highest priority first: the priority winner of a lane
    ;; collision, and the first pick of a free lane, then comes first.
    (dolist (ind sorted)
      (cond ((plist-get ind :background) (push ind backgrounds))
            ((plist-get ind :column) (push ind fixed))
            (t (push ind floating))))
    ;; Fixed lanes: honour the column.  A collision on a taken lane is resolved
    ;; per `svg-margin-fixed-collision' -- drop the (lower-priority) loser, or
    ;; re-flow it into a free lane with the floating indicators.
    (dolist (ind (nreverse fixed))
      (let ((col (plist-get ind :column)))
        (cond ((not (memq col used))
               (push col used)
               (push (list :indicator ind :column col) result))
              ((eq svg-margin-fixed-collision 'float)
               (push ind floating))
              (svg-margin-debug
               (message "svg-margin: dropped an indicator colliding on fixed column %d"
                        col)))))
    ;; Floating indicators (column-less, plus any re-flowed collisions) fill the
    ;; lowest free lanes, highest priority first.
    (dolist (ind (sort floating
                       (lambda (a b) (> (or (plist-get a :priority) 0)
                                        (or (plist-get b :priority) 0)))))
      (let ((col 0))
        (while (memq col used) (setq col (1+ col)))
        (push col used)
        (push (list :indicator ind :column col) result)))
    ;; Backgrounds claim no lane.
    (dolist (ind (nreverse backgrounds))
      (push (list :indicator ind :column nil) result))
    (nreverse result)))

(defun svg-margin--arrangement (side)
  "Return the arrangement symbol (`fill' or `fixed') in effect for SIDE.
Resolves `svg-margin-arrangement', which may be a bare symbol or a per-side
alist; an unlisted side falls back to `fill'."
  (if (consp svg-margin-arrangement)
      (or (alist-get side svg-margin-arrangement) 'fill)
    svg-margin-arrangement))

(defun svg-margin--arrange (indicators side)
  "Assign columns to INDICATORS on SIDE per `svg-margin-arrangement'.
Dispatches to `svg-margin--arrange-fixed' for a `fixed' side, else to
`svg-margin--pack-columns'."
  (if (eq (svg-margin--arrangement side) 'fixed)
      (svg-margin--arrange-fixed indicators)
    (svg-margin--pack-columns indicators)))

(defun svg-margin--max-column (packed)
  "Return the number of columns occupied by PACKED (max column + 1).
A background cell (nil `:column') occupies no column."
  (1+ (apply #'max -1 (mapcar (lambda (c) (or (plist-get c :column) -1))
                              packed))))

;;;; Compose (the renderer-independent layout seam)
;; ----------------------------------------------------------------

(cl-defun svg-margin--compose (indicators &key (min-left 0) (min-right 0))
  "Compose INDICATORS into a renderer-independent margin layout.
Groups INDICATORS by (POS . SIDE), arranges each group into columns per
`svg-margin-arrangement', and reserves each side's column count -- the most
columns any line needs on that side, never below MIN-LEFT / MIN-RIGHT.
Returns a plist (:left L :right R :lines ((POS SIDE PACKED) ...)), where PACKED
is the arranged (:indicator IND :column N-or-nil) list for that line.

This is the compositor seam: it has no dependency on SVG, overlays or window
geometry, so a renderer can consume the layout however it likes.  A
background-only line still yields a cell (PACKED is non-empty) but adds no
width of its own (its columns are nil)."
  (let ((groups (svg-margin--group indicators))
        (left (max 0 min-left))
        (right (max 0 min-right))
        (lines nil))
    (maphash
     (lambda (key inds)
       (let* ((pos (car key)) (side (cdr key))
              (packed (svg-margin--arrange inds side))
              (ncols (svg-margin--max-column packed)))
         (when (> ncols 0)
           (if (eq side 'left) (setq left (max left ncols))
             (setq right (max right ncols))))
         (when packed (push (list pos side packed) lines))))
     groups)
    (list :left left :right right :lines lines)))

(provide 'svg-margin-core)
;;; svg-margin-core.el ends here
