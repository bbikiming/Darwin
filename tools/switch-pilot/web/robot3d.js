// Live WebGL view of the real ROBOTIS DARwIn-OP for the cockpit's camera
// fallback. Loads a single pre-assembled, vertex-welded GLB (baked offline from
// the STL parts + URDF rig — see robot3d-rig.js / build-glb.html), so the
// runtime needs no STL parsing or rig math. Kept defeatable + paused when the
// camera is live, because the Switch's Tegra GPU is weak (never run WebGL +
// MJPEG together). Vendored Three.js only (no CDN); ES module + import map.

import * as THREE from "./vendor/three.module.min.js";
import { GLTFLoader } from "./vendor/GLTFLoader.js";

const MODEL_URL = "./assets/darwin.glb";
const D2R = Math.PI / 180;

function frameCamera(camera, target, object) {
  const box = new THREE.Box3().setFromObject(object);
  if (box.isEmpty()) return;
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  const maxDim = Math.max(size.x, size.y, size.z);
  const dist = (maxDim / (2 * Math.tan((camera.fov * D2R) / 2))) * 1.05;
  // Front 3/4 view (the robot faces -Z after the rig's root rotation).
  camera.position.set(center.x - dist * 0.5, center.y + size.y * 0.12, center.z - dist);
  camera.near = dist / 50;
  camera.far = dist * 50;
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
  const { autoRotate = true, onReady = null } = opts;
  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: "low-power" });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5)); // cap for weak GPU
  renderer.setSize(container.clientWidth || 640, container.clientHeight || 480, false);
  renderer.setClearColor(0x000000, 0);
  container.appendChild(renderer.domElement);
  renderer.domElement.style.cssText = "width:100%;height:100%;display:block";

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(38, (container.clientWidth || 640) / (container.clientHeight || 480), 0.01, 100);
  const target = new THREE.Vector3();

  scene.add(new THREE.HemisphereLight(0xbfe3ff, 0x202830, 1.05));
  const key = new THREE.DirectionalLight(0xffffff, 1.5);
  key.position.set(0.6, 1.0, 0.8);
  scene.add(key);
  const rim = new THREE.DirectionalLight(0x66ccff, 0.6);
  rim.position.set(-0.8, 0.3, -0.6);
  scene.add(rim);

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
  frameCamera(camera, target, model);
  camera.lookAt(target);
  renderer.render(scene, camera); // guaranteed first frame (don't wait for RAF).
  if (typeof onReady === "function") onReady();

  let active = true;
  let raf = 0;
  let last = 0;
  const FRAME_MS = 1000 / 30; // cap 30fps — Tegra friendly.

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
    last = t;
    if (autoRotate) model.rotation.y += 0.006;
    camera.lookAt(target);
    renderer.render(scene, camera);
  }
  raf = requestAnimationFrame(loop);

  return {
    setActive(on) {
      active = !!on;
      if (active && !raf) raf = requestAnimationFrame(loop);
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
