;;
;; This file is loaded when we generate some files using host's Gauche that
;; are required to build target's Gauche.    The issue is that some libraries
;; required to run the generator program may be compiled DSOs, and those
;; DSOs in ./src compiled for target's Gauche may be incompatible with
;; host's Gauche.   So we 'preload' those compiled libraries from the host
;; enviroment before we add ./src and ./lib to the *load-path*, i.e.:
;;
;;  gosh -l./preload -I./src -I./lib ....
;;

(use gauche.collection)
(use gauche.sequence)
(use gauche.dictionary)
(use gauche.hook)
(use gauche.uvector)
(use gauche.regexp)
(use gauche.record)
(use gauche.generator)
(use gauche.interpolate)
(use gauche.process)
(cond-expand
 [gauche-0.9.9 (use gauche.stringutil) (use gauche.portutil)]
 [else])
(use gauche.threads)
(cond-expand
 [gauche-0.9.10 (use srfi-1)]
 [else (use scheme.list)])
(use srfi-13)
(use file.util)
(use text.tr)
(use util.match)
(use rfc.822)
(use rfc.mime)
