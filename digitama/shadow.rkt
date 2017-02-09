#lang digimon/sugar

(provide (all-defined-out))

(require racket/list)
(require racket/bool)

(require typed/db/base)

(require "message.rkt")
(require "virtual-sql.rkt")

(define do-create-table : (-> (Option Symbol) Symbol (Option Symbol) Connection String (Listof+ String) (Option String)
                              (Listof String) (Listof String) (Listof Boolean) (Listof Boolean) Void)
  (lambda [func create maybe-force dbc dbtable rowid eam cols types not-nulls uniques]
    (unless (not func) (throw exn:fail:unsupported func "cannot create a temporary view"))
    (define (mksql) : Virtual-Statement (create-table.sql maybe-force dbtable rowid eam cols types not-nulls uniques))
    (query-exec dbc (sql-ref! (or maybe-force create) mksql))))

(define do-insert-table : (All (a) (-> (Option Symbol) Symbol (Option Symbol) String (Option String) (Listof String)
                                       Connection (Sequenceof a) (Listof (-> a Any)) (-> a SQL-Datum) Void))
  (lambda [func insert maybe-replace dbtable eam cols dbc selves refs serialize]
    (define (mksql) : Virtual-Statement (insert-into.sql maybe-replace dbtable eam cols))
    (unless (not func) (throw exn:fail:unsupported func "cannot insert records into a temporary view"))
    (define insert.sql : Statement (sql-ref! (or maybe-replace insert) mksql))
    (define dbsys : Symbol (dbsystem-name (connection-dbsystem dbc)))
    (for ([record : a selves])
      (define metrics : (Listof SQL-Datum) (for/list ([ref (in-list refs)]) (racket->sql (ref record) dbsys)))
      (cond [(false? eam) (apply query-exec dbc insert.sql metrics)]
            [else (apply query-exec dbc insert.sql (serialize record) metrics)]))))

(define do-delete-from-table : (All (a) (-> Symbol Boolean String (Listof+ String)
                                            Connection (Sequenceof a) (Listof (-> a SQL-Datum)) Void))
  (lambda [func view? dbtable rowid dbc selves refs]
    (define (mksql) : Virtual-Statement (delete-from.sql dbtable rowid))
    (when view? (throw exn:fail:unsupported func "cannot delete records from a temporary view"))
    (define delete.sql : Statement (sql-ref! func mksql))
    (for ([record : a selves])
      (apply query-exec dbc delete.sql
             (for/list : (Listof SQL-Datum) ([ref (in-list refs)]) (ref record))))))

