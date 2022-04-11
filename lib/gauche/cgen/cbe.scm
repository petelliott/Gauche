;;;
;;; gauche.cgen.cbe - C back-end
;;;
;;;   Copyright (c) 2022  Shiro Kawai  <shiro@acm.org>
;;;
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;

(define-module gauche.cgen.cbe
  (use gauche.cgen)
  (use gauche.cgen.bbb)
  (use gauche.vm.insn)
  (use scheme.list)
  (use srfi-13)
  (use util.match)
  (use text.tr)
  (export compile-b->c))
(select-module gauche.cgen.cbe)

(define (compile-b->c toplevel-benv)
  (parameterize ([cgen-current-unit (make <cgen-unit> :name "t")])
    (cgen-decl "#include <gauche.h>"
               "#include <gauche/precomp.h>")
    (benv->c toplevel-benv)
    (cgen-emit-c (cgen-current-unit))))

(define (benv->c benv)
  (for-each benv->c (~ benv'children))
  (for-each cluster->c (~ benv'clusters)))

(define (cluster->c cluster)
  (define cfn-name (cgen-safe-name (x->string (~ cluster'id))))
  (cgen-decl #"static ScmObj ~|cfn-name|(ScmObj*, int, void);")
  (cgen-body #"ScmObj ~|cfn-name|(ScmObj *ARGS, int ARGC, void *DATA)"
             #"{")
  (for-each block->c (reverse (~ cluster'blocks)))
  (cgen-body #"}"))

(define (block->c block)
  (cgen-body #"~(cgen-safe-name-friendly (bb-name block)):")
  (for-each insn->c (reverse (~ block'insns))))

(define (insn->c insn)
  (match insn
    [('MOV rd rs) (cgen-body #" ~(reg-cexpr rd) = ~(reg-cexpr rs);")]
    [('LD r id)   (let1 c-id (cgen-literal id)
                    (cgen-body
                     #" ~(reg-cexpr r) = /* ~(cgen-safe-comment (~ id'name)) */"
                     #"  Scm_IdentifierGlobalRef(~(cgen-cexpr c-id), NULL);"))]
    [('ST r id)   (let1 c-id (cgen-literal id)
                    (cgen-body
                     #" /* ~(cgen-safe-comment (~ id'name)) */"
                     #" Scm_GlobalVariableSet(~(cgen-cexpr c-id),"
                     #"                       ~(reg-cexpr r),"
                     #"                       NULL);"))]
    [('CLOSE r b) (cgen-body #" ~(reg-cexpr r) ="
                             #"   %%WRITEME%%Scm_MakeClosure ~(x->string b);")]
    [('BR r b1 b2)(cgen-body #" if (SCM_FALSEP(~(reg-cexpr r)))"
                             #"   goto ~(bb-name b1);"
                             #" else"
                             #"   goto ~(bb-name b2);")]
    [('JP b)      (cgen-body #" goto ~(bb-name b);")]
    [('CONT b)    (cgen-body #" %%WRITEME%%Scm_VMPushCC(~(x->string b));")]
    [('CALL bb proc r ...) (gen-vmcall proc r)]
    [('RET r . rs)(cgen-body #" return ~(reg-cexpr r);")]
    [('BUILTIN op r as ...)
     (cgen-body #" ~(reg-cexpr r) =") (builtin->c op as)]
    [('ASM op r as ...)
     (cgen-body #" ~(reg-cexpr r) =") (asm->c op as)]
    [('DEF id flags r)
     (let1 c-id (cgen-literal id)
       (cgen-body #" /* ~(cgen-safe-comment (~ id'name)) */"
                  #" Scm_Define(~(cgen-cexpr c-id), ~(reg-cexpr r));"))]
    ))

(define (gen-vmcall proc regs)
  (cgen-body #" return Scm_VMApply(~(reg-cexpr proc), ~(gen-list regs));"))

(define (c-call proc-cexpr regs)
  (string-concatenate `("  " ,proc-cexpr "("
                        ,@(intersperse ",\n    "
                                       (map reg-cexpr regs))
                        ");")))

(define (asm->c op regs)
  (case (~ (vm-find-insn-info (car op))'name)
    [(EQ) (cgen-body (c-call "SCM_EQ" regs))]
    [(NULLP) (cgen-body (c-call "SCM_NULLP" regs))]
    [(PAIRP) (cgen-body (c-call "SCM_PAIRP" regs))]
    [(CAR) (cgen-body (c-call "SCM_CAR" regs))]
    [(CDR) (cgen-body (c-call "SCM_CDR" regs))]
    [(CAAR) (cgen-body (c-call "SCM_CAAR" regs))]
    [(CADR) (cgen-body (c-call "SCM_CADR" regs))]
    [(CDAR) (cgen-body (c-call "SCM_CDAR" regs))]
    [(CDDR) (cgen-body (c-call "SCM_CDDR" regs))]
    [(REVERSE) (cgen-body (c-call "Scm_Reverse" regs))]
    [(NUMEQ2) (cgen-body (c-call "SCM_NUMEQ2" regs))]
    [(NUMLT2) (cgen-body (c-call "SCM_NUMLT2" regs))]
    [(NUMLE2) (cgen-body (c-call "SCM_NUMLE2" regs))]
    [(NUMGT2) (cgen-body (c-call "SCM_NUMGT2" regs))]
    [(NUMGE2) (cgen-body (c-call "SCM_NUMGE2" regs))]
    [(NUMADD2) (cgen-body (c-call "Scm_Add" regs))]
    [(NUMSUB2) (cgen-body (c-call "Scm_Sub" regs))]
    [(NUMNUL2) (cgen-body (c-call "Scm_Mul" regs))]
    [(NUMDIV2) (cgen-body (c-call "Scm_Div" regs))]
    [(NEGATE)  (cgen-body (c-call "Scm_Negate" regs))]
    [(LOGAND)  (cgen-body (c-call "Scm_LogAnd" regs))]
    [(LOGIOR)  (cgen-body (c-call "Scm_LogIor" regs))]
    [(LOGXOR)  (cgen-body (c-call "Scm_LogXor" regs))]
    [else
     (cgen-body #"  %%WRITEME%%Call_Asm(~op, ~(map reg-cexpr regs));")]))

(define (builtin->c op regs)
  (cgen-body #"  %%WRITEME%%Call_Builtin(~op, ~(map reg-cexpr regs));"))

(define (gen-list regs)
  (define (rec regs)
    (match regs
      [() '("SCM_NIL")]
      [(reg . regs) `("Scm_Cons(" ,(reg-cexpr reg) ", " ,@(rec regs) ")")]))
  (string-concatenate (rec regs)))

(define *constant-literals* (make-hash-table 'eq?)) ;; const -> <literal>

(define (reg-cexpr r)
  (if (is-a? r <reg>)
    (let1 m (#/^%(\d+)\.(\d+)(?:\.(.*))?/ (x->string (~ r'name)))
      (format "R~d_~d~a" (m 1) (m 2)
              (if-let1 name (m 3)
                #"_~(cgen-safe-name-friendly name)"
                "")))
    (let1 lit (or (hash-table-get *constant-literals* r #f)
                  (rlet1 lit (cgen-literal (const-value r))
                    (hash-table-put! *constant-literals* r lit)))
      (cgen-cexpr lit))))
