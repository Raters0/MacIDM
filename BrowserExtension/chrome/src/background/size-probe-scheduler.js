/**
 * SizeProbeScheduler (Background World).
 *
 * Explicit priority queue scheduler.
 *
 * Core mechanism:
 * 1. Strictly controlled concurrency model: default global peak concurrency
 *    <= 8, per-tab peak concurrency <= 4;
 * 2. True LRU positive cache (500 entries / 10-minute TTL, get refreshes
 *    order);
 * 3. Bounded negative cache with exponential backoff (1000 entries /
 *    10-minute TTL, at most 3 backoffs: 1s, 2s, 4s);
 * 4. Context security isolation: keys bind tabId + generation + referer +
 *    URL; merging or cross-use across security contexts is forbidden;
 * 5. Dual re-check gating: canDispatch (evidence and private-network
 *    re-check before dequeue) + canPublish (generation and target re-check
 *    before write-back);
 * 6. Round-robin fair scheduling across tabs + true aging anti-starvation;
 * 7. Cascading AbortController cancellation with zero active-count leaks;
 * 8. Bounded queue (max 200 entries) and overflow-safe seq reset.
 */

export const PROBE_PRIORITY = Object.freeze({
  HIGH: "HIGH",
  NORMAL: "NORMAL",
  LOW: "LOW",
});

const PRIORITY_SCORES = Object.freeze({
  [PROBE_PRIORITY.HIGH]: 300,
  [PROBE_PRIORITY.NORMAL]: 200,
  [PROBE_PRIORITY.LOW]: 100,
});

export const DEFAULT_SCHEDULER_CONFIG = Object.freeze({
  globalConcurrency: 8,
  perTabConcurrency: 4,
  maxCacheEntries: 500,
  cacheTtlMs: 10 * 60 * 1000,       // 10 minutes
  maxFailureEntries: 1000,
  failureTtlMs: 10 * 60 * 1000,     // 10 minutes
  maxQueueEntries: 200,
  agingIntervalMs: 2000,            // priority gains one level per 2s of waiting
  backoffBaseMs: 1000,              // 1s, 2s, 4s
  maxRetryAttempts: 3,
  // Hard cap on pending auto-retry lifecycles (timers plus items already
  // moved into the queue or in flight): even though the negative cache and
  // the queue each have their own limits, the total retry lifecycle count
  // must also be bounded to avoid unbounded buildup under failed-candidate
  // pressure; when exceeded, the oldest lifecycle is evicted and finalized
  // with a published terminal state.
  maxRetryTimers: 1000,
  autoRetry: false,
});

// Bounded compensating reschedules allowed when enqueue is rejected after a
// retry timer fires (queue full / backoff window); beyond this, retrying
// stops and a terminal state is published, ruling out an unbounded
// reschedule loop every ~10ms.
const MAX_RETRY_RESCHEDULES = 3;

export class SizeProbeScheduler {
  #globalConcurrency;
  #perTabConcurrency;
  #maxCacheEntries;
  #cacheTtlMs;
  #maxFailureEntries;
  #failureTtlMs;
  #maxQueueEntries;
  #agingIntervalMs;
  #maxAgingBoost;
  #backoffBaseMs;
  #maxBackoffMs;
  #maxRetryAttempts;
  #maxRetryTimers;
  #autoRetry;

  #getGeneration;
  #fetchProbe;
  #pushResult;
  #canDispatch;
  #canPublish;

  #activeGlobalCount;
  #activeCountByTab;           // Map<tabId, number>
  #queue;                      // Array<TaskItem>
  #inFlightTasks;              // Map<contextKey, InFlightRecord>
  #probeCache;                 // Map<contextKey, { payload, expiresAt }> (True LRU)
  #failureLedger;              // Map<contextKey, { attempts, nextRetryAt, expiresAt }>
  #retryTimers;                 // Map<contextKey, { timerId, tabId, generation }> (pending setTimeout handles only)
  #retryLifecycles;             // Map<contextKey, { tabId, generation, attempts, nextRetryAt, subscriber, timerId, reschedules }> (persists across timer/queue/in-flight)
  #abortControllersByTab;      // Map<tabId, Set<AbortController>>
  #sequence;
  #lastDispatchedTabId;

