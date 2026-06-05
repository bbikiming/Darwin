const CAMERA_RELOAD_MS = 240000; // ~4 min: recycle the MJPEG decoder (GPU/mem leak)
const CAMERA_RETRY_BASE_MS = 3000; // first auto-retry delay after an error
const CAMERA_RETRY_MAX_MS = 30000; // backoff cap

const state = {
  last: null,
  staleAfterMs: 900,
  lastLogsKey: "",
  camera: {
    src: "",          // bare stream URL (no cache-bust) — detects URL changes
    loaded: false,
    error: false,
    reloadCounter: 0, // bumped on every (re)load; appended as &_r=<n>
    lastReloadMs: 0,  // Date.now() of last successful-stream periodic reload
    retryAtMs: 0,     // Date.now() of next allowed retry while in error state
    backoffMs: 0      // current retry delay (grows 3s→6s→12s→cap 30s)
  },
  gamepad: {
    buttons: []
  }
};

const $ = (id) => document.getElementById(id);

function setClass(el, value) {
  if (el.className === value) return;
  el.className = value;
}

function setText(id, value) {
  const el = $(id);
  if (el.textContent === String(value)) return;
  el.textContent = value;
}

function setStateClass(id, base, level) {
  const el = $(id);
  el.className = `${base} ${level || ""}`.trim();
}

function setMeter(id, value, max) {
  const meter = $(id);
  const bar = meter.querySelector("i");
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

async function action(name) {
  const button = document.querySelector(`[data-action="${name}"]`);
  if (button) button.classList.add("pressed");
  try {
    await fetch("/api/action", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({action: name})
    });
    await refresh();
  } catch (_err) {
    setText("mission-caption", "명령 전송 실패");
  } finally {
    if (button) window.setTimeout(() => button.classList.remove("pressed"), 120);
  }
}

function updateClock() {
  const now = new Date();
  setText("clock", now.toLocaleTimeString([], {hour12: false}));
}

