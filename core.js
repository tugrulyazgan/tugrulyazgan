// Lyrisland Web — pure logic shared by the page and the tests.
// Works both in the browser (window.Core) and in Node (module.exports).
(function (Core) {
  'use strict';

  // ---------- LRC parsing ----------

  /** "[mm:ss.xx] text" → [{time, text}] sorted by time, empty lines dropped. */
  Core.parseLRC = function (raw) {
    const lines = [];
    const re = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
    for (const rawLine of String(raw || '').split(/\r?\n/)) {
      const stamps = [];
      let m;
      let lastEnd = 0;
      re.lastIndex = 0;
      while ((m = re.exec(rawLine)) !== null) {
        if (m.index !== lastEnd) break; // stamps must be at the start
        const frac = m[3] ? Number(m[3]) / Math.pow(10, m[3].length) : 0;
        stamps.push(Number(m[1]) * 60 + Number(m[2]) + frac);
        lastEnd = re.lastIndex;
      }
      if (!stamps.length) continue;
      const text = rawLine.slice(lastEnd).trim();
      if (!text) continue;
      for (const time of stamps) lines.push({ time, text });
    }
    lines.sort((a, b) => a.time - b.time);
    return lines;
  };

  // ---------- Track matching ----------

  Core.normalize = function (s) {
    return String(s || '')
      .toLowerCase()
      .normalize('NFKD').replace(/[̀-ͯ]/g, '')
      .replace(/ß/g, 'ss')
      .replace(/[([].*?[)\]]/g, ' ')
      .replace(/\s-\s.*$/, ' ')
      .replace(/\b(feat|ft)\.?\s.*$/, ' ')
      .replace(/[^\p{L}\p{N}]+/gu, ' ')
      .trim();
  };

  function bigrams(s) {
    const out = new Map();
    const t = s.replace(/\s+/g, ' ');
    for (let i = 0; i < t.length - 1; i++) {
      const g = t.slice(i, i + 2);
      out.set(g, (out.get(g) || 0) + 1);
    }
    return out;
  }

  /** Dice similarity of normalized strings, 0…1. */
  Core.similarity = function (a, b) {
    const x = Core.normalize(a);
    const y = Core.normalize(b);
    if (!x || !y) return 0;
    if (x === y) return 1;
    if (x.length < 2 || y.length < 2) return 0;
    const bx = bigrams(x);
    const by = bigrams(y);
    let inter = 0;
    let total = 0;
    for (const [g, n] of bx) { total += n; if (by.has(g)) inter += Math.min(n, by.get(g)); }
    for (const n of by.values()) total += n;
    return (2 * inter) / total;
  };

  /** "Song - Remastered 2011 (feat. X)" → "Song". */
  Core.cleanTitle = function (title) {
    return String(title || '')
      .replace(/\s[-–—]\s.*$/, '')
      .replace(/\s*[([](feat\.?|ft\.?|with|featuring|remaster|live|radio edit)[^)\]]*[)\]]/gi, '')
      .trim();
  };

  /** "A, B & C" → "A". */
  Core.primaryArtist = function (artist) {
    return String(artist || '').split(/,\s|\s&\s|\sfeat\.?\s|\sft\.?\s|\sx\s|\sund\s/i)[0].trim();
  };

  /** How well a lyrics result fits the playing track, 0…1. */
  Core.matchScore = function (track, cand) {
    const title = Math.max(
      Core.similarity(track.title, cand.title),
      Core.similarity(Core.cleanTitle(track.title), cand.title)
    );
    const artist = Math.max(
      Core.similarity(track.artist, cand.artist),
      Core.similarity(Core.primaryArtist(track.artist), Core.primaryArtist(cand.artist))
    );
    let duration = 0.5; // unknown
    if (cand.duration && track.duration) {
      const d = Math.abs(cand.duration - track.duration);
      duration = d <= 2 ? 1 : d <= 5 ? 0.7 : d <= 10 ? 0.3 : 0;
    }
    return title * 0.45 + artist * 0.35 + duration * 0.2;
  };

  // ---------- Plain lyrics with estimated timing ----------

  function isSectionHeader(line) {
    return (/^\[.*\]$/.test(line)) ||
      (/^\(.*\)$/.test(line) && line.length < 30 &&
        /chorus|verse|refrain|bridge|intro|outro|hook|strophe/i.test(line));
  }

  /** Spread plain lines over the song: weight by length, pause at stanza breaks. */
  Core.estimateLines = function (plain, durationSec) {
    const items = [];
    for (const raw of String(plain || '').split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || isSectionHeader(line)) {
        if (items.length && !items[items.length - 1].brk) items.push({ brk: true });
      } else {
        items.push({ text: line });
      }
    }
    while (items.length && items[items.length - 1].brk) items.pop();
    const count = items.filter((i) => !i.brk).length;
    if (!count) return [];
    const duration = durationSec > 0 ? durationSec : count * 3.5;
    const start = Math.min(12, duration * 0.08);
    const end = Math.max(start + 1, duration - Math.min(8, duration * 0.05));
    const weights = items.map((i) => (i.brk ? 6 : 6 + i.text.length));
    const total = weights.reduce((a, b) => a + b, 0);
    const lines = [];
    let elapsed = 0;
    items.forEach((item, k) => {
      if (!item.brk) lines.push({ time: start + ((end - start) * elapsed) / total, text: item.text });
      elapsed += weights[k];
    });
    return lines;
  };

  // ---------- Playback sync ----------

  /** Index of the active line (last line whose time <= position + offset), or -1. */
  Core.lineIndex = function (lines, position) {
    let lo = 0;
    let hi = lines.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (lines[mid].time <= position) lo = mid + 1; else hi = mid;
    }
    return lo - 1;
  };

  /** Singing time of a line: ~9 chars/s plus lead-in, never past the next line. */
  Core.singingDuration = function (chars, gap) {
    const byLength = Math.max(1.2, chars * 0.11 + 0.6);
    return Math.max(0.3, Math.min(gap * 0.95, byLength));
  };

  /** Fraction (0…1) of line i sung at the (offset-adjusted) position. */
  Core.progress = function (lines, i, position) {
    if (i < 0 || i >= lines.length) return 0;
    const elapsed = position - lines[i].time;
    if (elapsed <= 0) return 0;
    const gap = i + 1 < lines.length ? lines[i + 1].time - lines[i].time : 6;
    return Math.min(1, elapsed / Core.singingDuration(lines[i].text.length, gap));
  };

  Core.SOFT_THRESHOLD = 0.3;
  Core.SOFT_FACTOR = 0.35;

  /** Next clock anchor: snap on seeks/pauses/first sample, blend small jitter. */
  Core.nextAnchor = function (prev, wasPlaying, position, playing, at) {
    if (!prev || !wasPlaying || !playing) return { at, position };
    const predicted = prev.position + (at - prev.at) / 1000;
    const drift = position - predicted;
    if (Math.abs(drift) >= Core.SOFT_THRESHOLD) return { at, position };
    return { at, position: predicted + drift * Core.SOFT_FACTOR };
  };

  /** Offset change that makes the line starting at lineTime active right now. */
  Core.offsetDelta = function (lineTime, position, currentOffset) {
    return lineTime - (position + currentOffset) + 0.05;
  };

  // ---------- Translation helpers ----------

  Core.uniqueLines = function (texts) {
    const seen = new Set();
    const out = [];
    for (const t of texts) {
      const s = String(t).trim();
      if (!/\p{L}/u.test(s) || seen.has(s)) continue;
      seen.add(s);
      out.push(s);
    }
    return out;
  };

  Core.batches = function (lines, maxChars) {
    const out = [];
    let cur = [];
    let len = 0;
    for (const l of lines) {
      if (cur.length && len + l.length + 1 > maxChars) { out.push(cur); cur = []; len = 0; }
      cur.push(l);
      len += l.length + 1;
    }
    if (cur.length) out.push(cur);
    return out;
  };

  /** Google gtx response → {text, source}. */
  Core.parseGtx = function (json) {
    if (!Array.isArray(json) || !Array.isArray(json[0])) return null;
    const text = json[0].map((seg) => (Array.isArray(seg) && typeof seg[0] === 'string' ? seg[0] : '')).join('');
    if (!text) return null;
    return { text, source: typeof json[2] === 'string' ? json[2] : null };
  };

  Core.sameLanguage = function (a, b) {
    if (!a || !b) return false;
    return a.split('-')[0].toLowerCase() === b.split('-')[0].toLowerCase();
  };

  /** Pair originals with translations, skipping identical ones. */
  Core.pairUp = function (originals, translated) {
    const map = {};
    originals.forEach((o, i) => {
      const t = String(translated[i] || '').trim();
      if (t && t.toLowerCase() !== o.toLowerCase()) map[o] = t;
    });
    return map;
  };

  /** Small stable string hash for cache keys. */
  Core.hash = function (s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
    return (h >>> 0).toString(36);
  };
})(typeof module !== 'undefined' && module.exports ? module.exports : (window.Core = {}));
