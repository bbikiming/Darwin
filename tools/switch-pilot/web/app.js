const state = {
  last: null,
  staleAfterMs: 900,
  lastLogsKey: "",
  camera: {
    src: "",
    loaded: false,
    error: false
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
    setText("mission-caption", "Cockpit command failed");
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
    setText("link-text", "Agent offline");
    setText("route-state", "Offline");
    setClass($("link-pill"), "status-chip");
    setText("mission-kicker", "WAITING");
    setText("mission-title", "Runtime");
    setText("mission-caption", "Waiting for local agent");
    setClass($("stage-panel"), "stage-panel warn");
    setStateClass("link-state-panel", "readout-panel connection-panel", "bad");
    setText("link-state-text", "Agent offline");
    setStateClass("robot-batt", "robot-batt", "unknown");
    setText("battery-pct", "--%");
    setText("battery-v", "-- V");
    setBattFill(null);
    setStateClass("robot-pose", "robot-flag", "warn");
    setText("robot-pose-val", "No data");
    setStateClass("robot-link", "robot-flag", "warn");
    setText("robot-latency", "-- ms");
    setText("robot-walk-flag", "Idle");
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
  const routeText = stale ? "Stale" : (linked ? (sshMode ? "SSH" : "Linked") : (sshMode ? "Searching" : "Offline"));
  const mission = missionState(data, stale);
  const cameraLevel = renderCamera(camera);

  setClass($("link-pill"), linked && !stale ? "status-chip connected" : "status-chip");
  setText("link-text", routeText);
  setText("route-state", routeText);
  setText("mode", data.mode || "-");
  setText("target-type", "Link");
  setText("target", data.target || "-");
  setText("ip", data.local_ip || "-");
  setText("diag-mode", data.mode || "-");
  setText("runtime", formatRuntime(data.uptime_sec || 0));
  setText("input-status", data.input_status || "Unknown");
  setText("watchdog", "500 ms");
  setText("age", `${age} ms`);

  renderLink(data, linked, stale, sshMode);
  renderRobot(data, stale);

  setText("mission-kicker", mission.kicker);
  setText("mission-title", mission.title);
  setText("mission-caption", mission.caption);
  setClass($("stage-panel"), `stage-panel ${mission.level} ${cameraLevel}`);

  setText("armed", data.armed ? "Armed" : "Locked");
  setText("deadman", data.deadman ? "Held" : "Open");
  setText("estop", data.estopped ? "Active" : "Clear");
  setStateClass("tile-arm", "safety-tile", data.armed ? "good" : "warn");
  setStateClass("tile-estop", "safety-tile", data.estopped ? "bad" : "good");
  setStateClass("trigger-deadman", "trigger-state", data.deadman ? "good" : "warn");
  setStateClass("trigger-link", "trigger-state", linked && !stale ? "good" : (stale ? "bad" : "warn"));

  setText("stride-num", `${fixed(command.stride_mm)} mm`);
  setText("turn-num", `${fixed(command.turn_deg)} deg`);
  setText("pan-num", `${fixed(command.head_pan_deg)} deg`);
  setText("tilt-num", `${fixed(command.head_tilt_deg)} deg`);

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
  let text = sshMode ? "Searching SSH" : "Offline";
  if (linked && !stale) {
    level = "good";
    text = sshMode ? "SSH Linked" : "Linked";
  } else if (linked && stale) {
    level = "warn";
    text = "Stale";
  } else if (sshMode) {
    level = "warn";
    text = "Searching SSH";
  }
  setStateClass("link-state-panel", "readout-panel connection-panel", level);
  setText("link-state-text", `${text} · ${data.target || "no target"}`);
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
  setText("robot-walk-flag", walking ? "Walking" : "Idle");
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
  if (stale) return {text: "No data", level: "warn"};
  const fallen = Number(data.robot_fallen || 0);
  if (fallen > 0) return {text: "FALLEN ↟", level: "bad"};
  if (fallen < 0) return {text: "FALLEN ↡", level: "bad"};
  return {text: "UPRIGHT", level: "good"};
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
    state.camera = {src: "", loaded: false, error: false};
    setText("camera-mode", "CAMERA OFF");
    return "camera-off";
  }

  if (state.camera.src !== streamUrl) {
    state.camera = {src: streamUrl, loaded: false, error: false};
    image.src = streamUrl;
  }

  if (state.camera.error) {
    setCameraImageClass(image, "is-hidden");
    setText("camera-mode", "CAMERA LOST");
    return "camera-error";
  }
  if (state.camera.loaded) {
    setCameraImageClass(image, "is-live");
    setText("camera-mode", "CAMERA LIVE");
    return "camera-live";
  }
  setCameraImageClass(image, "is-hidden");
  setText("camera-mode", "CAMERA WAIT");
  return "camera-wait";
}

function setCameraImageClass(image, stateClass) {
  const next = `camera-stream ${stateClass}`;
  if (image.className !== next) image.className = next;
  const opacity = stateClass === "is-live" ? "0.78" : "0";
  if (image.style.opacity !== opacity) image.style.opacity = opacity;
}

function missionState(data, stale) {
  if (stale) {
    return {kicker: "SIGNAL", title: "Stale", caption: "Runtime update delayed", level: "warn"};
  }
  if (data.estopped) {
    return {kicker: "SAFETY", title: "E-Stop", caption: "Motion latch is active", level: "danger"};
  }
  if (!data.armed) {
    return {kicker: "STANDBY", title: "Locked", caption: "Arm command authority to continue", level: "warn"};
  }
  if (!data.deadman) {
    return {kicker: "READY", title: "Hold ZL", caption: "Movement gate is open until ZL is held", level: "ready"};
  }
  if (data.moving) {
    return {kicker: "PILOT", title: "Moving", caption: "Walking command active", level: "motion"};
  }
  return {kicker: "PILOT", title: "Ready", caption: "Standing by for stick input", level: "ready"};
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
  if (min < 60) return `${min}m ${sec}s`;
  const hr = Math.floor(min / 60);
  return `${hr}h ${min % 60}m`;
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
  setText("dock-focus-hint", button.dataset.hint || "A confirms selected command");
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
  state.camera.loaded = true;
  state.camera.error = false;
});

cameraImage.addEventListener("error", () => {
  state.camera.loaded = false;
  state.camera.error = true;
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
