;; Groundwater Depletion Prevention Contract
;; Manages sustainable use of underground water resources

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-AQUIFER-NOT-FOUND (err u301))
(define-constant ERR-PERMIT-NOT-FOUND (err u302))
(define-constant ERR-EXTRACTION-LIMIT-EXCEEDED (err u303))
(define-constant ERR-INVALID-AMOUNT (err u304))
(define-constant ERR-PERMIT-EXPIRED (err u305))

;; Contract owner
(define-constant CONTRACT-OWNER tx-sender)

;; Sustainability thresholds
(define-constant MAX-EXTRACTION-RATE u80) ;; 80% of recharge rate
(define-constant CRITICAL-LEVEL-THRESHOLD u20) ;; 20% of original capacity

;; Data structures
(define-map aquifers
  { aquifer-id: uint }
  {
    name: (string-ascii 100),
    location: (string-ascii 200),
    total-capacity: uint,
    current-level: uint,
    recharge-rate: uint,
    extraction-rate: uint,
    is-critical: bool,
    last-updated: uint
  }
)

(define-map extraction-permits
  { permit-id: uint }
  {
    aquifer-id: uint,
    holder: principal,
    max-extraction: uint,
    current-extraction: uint,
    issued-at: uint,
    expires-at: uint,
    is-active: bool,
    purpose: (string-ascii 100)
  }
)

(define-map extraction-records
  { record-id: uint }
  {
    permit-id: uint,
    aquifer-id: uint,
    amount: uint,
    timestamp: uint,
    method: (string-ascii 50),
    coordinates: (string-ascii 100)
  }
)

(define-map sustainability-assessments
  { assessment-id: uint }
  {
    aquifer-id: uint,
    sustainability-score: uint,
    depletion-risk: uint,
    recommended-limit: uint,
    assessment-date: uint,
    assessor: principal
  }
)

;; Counters
(define-data-var next-aquifer-id uint u1)
(define-data-var next-permit-id uint u1)
(define-data-var next-record-id uint u1)
(define-data-var next-assessment-id uint u1)

;; Register aquifer
(define-public (register-aquifer
  (name (string-ascii 100))
  (location (string-ascii 200))
  (total-capacity uint)
  (current-level uint)
  (recharge-rate uint))
  (let ((aquifer-id (var-get next-aquifer-id)))
    (asserts! (> total-capacity u0) ERR-INVALID-AMOUNT)
    (asserts! (<= current-level total-capacity) ERR-INVALID-AMOUNT)

    (map-set aquifers
      { aquifer-id: aquifer-id }
      {
        name: name,
        location: location,
        total-capacity: total-capacity,
        current-level: current-level,
        recharge-rate: recharge-rate,
        extraction-rate: u0,
        is-critical: (< (* current-level u100) (* total-capacity CRITICAL-LEVEL-THRESHOLD)),
        last-updated: block-height
      }
    )
    (var-set next-aquifer-id (+ aquifer-id u1))
    (ok aquifer-id)
  )
)

;; Issue extraction permit
(define-public (issue-permit
  (aquifer-id uint)
  (holder principal)
  (max-extraction uint)
  (duration uint)
  (purpose (string-ascii 100)))
  (let ((permit-id (var-get next-permit-id)))
    (asserts! (is-some (map-get? aquifers { aquifer-id: aquifer-id })) ERR-AQUIFER-NOT-FOUND)
    (asserts! (> max-extraction u0) ERR-INVALID-AMOUNT)

    ;; Check sustainability
    (asserts! (try! (is-extraction-sustainable aquifer-id max-extraction)) ERR-EXTRACTION-LIMIT-EXCEEDED)

    (map-set extraction-permits
      { permit-id: permit-id }
      {
        aquifer-id: aquifer-id,
        holder: holder,
        max-extraction: max-extraction,
        current-extraction: u0,
        issued-at: block-height,
        expires-at: (+ block-height duration),
        is-active: true,
        purpose: purpose
      }
    )
    (var-set next-permit-id (+ permit-id u1))
    (ok permit-id)
  )
)

