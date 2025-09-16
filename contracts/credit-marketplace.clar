;; Credit Marketplace Contract
;; Facilitates trading of verified carbon credits between buyers and sellers
;; Implements dynamic pricing and automatic retirement upon purchase

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-NOT-FOUND (err u201))
(define-constant ERR-INSUFFICIENT-CREDITS (err u202))
(define-constant ERR-INVALID-PRICE (err u203))
(define-constant ERR-INVALID-AMOUNT (err u204))
(define-constant ERR-LISTING-NOT-ACTIVE (err u205))
(define-constant ERR-INSUFFICIENT-FUNDS (err u206))
(define-constant ERR-SAME-SELLER (err u207))
(define-constant ERR-MARKETPLACE-PAUSED (err u208))

;; Data Variables
(define-data-var listing-counter uint u0)
(define-data-var transaction-counter uint u0)
(define-data-var marketplace-admin principal CONTRACT-OWNER)
(define-data-var marketplace-paused bool false)
(define-data-var marketplace-fee-percentage uint u250) ;; 2.5% = 250 basis points
(define-data-var base-price uint u1000000) ;; Base price in microSTX (1 STX = 1,000,000 microSTX)

;; Credit Listings
(define-map credit-listings
  { listing-id: uint }
  {
    seller: principal,
    project-id: uint,
    amount: uint,
    price-per-credit: uint,
    total-price: uint,
    listing-date: uint,
    expiry-date: uint,
    status: (string-ascii 20),
    quality-score: uint,
    project-type: (string-ascii 30)
  }
)

;; Transaction Records
(define-map transaction-records
  { transaction-id: uint }
  {
    listing-id: uint,
    buyer: principal,
    seller: principal,
    project-id: uint,
    amount: uint,
    price-per-credit: uint,
    total-amount: uint,
    marketplace-fee: uint,
    transaction-date: uint,
    retirement-immediate: bool
  }
)

;; User Credit Holdings
(define-map user-credit-holdings
  { user: principal, project-id: uint }
  {
    total-credits: uint,
    available-credits: uint,
    retired-credits: uint
  }
)

;; Market Statistics
(define-map project-market-stats
  { project-id: uint }
  {
    total-traded: uint,
    average-price: uint,
    last-trade-price: uint,
    trade-count: uint,
    market-cap: uint
  }
)

;; Price History (for trending analysis)
(define-map price-history
  { project-id: uint, period: uint }
  {
    average-price: uint,
    volume: uint,
    timestamp: uint
  }
)

;; Read-only functions

(define-read-only (get-listing (listing-id uint))
  (map-get? credit-listings { listing-id: listing-id })
)

(define-read-only (get-listing-counter)
  (var-get listing-counter)
)

(define-read-only (get-transaction-counter)
  (var-get transaction-counter)
)

(define-read-only (get-transaction-record (transaction-id uint))
  (map-get? transaction-records { transaction-id: transaction-id })
)

(define-read-only (get-user-holdings (user principal) (project-id uint))
  (map-get? user-credit-holdings { user: user, project-id: project-id })
)

(define-read-only (get-project-market-stats (project-id uint))
  (map-get? project-market-stats { project-id: project-id })
)

(define-read-only (get-marketplace-admin)
  (var-get marketplace-admin)
)

(define-read-only (is-marketplace-paused)
  (var-get marketplace-paused)
)

(define-read-only (get-marketplace-fee-percentage)
  (var-get marketplace-fee-percentage)
)

(define-read-only (get-base-price)
  (var-get base-price)
)

(define-read-only (get-price-history (project-id uint) (period uint))
  (map-get? price-history { project-id: project-id, period: period })
)

;; Calculate dynamic price based on demand and quality
(define-read-only (calculate-market-price (project-id uint) (quality-score uint))
  (let
    (
      (base (var-get base-price))
      (stats (default-to 
        { total-traded: u0, average-price: base, last-trade-price: base, trade-count: u0, market-cap: u0 }
        (get-project-market-stats project-id)))
      (quality-multiplier (+ u100 (/ (* quality-score u50) u100))) ;; Quality adds 0-50% premium
      (demand-multiplier (if (> (get trade-count stats) u10) u110 u100)) ;; 10% premium for high-demand projects
    )
    (/ (* base (* quality-multiplier demand-multiplier)) u10000)
  )
)

;; Private functions

(define-private (is-valid-listing-status (status (string-ascii 20)))
  (or 
    (is-eq status "active")
    (or (is-eq status "sold")
    (or (is-eq status "cancelled")
        (is-eq status "expired")))
  )
)

