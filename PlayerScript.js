// PlayerScript.js: runs inside the YouTube page in Hammer's player
// (PlayerMac.swift adds it to every page). It only finds the video and plays,
// pauses or seeks it; it changes nothing else on YouTube. In the mini player it
// shows just the video, filling the window. Tested in Tests/Player/script_test.js.
(() => {
  if (window.__hammer) return;

  const post = (message) => {
    try { window.webkit.messageHandlers.hammer.postMessage(message); } catch (e) {}
  };

  // The video being watched: the one playing, else the biggest on the page
  // (the home feed can hold small muted previews).
  const mainVideo = () => {
    const videos = Array.from(document.querySelectorAll('video'));
    if (videos.length === 0) return null;
    const area = (v) => { const r = v.getBoundingClientRect(); return r.width * r.height; };
    const playing = videos.filter((v) => !v.paused && !v.ended);
    const pool = playing.length > 0 ? playing : videos;
    return pool.reduce((best, v) => (area(v) > area(best) ? v : best));
  };

  const report = () => {
    const v = mainVideo();
    post({
      playing: !!v && !v.paused && !v.ended,
      hasVideo: !!v && (v.duration > 0 || v.readyState > 0),
      title: document.title || '',
    });
  };
  // Media events don't bubble, but listeners on the way down (capture) see them.
  for (const type of ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata']) {
    document.addEventListener(type, report, true);
  }

  // Mini player: hide everything but the video, and make it fill the window.
  // Effects that would trap a fixed-position video inside its box are turned off.
  const style = document.createElement('style');
  style.textContent = `
    html.hammer-mini, html.hammer-mini body { background: #000 !important; overflow: hidden !important; }
    html.hammer-mini body * { visibility: hidden !important; transform: none !important; filter: none !important;
      contain: none !important; perspective: none !important; backdrop-filter: none !important; }
    html.hammer-mini video[data-hammer-main] { visibility: visible !important; position: fixed !important;
      inset: 0 !important; left: 0 !important; top: 0 !important; width: 100vw !important; height: 100vh !important;
      max-width: none !important; max-height: none !important; margin: 0 !important;
      object-fit: contain !important; background: #000 !important; z-index: 2147483647 !important; }`;
  (document.head || document.documentElement).appendChild(style);

  window.__hammer = {
    // true: show only the video. Returns whether there was one.
    mini(on) {
      for (const v of document.querySelectorAll('video[data-hammer-main]')) v.removeAttribute('data-hammer-main');
      const v = on ? mainVideo() : null;
      if (v) v.setAttribute('data-hammer-main', '');
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
    seek(seconds) {
      const v = mainVideo();
      if (!v) return;
      const end = v.duration > 0 ? v.duration : Infinity;
      v.currentTime = Math.min(end, Math.max(0, v.currentTime + seconds));
    },
    hasVideo() { return !!mainVideo(); },
    report,
  };
  report();
})();
