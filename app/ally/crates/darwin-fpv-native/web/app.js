const CAMERA_RELOAD_MS = 240000; // ~4 min: recycle the MJPEG decoder (GPU/mem leak)
const CAMERA_SNAPSHOT_REFRESH_MS = 180; // local frame proxy refresh; robot reads are rate-limited server-side
const CAMERA_FRAME_TIMEOUT_MS = 900;
const CAMERA_RETRY_BASE_MS = 3000; // first auto-retry delay after an error
const CAMERA_RETRY_MAX_MS = 30000; // backoff cap
const STATE_FETCH_TIMEOUT_MS = 900;
const ACTION_FETCH_TIMEOUT_MS = 1200;
const SERVICE_FETCH_TIMEOUT_MS = 6500;
const CAMERA_AUTOSTART_INTERVAL_MS = 6000;
const DASH_STYLE_KEY = "darwinDashStyle";
const CONTROL_MODE_KEY = "darwinControlMode";
const UI_THEME_KEY = "darwinUiTheme";
const SERVICE_WORKER_URL = "/sw.js";
const CAMERA_FRAME_PROXY_URL = "/api/camera-frame.jpg";

const state = {
  last: null,
  dashStyle: readStorage(DASH_STYLE_KEY, "tactical"),
  controlMode: readStorage(CONTROL_MODE_KEY, "model"),
  uiTheme: readStorage(UI_THEME_KEY, "light"),
  staleAfterMs: 900,
  refreshPromise: null,
  lastLogsKey: "",
  camera: {
    src: "",          // bare stream URL (no cache-bust) — detects URL changes
    loaded: false,
    error: false,
    pending: false,
    errorCount: 0,
    reloadCounter: 0, // bumped on every (re)load; appended as &_r=<n>
    lastReloadMs: 0,  // Date.now() of last successful-stream periodic reload
    retryAtMs: 0,     // Date.now() of next allowed retry while in error state
    backoffMs: 0      // current retry delay (grows 3s→6s→12s→cap 30s)
  },
  gamepad: {
    buttons: []
  },
  services: {
    cameraTunnelBusy: false,
    lastCameraTunnelAtMs: 0,
    cameraTunnelStatus: "터널 대기"
  }
};

const $ = (id) => document.getElementById(id);

function readStorage(key, fallback) {
  try {
    const value = window.localStorage && window.localStorage.getItem(key);
    return value || fallback;
  } catch (_err) {
    return fallback;
  }
}

function writeStorage(key, value) {
  try {
    if (window.localStorage) window.localStorage.setItem(key, value);
  } catch (_err) {
    // localStorage can be unavailable in locked-down embedded browsers.
  }
}

function setClass(el, value) {
  if (el.className === value) return;
  el.className = value;
}

function setText(id, value) {
  const el = $(id);
  if (!el) return;
  if (el.textContent === String(value)) return;
  el.textContent = value;
}

function setStateClass(id, base, level) {
  const el = $(id);
  el.className = `${base} ${level || ""}`.trim();
}

function setMeter(id, value, max) {
  const meter = $(id);
  if (!meter) return;
  const bar = meter.querySelector("i");
  if (!bar) return;
  const pct = Math.min(50, Math.abs(value) / Math.max(max, 0.001) * 50);
  const className = value < 0 ? "negative" : "";
  if (bar.className !== className) bar.className = className;
  if (value < 0) {
    bar.style.right = "50%";
    bar.style.left = "auto";
  } else {
    bar.style.left = "50%";
    bar.style.right = "auto";
  }
  const width = `${pct}%`;
  if (bar.style.width !== width) bar.style.width = width;
}

function setDot(id, x, y) {
  const dot = $(id);
  const px = 50 + clamp(x, -1, 1) * 34;
  const py = 50 - clamp(y, -1, 1) * 34;
  const left = `calc(${px}% - 9px)`;
  const top = `calc(${py}% - 9px)`;
  if (dot.style.left !== left) dot.style.left = left;
  if (dot.style.top !== top) dot.style.top = top;
}

async function fetchJson(url, options, timeoutMs) {
  const opts = {...(options || {})};
  let timer = 0;
  let controller = null;
  if (typeof AbortController !== "undefined") {
    controller = new AbortController();
    opts.signal = controller.signal;
    timer = window.setTimeout(() => controller.abort(), timeoutMs);
  }
  try {
    const response = await fetch(url, opts);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally {
    if (timer) window.clearTimeout(timer);
  }
}

async function action(name) {
  const button = document.querySelector(`[data-action="${name}"]`);
  if (button) button.classList.add("pressed");
  try {
    await fetchJson("/api/action", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({action: name})
    }, ACTION_FETCH_TIMEOUT_MS);
    await refresh();
  } catch (_err) {
    setText("mission-caption-text", "명령 전송 실패");
  } finally {
    if (button) window.setTimeout(() => button.classList.remove("pressed"), 120);
  }
}

async function serviceAction(service, serviceActionName, options = {}) {
  const quiet = Boolean(options.quiet);
  if (service === "camera_tunnel") {
    if (state.services.cameraTunnelBusy) return false;
    state.services.cameraTunnelBusy = true;
    state.services.lastCameraTunnelAtMs = Date.now();
    state.services.cameraTunnelStatus = serviceActionName === "restart" ? "카메라 재시작 중" : "카메라 연결 중";
    setText("camera-service-state", state.services.cameraTunnelStatus);
  }
  const button = document.querySelector(`[data-service="${service}"][data-service-action="${serviceActionName}"]`);
  if (button) button.classList.add("pressed");
  try {
    const result = await fetchJson("/api/service", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({service, action: serviceActionName})
    }, SERVICE_FETCH_TIMEOUT_MS);
    if (service === "camera_tunnel") {
      state.services.cameraTunnelStatus = result && result.ok ? "터널 실행 중" : "터널 확인 필요";
      setText("camera-service-state", state.services.cameraTunnelStatus);
      if (state.camera.src) {
        state.camera = {...state.camera, error: true, retryAtMs: 0, errorCount: (state.camera.errorCount || 0) + 1};
      }
    }
    if (!quiet) await refresh();
    return Boolean(result && result.ok);
  } catch (_err) {
    if (service === "camera_tunnel") {
      state.services.cameraTunnelStatus = "터널 시작 실패";
      setText("camera-service-state", state.services.cameraTunnelStatus);
    }
    if (!quiet) setText("mission-caption-text", "서비스 명령 실패");
    return false;
  } finally {
    if (service === "camera_tunnel") state.services.cameraTunnelBusy = false;
    if (button) window.setTimeout(() => button.classList.remove("pressed"), 160);
  }
}

async function shutdownSwitch() {
  const button = $("shutdown-button");
  const ok = window.confirm("다윈 FPV 콕핏을 종료할까요?");
  if (!ok) return;
  if (button) button.classList.add("pressed");
  setText("mission-caption-text", "조종석 종료 중…");
  try {
    await fetchJson("/api/system", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({action: "exit_app"})
    }, ACTION_FETCH_TIMEOUT_MS);
    setText("mission-caption-text", "콕핏을 종료합니다");
  } catch (_err) {
    setText("mission-caption-text", "조종석 종료 실패");
  } finally {
    if (button) window.setTimeout(() => button.classList.remove("pressed"), 220);
  }
}