;; Record extraction
(define-public (record-extraction
  (permit-id uint)
  (amount uint)
  (method (string-ascii 50))
  (coordinates (string-ascii 100)))
  (let ((record-id (var-get next-record-id)))
    (match (map-get? extraction-permits { permit-id: permit-id })
      permit-data
      (begin
        (asserts! (get is-active permit-data) ERR-PERMIT-EXPIRED)
        (asserts! (< block-height (get expires-at permit-data)) ERR-PERMIT-EXPIRED)
        (asserts! (<= (+ (get current-extraction permit-data) amount) (get max-extraction permit-data)) ERR-EXTRACTION-LIMIT-EXCEEDED)

        ;; Update permit usage
        (map-set extraction-permits
          { permit-id: permit-id }
          (merge permit-data { current-extraction: (+ (get current-extraction permit-data) amount) })
        )

        ;; Record extraction
        (map-set extraction-records
          { record-id: record-id }
          {
            permit-id: permit-id,
            aquifer-id: (get aquifer-id permit-data),
            amount: amount,
            timestamp: block-height,
            method: method,
            coordinates: coordinates
          }
        )

        ;; Update aquifer levels
        (try! (update-aquifer-level (get aquifer-id permit-data) amount))

        (var-set next-record-id (+ record-id u1))
        (ok record-id)
      )
      ERR-PERMIT-NOT-FOUND
    )
  )
)

;; Update aquifer level after extraction
(define-private (update-aquifer-level (aquifer-id uint) (extracted-amount uint))
  (match (map-get? aquifers { aquifer-id: aquifer-id })
    aquifer-data
    (let ((new-level (- (get current-level aquifer-data) extracted-amount))
          (new-extraction-rate (+ (get extraction-rate aquifer-data) extracted-amount)))
      (map-set aquifers
        { aquifer-id: aquifer-id }
        (merge aquifer-data {
          current-level: new-level,
          extraction-rate: new-extraction-rate,
          is-critical: (< (* new-level u100) (* (get total-capacity aquifer-data) CRITICAL-LEVEL-THRESHOLD)),
          last-updated: block-height
        })
      )
      (ok true)
    )
    ERR-AQUIFER-NOT-FOUND
  )
)

;; Check if extraction is sustainable
(define-private (is-extraction-sustainable (aquifer-id uint) (proposed-extraction uint))
  (match (map-get? aquifers { aquifer-id: aquifer-id })
    aquifer-data
    (let ((total-extraction (+ (get extraction-rate aquifer-data) proposed-extraction))
          (sustainable-limit (* (get recharge-rate aquifer-data) MAX-EXTRACTION-RATE)))
      (ok (<= (* total-extraction u100) sustainable-limit))
    )
    ERR-AQUIFER-NOT-FOUND
  )
)

;; Conduct sustainability assessment
(define-public (conduct-assessment
  (aquifer-id uint)
  (sustainability-score uint)
  (depletion-risk uint)
  (recommended-limit uint))
  (let ((assessment-id (var-get next-assessment-id)))
    (asserts! (is-some (map-get? aquifers { aquifer-id: aquifer-id })) ERR-AQUIFER-NOT-FOUND)
    (asserts! (<= sustainability-score u100) ERR-INVALID-AMOUNT)
    (asserts! (<= depletion-risk u100) ERR-INVALID-AMOUNT)

    (map-set sustainability-assessments
      { assessment-id: assessment-id }
      {
        aquifer-id: aquifer-id,
        sustainability-score: sustainability-score,
        depletion-risk: depletion-risk,
        recommended-limit: recommended-limit,
        assessment-date: block-height,
        assessor: tx-sender
      }
    )
    (var-set next-assessment-id (+ assessment-id u1))
    (ok assessment-id)
  )
)

;; Read-only functions
(define-read-only (get-aquifer (aquifer-id uint))
  (map-get? aquifers { aquifer-id: aquifer-id })
)

(define-read-only (get-permit (permit-id uint))
  (map-get? extraction-permits { permit-id: permit-id })
)

(define-read-only (get-extraction-record (record-id uint))
  (map-get? extraction-records { record-id: record-id })
)

(define-read-only (get-assessment (assessment-id uint))
  (map-get? sustainability-assessments { assessment-id: assessment-id })
)

(define-read-only (get-aquifer-health (aquifer-id uint))
  (match (map-get? aquifers { aquifer-id: aquifer-id })
    aquifer-data
    (let ((capacity-percentage (* (/ (get current-level aquifer-data) (get total-capacity aquifer-data)) u100))
          (extraction-percentage (* (/ (get extraction-rate aquifer-data) (get recharge-rate aquifer-data)) u100)))
      (ok {
        capacity-remaining: capacity-percentage,
        extraction-vs-recharge: extraction-percentage,
        is-sustainable: (<= extraction-percentage MAX-EXTRACTION-RATE),
        is-critical: (get is-critical aquifer-data)
      })
    )
    ERR-AQUIFER-NOT-FOUND
  )
)
