// Tests PlayerScript.js in node with a stand-in page: which video it picks,
// playing, pausing, seeking, the mini-player switch, and what it reports.
// Run: node Tests/Player/script_test.js
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', '..', 'PlayerScript.js'), 'utf8');
let failures = 0, checks = 0;
const expect = (ok, what) => { checks++; if (!ok) { failures++; console.log('FAIL: ' + what); } };

function makeBox(parent) {
  return { parentElement: parent, attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, removeAttribute(k) { delete this.attrs[k]; } };
}

function makeVideo({ paused = true, width = 100, height = 56, duration = 100, readyState = 4, parent = null, muted = false,
                     youtubes = false, rejects = false } = {}) {
  return {
    parentElement: parent, paused, muted, ended: false, currentTime: 0, duration, readyState, attrs: {}, plays: 0,
    // YouTube marks its own player's video .html5-main-video.
    classList: youtubes ? { contains: (c) => c === 'html5-main-video' } : { contains: () => false },
    getBoundingClientRect() { return { width, height }; },
    setAttribute(k, v) { this.attrs[k] = v; },
    removeAttribute(k) { delete this.attrs[k]; },
    play() { this.paused = false; this.plays++; return rejects ? Promise.reject(new Error('NotAllowedError')) : Promise.resolve(); },
    pause() { this.paused = true; },
  };
}

function makePage(videos, pathname = '/watch') {
  const posted = [], listeners = {}, appended = [], timers = [];
  const classes = new Set();
  const boxes = [];
  for (const v of videos) for (let e = v.parentElement; e; e = e.parentElement) if (!boxes.includes(e)) boxes.push(e);
  const document = {
    title: 'Song - YouTube',
    head: { appendChild(n) { appended.push(n); } },
    documentElement: { classList: { toggle(c, on) { if (on) classes.add(c); else classes.delete(c); } } },
    createElement(tag) { return { tag }; },
    addEventListener(type, fn, capture) { (listeners[type] = listeners[type] || []).push({ fn, capture }); },
    querySelector(selector) {
      if (selector === '.ad-showing, .ad-interrupting') return page.ad ? {} : null;
      throw new Error('unexpected selector ' + selector);
    },
    querySelectorAll(selector) {
      if (selector === 'video') return page.videos;
      if (selector === 'video[data-hammer-main]') return page.videos.filter((v) => 'data-hammer-main' in v.attrs);
      if (selector === '[data-hammer-path]') return boxes.filter((e) => 'data-hammer-path' in e.attrs);
      throw new Error('unexpected selector ' + selector);
    },
  };
  const window = { webkit: { messageHandlers: { hammer: { postMessage(m) { posted.push(m); } } } } };
  const location = { pathname };
  document.body = boxes.find((e) => e.isBody) || null;
  document.documentElement.parentElement = null;
  const page = { videos, posted, listeners, appended, classes, document, window, timers, location, boxes };
  page.run = () => vm.runInNewContext(source, {
    window, document, location, Array, Math, Infinity, JSON,
    setInterval: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
  });
  page.tick = () => timers.forEach((t) => t.fn());
  page.fire = (type) => (listeners[type] || []).forEach((l) => l.fn());
  return page;
}

// Loading twice (YouTube changes pages without reloading) sets up once.
const body = Object.assign(makeBox(null), { isBody: true });
const feed = makeBox(body);
const player = makeBox(makeBox(body));              // two boxes between the video and <body>
let main = makeVideo({ width: 420, height: 236, parent: player });
let page = makePage([makeVideo({ width: 160, height: 90, parent: feed }), main]);
page.run();
page.run();
expect(page.listeners.play.length === 1 && page.appended.length === 1, 'set up once');
expect(page.listeners.play[0].capture === true, 'listens on the way down (media events do not bubble)');
expect(page.posted.length === 1 && page.posted[0].playing === false && page.posted[0].hasVideo === true
       && page.posted[0].title === 'Song - YouTube', 'reports when it starts: ' + JSON.stringify(page.posted[0]));

expect(page.timers.length === 1 && page.timers[0].ms === 1500, 'looks again every 1.5 s');
page.tick();
expect(page.posted.length === 1, 'nothing changed: nothing sent');
page.document.title = 'Next song - YouTube';
page.tick();
expect(page.posted.length === 2 && page.posted[1].title === 'Next song - YouTube', 'a new title is sent');

// Picks the biggest video when none plays, the playing one when one does.
const hammer = page.window.__hammer;
expect(hammer.toggle() === true && main.paused === false, 'toggle plays the biggest video');
const preview = page.videos[0];
preview.paused = false;               // a small muted preview starts in the feed
main.paused = true;
hammer.toggle();
expect(preview.paused === true && main.paused === true, 'toggle pauses the one playing, even if small');
main.paused = false; preview.paused = false;
page.fire('play');
expect(page.posted[page.posted.length - 1].playing === true, 'reports playing');
main.ended = true; main.paused = true; preview.paused = true;
expect(hammer.toggle() === true && main.plays === 2, 'an ended video plays again');
main.ended = false;

