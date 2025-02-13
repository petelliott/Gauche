;;;
;;; gauche.cgen.standalone - Create standalone binary
;;;
;;;   Copyright (c) 2014-2022  Shiro Kawai  <shiro@acm.org>
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

(define-module gauche.cgen.standalone
  (use gauche.cgen)
  (use gauche.config)
  (use gauche.process)
  (use srfi-13)
  (use srfi-42)
  (use file.util)
  (export build-standalone)
  )
(select-module gauche.cgen.standalone)

(define (build-standalone srcfile :key (outfile #f)
                                       (extra-files '())
                                       (include-dirs '())
                                       (cpp-definitions '())
                                       (keep-c-file #f)
                                       (header-dirs '())
                                       (library-dirs '()))
  (receive (placeholder out.c)
      (generate-c-file srcfile (append include-dirs '(".")) extra-files)
    (unwind-protect
        (compile-c-file out.c
                        (or outfile (path-sans-extension (sys-basename srcfile)))
                        (map (^d #"-D\"~|d|\"") cpp-definitions)
                        (map (^d #"-I\"~|d|\"") header-dirs)
                        (map (^d #"-L\"~|d|\"") library-dirs))
      (unless keep-c-file (sys-unlink out.c))
      (sys-unlink placeholder))))

;; This creates an empty file that reserve the temporary name, and the actual
;; C file.  Returns two names.
(define (generate-c-file file incdirs extras)
  (define outname
    (receive (oport name) (sys-mkstemp (path-sans-extension (sys-basename file)))
      (close-port oport)
      name))
  (parameterize ([cgen-current-unit
                  (make <cgen-unit>
                    :name outname
                    :preamble "/* Generated by build-standalone */"
                    :init-prologue "int main (int argc, const char *argv[]) {"
                    :init-epilogue "}")])
    (cgen-decl "#include <gauche/static.h>"
               "#include <gauche.h>")
    (cgen-decl (format "const char *main_script = ~a;"
                       (cgen-safe-string (file->string file))))
    (cgen-init "SCM_INIT_STATIC();")
    (unless (null? extras)
      (setup-library-table incdirs extras))
    (cgen-init "Scm_SimpleMain(argc, argv, main_script, 0);")
    (cgen-emit-c (cgen-current-unit)))
  (values outname (path-swap-extension outname "c")))

(define (setup-library-table incdirs extras)
  (define setup-code
    `(let1 tab (make-hash-table 'equal?)
       ,@(list-ec
          [: x extras]
          (if-let1 f (find-file-in-paths x :paths incdirs :pred file-exists?)
            `(hash-table-put! tab ,x ,(file->string f))
            (error "Can't find library file:" x)))
       (add-embedded-code-loader! tab)))
  (cgen-decl (format "const char *setup_libraries = ~a;"
                     (cgen-safe-string (write-to-string setup-code))))
  (cgen-init "Scm_EvalCString(setup_libraries, SCM_OBJ(Scm_GaucheModule()),"
             "                NULL);"))

(define (get-libs xdefs)
  (let* ([libs (gauche-config "--static-libs")]
         [libs (if (any #/^-D(=|\s*)\"?GAUCHE_STATIC_EXCLUDE_GDBM\"?/ xdefs)
                 (regexp-replace-all #/-lgdbm(_compat)?/ libs "")
                 libs)]
         [libs (if (any #/^-D(=|\s*)\"?GAUCHE_STATIC_EXCLUDE_MBEDTLS\"?/ xdefs)
                 (regexp-replace-all #/-lmbed\w*/ libs "")
                 libs)])
    libs))

;; Darwin's ld doesn't like that nonexistent directory is given to
;; -L flag.  The warning message is annoying, so we filter out such flags.
(define (exclude-nonexistent-dirs dir-flags)
  (define (existing-dir? flag)
    (if-let1 m (#/^-[IL]/ flag)
      (and (file-exists? (rxmatch-after m)) flag)
      flag))
  ($ string-join
     (filter-map existing-dir? (shell-tokenize-string dir-flags))
     " "))

(define (compile-c-file c-file outfile xdefs xincdirs xlibdirs)
  ;; TODO: We wish we could use gauche.package.compile, but currently it is
  ;; specialized to compile extension modules.  Eventually we will modify
  ;; the module so that this function can be just a one-liner
  (let ([cc (gauche-config "--cc")]
        [cflags (gauche-config "--so-cflags")]
        [defs    (string-join xdefs " ")]
        [incdirs (exclude-nonexistent-dirs
                  (string-join `(,@xincdirs ,(gauche-config "-I")) " "))]
        [libdirs (exclude-nonexistent-dirs
                  (string-join `(,@xlibdirs ,(gauche-config "-L")) " "))]
        [libs    (get-libs xdefs)])
    (let1 cmd #"~cc ~cflags ~defs ~incdirs -o ~outfile ~c-file ~libdirs ~libs"
      (print cmd)
      (sys-system cmd))))
