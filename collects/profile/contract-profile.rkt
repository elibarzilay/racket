#lang racket/base

(require racket/list unstable/list racket/match racket/set
         racket/contract
         (only-in racket/contract/private/guts contract-continuation-mark-key)
         "sampler.rkt")

(struct contract-profile
  (total-time n-samples n-contract-samples
   ;; (pairof blame? profile-sample)
   ;; samples taken while a contract was running
   live-contract-samples
   ;; (listof blame?)
   ;; all the blames that were observed during sampling
   all-blames))

;; (listof (U blame? #f)) profile-samples -> contract-profile struct
(define (correlate-contract-samples contract-samples samples*)
  (define total-time (car samples*))
  (define samples    (cdr samples*))
  (define n-samples             (length contract-samples))
  ;; combine blame info and stack trace info. samples should line up
  (define aug-contract-samples  (map cons contract-samples samples))
  (define live-contract-samples (filter car aug-contract-samples))
  (define n-contract-samples    (length live-contract-samples))
  (define all-blames (remove-duplicates (filter values contract-samples)))
  (contract-profile total-time n-samples n-contract-samples
                    live-contract-samples all-blames))


(define (analyze-contract-samples contract-samples samples*)
  (define correlated (correlate-contract-samples contract-samples samples*))
  (print-breakdown correlated)
  (module-graph-view correlated))


;;---------------------------------------------------------------------------
;; Break down contract checking time by contract, then by callee and by chain
;; of callers.

(define (print-breakdown correlated)
  (match-define (contract-profile total-time n-samples n-contract-samples
                                  live-contract-samples all-blames)
    correlated)

  (printf "Running time is ~a% contracts (~a/~a samples).\n\n"
          (* 100 (/ n-contract-samples n-samples 1.0))
          n-contract-samples n-samples)

  (define (print-contract/loc c)
    (printf "~a @ ~a\n" (blame-contract c) (blame-source c)))

  (displayln "\nBY CONTRACT\n")
  (define samples-by-contract
    (sort (group-by equal? live-contract-samples
                    #:key (lambda (x) (blame-contract (car x))))
          > #:key length #:cache-keys? #t))
  (for ([c (in-list samples-by-contract)])
    (define representative (caar c))
    (print-contract/loc representative)
    (printf "  ~a samples\n\n" (length c)))

  (displayln "\nBY CALLEE\n")
  (for ([g (in-list samples-by-contract)])
    (define representative (caar g))
    (print-contract/loc representative)
    (for ([x (sort
              (group-by equal? g
                        #:key (lambda (x) (blame-value (car x)))) ; callee source, maybe
              > #:key length)])
      (printf "  ~a\n  ~a samples\n" (blame-value (caar x)) (length x)))
    (newline))

  (define samples-by-contract-by-caller
    (for/list ([g (in-list samples-by-contract)])
      (sort (group-by equal? (map sample-prune-stack-trace g)
                      #:key cdddr) ; pruned stack trace
            > #:key length)))

  (displayln "\nBY CALLER\n")
  (for* ([g samples-by-contract-by-caller]
         [c g])
    (define representative (car c))
    (print-contract/loc (car representative))
    (for ([frame (in-list (cdddr representative))])
      (printf "  ~a @ ~a\n" (car frame) (cdr frame)))
    (printf "  ~a samples\n" (length c))
    (newline)))

;; Unrolls the stack until it hits a function on the negative side of the
;; contract boundary (based on module location info).
;; Will give bogus results if source location info is incomplete.
(define (sample-prune-stack-trace sample)
  (match-define (list blame thread-id timestamp stack-trace ...) sample)
  (define caller-module (blame-negative blame))
  (define new-stack-trace
    (dropf stack-trace
           (match-lambda
            [(cons name loc)
             (or (not loc)
                 (not (equal? (srcloc-source loc) caller-module)))])))
  (list* blame thread-id timestamp new-stack-trace))


;;---------------------------------------------------------------------------
;; Show graph of modules, with contract boundaries and contract costs for each
;; boundary.
;; Typed modules are in green, untyped modules are in red.

(define (module-graph-view correlated)
  (match-define (contract-profile total-time n-samples n-contract-samples
                                  live-contract-samples all-blames)
    correlated)

  ;; first, enumerate all the relevant modules
  (define-values (nodes edge-samples)
    (for/fold ([nodes (set)] ; set of modules
               ;; maps pos-neg edges (pairs) to lists of samples
               [edge-samples (hash)])
        ([s (in-list live-contract-samples)])
      (match-define (list blame thread-id timestamp stack-trace ...) s)
      (define pos (blame-positive blame))
      (define neg (blame-negative blame))
      (values (set-add (set-add nodes pos) neg) ; add all new modules
              (hash-update edge-samples (cons pos neg)
                           (lambda (ss) (cons s ss))
                           '()))))

  (define nodes->typed?
    (for/hash ([n nodes])
      ;; typed modules have a #%type-decl submodule
      (define submodule? (not (path? n)))
      (define filename (if submodule? (car n) n))
      (define typed?
        (with-handlers
            ([(lambda (e)
                (and (exn:fail:contract? e)
                     (regexp-match "^dynamic-require: unknown module"
                                   (exn-message e))))
              (lambda _ #f)])
          (dynamic-require
           (append (list 'submod (list 'file (path->string filename)))
                   (if submodule? (cdr n) '())
                   '(#%type-decl))
           #f)
          #t))
      (values n typed?)))

  ;; graphviz output
  (printf "digraph {\n")
  (define nodes->names (for/hash ([n nodes]) (values n (gensym))))
  (for ([n nodes])
    (printf "~a[label=\"~a\"][color=\"~a\"]\n"
            (hash-ref nodes->names n)
            n
            (if (hash-ref nodes->typed? n) "green" "red")))
  (for ([(k v) (in-hash edge-samples)])
    (match-define (cons pos neg) k)
    (printf "~a -> ~a[label=\"~a\"]\n"
            (hash-ref nodes->names neg)
            (hash-ref nodes->names pos)
            (length v)))
  (printf "}\n"))


;;---------------------------------------------------------------------------
;; Entry point

(provide (rename-out [contract-profile/user contract-profile]))

;; TODO have kw args for profiler, etc.
;; TODO have kw args for output files
(define-syntax-rule (contract-profile/user body ...)
  (let ([sampler (create-sampler (current-thread) 0.005 (current-custodian)
                                 (list contract-continuation-mark-key))])
    body ...
    (sampler 'stop)
    (define samples          (sampler 'get-snapshots))
    (define contract-samples (for/list ([s (in-list (sampler 'get-custom-snapshots))])
                               (and s (vector-ref s 0))))
    (analyze-contract-samples contract-samples samples)))