// Seeking stays within the video.
main.currentTime = 5;
hammer.seek(-10);
expect(main.currentTime === 0, 'seek back stops at 0');
hammer.seek(250);
expect(main.currentTime === 100, 'seek forward stops at the end');
main.duration = NaN; main.currentTime = 50;    // live streams
hammer.seek(10);
expect(main.currentTime === 60, 'no known length: seeks freely');
main.duration = 100;

// Mini player: marks the main video and switches the page's look; off undoes it.
main.paused = false; preview.paused = true;
expect(hammer.mini(true) === true && 'data-hammer-main' in main.attrs && !('data-hammer-main' in preview.attrs)
       && page.classes.has('hammer-mini'), 'mini on: the main video is marked');
preview.paused = false; main.paused = true;
hammer.mini(true);
expect('data-hammer-main' in preview.attrs && !('data-hammer-main' in main.attrs), 'only one video is ever marked');
expect(hammer.mini(false) === false && !page.classes.has('hammer-mini')
       && page.videos.every((v) => !('data-hammer-main' in v.attrs)), 'mini off: back to normal');
expect(/hammer-mini video\[data-hammer-main\]/.test(page.appended[0].textContent), 'the style targets the marked video');
main.paused = false; preview.paused = true;
hammer.mini(true);
expect('data-hammer-path' in player.attrs && 'data-hammer-path' in player.parentElement.attrs
       && !('data-hammer-path' in body.attrs) && !('data-hammer-path' in feed.attrs), 'the boxes around the video are marked, not <body>');