function maybeAutoStartCameraTunnel() {
  if (state.controlMode !== "camera" || state.dashStyle === "drive") return;
  if (state.services.cameraTunnelBusy) return;
  const now = Date.now();
  if (now - state.services.lastCameraTunnelAtMs < CAMERA_AUTOSTART_INTERVAL_MS) return;
  serviceAction("camera_tunnel", "enable_now", {quiet: true});
}

function updateClock() {
  const now = new Date();
  setText("clock", now.toLocaleTimeString([], {hour12: false}));
}

async function refresh() {
  if (state.refreshPromise) return state.refreshPromise;
  state.refreshPromise = refreshOnce().finally(() => {
    state.refreshPromise = null;
  });
  return state.refreshPromise;
}

async function refreshOnce() {
  let data;
  try {
    data = await fetchJson("/api/state", {cache: "no-store"}, STATE_FETCH_TIMEOUT_MS);
  } catch (_err) {
    setText("link-text", "에이전트 꺼짐");
    setText("route-state", "연결 끊김");
    setClass($("link-pill"), "status-chip");
    setText("mission-kicker", "대기");
    setText("mission-title", "시동 중");
    setText("mission-caption-text", "로컬 에이전트를 기다리는 중");
    setClass($("stage-panel"), "stage-panel warn");
    setStateClass("link-state-panel", "readout-panel connection-panel", "bad");
    setText("link-state-text", "에이전트 꺼짐");
    setStateClass("robot-batt", "robot-batt", "unknown");
    setText("battery-pct", "--%");
    setText("battery-v", "-- V");
    setBattFill(null);
    renderSwitchBattery(null);
    setStateClass("robot-pose", "robot-flag", "warn");
    setText("robot-pose-val", "정보 없음");
    setStateClass("robot-link", "robot-flag", "warn");
    setText("robot-latency", "-- ms");
    setText("robot-walk-flag", "정지");
    renderRecovery({
      mode: "offline",
      target: "-",
      input_status: "확인 불가",
      camera: {}
    }, false, true, false, "camera-off");
    return;
  }
  state.last = data;
  render(data);
}

function render(data) {
  const command = data.command || {};
  const ctl = data.controller || {};
  const camera = data.camera || {};
  const connected = Boolean(data.connected);
  const age = Math.max(0, Date.now() - (data.updated_at_ms || 0));
  const sshControlLinked = Boolean(data.connected || data.ssh_connected);
  const staleLimit = data.mode === "ssh" && !sshControlLinked
    ? 3500
    : state.staleAfterMs;
  const stale = age > staleLimit;
  const moving = Boolean(data.moving);
  const sshMode = data.mode === "ssh";
  const linked = sshMode ? sshControlLinked : connected;
  const routeText = stale ? "신호 끊김" : (linked ? (sshMode ? "SSH 연결됨" : "연결됨") : (sshMode ? "연결 중" : "연결 끊김"));
  const mission = missionState(data, stale);
  const dashboardMode = state.dashStyle === "drive";
  const visualMode = dashboardMode ? "dashboard" : state.controlMode;
  const cameraLevel = renderCamera(camera, visualMode, data.camera_runtime || {});
  if (visualMode === "camera" && cameraLevel !== "camera-live") {
    maybeAutoStartCameraTunnel();
  }

  setClass($("link-pill"), linked && !stale ? "status-chip connected" : "status-chip");
  setText("link-text", routeText);
  setText("route-state", routeText);
  setText("mode", modeLabel(data.mode));
  setText("target-type", "연결");
  setText("target", data.target || "-");
  setText("ip", data.local_ip || "-");
  setText("diag-mode", modeLabel(data.mode));
  setText("runtime", formatRuntime(data.uptime_sec || 0));
  setText("input-status", data.input_status || "알 수 없음");
  setText("watchdog", data.watchdog_label || "—");
  setText("age", `${age} ms`);

  renderLink(data, linked, stale, sshMode);
  renderSwitchBattery(data.switch_battery || null);
  renderRobot(data, stale);
  renderRecovery(data, linked, stale, sshMode, cameraLevel);

  setText("mission-kicker", mission.kicker);
  setText("mission-title", mission.title);
  setText("mission-caption-text", mission.caption);
  setClass($("stage-panel"), `stage-panel ${mission.level} ${cameraLevel}`);
  renderModelMode(cameraLevel);
  // Never run WebGL and MJPEG together on the Switch. Model mode gets WebGL;
  // camera mode gets the SSH-tunneled MJPEG stream and HUD overlays. Dashboard
  // mode is data-only, so keep both visual pipelines asleep there.
  if (window.__darwinRobot3D) {
    if (dashboardMode && typeof window.__darwinRobot3D.dispose === "function") {
      window.__darwinRobot3D.dispose();
    } else {
      window.__darwinRobot3D.setActive(state.controlMode === "model" && !dashboardMode);
    }
  }

  setText("armed", data.armed ? "준비됨" : "잠김");
  // 좌측 레일 '전송' 타일 — UDP 패스트레인 / SSH 폴백 / 미연결(Ally 는 데드맨 없음).
  setText("deadman", data.transport === "ssh_file" ? "SSH" : (data.transport === "udp" ? "UDP" : "—"));
  setText("estop", data.estopped ? "작동" : "정상");
  setStateClass("tile-arm", "safety-tile", data.armed ? "good" : "warn");
  setStateClass("tile-estop", "safety-tile", data.estopped ? "bad" : "good");
  setStateClass("trigger-deadman", "trigger-state", data.transport === "udp" ? "good" : (data.transport === "ssh_file" ? "warn" : "bad"));
  setStateClass("trigger-link", "trigger-state", linked && !stale ? "good" : (stale ? "bad" : "warn"));

  setText("stride-num", `${fixed(command.stride_mm)} mm`);
  setText("side-num", `${fixed(command.side_mm)} mm`);
  setText("turn-num", `${fixed(command.turn_deg)}°`);
  setText("pan-num", `${fixed(command.head_pan_deg)}°`);
  setText("tilt-num", `${fixed(command.head_tilt_deg)}°`);

  setMeter("stride-bar", Number(command.stride_mm || 0), 25);
  setMeter("side-bar", Number(command.side_mm || 0), 14);
  setMeter("turn-bar", Number(command.turn_deg || 0), 12);
  setMeter("pan-bar", Number(command.head_pan_deg || 0), 70);
  setMeter("tilt-bar", Number(command.head_tilt_deg || 0), 35);
  setDot("left-mini-dot", Number(ctl.left_x || 0), Number(ctl.left_y || 0));
  setDot("right-mini-dot", Number(ctl.right_x || 0), Number(ctl.right_y || 0));
  setMotionVector(Number(ctl.left_x || 0), Number(ctl.left_y || 0), moving);
  renderDriveDashboard(data, stale);
  renderPilotOverlay(data, stale);

  const logs = data.logs || [];
  setText("log-count", String(logs.length));
  const nextLogsKey = logs.slice(-5).join("\n");
  if (state.lastLogsKey !== nextLogsKey) {
    state.lastLogsKey = nextLogsKey;
    $("logs").innerHTML = logs.slice(-5).map((line) => `<div>${escapeHtml(line)}</div>`).join("");
  }
}

