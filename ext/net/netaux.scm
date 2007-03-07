;;;
;;; netaux.scm - network interface
;;;  
;;;   Copyright (c) 2000-2007  Shiro Kawai  <shiro@acm.org>
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
;;;  $Id: netaux.scm,v 1.11 2007-03-07 04:37:41 shirok Exp $
;;;

(select-module gauche.net)
(use srfi-1)
(use gauche.sequence)
(use util.match)

;; default backlog value for socket-listen
(define-constant DEFAULT_BACKLOG 5)

;; NB: we can't use (cond-expand (gauche.net.ipv6 ...) ) here, since
;; cond-expand is expanded when netaux.scm is compiled, but at that time
;; the feature 'gauche.net.ipv6' is not available since the gauche.net module
;; is not yet built.  So we use a bit of kludge here.
(define ipv6-capable (global-variable-bound? 'gauche.net 'sys-getaddrinfo))

(define (make-sys-addrinfo . args)
  (if ipv6-capable
    (let-keywords args ((flags    0)
                        (family   |AF_UNSPEC|)
                        (socktype 0)
                        (protocol 0))
      (make <sys-addrinfo>
        :flags (if (list? flags) (apply logior flags) flags)
        :family family :socktype socktype :protocol protocol))
    (error "make-sys-addrinfo is available on IPv6-enabled platform")))

;; Utility
(define (address->protocol-family addr)
  (case (sockaddr-family addr)
    ((unix)  |PF_UNIX|)
    ((inet)  |PF_INET|)
    ((inet6) |PF_INET6|) ;;this can't happen if !ipv6-capable
    (else (error "unknown family of socket address" addr))))

;; High-level interface.  We need some hardcoded heuristics here.

