(() => {
  'use strict';

  const canvas = document.getElementById('screen');
  const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
  const connectingEl = document.getElementById('connecting');
  const connectingText = document.getElementById('connecting-text');
  const hudEl = document.getElementById('hud');
  const statusDot = document.getElementById('status-dot');
  const modeBadge = document.getElementById('mode-badge');
  const fpsBadge = document.getElementById('fps-badge');
  const btnUpgrade = document.getElementById('btn-upgrade');
  const btnTouch = document.getElementById('btn-touch');
  const btnFit = document.getElementById('btn-fit');
  const btnFullscreen = document.getElementById('btn-fullscreen');
  const btnHide = document.getElementById('btn-hide');
  const upgradeModal = document.getElementById('upgrade-modal');
  const openHttpsLink = document.getElementById('open-https-link');
  const btnCloseModal = document.getElementById('btn-close-modal');

  const FRAME_H264_CONFIG = 0x01;
  const FRAME_H264_KEY = 0x02;
  const FRAME_H264_DELTA = 0x03;
  const FRAME_JPEG = 0x04;
  const FRAME_HEVC_CONFIG = 0x05;
  const FRAME_HEVC_KEY = 0x06;
  const FRAME_HEVC_DELTA = 0x07;

  const canUseWebCodecs = Boolean(window.isSecureContext && typeof VideoDecoder === 'function');
  let streamMode = canUseWebCodecs ? 'h264' : 'jpeg';

  let ws = null;
  let decoder = null;
  let decoderConfigured = false;
  let awaitingKeyframe = true;
  let touchEnabled = true;
  let hudTimer = null;
  let frameCounter = 0;
  let lastFpsTick = performance.now();
  let jpegDecoding = false;
  let wakeLock = null;
  let serverInfo = { httpPort: 8080, httpsPort: 8443, httpsAvailable: true };

  // Fetch server info, negotiate HEVC (H.265) vs H.264, and start WebSocket
  async function bootstrap() {
    try {
      const r = await fetch('/api/info');
      const info = await r.json();
      serverInfo = info;
      if (!canUseWebCodecs && info.httpsAvailable) {
        btnUpgrade.classList.remove('hidden');
        openHttpsLink.href = `https://${window.location.hostname}:${info.httpsPort}/`;
      }
      if (canUseWebCodecs && info.preferredCodec === 'hevc' && typeof VideoDecoder.isConfigSupported === 'function') {
        try {
          const support = await VideoDecoder.isConfigSupported({
            codec: 'hvc1.1.6.L120.90',
            hardwareAcceleration: 'prefer-hardware'
          });
          if (support && support.supported) {
            streamMode = 'hevc';
          }
        } catch (_) {}
      }
    } catch (_) {}
    connect();
  }

  function showHUD(autoHide = true) {
    hudEl.classList.remove('hidden');
    clearTimeout(hudTimer);
    if (autoHide) {
      hudTimer = setTimeout(() => hudEl.classList.add('hidden'), 4500);
    }
  }

  function toggleHUD() {
    if (hudEl.classList.contains('hidden')) {
      showHUD(true);
    } else {
      hudEl.classList.add('hidden');
    }
  }

  async function requestWakeLock() {
    try {
      if ('wakeLock' in navigator && !wakeLock) {
        wakeLock = await navigator.wakeLock.request('screen');
        wakeLock.addEventListener('release', () => { wakeLock = null; });
      }
    } catch (_) {}
  }

  // MARK: - WebCodecs H.264 / HEVC Decoder

  function initDecoder(isHEVC, width, height, configBytes) {
    if (decoder) {
      try { decoder.close(); } catch (_) {}
      decoder = null;
    }

    canvas.width = width;
    canvas.height = height;

    let codec;
    if (isHEVC) {
      codec = 'hvc1.1.6.L120.90';
    } else {
      codec = 'avc1.4D002A';
      if (configBytes.length >= 4) {
        const hex = (n) => n.toString(16).padStart(2, '0').toUpperCase();
        codec = `avc1.${hex(configBytes[1])}${hex(configBytes[2])}${hex(configBytes[3])}`;
      }
    }

    decoder = new VideoDecoder({
      output: (frame) => {
        if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
          canvas.width = frame.displayWidth;
          canvas.height = frame.displayHeight;
        }
        ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
        frame.close();
        onFrameRendered();
      },
      error: (err) => {
        console.warn('VideoDecoder error:', err);
        decoderConfigured = false;
        awaitingKeyframe = true;
        sendJSON({ cmd: 'keyframe' });
      }
    });

    decoder.configure({
      codec,
      codedWidth: width,
      codedHeight: height,
      description: configBytes,
      hardwareAcceleration: 'prefer-hardware',
      optimizeForLatency: true
    });

    decoderConfigured = true;
    awaitingKeyframe = true;
  }

  function handleBinaryPacket(arrayBuffer) {
    const view = new DataView(arrayBuffer);
    if (view.byteLength < 9) return;

    const frameType = view.getUint8(0);
    // Read 64-bit microsecond timestamp (BigInt safe for Safari 14+)
    const timestampUs = Number(view.getBigUint64(1, false));
    const payload = new Uint8Array(arrayBuffer, 9);

    if ((frameType === FRAME_H264_CONFIG || frameType === FRAME_HEVC_CONFIG) && canUseWebCodecs) {
      if (payload.byteLength < 9) return;
      const pv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
      const width = pv.getUint32(0, false);
      const height = pv.getUint32(4, false);
      const configBytes = payload.subarray(8);
      initDecoder(frameType === FRAME_HEVC_CONFIG, width, height, configBytes);
      return;
    }

    const isVideoFrame = (
      frameType === FRAME_H264_KEY || frameType === FRAME_H264_DELTA ||
      frameType === FRAME_HEVC_KEY || frameType === FRAME_HEVC_DELTA
    );
    if (isVideoFrame && decoderConfigured && decoder) {
      const isKey = (frameType === FRAME_H264_KEY || frameType === FRAME_HEVC_KEY);
      if (awaitingKeyframe && !isKey) return;
      if (isKey) awaitingKeyframe = false;

      // Drop delta frames if decoder queue backs up
      if (!isKey && decoder.decodeQueueSize > 3) return;

      try {
        const chunk = new EncodedVideoChunk({
          type: isKey ? 'key' : 'delta',
          timestamp: timestampUs,
          data: payload
        });
        decoder.decode(chunk);
      } catch (err) {
        awaitingKeyframe = true;
        sendJSON({ cmd: 'keyframe' });
      }
      return;
    }

    if (frameType === FRAME_JPEG) {
      if (jpegDecoding) return;
      jpegDecoding = true;
      const blob = new Blob([payload], { type: 'image/jpeg' });
      createImageBitmap(blob)
        .then(bitmap => {
          if (canvas.width !== bitmap.width || canvas.height !== bitmap.height) {
            canvas.width = bitmap.width;
            canvas.height = bitmap.height;
          }
          ctx.drawImage(bitmap, 0, 0);
          bitmap.close();
          onFrameRendered();
        })
        .catch(() => {})
        .finally(() => { jpegDecoding = false; });
    }
  }

  function onFrameRendered() {
    connectingEl.classList.add('hidden');
    frameCounter++;
    const now = performance.now();
    if (now - lastFpsTick >= 1000) {
      const fps = Math.round((frameCounter * 1000) / (now - lastFpsTick));
      fpsBadge.textContent = `${fps} FPS`;
      frameCounter = 0;
      lastFpsTick = now;
    }
  }

  // MARK: - WebSocket Connection

  function connect() {
    const proto = window.location.protocol === 'https:' ? 'wss' : 'ws';
    const url = `${proto}://${window.location.host}/ws?mode=${streamMode}`;

    statusDot.className = 'dot offline';
    modeBadge.className = 'badge';
    modeBadge.textContent = 'Connecting…';

    ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';

    ws.onopen = () => {
      statusDot.className = 'dot online';
      if (streamMode === 'hevc') {
        modeBadge.className = 'badge h264';
        modeBadge.textContent = 'HEVC 60fps';
      } else if (streamMode === 'h264') {
        modeBadge.className = 'badge h264';
        modeBadge.textContent = 'H.264 60fps';
      } else {
        modeBadge.className = 'badge';
        modeBadge.textContent = 'HTTP Mode';
      }
      connectingText.textContent = 'Waiting for Mac display frame…';
      showHUD(true);
      requestWakeLock();
    };

    ws.onmessage = (evt) => {
      if (evt.data instanceof ArrayBuffer) {
        handleBinaryPacket(evt.data);
      }
    };

    ws.onclose = () => {
      statusDot.className = 'dot offline';
      modeBadge.className = 'badge';
      modeBadge.textContent = 'Reconnecting…';
      connectingEl.classList.remove('hidden');
      connectingText.textContent = 'Reconnecting to Mac…';
      setTimeout(connect, 1200);
    };

    ws.onerror = () => {
      try { ws.close(); } catch (_) {}
    };
  }

  function sendJSON(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(obj));
    }
  }

  // MARK: - Touch & Apple Pencil Mapping

  function canvasNormalizedCoords(clientX, clientY) {
    const rect = canvas.getBoundingClientRect();
    const cw = canvas.width || rect.width;
    const ch = canvas.height || rect.height;
    const isFill = canvas.classList.contains('fill');

    const scale = isFill
      ? Math.max(rect.width / cw, rect.height / ch)
      : Math.min(rect.width / cw, rect.height / ch);

    const drawnW = cw * scale;
    const drawnH = ch * scale;
    const offsetX = rect.left + (rect.width - drawnW) / 2;
    const offsetY = rect.top + (rect.height - drawnH) / 2;

    const x = Math.min(1, Math.max(0, (clientX - offsetX) / drawnW));
    const y = Math.min(1, Math.max(0, (clientY - offsetY) / drawnH));
    return { x, y };
  }

  let activeTouches = new Map();
  let isDragging = false;
  let longPressTimer = null;
  let twoFingerLastMid = null;
  let twoFingerMoved = false;

  canvas.addEventListener('touchstart', (e) => {
    e.preventDefault();
    requestWakeLock();

    // 3-finger tap toggles HUD
    if (e.touches.length === 3) {
      clearTimeout(longPressTimer);
      toggleHUD();
      return;
    }

    if (!touchEnabled) return;

    if (e.touches.length === 1) {
      const t = e.touches[0];
      const pt = canvasNormalizedCoords(t.clientX, t.clientY);
      activeTouches.set(t.identifier, { x: t.clientX, y: t.clientY });
      isDragging = true;
      sendJSON({ action: 'down', x: pt.x, y: pt.y });

      clearTimeout(longPressTimer);
      longPressTimer = setTimeout(() => {
        if (activeTouches.size === 1) {
          sendJSON({ action: 'up', x: pt.x, y: pt.y });
          sendJSON({ action: 'rightClick', x: pt.x, y: pt.y });
          isDragging = false;
        }
      }, 520);
    } else if (e.touches.length === 2) {
      clearTimeout(longPressTimer);
      if (isDragging) {
        const t0 = e.touches[0];
        const pt = canvasNormalizedCoords(t0.clientX, t0.clientY);
        sendJSON({ action: 'up', x: pt.x, y: pt.y });
        isDragging = false;
      }
      const midX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
      const midY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
      twoFingerLastMid = { x: midX, y: midY };
      twoFingerMoved = false;
    }
  }, { passive: false });

  canvas.addEventListener('touchmove', (e) => {
    e.preventDefault();
    if (!touchEnabled) return;

    if (e.touches.length === 1 && isDragging) {
      const t = e.touches[0];
      const prev = activeTouches.get(t.identifier);
      if (prev && Math.hypot(t.clientX - prev.x, t.clientY - prev.y) > 8) {
        clearTimeout(longPressTimer);
      }
      const pt = canvasNormalizedCoords(t.clientX, t.clientY);
      sendJSON({ action: 'drag', x: pt.x, y: pt.y });
    } else if (e.touches.length === 2 && twoFingerLastMid) {
      const midX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
      const midY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
      const dx = (midX - twoFingerLastMid.x) * 2.2;
      const dy = (midY - twoFingerLastMid.y) * 2.2;
      if (Math.hypot(dx, dy) > 2) {
        twoFingerMoved = true;
        const pt = canvasNormalizedCoords(midX, midY);
        sendJSON({ action: 'scroll', x: pt.x, y: pt.y, dx, dy });
        twoFingerLastMid = { x: midX, y: midY };
      }
    }
  }, { passive: false });

  canvas.addEventListener('touchend', (e) => {
    e.preventDefault();
    clearTimeout(longPressTimer);

    if (twoFingerLastMid && e.touches.length === 0) {
      if (!twoFingerMoved && touchEnabled) {
        const pt = canvasNormalizedCoords(twoFingerLastMid.x, twoFingerLastMid.y);
        sendJSON({ action: 'rightClick', x: pt.x, y: pt.y });
      }
      twoFingerLastMid = null;
      twoFingerMoved = false;
    }

    for (const t of e.changedTouches) {
      activeTouches.delete(t.identifier);
      if (isDragging && e.touches.length === 0 && touchEnabled) {
        const pt = canvasNormalizedCoords(t.clientX, t.clientY);
        sendJSON({ action: 'up', x: pt.x, y: pt.y });
        isDragging = false;
      }
    }
  }, { passive: false });

  // MARK: - HUD Buttons

  btnTouch.addEventListener('click', () => {
    touchEnabled = !touchEnabled;
    btnTouch.textContent = touchEnabled ? 'Touch: ON' : 'Touch: OFF';
    btnTouch.classList.toggle('active', touchEnabled);
    showHUD(true);
  });

  btnFit.addEventListener('click', () => {
    canvas.classList.toggle('fill');
    btnFit.textContent = canvas.classList.contains('fill') ? 'Fill' : 'Fit';
    showHUD(true);
  });

  btnFullscreen.addEventListener('click', () => {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen?.().catch(() => {});
    } else {
      document.exitFullscreen?.().catch(() => {});
    }
    showHUD(true);
  });

  btnHide.addEventListener('click', () => {
    hudEl.classList.add('hidden');
  });

  btnUpgrade.addEventListener('click', () => {
    upgradeModal.classList.remove('hidden');
  });

  btnCloseModal.addEventListener('click', () => {
    upgradeModal.classList.add('hidden');
  });

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && (streamMode === 'h264' || streamMode === 'hevc')) {
      awaitingKeyframe = true;
      sendJSON({ cmd: 'keyframe' });
      requestWakeLock();
    }
  });

  bootstrap();
})();
