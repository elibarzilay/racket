#lang racket/base
(require racket/file
         racket/runtime-path
         pkg/util
         racket/match
         racket/list
         racket/date
         racket/system
         racket/string
         web-server/http/id-cookie)

(define-runtime-path src ".")

(define-runtime-path root "root")
(make-directory* root)
(define secret-key
  (make-secret-salt/file
   (build-path root "secret.key")))
(define users-path (build-path root "users"))
(make-directory* users-path)
(define users.new-path (build-path root "users.new"))
(make-directory* users.new-path)

(github-client_id (file->string (build-path root "client_id")))
(github-client_secret (file->string (build-path root "client_secret")))

(define cache-path (build-path root "cache"))
(make-directory* cache-path)

(define SUMMARY-NAME "summary.rktd")
(define SUMMARY-PATH (build-path cache-path SUMMARY-NAME))

(define pkgs-path (build-path root "pkgs"))
(make-directory* pkgs-path)

(define static.src-path (build-path src "static"))
(define static-path (build-path src "static-gen"))

(define (package-list)
  (sort (map path->string (directory-list pkgs-path))
        string-ci<=?))
(define (package-info pkg-name #:version [version #f])
  (define no-version (hash-set (file->value (build-path pkgs-path pkg-name)) 'name pkg-name))
  (cond
    [(and version
          (hash-ref no-version 'versions #f)
          (hash-ref (hash-ref no-version 'versions) version #f))
     =>
     (λ (version-ht)
       (hash-merge version-ht no-version))]
    [else
     no-version]))

(define (package-ref pkg-info key)
  (hash-ref pkg-info key
            (λ ()
              (match key
                [(or 'author 'source)
                 (error 'pkg "Package ~e is missing a required field: ~e"
                        (hash-ref pkg-info 'name) key)]
                ['checksum
                 ""]
                ['ring
                 2]
                ['checksum-error
                 #f]
                ['tags
                 empty]
                ['versions
                 (hash)]
                [(or 'last-checked 'last-edit 'last-updated)
                 -inf.0]))))

(define (package-info-set! pkg-name i)
  (write-to-file i (build-path pkgs-path pkg-name)
                 #:exists 'replace))

(define (hash-merge from to)
  (for/fold ([to to])
      ([(k v) (in-hash from)])
    (hash-set to k v)))

(define (author->list as)
  (string-split as))

(define (valid-name? t)
  (not (regexp-match #rx"[^a-zA-Z0-9_\\-]" t)))

(define (valid-author? a)
  (not (regexp-match #rx"[ :]" a)))

(define valid-tag?
  valid-name?)

(define-runtime-path update.rkt "update.rkt")
(define-runtime-path build-update.rkt "build-update.rkt")
(define-runtime-path static.rkt "static.rkt")
(define-runtime-path s3.rkt "s3.rkt")

(define run-sema (make-semaphore 1))
(define (run! file args)
  (call-with-semaphore
   run-sema
   (λ ()
     (parameterize ([date-display-format 'iso-8601])
       (printf "~a: ~a ~v\n" (date->string (current-date) #t) file args))
     (apply system* (find-executable-path (find-system-path 'exec-file))
            "-t" file
            "--"
            args)
     (printf "~a: done\n" (date->string (current-date) #t)))))

(define (run-update! pkgs)
  (run! update.rkt pkgs))
(define (run-build-update!)
  (run! build-update.rkt empty))
(define (run-static! pkgs)
  (run! static.rkt pkgs))
(define (run-s3! pkgs)
  (run! s3.rkt pkgs))

(define (signal-update! pkgs)
  (thread (λ () (run-update! pkgs))))
(define (signal-build-update!)
  (thread (λ () (run-build-update!))))
(define (signal-static! pkgs)
  (thread (λ () (run-static! pkgs))))
(define (signal-s3! pkgs)
  (thread (λ () (run-s3! pkgs))))

(provide (all-defined-out))
