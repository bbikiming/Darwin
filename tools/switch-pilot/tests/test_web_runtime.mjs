import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

function makeElement(id) {
  const child = {
    className: "",
    style: {},
    textContent: "",
    addEventListener() {},
    focus() {},
  };
  return {
    id,
    className: "",
    dataset: {},
    style: {},
    textContent: "",
    innerHTML: "",
    addEventListener() {},
    focus() {},
    querySelector() {
      return child;
    },
    classList: {
      add() {},
      remove() {},
      toggle() {},
    },
    setAttribute() {},
    removeAttribute() {},
  };
}

function makeRuntime() {
  const elements = new Map();
  const getElement = (id) => {
    if (!elements.has(id)) elements.set(id, makeElement(id));
    return elements.get(id);
  };
  const intervals = [];
  const timeouts = [];
  const context = {
    console,
    Date,
    Error,
    JSON,
    Math,
    Number,
    String,
    Boolean,
    Array,
    Map,
    Set,
    RegExp,
    Promise,
    AbortController,
    navigator: {
      getGamepads() {
        return [];
      },
      serviceWorker: {
        register() {
          return Promise.resolve();
        },
      },
    },
    document: {
      body: {
        dataset: {},
        classList: {
          add() {},
          remove() {},
          toggle() {},
        },
        removeAttribute() {},
      },
      activeElement: null,
      getElementById: getElement,
      querySelector(selector) {
        if (selector.startsWith("[data-action=")) return null;
        return null;
      },
      querySelectorAll() {
        return [];
      },
      addEventListener() {},
    },
    window: {
      localStorage: {
        getItem() {
          return null;
        },
        setItem() {},
      },
      addEventListener() {},
      setTimeout(fn, _ms) {
        timeouts.push(fn);
        return timeouts.length;
      },
      clearTimeout() {},
      __darwinRobot3D: null,
    },
    setInterval(fn, ms) {
      intervals.push({fn, ms});
      return intervals.length;
    },
    setTimeout(fn, _ms) {
      timeouts.push(fn);
      return timeouts.length;
    },
    clearTimeout() {},
    __intervals: intervals,
  };
  context.window.document = context.document;
  context.window.navigator = context.navigator;
  context.window.fetch = (...args) => context.fetch(...args);
  return {context, elements, intervals};
}

function installScript(context) {
  vm.createContext(context);
  const code = fs.readFileSync(new URL("../web/app.js", import.meta.url), "utf8");
  vm.runInContext(code, context, {filename: "app.js"});
}

function deferredResponse(payload) {
  let resolve;
  const promise = new Promise((res) => {
    resolve = res;
  });
  return {
    promise,
    resolve() {
      resolve({
        ok: true,
        json() {
          return Promise.resolve(payload);
        },
      });
    },
  };
}

const payload = {
  mode: "dry_run",
  connected: true,
  target: "unit-test",
  local_ip: "127.0.0.1",
  updated_at_ms: Date.now(),
  uptime_sec: 1,
  input_status: "keyboard test",
  watchdog_label: "unit",
  controller: {left_x: 0, left_y: 0, right_x: 0, right_y: 0},
  command: {stride_mm: 0, turn_deg: 0, head_pan_deg: 0, head_tilt_deg: 0},
  armed: true,
  deadman: true,
  estopped: false,
  camera: {enabled: false},
  logs: [],
};

