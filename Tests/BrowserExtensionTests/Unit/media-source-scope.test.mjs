import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import test from "node:test";

const read = path => fs.readFileSync(new URL(`../../../BrowserExtension/chrome/src/${path}`, import.meta.url), "utf8");
const sources = ["shared/media-utils.js", "content/media-source-observer.js", "content/media-element-scope.js"].map(read);

function environment({ clock = Date } = {}) {
  const timers = [];
  const intervals = [];
  const context = vm.createContext({ URL: class extends URL {}, console, setTimeout: callback => { timers.push(callback); }, setInterval: callback => intervals.push(callback), Date: class extends clock {} });
  // All constructors live in this VM: observer patches must not touch Node's
  // prototypes or leak across parallel tests.
  vm.runInContext(`
    globalThis.location = { href: "https://generic.example/thread", origin: "https://generic.example" };
    const listeners = [];
    globalThis.addEventListener = (type, fn) => { if (type === "message") listeners.push(fn); };
    globalThis.postMessage = data => { for (const fn of listeners) fn({ source: globalThis, data }); };
    globalThis.SourceBuffer = class { appendBuffer(value) { if (value === null) throw new Error("append failure"); this.value = value; } };
    globalThis.MediaSource = class { addSourceBuffer() { return new SourceBuffer(); } removeSourceBuffer() {} };
    let sequence = 0;
    URL.createObjectURL = () => "blob:" + location.origin + "/" + (++sequence);
    URL.revokeObjectURL = () => {};
    globalThis.Response = class {
      constructor(url, value) { this.url = url; this.value = value; }
      async arrayBuffer() { return this.value; }
      async blob() { return this.value; }
      async text() { return this.value; }
      clone() { return new Response(this.url, this.value); }
    };
    globalThis.XMLHttpRequest = class {
      open() {};
      get response() { return this.value; }
      get responseText() { return this.value; }
    };
    globalThis.fetch = async (url) => new Response(url, new ArrayBuffer(32));
    globalThis.element = src => ({ currentSrc: src, getAttribute(name) { return name === "src" ? src : null; }, querySelectorAll() { return []; } });
    globalThis.urlsFor = (src, candidates) => MacIDMMediaElementScope.filterCandidates(element(src), candidates, location.href).map(c => c.url);
  `, context);
  for (const source of sources) vm.runInContext(source, context);
  return {
    run: code => vm.runInContext(code, context),
    tick() { for (const callback of intervals) callback(); },
    flush() { for (let i = 0; timers.length && i < 20; i++) timers.shift()(); },
  };
}

test("generic fetch bytes -> MSE -> HLS ancestry isolates unrelated players on the same CDN", async () => {
  const env = environment();
  await env.run(`(async () => {
    globalThis.main = new MediaSource(); globalThis.reply = new MediaSource();
    globalThis.mainBlob = URL.createObjectURL(main); globalThis.replyBlob = URL.createObjectURL(reply);
    const first = main.addSourceBuffer(); const second = reply.addSourceBuffer();
    const a = await (await fetch("https://cdn.example/a/part.m4s")).arrayBuffer();
    const b = await (await fetch("https://cdn.example/b/part.m4s")).arrayBuffer();
    first.appendBuffer(new Uint8Array(a)); second.appendBuffer(b);
    await new Response("https://cdn.example/a/index.m3u8", "#EXTM3U\\n#EXTINF:6,\\npart.m4s").text();
    await new Response("https://cdn.example/a/master.m3u8", "#EXTM3U\\n#EXT-X-STREAM-INF:BANDWIDTH=1000\\nindex.m3u8").text();
    await new Response("https://cdn.example/b/index.m3u8", "#EXTM3U\\n#EXTINF:6,\\npart.m4s").text();
    globalThis.candidates = ["a/index.m3u8", "a/master.m3u8", "b/index.m3u8", "unknown.m3u8"].map(path => ({url: "https://cdn.example/" + path, format:"hls"}));
  })()`);
  env.flush();
  assert.deepEqual(Array.from(env.run("urlsFor(mainBlob, candidates)")), ["https://cdn.example/a/index.m3u8", "https://cdn.example/a/master.m3u8"]);
  assert.deepEqual(Array.from(env.run("urlsFor(replyBlob, candidates)")), ["https://cdn.example/b/index.m3u8"]);
  assert.equal(env.run("candidates.length"), 4);
  env.run("URL.revokeObjectURL(mainBlob)"); env.flush();
  assert.equal(env.run("urlsFor(mainBlob, candidates).length"), 0);
});

