;; Content Rights Protocol
;; Enables content licensing with royalty payments

(define-map license-records
    { license-id: (buff 32), content: principal, units: uint, licensee: principal }
    { active: bool, timestamp: uint })

(define-map registered-content principal bool)
(define-map processed-licenses (buff 32) bool)
(define-map pending-royalties {content: principal, account: principal} uint)
(define-trait content-trait
    (
        (transfer (uint principal principal (optional (buff 34))) (response bool uint))
        (get-name () (response (string-ascii 32) uint))
        (get-symbol () (response (string-ascii 32) uint))
        (get-decimals () (response uint uint))
        (get-balance (principal) (response uint uint))
        (get-total-supply () (response uint uint))
        (get-token-uri () (response (optional (string-utf8 256)) uint))
    )
)

(define-constant MINIMUM_LICENSE u100000)
(define-constant ROYALTY_EXPIRY u144)
(define-constant CREATOR_ROYALTY u100) ;; 1% royalty

;; Error codes
(define-constant ERR_NOT_AUTHORIZED (err u1))
(define-constant ERR_BELOW_MINIMUM (err u2))
(define-constant ERR_INSUFFICIENT_FUNDS (err u3))
(define-constant ERR_PROTOCOL_PAUSED (err u4))
(define-constant ERR_INVALID_ACTION (err u5))
(define-constant ERR_INVALID_OPERATION (err u6))
(define-constant ERR_ALREADY_LICENSED (err u7))
(define-constant ERR_LICENSE_TIMEOUT (err u8))
(define-constant ERR_INVALID_LICENSEE (err u9))
(define-constant ERR_INVALID_LICENSE_ID (err u10))
(define-constant ERR_CONTENT_NOT_REGISTERED (err u11))
(define-constant ERR_ROYALTY_ERROR (err u12))


;; Data Variables and Maps
(define-data-var registry-owner principal tx-sender)
(define-data-var protocol-paused bool false)
(define-data-var minimum-license-fee uint MINIMUM_LICENSE)
(define-data-var royalty-rate uint CREATOR_ROYALTY)

(define-map creator-vaults {content: principal, account: principal} uint)

;; Helper Functions
(define-private (meets-minimum-fee (units uint))
    (>= units (var-get minimum-license-fee)))

(define-private (is-registry-owner)
    (is-eq tx-sender (var-get registry-owner)))

(define-private (check-license-status (license-id (buff 32)))
    (default-to false (map-get? processed-licenses license-id)))

(define-private (validate-licensee (licensee principal))
    (and
        (not (is-eq licensee tx-sender))
        (not (is-eq licensee (var-get registry-owner)))))

(define-private (is-content-registered (content principal))
  (default-to false (map-get? registered-content content)))

(define-private (get-vault-amount (vault-data {content: principal, account: principal}))
  (default-to u0 (map-get? creator-vaults vault-data)))

(define-private (calculate-creator-royalty (units uint))
  (let ((royalty (/ (* units (var-get royalty-rate)) u10000)))
    (if (> royalty u0)
        (ok royalty)
        (err u12))))

(define-private (validate-license-data (content <content-trait>) (units uint))
    (let ((sender tx-sender))
        (asserts! (not (var-get protocol-paused)) ERR_PROTOCOL_PAUSED)
        (asserts! (meets-minimum-fee units) ERR_BELOW_MINIMUM)
        (asserts! (is-content-registered (contract-of content)) ERR_CONTENT_NOT_REGISTERED)
        (asserts! (>= (get-vault-amount {content: (contract-of content), account: sender}) units) ERR_INSUFFICIENT_FUNDS)
        (ok true)))

;; Public Functions
(define-public (request-license (license-id (buff 32)) (content <content-trait>) (units uint) (licensee principal))
    (begin
        (asserts! (meets-minimum-fee units) ERR_BELOW_MINIMUM)
        (asserts! (> (len license-id) u0) ERR_INVALID_LICENSE_ID)
        (asserts! (validate-licensee licensee) ERR_INVALID_LICENSEE)
        (asserts! (is-content-registered (contract-of content)) ERR_CONTENT_NOT_REGISTERED)
        (let ((validated (try! (validate-license-data content units))))
            (try! (contract-call? content transfer units tx-sender (as-contract tx-sender) none))
            (map-set processed-licenses license-id true)
            (map-set license-records
                { license-id: license-id, content: (contract-of content), units: units, licensee: licensee }
                { active: false, timestamp: burn-block-height })
            (ok true))))

(define-public (activate-license (license-id (buff 32)) (content <content-trait>) (units uint) (licensee principal))
    (begin
        (asserts! (is-registry-owner) ERR_NOT_AUTHORIZED)
        (asserts! (meets-minimum-fee units) ERR_BELOW_MINIMUM)
        (asserts! (> (len license-id) u0) ERR_INVALID_LICENSE_ID)
        (asserts! (validate-licensee licensee) ERR_INVALID_LICENSEE)
        (asserts! (is-content-registered (contract-of content)) ERR_CONTENT_NOT_REGISTERED)
        (match (map-get? license-records { license-id: license-id, content: (contract-of content), units: units, licensee: licensee })
            record-data (begin
                (asserts! (not (get active record-data)) ERR_INVALID_ACTION)
                (let ((royalty (try! (calculate-creator-royalty units)))
                      (license-amount (- units royalty)))
                    (try! (as-contract (contract-call? content transfer
                            royalty
                            (as-contract tx-sender)
                            (var-get registry-owner)
                            none)))
                    (try! (as-contract (contract-call? content transfer
                        license-amount
                        (as-contract tx-sender)
                        licensee
                        none)))
                    (ok (map-set license-records
                        { license-id: license-id, content: (contract-of content), units: units, licensee: licensee }
                        { active: true, timestamp: burn-block-height }))))
            ERR_INVALID_ACTION)))

;; Admin function to register content
(define-public (register-content (content <content-trait>))
  (begin
    (asserts! (is-registry-owner) ERR_NOT_AUTHORIZED)
    (asserts! (is-ok (contract-call? content get-name)) ERR_INVALID_ACTION)
    (ok (map-set registered-content (contract-of content) true))))

;; Admin function to unregister content
(define-public (unregister-content (content principal))
  (begin
    (asserts! (is-registry-owner) ERR_NOT_AUTHORIZED)
    (asserts! (is-content-registered content) ERR_CONTENT_NOT_REGISTERED)
    (ok (map-delete registered-content content))))

;; Initialize contract (add initial registered content - e.g., STX)
(begin
    (map-set registered-content .stx true) ;; Example: STX is initially registered
    (ok true))