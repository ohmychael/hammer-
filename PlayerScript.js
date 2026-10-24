// PlayerScript.js: runs inside the YouTube page in Hammer's player
// (PlayerMac.swift adds it to every page). It only finds the video and plays,
// pauses or seeks it; it changes nothing else on YouTube. In the mini player it
// shows just the video, filling the window. Tested in Tests/Player/script_test.js.
(() => {
  if (window.__hammer) return;

  const post = (message) => {
    try { window.webkit.messageHandlers.hammer.postMessage(message); } catch (e) {}
  };

  // A video page: the player's video can be there before it has loaded anything.
  const onVideoPage = () => /^\/(watch|shorts\/|live\/|embed\/)/.test(location.pathname || '');

  // The video being watched. On a video page: YouTube's own player (it marks it
  // .html5-main-video), else one with sound, else the biggest; a small muted
  // preview playing beside it never wins. Elsewhere (the home feed holds small
  // muted previews): the one playing, with sound first, else the biggest.
  const mainVideo = () => {
    const videos = Array.from(document.querySelectorAll('video'));
    if (videos.length === 0) return null;
    const area = (v) => { const r = v.getBoundingClientRect(); const a = r.width * r.height; return a > 0 ? a : 0; };
    const biggest = (pool) => pool.reduce((best, v) => (area(v) > area(best) ? v : best));
    const first = (...pools) => biggest(pools.find((pool) => pool.length > 0) || videos);
    const playing = (v) => !v.paused && !v.ended;
    if (onVideoPage()) {
      const own = videos.filter((v) => !!(v.classList && v.classList.contains('html5-main-video')));
      const loud = videos.filter((v) => !v.muted);
      return first(own.filter(playing), own, loud.filter(playing), loud);
    }
    const live = videos.filter(playing);
    return first(live.filter((v) => !v.muted), live);
  };
  // Muted previews in the feed don't count; a video with sound does, on any page.
  const counts = (v) => !!v && (onVideoPage() || !v.muted);
  // YouTube marks its player while an ad plays. Hammer never skips or seeks ads.
  const adShowing = () => !!document.querySelector('.ad-showing, .ad-interrupting');

  // Tells Hammer what's going on, when it changes.
  let last = '';
  const report = () => {
    const v = mainVideo();
    const real = counts(v);
    const state = {
      playing: real && !v.paused && !v.ended,
      hasVideo: real && (onVideoPage() || v.duration > 0 || v.readyState > 0),
      ad: real && adShowing(),
      title: document.title || '',
    };
    const key = JSON.stringify(state);
    if (key === last) return;
    last = key;
    post(state);
  };
  // Media events don't bubble, but listeners on the way down (capture) see them.
  for (const type of ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'loadstart']) {
    document.addEventListener(type, report, true);
  }
  // YouTube changes pages and titles without reloading: look again now and then.
  setInterval(report, 1500);

  // Mini player: hide everything but the video, and make it fill the window.
  // Effects that would trap a fixed-position video inside its box are turned off.
  // Otherwise (the dropdown): the page's own background is cleared, so Hammer's
  // glass shows through. On YouTube's mobile site only <html> paints it.
  const style = document.createElement('style');
  style.textContent = `
    html:not(.hammer-mini), html:not(.hammer-mini) body { background: transparent !important;
      background-color: transparent !important; }
    html.hammer-mini, html.hammer-mini body { background: #000 !important; overflow: hidden !important; }
    html.hammer-mini body * { visibility: hidden !important; transform: none !important; filter: none !important;
      contain: none !important; perspective: none !important; backdrop-filter: none !important;
      will-change: auto !important; container-type: normal !important; content-visibility: visible !important;
      opacity: 1 !important; clip-path: none !important; mask: none !important; -webkit-mask: none !important; }
    html.hammer-mini video[data-hammer-main] { visibility: visible !important; position: fixed !important;
      inset: 0 !important; left: 0 !important; top: 0 !important; width: 100vw !important; height: 100vh !important;
      max-width: none !important; max-height: none !important; margin: 0 !important;
      object-fit: contain !important; background: #000 !important; z-index: 2147483647 !important;
      pointer-events: auto !important; clip-path: none !important; opacity: 1 !important; }
    html.hammer-mini [data-hammer-path] { display: block !important; }`;
  (document.head || document.documentElement).appendChild(style);

  window.__hammer = {
    // true: show only the video. Returns whether there was one.
    mini(on) {
      for (const v of document.querySelectorAll('video[data-hammer-main]')) v.removeAttribute('data-hammer-main');
      for (const e of document.querySelectorAll('[data-hammer-path]')) e.removeAttribute('data-hammer-path');
      const v = on ? mainVideo() : null;
      if (v) {
        v.setAttribute('data-hammer-main', '');
        // A box around the video that isn't displayed would leave it no size at all.
        for (let e = v.parentElement; e && e !== document.body && e !== document.documentElement; e = e.parentElement) {
          e.setAttribute('data-hammer-path', '');
        }
      }
      document.documentElement.classList.toggle('hammer-mini', !!v);
      return !!v;
    },
    toggle() {
      const v = mainVideo();
      if (!v) return false;
      if (v.paused || v.ended) { const p = v.play(); if (p && p.catch) p.catch(() => {}); } else { v.pause(); }
      return true;
    },
    pause() { const v = mainVideo(); if (v) v.pause(); },
    // Not during an ad: the mini player hides YouTube's own ad controls, so it mustn't skip one.
    seek(seconds) {
      const v = mainVideo();
      if (!v || adShowing() || !Number.isFinite(seconds)) return false;
      const end = v.duration > 0 ? v.duration : Infinity;
      const now = Number.isFinite(v.currentTime) ? v.currentTime : 0;
      v.currentTime = Math.min(end, Math.max(0, now + seconds));
      return true;
    },
    // Where the video is, in seconds (for "Open in your browser"); null during an ad or without one.
    time() {
      const v = mainVideo();
      return v && counts(v) && !adShowing() && Number.isFinite(v.currentTime) ? v.currentTime : null;
    },
    hasVideo() { return !!mainVideo(); },
    report,
  };
  report();
})();