test("generic XHR and copied typed arrays retain origin; unobserved bytes never claim page media", () => {
  const env = environment();
  env.run(`
    globalThis.blob = URL.createObjectURL(globalThis.media = new MediaSource());
    const xhr = new XMLHttpRequest(); xhr.open("GET", "https://cdn.example/audio.m4a");
    xhr.responseURL = "https://cdn.example/audio.m4a"; xhr.value = new ArrayBuffer(32);
    const copy = new Uint8Array(32); copy.set(new Uint8Array(xhr.response).subarray(0));
    media.addSourceBuffer().appendBuffer(copy);
    globalThis.candidates = [{url:xhr.responseURL,format:"audio"},{url:"https://cdn.example/other.m4a",format:"audio"}];
    globalThis.unknown = URL.createObjectURL(globalThis.other = new MediaSource());
    other.addSourceBuffer().appendBuffer(new ArrayBuffer(32));
  `);
  env.flush();
  assert.deepEqual(Array.from(env.run("urlsFor(blob, candidates)")), ["https://cdn.example/audio.m4a"]);
  assert.equal(env.run("urlsFor(unknown, candidates).length"), 0);
});

test("navigation and delayed reads cannot resurrect a previous player's resources", async () => {
  const env = environment();
  await env.run(`(async () => {
    globalThis.response = await fetch("https://cdn.example/old.mp4");
    globalThis.candidates = [{url:response.url,format:"video"}];
    location.href = "https://generic.example/other";
    postMessage({type:"macidm.resetSniffState"});
    globalThis.media = new MediaSource(); globalThis.blob = URL.createObjectURL(media);
    media.addSourceBuffer().appendBuffer(await response.clone().arrayBuffer());
  })()`);
  env.flush();
  assert.equal(env.run("urlsFor(blob, candidates).length"), 0);
});

test("JSON collections and shared initialization files do not attribute every listed video", async () => {
  const env = environment();
  await env.run(`(async () => {
    globalThis.media = new MediaSource(); globalThis.blob = URL.createObjectURL(media);
    media.addSourceBuffer().appendBuffer(await (await fetch("https://cdn.example/init.mp4")).arrayBuffer());
    await new Response("https://cdn.example/a.m3u8", '#EXTM3U\\n#EXT-X-MAP:URI="init.mp4"\\n#EXTINF:6,\\na.m4s').text();
    await new Response("https://cdn.example/b.m3u8", '#EXTM3U\\n#EXT-X-MAP:URI="init.mp4"\\n#EXTINF:6,\\nb.m4s').text();
    await new Response("https://generic.example/api", JSON.stringify({videos:["https://cdn.example/a.m3u8","https://cdn.example/b.m3u8"]})).text();
    globalThis.candidates = ["a.m3u8","b.m3u8"].map(path => ({url:"https://cdn.example/"+path,format:"hls"}));
  })()`);
  env.flush();
  assert.equal(env.run("urlsFor(blob, candidates).length"), 0);
});

test("observer preserves append errors and rejected response reads", async () => {
  const env = environment();
  assert.throws(() => env.run("new SourceBuffer().appendBuffer(null)"), /append failure/);
  await assert.rejects(env.run("new Response('https://cdn.example/x', null).arrayBuffer.call({url:'x', get value() {throw new Error('read failure')} })"), /read failure/);
});

test("partial writes into a shared backing buffer cannot claim another view's media", async () => {
  const env = environment();
  await env.run(`(async () => {
    const a = new Uint8Array(await (await fetch("https://cdn.example/a.mp4")).arrayBuffer());
    const pool = new ArrayBuffer(64);
    const left = new Uint8Array(pool, 0, 32); const right = new Uint8Array(pool, 32, 32);
    left.set(a);
    globalThis.media = new MediaSource(); globalThis.blob = URL.createObjectURL(media);
    media.addSourceBuffer().appendBuffer(right);
    globalThis.candidates = [{url:"https://cdn.example/a.mp4",format:"video"},{url:"https://cdn.example/b.mp4",format:"video"}];
  })()`);
  env.flush();
  assert.equal(env.run("urlsFor(blob, candidates).length"), 0);
});

test("changing a declared src must not use stale currentSrc attribution", () => {
  const env = environment();
  assert.equal(env.run(`MacIDMMediaElementScope.filterCandidates({currentSrc:"https://cdn.example/old.mp4",getAttribute(name){return name === "src" ? "https://cdn.example/new.mp4" : null;},querySelectorAll(){return [];}},[{url:"https://cdn.example/old.mp4",format:"video"}], location.href).length`),0);
});


test("removing a SourceBuffer clears its old resource ownership", async () => {
  const env = environment();
  await env.run(`(async () => {
    globalThis.media = new MediaSource(); globalThis.blob = URL.createObjectURL(media);
    globalThis.buffer = media.addSourceBuffer();
    buffer.appendBuffer(await (await fetch("https://cdn.example/a.mp4")).arrayBuffer());
    globalThis.candidates = [{url:"https://cdn.example/a.mp4",format:"video"}];
  })()`);
  env.flush();
  assert.equal(env.run("urlsFor(blob, candidates).length"), 1);
  env.run("media.removeSourceBuffer(buffer)"); env.flush();
  assert.equal(env.run("urlsFor(blob, candidates).length"), 0);
});

