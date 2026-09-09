/**
 * SniffBudgetCoordinator (Background World).
 *
 * Centralized page sniff budget coordinator across frames.
 *
 * Core mechanism:
 * 1. Maintains a page ledger keyed by sender.tab.id and the current
 *    document generation.
 * 2. Strictly aggregates usedBytes + reservedBytes across all frames of
 *    the same page.
 * 3. Default total page budget is 2MB (MAX_PAGE_SNIFF_BUDGET).
 * 4. Two-phase lease protocol: acquireLease (reserve) -> settleLease
 *    (settle actual consumption and release the surplus reservation) /
 *    releaseLease (full release on error).
 * 5. Automatic TTL cleanup plus navigation/tab-close cleanup to prevent
 *    memory and quota leaks.
 * 6. Redacted metrics throughout (Zero URL / Zero PII / Zero Body).
 */

export const DEFAULT_PAGE_SNIFF_BUDGET = 2 * 1024 * 1024; // 2MB
export const DEFAULT_LEASE_TTL_MS = 30 * 1000; // 30s lease timeout
export const DEFAULT_PAGE_TTL_MS = 30 * 60 * 1000; // 30 minutes
export const MAX_PAGES_LEDGER_CAPACITY = 200;

export class SniffBudgetCoordinator {
  #budgetsByPage; // Map<string, PageBudgetEntry>
  #maxPageBudget;
  #leaseTtlMs;
  #pageTtlMs;
  #maxPages;
  #metrics;
  #leaseSequence;

