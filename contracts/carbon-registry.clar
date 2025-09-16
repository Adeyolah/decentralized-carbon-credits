;; Carbon Registry Contract
;; Manages registration and verification of carbon reduction projects
;; Tracks project progress and maintains immutable records of carbon credit generation

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-INVALID-STATUS (err u102))
(define-constant ERR-PROJECT-EXISTS (err u103))
(define-constant ERR-INVALID-AMOUNT (err u104))
(define-constant ERR-PROJECT-NOT-VERIFIED (err u105))

;; Data Variables
(define-data-var project-counter uint u0)
(define-data-var credit-counter uint u0)
(define-data-var registry-admin principal CONTRACT-OWNER)

;; Project Data Structure
(define-map projects
  { project-id: uint }
  {
    name: (string-ascii 100),
    description: (string-utf8 500),
    methodology: (string-ascii 50),
    location: (string-ascii 100),
    owner: principal,
    status: (string-ascii 20),
    credits-issued: uint,
    credits-available: uint,
    verification-date: uint,
    registration-date: uint,
    project-type: (string-ascii 30),
    estimated-credits: uint
  }
)

;; Credit Records
(define-map credit-records
  { credit-id: uint }
  {
    project-id: uint,
    amount: uint,
    issue-date: uint,
    batch-number: (string-ascii 50),
    quality-score: uint,
    methodology-version: (string-ascii 20)
  }
)

;; Project Verifiers (authorized to verify projects)
(define-map authorized-verifiers
  { verifier: principal }
  { authorized: bool }
)

;; Project Status History
(define-map project-status-history
  { project-id: uint, status-id: uint }
  {
    status: (string-ascii 20),
    timestamp: uint,
    updated-by: principal,
    notes: (string-utf8 200)
  }
)

;; Read-only functions

(define-read-only (get-project (project-id uint))
  (map-get? projects { project-id: project-id })
)

(define-read-only (get-project-counter)
  (var-get project-counter)
)

(define-read-only (get-credit-counter)
  (var-get credit-counter)
)

(define-read-only (get-credit-record (credit-id uint))
  (map-get? credit-records { credit-id: credit-id })
)

(define-read-only (is-authorized-verifier (verifier principal))
  (default-to false (get authorized (map-get? authorized-verifiers { verifier: verifier })))
)

(define-read-only (get-registry-admin)
  (var-get registry-admin)
)

(define-read-only (get-project-status-history (project-id uint) (status-id uint))
  (map-get? project-status-history { project-id: project-id, status-id: status-id })
)

(define-read-only (get-projects-by-status (status (string-ascii 20)))
  (ok "Query functionality would be implemented with indexing service")
)

;; Private functions

(define-private (is-valid-status (status (string-ascii 20)))
  (or 
    (is-eq status "pending")
    (or (is-eq status "under-review")
    (or (is-eq status "verified")
    (or (is-eq status "active")
    (or (is-eq status "completed")
        (is-eq status "suspended")))))
  )
)

(define-private (record-status-change (project-id uint) (new-status (string-ascii 20)) (notes (string-utf8 200)))
  (let
    (
      (status-counter (+ (len (default-to "" (get notes (get-project-status-history project-id u0)))) u1))
    )
    (map-set project-status-history
      { project-id: project-id, status-id: status-counter }
      {
        status: new-status,
        timestamp: block-height,
        updated-by: tx-sender,
        notes: notes
      }
    )
  )
)

;; Public functions

;; Register a new environmental project
(define-public (register-project 
    (name (string-ascii 100))
    (description (string-utf8 500))
    (methodology (string-ascii 50))
    (location (string-ascii 100))
    (project-type (string-ascii 30))
    (estimated-credits uint))
  (let
    (
      (new-project-id (+ (var-get project-counter) u1))
    )
    (begin
      (asserts! (> estimated-credits u0) ERR-INVALID-AMOUNT)
      (asserts! (> (len name) u0) ERR-INVALID-AMOUNT)
      
      ;; Create project record
      (map-set projects
        { project-id: new-project-id }
        {
          name: name,
          description: description,
          methodology: methodology,
          location: location,
          owner: tx-sender,
          status: "pending",
          credits-issued: u0,
          credits-available: u0,
          verification-date: u0,
          registration-date: block-height,
          project-type: project-type,
          estimated-credits: estimated-credits
        }
      )
      
      ;; Record initial status
      (record-status-change new-project-id "pending" u"Project registered and awaiting initial review")
      
      ;; Update counter
      (var-set project-counter new-project-id)
      
      (ok new-project-id)
    )
  )
)