  constructor(options = {}) {
    const config = { ...DEFAULT_SCHEDULER_CONFIG, ...options };
    this.#globalConcurrency = Math.max(1, config.globalConcurrency);
    this.#perTabConcurrency = Math.max(1, config.perTabConcurrency);
    this.#maxCacheEntries = Math.max(1, config.maxCacheEntries);
    this.#cacheTtlMs = Math.max(1000, config.cacheTtlMs);
    this.#maxFailureEntries = Math.max(1, config.maxFailureEntries);
    this.#failureTtlMs = Math.max(1000, config.failureTtlMs);
    this.#maxQueueEntries = Math.max(1, config.maxQueueEntries);
    this.#agingIntervalMs = Math.max(10, config.agingIntervalMs);
    this.#maxAgingBoost = Math.max(0, config.maxAgingBoost ?? 2);
    this.#backoffBaseMs = Math.max(0, config.backoffBaseMs ?? config.initialBackoffMs ?? 1000);
    this.#maxBackoffMs = Math.max(0, config.maxBackoffMs ?? 8000);
    this.#maxRetryAttempts = Math.max(1, config.maxRetryAttempts);
    this.#maxRetryTimers = Math.max(1, config.maxRetryTimers);
    this.#autoRetry = Boolean(config.autoRetry);

    this.#getGeneration = typeof options.getGeneration === "function"
      ? options.getGeneration
      : () => 0;
    this.#fetchProbe = typeof options.fetchProbe === "function"
      ? options.fetchProbe
      : async () => ({ size: null, mime: "" });
    this.#pushResult = typeof options.pushResult === "function"
      ? options.pushResult
      : () => {};
    this.#canDispatch = typeof options.canDispatch === "function"
      ? options.canDispatch
      : () => true;
    this.#canPublish = typeof options.canPublish === "function"
      ? options.canPublish
      : () => true;

    this.#activeGlobalCount = 0;
    this.#activeCountByTab = new Map();
    this.#queue = [];
    this.#inFlightTasks = new Map();
    this.#probeCache = new Map();
    this.#failureLedger = new Map();
    this.#retryTimers = new Map();
    this.#retryLifecycles = new Map();
    this.#abortControllersByTab = new Map();
    this.#sequence = 0;
    this.#lastDispatchedTabId = null;
  }

  /**
   * Builds a strict context-isolation key (binds tabId + generation +
   * referer + URL; reuse across generations or contexts is forbidden).
   */
  static makeContextKey({ tabId, generation, referer = "", url }) {
    const tid = Number.isInteger(tabId) ? tabId : -1;
    const gen = Number.isInteger(generation) ? generation : 0;
    const ref = typeof referer === "string" ? referer : "";
    const targetUrl = typeof url === "string" ? url : "";
    return `${tid}|${gen}|${ref}|${targetUrl}`;
  }

  /**
   * Positive-cache key (identical to makeContextKey, strictly binding
   * tabId + generation + referer + URL).
   */
  static makePositiveCacheKey({ tabId, generation, referer = "", url }) {
    return SizeProbeScheduler.makeContextKey({ tabId, generation, referer, url });
  }

  // ===== LRU positive cache =====

