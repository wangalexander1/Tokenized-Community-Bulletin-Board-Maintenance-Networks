;; Category Organization Contract
;; Sorts posts by relevance and topic

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_CATEGORY_NOT_FOUND (err u301))
(define-constant ERR_POST_NOT_FOUND (err u302))
(define-constant ERR_INVALID_PRIORITY (err u303))
(define-constant ERR_CATEGORY_EXISTS (err u304))

;; Data Variables
(define-data-var next-category-id uint u1)
(define-data-var relevance-decay-rate uint u10) ;; Relevance decreases by this amount per block
(define-data-var base-relevance-score uint u100)

;; Data Maps
(define-map categories (string-ascii 20) {
    category-id: uint,
    name: (string-ascii 20),
    description: (string-ascii 100),
    priority: uint,
    post-count: uint,
    active: bool,
    created-by: principal,
    created-at: uint
})

(define-map post-categories uint {
    post-id: uint,
    category: (string-ascii 20),
    relevance-score: uint,
    last-updated: uint,
    view-count: uint,
    interaction-count: uint,
    priority-boost: uint
})

(define-map category-moderators {category: (string-ascii 20), moderator: principal} bool)
(define-map user-category-preferences principal (list 10 (string-ascii 20)))
(define-map trending-categories uint (string-ascii 20))

;; Token definition
(define-fungible-token board-token)

;; Public Functions

;; Create a new category
(define-public (create-category (name (string-ascii 20)) (description (string-ascii 100)) (priority uint))
    (let ((category-id (var-get next-category-id)))
        (asserts! (is-none (map-get? categories name)) ERR_CATEGORY_EXISTS)
        (asserts! (<= priority u10) ERR_INVALID_PRIORITY)

        (map-set categories name {
            category-id: category-id,
            name: name,
            description: description,
            priority: priority,
            post-count: u0,
            active: true,
            created-by: tx-sender,
            created-at: block-height
        })

        (var-set next-category-id (+ category-id u1))
        (ok category-id)
    )
)

;; Assign post to category with relevance scoring
(define-public (assign-post-category (post-id uint) (category (string-ascii 20)) (initial-relevance (optional uint)))
    (let ((category-data (unwrap! (map-get? categories category) ERR_CATEGORY_NOT_FOUND))
          (relevance (default-to (var-get base-relevance-score) initial-relevance)))

        (map-set post-categories post-id {
            post-id: post-id,
            category: category,
            relevance-score: relevance,
            last-updated: block-height,
            view-count: u0,
            interaction-count: u0,
            priority-boost: u0
        })

        ;; Update category post count
        (map-set categories category (merge category-data {
            post-count: (+ (get post-count category-data) u1)
        }))

        (ok post-id)
    )
)

;; Update post relevance based on interactions
(define-public (update-post-relevance (post-id uint) (interaction-type (string-ascii 10)))
    (let ((post-cat (unwrap! (map-get? post-categories post-id) ERR_POST_NOT_FOUND))
          (relevance-boost (if (is-eq interaction-type "view") u1 u5))
          (current-relevance (get relevance-score post-cat))
          (blocks-passed (- block-height (get last-updated post-cat)))
          (decay-amount (* blocks-passed (var-get relevance-decay-rate)))
          (decayed-relevance (if (> current-relevance decay-amount)
                               (- current-relevance decay-amount)
                               u0))
          (new-relevance (+ decayed-relevance relevance-boost)))

        (map-set post-categories post-id (merge post-cat {
            relevance-score: new-relevance,
            last-updated: block-height,
            view-count: (if (is-eq interaction-type "view")
                          (+ (get view-count post-cat) u1)
                          (get view-count post-cat)),
            interaction-count: (+ (get interaction-count post-cat) u1)
        }))

        (ok new-relevance)
    )
)

;; Set category priority (moderators only)
(define-public (set-category-priority (category (string-ascii 20)) (new-priority uint))
    (let ((category-data (unwrap! (map-get? categories category) ERR_CATEGORY_NOT_FOUND)))
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER)
                     (default-to false (map-get? category-moderators {category: category, moderator: tx-sender})))
                 ERR_UNAUTHORIZED)
        (asserts! (<= new-priority u10) ERR_INVALID_PRIORITY)

        (map-set categories category (merge category-data {priority: new-priority}))
        (ok new-priority)
    )
)

;; Add category moderator
(define-public (add-category-moderator (category (string-ascii 20)) (moderator principal))
    (let ((category-data (unwrap! (map-get? categories category) ERR_CATEGORY_NOT_FOUND)))
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (map-set category-moderators {category: category, moderator: moderator} true)
        (ok true)
    )
)

;; Boost post priority temporarily
(define-public (boost-post-priority (post-id uint) (boost-amount uint))
    (let ((post-cat (unwrap! (map-get? post-categories post-id) ERR_POST_NOT_FOUND)))
        ;; Require payment for priority boost
        (try! (ft-burn? board-token boost-amount tx-sender))

        (map-set post-categories post-id (merge post-cat {
            priority-boost: (+ (get priority-boost post-cat) boost-amount),
            last-updated: block-height
        }))

        (ok boost-amount)
    )
)

;; Set user category preferences
(define-public (set-user-preferences (preferred-categories (list 10 (string-ascii 20))))
    (begin
        (map-set user-category-preferences tx-sender preferred-categories)
        (ok preferred-categories)
    )
)

;; Update trending categories
(define-public (update-trending-category (rank uint) (category (string-ascii 20)))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (is-some (map-get? categories category)) ERR_CATEGORY_NOT_FOUND)
        (map-set trending-categories rank category)
        (ok category)
    )
)

;; Read-only Functions

;; Get category details
(define-read-only (get-category (name (string-ascii 20)))
    (map-get? categories name)
)

;; Get post category info
(define-read-only (get-post-category (post-id uint))
    (map-get? post-categories post-id)
)

;; Calculate current relevance score (with decay)
(define-read-only (get-current-relevance (post-id uint))
    (match (map-get? post-categories post-id)
        post-cat
        (let ((blocks-passed (- block-height (get last-updated post-cat)))
              (decay-amount (* blocks-passed (var-get relevance-decay-rate)))
              (current-relevance (get relevance-score post-cat)))
            (if (> current-relevance decay-amount)
                (- current-relevance decay-amount)
                u0
            )
        )
        u0
    )
)

;; Get user preferences
(define-read-only (get-user-preferences (user principal))
    (map-get? user-category-preferences user)
)

;; Check if user is category moderator
(define-read-only (is-category-moderator (category (string-ascii 20)) (user principal))
    (default-to false (map-get? category-moderators {category: category, moderator: user}))
)

;; Get trending category by rank
(define-read-only (get-trending-category (rank uint))
    (map-get? trending-categories rank)
)

;; Get organization settings
(define-read-only (get-organization-settings)
    {
        next-category-id: (var-get next-category-id),
        relevance-decay-rate: (var-get relevance-decay-rate),
        base-relevance-score: (var-get base-relevance-score)
    }
)

;; Get category statistics
(define-read-only (get-category-stats (category (string-ascii 20)))
    (map-get? categories category)
)
