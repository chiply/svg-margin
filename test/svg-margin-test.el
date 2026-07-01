;;; svg-margin-test.el --- ERT tests for svg-margin -*- lexical-binding: t -*-

;; Run with:
;;   emacs -Q --batch -L .. -l svg-margin-test.el -f ert-run-tests-batch-and-exit
;; from the test/ directory.

(require 'ert)
(require 'cl-lib)
(require 'dom)
(add-to-list 'load-path
             (file-name-directory
              (directory-file-name
               (file-name-directory
                (or load-file-name buffer-file-name)))))
(require 'svg-margin)

;;;; Colour

(ert-deftest svg-margin/color-normalisation ()
  "Colours are reduced to 6-digit hex SVG understands."
  (should (equal (svg-margin--color "#e7edf6") "#e7edf6"))  ; pass-through
  (should (equal (svg-margin--color nil) nil))
  ;; A non-string is returned unchanged.
  (should (equal (svg-margin--color 'foo) 'foo))
  ;; A 12-digit hex reduces to 6-digit hex (exact value is display-dependent).
  (should (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'"
                          (svg-margin--color "#57c071477e0a"))))

;;;; Shape registry

(ert-deftest svg-margin/default-shapes-registered ()
  "The built-in shapes are present in the registry."
  (dolist (s '(dot circle bar box triangle))
    (should (functionp (gethash s svg-margin--shapes)))))

(ert-deftest svg-margin/define-shape ()
  "`svg-margin-define-shape' installs a drawing function under a name."
  (let ((svg-margin--shapes (copy-hash-table svg-margin--shapes)))
    (svg-margin-define-shape 'my-shape (lambda (&rest _) :drawn))
    (should (eq (funcall (gethash 'my-shape svg-margin--shapes)) :drawn))))

(ert-deftest svg-margin/shape-dot-draws-circle ()
  (let ((svg (svg-create 10 10)))
    (svg-margin--shape-dot svg 0 0 10 10 "#ff0000")
    (let ((c (dom-by-tag svg 'circle)))
      (should c)
      (should (equal (dom-attr (car c) 'fill) "#ff0000")))))

(ert-deftest svg-margin/shape-bar-draws-rect ()
  (let ((svg (svg-create 10 10)))
    (svg-margin--shape-bar svg 0 0 10 10 "#00ff00")
    (should (dom-by-tag svg 'rect))))

;;;; Drawing dispatch

(ert-deftest svg-margin/draw-text-centred ()
  "`svg-margin--draw-text' draws a centred text element."
  (let ((svg (svg-create 20 14)))
    (svg-margin--draw-text svg "x" 0 0 20 14 "#123456")
    (let ((tx (car (dom-by-tag svg 'text))))
      (should tx)
      (should (equal (dom-attr tx 'text-anchor) "middle"))
      (should (= (dom-attr tx 'x) 10)))))

(ert-deftest svg-margin/draw-dispatch ()
  "`svg-margin--draw' routes :draw, :text, :shape, then a default dot."
  (let ((svg (svg-create 10 10)))
    (svg-margin--draw '(:draw (lambda (svg x y w h _c)
                                (svg-rectangle svg x y w h :fill "#000")))
                      svg 0 0 10 10)
    (should (dom-by-tag svg 'rect)))
  (let ((svg (svg-create 10 10)))
    (svg-margin--draw '(:text "a" :color "#fff") svg 0 0 10 10)
    (should (dom-by-tag svg 'text)))
  (let ((svg (svg-create 10 10)))
    (svg-margin--draw '(:shape bar :color "#fff") svg 0 0 10 10)
    (should (dom-by-tag svg 'rect)))
  (let ((svg (svg-create 10 10)))
    (svg-margin--draw '(:color "#fff") svg 0 0 10 10) ; no shape -> dot
    (should (dom-by-tag svg 'circle))))

(ert-deftest svg-margin/indicator-color ()
  "Colour comes from :color, then :face foreground, then a default."
  (should (equal (svg-margin--indicator-color '(:color "#abcdef")) "#abcdef"))
  (should (equal (svg-margin--indicator-color '(:face error))
                 (face-foreground 'error nil 'default)))
  (should (stringp (svg-margin--indicator-color '(:shape dot)))))

;;;; Providers

(ert-deftest svg-margin/register-and-unregister-provider ()
  (let ((svg-margin--providers nil))
    (svg-margin-register-provider 'p (lambda (_b) nil))
    (should (assq 'p svg-margin--providers))
    (svg-margin-unregister-provider 'p)
    (should-not (assq 'p svg-margin--providers))))

(ert-deftest svg-margin/provider-defaults ()
  "Per-provider defaults fill missing keys; an override forces :side."
  (let ((props '(:fn ignore :side right :priority 5)))
    ;; Missing :side gets the provider default.
    (should (eq 'right (plist-get (svg-margin--apply-provider-defaults
                                   '(:line 1) props nil)
                                  :side)))
    ;; An indicator's own :side is kept (not clobbered by the default).
    (should (eq 'left (plist-get (svg-margin--apply-provider-defaults
                                  '(:line 1 :side left) props nil)
                                 :side)))
    ;; OVERRIDE-SIDE forces :side regardless.
    (should (eq 'right (plist-get (svg-margin--apply-provider-defaults
                                   '(:line 1 :side left) props 'right)
                                  :side)))
    ;; Missing :priority gets the default.
    (should (eql 5 (plist-get (svg-margin--apply-provider-defaults
                               '(:line 1) props nil)
                              :priority)))))

(ert-deftest svg-margin/collect-runs-providers ()
  "`svg-margin--collect' runs providers and normalises their output."
  (with-temp-buffer
    (insert "l1\nl2\nl3\n")
    (let ((svg-margin--providers nil))
      (svg-margin-register-provider 'p
        (lambda (_b) (list (list :line 2 :shape 'dot))))
      (let ((out (svg-margin--collect)))
        (should (= 1 (length out)))
        (should (plist-get (car out) :pos))
        (should (eq 'left (plist-get (car out) :side)))))))

;;;; Normalisation

(ert-deftest svg-margin/normalize-line-to-pos ()
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (let ((n (svg-margin--normalize '(:line 2 :shape dot))))
      (should n)
      (should (eq 'left (plist-get n :side)))
      ;; :pos is at the beginning of line 2.
      (should (= (plist-get n :pos)
                 (save-excursion (goto-char (point-min))
                                 (forward-line 1) (point)))))))

(ert-deftest svg-margin/normalize-side-and-missing-pos ()
  (with-temp-buffer
    (insert "a\nb\n")
    (should (eq 'right (plist-get (svg-margin--normalize '(:line 1 :side right)) :side)))
    ;; No :pos/:line at all -> dropped.
    (should-not (svg-margin--normalize '(:shape dot)))
    ;; An out-of-range :pos -> dropped.
    (should-not (svg-margin--normalize '(:pos 99999)))))

(ert-deftest svg-margin/normalize-widens ()
  "Line numbers resolve against the whole buffer even under narrowing."
  (with-temp-buffer
    (dotimes (i 10) (insert (format "line %d\n" i)))
    (let ((p2 (save-excursion (goto-char (point-min)) (forward-line 1) (point))))
      (narrow-to-region (save-excursion (goto-char (point-min)) (forward-line 5) (point))
                        (point-max))
      (should (= p2 (plist-get (svg-margin--normalize '(:line 2)) :pos))))))

;;;; Grouping & packing

(ert-deftest svg-margin/group-by-pos-side ()
  (let ((h (svg-margin--group '((:pos 1 :side left) (:pos 1 :side left)
                                (:pos 1 :side right)))))
    (should (= 2 (length (gethash '(1 . left) h))))
    (should (= 1 (length (gethash '(1 . right) h))))))

(ert-deftest svg-margin/pack-columns-auto ()
  "Two column-less indicators pack into columns 0 and 1."
  (let* ((packed (svg-margin--pack-columns '((:id a) (:id b))))
         (cols (sort (mapcar (lambda (c) (plist-get c :column)) packed) #'<)))
    (should (equal cols '(0 1)))))

(ert-deftest svg-margin/pack-columns-priority ()
  "Higher :priority is packed first (lands in column 0)."
  (let* ((packed (svg-margin--pack-columns '((:id lo :priority 0)
                                             (:id hi :priority 5))))
         (hi (cl-find-if (lambda (c) (eq (plist-get (plist-get c :indicator) :id) 'hi))
                         packed)))
    (should (= 0 (plist-get hi :column)))))

(ert-deftest svg-margin/pack-columns-explicit ()
  "A free explicit :column is honoured."
  (let ((packed (svg-margin--pack-columns '((:id a :column 3)))))
    (should (= 3 (plist-get (car packed) :column)))))

(ert-deftest svg-margin/max-column ()
  (should (= 2 (svg-margin--max-column '((:column 0) (:column 1)))))
  (should (= 0 (svg-margin--max-column nil))))

;;;; Fixed arrangement

(ert-deftest svg-margin/arrange-fixed-honours-column ()
  "Under `fixed', a `:column' is a dedicated lane kept even when alone."
  (let ((packed (svg-margin--arrange-fixed '((:id a :column 3)))))
    (should (= 1 (length packed)))
    (should (= 3 (plist-get (car packed) :column)))
    (should (= 4 (svg-margin--max-column packed)))))

(ert-deftest svg-margin/arrange-fixed-floats-around-fixed ()
  "Column-less indicators fill the free lanes around the fixed ones."
  (let* ((packed (svg-margin--arrange-fixed '((:id fixed :column 1)
                                              (:id x) (:id y))))
         (col (lambda (id)
                (plist-get
                 (cl-find-if (lambda (c)
                               (eq id (plist-get (plist-get c :indicator) :id)))
                             packed)
                 :column))))
    (should (= 1 (funcall col 'fixed)))
    ;; The two column-less indicators take the lowest free lanes, 0 and 2.
    (should (equal '(0 2) (sort (list (funcall col 'x) (funcall col 'y)) #'<)))))

(ert-deftest svg-margin/arrange-fixed-collision-keeps-priority ()
  "On a shared fixed lane the higher `:priority' keeps it; the other drops."
  (let ((packed (svg-margin--arrange-fixed '((:id lo :column 2 :priority 0)
                                             (:id hi :column 2 :priority 5)))))
    (should (equal '(hi) (mapcar (lambda (c) (plist-get (plist-get c :indicator) :id))
                                 packed)))
    (should (= 2 (plist-get (car packed) :column)))))

(ert-deftest svg-margin/arrange-fixed-background-no-column ()
  "A `:background' indicator claims no lane under `fixed'."
  (let* ((packed (svg-margin--arrange-fixed '((:background t) (:id a :column 0))))
         (bg (cl-find-if (lambda (c) (plist-get (plist-get c :indicator) :background))
                         packed)))
    (should bg)
    (should-not (plist-get bg :column))))

(ert-deftest svg-margin/arrange-fixed-collision-float ()
  "With `float' collision the loser re-flows to a free lane instead of dropping."
  (let* ((svg-margin-fixed-collision 'float)
         (packed (svg-margin--arrange-fixed '((:id lo :column 2 :priority 0)
                                              (:id hi :column 2 :priority 5))))
         (byid (lambda (id) (cl-find-if
                             (lambda (c) (eq id (plist-get (plist-get c :indicator) :id)))
                             packed))))
    (should (= 2 (length packed)))                         ; both kept
    (should (= 2 (plist-get (funcall byid 'hi) :column)))  ; winner keeps the lane
    (should (= 0 (plist-get (funcall byid 'lo) :column))))) ; loser re-flows to lane 0

;;;; Arrangement selection

(ert-deftest svg-margin/arrangement-resolver ()
  "`svg-margin--arrangement' reads a bare symbol or a per-side alist."
  (let ((svg-margin-arrangement 'fixed))
    (should (eq 'fixed (svg-margin--arrangement 'left)))
    (should (eq 'fixed (svg-margin--arrangement 'right))))
  (let ((svg-margin-arrangement '((left . fixed) (right . fill))))
    (should (eq 'fixed (svg-margin--arrangement 'left)))
    (should (eq 'fill (svg-margin--arrangement 'right))))
  ;; An unlisted side falls back to fill.
  (let ((svg-margin-arrangement '((left . fixed))))
    (should (eq 'fill (svg-margin--arrangement 'right)))))

(ert-deftest svg-margin/arrange-dispatch ()
  "`svg-margin--arrange' routes to the fixed or fill algorithm per side."
  (let ((inds '((:id a :column 0 :priority 5) (:id b :column 0 :priority 0))))
    ;; Fixed: the lane collision drops the loser (one cell remains).
    (let ((svg-margin-arrangement 'fixed))
      (should (= 1 (length (svg-margin--arrange inds 'left)))))
    ;; Fill: the collision bumps the loser to the next lane (two cells).
    (let ((svg-margin-arrangement 'fill))
      (should (= 2 (length (svg-margin--arrange inds 'left)))))))

;;;; Compose (the layout seam)

(ert-deftest svg-margin/compose-reserves-per-side ()
  "`svg-margin--compose' reserves each side's width and returns its lines."
  (let* ((svg-margin-arrangement 'fill)
         (layout (svg-margin--compose '((:pos 1 :side left :id a)
                                        (:pos 1 :side left :id b)
                                        (:pos 5 :side right :id c)))))
    (should (= 2 (plist-get layout :left)))
    (should (= 1 (plist-get layout :right)))
    (should (= 2 (length (plist-get layout :lines))))))

(ert-deftest svg-margin/compose-honours-minimums ()
  "Reserved columns never fall below the configured minimums."
  (let ((layout (svg-margin--compose '((:pos 1 :side left :id a))
                                     :min-left 3 :min-right 2)))
    (should (= 3 (plist-get layout :left)))
    (should (= 2 (plist-get layout :right)))))

(ert-deftest svg-margin/compose-background-only-adds-no-width ()
  "A background-only line yields a cell but reserves no width of its own."
  (let ((layout (svg-margin--compose '((:pos 1 :side left :background t)))))
    (should (= 0 (plist-get layout :left)))
    (should (= 1 (length (plist-get layout :lines))))))

(ert-deftest svg-margin/provider-columns-override ()
  "`svg-margin-provider-columns' forces a provider's indicators into a lane."
  ;; Direct: the OVERRIDE-COLUMN argument wins over the indicator's own.
  (should (= 7 (plist-get (svg-margin--apply-provider-defaults
                           '(:line 1 :column 2) '(:fn ignore) nil 7)
                          :column)))
  ;; Through `svg-margin--collect' via `svg-margin-provider-columns'.
  (with-temp-buffer
    (insert "l1\nl2\n")
    (let ((svg-margin--providers nil)
          (svg-margin-provider-columns '((p . 4))))
      (svg-margin-register-provider 'p (lambda (_b) (list (list :line 1 :column 1))))
      (let ((out (svg-margin--collect)))
        (should (= 1 (length out)))
        (should (= 4 (plist-get (car out) :column)))))))

;;;; Text renderer

(ert-deftest svg-margin/cell-glyph ()
  "`svg-margin--cell-glyph' uses :text, then a mapped shape char, then fallback."
  (should (equal "x" (svg-margin--cell-glyph '(:text "x" :shape dot))))
  (should (equal (alist-get 'dot svg-margin-shape-characters)
                 (svg-margin--cell-glyph '(:shape dot))))
  (should (equal svg-margin-text-fallback (svg-margin--cell-glyph '(:color "#fff")))))

(ert-deftest svg-margin/text-face ()
  "`svg-margin--text-face' builds a foreground from :color, or uses :face."
  (should (equal '(:foreground "#abcdef") (svg-margin--text-face '(:color "#abcdef"))))
  (should (eq 'warning (svg-margin--text-face '(:face warning))))
  ;; With a hover background the base face and background combine.
  (should (equal '(warning (:background "#123456"))
                 (svg-margin--text-face '(:face warning) "#123456"))))

(ert-deftest svg-margin/text-margin-glyphs-and-lanes ()
  "`svg-margin--text-margin' renders glyphs into their columns per side.
`equal' ignores text properties, so this checks the glyph layout only."
  (let ((svg-margin-column-width 1)
        (packed '((:indicator (:text "A") :column 0)
                  (:indicator (:text "B") :column 2))))
    ;; Left margin lays out the highest column first: [col2][col1][col0].
    (should (equal "B A" (svg-margin--text-margin packed 'left 3 1 nil)))
    ;; Right margin puts column 0 leftmost: [col0][col1][col2].
    (should (equal "A B" (svg-margin--text-margin packed 'right 3 1 nil)))))

(ert-deftest svg-margin/text-margin-fallback-glyph ()
  "A shapeless, textless indicator draws the fallback glyph."
  (let ((svg-margin-column-width 1)
        (svg-margin-text-fallback "•"))
    (should (equal "•" (svg-margin--text-margin '((:indicator (:color "#fff") :column 0))
                                                'left 1 1 nil)))))

(ert-deftest svg-margin/renderer-usable-p ()
  "The `text' renderer is usable on any frame; `svg' needs a graphical one.
Runs in batch, where `display-graphic-p' is nil (like a terminal)."
  (let ((svg-margin-renderer 'text))
    (should (svg-margin--renderer-usable-p)))          ; usable even non-graphically
  (let ((svg-margin-renderer 'svg))
    ;; `svg' tracks `display-graphic-p' exactly -- nil here, so unusable.
    (should (eq (display-graphic-p) (svg-margin--renderer-usable-p)))))

(ert-deftest svg-margin/setter-commands ()
  "The setter and toggle commands update the customs globally."
  (let ((r svg-margin-renderer) (a svg-margin-arrangement))
    (unwind-protect
        (progn
          (svg-margin-set-renderer 'text)
          (should (eq svg-margin-renderer 'text))
          (svg-margin-toggle-renderer)
          (should (eq svg-margin-renderer 'svg))
          (svg-margin-set-arrangement 'fixed)
          (should (eq svg-margin-arrangement 'fixed))
          (svg-margin-toggle-arrangement)
          (should (eq svg-margin-arrangement 'fill)))
      (setq-default svg-margin-renderer r svg-margin-arrangement a))))

;;;; Hover help & hot-spots

(ert-deftest svg-margin/area-help-composition ()
  (should (equal (svg-margin--area-help
                  '(:help "h" :action foo :action-help "jump"
                          :menu (("a" . b))))
                 "h  ·  click to jump  ·  right-click for menu"))
  (should (equal (svg-margin--area-help '(:help "only")) "only"))
  (should-not (svg-margin--area-help '(:shape dot))))

(ert-deftest svg-margin/cell-area-hotspot ()
  "A cell with :help yields a rect hot-spot tagged with its identity."
  (let ((area (svg-margin--cell-area '(:help "hi" :action foo :action-help "go")
                                     0 10 14 100 'left 0)))
    (should area)
    (should (eq 'rect (car (nth 0 area))))
    (let ((props (nth 2 area)))
      (should (eq 'hand (plist-get props 'pointer)))
      (should (get-text-property 0 'svg-margin-cell (plist-get props 'help-echo))))))

(ert-deftest svg-margin/cell-area-nil-without-help-or-action ()
  (should-not (svg-margin--cell-area '(:shape dot) 0 10 14 100 'left 0)))

(ert-deftest svg-margin/hover-color-is-string ()
  "The hover background resolves to a colour string (hex in a GUI frame)."
  (should (stringp (svg-margin--hover-color))))

;;;; Display-var save / restore

(ert-deftest svg-margin/save-restore-existing-local ()
  "A pre-existing buffer-local value is restored exactly."
  (with-temp-buffer
    (setq-local left-margin-width 5)
    (let ((svg-margin--saved-display nil))
      (svg-margin--save-display-var 'left-margin-width)
      (setq-local left-margin-width 10)
      (svg-margin--restore-display-var 'left-margin-width)
      (should (= 5 left-margin-width))
      (should (local-variable-p 'left-margin-width)))))

(ert-deftest svg-margin/save-restore-non-local ()
  "A var that was not buffer-local is killed (made non-local) on restore."
  (with-temp-buffer
    (let ((svg-margin--saved-display nil))
      (should-not (local-variable-p 'right-margin-width))
      (svg-margin--save-display-var 'right-margin-width)
      (setq-local right-margin-width 7)
      (svg-margin--restore-display-var 'right-margin-width)
      (should-not (local-variable-p 'right-margin-width)))))

;;;; Mode

(ert-deftest svg-margin/mode-toggles ()
  (with-temp-buffer
    (svg-margin-mode 1)
    (should svg-margin-mode)
    (should (memq #'svg-margin--after-change after-change-functions))
    (should (memq #'svg-margin--text-scale text-scale-mode-hook))
    (svg-margin-mode -1)
    (should-not svg-margin-mode)
    (should-not (memq #'svg-margin--after-change after-change-functions))
    (should-not (memq #'svg-margin--text-scale text-scale-mode-hook))))

(ert-deftest svg-margin/global-mode-defined ()
  (should (fboundp 'global-svg-margin-mode)))

(ert-deftest svg-margin/clear-deletes-orphans ()
  "Overlays the bookkeeping list lost track of are still deleted.
`kill-all-local-variables' (major-mode change, `revert-buffer') wipes the
buffer-local list but not the overlays; clearing must not depend on it."
  (with-temp-buffer
    (insert "one\ntwo\n")
    (let ((ov (make-overlay 1 1)))
      (overlay-put ov 'svg-margin t)
      (setq svg-margin--overlays nil)   ; simulate the list being wiped
      (svg-margin--clear)
      (should-not (overlay-buffer ov)))))

(ert-deftest svg-margin/clear-widens ()
  "Clearing reaches overlays outside the current narrowing."
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (let ((ov (make-overlay 1 1)))
      (overlay-put ov 'svg-margin t)
      (push ov svg-margin--overlays)
      (narrow-to-region 9 15)
      (svg-margin--clear)
      (should-not (overlay-buffer ov)))))

(ert-deftest svg-margin/major-mode-change-clears ()
  "A major-mode change deletes the overlays before the local state dies."
  (with-temp-buffer
    (svg-margin-mode 1)
    (let ((ov (make-overlay 1 1)))
      (overlay-put ov 'svg-margin t)
      (push ov svg-margin--overlays)
      (fundamental-mode)
      (should-not (overlay-buffer ov)))))

;;;; Background indicators

(ert-deftest svg-margin/background-claims-no-column ()
  "A :background indicator packs with a nil column and occupies no slot."
  (let* ((packed (svg-margin--pack-columns
                  '((:background t :color "#888888")
                    (:shape dot :color "#cc3333")
                    (:shape bar :color "#3333cc"))))
         (bg (seq-find (lambda (c) (plist-get (plist-get c :indicator) :background))
                       packed))
         (cols (delq nil (mapcar (lambda (c) (plist-get c :column)) packed))))
    (should bg)
    (should-not (plist-get bg :column))
    ;; The two regular indicators still pack densely from column 0.
    (should (equal (sort cols #'<) '(0 1)))
    (should (= 2 (svg-margin--max-column packed)))))

(ert-deftest svg-margin/background-only-line-counts-zero-columns ()
  "A line with only a background occupies zero columns (adds no width)."
  (should (= 0 (svg-margin--max-column
                (svg-margin--pack-columns '((:background t :color "#888888")))))))

;;;; Text weight

(ert-deftest svg-margin/draw-text-weight ()
  "`:weight' overrides the default bold font-weight; default is bold."
  (let ((svg (svg-create 20 14)))
    (svg-margin--draw-text svg "x" 0 0 20 14 "#123456" nil nil "300")
    (should (equal (dom-attr (car (dom-by-tag svg 'text)) 'font-weight) "300")))
  (let ((svg (svg-create 20 14)))
    (svg-margin--draw-text svg "x" 0 0 20 14 "#123456")
    (should (equal (dom-attr (car (dom-by-tag svg 'text)) 'font-weight) "bold"))))

(ert-deftest svg-margin/draw-passes-weight ()
  "`svg-margin--draw' forwards `:weight' to the text drawer."
  (let ((svg (svg-create 20 14)))
    (svg-margin--draw '(:text "x" :color "#fff" :weight "300") svg 0 0 20 14)
    (should (equal (dom-attr (car (dom-by-tag svg 'text)) 'font-weight) "300"))))

;;;; Hover

(ert-deftest svg-margin/note-help-obsolete-alias ()
  "The old private `svg-margin--note-help' name still resolves to the public one."
  (should (eq (indirect-function 'svg-margin--note-help)
              (indirect-function 'svg-margin-note-help))))

(ert-deftest svg-margin/hover-mode-wires-show-help ()
  "`svg-margin-hover-mode' installs then removes a `show-help-function' wrapper."
  (let ((show-help-function nil)
        (svg-margin-hover-highlight nil)
        (svg-margin--prev-show-help nil))
    (svg-margin-hover-mode 1)
    (unwind-protect
        (progn
          (should svg-margin-hover-highlight)
          (should (eq show-help-function #'svg-margin--show-help)))
      (svg-margin-hover-mode -1))
    (should-not svg-margin-hover-highlight)
    (should-not show-help-function)))

(ert-deftest svg-margin/hover-mode-chains-prior ()
  "Enabling preserves and chains a prior `show-help-function'."
  (let* ((seen nil)
         (show-help-function (lambda (h) (setq seen h)))
         (svg-margin-hover-highlight nil)
         (svg-margin--prev-show-help nil))
    (svg-margin-hover-mode 1)
    (unwind-protect
        (progn (funcall show-help-function "x")
               (should (equal seen "x")))      ; prior wrapper still called
      (svg-margin-hover-mode -1))))

;;;; Global predicate

(ert-deftest svg-margin/global-predicate ()
  "`svg-margin--maybe-enable' respects `svg-margin-global-predicate'."
  (with-temp-buffer
    (should-not (svg-margin-file-buffer-p))    ; no file -> default is nil
    (let ((svg-margin-global-predicate (lambda () t)))
      (svg-margin--maybe-enable)
      (should svg-margin-mode)
      (svg-margin-mode -1))))

;;;; Composite image (needs librsvg)

(ert-deftest svg-margin/image-builds ()
  "The composite margin image is an SVG image descriptor with a hot-spot map."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'svg)))
  (let* ((packed (svg-margin--pack-columns
                  '((:shape dot :color "#abcdef" :help "h" :action foo
                            :action-help "go"))))
         (img (svg-margin--image packed 1 'left 1 10 14 nil)))
    (should (eq 'image (car img)))
    (should (plist-get (cdr img) :map))))
