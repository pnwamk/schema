#lang digimon

(provide (all-defined-out))

(require typed/db)
(require "virtual-sql.rkt")

(require (for-syntax "normalize.rkt"))

(struct exn:schema exn:fail:sql () #:extra-constructor-name make-exn:schema)

(define raise-schema-error : (-> Symbol Symbol (Listof (Pairof Symbol Any)) String Any * exn:schema)
  (lambda [src sqlstate info msgfmt . argl]
    (define message : String (if (null? argl) msgfmt (apply format msgfmt argl)))
    (raise (make-exn:schema (format "~a: ~a" src message) (current-continuation-marks)
                            sqlstate (list* (cons 'code sqlstate) (cons 'message message) info)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define-syntax (define-table stx)
  (define (parse-field-definition tablename rowid racket? stx)
    (syntax-parse stx
      [(field DataType (~or (~optional (~seq #:check contract:expr))
                            (~optional (~or (~seq #:default defval) (~seq #:auto generate)) #:name "#:default or #:auto")
                            (~optional (~seq #:guard guard) #:name "#:guard")
                            (~optional (~seq (~and #:not-null not-null)) #:name "#:not-null")
                            (~optional (~seq (~and #:unique unique)) #:name "#:unique")
                            (~optional (~seq (~and #:hide hide)) #:name "#:hide")) ...)
       (define-values (primary-field? not-null?) (values (eq? (syntax-e #'field) rowid) (attribute not-null)))
       (define table-field (format-id #'field "~a-~a" tablename (syntax-e #'field)))
       (values (and primary-field? (list table-field #'DataType))
               (list (datum->syntax #'field (string->keyword (symbol->string (syntax-e #'field))))
                     table-field (if (attribute contract) #'contract #'#true)
                     (if (or primary-field? (attribute not-null)) #'DataType #'(Option DataType))
                     (if (attribute generate) #'generate #'(void))
                     (cond [(attribute defval) #'(defval)]
                           [(attribute generate) #'(generate)]
                           [(or primary-field? not-null?) #'()]
                           [else #'(#false)]))
               (unless (and racket? (attribute hide))
                 (list #'field (id->sql #'field) table-field #'DataType
                       (or (attribute guard) #'racket->sql)
                       (and not-null? #'#true)
                       (and (attribute unique) #'#true))))]))
  (syntax-parse stx #:datum-literals [:]
    [(_ id #:as Table #:with primary-key (~optional prefab) ([field : DataType constraints ...] ...)
        (~optional (~seq #:check record-contract:expr) #:defaults ([record-contract #'#true])))
     (with-syntax* ([(rowid ___) (list (id->sql #'primary-key) (format-id #'id "..."))]
                    [(table dbtable) (syntax-parse #'id [(id db) (list #'id (id->sql #'db))] [id (list #'id (id->sql #'id))])]
                    [(racket :opt) (if (attribute prefab) (list (id->sql #'prefab) #'#:prefab) (list #'#false #'#:transparent))]
                    [([(table-rowid RowidType) (:field table-field field-contract FieldType on-update [defval ...]) ...]
                      [(column-id column table-column ColumnType column-guard column-not-null column-unique) ...]
                      [table? table-row?] [check-fields table.sql]
                      [unsafe-table make-table remake-table create-table insert-table delete-table in-table select-table update-table])
                     (let ([tablename (syntax-e #'table)]
                           [pkname (syntax-e #'primary-key)]
                           [racket? (and (syntax-e #'racket) #true)])
                       (define-values (sdleif snmuloc rowid-info)
                         (for/fold ([sdleif null] [snmuloc null] [rowid-info #false])
                                   ([stx (in-syntax #'([field DataType constraints ...] ...))])
                           (define-values (pk-info field-info column-info) (parse-field-definition tablename pkname racket? stx))
                           (cond [(void? column-info) (values (cons field-info sdleif) snmuloc rowid-info)]
                                 [else (values (cons field-info sdleif) (cons column-info snmuloc) (or rowid-info pk-info))])))
                       (list (cons (or rowid-info (list #'#false #'Any)) (reverse sdleif)) (reverse snmuloc)
                             (for/list ([fmt (in-list (list "~a?" "~a-row?"))]) (format-id #'table fmt tablename))
                             (for/list ([idx (in-range 2)]) (datum->syntax #'table (gensym tablename)))
                             (for/list ([prefix (in-list (list 'unsafe 'make 'remake 'create 'insert 'delete 'in 'select 'update))])
                               (format-id #'table "~a-~a" prefix tablename))))]
                    [([mkargs ...] [reargs ...])
                     (for/fold ([syns (list null null)])
                               ([:fld (in-syntax #'(:field ...))]
                                [mkarg (in-syntax #'([field : FieldType defval ...] ...))]
                                [rearg (in-syntax #'([field : (U FieldType Void) on-update] ...))])
                       (list (cons :fld (cons mkarg (car syns)))
                             (cons :fld (cons rearg (cadr syns)))))])
       #'(begin (define-type Table table)
                (struct table ([field : FieldType] ...) :opt #:constructor-name unsafe-table)
                (define-predicate table-row? (List FieldType ...))
                (define table.sql : (HashTable Symbol Statement) (make-hasheq))
                
                (define-syntax (check-fields stx)
                  (syntax-case stx []
                    [(_ func field ...)
                     #'(unless (and field-contract ... record-contract)
                         (define expected : (Listof Any)
                           (for/list ([result (in-list (list record-contract field-contract ...))]
                                      [expected (in-list (list 'record-contract 'field-contract ...))]
                                      #:when (false? result)) expected))
                         (define ?fields (remove-duplicates (filter symbol? (flatten expected))))
                         (define given (filter-map (λ [f v] (and (memq f ?fields) (cons f v))) (list 'field ...) (list field ...)))
                         (raise-schema-error func 'contract `((struct . table) (expected . ,(~s expected)) (given . ,(~s given)))
                                             "constraint violation"))]))

                (define (make-table #:unsafe? [unsafe? : Boolean #false] mkargs ...) : Table
                  (when (not unsafe?) (check-fields 'make-table field ...))
                  (unsafe-table field ...))

                (define (remake-table [record : Table] reargs ...) : Table
                  (let ([field : FieldType (if (void? field) (table-field record) field)] ...)
                    (check-fields 'remake-table field ...)
                    (unsafe-table field ...)))

                (define (create-table [dbc : Connection] #:if-not-exists? [silent? : Boolean #false]) : Void
                  (when (false? table-rowid) (raise-unsupported-error 'create-table "no need to create a temporary view"))
                  (define (virtual.sql) : Virtual-Statement
                    (create-table.sql silent? dbtable rowid racket '(column ...) '(column-not-null ...) '(column-unique ...)))
                  (query-exec dbc (hash-ref! table.sql (if silent? 'create-if-not-exists 'create) virtual.sql)))

                (define (insert-table [dbc : Connection] [records : (U Table (Listof Table))]
                                      #:or-replace? [replace? : Boolean #false]) : Void
                  (define (virtual.sql) : Virtual-Statement (insert-into.sql replace? dbtable racket '(column ...)))
                  (when (false? table-rowid) (raise-unsupported-error 'create-table "cannot insert records into a temporary view"))
                  (define dbsys : Symbol (dbsystem-name (connection-dbsystem dbc)))
                  (define insert.sql : Statement (hash-ref! table.sql (if replace? 'replace 'insert) virtual.sql))
                  (for ([row (if (list? records) (in-list records) (in-value records))])
                    (define column-id : SQL-Datum (column-guard 'column-id (table-column row) dbsys)) ...
                    (cond [(false? racket) (query-exec dbc insert.sql column-id ...)]
                          [else (query-exec dbc insert.sql column-id ... (call-with-output-string (λ [db] (write row db))))])))
       
                (define (delete-table [dbc : Connection] [records : (U Table (Listof Table))]) : Void
                  (define (virtual.sql) : Virtual-Statement (delete.sql dbtable rowid))
                  (cond [(false? table-rowid) (raise-unsupported-error 'create-table "cannot delete records from a temporary view")]
                        [else (for ([record (if (list? records) (in-list records) (in-value records))])
                                (query-exec dbc (hash-ref! table.sql 'delete-table-by-rowid virtual.sql) (table-rowid record)))]))

                (define-syntax (select-table stx) (syntax-case stx [] [(_ argl ___) #'(sequence->list (in-table argl ___))]))
                (define (in-table [dbc : Connection] #:fetch [size : (U Positive-Integer +inf.0) 1]) : (Sequenceof (U Table exn))
                  (define (virtual.sql [which : Symbol]) : (-> Virtual-Statement)
                    (thunk (simple-select.sql which dbtable rowid racket '(column ...))))
                  (define (read-table sexp) : (U Table exn)
                    (with-handlers ([exn? (λ [[e : exn]] e)])
                      (read/assert sexp table?)))
                  (define (read-by-pk [pk : SQL-Datum]) : (U Table exn)
                    (with-handlers ([exn? (λ [[e : exn]] e)])
                      (define record : (Listof SQL-Datum)
                        (for/list ([row (in-vector (query-row dbc (hash-ref table.sql 'select-row (virtual.sql 'row)) pk))])
                          (if (sql-null? row) #false row)))
                      (apply unsafe-table (assert record table-row?))))
                  (define-values (key fmap) (if (and racket) (values 'select-racket read-table) (values 'select-rowid read-by-pk)))
                  (sequence-map fmap (in-query dbc #:fetch size (hash-ref table.sql key (virtual.sql 'nowhere)))))

                (define (update-table [dbc : Connection] [records : (U Table (Listof Table))]
                                      #:check-first? [check? : Boolean #true]) : Void
                  (define (virtual.sql [ensure? : Boolean]) : (-> Virtual-Statement)
                    (thunk (cond [(not ensure?) (update.sql dbtable rowid racket '(column ...))]
                                 [else (simple-select.sql 'ckrowid dbtable rowid racket '(column ...))])))
                  (cond [(false? table-rowid) (raise-unsupported-error 'create-table "cannot update records of a temporary view")]
                        [else (let ([dbsys (dbsystem-name (connection-dbsystem dbc))])
                                (define update.sql : Statement (hash-ref! table.sql 'update (virtual.sql #false)))
                                (define check.sql : Statement (hash-ref! table.sql 'check-rowid (virtual.sql #true)))
                                (for ([record (if (list? records) (in-list records) (in-value records))])
                                  (define pk : RowidType (table-rowid record))
                                  (when (and check? (false? (query-maybe-value dbc check.sql pk)))
                                    (raise-schema-error 'update-table 'norow `((struct . table) (record . ,pk))
                                                        "no such record found in the table"))
                                  (define column-id : SQL-Datum (column-guard 'column-id (table-column record) dbsys)) ...
                                  (cond [(false? racket) (query dbc update.sql column-id ... pk)]
                                        [else (query dbc update.sql column-id ...
                                                     (call-with-output-string (λ [db] (write record db))) pk)])))]))))]))

(define-syntax (define-schema stx)
  (syntax-parse stx
    [(_ Table-Datum (define-table id #:as ID rest ...) ...)
     #'(begin (define-type Table-Datum (U ID ...))
              (define-table id #:as ID rest ...) ...)]))