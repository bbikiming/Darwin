"use strict";

// First-boot provisioning form. Loads current config, lets the user pick a
// mode + targets, POSTs to /api/config, then redirects to the cockpit.
// No external libraries (matches cockpit constraints).

(function () {
  var MODEL_RESULT_KEY = "darwinModelCheckResult";
  var NO_3D_KEY = "darwinNo3D";
  var form = document.getElementById("setup-form");
  var statusEl = document.getElementById("status");
  var preflightBtn = document.getElementById("preflight-btn");
  var cameraTunnelBtn = document.getElementById("camera-tunnel-btn");
  var robotReadyButtons = Array.prototype.slice.call(document.querySelectorAll("[data-robot-ready]"));
  var robotReadyLog = document.getElementById("robot-ready-log");
  var saveButtons = Array.prototype.slice.call(document.querySelectorAll('button[type="submit"]'));
  var macSection = document.getElementById("mac-section");
  var robotSection = document.getElementById("robot-section");
  var sshSection = document.getElementById("ssh-section");
  var modeSummaryTitle = document.getElementById("mode-summary-title");
  var modeSummaryBody = document.getElementById("mode-summary-body");
  var modeSummaryRoute = document.getElementById("mode-summary-route");
  var defaultStatus = "입력한 값은 이 스위치의 로컬 설정 파일에 저장됩니다.";
  var preflightFreshUntil = 0;
  var navIndex = 0;

  var modeCopy = {
    dry_run: {
      title: "연습 모드",
      body: "로봇으로 명령을 보내지 않고 화면과 입력만 확인합니다.",
      route: "Switch 내부 dry-run"
    },
    mac_relay: {
      title: "맥 경유",
      body: "Mac DarwinForge를 중계점으로 사용해 가장 안전하게 시작합니다.",
      route: "Switch → Mac → Darwin"
    },
    robot_udp: {
      title: "로봇 직결 UDP",
      body: "로봇 수신기가 준비된 뒤 쓰는 빠른 직접 연결 경로입니다.",
      route: "Switch → Darwin UDP"
    },
    ssh: {
      title: "로봇 직접 조종 SSH",
      body: "구형 다윈 로봇에 SSH로 접속해 보행 프로그램을 제어합니다.",
      route: "Switch → SSH → Darwin"
    }
  };

  var els = {
    macHost: document.getElementById("mac-host"),
    macPort: document.getElementById("mac-port"),
    macPairing: document.getElementById("mac-pairing"),
    robotHost: document.getElementById("robot-host"),
    robotPort: document.getElementById("robot-port"),
    robotToken: document.getElementById("robot-token"),
    sshHost: document.getElementById("ssh-host"),
    sshUser: document.getElementById("ssh-user"),
    sshPort: document.getElementById("ssh-port"),
    sshIdentity: document.getElementById("ssh-identity"),
    cameraEnabled: document.getElementById("camera-enabled"),
    cameraStreamUrl: document.getElementById("camera-stream-url"),
    cameraSnapshotUrl: document.getElementById("camera-snapshot-url"),
    cameraLocalPort: document.getElementById("camera-local-port"),
    cameraRemotePort: document.getElementById("camera-remote-port"),
    cameraRoute: document.getElementById("camera-route"),
    cameraLabel: document.getElementById("camera-label"),
    model3dEnabled: document.getElementById("model3d-enabled"),
    modelCheckNote: document.getElementById("model-check-note"),
  };

  // The 3D robot model is a client display preference (localStorage), separate
  // from the device config POST. Reflect the current setting (default: on).
  try { els.model3dEnabled.checked = !localStorage.getItem(NO_3D_KEY); } catch (_e) {}

  function setStatus(text, kind) {
    statusEl.textContent = text || defaultStatus;
    statusEl.className = kind || "";
  }

  function setSaveDisabled(disabled) {
    for (var i = 0; i < saveButtons.length; i += 1) {
      saveButtons[i].disabled = disabled;
    }
  }

  function setPreflightDisabled(disabled) {
    if (preflightBtn) preflightBtn.disabled = disabled;
  }

  function setCameraTunnelDisabled(disabled) {
    if (cameraTunnelBtn) cameraTunnelBtn.disabled = disabled;
  }

  function setRobotReadyDisabled(disabled) {
    for (var i = 0; i < robotReadyButtons.length; i += 1) {
      robotReadyButtons[i].disabled = disabled;
    }
  }

  function setCheck(id, level, text) {
    var item = document.getElementById("check-" + id);
    var label = document.getElementById("check-" + id + "-text");
    if (item) item.className = "check-item " + (level || "warn");
    if (label) label.textContent = text || "";
  }

  function readModelCheckResult() {
    try {
      var raw = window.localStorage && window.localStorage.getItem(MODEL_RESULT_KEY);
      if (!raw) return null;
      var parsed = JSON.parse(raw);
      return parsed && typeof parsed === "object" ? parsed : null;
    } catch (_err) {
      return null;
    }
  }

  function resultAgeLabel(iso) {
    var time = Date.parse(iso || "");
    if (!Number.isFinite(time)) return "최근 점검";
    var minutes = Math.max(0, Math.round((Date.now() - time) / 60000));
    if (minutes < 1) return "방금 점검";
    if (minutes < 60) return minutes + "분 전";
    var hours = Math.round(minutes / 60);
    if (hours < 24) return hours + "시간 전";
    return Math.round(hours / 24) + "일 전";
  }

  function renderModelCheckResult() {
    var result = readModelCheckResult();
    var note = els.modelCheckNote;
    var modelOn = Boolean(els.model3dEnabled && els.model3dEnabled.checked);
    if (!result) {
      if (note) {
        note.className = "result-note warn";
        note.querySelector("span").textContent = "3D 성능 점검 전입니다. 실제 스위치에서 먼저 점검하는 것을 권장합니다.";
      }
      setCheck("model", "warn", "점검 전 · 기본값은 3D 켜짐");
      return;
    }

    var avg = Number(result.avgFps || 0);
    var maxMs = Number(result.maxMs || 0);
    var label = result.label || (result.level === "fail" ? "불충분" : result.level === "pass" ? "충분" : "주의");
    var wantsOff = result.recommendation === "disable_3d";
    var level = result.level === "pass" ? "good" : result.level === "fail" ? (modelOn ? "bad" : "warn") : "warn";
    var summary = label + " · " + avg.toFixed(1) + "fps · 최대 " + maxMs.toFixed(0) + "ms · " + resultAgeLabel(result.checkedAt);
    var applied = wantsOff ? !modelOn : modelOn;
    var actionText = wantsOff ? "권장: 3D 끄기" : "권장: 3D 켜기";

    if (note) {
      note.className = "result-note " + level;
      note.querySelector("span").textContent = summary + " · " + actionText + (applied ? " 적용됨" : " 미적용");
    }
    setCheck("model", applied ? level : "warn", summary + (applied ? "" : " · 권장 미적용"));
  }

  function selectedMode() {
    var checked = form.querySelector('input[name="mode"]:checked');
    return checked ? checked.value : "dry_run";
  }

  function isTypingTarget(el) {
    if (!el) return false;
    var tag = String(el.tagName || "").toLowerCase();
    return tag === "input" && el.type !== "radio" && el.type !== "checkbox";
  }

  function isVisible(el) {
    if (!el || el.disabled) return false;
    var rect = el.getBoundingClientRect();
    var style = window.getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
  }

  function navTargets() {
    var raw = Array.prototype.slice.call(document.querySelectorAll(
      ".mode-option, .toggle-row, .top-actions a, .top-actions button, .status-panel .pill-link, [data-robot-ready], input[type='text'], input[type='number'], input[type='password']"
    ));
    return raw.filter(isVisible);
  }

  function ensureNavTabIndex() {
    var labels = document.querySelectorAll(".mode-option, .toggle-row");
    for (var i = 0; i < labels.length; i += 1) labels[i].tabIndex = 0;
  }

  function focusNav(index) {
    var targets = navTargets();
    if (!targets.length) return;
    navIndex = (index + targets.length) % targets.length;
    for (var i = 0; i < targets.length; i += 1) {
      targets[i].classList.toggle("nav-selected", i === navIndex);
    }
    targets[navIndex].focus({ preventScroll: true });
  }

  function activateFocused() {
    var el = document.activeElement;
    if (!el) return;
    if (el.classList && (el.classList.contains("mode-option") || el.classList.contains("toggle-row"))) {
      var input = el.querySelector("input");
      if (input) {
        if (input.type === "radio") input.checked = true;
        else if (input.type === "checkbox") input.checked = !input.checked;
        input.dispatchEvent(new Event("change", { bubbles: true }));
      }
      return;
    }
    if (typeof el.click === "function") el.click();
  }

  function syncNavFromFocus(target) {
    var targets = navTargets();
    var index = targets.indexOf(target);
    if (index < 0) return;
    navIndex = index;
    for (var i = 0; i < targets.length; i += 1) {
      targets[i].classList.toggle("nav-selected", i === navIndex);
    }
  }

  // Show only the section relevant to the chosen mode.
  function syncSections() {
    var mode = selectedMode();
    var copy = modeCopy[mode] || modeCopy.dry_run;
    document.body.dataset.mode = mode;
    macSection.classList.toggle("hidden", mode !== "mac_relay");
    robotSection.classList.toggle("hidden", mode !== "robot_udp");
    sshSection.classList.toggle("hidden", mode !== "ssh");
    modeSummaryTitle.textContent = copy.title;
    modeSummaryBody.textContent = copy.body;
    modeSummaryRoute.textContent = copy.route;
    var options = form.querySelectorAll("[data-mode-option]");
    for (var i = 0; i < options.length; i += 1) {
      options[i].classList.toggle("selected", options[i].getAttribute("data-mode-option") === mode);
    }
    ensureNavTabIndex();
  }

  function setMode(mode) {
    var radio = form.querySelector('input[name="mode"][value="' + mode + '"]');
    if (radio) {
      radio.checked = true;
    } else {
      var fallback = form.querySelector('input[name="mode"][value="dry_run"]');
      if (fallback) fallback.checked = true;
    }
    syncSections();
  }

  function asObject(value) {
    return value && typeof value === "object" ? value : {};
  }

  // Prefill the form from the current config (best-effort).
  function applyConfig(config) {
    var cfg = asObject(config);
    setMode(typeof cfg.mode === "string" ? cfg.mode : "dry_run");

    var mac = asObject(cfg.mac);
    if (typeof mac.host === "string") els.macHost.value = mac.host;
    if (typeof mac.port === "number") els.macPort.value = String(mac.port);
    if (typeof mac.pairing_code === "string") els.macPairing.value = mac.pairing_code;

    var robot = asObject(cfg.robot);
    if (typeof robot.host === "string") els.robotHost.value = robot.host;
    if (typeof robot.port === "number") els.robotPort.value = String(robot.port);
    if (typeof robot.token === "string") els.robotToken.value = robot.token;

    var ssh = asObject(cfg.ssh);
    if (typeof ssh.host === "string") els.sshHost.value = ssh.host;
    if (typeof ssh.user === "string") els.sshUser.value = ssh.user;
    if (typeof ssh.port === "number") els.sshPort.value = String(ssh.port);
    if (typeof ssh.identity_file === "string") els.sshIdentity.value = ssh.identity_file;

    var camera = asObject(cfg.camera);
    els.cameraEnabled.checked = camera.enabled === true;
    if (typeof camera.stream_url === "string") els.cameraStreamUrl.value = camera.stream_url;
    if (typeof camera.snapshot_url === "string") els.cameraSnapshotUrl.value = camera.snapshot_url;
    if (typeof camera.local_port === "number") els.cameraLocalPort.value = String(camera.local_port);
    if (typeof camera.remote_port === "number") els.cameraRemotePort.value = String(camera.remote_port);
    if (typeof camera.route === "string") els.cameraRoute.value = camera.route;
    if (typeof camera.label === "string") els.cameraLabel.value = camera.label;
  }

  function loadConfig() {
    setStatus("현재 설정을 불러오는 중…", "busy");
    fetch("/api/config", { headers: { Accept: "application/json" } })
      .then(function (res) {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .then(function (config) {
        applyConfig(config);
        setStatus("", "");
      })
      .catch(function (err) {
        // Missing/unreadable config is fine on first boot — start with defaults.
        applyConfig({});
        setStatus("기본값으로 시작합니다 (" + err.message + ").", "");
      });
  }

  function loadRuntimeState() {
    fetch("/api/state", { cache: "no-store", headers: { Accept: "application/json" } })
      .then(function (res) {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .then(renderRuntimeState)
      .catch(function () {
        setCheck("agent", "bad", "로컬 에이전트 응답 없음");
        setCheck("input", "warn", "에이전트 시작 후 확인 가능");
        setCheck("link", "warn", "저장 후 재확인");
        setCheck("camera", "warn", "저장 후 재확인");
      });
  }

  function loadSystemHealth() {
    fetch("/api/health", { cache: "no-store", headers: { Accept: "application/json" } })
      .then(function (res) {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .then(renderSystemHealth)
      .catch(function () {
        setCheck("system", "warn", "설치 후 systemd/브라우저 상태 확인 필요");
      });
  }

  function checkLevelRank(level) {
    if (level === "bad") return 3;
    if (level === "warn") return 2;
    return 1;
  }

  function renderSystemHealth(result) {
    var checks = Array.isArray(result.checks) ? result.checks : [];
    var level = result.level === "bad" ? "bad" : result.level === "good" ? "good" : "warn";
    var sorted = checks.slice().sort(function (a, b) {
      return checkLevelRank(b.level) - checkLevelRank(a.level);
    });
    var top = sorted[0];
    var warnCount = checks.filter(function (item) { return item.level === "warn"; }).length;
    var badCount = checks.filter(function (item) { return item.level === "bad"; }).length;
    var text;

    if (level === "good") {
      text = "네이티브 실행 준비됨";
    } else if (badCount > 0 && top) {
      text = top.title + " · " + top.detail;
    } else if (top) {
      text = "준비 주의 " + warnCount + "개 · " + top.title + " 확인";
    } else {
      text = "설치 준비도 확인 필요";
    }
    setCheck("system", level, text);
  }

  function runCameraTunnelService() {
    setCameraTunnelDisabled(true);
    setStatus("카메라 터널 서비스를 시작하는 중…", "busy");
    fetch("/api/service", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ service: "camera_tunnel", action: "enable_now" }),
    })
      .then(function (res) {
        return res.json().then(function (data) {
          return { ok: res.ok, data: data };
        });
      })
      .then(function (result) {
        if (!result.ok || !result.data || result.data.ok !== true) {
          throw new Error((result.data && result.data.error) || "카메라 터널 시작에 실패했어요.");
        }
        setCheck("system", "good", "카메라 터널 서비스 시작됨");
        setStatus("카메라 터널 서비스를 시작했어요. 상태를 다시 확인합니다…", "ok");
        loadSystemHealth();
        loadRuntimeState();
      })
      .catch(function (err) {
        setStatus(err.message || "카메라 터널 시작에 실패했어요.", "error");
      })
      .finally(function () {
        setCameraTunnelDisabled(false);
      });
  }

  function robotReadyLabel(action) {
    return {
      plan: "계획",
      keygen: "키 생성",
      probe: "SSH 확인",
      status: "패치 확인",
      "start-walklab": "WalkLab 시작",
      "enable-agent-ssh": "SSH 모드 전환",
      all: "전체 준비",
    }[action] || action;
  }

  function setRobotReadyLog(text, kind) {
    if (!robotReadyLog) return;
    robotReadyLog.textContent = text || "";
    robotReadyLog.className = "robot-ready-log" + (kind ? " " + kind : "");
  }

  function runRobotReady(action) {
    var label = robotReadyLabel(action);
    setRobotReadyDisabled(true);
    setStatus(label + " 실행 중…", "busy");
    setRobotReadyLog("[" + label + "] 실행 중…", "");
    fetch("/api/robot-ready", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: action }),
    })
      .then(function (res) {
        return res.json().then(function (data) {
          return { ok: res.ok, data: data };
        });
      })
      .then(function (result) {
        var data = result.data || {};
        var output = "";
        if (data.stdout) output += data.stdout.replace(/\s+$/g, "");
        if (data.stderr) output += (output ? "\n\n--- stderr ---\n" : "") + data.stderr.replace(/\s+$/g, "");
        if (!output) output = data.error || "출력 없음";
        setRobotReadyLog(output, result.ok && data.ok ? "ok" : "error");
        if (!result.ok || data.ok !== true) {
          throw new Error(data.error || label + " 실패");
        }
        setStatus(label + " 완료", "ok");
        if (action === "all" || action === "enable-agent-ssh") {
          setCheck("link", "good", "SSH 조종 모드 전환 요청 완료");
          setTimeout(loadRuntimeState, 1200);
        } else if (action === "probe") {
          setCheck("link", "good", "로봇 SSH 인증 확인됨");
        } else if (action === "status") {
          setCheck("link", "good", "WalkLab 패치 확인됨");
        } else if (action === "plan") {
          setCheck("link", "warn", "로봇 SSH 준비 계획 확인됨");
        }
      })
      .catch(function (err) {
        setStatus(err.message || label + " 실패", "error");
      })
      .finally(function () {
        setRobotReadyDisabled(false);
      });
  }

  function renderRuntimeState(data) {
    var age = Math.max(0, Date.now() - Number(data.updated_at_ms || 0));
    setCheck("agent", age < 1200 ? "good" : "warn", age < 1200 ? "실행 중 · " + age + " ms" : "응답 지연 · " + age + " ms");

    var input = String(data.input_status || "입력장치 없음");
    var hasInput = !/없음|none|no controller/i.test(input);
    setCheck("input", hasInput ? "good" : "warn", input);

    if (Date.now() < preflightFreshUntil) return;

    var mode = String(data.mode || selectedMode());
    var linked = mode === "ssh" ? Boolean(data.ssh_connected) : Boolean(data.connected);
    var linkText = (data.target || "대상 없음") + " · " + (linked ? "연결됨" : "대기");
    setCheck("link", linked ? "good" : (mode === "dry_run" ? "good" : "warn"), linkText);

    var camera = data.camera && typeof data.camera === "object" ? data.camera : {};
    if (camera.enabled) {
      setCheck("camera", camera.stream_url ? "good" : "warn", (camera.route || "camera") + " · 켜짐");
    } else {
      setCheck("camera", "warn", "꺼짐");
    }
  }

  function transportCheck(checks) {
    var wanted = {
      dry_run: "mode",
      mac_relay: "mac",
      robot_udp: "robot_udp",
      ssh: "ssh"
    }[selectedMode()] || "mode";
    for (var i = 0; i < checks.length; i += 1) {
      if (checks[i].id === wanted) return checks[i];
    }
    return checks[0] || null;
  }

  function findCheck(checks, id) {
    for (var i = 0; i < checks.length; i += 1) {
      if (checks[i].id === id) return checks[i];
    }
    return null;
  }

  function renderPreflight(result) {
    var checks = Array.isArray(result.checks) ? result.checks : [];
    var link = transportCheck(checks);
    var camera = findCheck(checks, "camera");
    var key = findCheck(checks, "ssh_key");
    if (link) setCheck("link", link.level, link.title + " · " + link.detail);
    if (camera) setCheck("camera", camera.level, camera.title + " · " + camera.detail);
    if (key && selectedMode() === "ssh") setCheck("input", key.level, key.title + " · " + key.detail);

    var level = result.level || "warn";
    var statusKind = level === "bad" ? "error" : level === "good" ? "ok" : "busy";
    var label = level === "bad" ? "연결 점검 실패" : level === "good" ? "연결 점검 통과" : "연결 점검 주의";
    setStatus(label + " · 저장 전 상태 패널에 결과를 표시합니다.", statusKind);
    preflightFreshUntil = Date.now() + 9000;
  }

  function runPreflight() {
    var payload;
    try {
      payload = buildPayload();
    } catch (err) {
      setStatus(err.message, "error");
      return;
    }
    setPreflightDisabled(true);
    setStatus("연결 점검 중…", "busy");
    fetch("/api/preflight", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    })
      .then(function (res) {
        return res.json().then(function (data) {
          return { ok: res.ok, data: data };
        });
      })
      .then(function (result) {
        if (!result.ok || !result.data) {
          throw new Error((result.data && result.data.error) || "연결 점검에 실패했어요.");
        }
        renderPreflight(result.data);
      })
      .catch(function (err) {
        setStatus(err.message || "연결 점검에 실패했어요.", "error");
      })
      .finally(function () {
        setPreflightDisabled(false);
      });
  }

  function parsePort(raw) {
    var trimmed = (raw || "").trim();
    if (trimmed === "") return null;
    var num = Number(trimmed);
    if (!Number.isInteger(num) || num < 0 || num > 65535) {
      throw new Error("포트는 0~65535 사이의 정수여야 해요.");
    }
    return num;
  }

  function parseRequiredPort(raw, label) {
    var port = parsePort(raw);
    if (port === null) return null;
    if (port < 1 || port > 65535) throw new Error(label + "는 1~65535 사이의 정수여야 해요.");
    return port;
  }

  function normalizeCameraUrl(raw, label) {
    var value = (raw || "").trim();
    if (!value) return "";
    try {
      var parsed = new URL(value);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        throw new Error("bad scheme");
      }
      return parsed.href;
    } catch (_err) {
      throw new Error(label + "은 http:// 또는 https:// URL이어야 해요.");
    }
  }

  // SSH port: optional, but when present must be a whole number 1..65535.
  function parseSshPort(raw) {
    var trimmed = (raw || "").trim();
    if (trimmed === "") return null;
    var num = Number(trimmed);
    if (!Number.isInteger(num) || num < 1 || num > 65535) {
      throw new Error("SSH 포트는 1~65535 사이의 정수여야 해요.");
    }
    return num;
  }

  // Build + validate the ssh section. Host and user are required for SSH mode.
  function buildSsh() {
    var ssh = {};
    var host = els.sshHost.value.trim();
    if (!host) throw new Error("SSH 호스트를 입력하세요.");
    if (/\s/.test(host)) throw new Error("SSH 호스트에 공백을 넣을 수 없어요.");
    ssh.host = host;

    var user = els.sshUser.value.trim();
    if (!user) throw new Error("SSH 사용자를 입력하세요.");
    if (/\s/.test(user)) throw new Error("SSH 사용자에 공백을 넣을 수 없어요.");
    ssh.user = user;

    var port = parseSshPort(els.sshPort.value);
    if (port !== null) ssh.port = port;

    var identity = els.sshIdentity.value.trim();
    if (identity) ssh.identity_file = identity;
    return ssh;
  }

  // Build the validated-shape payload; throws on obvious client-side errors.
  function buildPayload() {
    var mode = selectedMode();
    var payload = { mode: mode };

    if (mode === "mac_relay") {
      var mac = {};
      var host = els.macHost.value.trim();
      if (host) mac.host = host;
      var macPort = parsePort(els.macPort.value);
      if (macPort !== null) mac.port = macPort;
      var pairing = els.macPairing.value.trim();
      if (pairing) {
        if (!/^[0-9]+$/.test(pairing)) throw new Error("페어링 코드는 숫자만 입력할 수 있어요.");
        mac.pairing_code = pairing;
      }
      if (Object.keys(mac).length) payload.mac = mac;
    } else if (mode === "robot_udp") {
      var robot = {};
      var rHost = els.robotHost.value.trim();
      if (rHost) robot.host = rHost;
      var rPort = parsePort(els.robotPort.value);
      if (rPort !== null) robot.port = rPort;
      var token = els.robotToken.value;
      if (token) robot.token = token;
      if (Object.keys(robot).length) payload.robot = robot;
    } else if (mode === "ssh") {
      payload.ssh = buildSsh();
    }

    var camera = { enabled: els.cameraEnabled.checked };
    var streamUrl = normalizeCameraUrl(els.cameraStreamUrl.value, "카메라 스트림 URL");
    var snapshotUrl = normalizeCameraUrl(els.cameraSnapshotUrl.value, "카메라 스냅샷 URL");
    if (streamUrl) camera.stream_url = streamUrl;
    if (snapshotUrl) camera.snapshot_url = snapshotUrl;
    var localPort = parseRequiredPort(els.cameraLocalPort.value, "스위치 카메라 포트");
    if (localPort !== null) camera.local_port = localPort;
    var remotePort = parseRequiredPort(els.cameraRemotePort.value, "로봇 카메라 포트");
    if (remotePort !== null) camera.remote_port = remotePort;
    var route = els.cameraRoute.value.trim();
    if (route) camera.route = route;
    var label = els.cameraLabel.value.trim();
    if (label) camera.label = label;
    payload.camera = camera;
    return payload;
  }

  function submit(event) {
    event.preventDefault();
    var payload;
    try {
      payload = buildPayload();
    } catch (err) {
      setStatus(err.message, "error");
      return;
    }

    // Persist the 3D-model display preference (localStorage; read by the cockpit).
    try {
      if (els.model3dEnabled.checked) localStorage.removeItem(NO_3D_KEY);
      else localStorage.setItem(NO_3D_KEY, "1");
    } catch (_e) {}

    setSaveDisabled(true);
    setStatus("저장 중…", "busy");
    fetch("/api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    })
      .then(function (res) {
        return res.json().then(function (data) {
          return { ok: res.ok, data: data };
        });
      })
      .then(function (result) {
        if (!result.ok || !result.data || result.data.ok !== true) {
          var msg = (result.data && result.data.error) || "저장에 실패했어요.";
          throw new Error(msg);
        }
        setStatus("저장했어요. 조종석을 엽니다…", "ok");
        window.location.href = "/";
      })
      .catch(function (err) {
        setStatus(err.message || "저장에 실패했어요.", "error");
        setSaveDisabled(false);
      });
  }

  function openModelCheck() {
    window.location.href = "/model-check.html";
  }

  function openCockpit() {
    window.location.href = "/";
  }

  function handleShortcut(event) {
    if (isTypingTarget(document.activeElement)) {
      if (event.key === "Escape") document.activeElement.blur();
      return;
    }
    var key = String(event.key || "").toLowerCase();
    if (key === "arrowright" || key === "arrowdown") {
      event.preventDefault();
      focusNav(navIndex + 1);
      return;
    }
    if (key === "arrowleft" || key === "arrowup") {
      event.preventDefault();
      focusNav(navIndex - 1);
      return;
    }
    if (key === "enter" || key === " " || key === "a") {
      event.preventDefault();
      activateFocused();
      return;
    }
    if (key === "x") {
      event.preventDefault();
      runPreflight();
      return;
    }
    if (key === "y") {
      event.preventDefault();
      openModelCheck();
      return;
    }
    if (key === "+" || key === "=") {
      event.preventDefault();
      form.requestSubmit();
      return;
    }
    if (key === "b") {
      event.preventDefault();
      openCockpit();
    }
  }

  form.addEventListener("change", function (event) {
    if (event.target && event.target.name === "mode") syncSections();
    if (event.target && event.target.id === "model3d-enabled") renderModelCheckResult();
  });
  form.addEventListener("submit", submit);
  if (preflightBtn) preflightBtn.addEventListener("click", runPreflight);
  if (cameraTunnelBtn) cameraTunnelBtn.addEventListener("click", runCameraTunnelService);
  for (var i = 0; i < robotReadyButtons.length; i += 1) {
    robotReadyButtons[i].addEventListener("click", function (event) {
      var action = event.currentTarget && event.currentTarget.getAttribute("data-robot-ready");
      if (action) runRobotReady(action);
    });
  }
  document.addEventListener("focusin", function (event) {
    syncNavFromFocus(event.target);
  });
  window.addEventListener("keydown", handleShortcut);

  syncSections();
  ensureNavTabIndex();
  renderModelCheckResult();
  loadConfig();
  loadSystemHealth();
  loadRuntimeState();
  window.setTimeout(function () { focusNav(0); }, 80);
  window.setInterval(loadRuntimeState, 2000);
  window.setInterval(loadSystemHealth, 10000);

  if ("serviceWorker" in navigator) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("/sw.js").catch(function () {});
    });
  }
})();