(define (make-client-socket proto . args)
  (cond ((eq? proto 'unix)
         (let-optionals* args ((path #f))
           (unless (string? path)
             (error "unix socket requires pathname, but got" path))
           (make-client-socket-unix path)))
        ((eq? proto 'inet)
         (let-optionals* args ((host #f) (port #f))
           (unless (and (string? host) (or (integer? port) (string? port)))
             (errorf "inet socket requires host name and port, but got ~s and ~s"
                     host port))
           (make-client-socket-inet host port)))
        ((is-a? proto <sockaddr>)
         ;; caller provided sockaddr
         (make-client-socket-from-addr proto))
        ((and (string? proto)
              (pair? args)
              (integer? (car args)))
         ;; STk compatibility
         (make-client-socket-inet proto (car args)))
        (else
         (error "unsupported protocol:" proto))))

(define (make-client-socket-from-addr addr)
  (let1 socket (make-socket (address->protocol-family addr) |SOCK_STREAM|)
    (socket-connect socket addr)
    socket))

(define (make-client-socket-unix path)
  (let ((address (make <sockaddr-un> :path path))
        (socket  (make-socket |PF_UNIX| |SOCK_STREAM|)))
    (socket-connect socket address)
    socket))

(define (make-client-socket-inet host port)
  (let1 err #f
    (define (try-connect address)
      (guard (e (else (set! err e) #f))
        (let1 socket (make-socket (address->protocol-family address)
                                  |SOCK_STREAM|)
          (socket-connect socket address)
          socket)))
    (let1 socket (any try-connect (make-sockaddrs host port))
      (unless socket (raise err))
      socket)))

(define (make-server-socket proto . args)
  (cond ((eq? proto 'unix)
         (let-optionals* args ((path #f))
           (unless (string? path)
             (error "unix socket requires pathname, but got" path))
           (apply make-server-socket-unix path (cdr args))))
        ((eq? proto 'inet)
         (let-optionals* args ((port #f))
           (unless (or (integer? port) (string? port))
             (error "inet socket requires port, but got" port))
           (apply make-server-socket-inet port (cdr args))))
        ((is-a? proto <sockaddr>)
         ;; caller provided sockaddr
         (apply make-server-socket-from-addr proto args))
        ((integer? proto)
         ;; STk compatibility
         (apply make-server-socket-inet proto args))
        (else
         (error "unsupported protocol:" proto))))

(define (make-server-socket-from-addr addr . args)
  (let-keywords args ((reuse-addr? #f)
                      (sock-init #f)
                      (backlog DEFAULT_BACKLOG))
    (let1 socket (make-socket (address->protocol-family addr) |SOCK_STREAM|)
      (when (procedure? sock-init)
	(sock-init socket addr))
      (when reuse-addr?
	(socket-setsockopt socket |SOL_SOCKET| |SO_REUSEADDR| 1))
      (socket-bind socket addr)
      (socket-listen socket backlog))))

(define (make-server-socket-unix path . args)
  (let-keywords args ((backlog DEFAULT_BACKLOG))
    (let ((address (make <sockaddr-un> :path path))
          (socket (make-socket |PF_UNIX| |SOCK_STREAM|)))
      (socket-bind socket address)
      (socket-listen socket backlog))))

(define (make-server-socket-inet port . args)
  (let1 addr (car (make-sockaddrs #f port))
    (apply make-server-socket-from-addr addr args)))

(define (make-server-sockets host port . args)
  (map (lambda (sockaddr) (apply make-server-socket sockaddr args))
       (make-sockaddrs host port)))

(define (make-sockaddrs host port . maybe-proto)
  (let1 proto (get-optional maybe-proto 'tcp)
    (cond (ipv6-capable
           (let* ((socktype (case proto
                              ((tcp) |SOCK_STREAM|)
                              ((udp) |SOCK_DGRAM|)
                              (else (error "unsupported protocol:" proto))))
                  (port (x->string port))
                  (hints (make-sys-addrinfo :flags |AI_PASSIVE|
                                            :socktype socktype)))
             (map (lambda (ai) (slot-ref ai 'addr))
                  (sys-getaddrinfo host port hints))))
          (else
           (let* ((proto (symbol->string proto))
                  (port (cond ((number? port) port)
                              ((sys-getservbyname port proto)
                               => (cut slot-ref <> 'port))
                              (else
                               (error "couldn't find a port number of service:"
                                      port)))))
             (if host
               (let ((hh (sys-gethostbyname host)))
                 (unless hh (error "couldn't find host: " host))
                 (map (cut make <sockaddr-in> :host <> :port port)
                      (slot-ref hh 'addresses)))
               (list (make <sockaddr-in> :host :any :port port))))))))

(define (call-with-client-socket socket proc)
  (guard (e (else (socket-close socket) (raise e)))
    (begin0
     (proc (socket-input-port socket) (socket-output-port socket))
     (socket-close socket))))

;;=================================================================
;; IP address <-> string converter
;; Although many systems support this feature (e.g. inet_ntop/inet_pton
;; or WSAAdressToString/WSAStringToAddress), it would be too cumbersome
;; to check availability of those and switch the implementation.  So we
;; provide them in Scheme.

;; accessor methods

(define-method sockaddr-name ((addr <sockaddr-in>))
  #`",(inet-address->string (sockaddr-addr addr) AF_INET):,(sockaddr-port addr)")

;; NB: this should be conditionally defined by cond-expand at compile-time,
;; instead of load-time dispatch.  We need to clean up cond feature management
;; more to do so.
(if ipv6-capable
  (define-method sockaddr-name ((addr <sockaddr-in6>))
    #`"[,(inet-address->string (sockaddr-addr addr) AF_INET6)]:,(sockaddr-port addr)"))


;; IP address parser.  Can deal with both v4 and v6 addresses.
;; Two variations: ip-parse-address returns an integer address
;; and protocol; ip-parse-address! fills the given uvector with
;; parsed address and returns a protocol.
;; We could use <sockaddr-in> and <sockaddr-in6>, giving STRING
;; to :host argument in the constructor and extract the address
;; value, but the host argument also accepts hostnames, which we
;; want to avoid.  So we parse the address by ourselves.

(define (inet-string->address string)
  (receive (ns proto) (%ip-parse-address string)
    (cond
     ((eqv? proto AF_INET) (values (%fold-addr-to-integer ns 8) proto))
     ((eqv? proto AF_INET6) (values (%fold-addr-to-integer ns 16) proto))
     (else (values #f #f)))))

(define (inet-string->address! string uv)
  (receive (ns proto) (%ip-parse-address string)
    (cond
     ((eqv? proto AF_INET) (%fill-addr-to-buf! ns uv u8vector-set! 1) proto)
     ((eqv? proto AF_INET6) (%fill-addr-to-buf! ns uv %u8vector-set2be! 2) proto)
     (else #f))))

(define (%ip-parse-address string)
  (define (try-ipv6 s)
    (let loop ((ss (map (lambda (s) (or (string=? s "") s))
                        (string-split s #\:)))
               (r '())
               (abbrev? #f))
      (match ss
        ((#t #t)                        ; ends with '::'
         (and (not abbrev?)
              (finish-ipv6 (reverse (cons '* r)) #t)))
        ((#t #t . rest)                 ; begins with '::'
         (and (null? r)
              (loop rest '(*) #t)))
        ((#t . rest)                    ; '::' in the middle
         (and (not (null? r))
              (not abbrev?)
              (loop rest (cons '* r) #t)))
        ((part)                         ; end
         (cond
          ((try-ipv4 part) =>           ;   ipv6-mapped-ipv4
           (lambda (ns)
             (finish-ipv6 (reverse (cons* (+ (* (caddr ns) 256) (cadddr ns))
                                          (+ (* (car ns) 256) (cadr ns))
                                          r))
                          abbrev?)))
          ((string->number part 16) =>
           (lambda (x) (finish-ipv6 (reverse (cons x r)) abbrev?)))
          (else #f)))
        ((part . rest)
         (and-let* ((x (string->number part 16))
                    ( (<= 0 x 65535) ))
           (loop rest (cons x r) abbrev?)))
        (_ #f))))
  (define (finish-ipv6 parts abbrev?)
    (if abbrev?
      (and-let* ((zeropart-length (- 8 (length parts) -1))
                 ( (< 0 zeropart-length 8) )
                 (zeropart (make-list zeropart-length 0)))
        (receive (pre post) (break (cut eq? <> '*) parts)
          (append pre zeropart (cdr post))))
      (and (= (length parts) 8) parts)))
  (define (try-ipv4 s)
    (let1 ss (string-split s #\.)
      (and (= (length ss) 4)
           (let1 ns (map string->number ss)
             (and (every (lambda (n) (and n (<= 0 n 255))) ns)
                  ns)))))

  (cond
   ((try-ipv6 string) => (cut values <> AF_INET6))
   ((try-ipv4 string) => (cut values <> AF_INET))
   (else (values #f #f))))

(define (%fold-addr-to-integer ns digbits)
  (let loop ((shift (* (- (length ns) 1) digbits))
             (ns ns)
             (v  0))
    (if (null? ns)
      v
      (loop (- shift digbits) (cdr ns) (logior (ash (car ns) shift) v)))))

(define (%fill-addr-to-buf! ns buf filler incr)
  (fold (lambda (n pos) (filler buf pos n) (+ pos incr)) 0 ns))

;; we don't want to use put-u16be! since it would make gauche.net 
;; depends on binary.io.  So this is the hack...
(define (%u8vector-set2be! buf pos n)
  (u8vector-set! buf pos (logand (ash n -8) #xff))
  (u8vector-set! buf (+ pos 1) (logand n #xff)))

;; IP address unparser.  ADDRESS can be an integer or u8vector.
(define (inet-address->string address proto)
  (cond
   ((eqv? proto AF_INET) (%addr->string-v4 address))
   ((eqv? proto AF_INET6) (%addr->string-v6 address))
   (else (error "unsupported protocol:" proto))))
     
(define (%addr->string-v4 address)
  (apply format "~a.~a.~a.~a"
         (cond ((integer? address)
                (list (logand (ash address -24) #xff)
                      (logand (ash address -16) #xff)
                      (logand (ash address -8) #xff)
                      (logand address #xff)))
               ((u8vector? address)
                (map (cut u8vector-ref address <>) '(0 1 2 3)))
               (else (error "integer or u8vector required, but got:" address)))))

(define (%addr->string-v6 address)
  ;; again, it would be easier if we could use get-u16be, but we can't
  ;; rely on binary.io...
  (define (split)
    (map (cond ((integer? address)
                (lambda (i) (logand (ash address (* (- 7 i) -16)) #xffff)))
               ((u8vector? address)
                (lambda (i) (+ (ash (u8vector-ref address (* i 2)) 8)
                               (u8vector-ref address (+ (* i 2) 1)))))
               (else (error "integer or u8vector required, but got:" address)))
         '(0 1 2 3 4 5 6 7)))
  (define (fmt num) (number->string num 16))

  (let1 parts (split)
    (receive (run start) (zero-sequence parts)
      (if run
        (string-append
         (string-join (map fmt (take parts start)) ":")
         "::"
         (string-join (map fmt (drop parts (+ start run))) ":"))
        (string-join (map fmt parts) ":")))))
               
;; finds two or more consecutive zeros in LIS, and returns a pair of
;; <length-of-zero-sequence> and <start-of-zero-sequence>, or #f if
;; no consecutive zero seq is found.
(define (zero-sequence lis)
  (let1 p ; (<length-of-consecutive-zeros-minus-1> . <start-of-zero-sequence>)
      (values-ref
       (fold3 (lambda (part index start maxrun)
                (let* ((start  (and (zero? part) (or start index)))
                       (maxrun (if (and start (> (- index start) (car maxrun)))
                                 (cons (- index start) start)
                                 maxrun)))
                  (values (+ index 1) start maxrun)))
              0 #f '(0 . #f) lis)
       2)
    (if (cdr p) (values (+ (car p) 1) (cdr p)) (values #f #f))))
