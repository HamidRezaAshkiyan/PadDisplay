(() => {
  'use strict';

  const canvas = document.getElementById('screen');
  const connectingEl = document.getElementById('connecting');
  const connectingText = document.getElementById('connecting-text');
  const hudEl = document.getElementById('hud');
  const statusDot = document.getElementById('status-dot');
  const modeBadge = document.getElementById('mode-badge');
  const fpsBadge = document.getElementById('fps-badge');
  const telemetryBadge = document.getElementById('telemetry-badge');
  const btnUpgrade = document.getElementById('btn-upgrade');
  const btnTouch = document.getElementById('btn-touch');
  const btnFit = document.getElementById('btn-fit');
  const btnFullscreen = document.getElementById('btn-fullscreen');
  const btnHide = document.getElementById('btn-hide');
  const upgradeModal = document.getElementById('upgrade-modal');
  const openHttpsLink = document.getElementById('open-https-link');
  const btnCloseModal = document.getElementById('btn-close-modal');
  const authModal = document.getElementById('auth-modal');
  const pinInput = document.getElementById('pin-input');
  const btnPinSubmit = document.getElementById('btn-pin-submit');
  const btnRequestApproval = document.getElementById('btn-request-approval');
  const authStatus = document.getElementById('auth-status');

  // MARK: - Zero-Copy WebGL2 Renderer (with 2D Canvas fallback)

  let gl = null;
  let glTexture = null;
  let ctx2d = null;
  let cachedCanvasRect = null;

  function invalidateCanvasRect() {
    cachedCanvasRect = null;
  }

  function initRenderer() {
    const glOpts = {
      alpha: false,
      antialias: false,
      depth: false,
      stencil: false,
      desynchronized: true,
      powerPreference: 'high-performance',
      preserveDrawingBuffer: false
    };
    const context = canvas.getContext('webgl2', glOpts) || canvas.getContext('webgl', glOpts);
    if (!context) {
      ctx2d = canvas.getContext('2d', { alpha: false, desynchronized: true });
      return;
    }

    const vsSrc = `
      attribute vec2 aPos;
      varying vec2 vTex;
      void main() {
        gl_Position = vec4(aPos, 0.0, 1.0);
        vTex = vec2(aPos.x * 0.5 + 0.5, 0.5 - aPos.y * 0.5);
      }
    `;
    const fsSrc = `
      precision mediump float;
      varying vec2 vTex;
      uniform sampler2D uTex;
      void main() {
        gl_FragColor = texture2D(uTex, vTex);
      }
    `;

    const compile = (type, src) => {
      const sh = context.createShader(type);
      context.shaderSource(sh, src);
      context.compileShader(sh);
      return context.getShaderParameter(sh, context.COMPILE_STATUS) ? sh : null;
    };

    const vs = compile(context.VERTEX_SHADER, vsSrc);
    const fs = compile(context.FRAGMENT_SHADER, fsSrc);
    if (!vs || !fs) {
      ctx2d = canvas.getContext('2d', { alpha: false, desynchronized: true });
      return;
    }

    const prog = context.createProgram();
    context.attachShader(prog, vs);
    context.attachShader(prog, fs);
    context.linkProgram(prog);
    if (!context.getProgramParameter(prog, context.LINK_STATUS)) {
      ctx2d = canvas.getContext('2d', { alpha: false, desynchronized: true });
      return;
    }

    context.useProgram(prog);
    const buf = context.createBuffer();
    context.bindBuffer(context.ARRAY_BUFFER, buf);
    context.bufferData(context.ARRAY_BUFFER, new Float32Array([
      -1, -1, 1, -1, -1, 1,
      -1,  1, 1, -1,  1, 1
    ]), context.STATIC_DRAW);

    const aPos = context.getAttribLocation(prog, 'aPos');
    context.enableVertexAttribArray(aPos);
    context.vertexAttribPointer(aPos, 2, context.FLOAT, false, 0, 0);

    glTexture = context.createTexture();
    context.bindTexture(context.TEXTURE_2D, glTexture);
    context.texParameteri(context.TEXTURE_2D, context.TEXTURE_WRAP_S, context.CLAMP_TO_EDGE);
    context.texParameteri(context.TEXTURE_2D, context.TEXTURE_WRAP_T, context.CLAMP_TO_EDGE);
    context.texParameteri(context.TEXTURE_2D, context.TEXTURE_MIN_FILTER, context.LINEAR);
    context.texParameteri(context.TEXTURE_2D, context.TEXTURE_MAG_FILTER, context.LINEAR);

    gl = context;
    canvas.addEventListener('webglcontextlost', (e) => {
      e.preventDefault();
      gl = null;
      glTexture = null;
    });
    canvas.addEventListener('webglcontextrestored', () => {
      initRenderer();
    });
  }

  function renderFrameToCanvas(source, width, height) {
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
      invalidateCanvasRect();
    }
    if (gl && glTexture) {
      gl.viewport(0, 0, width, height);
      gl.bindTexture(gl.TEXTURE_2D, glTexture);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    } else if (ctx2d) {
      ctx2d.drawImage(source, 0, 0, width, height);
    }
  }

  initRenderer();

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
  let pendingJpegPayload = null;
  let decodeStartTimes = new Map();
  let smoothedDecodeMs = 0;
  let lastKeyframeRequestMs = 0;
  let wakeLock = null;
  let pingInterval = null;
  let lastRttMs = 0;
  let serverInfo = { httpPort: 8080, httpsPort: 8443, httpsAvailable: true };

  function requestKeyframeThrottled() {
    const now = performance.now();
    if (now - lastKeyframeRequestMs < 250) return;
    lastKeyframeRequestMs = now;
    sendJSON({ cmd: 'keyframe' });
  }

  function recordDecodeLatency(ms) {
    if (ms >= 0 && ms < 500) {
      smoothedDecodeMs = smoothedDecodeMs === 0 ? ms : (smoothedDecodeMs * 0.8 + ms * 0.2);
    }
  }

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
        renderFrameToCanvas(frame, frame.displayWidth, frame.displayHeight);
        const startMs = decodeStartTimes.get(frame.timestamp);
        if (startMs !== undefined) {
          decodeStartTimes.delete(frame.timestamp);
          recordDecodeLatency(performance.now() - startMs);
        }
        frame.close();
        onFrameRendered();
      },
      error: (err) => {
        console.warn('VideoDecoder error:', err);
        decoderConfigured = false;
        awaitingKeyframe = true;
        decodeStartTimes.clear();
        requestKeyframeThrottled();
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

      // Drop delta frames if decoder queue backs up, and resync on next keyframe to avoid broken P-frame chains
      if (!isKey && decoder.decodeQueueSize > 1) {
        awaitingKeyframe = true;
        requestKeyframeThrottled();
        return;
      }

      try {
        if (decodeStartTimes.size > 16) decodeStartTimes.clear();
        decodeStartTimes.set(timestampUs, performance.now());
        const chunk = new EncodedVideoChunk({
          type: isKey ? 'key' : 'delta',
          timestamp: timestampUs,
          data: payload
        });
        decoder.decode(chunk);
      } catch (err) {
        awaitingKeyframe = true;
        decodeStartTimes.clear();
        requestKeyframeThrottled();
      }
      return;
    }

    if (frameType === FRAME_JPEG) {
      if (jpegDecoding) {
        // Hold only the freshest JPEG frame so we never decode stale frames
        pendingJpegPayload = payload;
        return;
      }
      decodeJpegPayload(payload);
    }
  }

  function decodeJpegPayload(payload) {
    jpegDecoding = true;
    const decodeStart = performance.now();
    const blob = new Blob([payload], { type: 'image/jpeg' });
    createImageBitmap(blob)
      .then((bitmap) => {
        renderFrameToCanvas(bitmap, bitmap.width, bitmap.height);
        bitmap.close();
        recordDecodeLatency(performance.now() - decodeStart);
        onFrameRendered();
      })
      .catch(() => {})
      .finally(() => {
        jpegDecoding = false;
        if (pendingJpegPayload) {
          const next = pendingJpegPayload;
          pendingJpegPayload = null;
          decodeJpegPayload(next);
        }
      });
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
      sendDisplayMetrics();
      clearInterval(pingInterval);
      pingInterval = setInterval(() => {
        sendJSON({ cmd: 'ping', t: performance.now(), rttMs: lastRttMs });
      }, 1500);
    };

    ws.onmessage = (evt) => {
      if (evt.data instanceof ArrayBuffer) {
        handleBinaryPacket(evt.data);
      } else if (typeof evt.data === 'string') {
        try {
          const msg = JSON.parse(evt.data);
          if (msg.cmd === 'pong' && typeof msg.t === 'number') {
            lastRttMs = Math.max(0, performance.now() - msg.t);
            const oneWay = Math.round(lastRttMs / 2);
            const encMs = Math.round(Number(msg.encodeMs || 0));
            const decMs = Math.round(smoothedDecodeMs);
            const mbps = Number(msg.bitrateMbps || 0).toFixed(1);
            const dropped = Number(msg.dropped || 0);
            telemetryBadge.textContent = `${encMs}+${oneWay}+${decMs} ms • ${mbps} Mbps • ${dropped} drop`;
          } else if (msg.cmd === 'authRequired') {
            const cachedPin = sessionStorage.getItem('paddisplay_pin');
            if (cachedPin && cachedPin.length === 4) {
              sendJSON({ cmd: 'auth', pin: cachedPin });
            } else {
              authStatus.textContent = '';
              authModal.classList.remove('hidden');
              setTimeout(() => pinInput.focus(), 100);
            }
          } else if (msg.cmd === 'authOK') {
            authModal.classList.add('hidden');
            authStatus.textContent = '';
            sendDisplayMetrics();
          } else if (msg.cmd === 'authFailed') {
            sessionStorage.removeItem('paddisplay_pin');
            authModal.classList.remove('hidden');
            authStatus.textContent = msg.reason || 'Incorrect PIN. Please try again.';
            pinInput.value = '';
            pinInput.focus();
          } else if (msg.cmd === 'authDenied') {
            authModal.classList.remove('hidden');
            authStatus.textContent = 'Connection request was denied on your Mac.';
          }
        } catch (_) {}
      }
    };

    ws.onclose = () => {
      clearInterval(pingInterval);
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

  let metricsDebounceTimer = null;
  function sendDisplayMetrics() {
    const w = Math.round(window.innerWidth || window.screen.width);
    const h = Math.round(window.innerHeight || window.screen.height);
    const dpr = Number(window.devicePixelRatio || 2);
    if (w > 0 && h > 0) {
      sendJSON({ cmd: 'displayMetrics', width: w, height: h, dpr });
    }
  }

  function scheduleDisplayMetrics() {
    clearTimeout(metricsDebounceTimer);
    metricsDebounceTimer = setTimeout(sendDisplayMetrics, 250);
  }

  window.addEventListener('resize', () => {
    invalidateCanvasRect();
    scheduleDisplayMetrics();
  });
  window.addEventListener('orientationchange', () => {
    invalidateCanvasRect();
    scheduleDisplayMetrics();
  });
  document.addEventListener('fullscreenchange', invalidateCanvasRect);

  // MARK: - Touch & Apple Pencil Mapping

  function canvasNormalizedCoords(clientX, clientY) {
    if (!cachedCanvasRect) {
      cachedCanvasRect = canvas.getBoundingClientRect();
    }
    const rect = cachedCanvasRect;
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
    invalidateCanvasRect();
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

  function submitPIN() {
    const pin = (pinInput.value || '').trim();
    if (pin.length !== 4) {
      authStatus.textContent = 'Please enter all 4 digits.';
      return;
    }
    sessionStorage.setItem('paddisplay_pin', pin);
    authStatus.textContent = 'Verifying…';
    sendJSON({ cmd: 'auth', pin });
  }

  btnPinSubmit.addEventListener('click', submitPIN);
  pinInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') submitPIN();
  });
  pinInput.addEventListener('input', () => {
    if ((pinInput.value || '').trim().length === 4) {
      submitPIN();
    }
  });
  btnRequestApproval.addEventListener('click', () => {
    authStatus.textContent = 'Waiting for approval in your Mac menu bar…';
    sendJSON({ cmd: 'requestApproval' });
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
