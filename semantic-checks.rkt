#lang typed/racket/base

(require racket/match racket/list)

(require "source-ast.rkt" "core-ast.rkt" "environment.rkt" "unique.rkt")

(provide
 global-environment
 rename-variables
 break-check)




(: assert-symbol (Any -> Symbol))
(define (assert-symbol v)
 (assert v symbol?))




(struct: environment
 ((ids : (HashTable Symbol unique))
  (types : (HashTable Symbol unique))) #:transparent)

(: global-environment environment)
(define global-environment
 (environment
  global-id-names
  global-type-names))


(: rename-variables (expression environment -> expression))
(define (rename-variables prog env)
 (define-type updater
  (case-lambda
   (lvalue -> lvalue)
   (type-reference -> type-reference)
   (compound-type -> compound-type)
   ((U type-reference compound-type) -> (U type-reference compound-type))
   (expression -> expression)))
 (: rename (environment -> updater))
 (define (rename env)
  (: recur updater)
  (define (recur prog)
   (match prog
    ((identifier sym) (identifier (lookup-identifier sym env)))
    ((field-ref base field ty) (field-ref (recur base) field (and ty (recur ty))))
    ((array-ref base index ty) (array-ref (recur base) (recur index) (and ty (recur ty))))
    ((binder declarations body)
     (let-values (((declarations env) (extend-environment declarations env)))
      (binder declarations ((rename env) body))))
    ((sequence exprs) (sequence (map recur exprs)))
    ((assignment value expr)
     (assignment (recur value) (recur expr)))
    ((if-then-else c t f ty)
     (if-then-else (recur c) (recur t) (and f (recur f)) (and ty (error 'rename-variables "Already annotated conditional"))))
    ((integer-literal v) prog)
    ((string-literal s) prog)
    ((nil ref) prog)
    ((negation expr) (negation (recur expr)))
    ((function-call fun args ty)
     (function-call (recur fun) (map recur args) (and ty (recur ty))))
    ((math op left right)
     (math op (recur left) (recur right)))
    ((comparison op left right ty)
     (comparison op (recur left) (recur right) (and ty (recur ty))))
    ((equality op left right ty)
     (equality op (recur left) (recur right) (and ty (recur ty))))
    ((create-record type fields)
     (create-record (recur type)
       (map (inst cons Symbol expression)
            (map (inst car Symbol expression) fields)
            (map recur (map (inst cdr Symbol expression) fields)))))
    ((create-array type size value)
     (create-array (recur type) (recur size) (recur value)))
    ((while-loop guard body)
     (while-loop (recur guard) (recur body)))
    ((for-loop id init final body)
     (let* ((env (add-identifier id env))
            (recur (rename env)))
      (for-loop (lookup-identifier id env) (recur init) (recur final) (recur body))))
    ((break) (break))
    ((array-type elem-type) (array-type (recur elem-type)))
    ((record-type fields)
     (record-type 
      (map (inst cons Symbol type-reference)
       (map (inst car Symbol type-reference) fields)
       (map recur (map (inst cdr Symbol type-reference) fields)))))
    ((function-type args return)
     (function-type (map recur args) (and return (recur return))))
    ((type-reference name)
     (type-reference (lookup-type name env)))
    (else (error 'rename-variables "missing case for ~a" prog))
    ))
       
  recur)
 
 (: lookup-identifier ((U Symbol unique) environment -> unique))
 (define (lookup-identifier sym env)
  (hash-ref (environment-ids env) (assert-symbol sym)
   (lambda ()
    (error 'lookup-identifier "Unbound Identifier ~a in ~a" sym env))))


 (: lookup-type ((U Symbol unique) environment -> unique))
 (define (lookup-type sym env)
  (hash-ref (environment-types env) (assert-symbol sym)
   (lambda ()
    (error 'lookup-type "Unbound type ~a" sym))))


 (: add-identifier ((U Symbol unique) environment -> environment))
 (define (add-identifier sym env)
  (let ((sym (assert-symbol sym)))
   (match env
    ((environment id type)
     (environment (hash-set id sym (gen-uniq sym)) type)))))


 (: add-type ((U Symbol unique) environment -> environment))
 (define (add-type sym env)
  (let ((sym (assert-symbol sym)))
   (match env
    ((environment id type)
     (environment id (hash-set type sym (gen-uniq sym)))))))



 (: add-identifiers ((Listof (U Symbol unique)) environment -> environment))
 (define (add-identifiers syms env)
  (for/fold: : environment
   ((env : environment env))
   ((sym : (U Symbol unique) syms))
   (add-identifier sym env)))


 (: add-types ((Listof (U Symbol unique)) environment -> environment))
 (define (add-types syms env)
  (for/fold: : environment
   ((env : environment env))
   ((sym : (U Symbol unique) syms))
   (add-type sym env)))


 (: extend-environment ((Listof declaration) environment -> (values (Listof declaration) environment)))
 (define (extend-environment decs env)
  (if (empty? decs) (values empty env)
   (let ((dec (first decs)))
    (match dec
     ((variable-declaration name type value)
      (let ((value ((rename env) value)))
       (let* ((env (add-identifier name env))
              (name (lookup-identifier name env))
              (type ((rename env) type)))
        (let-values (((decs env) (extend-environment (rest decs) env)))
         (values (cons (variable-declaration name type value) decs) env)))))
     ((untyped-variable-declaration name value)
      (let ((value ((rename env) value)))
       (let* ((env (add-identifier name env))
              (name (lookup-identifier name env)))
        (let-values (((decs env) (extend-environment (rest decs) env)))
         (values (cons (untyped-variable-declaration name value) decs) env)))))
     ((function-declaration name args type body)
      (let-values (((fun-decs decs) (span function-declaration? decs)))
       (let-values (((fun-decs env) (rename-functions fun-decs env)))
        (let-values (((decs env) (extend-environment decs env)))
         (values (append fun-decs decs) env)))))
     ((type-declaration name type)
      (let-values (((type-decs decs) (span type-declaration? decs)))
       (let-values (((type-decs env) (rename-types type-decs env)))
        (let-values (((decs env) (extend-environment decs env)))
         (values (append type-decs decs) env)))))))))


 (: rename-functions ((Listof function-declaration) environment -> (values (Listof function-declaration) environment)))
 (define (rename-functions decs env)
  (let ((names (map function-declaration-name decs)))
   (let ((env (add-identifiers names env)))
    (values
     (map (lambda: ((dec : function-declaration))
      (match dec
       ((function-declaration name args type body)
        (let ((arg-names (map (inst car (U Symbol unique) type-reference) args))
              (arg-types (map (inst cdr (U Symbol unique) type-reference) args)))
         (let ((inner-env (add-identifiers arg-names env)))
          (let ((arg-names (map (lambda: ((name : (U Symbol unique))) (lookup-identifier name inner-env)) arg-names)))
           (let ((recur (rename inner-env)))
            (function-declaration 
             (lookup-identifier name env)
             (map (inst cons (U Symbol unique) type-reference)
               arg-names
               (map recur arg-types))
             (and type (recur type))
             (recur body))))))))) decs)
     env))))

 (: rename-types ((Listof type-declaration) environment -> (values (Listof type-declaration) environment)))
 (define (rename-types decs env)
  (let ((names (map type-declaration-name decs)))
   (let ((env (add-types names env)))
    (values
     (map (lambda: ((dec : type-declaration))
      (match dec
       ((type-declaration name type)
        (type-declaration
         (lookup-type name env)
         ((rename env) type))))) decs)
     env))))

 ((rename env) prog))













 

(: span (All (a b) ((a -> Any : b) (Listof a) -> (values (Listof b) (Listof a)))))
(define (span f list)
 (if (empty? list) (values empty empty)
  (let ((elem (first list)))
   (if (f elem)
       (let-values (((f r) (span f (rest list))))
        (values (cons elem f) r))
       (values empty list)))))
   
(: map2 (All (a b c) ((a -> (values b c)) (Listof a) -> (values (Listof b) (Listof c)))))
(define (map2 f lst)
 (cond
  ((empty? lst) (values empty empty))
  (else
   (let-values (((b c) (f (first lst)))
                ((bs cs) (map2 f (rest lst))))
    (values (cons b bs) (cons c cs))))))










(: break-check (expression -> Boolean))
(define (break-check prog)
 (define-type updater ((U expression declaration) -> Boolean))
 (: check (Boolean -> updater))
 (define (check valid)
  (: recur updater)
  (define (recur prog)
   (match prog
    ((identifier sym) #t)
    ((field-ref base field ty) (recur base))
    ((array-ref base index ty) (and (recur base) (recur index)))
    ((binder declarations body)
      (and (andmap recur declarations) (recur body)))
    ((sequence exprs) (andmap recur exprs))
    ((assignment value expr)
     (and (recur value) (recur expr)))
    ((if-then-else c t f ty)
     (and (recur c) (recur t) (and f (recur f))))
    ((integer-literal v) #t)
    ((string-literal s) #t)
    ((nil _) #t)
    ((negation expr) (recur expr))
    ((function-call fun args ty)
     (and (recur fun) (andmap recur args)))
    ((math op left right)
     (and (recur left) (recur right)))
    ((comparison op left right ty)
     (and (recur left) (recur right)))
    ((equality op left right ty)
     (and (recur left) (recur right)))
    ((create-record type fields)
     (andmap recur (map (inst cdr Symbol expression) fields)))
    ((create-array type size value)
     (and (recur size) (recur value)))
    ((while-loop guard body)
     (and (recur guard) ((check #t) body)))
    ((for-loop id init final body)
     (and (recur init) (recur final) ((check #t) body)))
    ((break) valid)
    ((type-declaration name type) #t)
    ((function-declaration name args return-type body)
     ((check #f) body))
    ((variable-declaration sym type value)
     (recur value))
    ((untyped-variable-declaration sym value)
     (recur value))
    (else (error 'break-check "Missing case ~a" prog))
    ))
       
  recur)
 ((check #f) prog))



