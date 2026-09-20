// MAIN-world provenance observer. Observe bytes the player already reads;
// never fetch, clone, consume, or retain media payloads for attribution.
(function installMediaSourceObserver(global) {
  if (global.__macIDMMediaSourceObserverInstalled) return;
  global.__macIDMMediaSourceObserverInstalled = true;
  const SNAPSHOT = "macidm.mediaSourceSnapshot";
  const REQUEST = "macidm.requestMediaSourceSnapshot";
  const LIMIT = 128;
  // Fetches initiated just before an SPA transition respond (and get appended)
  // after reset, carrying the previous generation's epoch. Accept them for a
  // short window so a click-through detail/modal player keeps its blob->CDN
  // mapping instead of losing the FAB until the next seek/refetch.
  const RESET_GRACE_MS = 8_000;
  let generation = 0;
  let lastResetAt = 0;
  let pageURL = global.location?.href;
  const responses = new WeakMap();
  let tainted = new WeakSet();
  let payloads = new WeakMap();
  let sources = new WeakMap();
  let buffers = new WeakMap();
  const blobs = new Map();
  const revokedBlobs = new Set();
  const parents = new Map();
  let scheduled = false;

  function reset() {
    generation += 1;
    lastResetAt = Date.now();
    pageURL = global.location?.href;
    tainted = new WeakSet();
    payloads = new WeakMap();
    parents.clear();
    revokedBlobs.clear();
    // Structural associations (MediaSource/SourceBuffer/blob-URL -> record)
    // survive navigation: an SPA that reuses the same MSE player across a
    // route change must keep attributing post-navigation feeds, otherwise the
    // blob->CDN mapping is lost and the overlay shows no button. Only byte
    // provenance (payloads) and page-scoped playlist ancestry (parents) are
    // dropped. Pre-navigation segment URLs are cleared so the old page cannot
    // leak into the new one — except for blobs a still-mounted player keeps
    // using (a modal route over the same feed plays the same content; clearing
    // those would leave a paused reused player unattributable until it
    // fetches again). Records not reachable via the iterable `blobs`
    // Map (WeakMap-keyed sources/buffers) re-sync lazily in adoptRecord().
    const liveBlobs = new Set();
    const doc = global.document;
    if (doc && typeof doc.querySelectorAll === "function") {
      try {
        for (const media of doc.querySelectorAll("video, audio")) {
          for (const value of [media?.src, media?.currentSrc]) {
            if (typeof value === "string" && value.startsWith("blob:")) liveBlobs.add(value);
          }
        }
      } catch {
        // Ignore DOM read failures; fall back to clearing every record.
      }
    }
    for (const [blobURL, record] of blobs) {
      record.epoch = generation;
      if (!liveBlobs.has(blobURL)) record.urls.clear();
    }
    publish();
  }
  // Re-bind a carried-over record to the current generation the first time it
  // is used post-navigation, dropping its pre-navigation URLs.
  function adoptRecord(record, epoch) {
    if (record.epoch !== epoch) {
      record.epoch = epoch;
      record.urls.clear();
    }
    return record;
  }
  function current() {
    if (pageURL !== global.location?.href) reset();
    return generation;
  }
  function http(raw, base = pageURL) {
    if (typeof raw !== "string" || !raw.trim()) return null;
    try {
      const url = new URL(raw, base);
      if (!["http:", "https:"].includes(url.protocol) || url.href.length > 8192) return null;
      url.hash = "";
      return url.href;
    } catch { return null; }
  }
  function boundedAdd(map, key, value) {
    if (!map.has(key) && map.size >= LIMIT) {
      const victim = map === blobs ? [...map.keys()].find(url => !attachedBlob(url)) : map.keys().next().value;
      map.delete(victim ?? map.keys().next().value);
    }
    map.set(key, value);
  }
  function remember(value, url, epoch, graced = false) {
    if (!value || typeof value !== "object" || !url) return;
    const gen = current();
    const inGrace = graced || (epoch === gen - 1 && Date.now() - lastResetAt < RESET_GRACE_MS);
    if ((epoch === gen || inGrace) && !tainted.has(value.buffer ?? value)) {
      // Graced payloads stay marked: appendBuffer only honors them while the
      // appended record's blob is still mounted on a live media element, so
      // a removed previous player's late reads cannot resurrect its URLs.
      payloads.set(value, { url, epoch: gen, graced: inGrace });
    }
  }
  function publish() {
    if (scheduled) return;
    scheduled = true;
    global.setTimeout(() => {
      scheduled = false;
      current();
      try {
        const live = attachedBlobs();
        for (const blob of revokedBlobs) {
          if (!live.has(blob)) { blobs.delete(blob); revokedBlobs.delete(blob); }
        }
        global.postMessage({ type: SNAPSHOT, pageURL, generation,
          blobs: [...blobs].sort((a, b) => Number(live.has(b[0])) - Number(live.has(a[0])))
            .slice(0, 16).map(([blob, record]) => [blob, [...record.urls]]),
          parents: [...parents].map(([child, urls]) => [child, [...urls]]),
        }, "*");
      } catch {}
    }, 50);
  }
  function attachedBlobs() {
    return new Set([...(global.document?.querySelectorAll?.("video, audio") ?? [])]
      .map(element => element.getAttribute?.("src") || element.currentSrc).filter(Boolean));
  }
  function attachedBlob(url) {
    // Revoked object URLs can remain attached to an active player.
    return attachedBlobs().has(url);
  }
  function recordBlobIsLive(record) {
    for (const [blobURL, rec] of blobs) {
      if (rec === record && attachedBlob(blobURL)) return true;
    }
    return false;
  }
  function edge(parent, child) {
    if (!child || parent === child) return;
    const urls = parents.get(child) ?? new Set();
    // Ambiguous/shared URLs are bounded too. No host or prefix matching.
    if (urls.size < 8) urls.add(parent);
    boundedAdd(parents, child, urls);
  }
  function manifest(text, rawURL, epoch) {
    const gen = current();
    const inGrace = epoch === gen - 1 && Date.now() - lastResetAt < RESET_GRACE_MS;
    if ((epoch !== gen && !inGrace) || typeof text !== "string" || text.length > 262144) return;
    const url = http(rawURL);
    if (!url) return;
    if (text.trimStart().startsWith("#EXTM3U")) {
      let resourceFollows = false;
      for (const raw of text.split(/\r?\n/u).slice(0, 4096)) {
        const line = raw.trim();
        if (/^#EXT(?:INF:|-X-STREAM-INF:)/u.test(line)) resourceFollows = true;
        else if (line && !line.startsWith("#")) {
          if (resourceFollows) edge(url, http(line, url));
          resourceFollows = false;
        } else if (/^#EXT-X-MEDIA:/u.test(line)) {
          const uri = line.match(/(?:[:,])URI="([^"]+)"/u);
          if (uri) edge(url, http(uri[1], url));
        }
      }
    } else if (/^\s*(?:<\?xml[^>]*>\s*)?<MPD[\s>]/u.test(text) && global.DOMParser) {
      // Explicit DASH resources only. Templates and ambiguous BaseURL
      // alternatives are left unresolved rather than guessed by URL prefix.
      const doc = new global.DOMParser().parseFromString(text, "application/xml");
      if (doc.querySelector("parsererror")) return;
      for (const node of [...doc.querySelectorAll("SegmentURL, Representation")].slice(0, 256)) {
        let base = url;
        const chain = [];
        for (let p = node; p && p.nodeType === 1; p = p.parentElement) chain.unshift(p);
        let ambiguous = false;
        for (const p of chain) {
          const bases = [...p.children].filter(child => child.localName === "BaseURL");
          if (bases.length > 1) { ambiguous = true; break; }
          if (bases.length === 1) base = http(bases[0].textContent.trim(), base);
          if (!base) { ambiguous = true; break; }
        }
        if (ambiguous) continue;
        const media = node.getAttribute("media");
        if (media) edge(url, http(media, base));
        else if (node.localName === "Representation" && /\.(?:mp4|m4a|webm)(?:[?#]|$)/iu.test(base)) edge(url, base);
      }
    } else return;
    publish();
  }
  function recordFor(source) {
    current();
    let record = sources.get(source);
    if (!record) {
      record = { epoch: generation, urls: new Set() };
      sources.set(source, record);
    }
    return record;
  }
  function safely(work) { try { work(); } catch {} }

  safely(() => {
    const fetch = global.fetch;
    if (typeof fetch === "function") global.fetch = function (...args) {
      const epoch = current();
      return fetch.apply(this, args).then(response => {
        safely(() => responses.set(response, epoch));
        return response;
      });
    };
    const clone = global.Response?.prototype?.clone;
    if (clone) global.Response.prototype.clone = function (...args) {
      const response = clone.apply(this, args);
      safely(() => responses.set(response, responses.get(this) ?? current()));
      return response;
    };
  });

  // Fetch arrayBuffer/blob/text, including clones: Response.url preserves
  // the final redirected resource identity. Rejections and values pass through.
  for (const method of ["arrayBuffer", "blob", "text"]) safely(() => {
    const prototype = global.Response?.prototype;
    const original = prototype?.[method];
    if (typeof original !== "function") return;
    prototype[method] = function (...args) {
      const epoch = responses.get(this) ?? current();
      const url = http(this.url);
      return original.apply(this, args).then(value => {
        safely(() => method === "text" ? manifest(value, url, epoch) : remember(value, url, epoch));
        return value;
      });
    };
  });

  // Fetch streaming readers: tag each chunk with the response URL without
  // pulling an extra chunk or changing backpressure.
  safely(() => {
    const streams = new WeakMap();
    const readers = new WeakMap();
    const body = Object.getOwnPropertyDescriptor(global.Response?.prototype ?? {}, "body");
    if (body?.get && body.configurable) Object.defineProperty(global.Response.prototype, "body", {
      ...body, get() {
        const stream = body.get.call(this);
        safely(() => { if (stream) streams.set(stream, { url: http(this.url), epoch: responses.get(this) ?? current() }); });
        return stream;
      },
    });
    const getReader = global.ReadableStream?.prototype?.getReader;
    if (getReader) global.ReadableStream.prototype.getReader = function (...args) {
      const reader = getReader.apply(this, args);
      safely(() => { const source = streams.get(this); if (source) readers.set(reader, source); });
      return reader;
    };
    for (const Reader of [global.ReadableStreamDefaultReader, global.ReadableStreamBYOBReader]) {
      const read = Reader?.prototype?.read;
      if (!read) continue;
      Reader.prototype.read = function (...args) {
        const source = readers.get(this);
        return read.apply(this, args).then(result => {
          safely(() => { if (source) remember(result.value?.buffer ?? result.value, source.url, source.epoch, source.graced); });
          return result;
        });
      };
    }
  });

  // Preserve known provenance through the common byte-copy operations used
  // by players/transmuxers. Mixed origins fail closed; payload bytes are never
  // inspected or retained. New allocations without a tracked input stay unknown.
  safely(() => {
    const info = value => tainted.has(value?.buffer ?? value) ? null : (payloads.get(value) ?? payloads.get(value?.buffer));
    for (const prototype of [global.ArrayBuffer?.prototype, Object.getPrototypeOf(global.Uint8Array?.prototype ?? {})]) {
      for (const method of ["slice", "subarray"]) {
        const original = prototype?.[method];
        if (typeof original !== "function") continue;
        prototype[method] = function (...args) {
          const value = original.apply(this, args);
          safely(() => { const source = info(this); if (source) remember(value?.buffer ?? value, source.url, source.epoch, source.graced); });
          return value;
        };
      }
    }
    const prototype = Object.getPrototypeOf(global.Uint8Array?.prototype ?? {});
    const set = prototype?.set;
    if (set) prototype.set = function (input, ...args) {
      const result = set.call(this, input, ...args);
      safely(() => {
        const target = this.buffer;
        const source = info(input);
        const previous = info(this);
        if (tainted.has(target)) return;
        if (this.byteOffset !== 0 || this.byteLength !== target.byteLength || input?.byteLength !== this.byteLength) {
          // A partial view does not prove the provenance of its backing pool.
          // Reused pools and partially overwritten old media must stay unknown.
          payloads.delete(target);
          payloads.delete(this);
          tainted.add(target);
          return;
        }
        if (previous && (!source || previous.url !== source.url || previous.epoch !== source.epoch)) {
          payloads.delete(target);
          payloads.delete(this);
          tainted.add(target);
        } else if (source) remember(target, source.url, source.epoch, source.graced);
      });
      return result;
    };
  });

  // XHR response getters are observed before the application's onload reads
  // the buffer, so attribution is available even for synchronous appendBuffer.
  safely(() => {
    const prototype = global.XMLHttpRequest?.prototype;
    const descriptor = Object.getOwnPropertyDescriptor(prototype ?? {}, "response");
    if (!descriptor?.get || !descriptor.configurable) return;
    const epochs = new WeakMap();
    const open = prototype.open;
    prototype.open = function (...args) {
      const result = open.apply(this, args);
      safely(() => epochs.set(this, current()));
      return result;
    };
    Object.defineProperty(prototype, "response", { ...descriptor, get() {
      const value = descriptor.get.call(this);
      safely(() => {
        const epoch = epochs.get(this);
        const url = http(this.responseURL);
        if (typeof value === "string") manifest(value, url, epoch);
        else remember(value, url, epoch);
      });
      return value;
    } });
    const textDescriptor = Object.getOwnPropertyDescriptor(prototype, "responseText");
    if (textDescriptor?.get && textDescriptor.configurable) Object.defineProperty(prototype, "responseText", {
      ...textDescriptor, get() {
        const value = textDescriptor.get.call(this);
        safely(() => { if (this.readyState === 4) manifest(value, this.responseURL, epochs.get(this)); });
        return value;
      },
    });
  });

  for (const MediaSource of [global.MediaSource, global.ManagedMediaSource]) safely(() => {
    const prototype = MediaSource?.prototype;
    const original = prototype?.addSourceBuffer;
    if (typeof original !== "function") return;
    prototype.addSourceBuffer = function (...args) {
      const buffer = original.apply(this, args);
      safely(() => buffers.set(buffer, recordFor(this)));
      return buffer;
    };
    const remove = prototype.removeSourceBuffer;
    if (typeof remove === "function") prototype.removeSourceBuffer = function (buffer) {
      const result = remove.apply(this, arguments);
      safely(() => {
        // A player rebuilding its tracks must not retain the old source URLs.
        const record = sources.get(this);
        record?.urls.clear();
        buffers.delete(buffer);
        publish();
      });
      return result;
    };
  });
  safely(() => {
    const prototype = global.SourceBuffer?.prototype;
    const append = prototype?.appendBuffer;
    if (typeof append !== "function") return;
    prototype.appendBuffer = function (data) {
      const result = append.apply(this, arguments);
      safely(() => {
        const epoch = current();
        const record = buffers.get(this);
        const payload = tainted.has(data?.buffer ?? data) ? null : (payloads.get(data) ?? payloads.get(data?.buffer));
        if (!record || !payload || payload.epoch !== epoch) return;
        // Grace-normalized payloads (fetches initiated before an SPA
        // transition) only count while the appended record's blob is still
        // mounted on a live media element — a removed previous player's late
        // appends must not resurrect its URLs.
        if (payload.graced && !recordBlobIsLive(record)) return;
        // A record carried over from a previous generation (SPA reused the
        // same MediaSource) adopts the current generation now that post-
        // navigation bytes are being appended; its stale URLs were dropped.
        adoptRecord(record, epoch);
        if (record.urls.size >= LIMIT) record.urls.delete(record.urls.values().next().value);
        record.urls.add(payload.url);
        publish();
      });
      return result;
    };
  });
  safely(() => {
    const create = global.URL?.createObjectURL;
    const revoke = global.URL?.revokeObjectURL;
    if (typeof create !== "function") return;
    global.URL.createObjectURL = function (object) {
      const url = create.apply(this, arguments);
      safely(() => {
        const epoch = current();
        const payload = payloads.get(object);
        let record = null;
        if ((global.MediaSource && object instanceof global.MediaSource)
            || (global.ManagedMediaSource && object instanceof global.ManagedMediaSource)) record = adoptRecord(recordFor(object), epoch);
        else if (payload?.epoch === epoch) record = { epoch, urls: new Set([payload.url]) };
        if (record) { boundedAdd(blobs, url, record); publish(); }
      });
      return url;
    };
    if (typeof revoke === "function") global.URL.revokeObjectURL = function (url) {
      const result = revoke.apply(this, arguments);
      safely(() => {
        if (blobs.has(url) && attachedBlob(url)) revokedBlobs.add(url);
        else blobs.delete(url);
        publish();
      });
      return result;
    };
  });
  global.addEventListener?.("message", event => {
    if (event.source !== global) return;
    if (event.data?.type === REQUEST) { current(); publish(); }
    if (event.data?.type === "macidm.resetSniffState") reset();
  });
})(globalThis);