{
  const {context} = makeRuntime();
  const first = deferredResponse(payload);
  let calls = 0;
  context.fetch = (url) => {
    if (url === "/api/state") {
      calls += 1;
      return first.promise;
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  installScript(context);

  const a = context.refresh();
  const b = context.refresh();
  const c = context.refresh();
  assert.equal(calls, 1, "concurrent refresh calls must share one /api/state fetch");
  first.resolve();
  await Promise.all([a, b, c]);
  assert.equal(calls, 1, "resolving the shared refresh must not start another fetch");
  assert.equal(context.document.getElementById("mission-title").textContent, "준비 완료");
}

{
  const {context} = makeRuntime();
  const first = deferredResponse(payload);
  const second = deferredResponse({...payload, target: "second"});
  const responses = [first, second];
  let calls = 0;
  context.fetch = (url) => {
    if (url === "/api/state") {
      calls += 1;
      return responses.shift().promise;
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  installScript(context);

  const a = context.refresh();
  first.resolve();
  await a;
  const b = context.refresh();
  assert.equal(calls, 2, "a later refresh after settlement should start a new fetch");
  second.resolve();
  await b;
  assert.equal(context.document.getElementById("target").textContent, "second");
}

{
  const {context} = makeRuntime();
  context.fetch = () => {
    throw new Error("dashboard render test should not fetch");
  };
  installScript(context);

  let modelActive = null;
  let modelDisposed = false;
  context.window.__darwinRobot3D = {
    setActive(value) {
      modelActive = value;
    },
    dispose() {
      modelDisposed = true;
    },
  };
  context.setControlMode("model");
  context.setDashStyle("drive");
  context.render({
    ...payload,
    updated_at_ms: Date.now(),
    command: {stride_mm: 12.5, turn_deg: -6, head_pan_deg: 18, head_tilt_deg: -9},
    imu: {source: "robot", gyro_x: 120, gyro_y: -60, gyro_z: 30, accel_x: 550, accel_y: 480},
  });

  assert.equal(context.document.body.dataset.dashStyle, "drive");
  assert.equal(modelActive, null, "dashboard mode should bypass WebGL activation");
  assert.equal(modelDisposed, true, "dashboard mode must dispose the WebGL viewer");
  assert.equal(context.document.getElementById("camera-mode").textContent, "계기판 데이터 모드");
  assert.equal(context.document.getElementById("inst-speed").textContent, "50");
  assert.equal(context.document.getElementById("inst-speed-direction").textContent, "전진");
  assert.equal(context.document.getElementById("inst-turn").textContent, "-6.0°");
  assert.equal(context.document.getElementById("inst-imu-source").textContent, "로봇 IMU");
  assert.equal(context.document.getElementById("inst-balance-state").textContent, "수평");
}

{
  const {context} = makeRuntime();
  context.fetch = () => {
    throw new Error("camera recovery render test should not fetch");
  };
  installScript(context);

  context.setControlMode("camera");
  context.render({
    ...payload,
    mode: "ssh",
    connected: true,
    ssh_connected: false,
    target: "robotis@192.168.0.33",
    camera: {
      enabled: true,
      route: "ssh-tunnel",
      stream_url: "http://127.0.0.1:18080/?action=stream",
      snapshot_url: "http://127.0.0.1:18080/?action=snapshot",
    },
    camera_runtime: {status: "port_closed", local_port_open: false, port: 18080},
    updated_at_ms: Date.now(),
  });
  assert.notEqual(context.document.getElementById("camera-mode").textContent, "카메라 연결됨");

  context.render({
    ...payload,
    mode: "ssh",
    connected: true,
    ssh_connected: false,
    target: "robotis@192.168.0.33",
    camera: {
      enabled: true,
      route: "ssh-tunnel",
      stream_url: "http://127.0.0.1:18080/?action=stream",
      snapshot_url: "http://127.0.0.1:18080/?action=snapshot",
    },
    camera_runtime: {status: "port_open", local_port_open: true, port: 18080},
    updated_at_ms: Date.now(),
  });

  assert.notEqual(context.document.getElementById("camera-mode").textContent, "카메라 신호 없음");
  assert.notEqual(context.document.getElementById("camera-service-state").textContent, "터널 포트 닫힘 :18080");
  assert.equal(context.document.getElementById("fpv-link").textContent, "SSH LOCK");
  assert.match(context.document.getElementById("camera-stream").src, /api\/camera-frame\.jpg/);
}

console.log("web runtime single-flight tests OK");