  constructor({
    maxPageBudget = DEFAULT_PAGE_SNIFF_BUDGET,
    leaseTtlMs = DEFAULT_LEASE_TTL_MS,
    pageTtlMs = DEFAULT_PAGE_TTL_MS,
    maxPages = MAX_PAGES_LEDGER_CAPACITY,
  } = {}) {
    this.#budgetsByPage = new Map();
    this.#maxPageBudget = Math.max(1024, maxPageBudget);
    this.#leaseTtlMs = Math.max(10, leaseTtlMs);
    this.#pageTtlMs = Math.max(10, pageTtlMs);
    this.#maxPages = Math.max(1, maxPages);
    this.#leaseSequence = 0;

    this.#metrics = {
      scheduled: 0,
      started: 0,
      completed: 0,
      aborted: 0,
      skippedByType: 0,
      skippedByConcurrency: 0,
      skippedByBudget: 0,
      leaseTimeout: 0,
      cloneError: 0,
      readError: 0,
      parseError: 0,
      bytesRead: 0,
    };
  }

  static makePageKey(tabId, generation) {
    const tid = Number.isInteger(tabId) ? tabId : -1;
    const gen = Number.isInteger(generation) ? generation : 0;
    return `${tid}|${gen}`;
  }

  #getOrCreatePageBudget(tabId, generation) {
    this.#pruneExpiredPages();

    const key = SniffBudgetCoordinator.makePageKey(tabId, generation);
    let entry = this.#budgetsByPage.get(key);
    if (entry) {
      this.#pruneExpiredLeases(entry);
      entry.lastUpdated = Date.now();
      // True LRU: refresh access order
      this.#budgetsByPage.delete(key);
      this.#budgetsByPage.set(key, entry);
      return entry;
    }

    // Safe eviction policy once capacity is reached:
    // 1. Never evict a live page that still has active leases.
    // 2. Never evict a ledger that has consumed bytes (usedBytes > 0) —
    //    otherwise the page could rebuild and get a fresh 2MB budget.
    // 3. Only blank pages (no active lease, usedBytes === 0) may be evicted
    //    by LRU.
    // 4. If no legally evictable entry exists, fail closed (return null) and
    //    refuse to create a new ledger.
    if (this.#budgetsByPage.size >= this.#maxPages) {
      let evictCandidateKey = null;
      let oldestUpdated = Infinity;

      for (const [k, p] of this.#budgetsByPage) {
        this.#pruneExpiredLeases(p);
        if (p.usedBytes === 0 && p.leases.size === 0 && p.reservedBytes === 0 && p.lastUpdated < oldestUpdated) {
          oldestUpdated = p.lastUpdated;
          evictCandidateKey = k;
        }
      }

      if (evictCandidateKey !== null) {
        this.#budgetsByPage.delete(evictCandidateKey);
      } else {
        // Fail-closed: every page is actively sniffing or holds consumed
        // budget; refuse to allocate a new ledger.
        return null;
      }
    }

    entry = {
      tabId,
      generation,
      usedBytes: 0,
      reservedBytes: 0,
      leases: new Map(),
      lastUpdated: Date.now(),
    };
    this.#budgetsByPage.set(key, entry);
    return entry;
  }

  #pruneExpiredLeases(pageEntry) {
    if (!pageEntry || !pageEntry.leases) return;
    const now = Date.now();
    for (const [leaseId, lease] of pageEntry.leases) {
      if (now - lease.createdAt > this.#leaseTtlMs) {
        pageEntry.reservedBytes = Math.max(0, pageEntry.reservedBytes - lease.grantedBytes);
        // Fail-closed: conservatively count a timed-out lease's grantedBytes
        // into usedBytes so slow/hung readers cannot bypass the total page
        // budget.
        pageEntry.usedBytes = Math.min(this.#maxPageBudget, pageEntry.usedBytes + lease.grantedBytes);
        pageEntry.leases.delete(leaseId);
        this.#metrics.leaseTimeout += 1;
      }
    }
  }

  #pruneExpiredPages() {
    const now = Date.now();
    for (const [key, page] of this.#budgetsByPage) {
      this.#pruneExpiredLeases(page);
      if (
        now - page.lastUpdated > this.#pageTtlMs &&
        page.leases.size === 0 &&
        page.reservedBytes === 0 &&
        page.usedBytes === 0
      ) {
        this.#budgetsByPage.delete(key);
      }
    }
  }

  /**
   * Acquires a sniff reservation lease (Phase 1 Reservation).
   * Atomically checks whether usedBytes + reservedBytes exceeds the limit.
   */
  acquireLease({ tabId, generation, requestedBytes = 64 * 1024, tier = "unknown" }) {
    this.#metrics.scheduled += 1;

    if (!Number.isInteger(tabId) || tabId < 0 || !Number.isInteger(generation) || generation < 0) {
      this.#metrics.skippedByBudget += 1;
      return { ok: false, leaseId: null, grantedBytes: 0, reason: "invalid_tab_or_generation" };
    }

    const page = this.#getOrCreatePageBudget(tabId, generation);
    if (!page) {
      this.#metrics.skippedByBudget += 1;
      return { ok: false, leaseId: null, grantedBytes: 0, reason: "capacity_exhausted_all_active" };
    }

    this.#pruneExpiredLeases(page);

    const activeAllocated = page.usedBytes + page.reservedBytes;
    const remaining = Math.max(0, this.#maxPageBudget - activeAllocated);

    if (remaining <= 0) {
      this.#metrics.skippedByBudget += 1;
      return { ok: true, leaseId: null, grantedBytes: 0, reason: "page_budget_exhausted" };
    }

    const req = Math.max(0, Number.isFinite(requestedBytes) ? requestedBytes : 0);
    const granted = Math.min(req, remaining);

    if (granted <= 0) {
      this.#metrics.skippedByBudget += 1;
      return { ok: true, leaseId: null, grantedBytes: 0, reason: "zero_bytes_granted" };
    }

    this.#leaseSequence = (this.#leaseSequence + 1) % Number.MAX_SAFE_INTEGER;
    const leaseId = `ls_${tabId}_${generation}_${this.#leaseSequence}_${Date.now().toString(36)}`;

    page.reservedBytes += granted;
    page.leases.set(leaseId, {
      leaseId,
      grantedBytes: granted,
      tier,
      createdAt: Date.now(),
    });

    this.#metrics.started += 1;
    return {
      ok: true,
      leaseId,
      grantedBytes: granted,
      remainingPageBudget: Math.max(0, this.#maxPageBudget - (page.usedBytes + page.reservedBytes)),
    };
  }

  /**
   * Settles a lease (Phase 2 Settlement).
   * Counts actualBytes and releases the surplus reserved quota.
   */
  settleLease({ tabId, generation, leaseId, actualBytes = 0 }) {
    if (!leaseId) return { ok: false, reason: "missing_lease_id" };

    const key = SniffBudgetCoordinator.makePageKey(tabId, generation);
    const page = this.#budgetsByPage.get(key);
    if (!page) {
      return { ok: false, reason: "page_not_found" };
    }

    this.#pruneExpiredLeases(page);

    const lease = page.leases.get(leaseId);
    if (!lease) {
      return { ok: false, reason: "lease_not_found_or_expired" };
    }

    page.leases.delete(leaseId);
    page.reservedBytes = Math.max(0, page.reservedBytes - lease.grantedBytes);

    // Fail-closed: strictly validates actualBytes as a non-negative safe
    // integer; invalid input (NaN/Infinity/negative/non-integer) is
    // conservatively counted as the full grantedBytes into usedBytes.
    let actual;
    if (!Number.isSafeInteger(actualBytes) || actualBytes < 0) {
      actual = lease.grantedBytes;
    } else {
      actual = Math.min(actualBytes, lease.grantedBytes);
    }

    page.usedBytes = Math.min(this.#maxPageBudget, page.usedBytes + actual);
    page.lastUpdated = Date.now();

    // Refresh LRU order
    this.#budgetsByPage.delete(key);
    this.#budgetsByPage.set(key, page);

    this.#metrics.bytesRead += actual;
    this.#metrics.completed += 1;

    return {
      ok: true,
      usedBytes: page.usedBytes,
      reservedBytes: page.reservedBytes,
      remainingPageBudget: Math.max(0, this.#maxPageBudget - (page.usedBytes + page.reservedBytes)),
    };
  }

  /**
   * Releases an unused lease (cancel/error/timeout paths).
   */
  releaseLease({ tabId, generation, leaseId, reason = "aborted" }) {
    if (!leaseId) return { ok: false, reason: "missing_lease_id" };

    const key = SniffBudgetCoordinator.makePageKey(tabId, generation);
    const page = this.#budgetsByPage.get(key);
    if (!page) {
      return { ok: false, reason: "page_not_found" };
    }

    this.#pruneExpiredLeases(page);

    const lease = page.leases.get(leaseId);
    if (!lease) {
      return { ok: false, reason: "lease_not_found_or_expired" };
    }

    page.leases.delete(leaseId);
    page.reservedBytes = Math.max(0, page.reservedBytes - lease.grantedBytes);
    page.lastUpdated = Date.now();

    // Refresh LRU order
    this.#budgetsByPage.delete(key);
    this.#budgetsByPage.set(key, page);

    this.#metrics.aborted += 1;
    return {
      ok: true,
      releasedBytes: lease.grantedBytes,
      reservedBytes: page.reservedBytes,
    };
  }

  /**
   * Records an error-classification metric.
   */
  recordError(type) {
    if (type === "clone") this.#metrics.cloneError += 1;
    else if (type === "read") this.#metrics.readError += 1;
    else if (type === "parse") this.#metrics.parseError += 1;
  }

  /**
   * Records a skip-classification metric.
   */
  recordSkip(type) {
    if (type === "type") this.#metrics.skippedByType += 1;
    else if (type === "concurrency") this.#metrics.skippedByConcurrency += 1;
    else if (type === "budget") this.#metrics.skippedByBudget += 1;
  }

  /**
   * Clears page ledgers on navigation / SPA generation change / tab close.
   */
  clearTab(tabId, generation) {
    if (!Number.isInteger(tabId)) return;
    if (Number.isInteger(generation)) {
      const key = SniffBudgetCoordinator.makePageKey(tabId, generation);
      this.#budgetsByPage.delete(key);
    } else {
      const prefix = `${tabId}|`;
      for (const key of this.#budgetsByPage.keys()) {
        if (key.startsWith(prefix)) {
          this.#budgetsByPage.delete(key);
        }
      }
    }
  }

  /**
   * Returns a snapshot of the given page's current usage.
   */
  getPageSnapshot(tabId, generation) {
    const key = SniffBudgetCoordinator.makePageKey(tabId, generation);
    const page = this.#budgetsByPage.get(key);
    if (!page) {
      return {
        tabId,
        generation,
        usedBytes: 0,
        reservedBytes: 0,
        activeLeasesCount: 0,
        remainingBudget: this.#maxPageBudget,
      };
    }
    this.#pruneExpiredLeases(page);
    return {
      tabId,
      generation,
      usedBytes: page.usedBytes,
      reservedBytes: page.reservedBytes,
      activeLeasesCount: page.leases.size,
      remainingBudget: Math.max(0, this.#maxPageBudget - (page.usedBytes + page.reservedBytes)),
    };
  }

  getMetrics() {
    return { ...this.#metrics };
  }

  resetMetrics() {
    for (const key of Object.keys(this.#metrics)) {
      this.#metrics[key] = 0;
    }
  }
}