;; Update project status (only by authorized verifiers)
(define-public (update-project-status 
    (project-id uint) 
    (new-status (string-ascii 20))
    (notes (string-utf8 200)))
  (let
    (
      (project (unwrap! (get-project project-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (is-authorized-verifier tx-sender) ERR-UNAUTHORIZED)
      (asserts! (is-valid-status new-status) ERR-INVALID-STATUS)
      
      ;; Update project status
      (map-set projects
        { project-id: project-id }
        (merge project { 
          status: new-status,
          verification-date: (if (is-eq new-status "verified") block-height (get verification-date project))
        })
      )
      
      ;; Record status change
      (record-status-change project-id new-status notes)
      
      (ok true)
    )
  )
)

;; Issue carbon credits for verified projects
(define-public (issue-credits 
    (project-id uint) 
    (amount uint)
    (batch-number (string-ascii 50))
    (quality-score uint))
  (let
    (
      (project (unwrap! (get-project project-id) ERR-NOT-FOUND))
      (new-credit-id (+ (var-get credit-counter) u1))
      (current-issued (get credits-issued project))
      (current-available (get credits-available project))
    )
    (begin
      (asserts! (is-authorized-verifier tx-sender) ERR-UNAUTHORIZED)
      (asserts! (is-eq (get status project) "verified") ERR-PROJECT-NOT-VERIFIED)
      (asserts! (> amount u0) ERR-INVALID-AMOUNT)
      (asserts! (<= quality-score u100) ERR-INVALID-AMOUNT)
      
      ;; Create credit record
      (map-set credit-records
        { credit-id: new-credit-id }
        {
          project-id: project-id,
          amount: amount,
          issue-date: block-height,
          batch-number: batch-number,
          quality-score: quality-score,
          methodology-version: (get methodology project)
        }
      )
      
      ;; Update project credit counts
      (map-set projects
        { project-id: project-id }
        (merge project {
          credits-issued: (+ current-issued amount),
          credits-available: (+ current-available amount)
        })
      )
      
      ;; Update credit counter
      (var-set credit-counter new-credit-id)
      
      ;; Record status change
      (record-status-change project-id (get status project) u"Carbon credits issued successfully")
      
      (ok new-credit-id)
    )
  )
)

;; Authorize verifier (only admin)
(define-public (authorize-verifier (verifier principal))
  (begin
    (asserts! (is-eq tx-sender (var-get registry-admin)) ERR-UNAUTHORIZED)
    (map-set authorized-verifiers { verifier: verifier } { authorized: true })
    (ok true)
  )
)

;; Revoke verifier authorization (only admin)
(define-public (revoke-verifier (verifier principal))
  (begin
    (asserts! (is-eq tx-sender (var-get registry-admin)) ERR-UNAUTHORIZED)
    (map-set authorized-verifiers { verifier: verifier } { authorized: false })
    (ok true)
  )
)

;; Transfer admin rights (only current admin)
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get registry-admin)) ERR-UNAUTHORIZED)
    (var-set registry-admin new-admin)
    (ok true)
  )
)

;; Update project information (only project owner)
(define-public (update-project-info
    (project-id uint)
    (description (string-utf8 500))
    (location (string-ascii 100)))
  (let
    (
      (project (unwrap! (get-project project-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (is-eq tx-sender (get owner project)) ERR-UNAUTHORIZED)
      
      (map-set projects
        { project-id: project-id }
        (merge project {
          description: description,
          location: location
        })
      )
      
      (record-status-change project-id (get status project) u"Project information updated")
      
      (ok true)
    )
  )
)

;; Reduce available credits (called by marketplace contract)
(define-public (reduce-available-credits (project-id uint) (amount uint))
  (let
    (
      (project (unwrap! (get-project project-id) ERR-NOT-FOUND))
      (current-available (get credits-available project))
    )
    (begin
      (asserts! (>= current-available amount) ERR-INVALID-AMOUNT)
      
      (map-set projects
        { project-id: project-id }
        (merge project {
          credits-available: (- current-available amount)
        })
      )
      
      (ok true)
    )
  )
)