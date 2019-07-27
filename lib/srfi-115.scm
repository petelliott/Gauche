;;;
;;; SRFI-115  Scheme Regular Expressions
;;;

(define-module srfi-115
  (use scheme.charset)
  (use gauche.regexp.sre)
  (export rx regexp regexp->sre char-set->sre valid-sre?
          regexp-matches regexp-matches? regexp-search
          regexp-fold regexp-extract regexp-split regexp-partition
          regexp-replace regexp-replace-all
          regexp-match? regexp-match-count regexp-match-submatch
          regexp-match-submatch-start regexp-match-submatch-end
          regexp-match->list))
(select-module srfi-115)

(define-syntax rx
  (syntax-rules ()
    [(_ sre ...) (regexp `(: sre ...))]))

(define (regexp re)
  (if (regexp? re) re (regexp-compile-sre re)))

(define (regexp->sre re)
  (regexp-unparse-sre (regexp-ast re)))

(define (char-set->sre cs)
  (list (list->string (char-set->list cs))))

(define (valid-sre? sre)
  (guard (e [(<regexp-invalid-sre> e) #f][else (raise e)])
    (regexp-parse-sre sre)
    #t))

;; regexp? is already defined by gauche.regexp and is builtin.
;; do we even need to export it in pure R7RS environment?

(define (regexp-matches re str :optional start end)
  (if (regexp? re)
      (let1 match (regexp-search re str start end)
        (if (and match
                 (zero? (rxmatch-start match))
                 (eq? (rxmatch-end match)
                      (if (undefined? end)
                          (string-length str)
                          end)))
            match
            #f))
      ;; if re is not compiled yet, insert bos to take advantage of
      ;; BOL_ANCHORED optimization.
      (regexp-search `(: bos ,re eos) str start end)))

(define (regexp-matches? re str :optional start end)
  (if (regexp-matches re str start end) #t #f))

(define (regexp-search re str :optional start end)
  (rxmatch (regexp re) str start end))

(define (regexp-fold re kons knil str :optional finish start end)
  (cond
   [(undefined? finish)
    (regexp-fold re kons knil str (lambda (from match str acc)
                                    acc))]
   [(undefined? start)
    (regexp-fold re kons knil str finish 0)]
   [(undefined? end)
    (regexp-fold re kons knil str finish 0 (string-length str))]
   [(not (regexp? re))
    (regexp-fold (regexp re) kons knil str finish 0 end)]
   [else
    (let loop ([start start]
               [last-end start]
               [acc knil])
      (let1 match (and (< start end)
                       (regexp-search re str start end))
        (cond
         [(not match)
          (finish last-end #f str acc)]
         [(eq? start (rxmatch-end match)) ; empty match, try again
          (loop (+ start 1) last-end acc)]
         [else
          (loop (rxmatch-end match)
                (rxmatch-end match)
                (kons last-end match str acc))])))]))

(define (regexp-extract re str . opt)
  (apply regexp-fold re
         (lambda (i match str acc)
           (if (equal? (match 0) "")
               acc
               (cons (match 0) acc)))
         '()
         str
         (lambda (i match str acc)
           (reverse acc))
         opt))

(define (regexp-split rx str . o)
  ;; start and end in indices passed to regexp-fold
  (let ((start (if (pair? o) (car o) 0))
        (end (if (and (pair? o) (pair? (cdr o)))
                 (cadr o)
                 (string-length str))))
    (regexp-fold rx
                 (lambda (from md str a)
                   (let ((i (regexp-match-submatch-start md 0))
                         (j (regexp-match-submatch-end md 0)))
                     (if (eqv? i j)
                         a
                         (cons j
                               (cons (substring str (car a) i)
                                     (cdr a))))))
                 (cons start '())
                 str
                 (lambda (from md str a)
                   (reverse
                    (cons (substring str (car a) end)
                          (cdr a))))
                 start
                 end)))

(define (regexp-partition rx str . o)
  (let ((start (if (pair? o) (car o) 0))
        (end (if (and (pair? o) (pair? (cdr o)))
                 (cadr o)
                 (string-length str))))
    (define (kons from md str a)
      (let ((i (regexp-match-submatch-start md 0))
            (j (regexp-match-submatch-end md 0)))
        (if (eqv? i j)
            a
            (let ((left (substring str (car a) i)))
              (cons j
                    (cons (regexp-match-submatch md 0)
                          (cons left (cdr a))))))))
    (define (final from md str a)
      (if (or (< from end)
              (null? (cdr a)))
          (cons (substring str (car a) end) (cdr a))
          (cdr a)))
    (reverse
     (regexp-fold rx
                  kons
                  (cons start '())
                  str
                  final
                  start
                  end))))

(define regexp-replace #f)
(define regexp-replace-all #f)

(define regexp-match? regmatch?)
(define regexp-match-count rxmatch-num-matches)
(define regexp-match-submatch rxmatch-substring)
(define regexp-match-submatch-start rxmatch-start)
(define regexp-match-submatch-end rxmatch-end)
(define regexp-match->list rxmatch-substrings)