(define-private (update-market-stats (project-id uint) (amount uint) (price uint))
  (let
    (
      (current-stats (default-to 
        { total-traded: u0, average-price: price, last-trade-price: price, trade-count: u0, market-cap: u0 }
        (get-project-market-stats project-id)))
      (new-total-traded (+ (get total-traded current-stats) amount))
      (new-trade-count (+ (get trade-count current-stats) u1))
      (new-average-price (/ (+ (* (get average-price current-stats) (get trade-count current-stats)) price) new-trade-count))
    )
    (map-set project-market-stats
      { project-id: project-id }
      {
        total-traded: new-total-traded,
        average-price: new-average-price,
        last-trade-price: price,
        trade-count: new-trade-count,
        market-cap: (* new-total-traded new-average-price)
      }
    )
  )
)

(define-private (update-user-holdings (user principal) (project-id uint) (credit-change int) (retirement bool))
  (let
    (
      (current-holdings (default-to 
        { total-credits: u0, available-credits: u0, retired-credits: u0 }
        (get-user-holdings user project-id)))
    )
    (if (> credit-change 0)
      ;; Adding credits
      (map-set user-credit-holdings
        { user: user, project-id: project-id }
        {
          total-credits: (+ (get total-credits current-holdings) (to-uint credit-change)),
          available-credits: (if retirement 
            (get available-credits current-holdings)
            (+ (get available-credits current-holdings) (to-uint credit-change))),
          retired-credits: (if retirement 
            (+ (get retired-credits current-holdings) (to-uint credit-change))
            (get retired-credits current-holdings))
        })
      ;; Removing credits
      (map-set user-credit-holdings
        { user: user, project-id: project-id }
        {
          total-credits: (get total-credits current-holdings),
          available-credits: (- (get available-credits current-holdings) (to-uint (- credit-change))),
          retired-credits: (get retired-credits current-holdings)
        })
    )
  )
)

;; Public functions

;; List carbon credits for sale
(define-public (list-credits-for-sale
    (project-id uint)
    (amount uint)
    (price-per-credit uint)
    (expiry-blocks uint)
    (quality-score uint)
    (project-type (string-ascii 30)))
  (let
    (
      (new-listing-id (+ (var-get listing-counter) u1))
      (total-price (* amount price-per-credit))
      (user-holdings (unwrap! (get-user-holdings tx-sender project-id) ERR-INSUFFICIENT-CREDITS))
    )
    (begin
      (asserts! (not (var-get marketplace-paused)) ERR-MARKETPLACE-PAUSED)
      (asserts! (> amount u0) ERR-INVALID-AMOUNT)
      (asserts! (> price-per-credit u0) ERR-INVALID-PRICE)
      (asserts! (>= (get available-credits user-holdings) amount) ERR-INSUFFICIENT-CREDITS)
      
      ;; Create listing
      (map-set credit-listings
        { listing-id: new-listing-id }
        {
          seller: tx-sender,
          project-id: project-id,
          amount: amount,
          price-per-credit: price-per-credit,
          total-price: total-price,
          listing-date: block-height,
          expiry-date: (+ block-height expiry-blocks),
          status: "active",
          quality-score: quality-score,
          project-type: project-type
        }
      )
      
      ;; Update user holdings (remove from available)
      (update-user-holdings tx-sender project-id (- (to-int amount)) false)
      
      ;; Update listing counter
      (var-set listing-counter new-listing-id)
      
      (ok new-listing-id)
    )
  )
)

;; Purchase carbon credits (with automatic retirement)
(define-public (purchase-credits (listing-id uint) (retire-immediately bool))
  (let
    (
      (listing (unwrap! (get-listing listing-id) ERR-NOT-FOUND))
      (seller (get seller listing))
      (amount (get amount listing))
      (total-price (get total-price listing))
      (marketplace-fee (/ (* total-price (var-get marketplace-fee-percentage)) u10000))
      (seller-payment (- total-price marketplace-fee))
      (new-transaction-id (+ (var-get transaction-counter) u1))
    )
    (begin
      (asserts! (not (var-get marketplace-paused)) ERR-MARKETPLACE-PAUSED)
      (asserts! (is-eq (get status listing) "active") ERR-LISTING-NOT-ACTIVE)
      (asserts! (< block-height (get expiry-date listing)) ERR-LISTING-NOT-ACTIVE)
      (asserts! (not (is-eq tx-sender seller)) ERR-SAME-SELLER)
      
      ;; Transfer payment (placeholder - would integrate with STX transfer)
      ;; (try! (stx-transfer? total-price tx-sender seller))
      
      ;; Update listing status
      (map-set credit-listings
        { listing-id: listing-id }
        (merge listing { status: "sold" })
      )
      
      ;; Record transaction
      (map-set transaction-records
        { transaction-id: new-transaction-id }
        {
          listing-id: listing-id,
          buyer: tx-sender,
          seller: seller,
          project-id: (get project-id listing),
          amount: amount,
          price-per-credit: (get price-per-credit listing),
          total-amount: total-price,
          marketplace-fee: marketplace-fee,
          transaction-date: block-height,
          retirement-immediate: retire-immediately
        }
      )
      
      ;; Update buyer holdings
      (update-user-holdings tx-sender (get project-id listing) (to-int amount) retire-immediately)
      
      ;; Update market statistics
      (update-market-stats (get project-id listing) amount (get price-per-credit listing))
      
      ;; Update transaction counter
      (var-set transaction-counter new-transaction-id)
      
      (ok new-transaction-id)
    )
  )
)