  #getCached(key) {
    const entry = this.#probeCache.get(key);
    if (!entry) return null;
    if (Date.now() > entry.expiresAt) {
      this.#probeCache.delete(key);
      return null;
    }
    // True LRU: a hit refreshes the entry to the Map tail
    this.#probeCache.delete(key);
    this.#probeCache.set(key, entry);
    return entry.payload;
  }

  #setCached(key, payload) {
    if (this.#probeCache.has(key)) {
      this.#probeCache.delete(key);
    } else if (this.#probeCache.size >= this.#maxCacheEntries) {
      // Evict the least recently accessed entry (head)
      const oldestKey = this.#probeCache.keys().next().value;
      if (oldestKey !== undefined) this.#probeCache.delete(oldestKey);
    }
    this.#probeCache.set(key, {
      payload,
      expiresAt: Date.now() + this.#cacheTtlMs,
    });
  }

  // ===== Bounded negative cache and backoff =====

  #getFailureRecord(key) {
    const record = this.#failureLedger.get(key);
    if (!record) return null;
    if (Date.now() > record.expiresAt) {
      this.#failureLedger.delete(key);
      return null;
    }
    return record;
  }

  #recordFailure(key) {
    const now = Date.now();
    const existing = this.#getFailureRecord(key);
    const attempts = existing ? existing.attempts + 1 : 1;
    const delayMs = Math.min(
      this.#maxBackoffMs,
      this.#backoffBaseMs * Math.pow(2, attempts - 1),
    ); // 1s, 2s, 4s

    if (this.#failureLedger.size >= this.#maxFailureEntries && !this.#failureLedger.has(key)) {
      const oldestKey = this.#failureLedger.keys().next().value;
      if (oldestKey !== undefined) this.#failureLedger.delete(oldestKey);
    }

    this.#failureLedger.set(key, {
      attempts,
      nextRetryAt: now + delayMs,
      expiresAt: now + this.#failureTtlMs,
    });
  }

  #clearFailure(key) {
    this.#failureLedger.delete(key);
  }

  #clearRetryTimer(key) {
    const entry = this.#retryTimers.get(key);
    if (entry) {
      clearTimeout(entry.timerId);
      this.#retryTimers.delete(key);
    }
  }

  // Publishes the finalized "size unknown/failed" terminal state to
  // subscribers; strictly preserves the generation re-check and canPublish
  // gating.
  #publishTerminalFailure(subscribers, url) {
    for (const sub of subscribers) {
      if (this.#getGeneration(sub.tabId) === sub.generation) {
        const failPayload = {
          size: null,
          mime: "",
          url,
          sizeProbeFailed: true,
        };
        if (this.#canPublish(sub, failPayload)) {
          this.#pushResult(sub.tabId, failPayload);
        }
      }
    }
  }

  #makeSubscriber(task) {
    return {
      tabId: task.tabId,
      generation: task.generation,
      candidate: task.candidate,
      referer: task.referer,
    };
  }

  // Ends the retry lifecycle of a context: clears the timer and the
  // lifecycle record; with publish=true it also publishes the failure
  // terminal state (subject to the generation re-check and canPublish
  // gating). Used for bounded terminations such as queue eviction, timer
  // capacity eviction, and compensating reschedules running out.
  #terminateRetryLifecycle(contextKey, { publish = false } = {}) {
    this.#clearRetryTimer(contextKey);
    const lifecycle = this.#retryLifecycles.get(contextKey);
    this.#retryLifecycles.delete(contextKey);
    // The lifecycle may already have moved from a timer to a queue item or
    // an in-flight request. Retire the producer first, then publish the
    // terminal state; late results are discarded via that request's
    // AbortSignal and must not revive the retry.
    this.#queue = this.#queue.filter((task) => task.contextKey !== contextKey);
    this.#inFlightTasks.get(contextKey)?.abortController.abort();
    if (publish && lifecycle && !lifecycle.exhausted) {
      this.#publishTerminalFailure([lifecycle.subscriber], lifecycle.subscriber.candidate.url);
    }
  }

  // Only clears the lifecycle record (for cases already finalized
  // elsewhere: success, cancellation, generation invalidation).
  #clearRetryLifecycle(contextKey) {
    this.#clearRetryTimer(contextKey);
    this.#retryLifecycles.delete(contextKey);
  }

  // Marks a context with a persistent "retry budget exhausted" negative
  // cache flag (timerId=null, exhausted=true) that blocks ordinary page
  // updates from re-probing while failureTtlMs is in effect; independent
  // of the failureLedger, which LRU can evict.
  #markLifecycleExhausted(contextKey, task, attempts) {
    this.#clearRetryTimer(contextKey);
    this.#putRetryLifecycle(contextKey, {
      tabId: task.tabId,
      generation: task.generation,
      attempts: Math.max(attempts, this.#maxRetryAttempts),
      nextRetryAt: 0,
      subscriber: this.#makeSubscriber(task),
      timerId: null,
      reschedules: 0,
      exhausted: true,
      expiresAt: Date.now() + this.#failureTtlMs,
    });
  }

  // Single entry point for writing lifecycle records: performs expiry
  // cleanup plus capacity eviction (R5) uniformly, so both active and
  // terminal (exhausted) records obey the same maxRetryTimers cap and the
  // budget-tracking map cannot degrade into an unbounded cache.
  #putRetryLifecycle(contextKey, record) {
    const now = Date.now();
    // Expiry cleanup: reclaim expired exhausted negative-cache flags
    // (without depending on revisiting the same key)
    for (const [key, lc] of this.#retryLifecycles) {
      if (lc.exhausted && now > lc.expiresAt) this.#retryLifecycles.delete(key);
    }
    // Capacity eviction: when over the limit, evict the oldest lifecycle
    // (active ones get a published terminal state; exhausted ones are
    // simply removed)
    if (!this.#retryLifecycles.has(contextKey) && this.#retryLifecycles.size >= this.#maxRetryTimers) {
      const oldestKey = this.#retryLifecycles.keys().next().value;
      if (oldestKey !== undefined) this.#terminateRetryLifecycle(oldestKey, { publish: true });
    }
    this.#retryLifecycles.set(contextKey, record);
  }

  // Schedules a context-bound backoff retry. Creates/updates the durable
  // retry lifecycle record (attempts, nextRetryAt, subscriber); the record
  // survives "timer → queue → in-flight" until success / terminal state /
  // cancellation / eviction, so the retry budget does not depend on the
  // evictable failureLedger and is not lost when the timer fires and moves
  // the task into the queue (fixes R2/R3).
  #scheduleRetry(task, nextRetryAt, attempts, reschedules = 0) {
    const contextKey = SizeProbeScheduler.makeContextKey({
      tabId: task.tabId,
      generation: task.generation,
      referer: task.referer,
      url: task.candidate.url,
    });
    const subscriber = this.#makeSubscriber(task);

    this.#clearRetryTimer(contextKey);

    // Add a 10ms safety margin so timer precision jitter cannot fire early
    // and get mistakenly rejected by the enqueue backoff window
    const delayMs = Math.max(0, nextRetryAt - Date.now()) + 10;
    const timerId = setTimeout(() => {
      // A cleaned-up/replaced old timer must not advance the new lifecycle
      // under the same key.
      if (this.#retryTimers.get(contextKey)?.timerId !== timerId) return;
      // Timer fired: remove only the timer handle and keep the lifecycle
      // record (the task moves into the queue/in flight, and the budget
      // must carry on).
      this.#retryTimers.delete(contextKey);
      const lifecycle = this.#retryLifecycles.get(contextKey);
      if (lifecycle) {
        lifecycle.timerId = null;
        lifecycle.reschedules = reschedules;
      }

      // 1. Generation validity re-check: if the tab has navigated or the
      // generation changed, drop the whole lifecycle (nothing is published
      // to the old page).
      if (this.#getGeneration(task.tabId) !== task.generation) {
        this.#retryLifecycles.delete(contextKey);
        return;
      }

      // 2. Dispatch gating re-check: if not allowed, keep the lifecycle and
      // use the bounded compensation below.
      const dispatchable = this.#canDispatch(task);

      // 3. Re-enqueue through the unified capacity entry point (R4: retry
      // enqueues are equally bound by maxQueueEntries), carrying this
      // lifecycle's attempt budget.
      const enqueued = dispatchable
        ? this.#admitWithCapacity({
            tabId: task.tabId,
            generation: task.generation,
            candidate: task.candidate,
            referer: task.referer,
            priority: task.priority,
            timeoutMs: task.timeoutMs,
            contextKey,
            retryAttempt: attempts,
          })
        : false;

      // 4. Bounded compensation when progress fails (gate rejection /
      //    queue full / backoff window): reschedule at most
      //    MAX_RETRY_RESCHEDULES times; if it still cannot proceed, stop
      //    retrying and publish the terminal state, ruling out an unbounded
      //    tight loop.
      if (!enqueued) {
        if (reschedules < MAX_RETRY_RESCHEDULES) {
          const delay = Math.min(this.#maxBackoffMs, this.#backoffBaseMs * Math.pow(2, attempts));
          this.#scheduleRetry(task, Date.now() + delay, attempts, reschedules + 1);
        } else {
          this.#terminateRetryLifecycle(contextKey, { publish: true });
        }
      }
    }, delayMs);

    if (typeof timerId?.unref === "function") {
      timerId.unref();
    }

    this.#retryTimers.set(contextKey, { timerId, tabId: task.tabId, generation: task.generation });
    this.#putRetryLifecycle(contextKey, {
      tabId: task.tabId,
      generation: task.generation,
      attempts,
      nextRetryAt,
      subscriber,
      timerId,
      reschedules,
    });
  }

  /**
   * Submits a probe task into the queue.
   */
  enqueue({
    tabId,
    candidate,
    referer = "",
    priority = PROBE_PRIORITY.NORMAL,
    timeoutMs = 5000,
    retryAttempt = 0,
  }) {
    if (!candidate || !candidate.url || typeof candidate.url !== "string") return false;
    if (!Number.isInteger(tabId) || tabId < 0) return false;

    const generation = this.#getGeneration(tabId);
    if (!Number.isInteger(generation) || generation < 0) return false;

    const contextKey = SizeProbeScheduler.makeContextKey({
      tabId,
      generation,
      referer,
      url: candidate.url,
    });

    // 1. Context-isolated positive LRU cache hit check (strictly bound to
    // generation)
    const cached = this.#getCached(contextKey);
    if (cached) {
      if (this.#canPublish({ tabId, generation, candidate, referer }, cached)) {
        this.#pushResult(tabId, { ...cached, url: candidate.url, fromCache: true });
      }
      return true;
    }

    // 2. Bounded negative-cache exponential backoff check
    const failure = this.#getFailureRecord(contextKey);
    if (failure) {
      if (failure.attempts >= this.#maxRetryAttempts) {
        return false;
      }
      if (this.#backoffBaseMs > 0 && Date.now() < failure.nextRetryAt) {
        return false;
      }
    }

    // 2b. Active/finalized retry lifecycle handling (R3/R4): duplicate
    //     submissions from external page updates must not reset the budget
    //     of an unfinished lifecycle, nor force their way past queue
    //     capacity — active lifecycles are always merged or deferred, and
    //     advanced by the timer callback via #admitWithCapacity.
    const lifecycle = this.#retryLifecycles.get(contextKey);
    if (lifecycle) {
      if (lifecycle.exhausted) {
        if (Date.now() > lifecycle.expiresAt) {
          // Negative-cache TTL expired: clear the finalized flag and allow
          // probing anew as a brand-new task (through the unified
          // capacity entry below).
          this.#retryLifecycles.delete(contextKey);
        } else {
          // Finalized and still within the negative-cache TTL: ordinary
          // page updates do not re-probe (unlike an explicit user retry).
          return false;
        }
      } else {
        const inFlightLc = this.#inFlightTasks.get(contextKey);
        if (inFlightLc) {
          if (inFlightLc.abortController.signal.aborted) return false;
          if (PRIORITY_SCORES[priority] > PRIORITY_SCORES[inFlightLc.task.priority]) {
            inFlightLc.task.priority = priority;
          }
          inFlightLc.subscribers.push({ tabId, generation, candidate, referer });
          return true;
        }
        const queuedLc = this.#queue.find((item) => item.contextKey === contextKey);
        if (queuedLc) {
          if (PRIORITY_SCORES[priority] > PRIORITY_SCORES[queuedLc.priority]) {
            queuedLc.priority = priority;
          }
          return true;
        }
        // Pending timer (or the transient moment when the timer just fired
        // and its callback is synchronously enqueuing): defer, and let the
        // timer callback advance through the capacity entry point — this
        // preserves the spent budget (R3) without bypassing
        // maxQueueEntries (R4).
        return true;
      }
    }

    // 3–5. Unified capacity-aware admission (in-flight merging / queue
    // dedup / maxQueueEntries capacity guard + priority eviction)
    return this.#admitWithCapacity({ tabId, generation, candidate, referer, priority, timeoutMs, contextKey, retryAttempt });
  }

  // Single capacity entry point for "creating a queue item" (R4): first
  // submissions, timer retries, and fresh probes after an exhausted flag
  // expires all pass through here, uniformly performing in-flight merging,
  // queue dedup, maxQueueEntries capacity guard, and priority eviction, so
  // no path can bypass queue capacity.
  #admitWithCapacity({ tabId, generation, candidate, referer, priority, timeoutMs, contextKey, retryAttempt }) {
    // In-flight request merge check (same security context)
    const inFlight = this.#inFlightTasks.get(contextKey);
    if (inFlight) {
      // When a terminated request has not released its slot yet, do not
      // merge new submissions into the stale producer.
      if (inFlight.abortController.signal.aborted) return false;
      if (PRIORITY_SCORES[priority] > PRIORITY_SCORES[inFlight.task.priority]) {
        inFlight.task.priority = priority;
      }
      inFlight.subscribers.push({ tabId, generation, candidate, referer });
      return true;
    }

    // Queue dedup and priority boost
    const existingQueueItem = this.#queue.find((item) => item.contextKey === contextKey);
    if (existingQueueItem) {
      if (PRIORITY_SCORES[priority] > PRIORITY_SCORES[existingQueueItem.priority]) {
        existingQueueItem.priority = priority;
      }
      return true;
    }

    // Queue capacity guard
    if (this.#queue.length >= this.#maxQueueEntries) {
      // Queue is full; reject unless the new task is HIGH
      if (priority !== PROBE_PRIORITY.HIGH) return false;
      // Evict the oldest lowest-priority item in the queue
      const lowIndex = this.#queue.findIndex((item) => item.priority === PROBE_PRIORITY.LOW);
      if (lowIndex >= 0) {
        // R2: if the evicted item is in an auto-retry lifecycle, terminate
        // it in a bounded way and publish the terminal state so it is not
        // silently lost.
        const [evicted] = this.#queue.splice(lowIndex, 1);
        if (evicted && this.#retryLifecycles.has(evicted.contextKey)) {
          this.#terminateRetryLifecycle(evicted.contextKey, { publish: true });
        }
      } else {
        return false;
      }
    }

    return this.#admitTask({ tabId, generation, candidate, referer, priority, timeoutMs, contextKey, retryAttempt });
  }

  // Creates and enqueues a probe task and drives scheduling. retryAttempt
  // carries the auto-retry lifecycle's spent budget through: fresh external
  // submissions are 0, while retry re-enqueues or lifecycle merges reuse
  // the spent count, so the budget does not depend on the evictable
  // failureLedger.
  #admitTask({ tabId, generation, candidate, referer, priority, timeoutMs, contextKey, retryAttempt }) {
    this.#sequence = (this.#sequence + 1) % Number.MAX_SAFE_INTEGER;
    const task = {
      seq: this.#sequence,
      tabId,
      generation,
      candidate,
      referer,
      priority,
      timeoutMs,
      contextKey,
      enqueuedAt: Date.now(),
      retryAttempt: Number.isInteger(retryAttempt) && retryAttempt > 0 ? retryAttempt : 0,
    };
    this.#queue.push(task);
    this.#pump();
    return true;
  }

  /**
   * Core scheduler pump loop (tab round-robin + aging priority).
   */
  #pump() {
    while (this.#activeGlobalCount < this.#globalConcurrency && this.#queue.length > 0) {
      const taskIndex = this.#selectNextTaskIndex();
      if (taskIndex === -1) break;

      const [task] = this.#queue.splice(taskIndex, 1);

      // Generation validation
      const currentGen = this.#getGeneration(task.tabId);
      if (currentGen !== task.generation) {
        this.#terminateRetryLifecycle(task.contextKey);
        continue;
      }

      // Pre-dequeue safety/evidence re-check gate
      if (!this.#canDispatch(task)) {
        // Removing from the queue ends this retry; no active record may be
        // left without a timer/queue/inFlight slot. The terminal state is
        // still gated by canPublish and generation.
        this.#terminateRetryLifecycle(task.contextKey, { publish: true });
        continue;
      }

      this.#dispatch(task);
    }
  }

  /**
   * Task selection algorithm based on tab round-robin and aging.
   */
  #selectNextTaskIndex() {
    const now = Date.now();
    let bestIndex = -1;
    let highestScore = -Infinity;

    // Collect candidate tasks currently allowed to dispatch (per-tab
    // concurrency constraint satisfied)
    const eligibleIndices = [];
    for (let i = 0; i < this.#queue.length; i++) {
      const task = this.#queue[i];
      const tabActive = this.#activeCountByTab.get(task.tabId) || 0;
      if (tabActive < this.#perTabConcurrency) {
        eligibleIndices.push(i);
      }
    }

    if (eligibleIndices.length === 0) return -1;

    for (const idx of eligibleIndices) {
      const task = this.#queue[idx];
      const baseScore = PRIORITY_SCORES[task.priority] || 100;
      const waitingMs = Math.max(0, now - task.enqueuedAt);
      const agingSteps = Math.min(this.#maxAgingBoost, Math.floor(waitingMs / this.#agingIntervalMs));
      const agingBoost = agingSteps * 100;
      let totalScore = baseScore + agingBoost;

      // Tab round-robin bonus: prefer a tab other than the last dispatched
      // one to promote multi-tab fairness
      if (this.#lastDispatchedTabId !== null && task.tabId !== this.#lastDispatchedTabId) {
        totalScore += 5;
      }

      if (totalScore > highestScore) {
        highestScore = totalScore;
        bestIndex = idx;
      }
    }

    return bestIndex;
  }

  /**
   * Starts probe execution.
   */
  #dispatch(task) {
    const tabId = task.tabId;
    const contextKey = task.contextKey;

    this.#activeGlobalCount += 1;
    this.#activeCountByTab.set(tabId, (this.#activeCountByTab.get(tabId) || 0) + 1);
    this.#lastDispatchedTabId = tabId;

    const abortController = new AbortController();
    if (!this.#abortControllersByTab.has(tabId)) {
      this.#abortControllersByTab.set(tabId, new Set());
    }
    this.#abortControllersByTab.get(tabId).add(abortController);

    const inFlightRecord = {
      task,
      abortController,
      subscribers: [{ tabId, generation: task.generation, candidate: task.candidate, referer: task.referer }],
    };
    this.#inFlightTasks.set(contextKey, inFlightRecord);

    (async () => {
      let result = null;
      let isSuccess = false;
      try {
        result = await this.#fetchProbe(task.candidate.url, {
          signal: abortController.signal,
          timeoutMs: task.timeoutMs,
          referer: task.referer,
        });

        if (result && Number.isSafeInteger(result.size) && result.size > 0) {
          isSuccess = true;
        }
      } catch (err) {
        result = { size: null, mime: "" };
      } finally {
        // After clearAll, a new request may already exist under the same
        // key. The old callback releases only the record and counts it
        // still owns; it must not delete the new request or decrement the
        // new generation's concurrency counts.
        if (this.#inFlightTasks.get(contextKey) === inFlightRecord) {
          this.#activeGlobalCount = Math.max(0, this.#activeGlobalCount - 1);
          const currentTabActive = this.#activeCountByTab.get(tabId) || 1;
          if (currentTabActive <= 1) {
            this.#activeCountByTab.delete(tabId);
          } else {
            this.#activeCountByTab.set(tabId, currentTabActive - 1);
          }

          const tabControllers = this.#abortControllersByTab.get(tabId);
          if (tabControllers) {
            tabControllers.delete(abortController);
            if (tabControllers.size === 0) this.#abortControllersByTab.delete(tabId);
          }
          this.#inFlightTasks.delete(contextKey);
        }
      }

      // Check cancellation before handling success or failure: ignore late
      // results from producers that ignore the AbortSignal.
      if (abortController.signal.aborted) {
        this.#pump();
        return;
      }
      // Result settlement and publishing
      if (isSuccess && result) {
        let publishedCount = 0;
        for (const sub of inFlightRecord.subscribers) {
          if (this.#getGeneration(sub.tabId) === sub.generation) {
            if (this.#canPublish(sub, result)) {
              this.#pushResult(sub.tabId, { ...result, url: task.candidate.url });
              publishedCount += 1;
            }
          }
        }

        // Write to the generation-bound cache only when at least one
        // legitimate subscriber passed the canPublish check
        if (publishedCount > 0) {
          this.#clearRetryLifecycle(contextKey);
          this.#clearFailure(contextKey);
          this.#setCached(contextKey, result);
        } else {
          // When the publish gate rejects, also end this lifecycle; do not
          // keep a record nobody will advance.
          this.#clearRetryLifecycle(contextKey);
        }
      } else {
        this.#recordFailure(contextKey);
        // Authoritative attempt count = max(ledger count, task lifecycle
        // count). The lifecycle count is carried with the task,
        // independent of the LRU-evictable failureLedger; on the
        // autoRetry:false external duplicate-submission path the lifecycle
        // count is always 1, degrading to the ledger count, so existing
        // behavior is unchanged.
        const failure = this.#getFailureRecord(contextKey);
        const ledgerAttempts = failure ? failure.attempts : 0;
        const lifecycleAttempts = (Number.isInteger(task.retryAttempt) ? task.retryAttempt : 0) + 1;
        const attempts = Math.max(ledgerAttempts, lifecycleAttempts);
        const isFinalFailure = attempts >= this.#maxRetryAttempts;
        if (isFinalFailure) {
          // Publish the terminal state and mark this context with the
          // persistent "budget exhausted" negative cache (not lost when
          // the failureLedger is evicted), so ordinary page updates stop
          // re-probing while it is valid (R3: after the lifecycle ends it
          // is not reset by duplicate submissions).
          this.#markLifecycleExhausted(contextKey, task, attempts);
          this.#publishTerminalFailure(inFlightRecord.subscribers, task.candidate.url);
        } else if (this.#autoRetry) {
          // Below the cap: compute the backoff time from the authoritative
          // attempt count and schedule a context-bound, cancellable,
          // bounded retry lifecycle, ensuring progress to a terminal state
          // or success even when a static page sends no further candidate
          // updates.
          const delayMs = Math.min(this.#maxBackoffMs, this.#backoffBaseMs * Math.pow(2, attempts - 1));
          this.#scheduleRetry(task, Date.now() + delayMs, attempts);
        }
      }

      // Advance follow-up tasks
      this.#pump();
    })();
  }

  /**
   * Cancels all in-flight and queued requests of the given tab.
   */
  cancelTab(tabId) {
    if (!Number.isInteger(tabId)) return;

    // 1. Drop matching queued tasks
    this.#queue = this.#queue.filter((task) => task.tabId !== tabId);

    // 2. Abort matching in-flight tasks
    const controllers = this.#abortControllersByTab.get(tabId);
    if (controllers) {
      for (const ctrl of controllers) {
        try {
          ctrl.abort();
        } catch {}
      }
      this.#abortControllersByTab.delete(tabId);
    }

    // 3. Cancel all pending retry timers and retry lifecycles of the
    // matching tab (cancellation is user intent; no terminal state is
    // published)
    for (const [key, entry] of this.#retryTimers) {
      if (entry.tabId === tabId) {
        clearTimeout(entry.timerId);
        this.#retryTimers.delete(key);
      }
    }
    for (const [key, lc] of this.#retryLifecycles) {
      if (lc.tabId === tabId) this.#retryLifecycles.delete(key);
    }
  }

  // ===== Observation and diagnostics interface =====

  getActiveCounts() {
    return {
      global: this.#activeGlobalCount,
      byTab: new Map(this.#activeCountByTab),
      queueLength: this.#queue.length,
      inFlightCount: this.#inFlightTasks.size,
      cacheSize: this.#probeCache.size,
      failureSize: this.#failureLedger.size,
      retryTimerCount: this.#retryTimers.size,
      retryLifecycleCount: this.#retryLifecycles.size,
    };
  }

  clearAll() {
    for (const [tabId] of this.#abortControllersByTab) {
      this.cancelTab(tabId);
    }
    for (const entry of this.#retryTimers.values()) {
      clearTimeout(entry.timerId);
    }
    this.#retryTimers.clear();
    this.#retryLifecycles.clear();
    this.#queue = [];
    this.#inFlightTasks.clear();
    this.#probeCache.clear();
    this.#failureLedger.clear();
    this.#activeGlobalCount = 0;
    this.#activeCountByTab.clear();
  }
}