function setDashStyle(style) {
  const next = style === "drive" ? "drive" : "tactical";
  if (state.dashStyle === next && document.body.dataset.dashStyle === next) return;
  state.dashStyle = next;
  document.body.dataset.dashStyle = next;
  writeStorage(DASH_STYLE_KEY, next);
  for (const button of document.querySelectorAll("[data-dash-style]")) {
    const selected = button.dataset.dashStyle === next;
    button.classList.toggle("selected", selected);
    button.setAttribute("aria-pressed", selected ? "true" : "false");
  }
  if (state.last) render(state.last);
}

function setControlMode(mode) {
  const next = mode === "camera" ? "camera" : "model";
  state.controlMode = next;
  document.body.dataset.controlMode = next;
  writeStorage(CONTROL_MODE_KEY, next);
  for (const button of document.querySelectorAll("[data-control-mode]")) {
    const selected = button.dataset.controlMode === next;
    button.classList.toggle("selected", selected);
    button.setAttribute("aria-pressed", selected ? "true" : "false");
  }
  if (next === "camera") {
    serviceAction("camera_tunnel", "enable_now", {quiet: true});
  }
  if (state.last) render(state.last);
}

function setUiTheme(theme) {
  const next = theme === "dark" ? "dark" : "light";
  state.uiTheme = next;
  document.body.dataset.uiTheme = next;
  document.body.classList.remove("selected");
  document.body.removeAttribute("aria-pressed");
  writeStorage(UI_THEME_KEY, next);
  for (const button of document.querySelectorAll(".theme-switch [data-ui-theme]")) {
    const selected = button.dataset.uiTheme === next;
    button.classList.toggle("selected", selected);
    button.setAttribute("aria-pressed", selected ? "true" : "false");
  }
}

function renderDriveDashboard(data, stale) {
  const command = data.command || {};
  const stride = Number(command.stride_mm || 0);
  const side = Number(command.side_mm || 0);
  const turn = Number(command.turn_deg || 0);
  const pan = Number(command.head_pan_deg || 0);
  const tilt = Number(command.head_tilt_deg || 0);
  const motion = driveVector(stride, side, stale);
  const speedPct = motion.speedPct;
  const direction = motion.label;
  const directionState = stale
    ? "stale"
    : motion.state;
  const anglePct = clamp(turn / 12, -1, 1);
  const turnState = stale
    ? "stale"
    : (Math.abs(turn) < 0.2 ? "neutral" : (turn > 0 ? "right" : "left"));
  const sshMode = data.mode === "ssh";
  const connected = Boolean(data.connected);
  const linked = sshMode ? Boolean(data.connected || data.ssh_connected) : connected;
  const routeText = stale ? "신호 끊김" : (linked ? (sshMode ? "SSH 연결됨" : "연결됨") : (sshMode ? "연결 중" : "연결 끊김"));
  const linkLevel = linked && !stale ? "good" : (stale ? "bad" : "warn");
  const latency = numOrNull(data.link_latency_ms);
  const packetLoss = numOrNull(data.packet_loss_pct);
  const packetLossValue = packetLoss === null ? 0 : clamp(packetLoss, 0, 100);
  const packetLossLevel = stale ? "bad" : (packetLossValue >= 5 ? "bad" : (packetLossValue >= 1 ? "warn" : "good"));
  const signalDbm = numOrNull(data.signal_dbm ?? data.wifi_dbm);
  const signalText = linked && !stale ? "우수" : (stale ? "지연" : "대기");
  const signalLevel = linked && !stale ? "good" : (stale ? "bad" : "warn");

  setText("dash-speed", String(Math.round(speedPct)));
  setText("dash-drive-direction", direction);
  setText("dash-stride", `${fixed(stride)} / ${fixed(side)} mm`);
  setText("dash-angle", `${fixed(turn)}°`);
  setText("dash-head-pan", `${fixed(pan)}°`);
  setText("dash-head-tilt", `${fixed(tilt)}°`);
  setNeedle("dash-speed-needle", -126 + speedPct * 2.52);
  setNeedle("dash-angle-needle", anglePct * 78);

  setText("inst-speed", String(Math.round(speedPct)));
  setText("inst-speed-direction", direction);
  setText("inst-stride", `${fixed(stride)} / ${fixed(side)} mm`);
  setText("inst-turn", `${fixed(turn)}°`);
  setText("inst-pan", `${fixed(pan)}°`);
  setText("inst-tilt", `${fixed(tilt)}°`);
  setStateClass("inst-speed-card", "instrument-card instrument-speed-card", directionState);
  setStateClass("inst-turn-card", "instrument-card instrument-turn-card", turnState);
  setClass($("inst-speed-direction"), `direction-chip ${directionState}`);
  setNeedle("inst-speed-needle", -126 + speedPct * 2.52);
  setNeedle("inst-turn-needle", anglePct * 78);
  setAxisValue("inst-stride-axis", stride, 25);
  setAxisValue("inst-turn-axis", turn, 12);

  setText("inst-armed", data.armed ? "준비됨" : "잠김");
  setText("inst-estop", data.estopped ? "작동" : "정상");
  setText("inst-watchdog", data.watchdog_label || "—");
  setText("inst-age", `${Math.max(0, Date.now() - (data.updated_at_ms || 0))} ms`);
  setStateClass("inst-tile-arm", "instrument-state-tile", data.armed ? "good" : "warn");
  setStateClass("inst-tile-estop", "instrument-state-tile", data.estopped ? "bad" : "good");
  setStateClass("inst-tile-watchdog", "instrument-state-tile", stale ? "bad" : "good");
  setStateClass("inst-tile-age", "instrument-state-tile", stale ? "bad" : "good");

  const {realGyro, gyroX, gyroY, gyroZ, gyroMax, gyroLoad, pitch, roll} = dashboardTelemetry(data);

  setText("dash-gyro-x", formatSigned(gyroX, 0));
  setText("dash-gyro-y", formatSigned(gyroY, 0));
  setText("dash-gyro-z", formatSigned(gyroZ, 0));
  setText("dash-gyro-load", String(Math.round(gyroLoad)));
  setText("dash-pitch", `${formatSigned(pitch, 1)}°`);
  setText("dash-roll", `${formatSigned(roll, 1)}°`);
  setText("dash-imu-source", realGyro ? "로봇 IMU" : "입력 추정");
  setGyroBar("dash-gyro-x-bar", gyroX, gyroMax);
  setGyroBar("dash-gyro-y-bar", gyroY, gyroMax);
  setGyroBar("dash-gyro-z-bar", gyroZ, gyroMax);
  setHorizon(pitch, roll);

  setText("inst-gyro-x", formatSigned(gyroX, 0));
  setText("inst-gyro-y", formatSigned(gyroY, 0));
  setText("inst-gyro-z", formatSigned(gyroZ, 0));
  setText("inst-gyro-load", String(Math.round(gyroLoad)));
  setText("inst-pitch", `${formatSigned(pitch, 1)}°`);
  setText("inst-roll", `${formatSigned(roll, 1)}°`);
  setText("inst-imu-source", realGyro ? "로봇 IMU" : "입력 추정");
  const balance = balanceStatus(pitch, roll);
  const gyroLevel = gyroLoad >= 78 ? "bad" : (gyroLoad >= 48 ? "warn" : "good");
  setText("inst-balance-state", balance.text);
  setStateClass("inst-attitude-card", "instrument-card instrument-attitude-card", balance.level);
  setStateClass("inst-gyro-card", "instrument-card instrument-gyro-card", gyroLevel);
  setClass($("inst-balance-state"), `balance-pill ${balance.level}`);
  setGyroBar("inst-gyro-x-bar", gyroX, gyroMax);
  setGyroBar("inst-gyro-y-bar", gyroY, gyroMax);
  setGyroBar("inst-gyro-z-bar", gyroZ, gyroMax);
  setHorizonFor("inst-horizon", pitch, roll);

  setStateClass("inst-link-tile", "instrument-link-tile", linkLevel);
  setText("inst-link-state", routeText);
  setText("inst-link-detail", linked && !stale ? "Link OK" : (stale ? "Signal stale" : "Waiting"));
  setText("inst-mode", modeLabel(data.mode));
  setText("inst-ip", data.local_ip || "-");
  setText("inst-packet-loss", `${Math.round(packetLossValue)}%`);
  setText("inst-latency", latency === null ? "-- ms" : `${Math.round(latency)} ms`);
  setText("inst-uptime", formatRuntimeClock(data.uptime_sec || 0));
  setText("inst-signal", signalText);
  setText("inst-signal-detail", signalDbm === null ? (linked && !stale ? "Link OK" : (stale ? "stale" : "--")) : `${Math.round(signalDbm)} dBm`);
  const loss = $("inst-packet-loss");
  if (loss) loss.className = packetLossLevel;
  const signal = $("inst-signal");
  if (signal) signal.className = signalLevel;
}

