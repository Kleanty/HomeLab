import { API, PANEL_HEADERS, api, applyState, bridge, buzz, D, evSeq, h, en, haptic, icon, toast, store, t, tp, tpv } from '../main.js';
import { W } from '../registry.js';

let cached = null, at = 0, epoch = 0, pending = null;
export function invalidateDeckState() {
  epoch++;
  cached = null;
  at = 0;
  pending = null;
}
export async function deckState(force = false) {
  if (!force && cached && performance.now() - at < 650) return cached;
  if (!force && pending) return pending;
  const stamp = epoch;
  const task = api('/controls/state', 'GET', 15000).then(data => {
    if (stamp === epoch) { cached = data; at = performance.now(); }
    return data;
  }).finally(() => { if (pending === task) pending = null; });
  pending = task;
  return task;
}
export async function deckCommand(kind, values = {}) {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) if (value != null) query.set(key, String(value));
  invalidateDeckState();
  const result = await api(`/controls/command/${encodeURIComponent(kind)}?${query}`, 'POST', 20000);
  if (!result.ok) throw new Error(result.error || tp('Control is unavailable'));
  invalidateDeckState();
  if (kind === 'action' || kind === 'sound-stop' || kind === 'media') {
    api('/state' + (evSeq != null ? '?ev=' + evSeq : '')).then(s => {
      if (s && (evSeq == null || s.evSeq == null || s.evSeq >= evSeq) && (!D.state?.ts || !s.ts || s.ts >= D.state.ts)) applyState(s);
    }).catch(() => {});
  }
  return result;
}
const fail = error => toast(error?.message || tp('The computer did not answer'), 'err');
const button = (label, click, name = label) => {
  const b = h('button', 'deck-button', label); b.type = 'button'; b.setAttribute('aria-label', name);
  b.onclick = async () => { haptic(); b.disabled = true; try { await click(); } catch (e) { fail(e); } finally { b.disabled = false; } };
  return b;
};
function reconcile(root, nodes) {
  nodes.forEach((node, index) => { if (root.children[index] !== node) root.insertBefore(node, root.children[index] || null); });
  [...root.children].filter(node => !nodes.includes(node)).forEach(node => node.remove());
}
function empty(root, text) { root.replaceChildren(h('div', 'deck-empty', text)); }





const groups = {
  'app-dock': ['app', 'shortcut'], hotkeys: ['keys'], 'macro-pad': ['macro'],
  'project-launcher': ['project', 'app'], snippets: ['snippet', 'text'], 'focus-profile': ['focus', 'macro'],
  'task-runner': ['task'], 'dev-servers': ['server'], 'script-pad': ['task', 'shortcut'],
  'osc-pad': ['osc'],
};
function actionsView(box, options, type) {
  const grid = h('div', 'deck-actions'); box.append(grid); let signature = '';
  return data => {
    const permitted = groups[type] || [];
    let items = [...(data.actions || []), ...(data.shortcuts || []).map(s => ({ ...s, id: 'shortcut:' + s.id }))]
      .filter(item => permitted.includes(item.kind));
    if (options.ids?.length) items = items.filter(item => options.ids.includes(item.id));
    const key = JSON.stringify(items); if (key === signature) return; signature = key;
    if (!items.length) { empty(grid, 'Assign controls in the computer’s Control Deck settings'); return; }
    grid.replaceChildren(...items.map(item => {
      const label = h('span', '', item.name), state = h('small', '', item.state || tp('Ready'));
      const b = button('', async () => { await deckCommand('action', { id: item.id }); signature = ''; });
      b.disabled = item.available === false;
      b.append(label, state);
      if (type === 'dev-servers') return h('div', 'deck-task', b, button('Stop', () => deckCommand('action', { id: item.id, op: 'stop' }), 'Stop ' + item.name));
      return b;
    }));
  };
}

