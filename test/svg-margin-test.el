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
    (svg-margin-mode -1)
    (should-not svg-margin-mode)
    (should-not (memq #'svg-margin--after-change after-change-functions))))

(ert-deftest svg-margin/global-mode-defined ()
  (should (fboundp 'global-svg-margin-mode)))

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
