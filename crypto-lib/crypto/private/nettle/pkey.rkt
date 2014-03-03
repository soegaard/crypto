;; Copyright 2014 Ryan Culpepper
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
(require ffi/unsafe
         racket/class
         racket/match
         "../common/interfaces.rkt"
         "../common/common.rkt"
         "../common/catalog.rkt"
         "../common/error.rkt"
         "../gmp/ffi.rkt"
         "../rkt/asn1.rkt"
         "ffi.rkt")
(provide (all-defined-out))

#|
;; Reference: http://www.ietf.org/rfc/rfc2459.txt

SubjectPublicKeyInfo  ::=  SEQUENCE  {
    algorithm            AlgorithmIdentifier,
    subjectPublicKey     BIT STRING  }

AlgorithmIdentifier  ::=  SEQUENCE  {
    algorithm               OBJECT IDENTIFIER,
    parameters              ANY DEFINED BY algorithm OPTIONAL  }
                            -- contains a value of the type
                            -- registered for use with the
                            -- algorithm object identifier value

|#

#|
;; Reference: http://www.ietf.org/rfc/rfc3447.txt

RSAPrivateKey ::= SEQUENCE {
    version           Version,
    modulus           INTEGER,  -- n
    publicExponent    INTEGER,  -- e
    privateExponent   INTEGER,  -- d
    prime1            INTEGER,  -- p
    prime2            INTEGER,  -- q
    exponent1         INTEGER,  -- d mod (p-1)
    exponent2         INTEGER,  -- d mod (q-1)
    coefficient       INTEGER,  -- (inverse of q) mod p
    otherPrimeInfos   OtherPrimeInfos OPTIONAL
    }

Version ::= INTEGER { two-prime(0), multi(1) }
    (CONSTRAINED BY {-- version must be multi if otherPrimeInfos present --})

|#

#|
;; Reference: https://www.ietf.org/rfc/rfc3279.txt

;; Section 2.3.1 - RSA keys

pkcs-1 OBJECT IDENTIFIER ::= { iso(1) member-body(2) us(840)
    rsadsi(113549) pkcs(1) 1 }

rsaEncryption OBJECT IDENTIFIER ::=  { pkcs-1 1}

RSAPublicKey ::= SEQUENCE {
    modulus            INTEGER,    -- n
    publicExponent     INTEGER  }  -- e


;; Section 2.3.2 - DSA keys

id-dsa OBJECT IDENTIFIER ::= {
    iso(1) member-body(2) us(840) x9-57(10040) x9cm(4) 1 }

Dss-Parms  ::=  SEQUENCE  {
    p             INTEGER,
    q             INTEGER,
    g             INTEGER  }

DSAPublicKey ::= INTEGER -- public key, Y


;; Section 2.3.3 - DH

dhpublicnumber OBJECT IDENTIFIER ::= { iso(1) member-body(2)
    us(840) ansi-x942(10046) number-type(2) 1 }

DomainParameters ::= SEQUENCE {
    p       INTEGER, -- odd prime, p=jq +1
    g       INTEGER, -- generator, g
    q       INTEGER, -- factor of p-1
    j       INTEGER OPTIONAL, -- subgroup factor
    validationParms  ValidationParms OPTIONAL }

ValidationParms ::= SEQUENCE {
    seed             BIT STRING,
    pgenCounter      INTEGER }

DHPublicKey ::= INTEGER -- public key, y = g^x mod p


;; Section 2.3.5 - EC keys

ansi-X9-62 OBJECT IDENTIFIER ::=
    { iso(1) member-body(2) us(840) 10045 }

id-public-key-type OBJECT IDENTIFIER  ::= { ansi-X9.62 2 }

id-ecPublicKey OBJECT IDENTIFIER ::= { id-publicKeyType 1 }

EcpkParameters ::= CHOICE {
    ecParameters  ECParameters,
    namedCurve    OBJECT IDENTIFIER,
    implicitlyCA  NULL }