test("X association requires the exact official host, namespace and media ID", () => {
  const env = environment();
  const result = env.run(`(() => {
    location.href = "https://x.com/user/status/123";
    const video = {getAttribute(name) { return name === "poster" ? "https://pbs.twimg.com/amplify_video_thumb/111/img/p.jpg" : null; }, querySelectorAll(){return [];} };
    const candidates = [
      "https://video.twimg.com/amplify_video/111/pl/master.m3u8",
      "https://video.twimg.com/amplify_video/222/pl/master.m3u8",
      "https://video.twimg.com/ext_tw_video/111/pl/master.m3u8",
      "https://video.twimg.com.evil.example/amplify_video/111/pl/master.m3u8"
    ].map(url=>({url,format:"hls"}));
    return MacIDMMediaElementScope.filterCandidates(video,candidates,location.href).map(c=>c.url);
  })()`);
  assert.deepEqual(Array.from(result), ["https://video.twimg.com/amplify_video/111/pl/master.m3u8"]);
});


test("revoked object URLs retain attribution while their MediaSource is still attached", async () => {
  const env = environment();
  await env.run(`(async () => {
    globalThis.media = new MediaSource(); globalThis.blob = URL.createObjectURL(media);
    globalThis.video = element(blob); globalThis.document = {querySelectorAll(){return [video];}};
    URL.revokeObjectURL(blob);
    media.addSourceBuffer().appendBuffer(await (await fetch("https://cdn.example/a.mp4")).arrayBuffer());
    globalThis.candidates = [{url:"https://cdn.example/a.mp4",format:"video"}];
  })()`);
  env.flush();
  assert.equal(env.run("urlsFor(blob, candidates).length"),1);
  env.run("document.querySelectorAll=()=>[];postMessage({type:'macidm.requestMediaSourceSnapshot'})");env.flush();
  assert.equal(env.run("urlsFor(blob, candidates).length"),0);
});

test("快照 TTL 过期：blob 归属节流重取自愈（长播放页 FAB 不再静默消失）", async () => {
  const env = environment();
  await env.run(`(async () => {
    globalThis.media = new MediaSource(); globalThis.blob = URL.createObjectURL(media);
    media.addSourceBuffer().appendBuffer(await (await fetch("https://cdn.example/live.m4s")).arrayBuffer());
    globalThis.candidates = [{url:"https://cdn.example/live.m4s",format:"video"}];
  })()`);
  env.flush();
  assert.equal(env.run("urlsFor(blob, candidates).length"), 1, "快照有效期内：归属存在");
  // 模拟播放超过 5 分钟：快照过期且 observer 不再主动广播（详情页长视频）。
  env.run("globalThis.__realNow = Date.now; Date.now = () => __realNow.call(Date) + 6 * 60 * 1000;");
  assert.equal(env.run("urlsFor(blob, candidates).length"), 0, "过期后首轮：空，但必须触发重请求");
  env.flush(); // observer 的快照应答经由延迟广播
  assert.equal(env.run("urlsFor(blob, candidates).length"), 1, "重请求后（observer 已应答）：归属恢复，FAB 可重新附着");
});

test("only mounted blob owners survive, and recoverable URLs restore a missed media candidate", async () => {
  const env = environment();
  await env.run(`(async () => {
    globalThis.a = new MediaSource(); globalThis.b = new MediaSource();
    globalThis.ab = URL.createObjectURL(a); globalThis.bb = URL.createObjectURL(b);
    a.addSourceBuffer().appendBuffer(await (await fetch("https://cdn.example/a.mp4")).arrayBuffer());
    b.addSourceBuffer().appendBuffer(await (await fetch("https://cdn.example/b.mp4")).arrayBuffer());
    globalThis.document = { querySelectorAll: () => [element(ab)] };
  })()`);
  env.flush();
  assert.deepEqual(Array.from(env.run("MacIDMMediaElementScope.liveURLs()")), ["https://cdn.example/a.mp4"]);
  assert.deepEqual(Array.from(env.run("MacIDMMediaElementScope.recoverableCandidates().map(c => c.url)")), ["https://cdn.example/a.mp4"]);
  env.run("document.querySelectorAll = () => []");
  assert.equal(env.run("MacIDMMediaElementScope.liveURLs().size"), 0);
});