async function refresh() {
  let data;
  try {
    data = await fetch("/api/state", {cache: "no-store"}).then((r) => r.json());
  } catch (_err) {
    setText("link-text", "에이전트 꺼짐");
    setText("route-state", "연결 끊김");
    setClass($("link-pill"), "status-chip");
    setText("mission-kicker", "대기");
    setText("mission-title", "시동 중");
    setText("mission-caption", "로컬 에이전트를 기다리는 중");
    setClass($("stage-panel"), "stage-panel warn");
    setStateClass("link-state-panel", "readout-panel connection-panel", "bad");
    setText("link-state-text", "에이전트 꺼짐");
    setStateClass("robot-batt", "robot-batt", "unknown");
    setText("battery-pct", "--%");
    setText("battery-v", "-- V");
    setBattFill(null);
    setStateClass("robot-pose", "robot-flag", "warn");
    setText("robot-pose-val", "정보 없음");
    setStateClass("robot-link", "robot-flag", "warn");
    setText("robot-latency", "-- ms");
    setText("robot-walk-flag", "정지");
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
  const stale = age > state.staleAfterMs;
  const moving = Boolean(data.moving);
  const sshMode = data.mode === "ssh";
  const linked = sshMode ? Boolean(data.ssh_connected) : connected;
  const routeText = stale ? "신호 끊김" : (linked ? (sshMode ? "SSH 연결됨" : "연결됨") : (sshMode ? "연결 중" : "연결 끊김"));
  const mission = missionState(data, stale);
  const cameraLevel = renderCamera(camera);

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
  renderRobot(data, stale);

  setText("mission-kicker", mission.kicker);
  setText("mission-title", mission.title);
  setText("mission-caption", mission.caption);
  setClass($("stage-panel"), `stage-panel ${mission.level} ${cameraLevel}`);
  // Show the live WebGL robot whenever the real camera is not streaming; pause
  // it when the camera is live so WebGL and MJPEG never run together.
  if (window.__darwinRobot3D) window.__darwinRobot3D.setActive(cameraLevel !== "camera-live");

  setText("armed", data.armed ? "준비됨" : "잠김");
  setText("deadman", data.deadman ? "잡음" : "놓음");
  setText("estop", data.estopped ? "작동" : "정상");
  setStateClass("tile-arm", "safety-tile", data.armed ? "good" : "warn");
  setStateClass("tile-estop", "safety-tile", data.estopped ? "bad" : "good");
  setStateClass("trigger-deadman", "trigger-state", data.deadman ? "good" : "warn");
  setStateClass("trigger-link", "trigger-state", linked && !stale ? "good" : (stale ? "bad" : "warn"));

  setText("stride-num", `${fixed(command.stride_mm)} mm`);
  setText("turn-num", `${fixed(command.turn_deg)}°`);
  setText("pan-num", `${fixed(command.head_pan_deg)}°`);
  setText("tilt-num", `${fixed(command.head_tilt_deg)}°`);

  setMeter("stride-bar", Number(command.stride_mm || 0), 25);
  setMeter("turn-bar", Number(command.turn_deg || 0), 12);
  setMeter("pan-bar", Number(command.head_pan_deg || 0), 70);
  setMeter("tilt-bar", Number(command.head_tilt_deg || 0), 35);
  setDot("left-mini-dot", Number(ctl.left_x || 0), Number(ctl.left_y || 0));
  setDot("right-mini-dot", Number(ctl.right_x || 0), Number(ctl.right_y || 0));
  setMotionVector(Number(ctl.left_x || 0), Number(ctl.left_y || 0), moving);

  const logs = data.logs || [];
  setText("log-count", String(logs.length));
  const nextLogsKey = logs.slice(-5).join("\n");
  if (state.lastLogsKey !== nextLogsKey) {
    state.lastLogsKey = nextLogsKey;
    $("logs").innerHTML = logs.slice(-5).map((line) => `<div>${escapeHtml(line)}</div>`).join("");
  }
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
  state.camera = {
    ...base,
    src: streamUrl,
    loaded: false,
    error: false,
    reloadCounter,
    lastReloadMs: Date.now()
  };
  image.src = bustedSrc(streamUrl, reloadCounter);
}

function renderCamera(camera) {
  const enabled = Boolean(camera.enabled);
  const streamUrl = String(camera.stream_url || "");
  const label = String(camera.label || "Robot Camera");
  const route = String(camera.route || "ssh-tunnel");
  const image = $("camera-stream");

  setText("camera-label", label);
  setText("camera-route", route);

  if (!enabled || !streamUrl) {
    if (state.camera.src) image.removeAttribute("src");
    setCameraImageClass(image, "is-hidden");
    state.camera = {
      src: "", loaded: false, error: false,
      reloadCounter: 0, lastReloadMs: 0, retryAtMs: 0, backoffMs: 0
    };
    setText("camera-mode", "카메라 꺼짐");
    return "camera-off";
  }

  if (state.camera.src !== streamUrl) {
    // New URL: reset backoff and start fresh.
    loadCameraStream(image, streamUrl, {reloadCounter: 0, retryAtMs: 0, backoffMs: 0});
  }

  if (state.camera.error) return renderCameraRetry(image, streamUrl);
  if (state.camera.loaded) return renderCameraLive(image, streamUrl);

  setCameraImageClass(image, "is-hidden");
  setText("camera-mode", "카메라 연결 중");
  return "camera-wait";
}

// Live stream: every ~4 min recycle the decoder via a cache-busted reload to
// dodge the long-running MJPEG GPU/process-memory leak. No per-poll flicker.
function renderCameraLive(image, streamUrl) {
  const cam = state.camera;
  if (Date.now() - cam.lastReloadMs >= CAMERA_RELOAD_MS) {
    loadCameraStream(image, streamUrl, {
      reloadCounter: cam.reloadCounter, retryAtMs: 0, backoffMs: 0
    });
    // Keep the visible frame up while the new stream warms (no blank flash).
    setCameraImageClass(image, "is-live");
    setText("camera-mode", "카메라 연결됨");
    return "camera-live";
  }
  setCameraImageClass(image, "is-live");
  setText("camera-mode", "카메라 연결됨");
  return "camera-live";
}

// Error: auto-retry with growing backoff (3s→6s→12s→cap 30s) instead of a
// permanent "CAMERA LOST" latch. Reuses the refresh loop + Date.now() — no
// extra timers. Stays in the themed camera-error state while retrying.
function renderCameraRetry(image, streamUrl) {
  const cam = state.camera;
  const now = Date.now();
  if (cam.retryAtMs === 0) {
    const backoffMs = cam.backoffMs > 0
      ? Math.min(cam.backoffMs * 2, CAMERA_RETRY_MAX_MS)
      : CAMERA_RETRY_BASE_MS;
    state.camera = {...cam, retryAtMs: now + backoffMs, backoffMs};
  } else if (now >= cam.retryAtMs) {
    loadCameraStream(image, streamUrl, {
      reloadCounter: cam.reloadCounter, retryAtMs: 0, backoffMs: cam.backoffMs
    });
  }
  setCameraImageClass(image, "is-hidden");
  setText("camera-mode", "다시 연결 중…");
  return "camera-error";
}

function setCameraImageClass(image, stateClass) {
  const next = `camera-stream ${stateClass}`;
  if (image.className !== next) image.className = next;
  const opacity = stateClass === "is-live" ? "0.78" : "0";
  if (image.style.opacity !== opacity) image.style.opacity = opacity;
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

function formatRuntime(seconds) {
  const total = Math.max(0, Math.floor(seconds));
  const min = Math.floor(total / 60);
  const sec = total % 60;
  if (min < 60) return `${min}분 ${sec}초`;
  const hr = Math.floor(min / 60);
  return `${hr}시간 ${min % 60}분`;
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
  ["+", "estop"],
  ["=", "estop"]
]);

const dockButtons = Array.from(document.querySelectorAll("[data-action]"));
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
  button.addEventListener("click", () => action(button.dataset.action));
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
    retryAtMs: 0,
    backoffMs: 0
  };
});

cameraImage.addEventListener("error", () => {
  // Enter the auto-retry state; renderCameraRetry schedules the next attempt.
  state.camera = {
    ...state.camera,
    loaded: false,
    error: true
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
setInterval(refresh, 250);
setInterval(pollGamepad, 80);
updateClock();
refresh();
window.setTimeout(() => focusDockButton(0), 80);

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
