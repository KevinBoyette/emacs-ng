;;; cl-preloaded.el --- Preloaded part of the CL library  -*- lexical-binding: t; -*-

;; Copyright (C) 2015-2022  Free Software Foundation, Inc

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>
;; Package: emacs

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The cl-defstruct macro is full of circularities, since it uses the
;; cl-structure-class type (and its accessors) which is defined with itself,
;; and it setups a default parent (cl-structure-object) which is also defined
;; with cl-defstruct, and to make things more interesting, the class of
;; cl-structure-object is of course an object of type cl-structure-class while
;; cl-structure-class's parent is cl-structure-object.
;; Furthermore, the code generated by cl-defstruct generally assumes that the
;; parent will be loaded when the child is loaded.  But at the same time, the
;; expectation is that structs defined with cl-defstruct do not need cl-lib at
;; run-time, which means that the `cl-structure-object' parent can't be in
;; cl-lib but should be preloaded.  So here's this preloaded circular setup.

;;; Code:

(eval-when-compile (require 'cl-lib))
(eval-when-compile (require 'cl-macs))  ;For cl--struct-class.

;; The `assert' macro from the cl package signals
;; `cl-assertion-failed' at runtime so always define it.
(define-error 'cl-assertion-failed (purecopy "Assertion failed"))

(defun cl--assertion-failed (form &optional string sargs args)
  (if debug-on-error
      (funcall debugger 'error `(cl-assertion-failed (,form ,string ,@sargs)))
    (if string
        (apply #'error string (append sargs args))
      (signal 'cl-assertion-failed `(,form ,@sargs)))))

(defconst cl--typeof-types
  ;; Hand made from the source code of `type-of'.
  '((integer number number-or-marker atom)
    (symbol atom) (string array sequence atom)
    (cons list sequence)
    ;; Markers aren't `numberp', yet they are accepted wherever integers are
    ;; accepted, pretty much.
    (marker number-or-marker atom)
    (overlay atom) (float number atom) (window-configuration atom)
    (process atom) (window atom)
    ;; FIXME: We'd want to put `function' here, but that's only true
    ;; for those `subr's which aren't special forms!
    (subr atom)
    ;; FIXME: We should probably reverse the order between
    ;; `compiled-function' and `byte-code-function' since arguably
    ;; `subr' and also "compiled functions" but not "byte code functions",
    ;; but it would require changing the value returned by `type-of' for
    ;; byte code objects, which risks breaking existing code, which doesn't
    ;; seem worth the trouble.
    (compiled-function byte-code-function function atom)
    (module-function function atom)
    (buffer atom) (char-table array sequence atom)
    (bool-vector array sequence atom)
    (frame atom) (hash-table atom) (terminal atom)
    (thread atom) (mutex atom) (condvar atom)
    (font-spec atom) (font-entity atom) (font-object atom)
    (vector array sequence atom)
    (user-ptr atom)
    ;; Plus, really hand made:
    (null symbol list sequence atom))
  "Alist of supertypes.
Each element has the form (TYPE . SUPERTYPES) where TYPE is one of
the symbols returned by `type-of', and SUPERTYPES is the list of its
supertypes from the most specific to least specific.")

(defconst cl--all-builtin-types
  (delete-dups (copy-sequence (apply #'append cl--typeof-types))))

(defun cl--struct-name-p (name)
  "Return t if NAME is a valid structure name for `cl-defstruct'."
  (and name (symbolp name) (not (keywordp name))
       (not (memq name cl--all-builtin-types))))

;; When we load this (compiled) file during pre-loading, the cl--struct-class
;; code below will need to access the `cl-struct' info, since it's considered
;; already as its parent (because `cl-struct' was defined while the file was
;; compiled).  So let's temporarily setup a fake.
(defvar cl-struct-cl-structure-object-tags nil)
(unless (cl--find-class 'cl-structure-object)
  (setf (cl--find-class 'cl-structure-object) 'dummy))

(fset 'cl--make-slot-desc
      ;; To break circularity, we pre-define the slot constructor by hand.
      ;; It's redefined a bit further down as part of the cl-defstruct of
      ;; cl-slot-descriptor.
      ;; BEWARE: Obviously, it's important to keep the two in sync!
      (lambda (name &optional initform type props)
        (record 'cl-slot-descriptor
                name initform type props)))

(defun cl--struct-get-class (name)
  (or (if (not (symbolp name)) name)
      (cl--find-class name)
      (if (not (get name 'cl-struct-type))
          ;; FIXME: Add a conversion for `eieio--class' so we can
          ;; create a cl-defstruct that inherits from an eieio class?
          (error "%S is not a struct name" name)
        ;; Backward compatibility with a defstruct compiled with a version
        ;; cl-defstruct from Emacs<25.  Convert to new format.
        (let ((tag (intern (format "cl-struct-%s" name)))
              (type-and-named (get name 'cl-struct-type))
              (descs (get name 'cl-struct-slots)))
          (cl-struct-define name nil (get name 'cl-struct-include)
                            (unless (and (eq (car type-and-named) 'vector)
                                         (null (cadr type-and-named))
                                         (assq 'cl-tag-slot descs))
                              (car type-and-named))
                            (cadr type-and-named)
                            descs
                            (intern (format "cl-struct-%s-tags" name))
                            tag
                            (get name 'cl-struct-print))
          (cl--find-class name)))))

(defun cl--plist-to-alist (plist)
  (let ((res '()))
    (while plist
      (push (cons (pop plist) (pop plist)) res))
    (nreverse res)))

(defun cl--struct-register-child (parent tag)
  ;; Can't use (cl-typep parent 'cl-structure-class) at this stage
  ;; because `cl-structure-class' is defined later.
  (while (recordp parent)
    (add-to-list (cl--struct-class-children-sym parent) tag)
    ;; Only register ourselves as a child of the leftmost parent since structs
    ;; can only only have one parent.
    (setq parent (car (cl--struct-class-parents parent)))))

;;;###autoload
(defun cl-struct-define (name docstring parent type named slots children-sym
                              tag print)
  (cl-check-type name cl--struct-name)
  (unless type
    ;; Legacy defstruct, using tagged vectors.  Enable backward compatibility.
    (cl-old-struct-compat-mode 1))
  (if (eq type 'record)
      ;; Defstruct using record objects.
      (setq type nil))
  (cl-assert (or type (not named)))
  (if (boundp children-sym)
      (add-to-list children-sym tag)
    (set children-sym (list tag)))
  (and (null type) (eq (caar slots) 'cl-tag-slot)
       ;; Hide the tag slot from "standard" (i.e. non-`type'd) structs.
       (setq slots (cdr slots)))
  (let* ((parent-class (when parent (cl--struct-get-class parent)))
         (n (length slots))
         (index-table (make-hash-table :test 'eq :size n))
         (vslots (let ((v (make-vector n nil))
                       (i 0)
                       (offset (if type 0 1)))
                   (dolist (slot slots)
                     (let* ((props (cl--plist-to-alist (cddr slot)))
                            (typep (assq :type props))
                            (type (if (null typep) t
                                    (setq props (delq typep props))
                                    (cdr typep))))
                       (aset v i (cl--make-slot-desc
                                  (car slot) (nth 1 slot)
                                  type props)))
                     (puthash (car slot) (+ i offset) index-table)
                     (cl-incf i))
                   v))
         (class (cl--struct-new-class
                 name docstring
                 (unless (symbolp parent-class) (list parent-class))
                 type named vslots index-table children-sym tag print)))
    (unless (symbolp parent-class)
      (let ((pslots (cl--struct-class-slots parent-class)))
        (or (>= n (length pslots))
            (let ((ok t))
              (dotimes (i (length pslots))
                (unless (eq (cl--slot-descriptor-name (aref pslots i))
                            (cl--slot-descriptor-name (aref vslots i)))
                  (setq ok nil)))
              ok)
            (error "Included struct %S has changed since compilation of %S"
                   parent name))))
    (add-to-list 'current-load-list `(define-type . ,name))
    (cl--struct-register-child parent-class tag)
    (unless (or (eq named t) (eq tag name))
      ;; We used to use `defconst' instead of `set' but that
      ;; has a side-effect of purecopying during the dump, so that the
      ;; class object stored in the tag ends up being a *copy* of the
      ;; one stored in the `cl--class' property!  We could have fixed
      ;; this needless duplication by using the purecopied object, but
      ;; that then breaks down a bit later when we modify the
      ;; cl-structure-class class object to close the recursion
      ;; between cl-structure-object and cl-structure-class (because
      ;; modifying purecopied objects is not allowed.  Since this is
      ;; done during dumping, we could relax this rule and allow the
      ;; modification, but it's cumbersome).
      ;; So in the end, it's easier to just avoid the duplication by
      ;; avoiding the use of the purespace here.
      (set tag class)
      ;; In the cl-generic support, we need to be able to check
      ;; if a vector is a cl-struct object, without knowing its particular type.
      ;; So we use the (otherwise) unused function slots of the tag symbol
      ;; to put a special witness value, to make the check easy and reliable.
      (fset tag :quick-object-witness-check))
    (setf (cl--find-class name) class)))

(cl-defstruct (cl-structure-class
               (:conc-name cl--struct-class-)
               (:predicate cl--struct-class-p)
               (:constructor nil)
               (:constructor cl--struct-new-class
                (name docstring parents type named slots index-table
                      children-sym tag print))
               (:copier nil))
  "The type of CL structs descriptors."
  ;; The first few fields here are actually inherited from cl--class, but we
  ;; have to define this one before, to break the circularity, so we manually
  ;; list the fields here and later "backpatch" cl--class as the parent.
  ;; BEWARE: Obviously, it's indispensable to keep these two structs in sync!
  (name nil :type symbol)               ;The type name.
  (docstring nil :type string)
  (parents nil :type (list-of cl--class)) ;The included struct.
  (slots nil :type (vector cl-slot-descriptor))
  (index-table nil :type hash-table)
  (tag nil :type symbol) ;Placed in cl-tag-slot.  Holds the struct-class object.
  (type nil :type (memq (vector list)))
  (named nil :type bool)
  (print nil :type bool)
  (children-sym nil :type symbol) ;This sym's value holds the tags of children.
  )

(cl-defstruct (cl-structure-object
               (:predicate cl-struct-p)
               (:constructor nil)
               (:copier nil))
  "The root parent of all \"normal\" CL structs")

(setq cl--struct-default-parent 'cl-structure-object)

(cl-defstruct (cl-slot-descriptor
               (:conc-name cl--slot-descriptor-)
               (:constructor nil)
               (:constructor cl--make-slot-descriptor
                (name &optional initform type props))
               (:copier cl--copy-slot-descriptor-1))
  ;; FIXME: This is actually not used yet, for circularity reasons!
  "Descriptor of structure slot."
  name                                  ;Attribute name (symbol).
  initform
  type
  ;; Extra properties, kept in an alist, can include:
  ;;  :documentation, :protection, :custom, :label, :group, :printer.
  (props nil :type alist))

(defun cl--copy-slot-descriptor (slot)
  (let ((new (cl--copy-slot-descriptor-1 slot)))
    (cl-callf copy-alist (cl--slot-descriptor-props new))
    new))

(cl-defstruct (cl--class
               (:constructor nil)
               (:copier nil))
  "Type of descriptors for any kind of structure-like data."
  ;; Intended to be shared between defstruct and defclass.
  (name nil :type symbol)               ;The type name.
  (docstring nil :type string)
  ;; For structs there can only be one parent, but when EIEIO classes inherit
  ;; from cl--class, we'll need this to hold a list.
  (parents nil :type (list-of cl--class))
  (slots nil :type (vector cl-slot-descriptor))
  (index-table nil :type hash-table))

(cl-assert
 (let ((sc-slots (cl--struct-class-slots (cl--find-class 'cl-structure-class)))
       (c-slots (cl--struct-class-slots (cl--find-class 'cl--class)))
       (eq t))
   (dotimes (i (length c-slots))
     (let ((sc-slot (aref sc-slots i))
           (c-slot (aref c-slots i)))
       (unless (eq (cl--slot-descriptor-name sc-slot)
                   (cl--slot-descriptor-name c-slot))
         (setq eq nil))))
   eq))

;; Close the recursion between cl-structure-object and cl-structure-class.
(setf (cl--struct-class-parents (cl--find-class 'cl-structure-class))
      (list (cl--find-class 'cl--class)))
(cl--struct-register-child
 (cl--find-class 'cl--class)
 (cl--struct-class-tag (cl--find-class 'cl-structure-class)))

(cl-assert (cl--find-class 'cl-structure-class))
(cl-assert (cl--find-class 'cl-structure-object))
(cl-assert (cl-struct-p (cl--find-class 'cl-structure-class)))
(cl-assert (cl-struct-p (cl--find-class 'cl-structure-object)))
(cl-assert (cl--class-p (cl--find-class 'cl-structure-class)))
(cl-assert (cl--class-p (cl--find-class 'cl-structure-object)))

(defun cl--class-allparents (class)
  (let ((parents ())
        (classes (list class)))
    ;; BFS precedence.  FIXME: Use a topological sort.
    (while (let ((class (pop classes)))
             (cl-pushnew (cl--class-name class) parents)
             (setq classes
                   (append classes
                           (cl--class-parents class)))))
    (nreverse parents)))

;; Make sure functions defined with cl-defsubst can be inlined even in
;; packages which do not require CL.  We don't put an autoload cookie
;; directly on that function, since those cookies only go to cl-loaddefs.
(autoload 'cl--defsubst-expand "cl-macs")
;; Autoload, so autoload.el and font-lock can use it even when CL
;; is not loaded.
(put 'cl-defun    'doc-string-elt 3)
(put 'cl-defmacro 'doc-string-elt 3)
(put 'cl-defsubst 'doc-string-elt 3)
(put 'cl-defstruct 'doc-string-elt 2)

(provide 'cl-preloaded)
;;; cl-preloaded.el ends here