export function registerDeckWidget(type, title, mode = type) {
  W[type] = {
    needs: ['tick'],
    create(box, { o }) {
      box.classList.add('control-deck'); box.append(h('div', 'w-title', o.title || en(title)));
      let render = null, alive = true, loading = false;
      if (mode === 'system') box.append(button('Lock', () => deckCommand('lock')), button('Display off', () => deckCommand('monitor-off')));
      else render = actionsView(box, o, type);
      return {
        async update() {
          if (loading || !alive || !render) return;
          loading = true;
          try { const data = await deckState(); if (alive) { render(data); box.classList.remove('deck-offline'); } }
          catch (_) { if (alive) box.classList.add('deck-offline'); }
          finally { loading = false; }
        },
        destroy() { alive = false; },
      };
    },
  };
}

for (const [type, title, mode] of [['system-keys', 'Lock and displays', 'system']]) registerDeckWidget(type, title, mode);
for (const type of Object.keys(groups)) registerDeckWidget(type, type.split('-').map(s => s[0].toUpperCase() + s.slice(1)).join(' '));

W.trackpad = {
  needs: [],
  create(box, { o }) {
    box.classList.add('control-deck');
    const controlEnabled = Boolean(o.control);
    const sensitivity = Number(o.sensitivity) || 1.0;
    const acceleration = o.acceleration !== false;
    const scrollSpeed = Number(o.scrollSpeed) || 1.0;
    const natural = Boolean(o.naturalScroll);
    const holdDuration = Math.max(100, Number(o.holdDuration) || 350);
    const scrollBar = o.scrollBar || 'right';
    const scrollBarWidth = Math.max(16, Number(o.scrollBarWidth) || 36);
    // A different feel for each thing the pad does: a tick for a click, two for a right click, a firmer press when a
    // drag starts, a longer one when a gesture fires, and a light tick for every notch of a scroll. "Haptic feedback"
    // sets how strong they are (or turns them off) and "Tick while scrolling" turns the scroll ticks on (off by default).
    // They go through the panel's buzz(), so night mode and the display's vibration switch silence them too. The gestures
    // vibrate only for a Mac: the agent ignores them on any other computer, where a vibration would suggest something happened.
    const strength = o.haptics === 'off' ? 0 : ({ light: 0.6, strong: 1.8 }[o.haptics] ?? 1);
    const scrollTicks = o.scrollHaptics === true;
    const patterns = { click: '0,14', rightClick: '0,14,70,14', drag: '0,30', swipe: '0,20,45,20', spread: '0,45', pinch: '0,45', scroll: '0,8' };
    const feel = (kind) => {
      if (!strength || (kind === 'scroll' && !scrollTicks) || !patterns[kind]) return;
      if ((kind === 'swipe' || kind === 'spread' || kind === 'pinch') && D.state?.os !== 'macos') return;
      // only the vibrations get weaker or stronger, not the pauses between them
      const pattern = patterns[kind].split(',').map((ms, i) => (i % 2 ? Math.max(4, Math.round(Number(ms) * strength)) : Number(ms))).join(',');
      buzz(pattern);
    };

    const surface = h('div', 'deck-trackpad-surface',
      h('div', 'deck-trackpad-icon', icon(controlEnabled ? 'mouse' : 'lock')),
      h('div', 'deck-trackpad-hint', !controlEnabled
        ? 'Enable mouse control in widget settings'
        : (scrollBar !== 'none'
          ? 'Drag to move · Tap to click · Hold to drag · Bar or 2 fingers to scroll'
          : 'Drag to move · Tap to click · Hold to drag · Two fingers to scroll'))
    );

    let scrollBarEl = null;
    if (controlEnabled && scrollBar !== 'none') {
      scrollBarEl = h('div', 'deck-trackpad-bar',
        h('div', 'deck-trackpad-bar-icon',
          h('span', null, '▲'),
          h('span', null, '▼')
        )
      );
      scrollBarEl.style.width = scrollBarWidth + 'px';
    }

    const pad = h('div', 'deck-trackpad' + (scrollBar === 'left' ? ' has-scroll-left' : ''), surface);
    pad.setAttribute('tabindex', '0');
    pad.setAttribute('role', 'region');
    pad.setAttribute('aria-label', o.title || 'Trackpad');
    if (scrollBarEl) pad.append(scrollBarEl);
    box.append(h('div', 'w-title', o.title || 'Trackpad'), pad);

    if (!controlEnabled) {
      pad.classList.add('is-disabled');
      return { update() {}, destroy() {} };
    }

    let ws = null, destroyed = false, reconnectTimer = null;
    function getWsUrl() {
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      if (location.host && !location.host.includes('androidplatform.net')) return `${proto}//${location.host}/api/trackpad`;
      return 'ws://127.0.0.1:8765/api/trackpad';
    }
    function connectWs() {
      if (destroyed || (bridge && typeof bridge.trackpad === 'function')) return;
      try {
        ws = new WebSocket(getWsUrl());
        ws.onclose = () => { if (!destroyed) reconnectTimer = setTimeout(connectWs, 2000); };
        ws.onerror = () => { try { ws.close(); } catch (_) {} };
      } catch (_) {
        if (!destroyed) reconnectTimer = setTimeout(connectWs, 2000);
      }
    }
    connectWs();

    function send(msg) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(msg));
      } else if (bridge && typeof bridge.trackpad === 'function') {
        bridge.trackpad(msg.type || '', msg.dx || 0, msg.dy || 0, msg.delta ?? msg.dy ?? 0);
      } else {
        fetch('/api/trackpad', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(msg),
          cache: 'no-store'
        }).catch(() => {});
      }
    }

    // Windows Precision Touchpad ballistics curve: 3.5x base gain with controlled +1.6x dynamic flick boost
    function getGain(v) {
      const vp = v * v;
      return 3.5 + (1.6 * vp) / (2.0 + vp);
    }

    let accDx = 0, accDy = 0, moveScheduled = false;
    function queueMove(dx, dy) {
      accDx += dx; accDy += dy;
      if (!moveScheduled) {
        moveScheduled = true;
        requestAnimationFrame(() => {
          moveScheduled = false;
          flushMove();
        });
      }
    }
    function flushMove() {
      if (destroyed) return;
      moveScheduled = false;
      const sendDx = Math.round(accDx), sendDy = Math.round(accDy);
      accDx -= sendDx; accDy -= sendDy;
      if (sendDx !== 0 || sendDy !== 0) send({ type: 'move', dx: sendDx, dy: sendDy });
    }

    let accScrollX = 0, accScrollY = 0, scrollScheduled = false;
    function queueScroll(dx, dy) {
      accScrollX += dx;
      accScrollY += dy;
      if (!scrollScheduled) {
        scrollScheduled = true;
        requestAnimationFrame(() => {
          scrollScheduled = false;
          flushScroll();
        });
      }
    }
    function flushScroll() {
      if (destroyed) return;
      scrollScheduled = false;
      const sx = Math.round(accScrollX);
      const sy = Math.round(accScrollY);
      accScrollX -= sx;
      accScrollY -= sy;
      if (sx !== 0 || sy !== 0) { send({ type: 'scroll', dx: sx, dy: sy, delta: sy }); scrollFeel(sx, sy); }
    }
    // a light tick for each notch of a wheel (120), at most one every 45 ms so a fast scroll hums instead of buzzing
    let scrollSince = 0, lastScrollTick = 0;
    function scrollFeel(dx, dy) {
      scrollSince += Math.abs(dx) + Math.abs(dy);
      const now = performance.now();
      if (scrollSince < 120 || now - lastScrollTick < 45) return;
      scrollSince %= 120;
      lastScrollTick = now;
      feel('scroll');
    }

    const activePointers = new Map();
    let maxActivePointers = 0, moved = false, tapFired = false;
    let isDragging = false, holdTimer = null;
    let scrollAxis = null, cumScrollX = 0, cumScrollY = 0;

    // Three or more fingers make a gesture, as on a Mac's trackpad: a swipe (3 or 4 fingers) or, with 4 or more, a spread
    // or pinch. The agent decides what it does from the Mac's own Trackpad settings and ignores it on other computers.
    let gestureBase = null, gestureFired = false, gestureCheckScheduled = false, gestureQuietTimer = null;
    const touches = () => [...activePointers.values()].filter((p) => !p.isBar);
    function gestureShape() {
      const ps = touches(), n = ps.length;
      let cx = 0, cy = 0, r = 0;
      for (const p of ps) { cx += p.lastX; cy += p.lastY; }
      cx /= n; cy /= n;
      for (const p of ps) r += Math.hypot(p.lastX - cx, p.lastY - cy);
      return { n, cx, cy, r: r / n };
    }
    // measure from here: with three or more fingers down, or no gesture to judge
    function rebase() {
      clearTimeout(gestureQuietTimer);
      const ps = touches();
      gestureBase = !gestureFired && ps.length >= 3 ? gestureShape() : null;
      for (const p of ps) { p.baseX = p.lastX; p.baseY = p.lastY; }
    }
    // 'out' when every finger that has moved went mostly away from the middle it started around, 'in' when mostly towards it
    function radialMotion(b) {
      let out = 0, inward = 0, other = 0;
      for (const p of touches()) {
        const dx = p.lastX - p.baseX, dy = p.lastY - p.baseY, d = Math.hypot(dx, dy);
        if (d <= 12) continue; // it rests
        const rx = p.baseX - b.cx, ry = p.baseY - b.cy, r = Math.hypot(rx, ry);
        if (r < 8) continue; // it started in the middle: there is no away or towards, so it neither helps nor hinders
        const along = (dx * rx + dy * ry) / (d * r);
        if (along >= 0.6) out++; else if (along <= -0.6) inward++; else other++;
      }
      return other === 0 && out > 0 && inward === 0 ? 'out' : other === 0 && inward > 0 && out === 0 ? 'in' : null;
    }
    // A swipe is judged as it goes, from how far the fingers' middle has moved. A spread or pinch is judged only when the fingers
    // have finished (one lifts, or they have been still for a moment): while they are moving, a frame can show some of them
    // moved and the others not yet, which is a partial sample that looks like one.
    function checkGesture(final = false) {
      const g = gestureShape(), b = gestureBase;
      if (g.n !== b.n) { rebase(); return; } // a finger landed or lifted: measure again from here
      const dx = g.cx - b.cx, dy = g.cy - b.cy, dist = Math.hypot(dx, dy);
      const ratio = b.r > 8 ? g.r / b.r : 1;
      // A spread or pinch is the fingers moving apart or together, so at least half of them must have moved: one finger that
      // has moved before the others (a frame, a pause, a finger lifting) is not one, and fingers that rest do not stop it.
      const together = touches().filter((p) => Math.hypot(p.lastX - p.baseX, p.lastY - p.baseY) > 12).length >= Math.ceil(g.n / 2);
      // and the way they moved: away from the middle for a spread, towards it for a pinch. One finger that moved along
      // (up, say, while the others have yet to follow) changed the spread of the fingers but did not open them.
      const way = radialMotion(b);
      let type = null;
      if (final && g.n >= 4 && together && way === 'out' && dist < 45 && ratio > 1.35) type = 'spread';
      else if (final && g.n >= 4 && together && way === 'in' && dist < 45 && ratio < 0.72) type = 'pinch';
      else if (dist > 60) type = 'swipe' + Math.min(g.n, 4) + (Math.abs(dx) > Math.abs(dy) ? (dx < 0 ? 'left' : 'right') : (dy < 0 ? 'up' : 'down'));
      if (!type) return;
      gestureFired = true;
      clearTimeout(gestureQuietTimer);
      moved = true;
      send({ type });
      feel(type.startsWith('swipe') ? 'swipe' : type);
    }

    pad.addEventListener('pointerdown', (e) => {
      e.stopPropagation(); e.preventDefault();
      try { pad.setPointerCapture(e.pointerId); } catch (_) {}
      const isBar = scrollBarEl && (e.target === scrollBarEl || scrollBarEl.contains(e.target));
      if (isBar) scrollBarEl.classList.add('is-scrolling');
      const now = performance.now();
      activePointers.set(e.pointerId, {
        startX: e.clientX, startY: e.clientY,
        lastX: e.clientX, lastY: e.clientY,
        downTime: now,
        lastMoveTime: now,
        history: [{ t: now, x: e.clientX, y: e.clientY }],
        isBar,
      });
      maxActivePointers = Math.max(maxActivePointers, activePointers.size);
      if (activePointers.size > 1) {
        if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
        if (isDragging) {
          isDragging = false;
          send({ type: 'mouseup' });
        }
        scrollAxis = null;
        cumScrollX = 0;
        cumScrollY = 0;
      }
      if (!isBar) rebase();
      if (!isBar && activePointers.size === 1) {
        moved = false;
        tapFired = false;
        holdTimer = setTimeout(() => {
          if (!moved && !tapFired && maxActivePointers === 1 && activePointers.size === 1 && !isDragging) {
            isDragging = true;
            flushMove();
            send({ type: 'mousedown' });
            feel('drag');
          }
        }, holdDuration);
      }
    });

    pad.addEventListener('pointermove', (e) => {
      e.stopPropagation(); e.preventDefault();
      const pt = activePointers.get(e.pointerId);
      if (!pt) return;
      const rawDx = e.clientX - pt.lastX, rawDy = e.clientY - pt.lastY;
      pt.lastX = e.clientX; pt.lastY = e.clientY;
      // after a gesture fires, the fingers still down do nothing until all of them lift (no scroll, no pointer)
      if (gestureFired) return;

      if (pt.isBar) {
        const factor = natural ? 1 : -1;
        queueScroll(0, rawDy * scrollSpeed * 10 * factor);
        return;
      }

      if (Math.hypot(e.clientX - pt.startX, e.clientY - pt.startY) > 6) {
        moved = true;
        if (!isDragging && holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
      }

      // a finger's pointermove comes one at a time, so look at the fingers together once per frame, not between two of them
      if (gestureBase && !gestureFired && !gestureCheckScheduled) {
        gestureCheckScheduled = true;
        requestAnimationFrame(() => {
          gestureCheckScheduled = false;
          if (!destroyed && gestureBase && !gestureFired) checkGesture();
        });
      }
      clearTimeout(gestureQuietTimer);
      if (gestureBase && !gestureFired) {
        gestureQuietTimer = setTimeout(() => { if (!destroyed && gestureBase && !gestureFired) checkGesture(true); }, 90);
      }

      if (activePointers.size === 1) {
        let gain = 1.0;
        if (acceleration) {
          const now = performance.now();
          const elapsed = now - pt.lastMoveTime;
          if (elapsed > 60) {
            const dt = Math.max(12, Math.min(35, elapsed));
            const dist = Math.hypot(rawDx, rawDy);
            gain = getGain(dist / dt);
            pt.history = [
              { t: now - dt, x: pt.lastX - rawDx, y: pt.lastY - rawDy },
              { t: now, x: e.clientX, y: e.clientY },
            ];
          } else {
            pt.history.push({ t: now, x: e.clientX, y: e.clientY });
            while (pt.history.length > 2 && (now - pt.history[0].t) > 45) {
              pt.history.shift();
            }
            const oldest = pt.history[0];
            const dt = now - oldest.t;
            if (dt > 0) {
              const dist = Math.hypot(e.clientX - oldest.x, e.clientY - oldest.y);
              gain = getGain(dist / dt);
            } else {
              gain = getGain(0);
            }
          }
          pt.lastMoveTime = now;
        }
        queueMove(rawDx * gain * sensitivity, rawDy * gain * sensitivity);
      } else if (activePointers.size === 2) {
        if (isDragging) {
          isDragging = false;
          send({ type: 'mouseup' });
        }
        const factorY = natural ? 1 : -1;
        const factorX = natural ? -1 : 1;
        // Two pointers concurrently fire pointermove; scale by 5 so total 2-finger sensitivity matches 1-finger scrollbar
        const scale = scrollSpeed * 5;
        const dxDelta = rawDx * scale * factorX;
        const dyDelta = rawDy * scale * factorY;

        cumScrollX += Math.abs(rawDx);
        cumScrollY += Math.abs(rawDy);

        if (!scrollAxis) {
          if (cumScrollX + cumScrollY > 3) {
            moved = true;
            if (cumScrollY >= cumScrollX * 1.25) scrollAxis = 'y';
            else if (cumScrollX >= cumScrollY * 1.25) scrollAxis = 'x';
            else scrollAxis = 'free';
          }
        } else if (scrollAxis === 'y') {
          if (Math.abs(rawDx) > Math.abs(rawDy) * 2.5 && Math.abs(rawDx) > 7) {
            scrollAxis = 'x';
            cumScrollX = Math.abs(rawDx);
            cumScrollY = 0;
          }
        } else if (scrollAxis === 'x') {
          if (Math.abs(rawDy) > Math.abs(rawDx) * 2.5 && Math.abs(rawDy) > 7) {
            scrollAxis = 'y';
            cumScrollY = Math.abs(rawDy);
            cumScrollX = 0;
          }
        }

        if (scrollAxis === 'y') {
          queueScroll(0, dyDelta);
        } else if (scrollAxis === 'x') {
          queueScroll(dxDelta, 0);
        } else {
          const sendX = Math.abs(rawDx) >= 1.5 ? dxDelta : 0;
          const sendY = Math.abs(rawDy) >= 1.5 ? dyDelta : 0;
          queueScroll(sendX, sendY);
        }
      }
    });

    const onPointerEnd = (e) => {
      e.stopPropagation(); e.preventDefault();
      try { pad.releasePointerCapture(e.pointerId); } catch (_) {}
      if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
      // a quick flick can lift in the frame of its last move: judge the fingers now, before the one that lifts is gone
      if (e.type === 'pointerup' && gestureBase && !gestureFired) checkGesture(true);
      const pt = activePointers.get(e.pointerId);
      if (pt?.isBar) {
        if (scrollBarEl) scrollBarEl.classList.remove('is-scrolling');
        flushScroll();
      } else if (isDragging) {
        flushMove();
        send({ type: 'mouseup' });
        isDragging = false;
        tapFired = true;
      } else if (!moved && !tapFired && e.type !== 'pointercancel') {
        const duration = pt ? performance.now() - pt.downTime : 9999;
        if (maxActivePointers === 1 && duration < 300) {
          flushMove();
          send({ type: 'click' });
          feel('click');
          tapFired = true;
        } else if (maxActivePointers === 2 && duration < 400) {
          flushMove();
          flushScroll();
          send({ type: 'rightClick' });
          feel('rightClick');
          tapFired = true;
        }
      }
      activePointers.delete(e.pointerId);
      rebase();
      if (activePointers.size < 2) {
        scrollAxis = null;
        cumScrollX = 0;
        cumScrollY = 0;
      }
      if (activePointers.size === 0) {
        maxActivePointers = 0; moved = false; tapFired = false;
        gestureFired = false; gestureBase = null; scrollSince = 0;
        if (scrollBarEl) scrollBarEl.classList.remove('is-scrolling');
        flushMove(); flushScroll();
      }
    };

    pad.addEventListener('pointerup', onPointerEnd);
    pad.addEventListener('pointercancel', onPointerEnd);
    pad.addEventListener('touchstart', (e) => { e.stopPropagation(); }, { passive: false });
    pad.addEventListener('touchmove', (e) => { e.stopPropagation(); e.preventDefault(); }, { passive: false });
    pad.addEventListener('touchend', (e) => { e.stopPropagation(); }, { passive: false });
    pad.addEventListener('contextmenu', (e) => { e.preventDefault(); e.stopPropagation(); });

    return {
      update() {},
      destroy() {
        destroyed = true;
        moveScheduled = false;
        scrollScheduled = false;
        accScrollX = 0;
        accScrollY = 0;
        scrollAxis = null;
        cumScrollX = 0;
        cumScrollY = 0;
        if (reconnectTimer) clearTimeout(reconnectTimer);
        if (holdTimer) clearTimeout(holdTimer);
        clearTimeout(gestureQuietTimer);
        if (isDragging) { send({ type: 'mouseup' }); isDragging = false; }
        if (ws) { try { ws.close(); } catch (_) {} ws = null; }
        activePointers.clear();
      }
    };
  }
};