test("paused blob owners refresh snapshots without DOM renders, including after TTL", () => {
  let now = 1000;
  const env = environment({ clock: class extends Date { static now() { return now; } } });
  env.run(`
    globalThis.requests = 0;
    addEventListener("message", e => { if (e.data.type === "macidm.requestMediaSourceSnapshot") requests++; });
    globalThis.document = { querySelectorAll: () => [element("blob:https://generic.example/paused")] };
  `);
  env.flush();
  now += 3100; env.tick(); env.flush();
  assert.equal(env.run("requests"), 1);
  now += 310000; env.tick(); env.flush();
  assert.equal(env.run("requests"), 2);
  env.run("document.querySelectorAll = () => []");
  now += 16000; env.tick(); env.flush();
  assert.equal(env.run("requests"), 2, "no requests without mounted blob owners");
});

test("production content snapshot recovers observed Douyin media after missed capture and SPA reset", async () => {
  const env = environment();
  env.run(`
    location.href = "https://www.douyin.com/jingxuan";
    location.origin = "https://www.douyin.com";
    location.hostname = "www.douyin.com";
    globalThis.window = globalThis; globalThis.top = globalThis;
    globalThis.clearTimeout = () => {};
    globalThis.performance = { getEntriesByType: () => [], now: () => 1 };
    globalThis.MutationObserver = class { observe() {} };
    globalThis.chrome = { runtime: {
      onMessage: { addListener(fn) { globalThis.runtimeListener = fn; } },
      sendMessage: () => Promise.resolve()
    } };
    globalThis.document = { title: "抖音", documentElement: {}, addEventListener() {},
      querySelector: () => null,
      querySelectorAll: selector => selector === "video, audio" ? (globalThis.mounted || []) : [] };
    globalThis.mounted = [];
  `);
  env.run(read("content/discovery.js"));
  env.run(read("content/content-script.js"));
  await env.run(`(async () => {
    globalThis.media = new MediaSource(); globalThis.blob = URL.createObjectURL(media);
    globalThis.mounted = [element(blob)];
    media.addSourceBuffer().appendBuffer(await (await fetch("https://v11-weba.douyinvod.com/resource/?mime_type=video_mp4")).arrayBuffer());
  })()`);
  env.flush();
  const scan = () => env.run(`runtimeListener({ type: "macidm.getMediaCandidates" }, {}, value => { globalThis.reply = value; }); reply.candidates.map(c => c.url)`);
  assert.deepEqual(Array.from(scan()), ["https://v11-weba.douyinvod.com/resource/?mime_type=video_mp4"]);
  env.run(`runtimeListener({ type: "macidm.addMediaCandidate", updateOnly: true,
    candidate: { url: location.href, sizeProbeFailed: true } }, {}, () => {});`);
  assert.deepEqual(Array.from(scan()), ["https://v11-weba.douyinvod.com/resource/?mime_type=video_mp4"]);
  env.run('location.href += "?modal_id=123"');
  env.flush(); scan(); env.flush();
  assert.deepEqual(Array.from(scan()), ["https://v11-weba.douyinvod.com/resource/?mime_type=video_mp4"]);
});

test("snapshot prioritizes a mounted player over more than sixteen preloaded MediaSources", async () => {
  const env = environment();
  await env.run(`(async()=>{
    const active = new MediaSource(); globalThis.ab = URL.createObjectURL(active);
    active.addSourceBuffer().appendBuffer(await (await fetch("https://cdn.example/active.mp4")).arrayBuffer());
    document = {querySelectorAll:()=>[element(ab)]};
    for(let i=0;i<20;i++) URL.createObjectURL(new MediaSource());
  })()`);
  env.flush();
  assert.equal(env.run('urlsFor(ab,[{url:"https://cdn.example/active.mp4",format:"video"}]).length'),1);
});

test("actual byte ownership pairs split tracks across CDN hosts and different expiry directories", async () => {
  const env = environment();
  await env.run(`(async()=>{
    const media=new MediaSource(); globalThis.blob=URL.createObjectURL(media);
    globalThis.videoURL="https://v1.douyinvod.com/hash/expiry-a/media-video-hvc1/";
    globalThis.audioURL="https://v2.douyinvod.com/hash/expiry-b/media-audio-mp4a/";
    media.addSourceBuffer().appendBuffer(await(await fetch(videoURL)).arrayBuffer());
    media.addSourceBuffer().appendBuffer(await(await fetch(audioURL)).arrayBuffer());
    document={querySelectorAll:()=>[element(blob)]};
  })()`); env.flush();
  env.run(`globalThis.paired=MacIDMMediaUtils.coalesceMediaCandidates(MacIDMMediaElementScope.annotateOwnership(
    [{url:videoURL,format:"video"},{url:audioURL,format:"video"}]));`);
  assert.equal(env.run('paired.length'),1); assert.equal(env.run('paired[0].pairKind'),"m4s-pair");
  assert.equal(env.run('urlsFor(blob,paired).length'),1);
});