function renderPilotOverlay(data, stale) {
  const command = data.command || {};
  const stride = Number(command.stride_mm || 0);
  const side = Number(command.side_mm || 0);
  const turn = Number(command.turn_deg || 0);
  const pan = Number(command.head_pan_deg || 0);
  const tilt = Number(command.head_tilt_deg || 0);
  const motion = driveVector(stride, side, stale);
  const speedPct = motion.speedPct;
  const direction = motion.label;
  const telemetry = dashboardTelemetry(data);

  setText("overlay-speed", String(Math.round(speedPct)));
  setText("overlay-direction", direction);
  setText("overlay-stride", `${fixed(stride)} / ${fixed(side)}`);
  setText("overlay-turn", `${fixed(turn)}°`);
  setText("overlay-head", `${fixed(pan)} / ${fixed(tilt)}`);
  setText("overlay-imu-source", telemetry.realGyro ? "로봇 IMU" : "입력 추정");
  setText("overlay-gyro-x", formatSigned(telemetry.gyroX, 0));
  setText("overlay-gyro-y", formatSigned(telemetry.gyroY, 0));
  setText("overlay-gyro-z", formatSigned(telemetry.gyroZ, 0));
  const latency = numOrNull(data.link_latency_ms);
  const switchBattery = data.switch_battery || {};
  const switchPct = numOrNull(switchBattery.percent);
  const linkText = data.mode === "ssh"
    ? ((data.connected || data.ssh_connected) ? "SSH LOCK" : "SSH WAIT")
    : (data.connected ? "LINK LOCK" : "LINK WAIT");
  setText("fpv-link", linkText);
  setText("fpv-latency", latency === null ? "-- ms" : `${Math.round(latency)} ms`);
  setText("fpv-battery", switchPct === null ? "SW --%" : `SW ${Math.round(switchPct)}%`);
  setText("fpv-stride", fixed(stride));
  setText("fpv-side", fixed(side));
  setText("fpv-turn", `${fixed(turn)}°`);
  setText("fpv-pan", `${fixed(pan)}°`);
  setText("fpv-tilt", `${fixed(tilt)}°`);
  setText("fpv-imu", telemetry.realGyro ? "ROBOT" : "EST");
  setFpvHorizon(telemetry.pitch, telemetry.roll);
}

function dashboardTelemetry(data) {
  const command = data.command || {};
  const ctl = data.controller || {};
  const imu = data.imu || {};
  const pan = Number(command.head_pan_deg || 0);
  const tilt = Number(command.head_tilt_deg || 0);
  const turn = Number(command.turn_deg || 0);
  const realGyro = imu.source === "robot" && numOrNull(imu.gyro_x) !== null;
  const gyroX = realGyro ? Number(imu.gyro_x) : Math.round(clamp(tilt / 35, -1, 1) * 120);
  const gyroY = realGyro ? Number(imu.gyro_y) : Math.round(clamp(pan / 70, -1, 1) * 120);
  const gyroZ = realGyro ? Number(imu.gyro_z) : Math.round(clamp(turn / 12, -1, 1) * 160);
  const gyroMax = realGyro ? 900 : 180;
  const gyroLoad = clamp(Math.hypot(gyroX, gyroY, gyroZ) / gyroMax * 100, 0, 100);
  const pitch = realGyro
    ? clamp((Number(imu.accel_x || 0) - 512) / 512 * 28, -28, 28)
    : clamp(Number(ctl.left_y || 0) * 18, -18, 18);
  const roll = realGyro
    ? clamp((Number(imu.accel_y || 0) - 512) / 512 * 28, -28, 28)
    : clamp(Number(ctl.left_x || 0) * 22, -22, 22);
  return {realGyro, gyroX, gyroY, gyroZ, gyroMax, gyroLoad, pitch, roll};
}

function driveVector(stride, side, stale) {
  if (stale) return {speedPct: 0, label: "신호 끊김", state: "stale"};
  const mag = Math.hypot(stride, side);
  const speedPct = clamp(Math.hypot(stride / 25, side / 14) * 100, 0, 100);
  if (mag < 0.2) return {speedPct, label: "정지", state: "idle"};
  const fb = Math.abs(stride) < 0.8 ? "" : (stride > 0 ? "전진" : "후진");
  const lr = Math.abs(side) < 0.8 ? "" : (side > 0 ? "우측" : "좌측");
  const label = fb && lr ? `${fb}·${lr}` : (fb || lr);
  const state = stride < -0.8 ? "backward" : "forward";
  return {speedPct, label, state};
}

