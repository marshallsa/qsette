#lang rosette

(require "complex.rkt"
         "matrix.rkt")

(provide environment
         environment-probabilities
         environment-variables
         interpret-stmt
         interpret-expr)

(struct environment (variables state probabilities) #:transparent)

(define identity-gate 
  `((,(complex 1 0) ,(complex 0 0))
    (,(complex 0 0) ,(complex 1 0))))

(define x-gate
  `((,(complex 0 0) ,(complex 1 0))
    (,(complex 1 0) ,(complex 0 0))))

(define z-gate
  `((,(complex 1 0) ,(complex 0 0))
    (,(complex 0 0) ,(complex -1 0))))

(define h-gate
  `((,(complex (/ 1 (sqrt 2)) 0) ,(complex (/ 1 (sqrt 2)) 0))
    (,(complex (/ 1 (sqrt 2)) 0) ,(complex (/ -1 (sqrt 2)) 0))))

(define t-gate
  `((,(complex 1 0) ,(complex 0 0))
    (,(complex 0 0) ,(complex (/ 1 (sqrt 2)) (/ 1 (sqrt 2))))))

(define select-zero
  `((,(complex 1 0) ,(complex 0 0))
    (,(complex 0 0) ,(complex 0 0))))

(define select-one
  `((,(complex 0 0) ,(complex 0 0))
    (,(complex 0 0) ,(complex 1 0))))

; Returns a new environment with variables created between env and env* removed
(define (drop-scope env env*)
  (let* ([variables* (environment-variables env*)]
         [new-count (- (length variables*) (length (environment-variables env)))])
    (struct-copy environment env* (variables (drop variables* new-count)))))

(define (interpret-stmt-scoped stmt env)
  (match (interpret-stmt stmt env)
    [(cons ret env*) (cons ret (drop-scope env env*))]
    [env* (drop-scope env env*)]))
                     
(define (interpret-stmt stmt env)
  (if (not (environment? env))
      ; env is some return value instead, so just return it again.
      env
      ; env is actually an environment.
      (match stmt
        [`(begin ,stmts ...)
         (foldl interpret-stmt env stmts)]
        [`(if ,expr ,stmt1 ,stmt2)
         (let*-values ([(value env*) (interpret-expr expr env)])
           (if value
               (interpret-stmt-scoped stmt1 env*)
               (interpret-stmt-scoped stmt2 env*)))]
        [`(if ,expr ,stmt1)
         (interpret-stmt `(if ,expr ,stmt1 (begin)) env)]
        [`(mutable ,id ,expr)
         ; Because we have "mutable" and "set" statements, we can shadow previous ids.
         ; New ids are added to the beginning of the list, only the most recently defined is used.
         (let*-values ([(value env*) (interpret-expr expr env)]
                       [(variables*) (environment-variables env*)])
           (struct-copy environment env*
                        (variables (cons (cons id value) variables*))))]
        [`(set ,id ,expr)
         (let*-values ([(value env*) (interpret-expr expr env)]
                       [(variables*) (environment-variables env*)])
           (struct-copy environment env*
                        [variables (dict-set variables* id value)]))]
        ; TODO: Should "using" have lexical scope, currently behaves like a begin, no scoping
        [`(using (,qubits ...) ,stmts ...)
         (let*-values ([(num env*) (using-qubits qubits env)]
                       ; TODO: Is it an error to return from inside a using block?
                       ; If not then we need to add a check here for cons.
                       [(env**) (interpret-stmt `(begin ,@stmts) env*)]
                       [(state**) (environment-state env**)])
           ; TODO: Remove qubit variables from the environment.
           (struct-copy environment env**
                        [state (release-qubits num state**)]))]
        [`(for (,id ,exprs ...) ,S)
         (let*-values ([(values env*) (sequence-exprs exprs env)])
           (foldl (lambda (i env**)
                    (interpret-stmt-scoped `(begin (mutable ,id ,i) ,S) env**))
                  env*
                  (stream->list (apply in-range values))))]
        [`(return ,expr)
         (let-values ([(value env*) (interpret-expr expr env)])
           (cons value env*))]
        [`(print-env)
         (pretty-print env)
         env]
        [expr
         (let-values ([(value env*) (interpret-expr expr env)])
           env*)])))

(define (interpret-expr expr env)
  (define (apply-gate gate qubit)
    (let-values ([(id env*) (interpret-expr qubit env)])
      (apply-to-each gate (list id))))

  (define (apply-to-each gate qubits)
    (let*-values ([(ids env*) (interpret-expr qubits env)]
                  [(state*) (environment-state env*)])
      (values (void)
              (struct-copy environment env*
                           [state (column-vector->list
                                   (apply-to-qubits gate ids state*))]))))

  (match expr
    [`(x ,q) (apply-gate x-gate q)]
    [`(z ,q) (apply-gate z-gate q)]
    [`(h ,q) (apply-gate h-gate q)]
    [`(t ,q) (apply-gate t-gate q)]
    [`(cnot ,control ,target)
     (let*-values ([(control-id env*) (interpret-expr control env)])
       (interpret-expr `(controlled x ,(list control-id) ,target) env*))]
    [`(apply-to-each ,operator ,qubits)
     (let* ([gate (match operator
                    ['x x-gate]
                    ['z z-gate]
                    ['h h-gate]
                    ['t t-gate])])
       (apply-to-each gate qubits))]
    [`(controlled ,operator ,controls ,target)
     (let*-values ([(controls-val env*) (interpret-expr controls env)]
                   [(control-ids) (if (list? controls-val)
                                      controls-val
                                      (list controls-val))])
       (interpret-expr `(controlled-on-bit-string
                         ,operator
                         ,(bv (- (expt 2 (length control-ids)) 1)
                              (length control-ids))
                         ,control-ids
                         ,target)
                       env*))]
    [`(controlled-on-bit-string ,operator ,bits ,controls ,target)
     (match-let*-values ([(gate) (match operator
                                   ['x x-gate]
                                   ['z z-gate]
                                   ['h h-gate]
                                   ['t t-gate])]
                         [((list bit-values control-ids target-id) env*)
                          (sequence-exprs (list bits controls target) env)]
                         [(state*) (environment-state env*)])
       (values
        (void)
        (struct-copy environment env*
                     [state (column-vector->list
                             (apply-controlled gate
                                               control-ids
                                               bit-values
                                               target-id
                                               state*))])))]
    [`(m ,q)
     (match-let*-values
      ([(id (environment variables* state* probabilities*))
        (interpret-expr q env)]
       [(`(,result ,state** ,probability)) (measure state* id)])
      (values result
              (environment variables*
                           state**
                           (dict-set probabilities* result probability))))]
    [`(measure-integer ,qs)
     (let*-values ([(ids env*) (interpret-expr qs env)]
                   [(results env**) (sequence-exprs
                                     (map (lambda (id) `(m ,id)) ids) env*)])
       (values (booleans->bitvector results) env**))]
    [`(reset ,q)
     (values (void) (interpret-stmt `(if (m ,q) (x ,q)) env))]
    [`(reset-all ,qs)
     (let-values ([(ids env*) (interpret-expr qs env)])
       (values (void)
               (foldl interpret-stmt
                      env*
                      (map (lambda (q) `(reset ,q)) ids))))]
    [`(= ,expr1 ,expr2)
     (let*-values ([(value1 env1) (interpret-expr expr1 env)]
                   [(value2 env2) (interpret-expr expr2 env1)])
       (values (equal? value1 value2) env2))]
    [`(index ,expr ,i)
     (match-let-values ([((list value i) env*) (sequence-exprs (list expr i) env)])
       (values (list-ref value i) env*))]
    [`(drop ,lst ,pos)
     (match-let-values ([((list lst-value pos-value) env*)
                         (sequence-exprs (list lst pos) env)])
       (values (drop lst-value pos-value) env*))]
    [`(,id ,exprs ...)
     #:when (procedure? id)
     (match-let*-values
      ([(args env*)
        (sequence-exprs exprs env)]
       [((cons ret (environment _ state* probabilities*)))
        (apply id (append args (list env*)))])
      (values ret
              (struct-copy environment env
                           (state state*)
                           (probabilities probabilities*))))]
    [(? boolean?) (values expr env)]
    [(? integer?) (values expr env)]
    [(? bv?) (values expr env)]
    [(? list?) (values expr env)]
    [id (values (dict-ref (environment-variables env) id) env)]))

(define (apply-operator operator state)
  (matrix-multiply operator (list->column-vector state)))

(define (expand-operator operator qubits size)
  (let ([operators (build-list size
                               (lambda (i)
                                 (if (member i qubits)
                                     operator
                                     identity-gate)))])
    (foldl kronecker-product (car operators) (cdr operators))))

(define (control-operator operator controls bits target size)
  (define (controls-satisfied basis)
    (bveq bits
          (apply bvadd
                 (map (lambda (index qubit)
                        (bv (arithmetic-shift
                             (bitwise-bit-field basis qubit (+ 1 qubit))
                             index)
                            (length controls)))
                      (stream->list (in-range (length controls)))
                      controls))))

  (let ([expanded-op (expand-operator operator (list target) size)]
        [expanded-id (expand-operator identity-gate (list target) size)])
    (transpose (map (lambda (basis op-column id-column)
                      (if (controls-satisfied basis) op-column id-column))
                    (stream->list (in-range (expt 2 size)))
                    (transpose expanded-op)
                    (transpose expanded-id)))))

(define (apply-to-qubit operator qubit state)
  (apply-to-qubits operator (list qubit) state))

(define (apply-to-qubits operator qubits state)
  (apply-operator (expand-operator operator qubits (num-qubits state)) state))

(define (apply-controlled operator controls bits target state)
  (apply-operator
   (control-operator operator controls bits target (num-qubits state))
   state))

(define (measure state qubit)
  ; The state vector is unnormalized, so remember to divide the probability by
  ; the state vector's magnitude squared.
  (let* ([state-mag-sq (vector-magnitude-sq (list->column-vector state))]
         [zero-state (apply-to-qubit select-zero qubit state)]
         [one-state (apply-to-qubit select-one qubit state)]
         [probability (if (= 0 state-mag-sq)
                          0
                          (/ (vector-magnitude-sq one-state) state-mag-sq))])
    (define-symbolic* m boolean?)
    `(,m
      ,(column-vector->list (if m one-state zero-state))
      ,probability)))

(define (num-qubits state)
  (exact-truncate (log (length state) 2)))

(define (allocate-qubits num state)
  (let* ([next-id (if (empty? state) 0 (num-qubits state))]
         [state* (if (empty? state)
                     (build-list (expt 2 num)
                                 (lambda (i)
                                   (if (= 0 i) (complex 1 0) (complex 0 0))))
                     (append state
                             (build-list (* (length state) (- (expt 2 num) 1))
                                         (const (complex 0 0)))))])
    (values (stream->list (in-range next-id (+ num next-id))) state*)))

(define (release-qubits num state)
  ; TODO: Check that released qubits are all zero?
  (if (= num (num-qubits state))
      empty
      (take state (/ (length state) (expt 2 num)))))

(define (using-qubits initializers env)
  (define (update-env env name value state)
    (struct-copy environment env
                 [variables (dict-set (environment-variables env) name value)]
                 [state state]))

  (for/fold ([num 0]
             [env* env])
            ([initializer initializers])
    (let ([state* (environment-state env*)])
      (match initializer
        [`[,name (qubit)]
         (let-values ([(ids state**) (allocate-qubits 1 state*)])
           (values (+ 1 num) (update-env env* name (car ids) state**)))]
        [`[,name (qubits ,size)]
         (let-values ([(ids state*) (allocate-qubits size state*)])
           (values (+ size num) (update-env env* name ids state*)))]))))

(define (sequence-exprs exprs env)
  (let-values ([(vals env*) (for/fold ([vals empty]
                                       [env* env])
                                      ([expr exprs])
                              (let-values ([(value env**)
                                            (interpret-expr expr env*)])
                                (values (cons value vals) env**)))])
    (values (reverse vals) env*)))

(define (booleans->bitvector bools)
  (apply bvadd (map (lambda (index bool)
                      (if bool
                          (bv (arithmetic-shift 1 index) (length bools))
                          (bv 0 (length bools))))
                    (stream->list (in-range 0 (length bools)))
                    bools)))
