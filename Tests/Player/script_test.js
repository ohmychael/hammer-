// Tests PlayerScript.js in node with a stand-in page: which video it picks,
// playing, pausing, seeking, the mini-player switch, and what it reports.
// Run: node Tests/Player/script_test.js
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', '..', 'PlayerScript.js'), 'utf8');
let failures = 0, checks = 0;
const expect = (ok, what) => { checks++; if (!ok) { failures++; console.log('FAIL: ' + what); } };

function makeVideo({ paused = true, width = 100, height = 56, duration = 100, readyState = 4 } = {}) {
  return {
    paused, ended: false, currentTime: 0, duration, readyState, attrs: {}, plays: 0,
    getBoundingClientRect() { return { width, height }; },
    setAttribute(k, v) { this.attrs[k] = v; },
    removeAttribute(k) { delete this.attrs[k]; },
    play() { this.paused = false; this.plays++; return Promise.resolve(); },
    pause() { this.paused = true; },
  };
}

function makePage(videos) {
  const posted = [], listeners = {}, appended = [];
  const classes = new Set();
  const document = {
    title: 'Song - YouTube',
    head: { appendChild(n) { appended.push(n); } },
    documentElement: { classList: { toggle(c, on) { if (on) classes.add(c); else classes.delete(c); } } },
    createElement(tag) { return { tag }; },
    addEventListener(type, fn, capture) { (listeners[type] = listeners[type] || []).push({ fn, capture }); },
    querySelectorAll(selector) {
      if (selector === 'video') return page.videos;
      if (selector === 'video[data-hammer-main]') return page.videos.filter((v) => 'data-hammer-main' in v.attrs);
      throw new Error('unexpected selector ' + selector);
    },
  };
  const window = { webkit: { messageHandlers: { hammer: { postMessage(m) { posted.push(m); } } } } };
  const page = { videos, posted, listeners, appended, classes, document, window };
  page.run = () => vm.runInNewContext(source, { window, document, Array, Math, Infinity });
  page.fire = (type) => (listeners[type] || []).forEach((l) => l.fn());
  return page;
}

// Loading twice (YouTube changes pages without reloading) sets up once.
let main = makeVideo({ width: 420, height: 236 });
let page = makePage([makeVideo({ width: 160, height: 90 }), main]);
page.run();
page.run();
expect(page.listeners.play.length === 1 && page.appended.length === 1, 'set up once');
expect(page.listeners.play[0].capture === true, 'listens on the way down (media events do not bubble)');
expect(page.posted.length === 1 && page.posted[0].playing === false && page.posted[0].hasVideo === true
       && page.posted[0].title === 'Song - YouTube', 'reports when it starts: ' + JSON.stringify(page.posted[0]));

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

// No video on the page (search results, home): nothing breaks.
page = makePage([]);
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

console.log(`${checks} checks, ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
