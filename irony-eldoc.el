;;; irony-eldoc.el --- irony-mode support for eldoc-mode -*- lexical-binding: t -*-
;;
;; Copyright (C) 2014 Kirill Ignatiev <github.com/ikirill>
;;
;; Author: Kirill Ignatiev <github.com/ikirill>
;; Version: 0.1
;; Keywords: c, c++, objc, convenience, tools
;; URL: https://github.com/ikirill/irony-eldoc
;; Package-Requires: ((emacs "24") (cl-lib "0.5") (irony "0.1"))
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; This implements eldoc support in irony-mode.  eldoc is a built-in
;; Emacs mode for displaying documentation about a symbol or function
;; call at point in the message buffer (see `eldoc-mode').
;;
;; To use:
;;
;; Enable the minor mode `irony-eldoc', as well as `eldoc-mode'. For
;; an example, place point on top of a symbol, or inside a function
;; call.
;;
;; It is easiest to add `irony-eldoc' to `irony-mode-hook', if you
;; already have `irony-mode' set up.
;;
;; Screenshot:
;;
;; ![Screenshot](screenshot.png "Screenshot")
;;
;; Notes:
;;
;; - It is based on irony-mode, which is in turn based on libclang. As a
;;   result, it avoid reparsing files when possible and is quite
;;   accurate.
;;
;; - TODO It is a little imprecise when it comes to function calls:
;;   right now it resolves overloaded function calls by the number of
;;   arguments, but doesn't take arguments' types into account. It
;;   will show all matching functions in the minibuffer message, but
;;   that will include some irrelevant ones too. There is a plan to
;;   incorporate a precise version of this feature into `irony-mode'.
;;
;;; Code:

(require 'irony)
(require 'irony-completion)
(require 'thingatpt)
(require 'cl-lib)
(require 'eldoc)

;; {{{ Customizations

(defgroup irony-eldoc nil
  "eldoc support in `irony-mode'.

eldoc is a built-in emacs mode for displaying documentation about
a symbol or function call at point in the message buffer (see
`eldoc-mode')."
  :group 'irony)

(defcustom irony-eldoc-strip-underscores
  t
  "In a type, strip leading underscores from all identifiers.

Many common types, especially in the standard library in c++,
have these underscores, which carry no extra information."
  :group 'irony-eldoc
  :type 'boolean)

(defcustom irony-eldoc-use-unicode
  nil
  "If non-nil, use Unicode characters ∷ and ⇒ instead of :: and
=> in eldoc messages."
  :group 'irony-eldoc
  :type 'boolean)

;; }}}
;; {{{ Utilities

(defun irony-eldoc--strip-underscores (string)
  "Strip leading underscores from all identifiers in STRING.

It also prettifies the string by replacing things like \"::\"
with their Unicode equivalents, if `irony-eldoc-use-unicode' is
non-nil.

Has no effect if `irony-eldoc-strip-underscores' is non-nil."
  (if (or (not string) (not irony-eldoc-strip-underscores))
      string
    (let ((new-string string)
          (regexps (if irony-eldoc-use-unicode
                       '(("\\_<_+" . "") ("::" . "∷"))
                     '(("\\_<_+" . "")))))
      (dolist (r regexps)
        (setq new-string
              (replace-regexp-in-string (car r) (cdr r) new-string)))
      new-string)))

(defvar irony-eldoc--ignore-symbol-regex
  (rx string-start
      (or
       (and (1+ digit) (opt "e" (opt (1+ digit))))
       (or ;; Taken from `cc-langs'
        "bool" "char" "wchar_t" "short" "int" "long" "signed" "unsigned"
        "float" "double" "void" "_Bool" "_Complex" "_Imaginary"
        "id" "Class" "SEL" "IMP" "BOOL" "struct" "union" "enum"
        "class" "typename" "const" "restrict" "volatile" "throw"
        "@interface" "@implementation" "@protocol"
        "namespace" "extern" "auto" "extern" "inline" "register" "static"
        "explicit" "friend" "mutable" "template" "using" "virtual"
        "auto" "bycopy" "byref" "extern" "in" "inout" "oneway" "out" "static"
        "@class" "@end" "@defs"
        "__attribute__" "__declspec"
        "private" "protected" "public"
        "@private" "@protected" "@public"
        "struct" "union" "enum" "typedef"
        "class" "struct" "union" "enum" "typedef"
        "operator" "@class"
        "template"
        "do" "else" "try" "@finally" "@try"
        "for" "if" "switch" "while" "catch" "@catch" "@synchronized"
        "break" "continue" "goto" "return" "@throw"
        "asm" "__asm__"
        "case" "default"
        "goto" "break" "continue"
        "NULL" "nullptr" "false" "true"
        "nil" "Nil" "YES" "NO" "NS_DURING" "NS_HANDLER" "NS_ENDHANDLER"
        "operator" "this" "super" "self"))
      string-end)
  "Regex for identifiers that irony-eldoc should ignore entirely.

This is primitive types, common types, common values (NULL, true,
false), various keywords that may appear sometimes but for which
there should be no documentation.")

(defun irony-eldoc--which-symbol ()
  "Return a symbol under point suitable for documentation."
  ;; Require that char-after should be word-/symbol-constituent
  (let (bounds thing)
    (when (and (let ((s (car (syntax-after (point)))))
                 (and s (or (= s 2) (= s 3)))) ; Note that s can be nil
               (setq bounds (bounds-of-thing-at-point 'symbol))
               (setq thing (buffer-substring-no-properties
                            (car bounds) (cdr bounds)))
               ;; Check thing is not a built-in type or something useless
               (not (string-match-p irony-eldoc--ignore-symbol-regex thing)))
      (list nil thing (car bounds) (cdr bounds)))))

(defun irony-eldoc--argindex (&optional pos open-paren close-paren)
  "Return the index of the argument at POS inside parentheses.

Returns cons pair '(argindex . argcount), with 0 <= argindex < argcount.

OPEN-PAREN and CLOSE-PAREN are assumed to be balanced parens with everything balanced inside them as well."
  (unless pos (setq pos (point)))
  (unless open-paren
    (save-excursion
      (backward-up-list)
      (setq open-paren (point))
      (forward-list)
      (setq close-paren (point))))
  (let ((argindex 0) (argcount 1))
    (save-excursion
      (goto-char (1+ open-paren))
      (while (< (point) close-paren)
        (skip-syntax-forward "w_-" close-paren)
        (while (and (< (point) close-paren)
                    ;; open paren of any kind
                    (= (car (syntax-after (point))) 4))
          ;; works for any balanced group, not just parens
          (forward-list))
        (when (= (char-after) ?,)
          (when (< (point) pos) (cl-incf argindex))
          (cl-incf argcount))
        (forward-char)))
    ;; Add the number of template arguments to argcount
    (save-excursion
      (goto-char open-paren)
      (when (= (char-before) ?>)
        (let (template-count open-template (close-template (point)))
          (backward-list)
          (setq open-template (point)
                template-count
                (cdr (irony-eldoc--argindex
                      (point) open-template close-template)))
          (setq argcount (+ argcount template-count)
                argindex (+ argindex template-count)))))
    (cons argindex argcount)))

(defun irony-eldoc--which-funcall ()
  "Return description of surrounding function call,

suitable for `irony-eldoc--which-thing'.  Throws an
error (scan-error) on any unrecognized syntax, so probably call
inside `condition-case'."
  (let (bounds thing (old-point (point)) open-paren close-paren)
    (save-excursion
      ;; the escape-strings argument is not present in 24.4
      ;; (backward-up-list nil t) ; escape strings
      ;; if inside a string, move out of the string first
      (let ((syntax (syntax-ppss)))
        (when (nth 3 syntax) (goto-char (nth 8 syntax))))
      (backward-up-list)
      (when
          (and (= (char-after) #x28)    ; open paren
               (setq open-paren (point)
                     close-paren (save-excursion (forward-list) (point)))
               ;; possibly skip across a template bracket
               (progn (when (= (char-before) ?>) (backward-list))
                      (skip-syntax-backward " ")
                      (thing-at-point 'symbol)))
        (setq bounds (bounds-of-thing-at-point 'symbol)
              thing (buffer-substring-no-properties
                     (car bounds) (cdr bounds)))))
    (when thing
      (list (irony-eldoc--argindex old-point open-paren close-paren)
            thing (car bounds) (cdr bounds)))))

(defun irony-eldoc--which-thing (&optional force-funcall)
  "Return the buffer substring and its bounds for which doc should be shown.

If FORCE-FUNCALL is non-nil, look for the symbol at the head of
the surrounding function call, otherwise try to guess if that's
appropriate.

Returns nil if there is nothing suitable under point.

Returns a list of the form

  (arg-index thing-string thing-start thing-end)

where arg-index is nil if doc should be displayed for the symbol
at point, or (argindex . argcount) if it is for the function call
surrounding point."
  (let* ((ppss (syntax-ppss (point)))
         ;; Do nothing inside strings and comments
         (in-string (nth 3 ppss))
         (in-comment (nth 4 ppss)))
    (unless in-comment
      (or (and (not force-funcall)
               (not in-string)
               (irony-eldoc--which-symbol))
          (condition-case nil
              (irony-eldoc--which-funcall)
            (scan-error nil))))))

;; }}}
;; {{{ Making displayed strings

(defun irony-eldoc--show-symbol (prop)
  "Return docstring for a given symbol.

The symbol is specified by PROP, which is an object taken from
`irony-completion-candidates'."
  ;; Show documentation for a symbol.
  ;; variable of type T: "variable => T"
  ;; void function(...): "function(...)"
  ;; T function(...): "function(...) => T"
  (let* ((name (propertize (irony-completion-typed-text prop)
                           'face
                           (if (string= "" (irony-completion-annotation prop))
                               'font-lock-variable-name-face
                             'font-lock-function-name-face)))
         (result-type (irony-completion-type prop))
         (post-completion-data
          (cons (irony-completion-post-comp-str prop)
                (irony-completion-post-comp-placeholders prop)))
         (has-result-type (not (string= "" result-type)))
         (arglist (car post-completion-data))
         (has-arglist (not (string= "" arglist)))
         (docstring (irony-completion-brief prop))
         (has-docstring (not (string= "" docstring))))
    (unless (string= "" docstring)
      (setq docstring (propertize docstring 'face 'variable-pitch))
      (setq docstring (concat "; " docstring)))
    (irony-eldoc--strip-underscores
     (cond
      (has-result-type
       (concat name arglist (if irony-eldoc-use-unicode " ⇒ " " => ") result-type docstring))
      ;; (not has-result-type) seems to happen to some macros,
      ;; in which case argument names can still be meaningful
      ((or has-arglist has-docstring)
       (concat name arglist docstring))
      (t
       nil)))))

(defun irony-eldoc--show-funcall (arg-index arg-count prop)
  "Return docstring for a given function call.

ARG-INDEX and ARG-COUNT specify the index of function argument to
be highlighted, and PROP is an object from
`irony-completion--candidates'."
  ;; Show documentation inside a function call
  (let* ((name (propertize (irony-completion-typed-text prop)
                           'face 'font-lock-function-name-face))
         ;; FIXME The result type is "void" for constructors
         (result-type (irony-completion-type prop))
         (has-result-type (not (string= "" result-type)))
         (post-completion-data
          (cons (irony-completion-post-comp-str prop)
                (irony-completion-post-comp-placeholders prop)))
         (arglist (car post-completion-data))
         (has-arguments (not (string= "" arglist)))
         (docstring (irony-completion-brief prop))
         (has-docstring (not (string= "" docstring))))
    (when has-docstring
      (setq docstring (propertize docstring 'face 'variable-pitch))
      (setq docstring (concat "; " docstring)))
    (when (and has-arguments
               (>= (length post-completion-data)
                  (1+ (* 2 arg-count))))
      (let ((from (nth (+ 1 (* 2 arg-index)) post-completion-data))
            (to (nth (+ 2 (* 2 arg-index)) post-completion-data)))
        (setq arglist
              (concat (substring arglist 0 from)
                      (propertize (substring arglist from to)
                                  'face 'eldoc-highlight-function-argument)
                      (substring arglist to)))))
    (irony-eldoc--strip-underscores
     (if (or has-result-type has-docstring)
         (concat name arglist (if irony-eldoc-use-unicode " ⇒ " " => ") result-type docstring)
       (concat name arglist)))))

;; }}}
;; {{{ eldoc support

(defun irony-eldoc--callback (thing candidates &optional continuation)
  "Store found documentation in an overlay on THING,
for use by future calls to `irony-eldoc-documentation-function'.

THING is expected to be of the form

  (thing-string thing-start thing-end)

where the symbol between thing-start and thing-end should have
its documentation stored.

Once this is done, CONTINUATION will be called."
  ;; (message "irony-eldoc--callback %s: %d candidates" thing (length irony-completion--candidates))
  (let ((current-thing (buffer-substring-no-properties (nth 1 thing) (nth 2 thing)))
        (matches
         (cl-remove-if-not
          (lambda (x) (equal (car x) (car thing)))
          ;; FIXME This really should be (irony-completion-candidates)
          ;; but that function looks at (point) to see if completion
          ;; context is the same, so we use the internal irony-mode variable.
          candidates)))
    (when (equal current-thing (car thing))
      (let ((o (make-overlay (nth 1 thing) (nth 2 thing))))
        (overlay-put o 'category 'irony-eldoc)
        (overlay-put o 'irony-eldoc matches))
      (funcall continuation))))

(defun irony-eldoc-documentation-function (&optional only-use-cached)
  "Support for eldoc in function `irony-mode'.

See `eldoc-documentation-function' for what this function is
supposed to do.

If ONLY-USE-CACHED is non-nil, only look at cached documentation."
  (let* ((in-string (nth 3 (syntax-ppss)))
         ;; If inside a string, look for a surrounding function call.
         (thing (irony-eldoc--which-thing in-string))
         ;; Previous lookups of documentation are stored in char property
         ;; 'irony-eldoc (which belongs to an overlay on top of the symbol).
         (has-props (and thing (nth 2 thing)
                       (cl-remove-if-not
                        (lambda (o) (eq (overlay-get o 'category) 'irony-eldoc))
                        (overlays-at (nth 2 thing)))))
         ;; props can be nil if there were no candidates
         (props (and thing (get-char-property (nth 2 thing) 'irony-eldoc))))
    ;; (dolist (p props) (message "%s" (prin1-to-string p)))
    (cond
     ((not thing) nil)

     ;; Here each element of props is an object that came from
     ;; `irony-completion-candidates' that matches the symbol whose
     ;; information needs to be displayed.
     ((and props (not (car thing)))
      (let ((matching-docstrings
             (cl-remove-if-not
              #'identity (mapcar #'irony-eldoc--show-symbol props))))
        (when matching-docstrings
          (mapconcat #'identity matching-docstrings ";; "))))

     ;; For a function call there will often be many different matches
     ;; in `irony-completion-candidates', so here we select all of
     ;; them that have the same number of arguments.
     ;; FIXME This doesn't distinguish between template and function arguments.
     (props
      (let* ((arg-index (caar thing))
             (arg-count (cdar thing))
             (matching-props
              ;; Matching function calls with the right number of arguments
              (cl-remove-if-not
               (lambda (it) (= (length (nth 6 it)) (1+ (* 2 arg-count))))
               props))
             (docstring (mapconcat
                         (apply-partially
                          #'irony-eldoc--show-funcall arg-index arg-count)
                         matching-props
                         ";; ")))
        (unless (string= "" docstring) docstring)))

     ;; If there is no cached doc, a request is made, which may or may
     ;; not return immediately.
     ((not (or has-props only-use-cached))
      (save-excursion
        (goto-char (nth 3 thing))
        (let ((callback-thing (cdr thing))
              (async-flag nil)
              (matches-available nil))
          ;; Sometimes the callback is called immediately, and
          ;; sometimes it is called later. Both cases need to be
          ;; handled properly.
          (irony-completion-candidates-async
           (lambda (candidates)
             (irony-eldoc--callback
              callback-thing
              candidates
              (lambda () (if async-flag
                             (eldoc-print-current-symbol-info)
                           (setq matches-available t))))))
          (setq async-flag t)
          (when matches-available
            (irony-eldoc-documentation-function t))))))))

;; }}}
;; {{{ Minor mode

(defun irony-eldoc-reset ()
  "Reset information used by `irony-eldoc'.

Can be helpful is `irony-eldoc' starts displaying stale un-updated
information."
  (interactive)
  (remove-overlays (point-min) (point-max) 'category 'irony-eldoc))

;;;###autoload
(define-minor-mode irony-eldoc
  "Eldoc support in irony-mode.

eldoc is a built-in Emacs mode for displaying documentation about
a symbol or function call at point in the message buffer (see
`eldoc-mode').

To use:

- Enable the minor mode `irony-eldoc', as well as
  `eldoc-mode'. For an example, place point on top of a symbol,
  or inside a function call.

- It is easiest to add `irony-eldoc' to `irony-mode-hook', if you
  already have `irony-mode' set up.

Notes:

- Sometimes the information `irony-eldoc' uses can go out of
  date. In that case, try calling `irony-eldoc-reset'."
  :group 'irony
  ;; FIXME This deletes documentation overlays not conservatively enough
  ;; There are more changes. that can make an overlay invalid.
  (let ((hook (lambda (o _beforep _start _end &optional _change-length)
                (delete-overlay o))))
    (put 'irony-eldoc 'modification-hooks (list hook))
    (put 'irony-eldoc 'insert-in-front-hooks (list hook))
    (put 'irony-eldoc 'insert-behind-hooks (list hook)))
  (cond
   (irony-eldoc
    (setq-local eldoc-documentation-function
                #'irony-eldoc-documentation-function)
    (unless eldoc-mode (eldoc-mode)))
   (t
    (when (eq eldoc-documentation-function
              #'irony-eldoc-documentation-function)
      (setq-local eldoc-documentation-function #'ignore)))))

;; }}}

(provide 'irony-eldoc)
;; Local Variables:
;; coding: utf-8
;; End:
;;; irony-eldoc.el ends here
