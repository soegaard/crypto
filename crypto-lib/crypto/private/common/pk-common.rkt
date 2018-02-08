;; Copyright 2013-2018 Ryan Culpepper
;; 
;; This library is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Lesser General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;; 
;; This library is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Lesser General Public License for more details.
;; 
;; You should have received a copy of the GNU Lesser General Public License
;; along with this library.  If not, see <http://www.gnu.org/licenses/>.

#lang racket/base
(require racket/class
         racket/match
         asn1
         binaryio/integer
         "interfaces.rkt"
         "common.rkt"
         "error.rkt"
         "base256.rkt"
         "../rkt/pk-asn1.rkt")
(provide (all-defined-out))

(define pk-read-key-base%
  (class* impl-base% (pk-read-key<%>)
    (super-new)

    (define/public (read-key sk fmt)
      (case fmt
        [(SubjectPublicKeyInfo)
         (-check-bytes fmt sk)
         (match (bytes->asn1/DER SubjectPublicKeyInfo sk)
           ;; Note: decode w/ type checks some well-formedness properties
           [(hash-table ['algorithm alg] ['subjectPublicKey subjectPublicKey])
            (define alg-oid (hash-ref alg 'algorithm))
            (define params (hash-ref alg 'parameters #f))
            (cond [(equal? alg-oid rsaEncryption)
                   (-decode-pub-rsa subjectPublicKey)]
                  [(equal? alg-oid id-dsa)
                   (-decode-pub-dsa params subjectPublicKey)]
                  ;; FIXME: DH support
                  [(equal? alg-oid id-ecPublicKey)
                   (-decode-pub-ec params subjectPublicKey)]
                  [else #f])]
           [_ #f])]
        [(PrivateKeyInfo)
         (-check-bytes fmt sk)
         (match (bytes->asn1/DER PrivateKeyInfo sk)
           [(hash-table ['version version]
                        ['privateKeyAlgorithm alg]
                        ['privateKey privateKey])
            (define alg-oid (hash-ref alg 'algorithm))
            (define alg-params (hash-ref alg 'parameters #f))
            (cond [(equal? alg-oid rsaEncryption)
                   (-decode-priv-rsa privateKey)]
                  [(equal? alg-oid id-dsa)
                   (-decode-priv-dsa alg-params privateKey)]
                  [(equal? alg-oid id-ecPublicKey)
                   (-decode-priv-ec alg-params privateKey)]
                  [else #f])]
           [_ #f])]
        [(RSAPrivateKey)
         (-check-bytes fmt sk)
         (-decode-priv-rsa (bytes->asn1/DER RSAPrivateKey sk))]
        [(DSAPrivateKey)
         (-check-bytes fmt sk)
         (match (bytes->asn1/DER (SEQUENCE-OF INTEGER) sk)
           [(list 0 p q g y x) ;; FIXME!
            (-make-priv-dsa p q g y x)])]
        [else #f]))

    ;; ---- RSA ----

    (define/public (-decode-pub-rsa subjectPublicKey)
      (match subjectPublicKey
        [(hash-table ['modulus n] ['publicExponent e])
         (-make-pub-rsa n e)]
        [_ #f]))

    (define/public (-decode-priv-rsa privateKey)
      (match privateKey
        [(hash-table ['version 0] ;; support only two-prime keys
                     ['modulus n]
                     ['publicExponent e]
                     ['privateExponent d]
                     ['prime1 p]
                     ['prime2 q]
                     ['exponent1 dp]     ;; e * dp = 1 mod (p-1)
                     ['exponent2 dq]     ;; e * dq = 1 mod (q-1)
                     ['coefficient qInv]);; q * c = 1 mod p
         (-make-priv-rsa n e d p q dp dq qInv)]
        [_ #f]))

    (define/public (-make-pub-rsa n e) #f)
    (define/public (-make-priv-rsa n e d p q dp dq qInv) #f)

    ;; ---- DSA ----

    (define/public (-decode-pub-dsa params subjectPublicKey)
      (match params
        [(hash-table ['p p] ['q q] ['g g])
         (-make-pub-dsa p q g subjectPublicKey)]
        [_ #f]))

    (define (-decode-priv-dsa alg-params privateKey)
      (match alg-params
        [(hash-table ['p p] ['q q] ['g g])
         (-make-priv-dsa p q g #f privateKey)]
        [_ #f]))

    (define/public (-make-pub-dsa p q g y) #f)
    (define/public (-make-priv-dsa p q g y x) #f)

    ;; ---- DH ----

    ;; ---- EC ----

    (define/public (-decode-pub-ec params subjectPublicKey)
      (match params
        [`(namedCurve ,curve-oid)
         (-make-pub-ec curve-oid subjectPublicKey)]
        [_ #f]))

    (define (-decode-priv-ec alg-params privateKey)
      (match alg-params
        [`(namedCurve ,curve-oid)
         (match privateKey
           [(hash-table ['version 1] ['privateKey xB] ['publicKey qB])
            (-make-priv-ec curve-oid qB (base256->unsigned xB))]
           [_ #f])]
        [_ #f]))

    (define/public (-make-pub-ec curve-oid qB) #f)
    (define/public (-make-priv-ec curve-oid qB x) #f)

    ;; ----------------------------------------

    (define/public (read-params buf fmt)
      (case fmt
        [(AlgorithmIdentifier)
         (-check-bytes fmt buf)
         (match (bytes->asn1/DER AlgorithmIdentifier/DER buf)
           [(hash-table ['algorithm alg-oid] ['parameters parameters])
            (cond [(equal? alg-oid id-dsa)
                   (read-params parameters 'DSAParameters)] ;; Dss-Parms
                  [(equal? alg-oid dhKeyAgreement)
                   (read-params parameters 'DHParameter)] ;; DHParameter
                  [(equal? alg-oid id-ecPublicKey)
                   (read-params parameters 'EcpkParameters)] ;; EcpkParameters
                  [else #f])]
           [_ #f])]
        [(DSAParameters)
         (-decode-params-dsa buf)]
        [(DHParameter) ;; PKCS#3 ... not DomainParameters!
         (-decode-params-dh buf)]
        [(EcpkParameters)
         (-decode-params-ec buf)]
        [else #f]))

    (define/public (-decode-params-dsa buf) #f)
    (define/public (-decode-params-dh buf) #f)
    (define/public (-decode-params-ec buf) #f)

    ;; ----------------------------------------

    (define/private (-check-bytes fmt v)
      (unless (bytes? v)
        (crypto-error "bad value for key format\n  format: ~e\n  expected: bytes?\n  got: ~e"
                      fmt v)))
    ))

;; ============================================================

;; ---- RSA ----

(define (encode-pub-rsa fmt n e)
  (case fmt
    [(SubjectPublicKeyInfo)
     (asn1->bytes/DER
      SubjectPublicKeyInfo
      (hasheq 'algorithm (hasheq 'algorithm rsaEncryption 'parameters #f)
              'subjectPublicKey (hasheq 'modulus n 'publicExponent e)))]
    [else #f]))

(define (encode-priv-rsa fmt n e d p q dp dq qInv)
  (case fmt
    [(SubjectPublicKeyInfo)
     (encode-pub-rsa fmt n e)]
    [(PrivateKeyInfo)
     (asn1->bytes/DER
      PrivateKeyInfo
      (hasheq 'version 0
              'privateKeyAlgorithm (hasheq 'algorithm rsaEncryption 'parameters #f)
              'privateKey (-priv-rsa n e d p q dp dq qInv)))]
    [(RSAPrivateKey)
     (asn1->bytes/DER RSAPrivateKey (-priv-rsa n e d p q dp dq qInv))]
    [else #f]))

(define (-priv-rsa n e d p q dp dq qInv)
  (hasheq 'version 0
          'modulus n
          'publicExponent e
          'privateExponent d
          'prime1 p
          'prime2 q
          'exponent1 dp
          'exponent2 dq
          'coefficient qInv))

;; ---- DSA ----

(define (encode-pub-dsa fmt p q g y)
  (case fmt
    [(SubjectPublicKeyInfo)
     (asn1->bytes/DER
      SubjectPublicKeyInfo
      (hasheq 'algorithm (hasheq 'algorithm id-dsa 'parameters (hasheq 'p p 'q q 'g g))
              'subjectPublicKey y))]
    [else #f]))

(define (encode-priv-dsa fmt p q g y x)
  (case fmt
    [(SubjectPublicKeyInfo)
     (encode-pub-dsa fmt p q g y)]
    [(PrivateKeyInfo)
     (asn1->bytes/DER
      PrivateKeyInfo
      (hasheq 'version 0
              'privateKeyAlgorithm (hasheq 'algorithm id-dsa 'parameters (hasheq 'p p 'q q 'g g))
              'privateKey x))]
    [(DSAPrivateKey)
     (asn1->bytes/DER
      (SEQUENCE-OF INTEGER)
      (list 0 p q g y x))]
    [else #f]))

;; ---- DH ----

;; ---- EC ----

(define (encode-pub-ec fmt curve-oid qB)
  (case fmt
    [(SubjectPublicKeyInfo)
     (asn1->bytes/DER
      SubjectPublicKeyInfo
      (hasheq 'algorithm (hasheq 'algorithm id-ecPublicKey
                                 'parameters (list 'namedCurve curve-oid))
              'subjectPublicKey qB))]
    [else #f]))

(define (encode-priv-ec fmt curve-oid qB d)
  (case fmt
    [(SubjectPublicKeyInfo)
     (encode-pub-ec fmt curve-oid qB)]
    [(PrivateKeyInfo)
     (asn1->bytes/DER
      PrivateKeyInfo
      (hasheq 'version 0
              'privateKeyAlgorithm (hasheq 'algorithm id-ecPublicKey
                                           'parameters (list 'namedCurve curve-oid))
              'privateKey (hasheq 'version 1
                                  'privateKey (unsigned->base256 d)
                                  'publicKey qB)))]
    [else #f]))

;; EC public key = ECPoint = octet string
;; EC private key = unsigned integer

;; Reference: SEC1 Section 2.3
;; We assume no compression, valid, not infinity, prime field.
;; mlen = ceil(bitlen(p) / 8), where q is the field in question.

;; ec-point->bytes : Nat Nat -> Bytes
(define (ec-point->bytes mlen x y)
  ;; no compression, assumes valid, assumes not infinity/zero point
  (bytes-append (bytes #x04) (integer->bytes x mlen #f #f) (integer->bytes y mlen #f #f)))

;; bytes->ec-point : Bytes -> (cons Nat Nat)
(define (bytes->ec-point buf)
  (define (bad) (crypto-error "failed to parse ECPoint"))
  (define buflen (bytes-length buf))
  (unless (> buflen 0) (bad))
  (case (bytes-ref buf 0)
    [(#x04) ;; uncompressed point
     (unless (odd? buflen) (bad))
     (define len (quotient (sub1 (bytes-length buf)) 2))
     (cons (bytes->integer buf #f #f 1 (+ 1 len))
           (bytes->integer buf #f #f (+ 1 len) (+ 1 len len)))]
    [else (bad)]))

;; curve-oid->name : OID -> Symbol/#f
(define (curve-oid->name oid)
  (for/first ([entry (in-list known-curves)]
              #:when (equal? (cdr entry) oid))
    (car entry)))

;; curve-name->oid : Symbol -> OID/#f
(define (curve-name->oid name)
  (cond [(assq known-curves name) => cdr] [else #f]))