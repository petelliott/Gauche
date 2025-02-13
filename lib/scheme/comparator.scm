;; R7RS Large - Red edition

;; All of SRFI-128 features are built-in.  This module is just
;; for the namespace.

(define-module scheme.comparator
  (export comparator? comparator-ordered? comparator-hashable?

          make-comparator make-pair-comparator
          make-list-comparator make-vector-comparator
          make-eq-comparator make-eqv-comparator make-equal-comparator

          boolean-hash char-hash char-ci-hash string-hash
          string-ci-hash symbol-hash number-hash

          hash-bound hash-salt

          make-default-comparator default-hash
          comparator-register-default!

          comparator-type-test-predicate comparator-equality-predicate
          comparator-ordering-predicate comparator-hash-function
          comparator-test-type comparator-check-type comparator-hash

          =? <? >? <=? >=?

          comparator-if<=>)

  ;; srfi-162 adds a few more.
  (extend srfi-162))
