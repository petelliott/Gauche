(use gauche.test)
(use gauche.process)
(use gauche.version)
(use file.util)

(test-start "rfc.tls")

(use rfc.tls)
(test-module 'rfc.tls)
(use rfc.tls.mbed)
(test-module 'rfc.tls.mbed)


(cond-expand
 ;; ssltest program needs thread support, so we don't build it if we don't
 ;; have threads.
 [(and gauche.net.tls.axtls gauche.sys.threads)
  ;; Run ssltest program for sanity-check of axTLS build.
  ;; Some tests requires openssl command.  We've checked its availability
  ;; in toplevel configure.
  ;; NB: We assume we're running in $top_builddir/ext/tls.
  (define openssl-cmd
    (and-let1 m (any #/S\["OPENSSL"\]=\"(.+)\"/
                     (file->string-list "../../config.status"))
      (m 1)))
  (define (no-openssl msg)
    (warn #"~|msg|: some tests are skipped.\n")
    (set! openssl-cmd #f))

  (sys-unlink "axTLS/ssl/openssl.pid")
  (sys-unlink "kick_openssl.sh")

  (if (not openssl-cmd)
    (no-openssl "openssl command not available")
    ;; Check openssl version.  OSX and MinGW32 ship with old openssl
    ;; that's unusable.
    (guard (e [(<process-abnormal-exit> e)
               (no-openssl "couldn't run openssl command")])
      (if-let1 m ($ #/(?:OpenSSL|LibreSSL)\s+([\d\.]+\w*)/
                    $ process-output->string
                      (cond-expand
                       ;; for MSYS (mintty)
                       [gauche.os.windows `("cmd.exe" "/c" ,openssl-cmd "version")]
                       [else              `(,openssl-cmd "version")]))
        (let1 vers (m 1)
          (unless (version>=? vers "1.0.1")
            (no-openssl #"openssl version is too old (~vers)")))
        (no-openssl "couldn't get openssl version"))))

  (when openssl-cmd
    (with-output-to-file "kick_openssl.sh"
      (^[]
        (print "#!/bin/sh")
        (print "set -e")
        (print #"echo \"$$\" \"~|openssl-cmd|\" >> openssl.pid")
        (cond-expand
         [gauche.os.windows
          ;; MinGW's openssl.exe needs winpty only when stdin is terminal.
          ;; (MSYS's openssl.exe doesn't need this workaround.)
          (print  "mingw_workaround=no")
          (print  "case \"$MSYSTEM\" in")
          (print  "    MINGW64|MINGW32)")
          (print #"        if echo `/usr/bin/which \"~|openssl-cmd|\" || :` | grep -q -E \"/mingw(64|32)\"; then")
          (print  "            mingw_workaround=yes")
          (print  "        fi;;")
          (print  "esac")
          (print  "if [ \"$mingw_workaround\" = yes -a -t 0 ]; then")
          (print #"    exec winpty -Xallow-non-tty -Xplain \"~|openssl-cmd|\" \"$@\"")
          (print  "else")
          (print #"    exec \"~|openssl-cmd|\" \"$@\"")
          (print  "fi")]
         [else
          (print #"exec \"~|openssl-cmd|\" \"$@\"")])))
    (sys-chmod "kick_openssl.sh" #o755))

  (test* "ssltest" 0
         (process-exit-status
          (run-process `(./ssltest
                         ,@(cond-list [openssl-cmd "--exttest"]))
                       :directory "axTLS/ssl"
                       :output "ssltest.log"
                       :wait #t)))

  ;; On MSYS (mintty), winpty with '-Xallow-non-tty' option changes tty
  ;; setting so that we should reset it.
  (cond-expand
   [gauche.os.windows (sys-system "stty sane")]
   [else])
  ]
 [else])



(test-end)