function setNeedle(id, degrees) {
  const el = $(id);
  const transform = `rotate(${degrees.toFixed(1)}deg)`;
  if (el.style.transform !== transform) el.style.transform = transform;
}

function setGyroBar(id, value, max) {
  const el = $(id);
  const pct = Math.min(100, Math.abs(value) / Math.max(max, 1) * 100);
  const width = `${pct.toFixed(0)}%`;
  if (el.style.width !== width) el.style.width = width;
  const className = value < 0 ? "negative" : "";
  if (el.className !== className) el.className = className;
}

function setAxisValue(id, value, max) {
  const track = $(id);
  if (!track) return;
  const fill = track.querySelector("i");
  const dot = track.querySelector("b");
  const pct = clamp(value / Math.max(max, 0.001), -1, 1);
  const magnitude = `${(Math.abs(pct) * 50).toFixed(0)}%`;
  const dotLeft = `calc(${(50 + pct * 48).toFixed(1)}% - 5px)`;
  const className = pct < 0 ? "negative" : "";
  if (track.className !== `instrument-axis-track ${className}`.trim()) {
    track.className = `instrument-axis-track ${className}`.trim();
  }
  if (pct < 0) {
    fill.style.left = "auto";
    fill.style.right = "50%";
  } else {
    fill.style.left = "50%";
    fill.style.right = "auto";
  }
  if (fill.style.width !== magnitude) fill.style.width = magnitude;
  if (dot.style.left !== dotLeft) dot.style.left = dotLeft;
}

function setHorizon(pitch, roll) {
  setHorizonFor("dash-horizon", pitch, roll);
}

function setHorizonFor(id, pitch, roll) {
  const el = $(id);
  const transform = `translateY(${clamp(pitch, -28, 28).toFixed(1)}px) rotate(${clamp(roll, -32, 32).toFixed(1)}deg)`;
  if (el.style.transform !== transform) el.style.transform = transform;
}

function setFpvHorizon(pitch, roll) {
  const el = $("fpv-horizon");
  const transform = `translate(-50%, -50%) translateY(${clamp(pitch, -28, 28).toFixed(1)}px) rotate(${clamp(roll, -32, 32).toFixed(1)}deg)`;
  if (el.style.transform !== transform) el.style.transform = transform;
}

// Link / diagnostics readout. SSH modes report ssh_connected; other modes
// fall back to the generic relay "connected" flag so this never goes dark.
function renderLink(data, linked, stale, sshMode) {
  let level = "bad";
  let text = sshMode ? "SSH 연결 중" : "연결 끊김";
  if (linked && !stale) {
    level = "good";
    text = sshMode ? "SSH 연결됨" : "연결됨";
  } else if (linked && stale) {
    level = "warn";
    text = "신호 끊김";
  } else if (sshMode) {
    level = "warn";
    text = "SSH 연결 중";
  }
  setStateClass("link-state-panel", "readout-panel connection-panel", level);
  setText("link-state-text", `${text} · ${data.target || "대상 없음"}`);
}

function renderRecovery(data, linked, stale, sshMode, cameraLevel) {
  let level = "good";
  let stateText = "정상";
  let title = "운영 준비";
  let hint = "문제가 생기면 점검으로 로그를 남기거나 재연결을 누르세요.";
  const inputStatus = String(data.input_status || "입력장치 없음");
  const noInput = /없음|none|no controller/i.test(inputStatus);

  if (stale) {
    level = "bad";
    stateText = "신호 지연";
    title = "로컬 에이전트 응답 지연";
    hint = "서비스가 멈췄거나 브라우저가 오래 대기 중입니다. 설정을 확인하거나 에이전트를 재시작하세요.";
  } else if (data.mode === "offline") {
    level = "bad";
    stateText = "에이전트 꺼짐";
    title = "로컬 에이전트에 연결할 수 없음";
    hint = "systemd 서비스 상태를 확인한 뒤 조종석을 다시 여세요.";
  } else if (data.mode !== "dry_run" && !linked) {
    level = "warn";
    stateText = sshMode ? "SSH 대기" : "연결 대기";
    title = sshMode ? "SSH 연결을 기다리는 중" : "대상 연결을 기다리는 중";
    hint = recoveryHintForMode(data.mode, data.target || "-");
  } else if (noInput) {
    level = "warn";
    stateText = "입력 없음";
    title = "조이콘 입력장치가 아직 없음";
    hint = "joycond, 블루투스 페어링, /dev/input 권한을 확인하세요. 화면 버튼으로 안전 명령은 보낼 수 있습니다.";
  } else if (state.dashStyle !== "drive" && state.controlMode === "camera" && cameraLevel === "camera-error") {
    level = "warn";
    stateText = "카메라";
    title = "카메라 스트림 재연결 중";
    hint = "SSH 터널과 robot camera_tutorial 상태를 확인하세요. 필요하면 모델 모드로 전환하세요.";
  }

  setStateClass("recovery-panel", "readout-panel recovery-panel", level);
  setText("recovery-state", stateText);
  setText("recovery-title", title);
  setText("recovery-hint", hint);
}

function recoveryHintForMode(mode, target) {
  if (mode === "ssh") {
    return `${target} 전원, IP, SSH 키 파일을 확인한 뒤 재연결을 누르세요.`;
  }
  if (mode === "mac_relay") {
    return `${target}의 DarwinForge 실행, 같은 네트워크, 페어링 코드를 확인하세요.`;
  }
  if (mode === "robot_udp") {
    return `${target}의 로봇 UDP 수신기가 실행 중인지 확인하세요.`;
  }
  return "설정을 확인한 뒤 재연결을 누르세요.";
}

// Robot telemetry: battery, pose (UPRIGHT/FALLEN), walking, link latency.
function renderRobot(data, stale) {
  const pct = numOrNull(data.battery_pct);
  const volts = numOrNull(data.battery_v);
  const battLevel = batteryLevel(pct);
  setStateClass("robot-batt", "robot-batt", battLevel);
  setText("battery-pct", pct === null ? "--%" : `${Math.round(pct)}%`);
  setText("battery-v", volts === null ? "-- V" : `${volts.toFixed(1)} V`);
  setBattFill(pct);

  const pose = poseState(data, stale);
  setStateClass("robot-pose", "robot-flag", pose.level);
  setText("robot-pose-val", pose.text);

  const latency = numOrNull(data.link_latency_ms);
  setStateClass("robot-link", "robot-flag", latencyLevel(latency, stale));
  setText("robot-latency", latency === null ? "-- ms" : `${Math.round(latency)} ms`);

  const walking = Boolean(data.robot_walking) && !stale;
  setText("robot-walk-flag", walking ? "보행 중" : "정지");
  const flag = $("robot-walk-flag");
  const flagClass = walking ? "walking" : "";
  if (flag.className !== flagClass) flag.className = flagClass;
}

function setBattFill(pct) {
  const fill = $("batt-fill");
  const width = pct === null ? "0%" : `${clamp(pct, 0, 100)}%`;
  if (fill.style.width !== width) fill.style.width = width;
}