(define do-update-table : (All (a) (-> Symbol Boolean Symbol (Option Symbol) String (Listof+ String) (Option String) (Listof+ String)
                                       Connection (Sequenceof a) (Listof (-> a Any)) (Listof (-> a SQL-Datum)) (-> a SQL-Datum) Void))
  (lambda [func view? table maybe-chpk dbtable rowid eam cols dbc selves refs pkrefs serialize]
    (when view? (throw exn:fail:unsupported func "cannot update records of a temporary view"))
    (define (mkup) : Virtual-Statement (update.sql dbtable rowid eam cols))
    (define (mkck) : Virtual-Statement (simple-select.sql 'ckrowid dbtable rowid eam cols))
    (define up.sql : Statement (sql-ref! func mkup))
    (define ck.sql : Statement (if maybe-chpk (sql-ref! maybe-chpk mkck) up.sql))
    (define dbsys : Symbol (dbsystem-name (connection-dbsystem dbc)))
    (for ([record : a selves])
      (define rowid : (Listof SQL-Datum) (for/list ([ref (in-list pkrefs)]) (ref record)))
      (when (and maybe-chpk (false? (apply query-maybe-value dbc ck.sql rowid)))
        (schema-throw [exn:schema 'norow `((struct . ,table) (record . ,(list->vector rowid)))]
                      func "no such record found in the table"))
      (define metrics : (Listof SQL-Datum) (for/list ([ref (in-list refs)]) (racket->sql (ref record) dbsys)))
      (cond [(false? eam) (apply query dbc up.sql (append metrics rowid))]
            [else (apply query dbc up.sql (serialize record) (append metrics rowid))]))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define get-select-sql : (-> Symbol (Option Symbol) Symbol Symbol String (Listof+ String) (Option String) (Listof String)
                             (Values Statement Statement))
  (lambda [select-rowid maybe-where select-racket select-row dbtable rowid eam cols]
    (define (mksql [method : Symbol]) : (-> Statement) (λ [] (simple-select.sql method dbtable rowid eam cols)))
    (define sql : Statement
      (cond [(and maybe-where) (sql-ref! maybe-where (mksql 'byrowid))]
            [(and eam) (sql-ref! select-racket (mksql 'nowhere))]
            [else (sql-ref! select-rowid (mksql 'nowhere))]))
    (cond [(not eam) (values sql (sql-ref! select-row (mksql 'row)))]
          [else (values sql sql)])))

(define select-row-from-table : (All (a) (-> Symbol Symbol Connection Statement (Vectorof SQL-Datum)
                                             (-> Any Boolean : #:+ a) (Listof (-> String Any)) a))
  (lambda [func table dbc select.sql rowid table-row? guards]
    (define metrics : (Listof Any)
      (for/list ([sql (in-vector (apply query-row dbc select.sql (vector->list rowid)))]
                 [guard (in-list guards)])
        (sql->racket sql guard)))
    (cond [(table-row? metrics) metrics]
          [else (schema-throw [exn:schema 'assertion `((struct . ,table) (record . ,rowid) (got . ,metrics))]
                              func "maybe the database is penetrated")])))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define sqls : (HashTable Symbol Statement) (make-hasheq))
(define sql-ref! : (-> Symbol (-> Statement) Statement)
  (lambda [which mksql]
    (hash-ref! sqls which mksql)))

(define check-constraint : (-> Symbol Symbol (Listof Symbol) (Listof Any) (Listof Any) Any * Void)
  (lambda [func table fields literals contracts  . givens]
    (when (memq #false contracts)
      (define expected : (Listof Any)
        (for/list ([result (in-list contracts)]
                   [expected (in-list literals)]
                   #:when (false? result))
          expected))
      (define ?fields : (Listof Symbol) (remove-duplicates (filter symbol? (flatten expected))))
      (define given : HashTableTop
        (for/hasheq ([f (in-list fields)]
                     [v (in-list givens)]
                     #:when (memq f ?fields))
            (values f v)))
      (schema-throw [exn:schema 'contract `((struct . ,table) (expected . ,expected) (given . ,given))]
                    func "constraint violation"))))

(define check-default-value : (All (a) (-> Symbol Symbol (U a Void) a))
  (lambda [func field defval]
    (when (void? defval) (error func "missing value for field '~a'" field))
    defval))

(define check-row : (All (a) (-> Symbol (Listof Any) (-> Any Boolean : #:+ a) String Any * a))
  (lambda [func metrics table-row? errfmt . errmsg]
    (cond [(table-row? metrics) metrics]
          [else (apply error func errfmt errmsg)])))

(define field-value : (All (a b c) (-> Symbol Symbol (Option a) (-> a b) (U b Void) (-> (U c Void)) (U b c)))
  (lambda [func field self table-field value mkdefval]
    (cond [(not (void? value)) value]
          [(not self) (check-default-value func field (mkdefval))]
          [else (table-field self)])))

(define record-ref : (All (a) (-> Symbol HashTableTop (Listof Symbol) (Listof (-> Any)) (-> Any Boolean : #:+ a) a))
  (lambda [func src fields mkdefval table-row?]
    (define metrics : (Listof Any)
      (for/list ([field (in-list fields)]
                 [mkval (in-list mkdefval)])
        (hash-ref src field (λ [] (check-default-value func field (mkval))))))
    (check-row func metrics table-row? "mismatched source: ~a" metrics)))

(define make-dict : (All (a) (-> (Listof Symbol) (Listof a) Boolean (HashTable Symbol a)))
  (lambda [fields fvalues skip?]
    (cond [(not skip?) (make-immutable-hasheq (map (inst cons Symbol a) fields fvalues))]
          [else (for/hasheq : (HashTable Symbol a)
                  ([key (in-list fields)]
                   [val (in-list fvalues)]
                   #:when val)
                  (values key val))])))