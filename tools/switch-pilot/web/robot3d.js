// Live WebGL view of the real ROBOTIS DARwIn-OP for the cockpit's camera
// fallback. Loads a single pre-assembled, vertex-welded GLB (baked offline from
// the STL parts + URDF rig — see robot3d-rig.js / build-glb.html), so the
// runtime needs no STL parsing or rig math. Kept defeatable + paused when the
// camera is live, because the Switch's Tegra GPU is weak (never run WebGL +
// MJPEG together). Vendored Three.js only (no CDN, no import map dependency).

import * as THREE from "./vendor/three.module.min.js";
import { GLTFLoader } from "./vendor/GLTFLoader.js";

const MODEL_URL = "./assets/darwin.glb";
const D2R = Math.PI / 180;

const CAMERA_VIEWS = {
  "front-3q": { x: -0.5, y: 0.12, z: -1 },
  front: { x: 0, y: 0.1, z: -1 },
  left: { x: -1, y: 0.1, z: 0 },
  right: { x: 1, y: 0.1, z: 0 },
  rear: { x: 0, y: 0.1, z: 1 },
};

function frameCamera(camera, target, object, view = "front-3q", distanceScale = 1.05) {
  const box = new THREE.Box3().setFromObject(object);
  if (box.isEmpty()) return;
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  const maxDim = Math.max(size.x, size.y, size.z);
  const dist = (maxDim / (2 * Math.tan((camera.fov * D2R) / 2))) * distanceScale;
  const offset = CAMERA_VIEWS[view] || CAMERA_VIEWS["front-3q"];
  camera.position.set(
    center.x + (dist * offset.x),
    center.y + (size.y * offset.y),
    center.z + (dist * offset.z),
  );
  camera.near = dist / 50;
  camera.far = dist * 50;
  camera.up.set(0, 1, 0);
  camera.updateProjectionMatrix();
  camera.lookAt(center);
  target.copy(center);
}

/**
 * Mount the robot viewer into `container`. Returns { setActive, dispose }.
 * setActive(false) stops the render loop (call when the camera goes live).
 * Rejects if WebGL or the GLB is unavailable — callers fall back to the figure.
 */
export async function mountRobot(container, opts = {}) {
  const {
    autoRotate = true,
    cameraView = "front-3q",
    distanceScale = 1.05,
    lighting = "cockpit",
    onFrame = null,
    onReady = null,
  } = opts;
  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: "low-power" });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5)); // cap for weak GPU
  renderer.setSize(container.clientWidth || 640, container.clientHeight || 480, false);
  renderer.setClearColor(0x000000, 0);
  container.appendChild(renderer.domElement);
  renderer.domElement.style.cssText = "width:100%;height:100%;display:block";

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(38, (container.clientWidth || 640) / (container.clientHeight || 480), 0.01, 100);
  const target = new THREE.Vector3();
  const inspection = lighting === "inspection";

  scene.add(new THREE.HemisphereLight(0xbfe3ff, 0x202830, inspection ? 1.32 : 1.05));
  const key = new THREE.DirectionalLight(0xffffff, inspection ? 1.8 : 1.5);
  key.position.set(0.6, 1.0, 0.8);
  scene.add(key);
  const rim = new THREE.DirectionalLight(0x66ccff, inspection ? 0.8 : 0.6);
  rim.position.set(-0.8, 0.3, -0.6);
  scene.add(rim);
  const cameraFill = new THREE.DirectionalLight(0xdff7ff, inspection ? 1.05 : 0.35);
  scene.add(cameraFill);

  let model;
  try {
    const gltf = await new GLTFLoader().loadAsync(MODEL_URL);
    model = gltf.scene;
  } catch (err) {
    renderer.dispose();
    if (renderer.domElement.parentNode) renderer.domElement.parentNode.removeChild(renderer.domElement);
    throw err; // let the cockpit keep the CSS figure.
  }
  scene.add(model);
  frameCamera(camera, target, model, cameraView, distanceScale);
  cameraFill.position.copy(camera.position).sub(target).normalize();
  camera.lookAt(target);
  renderer.render(scene, camera); // guaranteed first frame (don't wait for RAF).
  if (typeof onReady === "function") onReady();

  let active = true;
  let raf = 0;
  let last = 0;
  const FRAME_MS = 1000 / 30; // cap 30fps — Tegra friendly.

  function renderFrame(t, deltaMs = 0) {
    if (autoRotate) model.rotation.y += 0.006;
    camera.lookAt(target);
    renderer.render(scene, camera);
    if (typeof onFrame === "function") {
      onFrame({ timeMs: t, deltaMs, active });
    }
  }

  function resize() {
    const w = container.clientWidth || 640;
    const h = container.clientHeight || 480;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  }
  const ro = new ResizeObserver(resize);
  ro.observe(container);

  function loop(t) {
    raf = requestAnimationFrame(loop);
    if (!active) return;
    if (t - last < FRAME_MS) return;
    const deltaMs = last > 0 ? t - last : 0;
    last = t;
    renderFrame(t, deltaMs);
  }
  raf = requestAnimationFrame(loop);

  return {
    setActive(on) {
      active = !!on;
      if (active) {
        resize();
        renderFrame(performance.now(), 0);
        if (!raf) raf = requestAnimationFrame(loop);
      }
    },
    dispose() {
      active = false;
      cancelAnimationFrame(raf);
      ro.disconnect();
      renderer.dispose();
      if (renderer.domElement.parentNode) renderer.domElement.parentNode.removeChild(renderer.domElement);
    },
  };
}