function renderSwitchBattery(power) {
  const pct = numOrNull(power && power.percent);
  const charging = Boolean(power && power.charging);
  const level = pct === null ? "unknown" : (charging ? "charging" : batteryLevel(pct));
  setStateClass("switch-batt-chip", "switch-batt-chip", level);
  setText("switch-battery-pct", pct === null ? "--%" : `${Math.round(pct)}%`);
  setText("switch-power-state", charging ? "충전" : "기기");
  const fill = $("switch-batt-fill");
  if (fill) {
    const width = pct === null ? "0%" : `${clamp(pct, 0, 100)}%`;
    if (fill.style.width !== width) fill.style.width = width;
  }
}

function batteryLevel(pct) {
  if (pct === null) return "unknown";
  if (pct <= 20) return "bad";
  if (pct <= 40) return "warn";
  return "good";
}

function poseState(data, stale) {
  if (stale) return {text: "정보 없음", level: "warn"};
  const fallen = Number(data.robot_fallen || 0);
  if (fallen > 0) return {text: "넘어짐 ↟", level: "bad"};
  if (fallen < 0) return {text: "넘어짐 ↡", level: "bad"};
  return {text: "정상", level: "good"};
}

function latencyLevel(latency, stale) {
  if (latency === null || stale) return "warn";
  if (latency > 600) return "bad";
  if (latency > 300) return "warn";
  return "good";
}

function numOrNull(value) {
  if (value === null || value === undefined || value === "") return null;
  const num = Number(value);
  return Number.isFinite(num) ? num : null;
}

// Append/replace a cache-busting &_r=<n> so the browser tears down the old
// MJPEG decoder and starts a fresh stream. Keeps any existing query string.
function bustedSrc(streamUrl, counter) {
  const base = streamUrl.split("#")[0];
  const sep = base.includes("?") ? "&" : "?";
  return `${base}${sep}_r=${counter}`;
}

// Build the next immutable camera state and (re)point the <img>. Used by both
// the initial load and every reload/retry so timing fields persist correctly.
function loadCameraStream(image, streamUrl, base) {
  const reloadCounter = base.reloadCounter + 1;
  const nextSrc = bustedSrc(streamUrl, reloadCounter);
  const keepVisibleFrame = Boolean(base.loaded);
  state.camera = {
    ...base,
    src: streamUrl,
    loaded: keepVisibleFrame,
    error: false,
    pending: true,
    errorCount: base.errorCount || 0,
    reloadCounter,
    lastReloadMs: Date.now()
  };

  if (typeof window !== "undefined" && typeof window.Image === "function") {
    const frame = new window.Image();
    frame.decoding = "async";
    frame.onload = () => commitCameraFrame(image, streamUrl, nextSrc, reloadCounter);
    frame.onerror = () => failCameraFrame(streamUrl, reloadCounter);
    frame.src = nextSrc;
    return;
  }

  image.src = nextSrc;
}

function commitCameraFrame(image, streamUrl, nextSrc, reloadCounter) {
  if (state.camera.src !== streamUrl || state.camera.reloadCounter !== reloadCounter) return;
  state.camera = {
    ...state.camera,
    loaded: true,
    error: false,
    pending: false,
    errorCount: 0,
    retryAtMs: 0,
    backoffMs: 0,
    lastReloadMs: Date.now()
  };
  image.src = nextSrc;
}

function failCameraFrame(streamUrl, reloadCounter) {
  if (state.camera.src !== streamUrl || state.camera.reloadCounter !== reloadCounter) return;
  const hadVisibleFrame = Boolean(state.camera.loaded);
  state.camera = {
    ...state.camera,
    loaded: hadVisibleFrame,
    error: !hadVisibleFrame,
    pending: false,
    errorCount: (state.camera.errorCount || 0) + 1,
    // If a visible frame exists, hold it briefly instead of flashing black.
    lastReloadMs: hadVisibleFrame ? Date.now() + 350 : state.camera.lastReloadMs
  };
}

function settleStalledCameraRequest() {
  if (!state.camera.pending) return;
  if (Date.now() - state.camera.lastReloadMs < CAMERA_FRAME_TIMEOUT_MS) return;
  const hadVisibleFrame = Boolean(state.camera.loaded);
  state.camera = {
    ...state.camera,
    loaded: hadVisibleFrame,
    error: !hadVisibleFrame,
    pending: false,
    errorCount: (state.camera.errorCount || 0) + 1,
    lastReloadMs: hadVisibleFrame ? Date.now() + 350 : state.camera.lastReloadMs
  };
}

function renderCamera(camera, controlMode, runtime = {}) {
  const enabled = Boolean(camera.enabled);
  const streamUrl = String(camera.stream_url || "");
  const snapshotUrl = String(camera.snapshot_url || "");
  // **2026-06-16 수정** — 실시간 우선: MJPEG 스트림(?action=stream, 멀티파트 연속)을 직접 쓴다.
  // 종전엔 snapshot_url 존재 시 무조건 /api/camera-frame.jpg(단일 JPEG ~5fps 폴링)로 폴백해
  // "영상이 실시간이 아님". loadCameraStream 이 MJPEG 를 처리하므로 stream_url 을 우선하고,
  // stream_url 이 없을 때만 스냅샷 프록시로 폴백한다. (Ally→로봇:8080 직결, 동일 HTTP 오리진 무관.)
  const displayUrl = streamUrl ? streamUrl : (snapshotUrl ? CAMERA_FRAME_PROXY_URL : "");
  const label = String(camera.label || "Robot Camera");
  const route = String(camera.route || "ssh-tunnel");
  const image = $("camera-stream");

  setText("camera-label", label);
  setText("camera-route", route);

  if (controlMode === "dashboard") {
    if (state.camera.src) image.removeAttribute("src");
    setCameraImageClass(image, "is-hidden");
    state.camera = {
      src: "", loaded: false, error: false, pending: false, errorCount: 0,
      reloadCounter: 0, lastReloadMs: 0, retryAtMs: 0, backoffMs: 0
    };
    setCameraFault(false);
    setCameraSignal("CAM OFF", false);
    setText("camera-mode", "계기판 데이터 모드");
    setText("camera-service-state", state.services.cameraTunnelStatus);
    return "dashboard-data";
  }

  if (controlMode !== "camera") {
    if (state.camera.src) image.removeAttribute("src");
    setCameraImageClass(image, "is-hidden");
    state.camera = {
      src: "", loaded: false, error: false, pending: false, errorCount: 0,
      reloadCounter: 0, lastReloadMs: 0, retryAtMs: 0, backoffMs: 0
    };
    setCameraFault(false);
    setCameraSignal("CAM OFF", false);
    setText("camera-mode", "모델 조종 모드");
    setText("camera-service-state", state.services.cameraTunnelStatus);
    return "camera-model";
  }

  if (!enabled || !displayUrl) {
    if (state.camera.src) image.removeAttribute("src");
    setCameraImageClass(image, "is-hidden");
    state.camera = {
      src: "", loaded: false, error: false, pending: false, errorCount: 0,
      reloadCounter: 0, lastReloadMs: 0, retryAtMs: 0, backoffMs: 0
    };
    setCameraFault(false);
    setCameraSignal("CAM OFF", false);
    setText("camera-mode", "카메라 꺼짐");
    setText("camera-service-state", "카메라 설정 꺼짐");
    return "camera-off";
  }

  if (state.camera.src !== displayUrl) {
    // New URL: reset backoff and start fresh.
    loadCameraStream(image, displayUrl, {reloadCounter: 0, retryAtMs: 0, backoffMs: 0, errorCount: 0});
  }

  const portClosed = runtime.local_port_open === false && runtime.status === "port_closed";
  if (portClosed && !state.services.cameraTunnelBusy) {
    state.camera = {...state.camera, loaded: false, error: true, errorCount: Math.max(2, state.camera.errorCount || 0)};
    return renderCameraRetry(image, displayUrl, runtime);
  }

  settleStalledCameraRequest();

  const portOpen = runtime.local_port_open === true && runtime.status === "port_open";
  if (portOpen && state.camera.error) {
    loadCameraStream(image, displayUrl, {
      reloadCounter: state.camera.reloadCounter || 0,
      loaded: state.camera.loaded,
      retryAtMs: 0,
      backoffMs: 0,
      errorCount: 0
    });
    setCameraImageClass(image, "is-hidden");
    setCameraFault(false);
    setText("camera-mode", "카메라 연결 중");
    setText("camera-service-state", cameraRuntimeText(runtime, "터널 포트 열림"));
    setCameraSignal("CAM WAIT", false);
    return "camera-wait";
  }

  if (state.camera.error) return renderCameraRetry(image, displayUrl, runtime);
  if (state.camera.loaded) return renderCameraLive(image, displayUrl);

  setCameraImageClass(image, "is-hidden");
  setCameraFault(false);
  setText("camera-mode", state.services.cameraTunnelBusy ? "카메라 터널 시작 중" : "카메라 연결 중");
  setText("camera-service-state", cameraRuntimeText(runtime, state.services.cameraTunnelStatus));
  setCameraSignal("CAM WAIT", false);
  return "camera-wait";
}