hammer.mini(false);
expect(page.boxes.every((e) => !('data-hammer-path' in e.attrs)), 'and unmarked after');
expect(/\[data-hammer-path\] \{ display: block !important; \}/.test(page.appended[0].textContent), 'marked boxes are shown');
expect(/html:not\(\.hammer-mini\), html:not\(\.hammer-mini\) body \{ background: transparent !important;/.test(page.appended[0].textContent),
       'outside the mini player the page background is cleared for the glass');

// A video page counts as having a video before anything has loaded; other pages don't.
page = makePage([makeVideo({ duration: NaN, readyState: 0 })], '/watch');
page.run();
expect(page.posted[0].hasVideo === true, 'a watch page has a video before it loads');
page = makePage([makeVideo({ duration: NaN, readyState: 0 })], '/');
page.run();
expect(page.posted[0].hasVideo === false, 'an unloaded preview on the home page does not count');
page = makePage([makeVideo({ duration: NaN, readyState: 0 })], '/shorts/abc');
page.run();
expect(page.posted[0].hasVideo === true, 'shorts count');

// The home feed: a muted preview playing doesn't count; a video with sound does (YouTube's own little player).
page = makePage([makeVideo({ paused: false, muted: true })], '/');
page.run();
expect(page.posted[0].playing === false && page.posted[0].hasVideo === false, 'a muted feed preview is ignored');
page.videos[0].muted = false;
page.tick();
expect(page.posted[1].playing === true && page.posted[1].hasVideo === true, 'a video with sound counts on any page');

// Ads: reported, and never skipped.
const adVideo = makeVideo({ paused: false });
page = makePage([adVideo], '/watch');
page.ad = true;
page.run();
adVideo.currentTime = 3;
expect(page.posted[0].ad === true, 'an ad playing is reported');
expect(page.window.__hammer.seek(10) === false && adVideo.currentTime === 3, 'no seeking during an ad');
page.ad = false;
expect(page.window.__hammer.seek(10) === true && adVideo.currentTime === 13, 'seeking works again after it');
page.tick();
expect(page.posted[page.posted.length - 1].ad === false, 'the end of the ad is reported');

// No video on the page (search results, home): nothing breaks.
page = makePage([], '/results');
page.run();
const empty = page.window.__hammer;
expect(empty.toggle() === false && empty.hasVideo() === false && empty.mini(true) === false
       && !page.classes.has('hammer-mini'), 'no video: nothing to do');
empty.seek(10); empty.pause();
expect(page.posted[0].hasVideo === false && page.posted[0].playing === false, 'reports no video');

// A page without Hammer's message handler (opened elsewhere) doesn't throw.
page = makePage([makeVideo()]);
delete page.window.webkit;
let threw = false;
try { page.run(); page.window.__hammer.report(); } catch (e) { threw = true; }
expect(!threw, 'no message handler: no error');

// A watch page: the video is paused, and a small muted preview (in the list beside it) plays.
{
  const watched = makeVideo({ width: 420, height: 236 });
  const beside = makeVideo({ width: 160, height: 90, muted: true, paused: false });
  page = makePage([watched, beside], '/watch');
  page.run();
  const h = page.window.__hammer;
  expect(page.posted[0].playing === false, 'a muted preview playing beside a paused video is not "playing"');
  expect(h.mini(true) === true && 'data-hammer-main' in watched.attrs && !('data-hammer-main' in beside.attrs),
         'the mini player shows the video being watched, not the preview');
  h.mini(false);
  h.toggle();
  expect(watched.paused === false && beside.paused === false, 'play/pause plays the video being watched');
}
// YouTube's own player wins on a watch page, even muted and smaller.
{
  const own = makeVideo({ width: 300, height: 170, muted: true, youtubes: true });
  const other = makeVideo({ width: 640, height: 360, paused: false });
  page = makePage([other, own], '/watch');
  page.run();
  page.window.__hammer.mini(true);
  expect('data-hammer-main' in own.attrs, "YouTube's own player (.html5-main-video) is the one");
  page.window.__hammer.mini(false);
}
// Two videos with sound on a watch page, neither YouTube's: the playing one, else the biggest.
{
  const small = makeVideo({ width: 160, height: 90, paused: false }), big = makeVideo({ width: 640, height: 360 });
  page = makePage([small, big], '/watch');
  page.run();
  page.window.__hammer.toggle();
  expect(small.paused === true && big.paused === true, 'with sound and playing: that one is paused');
  page.window.__hammer.toggle();
  expect(big.paused === false, 'none playing: the biggest plays');
}
// The home feed: a muted preview and one with sound both playing: the one with sound.
{
  const preview = makeVideo({ width: 640, height: 360, muted: true, paused: false });
  const loud = makeVideo({ width: 160, height: 90, paused: false });
  page = makePage([preview, loud], '/');
  page.run();
  page.window.__hammer.mini(true);
  expect('data-hammer-main' in loud.attrs, 'home feed: the playing video with sound');
}
// A video with no size yet (NaN) never wins over a real one.
{
  const blank = makeVideo({ width: NaN, height: NaN }), real = makeVideo({ width: 300, height: 200 });
  page = makePage([blank, real], '/watch');
  page.run();
  page.window.__hammer.mini(true);
  expect('data-hammer-main' in real.attrs, 'a video with NaN size is never chosen over a real one');
  page = makePage([real, blank], '/watch');
  page.run();
  page.window.__hammer.mini(true);
  expect('data-hammer-main' in real.attrs, '…in either order');
}
// Seeking with odd numbers, and a video that hasn't loaded.
{
  const v = makeVideo();
  page = makePage([v], '/watch');
  page.run();
  v.currentTime = 50;
  expect(page.window.__hammer.seek(NaN) === false && v.currentTime === 50, 'seek(NaN) leaves the time alone');
  expect(page.window.__hammer.seek(Infinity) === false && v.currentTime === 50, 'seek(Infinity) too');
  v.duration = 0;
  page.window.__hammer.seek(10);
  expect(v.currentTime === 60, 'no length known yet (0): seeks freely');
  v.currentTime = NaN;
  page.window.__hammer.seek(10);
  expect(v.currentTime === 10, 'no current time yet: seeks from the start');
}
// The time, for "Open in your browser": not during an ad, and not without a video.
{
  const v = makeVideo({ paused: false });
  page = makePage([v], '/watch');
  page.run();
  v.currentTime = 61.5;
  expect(page.window.__hammer.time() === 61.5, 'the time the video is at');
  page.ad = true;
  expect(page.window.__hammer.time() === null, 'during an ad: none (that time is the ad\'s)');
  page.ad = false;
  v.currentTime = NaN;
  expect(page.window.__hammer.time() === null, 'no time yet: none');
  page = makePage([], '/results');
  page.run();
  expect(page.window.__hammer.time() === null, 'no video: none');
  page = makePage([makeVideo({ muted: true, paused: false })], '/');
  page.run();
  expect(page.window.__hammer.time() === null, 'a muted feed preview: none');
}
// play() refused (the page's autoplay rules): no unhandled error.
{
  const v = makeVideo({ rejects: true });
  page = makePage([v], '/watch');
  page.run();
  let failed = false;
  const unhandled = () => { failed = true; };
  process.on('unhandledRejection', unhandled);
  try { page.window.__hammer.toggle(); } catch (e) { failed = true; }
  setTimeout(() => {
    process.removeListener('unhandledRejection', unhandled);
    expect(!failed, 'a refused play(): no error');
    finish();
  }, 20);
}
// No <head> yet: the style still goes in, no error.
{
  page = makePage([makeVideo()], '/watch');
  const into = [];
  page.document.head = null;
  page.document.documentElement.appendChild = (n) => into.push(n);
  let broke = false;
  try { page.run(); } catch (e) { broke = true; }
  expect(!broke && into.length === 1, 'no <head>: the style goes on <html>, no error');
}

function finish() {
  console.log(`${checks} checks, ${failures} failed`);
  process.exit(failures === 0 ? 0 : 1);
}
