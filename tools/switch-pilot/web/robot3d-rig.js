// BUILD-TIME ONLY — assembles the DARwIn-OP from the raw STL parts following
// the Mac app's MeshRig.swift (URDF joint origins/axes/rpy). Used by
// build-glb.html to bake assets/darwin.glb. The cockpit runtime does NOT load
// this (it loads the baked GLB via robot3d.js), so the STL parts + STLLoader
// never ship to the Switch. Re-bake: serve the repo with the bake server
// (maps /meshes/ -> vendor/robotis-op2-common/meshes) and open build-glb.html.

import * as THREE from "./vendor/three.module.min.js";
import { STLLoader } from "./vendor/STLLoader.js";

const MESH_DIR = "/meshes/"; // bake server maps this to the vendored STL source.
const PI = Math.PI;
const D2R = PI / 180;

function linkColor(name) {
  if (name.includes("head")) return 0x525252;
  if (name.includes("foot")) return 0x2e2e2e;
  if (name.includes("ankle")) return 0x404040;
  if (name.includes("body")) return 0xc7c7c7;
  if (name.includes("shoulder") || name.includes("hip")) return 0x858585;
  return 0xbdbdbd;
}

function frame(parent, origin, rpy) {
  const f = new THREE.Group();
  f.position.set(origin[0], origin[1], origin[2]);
  if (rpy) f.rotation.set(rpy[0], rpy[1], rpy[2]);
  parent.add(f);
  const anchor = new THREE.Group();
  f.add(anchor);
  return anchor;
}

function attachMesh(loader, parent, name, opts = {}) {
  const { originZ = 0, rpy = null, applyDefaultZ = true } = opts;
  return new Promise((resolve) => {
    loader.load(
      MESH_DIR + name + ".stl",
      (geom) => {
        geom.computeVertexNormals();
        const mat = new THREE.MeshStandardMaterial({
          color: linkColor(name), metalness: 0.12, roughness: 0.62,
        });
        const mesh = new THREE.Mesh(geom, mat);
        mesh.scale.setScalar(0.001);
        if (rpy) mesh.rotation.set(rpy[0], rpy[1], rpy[2]);
        else if (applyDefaultZ) mesh.rotation.set(0, 0, -PI / 2);
        mesh.position.set(0, 0, originZ);
        parent.add(mesh);
        resolve(mesh);
      },
      undefined,
      () => resolve(null)
    );
  });
}

export function buildRig(loader) {
  const root = new THREE.Group();
  root.quaternion.setFromAxisAngle(new THREE.Vector3(-1, 1, 1).normalize(), (2 * PI) / 3);
  root.position.set(0, 0.265, 0);

  const body = new THREE.Group();
  root.add(body);
  const jobs = [attachMesh(loader, body, "geo_op_body")];

  const headPan = frame(body, [0, 0, 0.0205]);
  jobs.push(attachMesh(loader, headPan, "geo_op_neck", { originZ: 0.03 }));
  const headTilt = frame(headPan, [0, 0, 0.03], [0, 33 * D2R, 0]);
  jobs.push(attachMesh(loader, headTilt, "geo_op_head",
    { rpy: [0, PI, PI / 2], applyDefaultZ: false }));

  for (const side of ["left", "right"]) {
    const yMul = side === "left" ? 1 : -1;
    const sgn = side === "left" ? 1 : -1;
    const shoP = frame(body, [0, yMul * 0.0575, 0]);
    jobs.push(attachMesh(loader, shoP, `geo_op_${side}_shoulder`));
    const shoR = frame(shoP, [0, yMul * 0.0245, -0.016], [sgn * 45 * D2R, 0, 0]);
    jobs.push(attachMesh(loader, shoR, `geo_op_${side}_upper-arm`));
    const elbow = frame(shoR, [0.016, 0, -0.06], [0, -PI / 2, 0]);
    jobs.push(attachMesh(loader, elbow, `geo_op_${side}_lower-arm`));

    const yaw = frame(body, [-0.005, yMul * 0.037, -0.0907]);
    jobs.push(attachMesh(loader, yaw, `geo_op_${side}_hip-yaw`));
    const roll = frame(yaw, [0, 0, -0.0315]);
    jobs.push(attachMesh(loader, roll, `geo_op_${side}_hip-roll`));
    const pitch = frame(roll, [0, 0, 0]);
    jobs.push(attachMesh(loader, pitch, `geo_op_${side}_thigh`));
    const knee = frame(pitch, [0, 0, -0.093]);
    const shinZ = side === "right" ? -0.093 : 0;
    jobs.push(attachMesh(loader, knee, `geo_op_${side}_shin`, { originZ: shinZ }));
    const ankP = frame(knee, [0, 0, -0.093]);
    jobs.push(attachMesh(loader, ankP, `geo_op_${side}_ankle`));
    jobs.push(attachMesh(loader, ankP, `geo_op_${side}_foot`));
  }

  return { root, ready: Promise.all(jobs) };
}

export { STLLoader };