function renderModelMode(cameraLevel) {
  const status = document.body.dataset.robot3d || "loading";
  let text = "3D 준비 중";
  if (status === "disabled") text = "3D 꺼짐";
  else if (status === "unsupported") text = "3D 미지원";
  else if (status === "failed") text = "3D 로드 실패";
  else if (state.controlMode === "camera") text = "3D 일시정지";
  else if (status === "ready") text = "3D 모델 표시";
  setText("model-mode", text);
}

// Live stream: every ~4 min recycle the decoder via a cache-busted reload to
// dodge the long-running MJPEG GPU/process-memory leak. No per-poll flicker.
function renderCameraLive(image, streamUrl) {
  const cam = state.camera;
  const refreshMs = streamUrl.indexOf("action=snapshot") >= 0 ? CAMERA_SNAPSHOT_REFRESH_MS : CAMERA_RELOAD_MS;
  if (!cam.pending && Date.now() - cam.lastReloadMs >= refreshMs) {
    loadCameraStream(image, streamUrl, {
      reloadCounter: cam.reloadCounter, loaded: cam.loaded, retryAtMs: 0, backoffMs: 0, errorCount: 0
    });
    // Keep the visible frame up while the new stream warms (no blank flash).
    setCameraImageClass(image, "is-live");
    setCameraFault(false);
    setText("camera-mode", "카메라 연결됨");
    setCameraSignal("CAM LIVE", false);
    return "camera-live";
  }
  setCameraImageClass(image, "is-live");
  setCameraFault(false);
  setText("camera-mode", "카메라 연결됨");
  setText("camera-service-state", "실시간 영상 수신 중");
  setCameraSignal("CAM LIVE", false);
  return "camera-live";
}

// Error: auto-retry with growing backoff (3s→6s→12s→cap 30s) instead of a
// permanent "CAMERA LOST" latch. Reuses the refresh loop + Date.now() — no
// extra timers. Stays in the themed camera-error state while retrying.
function renderCameraRetry(image, streamUrl, runtime = {}) {
  const cam = state.camera;
  const now = Date.now();
  if (cam.retryAtMs === 0) {
    const backoffMs = cam.backoffMs > 0
      ? Math.min(cam.backoffMs * 2, CAMERA_RETRY_MAX_MS)
      : CAMERA_RETRY_BASE_MS;
    state.camera = {...cam, retryAtMs: now + backoffMs, backoffMs};
  } else if (now >= cam.retryAtMs) {
    loadCameraStream(image, streamUrl, {
      reloadCounter: cam.reloadCounter, retryAtMs: 0, backoffMs: cam.backoffMs, errorCount: cam.errorCount || 0
    });
  }
  setCameraImageClass(image, "is-hidden");
  setCameraFault(true);
  const repeatedFailure = cam.errorCount >= 2;
  setText("camera-mode", state.services.cameraTunnelBusy ? "카메라 터널 시작 중" : "카메라 신호 없음");
  setText("camera-service-state", cameraRuntimeText(
    runtime,
    state.services.cameraTunnelBusy
      ? "터널 시작 중"
      : (repeatedFailure ? "로봇 네트워크/터널 확인" : "터널 재시도 대기")
  ));
  setCameraSignal(repeatedFailure ? "CAM LOST" : "CAM RETRY", true);
  return "camera-error";
}

function cameraRuntimeText(runtime, fallback) {
  if (!runtime || !runtime.status) return fallback;
  if (runtime.status === "disabled") return "카메라 꺼짐";
  if (runtime.status === "missing_url") return "카메라 URL 없음";
  if (runtime.status === "port_open") return "터널 포트 열림";
  if (runtime.status === "port_closed") {
    return runtime.port ? `터널 포트 닫힘 :${runtime.port}` : "터널 포트 닫힘";
  }
  return fallback;
}

function setCameraImageClass(image, stateClass) {
  const next = `camera-stream ${stateClass}`;
  if (image.className !== next) image.className = next;
  const opacity = stateClass === "is-live" ? "0.78" : "0";
  if (image.style.opacity !== opacity) image.style.opacity = opacity;
}

function setCameraFault(faulted) {
  const hud = document.querySelector(".camera-hud");
  if (hud) hud.classList.toggle("camera-fault", Boolean(faulted));
}

function setCameraSignal(label, faulted) {
  const signal = $("fpv-camera-state");
  if (!signal) return;
  setText("fpv-camera-state", label);
  signal.classList.toggle("camera-warn", Boolean(faulted));
}

function modeLabel(mode) {
  switch (mode) {
    case "ssh": return "SSH 직접";
    case "mac_relay": return "맥 경유";
    case "robot_udp": return "로봇 직결";
    case "dry_run": return "연습";
    default: return mode || "-";
  }
}