;; Cancel active listing
(define-public (cancel-listing (listing-id uint))
  (let
    (
      (listing (unwrap! (get-listing listing-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (is-eq tx-sender (get seller listing)) ERR-UNAUTHORIZED)
      (asserts! (is-eq (get status listing) "active") ERR-LISTING-NOT-ACTIVE)
      
      ;; Update listing status
      (map-set credit-listings
        { listing-id: listing-id }
        (merge listing { status: "cancelled" })
      )
      
      ;; Return credits to seller's available balance
      (update-user-holdings tx-sender (get project-id listing) (to-int (get amount listing)) false)
      
      (ok true)
    )
  )
)

;; Retire credits (remove from circulation)
(define-public (retire-credits (project-id uint) (amount uint))
  (let
    (
      (user-holdings (unwrap! (get-user-holdings tx-sender project-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (>= (get available-credits user-holdings) amount) ERR-INSUFFICIENT-CREDITS)
      
      ;; Move credits from available to retired
      (map-set user-credit-holdings
        { user: tx-sender, project-id: project-id }
        {
          total-credits: (get total-credits user-holdings),
          available-credits: (- (get available-credits user-holdings) amount),
          retired-credits: (+ (get retired-credits user-holdings) amount)
        }
      )
      
      (ok true)
    )
  )
)

;; Transfer credits between users
(define-public (transfer-credits (recipient principal) (project-id uint) (amount uint))
  (let
    (
      (sender-holdings (unwrap! (get-user-holdings tx-sender project-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (>= (get available-credits sender-holdings) amount) ERR-INSUFFICIENT-CREDITS)
      (asserts! (not (is-eq tx-sender recipient)) ERR-SAME-SELLER)
      
      ;; Update sender holdings
      (update-user-holdings tx-sender project-id (- (to-int amount)) false)
      
      ;; Update recipient holdings
      (update-user-holdings recipient project-id (to-int amount) false)
      
      (ok true)
    )
  )
)

;; Admin functions

(define-public (pause-marketplace)
  (begin
    (asserts! (is-eq tx-sender (var-get marketplace-admin)) ERR-UNAUTHORIZED)
    (var-set marketplace-paused true)
    (ok true)
  )
)

(define-public (unpause-marketplace)
  (begin
    (asserts! (is-eq tx-sender (var-get marketplace-admin)) ERR-UNAUTHORIZED)
    (var-set marketplace-paused false)
    (ok true)
  )
)

(define-public (update-marketplace-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender (var-get marketplace-admin)) ERR-UNAUTHORIZED)
    (asserts! (<= new-fee u1000) ERR-INVALID-AMOUNT) ;; Max 10% fee
    (var-set marketplace-fee-percentage new-fee)
    (ok true)
  )
)

(define-public (transfer-marketplace-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get marketplace-admin)) ERR-UNAUTHORIZED)
    (var-set marketplace-admin new-admin)
    (ok true)
  )
)

;; Update base price (for dynamic pricing calculations)
(define-public (update-base-price (new-base-price uint))
  (begin
    (asserts! (is-eq tx-sender (var-get marketplace-admin)) ERR-UNAUTHORIZED)
    (asserts! (> new-base-price u0) ERR-INVALID-PRICE)
    (var-set base-price new-base-price)
    (ok true)
  )
)

;; Batch operations for efficiency
(define-public (batch-retire-credits (retirements (list 10 { project-id: uint, amount: uint })))
  (let
    (
      (results (map retire-single-batch retirements))
    )
    (ok results)
  )
)

(define-private (retire-single-batch (retirement { project-id: uint, amount: uint }))
  (retire-credits (get project-id retirement) (get amount retirement))
)