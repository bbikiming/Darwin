"use strict";

// First-boot provisioning form. Loads current config, lets the user pick a
// mode + targets, POSTs to /api/config, then redirects to the cockpit.
// No external libraries (matches cockpit constraints).

(function () {
  var form = document.getElementById("setup-form");
  var statusEl = document.getElementById("status");
  var saveBtn = document.getElementById("save-btn");
  var macSection = document.getElementById("mac-section");
  var robotSection = document.getElementById("robot-section");
  var sshSection = document.getElementById("ssh-section");

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
    model3dEnabled: document.getElementById("model3d-enabled"),
  };

  // The 3D robot model is a client display preference (localStorage), separate
  // from the device config POST. Reflect the current setting (default: on).
  try { els.model3dEnabled.checked = !localStorage.getItem("darwinNo3D"); } catch (_e) {}

  function setStatus(text, kind) {
    statusEl.textContent = text || "";
    statusEl.className = kind || "";
  }

  function selectedMode() {
    var checked = form.querySelector('input[name="mode"]:checked');
    return checked ? checked.value : "dry_run";
  }

  // Show only the section relevant to the chosen mode.
  function syncSections() {
    var mode = selectedMode();
    macSection.classList.toggle("hidden", mode !== "mac_relay");
    robotSection.classList.toggle("hidden", mode !== "robot_udp");
    sshSection.classList.toggle("hidden", mode !== "ssh");
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

  function parsePort(raw) {
    var trimmed = (raw || "").trim();
    if (trimmed === "") return null;
    var num = Number(trimmed);
    if (!Number.isInteger(num) || num < 0 || num > 65535) {
      throw new Error("포트는 0~65535 사이의 정수여야 해요.");
    }
    return num;
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

    payload.camera = { enabled: els.cameraEnabled.checked };
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
      if (els.model3dEnabled.checked) localStorage.removeItem("darwinNo3D");
      else localStorage.setItem("darwinNo3D", "1");
    } catch (_e) {}

    saveBtn.disabled = true;
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
        saveBtn.disabled = false;
      });
  }

  form.addEventListener("change", function (event) {
    if (event.target && event.target.name === "mode") syncSections();
  });
  form.addEventListener("submit", submit);

  syncSections();
  loadConfig();
})();