function missionState(data, stale) {
  if (stale) {
    return {kicker: "신호", title: "신호 끊김", caption: "응답이 지연되고 있어요", level: "warn"};
  }
  if (data.estopped) {
    return {kicker: "안전", title: "비상정지", caption: "비상정지가 걸렸어요", level: "danger"};
  }
  if (!data.armed) {
    return {kicker: "대기", title: "잠김", caption: "조종하려면 먼저 '조종 시작'을 누르세요", level: "warn"};
  }
  if (!data.deadman) {
    return {kicker: "준비", title: "ZL 잡기", caption: "ZL을 잡고 있어야 움직여요", level: "ready"};
  }
  if (data.moving) {
    return {kicker: "조종", title: "이동 중", caption: "보행 명령 전송 중", level: "motion"};
  }
  return {kicker: "조종", title: "준비 완료", caption: "스틱 입력을 기다리는 중", level: "ready"};
}

function setMotionVector(x, y, moving) {
  const el = $("motion-vector");
  const magnitude = Math.min(1, Math.hypot(x, y));
  const angle = Math.atan2(x, y) * 180 / Math.PI;
  const scale = moving ? 0.55 + magnitude * 0.75 : 0.45;
  const transform = `rotate(${angle}deg) scaleY(${scale})`;
  if (el.style.transform !== transform) el.style.transform = transform;
}

function fixed(value) {
  return Number(value || 0).toFixed(1);
}

function formatSigned(value, digits) {
  const num = Number(value || 0);
  return `${num > 0 ? "+" : ""}${num.toFixed(digits)}`;
}

function balanceLabel(pitch, roll) {
  return balanceStatus(pitch, roll).text;
}

function balanceStatus(pitch, roll) {
  const load = Math.hypot(Number(pitch || 0), Number(roll || 0));
  if (load >= 20) return {text: "위험", level: "bad"};
  if (load >= 10) return {text: "주의", level: "warn"};
  return {text: "수평", level: "good"};
}

function formatRuntime(seconds) {
  const total = Math.max(0, Math.floor(seconds));
  const min = Math.floor(total / 60);
  const sec = total % 60;
  if (min < 60) return `${min}분 ${sec}초`;
  const hr = Math.floor(min / 60);
  return `${hr}시간 ${min % 60}분`;
}

function formatRuntimeClock(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds || 0)));
  const hr = Math.floor(total / 3600);
  const min = Math.floor((total % 3600) / 60);
  const sec = total % 60;
  if (hr > 0) {
    return `${String(hr).padStart(2, "0")}:${String(min).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
  }
  return `${String(min).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, Number(value || 0)));
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

const shortcutActions = new Map([
  ["a", "arm"],
  ["x", "recover"],
  ["b", "stop"],
  ["y", "ping"],
  ["r", "reconnect"],
  ["+", "estop"],
  ["=", "estop"]
]);

for (const button of document.querySelectorAll("[data-dash-style]")) {
  button.addEventListener("click", () => setDashStyle(button.dataset.dashStyle));
}
setDashStyle(state.dashStyle);

for (const button of document.querySelectorAll("[data-control-mode]")) {
  button.addEventListener("click", () => setControlMode(button.dataset.controlMode));
}
setControlMode(state.controlMode);

for (const button of document.querySelectorAll(".theme-switch [data-ui-theme]")) {
  button.addEventListener("click", () => setUiTheme(button.dataset.uiTheme));
}
setUiTheme(state.uiTheme);

for (const button of document.querySelectorAll("[data-action]")) {
  button.addEventListener("click", () => action(button.dataset.action));
}

for (const button of document.querySelectorAll("[data-service][data-service-action]")) {
  button.addEventListener("click", () => serviceAction(button.dataset.service, button.dataset.serviceAction));
}

const dockButtons = Array.from(document.querySelectorAll(".dock-button[data-action]"));
let dockFocusIndex = 0;
const cameraImage = $("camera-stream");

function focusDockButton(index) {
  dockFocusIndex = (index + dockButtons.length) % dockButtons.length;
  const button = dockButtons[dockFocusIndex];
  for (const item of dockButtons) {
    item.classList.toggle("selected", item === button);
  }
  setText("dock-focus-label", button.dataset.label || button.textContent.trim());
  setText("dock-focus-hint", button.dataset.hint || "A: 선택한 명령 실행");
  button.focus({preventScroll: true});
}

for (const button of dockButtons) {
  button.addEventListener("focus", () => {
    const index = dockButtons.indexOf(button);
    if (index >= 0) focusDockButton(index);
  });
}

cameraImage.addEventListener("load", () => {
  // Successful (re)load: clear error and reset the retry backoff.
  state.camera = {
    ...state.camera,
    loaded: true,
    error: false,
    pending: false,
    errorCount: 0,
    retryAtMs: 0,
    backoffMs: 0
  };
});

const shutdownButton = $("shutdown-button");
if (shutdownButton) shutdownButton.addEventListener("click", shutdownSwitch);

cameraImage.addEventListener("error", () => {
  // Enter the auto-retry state; renderCameraRetry schedules the next attempt.
  state.camera = {
    ...state.camera,
    loaded: false,
    error: true,
    pending: false,
    errorCount: (state.camera.errorCount || 0) + 1
  };
});

window.addEventListener("keydown", (event) => {
  if (event.key === "ArrowLeft") {
    event.preventDefault();
    focusDockButton(dockFocusIndex - 1);
    return;
  }
  if (event.key === "ArrowRight") {
    event.preventDefault();
    focusDockButton(dockFocusIndex + 1);
    return;
  }
  if (event.key === "Enter" || event.key === " ") {
    const focused = document.activeElement;
    if (focused && focused.dataset && focused.dataset.action) {
      event.preventDefault();
      action(focused.dataset.action);
      return;
    }
  }
  const actionName = shortcutActions.get(event.key.toLowerCase());
  if (!actionName) return;
  event.preventDefault();
  action(actionName);
});

setInterval(updateClock, 1000);
setInterval(refresh, 125);
setInterval(pollGamepad, 40);
updateClock();
refresh();
window.setTimeout(() => focusDockButton(0), 80);
registerServiceWorker();

function pollGamepad() {
  if (!navigator.getGamepads) return;
  const pads = navigator.getGamepads();
  let pad = null;
  for (const candidate of pads) {
    if (candidate) {
      pad = candidate;
      break;
    }
  }
  if (!pad) return;

  const pressed = pad.buttons.map((button) => Boolean(button && button.pressed));
  const edge = (index) => Boolean(pressed[index] && !state.gamepad.buttons[index]);

  if (edge(14)) focusDockButton(dockFocusIndex - 1);
  if (edge(15)) focusDockButton(dockFocusIndex + 1);
  if (edge(1)) action("stop");
  if (edge(9)) action("estop");

  state.gamepad.buttons = pressed;
}

function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) return;
  window.addEventListener("load", () => {
    navigator.serviceWorker.register(SERVICE_WORKER_URL).catch(() => {
      // Older Switchroot browsers or strict kiosk policies may not support SW.
      // The cockpit is still fully usable as a normal local page.
    });
  });
}
