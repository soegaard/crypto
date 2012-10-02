;; mzcrypto: libcrypto bindings for PLT-scheme
;; main library file
;; 
;; (C) Copyright 2007-2009 Dimitris Vyzovitis <vyzo at media.mit.edu>
;; 
;; mzcrypto is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Lesser General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;; 
;; mzcrypto is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Lesser General Public License for more details.
;; 
;; You should have received a copy of the GNU Lesser General Public License
;; along with mzcrypto.  If not, see <http://www.gnu.org/licenses/>.

#lang racket/base
(require (for-syntax racket/base
                     racket/syntax)
         racket/class
         racket/match
         ffi/unsafe
         (only-in "../common/digest.rkt" digest)
         "ffi.rkt"
         "macros.rkt"
         "rand.rkt"
         "digest.rkt"
         "cipher.rkt"
         "pkey.rkt"
         "dh.rkt")

(provide random-bytes
         pseudo-random-bytes)

(provide-dh)

;; ============================================================
;; Available Digests

(define digest-table (make-hasheq))
(define (available-digests) (hash-keys digest-table))

(define (intern-digest-impl name)
  (cond [(hash-ref digest-table name #f)
         => values]
        [(EVP_get_digestbyname (symbol->string name))
         => (lambda (md)
              (let ([di (new digest-impl% (md md) (name name))])
                (hash-set! digest-table name di)
                di))]
        [else #f]))

(define (make-digest-op name di)
  (procedure-rename
   (if di
       (lambda (inp) (digest di inp))
       (unavailable-function name))
   name))

(define-syntax (define-digest stx)
  (syntax-case stx ()
    [(_ id)
     (with-syntax ([di (format-id stx "digest:~a" #'id)])
       #'(begin
           (define di (intern-digest-impl 'id))
           (define id (make-digest-op 'id di))
           (put-symbols! avail-digests.symbols di id)))]))

(define (unavailable-function who)
  (lambda x (error who "unavailable")))

(define-symbols avail-digests.symbols)

(define-digest md5)
(define-digest ripemd160)
(define-digest dss1) ; sha1...
(define-digest sha1)
(define-digest sha224)
(define-digest sha256)
(define-digest sha384)
(define-digest sha512)

(define-provider provide-avail-digests avail-digests.symbols)
(provide-avail-digests)

;; ============================================================
;; Available Ciphers

(define cipher-table (make-hasheq))
(define (available-ciphers) (hash-keys cipher-table))

(define-for-syntax cipher-modes '(ecb cbc cfb ofb))
;; (define-for-syntax default-cipher-mode 'cbc)

;; Full cipher names look like "<FAMILY>(-<PARAM>)?-<MODE>?"
;; where key length is the most common parameter.
;; eg "aes-128-cbc", "bf-ecb", "des-ede-cbc"

(define-syntax define-cipher
  (syntax-rules ()
    [(define-cipher c)
     (define-cipher1 c #f)]
    [(define-cipher c (p ...))
     (begin (define-cipher1 c p) ...)]))

(define-syntax (define-cipher1 stx)
  (syntax-case stx ()
    [(define-cipher1 c klen)
     (with-syntax ([(mode ...) (cons #f cipher-modes)])
       #'(begin (define-cipher1/mode c klen mode) ...))]))

(define-syntax (define-cipher1/mode stx)
  (syntax-case stx ()
    [(define-cipher1/mode c p mode)
     (let* ([p (syntax-e #'p)]
            [mode (syntax-e #'mode)]
            [c-p (if p (format-id #'c "~a-~a" #'c p) #'c)]
            [c-p-mode (if mode (format-id #'c "~a-~a" c-p mode) c-p)])
       (with-syntax ([c-p-mode c-p-mode]
                     [cipher:c-p-mode (format-id #'c "cipher:~a" c-p-mode)])
         #'(begin
             (define cipher:c-p-mode (intern-cipher 'c-p-mode))
             (put-symbols! avail-ciphers.symbols cipher:c-p-mode))))]))

(define (intern-cipher name-sym)
  (cond [(hash-ref cipher-table name-sym #f)
         => values]
        [(EVP_get_cipherbyname (symbol->string name-sym))
         => (lambda (cipher)
              (let ([ci (new cipher-impl% (cipher cipher) (name name-sym))])
                (hash-set! cipher-table name-sym ci)
                ci))]
        [else #f]))

(define-symbols avail-ciphers.symbols available-ciphers)

(define-cipher des (#f ede ede3))
(define-cipher idea)
(define-cipher bf)
(define-cipher cast5)
(define-cipher aes (#f 128 192 256))
(define-cipher camellia (#f 128 192 256))

(define-provider provide-avail-ciphers avail-ciphers.symbols)
(provide-avail-ciphers)

;; ============================================================
;; Public Key - Available Digests

;; XXX As of openssl-0.9.8 pkeys can only be used with certain types of
;;     digests.
;;     openssl-0.9.9 is supposed to remove the restriction for digest types
(define pkey:rsa:digests 
  (filter values
    (list digest:ripemd160 
          digest:sha1 digest:sha224 digest:sha256 digest:sha384 digest:sha512)))

(define pkey:dsa:digests
  (filter values
    (list digest:dss1))) ; sha1 with fancy name

(define (pkey-digest? pk dgt)
  (cond [(!pkey? pk)
         (memq dgt
               (cond [(eq? pk pkey:rsa) pkey:rsa:digests]
                     [(eq? pk pkey:dsa) pkey:dsa:digests]
                     [else #f]))]
        [(pkey? pk) (pkey-digest? (-pkey-type pk) dgt)]
        [else (raise-type-error 'pkey-digest? "pkey or pkey type" pk)]))

(provide pkey:rsa:digests
         pkey:dsa:digests
         pkey-digest?)

;; ============================================================
;; Public-Key Available Cryptosystems

(define (rsa-keygen bits [exp 65537])
  (let/fini ([ep (BN_new) BN_free])
    (BN_add_word ep exp)
    (let/error ([rsap (RSA_new) RSA_free]
                [evp (EVP_PKEY_new) EVP_PKEY_free])
      (RSA_generate_key_ex rsap bits ep)
      (EVP_PKEY_set1_RSA evp rsap)
      (new pkey-ctx% (impl pkey:rsa) (evp evp) (private? #t)))))

(define (dsa-keygen bits)
  (let/error ([dsap (DSA_new) DSA_free]
              [evp (EVP_PKEY_new) EVP_PKEY_free])
    (DSA_generate_parameters_ex dsap bits)
    (DSA_generate_key dsap)
    (EVP_PKEY_set1_DSA evp dsap)
    (new pkey-ctx% (impl pkey:dsa) (evp evp) (private? #t))))

;; FIXME: get pktype constants from C headers

;; libcrypto #defines for those are autogened...
;; EVP_PKEY: struct evp_pkey_st {type ...}
(define (pk->type evp)
  (EVP_PKEY_type (car (ptr-ref evp (_list-struct _int)))))

(define pkey:rsa
  (with-handlers (#|(exn:fail? (lambda x #f))|#)
    (let ([pktype (let/fini ([rsap (RSA_new) RSA_free]
                             [evp (EVP_PKEY_new) EVP_PKEY_free])
                    (EVP_PKEY_set1_RSA evp rsap)
                    (pk->type evp))])
      (new pkey-impl% (pktype pktype) (keygen rsa-keygen)))))

(define pkey:dsa
  (with-handlers (#|(exn:fail? (lambda x #f))|#)
    (let ([pktype (let/fini ([dsap (DSA_new) DSA_free]
                             [evp (EVP_PKEY_new) EVP_PKEY_free])
                    (EVP_PKEY_set1_DSA evp dsap)
                    (pk->type evp))])
      (new pkey-impl% (pktype pktype) (keygen dsa-keygen)))))

(provide pkey:rsa
         pkey:dsa)

;; ============================================================
;; Key Generation

(define (generate-key algo . params)
  (apply (cond [(!cipher? algo) generate-cipher-key]
               [(!pkey? algo) generate-pkey]
               [(!digest? algo) generate-hmac-key]
               [(!dh? algo) generate-dhkey]
               [else (raise-type-error 'generate-key "crypto type" algo)])
         algo params))

(define (generate-hmac-key di)
  (random-bytes (send di get-size)))

(define (generate-cipher-key ci)
  (let ([klen (send ci get-key-size)]
        [ivlen (send ci get-iv-size)])
    (values (random-bytes klen) 
            (and ivlen (pseudo-random-bytes ivlen)))))

(define (generate-pkey pki bits . args)
  (send pki generate-key (cons bits args)))

(provide generate-key)