ECParameters ::= SEQUENCE {
    version   ECPVer,          -- version is always 1
    fieldID   FieldID,         -- identifies the finite field over
                               -- which the curve is defined
    curve     Curve,           -- coefficients a and b of the
                               -- elliptic curve
    base      ECPoint,         -- specifies the base point P
                               -- on the elliptic curve
    order     INTEGER,         -- the order n of the base point
    cofactor  INTEGER OPTIONAL -- The integer h = #E(Fq)/n
    }

ECPVer ::= INTEGER {ecpVer1(1)}

Curve ::= SEQUENCE {
    a         FieldElement,
    b         FieldElement,
    seed      BIT STRING OPTIONAL }

FieldElement ::= OCTET STRING

ECPoint ::= OCTET STRING


|#

;; ============================================================

(define nettle-read-key%
  (class* impl-base% (pk-read-key<%>)
    (inherit-field factory)
    (super-new (spec 'nettle-read-key))

    (define/public (read-key sk)
      (define (bad) #f)
      (match sk
        ;; RSA, DSA private keys
        [(list 'rsa 'private 'pkcs1 (? bytes? buf))
         (bad)]
        [(list 'dsa 'private 'libcrypto (? bytes? buf))
         (bad)]
        [(list (or 'rsa 'dsa) 'private 'pkcs8 (? bytes? buf)) ;; PrivateKeyInfo
         (bad)]
        ;; RSA, DSA public keys (and maybe others too?)
        [(list (or 'rsa 'dsa 'ec) 'public 'pkix (? bytes? buf)) ;; SubjectPublicKeyInfo
         (bad)]
        [(list 'ec 'private 'sec1 (? bytes? buf)) ;; ECPrivateKey
         (bad)]
        ;; Ad hoc
        [(list 'rsa 'private 'nettle
               (? bytes? n) (? bytes? e)
               (? bytes? d) (? bytes? p) (? bytes? q)
               (? bytes? a) (? bytes? b) (? bytes? c))
         (define pub (new-rsa_public_key))
         (define priv (new-rsa_private_key))
         (__gmpz_set (rsa_public_key_struct-n pub) (bin->mpz n))
         (__gmpz_set (rsa_public_key_struct-e pub) (bin->mpz e))
         (__gmpz_set (rsa_private_key_struct-d priv) (bin->mpz d))
         (__gmpz_set (rsa_private_key_struct-p priv) (bin->mpz p))
         (__gmpz_set (rsa_private_key_struct-q priv) (bin->mpz q))
         (__gmpz_set (rsa_private_key_struct-a priv) (bin->mpz a))
         (__gmpz_set (rsa_private_key_struct-b priv) (bin->mpz b))
         (__gmpz_set (rsa_private_key_struct-c priv) (bin->mpz c))
         (unless (nettle_rsa_public_key_prepare pub)
           (crypto-error "bad public key"))
         (unless (nettle_rsa_private_key_prepare priv)
           (crypto-error "bad private key"))
         (define impl (send factory get-pk 'rsa))
         (new nettle-rsa-key% (impl impl) (pub pub) (priv priv))]
        [(list 'rsa 'public 'nettle
               (? bytes? n) (? bytes? e))
         (define pub (new-rsa_public_key))
         (__gmpz_set (rsa_public_key_struct-n pub) (bin->mpz n))
         (__gmpz_set (rsa_public_key_struct-e pub) (bin->mpz e))
         (unless (nettle_rsa_public_key_prepare pub)
           (crypto-error "bad public key"))
         (define impl (send factory get-pk 'rsa))
         (new nettle-rsa-key% (impl impl) (pub pub) (priv #f))]
        [_ #f]))

    (define/public (read-params sp) #f)
    ))

;; ============================================================

(define nettle-pk-impl%
  (class* impl-base% (pk-impl<%>)
    (inherit-field spec factory)
    (super-new)

    (define/public (generate-key config)
      (err/no-direct-keygen spec))
    (define/public (generate-params config)
      (err/no-params spec))
    (define/public (can-encrypt?) #f)
    (define/public (can-sign?) #f)
    (define/public (can-key-agree?) #f)
    (define/public (has-params?) #f)

    (define/public (get-random-ctx)
      (define r (send factory get-random))
      (send r get-context))
    ))

;; ============================================================

(define allowed-rsa-keygen
  `((nbits ,exact-positive-integer? "exact-positive-integer?")
    (e     ,exact-positive-integer? "exact-positive-integer?")))

(define nettle-rsa-impl%
  (class nettle-pk-impl%
    (inherit-field spec factory)
    (inherit get-random-ctx)
    (super-new (spec 'rsa))

    (define/override (can-encrypt?) #t)
    (define/override (can-sign?) #t)

    (define/override (generate-key config)
      (check-keygen-spec config allowed-rsa-keygen)
      (let ([nbits (or (keygen-spec-ref config 'nbits) 2048)]
            [e (or (keygen-spec-ref config 'e) 65537)])
        (define pub (new-rsa_public_key))
        (define priv (new-rsa_private_key))
        (__gmpz_set_si (rsa_public_key_struct-e pub) e)
        (or (nettle_rsa_generate_keypair pub priv (get-random-ctx) nbits 0)
            (crypto-error "RSA key generation failed"))
        (new nettle-rsa-key% (impl this) (pub pub) (priv priv))))
    ))

(define nettle-rsa-key%
  (class* ctx-base% (pk-key<%>)
    (init-field pub priv)
    (inherit-field impl)
    (super-new)

    (define/public (is-private?) (and priv #t))

    (define/public (get-public-key)
      (if priv (new nettle-rsa-key% (impl impl) (pub pub) (priv #f)) this))

    (define/public (get-params)
      (crypto-error "key parameters not supported"))

    (define/public (write-key fmt)
      (case fmt
        [(#f)
         (cond [priv
                `(rsa private nettle
                      ,(mpz->bin (rsa_public_key_struct-n pub))
                      ,(mpz->bin (rsa_public_key_struct-e pub))
                      ,(mpz->bin (rsa_private_key_struct-d priv))
                      ,(mpz->bin (rsa_private_key_struct-p priv))
                      ,(mpz->bin (rsa_private_key_struct-q priv))
                      ,(mpz->bin (rsa_private_key_struct-a priv))
                      ,(mpz->bin (rsa_private_key_struct-b priv))
                      ,(mpz->bin (rsa_private_key_struct-c priv)))]
               [else
                `(rsa public nettle
                      ,(mpz->bin (rsa_public_key_struct-n pub))
                      ,(mpz->bin (rsa_public_key_struct-e pub)))])]
        [else
         (err/key-format fmt)]))

    (define/public (equal-to-key? other)
      (and (is-a? other nettle-rsa-key%)
           (= (rsa_public_key_struct-size pub)
              (rsa_public_key_struct-size (get-field pub other)))
           (mpz=? (rsa_public_key_struct-n pub)
                  (rsa_public_key_struct-n (get-field pub other)))
           (mpz=? (rsa_public_key_struct-e pub)
                  (rsa_public_key_struct-e (get-field pub other)))))

    (define/public (sign digest digest-spec pad)
      (unless (send impl can-sign?) (err/no-sign (send impl get-spec)))
      (unless priv (err/sign-requires-private))
      (check-digest digest digest-spec)
      (define sign-fun
        (case digest-spec
          [(md5) nettle_rsa_md5_sign_digest]
          [(sha1) nettle_rsa_sha1_sign_digest]
          [(sha256) nettle_rsa_sha256_sign_digest]
          [(sha512) nettle_rsa_sha512_sign_digest]
          [else
           (crypto-error "RSA signing not supported for digest\n  digest algorithm: ~s"
                         digest-spec)]))
      (define sigz (new-mpz))
      (or (sign-fun priv digest sigz)
          (crypto-error "RSA signing failed"))
      (mpz->bin sigz))

    (define/private (check-digest digest digest-spec)
      (unless (= (bytes-length digest)
                 (digest-spec-size digest-spec))
        (crypto-error
         "digest wrong size\n  digest algorithm: ~s\n  expected size:  ~s\n  digest: ~e"
         digest-spec (digest-spec-size digest-spec) digest)))

    (define/public (verify digest digest-spec pad sig)
      (unless (send impl can-sign?) (err/no-sign (send impl get-spec)))
      (check-digest digest digest-spec)
      (define verify-fun
        (case digest-spec
          [(md5) nettle_rsa_md5_verify_digest]
          [(sha1) nettle_rsa_sha1_verify_digest]
          [(sha256) nettle_rsa_sha256_verify_digest]
          [(sha512) nettle_rsa_sha512_verify_digest]
          [else
           (crypto-error "RSA verification not supported for digest\n  digest algorithm: ~s\n"
                         digest-spec)]))
      (unless (member pad '(#f pkcs1-v1.5))
        (crypto-error "RSA padding not supported\n  padding: ~s" pad))
      (define sigz (bin->mpz sig))
      (verify-fun pub digest sigz))

    (define/public (encrypt buf pad)
      (unless (send impl can-encrypt?) (err/no-encrypt (send impl get-spec)))
      (unless (member pad '(#f pkcs1-v1.5))
        (crypto-error "bad pad")) ;; FIXME
      (define enc-z (new-mpz))
      (or (nettle_rsa_encrypt pub (send impl get-random-ctx) buf enc-z)
          (crypto-error "RSA encyption failed"))
      (mpz->bin enc-z))

    (define/public (decrypt buf pad)
      (unless (send impl can-encrypt?) (err/no-encrypt (send impl get-spec)))
      (unless priv (err/decrypt-requires-private))
      (define enc-z (bin->mpz buf))
      (define dec-buf (make-bytes (rsa_public_key_struct-size pub)))
      (define dec-size (nettle_rsa_decrypt priv dec-buf enc-z))
      (unless dec-size
        (crypto-error "RSA decryption failed"))
      (shrink-bytes dec-buf dec-size))

    (define/public (compute-secret peer-pubkey0)
      (crypto-error "not supported"))
    ))

;; ============================================================

;; Nettle doesn't support DSA params, so just use keygen directly.

(define allowed-dsa-keygen
  `((nbits ,exact-positive-integer? "exact-positive-integer?")
    (qbits ,(lambda (x) (member x '(160 256))) "(or/c 160 256)")))

(define nettle-dsa-impl%
  (class nettle-pk-impl%
    (inherit-field spec factory)
    (inherit get-random-ctx)
    (super-new (spec 'dsa))

    (define/override (can-encrypt?) #f)
    (define/override (can-sign?) #t)

    (define/override (generate-key config)
      (check-keygen-spec config allowed-dsa-keygen)
      (let ([nbits (or (keygen-spec-ref config 'nbits) 2048)]
            [qbits (or (keygen-spec-ref config 'qbits) 256)])
        (define pub (new-dsa_public_key))
        (define priv (new-dsa_private_key))
        (define random-ctx (get-random-ctx))
        (or (nettle_dsa_generate_keypair pub priv (get-random-ctx) nbits qbits)
            (crypto-error "DSA key generation failed"))
        (new nettle-dsa-key% (impl this) (pub pub) (priv priv))))
    ))

(define nettle-dsa-key%
  (class* ctx-base% (pk-key<%>)
    (init-field pub priv)
    (inherit-field impl)
    (super-new)

    (define/public (is-private?) (and priv #t))

    (define/public (get-public-key)
      (if priv (new nettle-dsa-key% (impl impl) (pub pub) (priv #f)) this))

    (define/public (get-params)
      (crypto-error "key parameters not supported"))

    (define/public (write-key fmt)
      (case fmt
        [(#f)
         (cond [priv
                `(dsa private nettle
                      ,(mpz->bin (dsa_public_key_struct-p pub))
                      ,(mpz->bin (dsa_public_key_struct-q pub))
                      ,(mpz->bin (dsa_public_key_struct-g pub))
                      ,(mpz->bin (dsa_public_key_struct-y pub))
                      ,(mpz->bin (dsa_private_key_struct-x priv)))]
               [else
                `(dsa private nettle
                      ,(mpz->bin (dsa_public_key_struct-p pub))
                      ,(mpz->bin (dsa_public_key_struct-q pub))
                      ,(mpz->bin (dsa_public_key_struct-g pub))
                      ,(mpz->bin (dsa_public_key_struct-y pub)))])]
        [else
         (err/key-format fmt)]))

    (define/public (equal-to-key? other)
      (and (is-a? other nettle-dsa-key%)
           (mpz=? (dsa_public_key_struct-p pub)
                  (dsa_public_key_struct-p (get-field pub other)))
           (mpz=? (dsa_public_key_struct-q pub)
                  (dsa_public_key_struct-q (get-field pub other)))
           (mpz=? (dsa_public_key_struct-g pub)
                  (dsa_public_key_struct-g (get-field pub other)))
           (mpz=? (dsa_public_key_struct-y pub)
                  (dsa_public_key_struct-y (get-field pub other)))))

    (define/public (sign digest digest-spec pad)
      (unless (send impl can-sign?) (err/no-sign (send impl get-spec)))
      (unless priv (err/sign-requires-private))
      (check-digest digest digest-spec)
      (define sign-fun
        (case digest-spec
          [(sha1) nettle_dsa_sha1_sign_digest]
          [(sha256) nettle_dsa_sha256_sign_digest]
          [else
           (crypto-error "DSA signing not supported for digest\n  digest algorithm: ~s"
                         digest-spec)]))
      (define sig (new-dsa_signature))
      (or (sign-fun pub priv (send impl get-random-ctx) digest sig)
          (crypto-error "DSA signing failed"))
      (dsa_signature->der sig))

    (define/private (dsa_signature->der sig)
      (sequence->der
       (list (wrap-integer (mpz->bin (dsa_signature_struct-r sig) #t))
             (wrap-integer (mpz->bin (dsa_signature_struct-s sig) #t)))))

    (define/private (der->dsa_signature der)
      (match (unwrap-der der)
        [(list 'SEQUENCE (list 'INTEGER (? bytes? r)) (list 'INTEGER (? bytes? s)))
         (define sig (new-dsa_signature))
         (__gmpz_set (dsa_signature_struct-r sig) (bin->mpz r))
         (__gmpz_set (dsa_signature_struct-s sig) (bin->mpz s))
         sig]
        [_ (crypto-error 'der->dsa_signature "signature is not well-formed")]))

    (define/private (check-digest digest digest-spec)
      (unless (= (bytes-length digest)
                 (digest-spec-size digest-spec))
        (crypto-error
         "digest wrong size\n  digest algorithm: ~s\n  expected size:  ~s\n  digest: ~e"
         digest-spec (digest-spec-size digest-spec) digest)))

    (define/public (verify digest digest-spec pad sig-der)
      (unless (send impl can-sign?) (err/no-sign (send impl get-spec)))
      (check-digest digest digest-spec)
      (define verify-fun
        (case digest-spec
          [(sha1) nettle_dsa_sha1_verify_digest]
          [(sha256) nettle_dsa_sha256_verify_digest]
          [else
           (crypto-error "DSA verification not supported for digest\n  digest algorithm: ~s\n"
                         digest-spec)]))
      (unless (member pad '(#f))
        (crypto-error "DSA padding not supported\n  padding: ~s" pad))
      (define sig (der->dsa_signature sig-der))
      (verify-fun pub digest sig))

    (define/public (encrypt buf pad)
      (err/no-encrypt (send impl get-spec)))

    (define/public (decrypt buf pad)
      (err/no-encrypt (send impl get-spec)))

    (define/public (compute-secret peer-pubkey0)
      (crypto-error "not supported"))
    ))