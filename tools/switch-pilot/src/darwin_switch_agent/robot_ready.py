from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .config import AgentConfig
from .ssh_control_client import (
    CMD_PATH,
    DEFAULT_HOST,
    DEFAULT_IDENTITY,
    DEFAULT_USER,
    ESTOP_PATH,
    PILOT_MODE_PATH,
    ssh_args,
)

DEFAULT_CONFIG = Path("/etc/darwin-switch-agent/config.json")
DEFAULT_ROOT = Path("/opt/darwin-switch-agent")

REMOTE_STATUS_SCRIPT = r"""
set +e
echo "DF_READY_STATUS=begin"
echo "host=$(hostname 2>/dev/null || uname -n)"
echo "user=$(id -un 2>/dev/null)"
echo "kernel=$(uname -srmo 2>/dev/null)"
BIN=""
OLD_PATCH=""
for d in "$HOME/Framework/Linux/project/demo/demo-pilot" \
         "$HOME/darwin/Linux/project/demo/demo-pilot" \
         "/darwin/Linux/project/demo/demo-pilot" \
         "/robotis/Linux/project/demo/demo-pilot" \
         "$HOME/Framework/Linux/project/demo/demo" \
         "$HOME/darwin/Linux/project/demo/demo" \
         "/darwin/Linux/project/demo/demo" \
         "/robotis/Linux/project/demo/demo"; do
  if [ -x "$d" ]; then
    if grep -qa "ROBOTIS onboard brokerage, switch fix" "$d" 2>/dev/null; then BIN="$d"; break; fi
    if [ -z "$OLD_PATCH" ] && grep -qa "df-walklab-cmd" "$d" 2>/dev/null; then OLD_PATCH="$d"; fi
  fi
done
if [ -n "$BIN" ]; then
  echo "demo_binary=$BIN"
  echo "walklab_patch=present"
elif [ -n "$OLD_PATCH" ]; then
  echo "demo_binary=$OLD_PATCH"
  echo "walklab_patch=old"
else
  echo "demo_binary=missing"
  echo "walklab_patch=missing"
fi
if pgrep -x demo-pilot >/dev/null 2>&1; then
  echo "demo_process=demo-pilot:$(pgrep -x demo-pilot | tr '\n' ',')"
elif pgrep -x demo >/dev/null 2>&1; then
  echo "demo_process=demo:$(pgrep -x demo | tr '\n' ',')"
else
  echo "demo_process=none"
fi
for f in /tmp/df-pilot-mode /tmp/df-walklab-cmd /tmp/df-walklab-ack /tmp/df-walklab-telemetry /tmp/df-walklab-estop; do
  if [ -e "$f" ]; then
    ls -l "$f" 2>/dev/null | sed "s#^#file=#"
  else
    echo "file=$f missing"
  fi
done
echo "DF_READY_STATUS=end"
"""

REMOTE_START_WALKLAB_SCRIPT = r"""
set +e
rm -f /tmp/df-walklab-estop 2>/dev/null
sudo killall socat 2>/dev/null
sleep 0.3

camera_port_open() {
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | grep -q ':8080'
  else
    netstat -lnt 2>/dev/null | grep -q ':8080'
  fi
}

stop_camera_stream() {
  echo "DF_READY_CAMERA_STOP=begin"
  sudo killall camera_tutorial vision_demo 2>/dev/null || killall camera_tutorial vision_demo 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    pgrep -x camera_tutorial >/dev/null 2>&1 || pgrep -x vision_demo >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x camera_tutorial >/dev/null 2>&1 || pgrep -x vision_demo >/dev/null 2>&1; then
    echo "DF_READY_CAMERA_STOP=warn_still_running"
    pgrep -af 'camera_tutorial|vision_demo' 2>/dev/null
  else
    echo "DF_READY_CAMERA_STOP=ok"
  fi
}

start_camera_stream() {
  CAM_DIR=""
  for d in "$HOME/Framework/Linux/project/tutorial/camera" \
           "$HOME/darwin/Linux/project/tutorial/camera" \
           "/darwin/Linux/project/tutorial/camera" \
           "/robotis/Linux/project/tutorial/camera"; do
    if [ -d "$d" ]; then CAM_DIR="$d"; break; fi
  done
  if [ -z "$CAM_DIR" ]; then
    echo "DF_READY_CAMERA=missing"
    echo "camera tutorial directory not found"
    return 0
  fi
  cd "$CAM_DIR" || { echo "DF_READY_CAMERA=bad_dir"; return 0; }
  if [ ! -x ./camera_tutorial ]; then
    echo "DF_READY_CAMERA=build"
    make >/tmp/df-camera-build.log 2>&1 || {
      echo "DF_READY_CAMERA=build_failed"
      tail -30 /tmp/df-camera-build.log 2>/dev/null
      return 0
    }
  fi
  if camera_port_open; then
    echo "DF_READY_CAMERA=already_running"
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    nohup sudo -n ./camera_tutorial >/tmp/df-camera.log 2>&1 &
  else
    nohup ./camera_tutorial >/tmp/df-camera.log 2>&1 &
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    camera_port_open && { echo "DF_READY_CAMERA=running"; return 0; }
    sleep 0.2
  done
  echo "DF_READY_CAMERA=start_failed"
  tail -40 /tmp/df-camera.log 2>/dev/null
  return 0
}

stop_camera_stream

BIN=""
OLD_PATCH=""
for d in "$HOME/Framework/Linux/project/demo/demo-pilot" \
         "$HOME/darwin/Linux/project/demo/demo-pilot" \
         "/darwin/Linux/project/demo/demo-pilot" \
         "/robotis/Linux/project/demo/demo-pilot" \
         "$HOME/Framework/Linux/project/demo/demo" \
         "$HOME/darwin/Linux/project/demo/demo" \
         "/darwin/Linux/project/demo/demo" \
         "/robotis/Linux/project/demo/demo"; do
  if [ -x "$d" ]; then
    if grep -qa "ROBOTIS onboard brokerage, switch fix" "$d" 2>/dev/null; then BIN="$d"; break; fi
    if [ -z "$OLD_PATCH" ] && grep -qa "df-walklab-cmd" "$d" 2>/dev/null; then OLD_PATCH="$d"; fi
  fi
done
if [ -z "$BIN" ]; then
  if [ -n "$OLD_PATCH" ]; then
    echo "DF_READY_START=old_walklab_patch"
    echo "old_demo_binary=$OLD_PATCH"
    echo "구버전 WalkLab patch 감지 — switch fix 성공 버전으로 demo 재빌드가 필요합니다."
    exit 4
  fi
  echo "DF_READY_START=missing_walklab_patch"
  echo "switch fix WalkLab demo / demo-pilot binary not found"
  exit 4
fi

mkdir -p ~/.config/darwinforge 2>/dev/null
echo walklab > ~/.config/darwinforge/pilot-mode 2>/dev/null
echo walklab > /tmp/df-pilot-mode
: > /tmp/df-walklab-cmd
chmod 0666 /tmp/df-walklab-cmd 2>/dev/null
rm -f /tmp/df-walklab-ack 2>/dev/null

sudo killall demo demo-pilot walk_demo action_editor 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  pgrep -x demo >/dev/null 2>&1 || pgrep -x demo-pilot >/dev/null 2>&1 || break
  sleep 0.2
done
sleep 1.5

cd "$(dirname "$BIN")" || exit 5
nohup sudo -n "$BIN" >/tmp/df-demo.log 2>&1 &
sleep 1

PROC="$(pgrep -x "$(basename "$BIN")" 2>/dev/null | head -1)"
if [ -n "$PROC" ]; then
  echo "DF_READY_START=walklab_running"
  echo "demo_binary=$BIN"
  echo "pid=$PROC"
  tail -10 /tmp/df-demo.log 2>/dev/null
  start_camera_stream
else
  echo "DF_READY_START=start_failed"
  tail -40 /tmp/df-demo.log 2>/dev/null
  exit 6
fi
"""


@dataclass(frozen=True)
class RobotSshConfig:
    host: str
    user: str
    port: int
    identity_file: str | None
    timeout_seconds: int
    connect_timeout_seconds: int


def load_config(config_path: Path, root: Path = DEFAULT_ROOT) -> AgentConfig:
    if config_path.is_file():
        return AgentConfig.load(str(config_path))
    fallback = root / "config.example.json"
    if fallback.is_file():
        return AgentConfig.load(str(fallback))
    return AgentConfig({"ssh": {}})


def robot_ssh_config(
    config: AgentConfig,
    *,
    host_override: str | None = None,
    user_override: str | None = None,
    port_override: int | None = None,
) -> RobotSshConfig:
    """Build the robot SSH config from the agent config, with optional overrides.

    The overrides exist so the **Mac DarwinForge "Switch Robot Link" wizard** can
    point the Switch at a robot IP it can actually *route to* — the deployed
    config often defaults to the wired direct-ethernet IP (192.168.123.1), which
    is unreachable from the Switch on Wi-Fi. `enable-agent-ssh` then persists the
    overridden host, closing the network half of the bridge (not just the key
    half). Empty/blank overrides fall back to the config value.
    """
    ssh = config.section("ssh")
    identity = str(ssh.get("identity_file", DEFAULT_IDENTITY)).strip()
    host = (host_override or "").strip() or str(ssh.get("host", DEFAULT_HOST)).strip() or DEFAULT_HOST
    user = (user_override or "").strip() or str(ssh.get("user", DEFAULT_USER)).strip() or DEFAULT_USER
    port = int(port_override) if port_override else int(ssh.get("port", 22))
    return RobotSshConfig(
        host=host,
        user=user,
        port=port,
        identity_file=identity or None,
        timeout_seconds=int(ssh.get("timeout_seconds", 6)),
        connect_timeout_seconds=int(ssh.get("connect_timeout_seconds", 2)),
    )


def tcp_reachable(host: str, port: int, timeout: float) -> bool:
    """True if a TCP connection to host:port opens within `timeout` seconds.

    Run **on the Switch** (via SSH from the Mac) to discover which robot IP the
    Switch can actually route to — the key-distribution half of the bridge is
    useless if the Switch can't reach the robot at all.
    """
    import socket

    try:
        with socket.create_connection((host, int(port)), timeout=float(timeout)):
            return True
    except OSError:
        return False


def cmd_reachability(candidates: list[str], port: int, timeout: float) -> int:
    """Probe each candidate robot IP for TCP reachability from this host (Switch).

    Output contract (Mac wizard parses):
      reach=<ip>:<port> open|closed     (one per candidate)
      DF_REACHABLE=<first-reachable-ip>  OR  DF_REACHABLE=none
      DF_REACHABLE_ALL=<csv of reachable> (only when at least one is reachable)
    """
    reachable: list[str] = []
    for raw in candidates:
        host = raw.strip()
        if not host:
            continue
        ok = tcp_reachable(host, port, timeout)
        print(f"reach={host}:{port} {'open' if ok else 'closed'}")
        if ok:
            reachable.append(host)
    if reachable:
        print(f"DF_REACHABLE={reachable[0]}")
        print(f"DF_REACHABLE_ALL={','.join(reachable)}")
        return 0
    print("DF_REACHABLE=none")
    return 1


def expanded_identity(path: str | None) -> Path | None:
    if not path:
        return None
    return Path(os.path.expanduser(path))


def ensure_identity(identity: Path) -> bool:
    if identity.is_file() and identity.with_suffix(identity.suffix + ".pub").is_file():
        return False
    identity.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    subprocess.run(
        [
            "ssh-keygen",
            "-t",
            "rsa",
            "-b",
            "2048",
            "-N",
            "",
            "-f",
            str(identity),
            "-C",
            "darwin-switch-robot",
        ],
        check=True,
    )
    return True


def run_ssh(
    cfg: RobotSshConfig,
    command: str,
    *,
    timeout: int | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    ssh_bin = shutil.which("ssh") or "/usr/bin/ssh"
    identity = expanded_identity(cfg.identity_file)
    identity_arg = str(identity) if identity and identity.is_file() else None
    args = [ssh_bin] + ssh_args(
        cfg.host,
        cfg.user,
        command,
        identity_arg,
        timeout if timeout is not None else cfg.timeout_seconds,
        port=cfg.port,
    )
    eff_timeout = timeout if timeout is not None else cfg.timeout_seconds
    try:
        return subprocess.run(
            args,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=eff_timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        # Clean degradation (2026-06-07): never crash the CLI with a traceback on
        # a slow link. Return a non-zero CompletedProcess so callers report a
        # readable WARN. Note: a backgrounded `nohup ... &` (e.g. start-walklab)
        # may still have launched on the robot — callers should re-check status.
        out = exc.stdout if isinstance(exc.stdout, str) else (exc.stdout.decode() if exc.stdout else "")
        err = exc.stderr if isinstance(exc.stderr, str) else (exc.stderr.decode() if exc.stderr else "")
        err = (err + f"\nssh timed out after {eff_timeout}s").strip()
        return subprocess.CompletedProcess(args=args, returncode=124, stdout=out, stderr=err)


def copy_key_command(cfg: RobotSshConfig) -> list[str]:
    identity = expanded_identity(cfg.identity_file)
    if identity is None:
        identity = Path(os.path.expanduser(DEFAULT_IDENTITY))
    pub = Path(str(identity) + ".pub")
    return [
        "ssh-copy-id",
        "-o",
        "PubkeyAcceptedAlgorithms=+ssh-rsa",
        "-o",
        "HostKeyAlgorithms=+ssh-rsa",
        "-i",
        str(pub),
        "-p",
        str(cfg.port),
        f"{cfg.user}@{cfg.host}",
    ]


def print_process(proc: subprocess.CompletedProcess[str]) -> None:
    if proc.stdout:
        print(proc.stdout.rstrip())
    if proc.stderr:
        print(proc.stderr.rstrip(), file=sys.stderr)


def _line(title: str, detail: str) -> None:
    print(f"{title}: {detail}")


def cmd_plan(cfg: RobotSshConfig) -> int:
    identity = expanded_identity(cfg.identity_file)
    _line("Robot SSH target", f"{cfg.user}@{cfg.host}:{cfg.port}")
    _line("Identity", str(identity) if identity else "(ssh default)")
    _line("Protocol", "DarwinForge parity: BatchMode, accept-new known_hosts, ServerAlive 2x2, +ssh-rsa, ControlMaster when identity exists")
    _line("Control contract", f"{PILOT_MODE_PATH}=walklab, {CMD_PATH}=14-token atomic writes, {ESTOP_PATH}=presence stop")
    _line("Copy key command", " ".join(copy_key_command(cfg)))
    _line("Final switch command", "darwin-switch-robot-ready all")
    return 0


def cmd_keygen(cfg: RobotSshConfig) -> int:
    identity = expanded_identity(cfg.identity_file)
    if identity is None:
        identity = Path(os.path.expanduser(DEFAULT_IDENTITY))
    created = ensure_identity(identity)
    _line("Identity", str(identity))
    _line("Status", "created" if created else "already present")
    return 0


def cmd_copy_key(cfg: RobotSshConfig) -> int:
    identity = expanded_identity(cfg.identity_file) or Path(os.path.expanduser(DEFAULT_IDENTITY))
    ensure_identity(identity)
    command = copy_key_command(cfg)
    print("+ " + " ".join(command))
    proc = subprocess.run(command, text=True, check=False)
    return int(proc.returncode)


def cmd_probe(cfg: RobotSshConfig) -> int:
    proc = run_ssh(cfg, "echo ok", timeout=cfg.connect_timeout_seconds)
    print_process(proc)
    if proc.returncode == 0 and proc.stdout.strip() == "ok":
        print("Robot SSH auth: OK")
        return 0
    print("Robot SSH auth: WARN", file=sys.stderr)
    return 1


def cmd_status(cfg: RobotSshConfig) -> int:
    proc = run_ssh(cfg, REMOTE_STATUS_SCRIPT)
    print_process(proc)
    if proc.returncode != 0:
        return int(proc.returncode)
    if "walklab_patch=present" not in proc.stdout:
        print("Robot WalkLab patch: MISSING", file=sys.stderr)
        return 1
    print("Robot WalkLab patch: OK")
    return 0


# start-walklab restarts demo on the robot: kill socat/demo + wait up to ~4s for
# exit + 1.5s settle + nohup launch + 1s verify. Over slow Wi-Fi that easily
# exceeds 10s, so the client timeout must be generous (2026-06-07 fix — was 10s,
# which raised a false "start failed" while the demo had actually launched).
START_WALKLAB_TIMEOUT = 45


def cmd_start_walklab(cfg: RobotSshConfig) -> int:
    proc = run_ssh(cfg, REMOTE_START_WALKLAB_SCRIPT,
                   timeout=max(START_WALKLAB_TIMEOUT, cfg.timeout_seconds))
    print_process(proc)
    if proc.returncode == 0 and "DF_READY_START=walklab_running" in proc.stdout:
        print("Robot WalkLab start: OK")
        return 0
    if proc.returncode == 124:
        # Timed out — the backgrounded demo may still have started. Tell the
        # caller to verify via `status`/liveness rather than assume failure.
        print("Robot WalkLab start: TIMEOUT — demo 가 백그라운드로 떴을 수 있어요. "
              "잠시 후 `status` 또는 로봇 demo 프로세스를 확인하세요.", file=sys.stderr)
        return 124
    print("Robot WalkLab start: WARN", file=sys.stderr)
    return int(proc.returncode or 1)


def absolute_identity_file(identity: str | None) -> str:
    """Resolve the identity path to an ABSOLUTE path for systemd-safe storage.

    **Critical real-hardware bug (2026-06-07):** `darwin-switch-agent` runs as a
    systemd service. A stored `~/.ssh/id_rsa_darwin` expands to `/root/.ssh/...`
    under systemd (not the Switch user's home), so the key is "not found" and
    `ssh_connected` stays false. The fix: never persist a `~`; store the absolute
    path resolved against the user running the CLI (the Switch user, e.g.
    `/home/yuseok/.ssh/id_rsa_darwin`). The CLI runs as that user, so
    `expanduser` resolves correctly here even though systemd would not.
    """
    raw = (identity or DEFAULT_IDENTITY).strip() or DEFAULT_IDENTITY
    expanded = os.path.expanduser(raw)
    # If it still begins with ~ (no HOME), fall back to the invoking user's home.
    if expanded.startswith("~"):
        home = os.path.expanduser("~")
        expanded = expanded.replace("~", home, 1)
    return os.path.abspath(expanded)


def _agent_config_payload(config_path: Path, cfg: RobotSshConfig) -> str:
    if config_path.is_file():
        with config_path.open("r", encoding="utf-8") as fp:
            raw = json.load(fp)
    else:
        raw = {}
    if not isinstance(raw, dict):
        raise ValueError(f"{config_path} must contain a JSON object")
    ssh = raw.get("ssh", {})
    ssh = ssh if isinstance(ssh, dict) else {}
    ssh.update(
        {
            "host": cfg.host,
            "user": cfg.user,
            "port": cfg.port,
            # Absolute path — never persist `~` (systemd would expand it to /root).
            "identity_file": absolute_identity_file(cfg.identity_file),
            "connect_timeout_seconds": cfg.connect_timeout_seconds,
            "timeout_seconds": cfg.timeout_seconds,
        }
    )
    raw["mode"] = "ssh"
    raw["ssh"] = ssh
    return json.dumps(raw, ensure_ascii=False, indent=2) + "\n"


# Conservative "stability-first" tuning for early real-robot testing — lowers
# SSH/Wi-Fi pressure (send/telemetry/heartbeat) and makes the gait speed ramp
# gentler (dynamic period/foot bounds). Applied via the `stabilize` subcommand.
STABILIZE_DEFAULTS: dict[str, Any] = {
    "send_hz": 5,
    "telemetry_hz": 1,
    "heartbeat_ms": 900,
    "timeout_seconds": 8,
    "connect_timeout_seconds": 3,
    "min_period_ms": 500,
    "max_period_ms": 860,
    "min_foot_mm": 16,
    "stride_ref_mm": 38,
    "turn_ref_deg": 14,
}


STABILIZE_MOTION_DEFAULTS: dict[str, Any] = {
    "max_stride_mm": 38,
    "max_side_mm": 22,
    "max_turn_deg": 14,
    "turn_from_side_ratio": 0.75,
    "hold_head_position": True,
    "drive_curve": 1.35,
    "speed_scale": 0.8,
}


def _stabilize_payload(config_path: Path, cfg: RobotSshConfig) -> str:
    """Merge the stability-first tuning into the ssh section (host/identity kept
    absolute and routable). Preserves mode if already ssh; does not force it."""
    if config_path.is_file():
        with config_path.open("r", encoding="utf-8") as fp:
            raw = json.load(fp)
    else:
        raw = {}
    if not isinstance(raw, dict):
        raise ValueError(f"{config_path} must contain a JSON object")
    ssh = raw.get("ssh", {})
    ssh = ssh if isinstance(ssh, dict) else {}
    ssh.update(STABILIZE_DEFAULTS)
    ssh["host"] = cfg.host
    ssh["user"] = cfg.user
    ssh["port"] = cfg.port
    ssh["identity_file"] = absolute_identity_file(cfg.identity_file)
    raw["ssh"] = ssh
    motion = raw.get("motion", {})
    motion = motion if isinstance(motion, dict) else {}
    motion.update(STABILIZE_MOTION_DEFAULTS)
    raw["motion"] = motion
    return json.dumps(raw, ensure_ascii=False, indent=2) + "\n"


def _atomic_write_config(config_path: Path, text: str) -> bool:
    """Write `text` to config_path atomically; fall back to **non-interactive**
    sudo install on EPERM.

    Non-interactive is the whole point: the DarwinForge Mac app drives this over
    BatchMode SSH where there is no terminal for a sudo password prompt. So the
    sudo fallback uses `sudo -n` and, if that needs a password, raises
    PermissionError so the caller prints a clean fallback instead of crashing
    with a CalledProcessError traceback (2026-06-07 real-hardware fix).
    """
    tmp = config_path.with_suffix(config_path.suffix + ".tmp")
    try:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        with tmp.open("w", encoding="utf-8") as fp:
            fp.write(text)
        os.replace(tmp, config_path)
        return True
    except PermissionError:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
    if not shutil.which("sudo"):
        raise PermissionError(str(config_path))
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as fp:
        fp.write(text)
        user_tmp = Path(fp.name)
    try:
        mk = subprocess.run(["sudo", "-n", "mkdir", "-p", str(config_path.parent)],
                            text=True, capture_output=True, check=False)
        inst = subprocess.run(["sudo", "-n", "install", "-m", "0644", str(user_tmp), str(config_path)],
                              text=True, capture_output=True, check=False)
        if mk.returncode != 0 or inst.returncode != 0:
            # Most likely: sudo needs a password (no NOPASSWD), no TTY over SSH.
            raise PermissionError(str(config_path))
    finally:
        try:
            user_tmp.unlink()
        except OSError:
            pass
    return True


def write_agent_ssh_mode(config_path: Path, cfg: RobotSshConfig) -> bool:
    return _atomic_write_config(config_path, _agent_config_payload(config_path, cfg))


def write_stabilize_config(config_path: Path, cfg: RobotSshConfig) -> bool:
    return _atomic_write_config(config_path, _stabilize_payload(config_path, cfg))


def restart_agent_service() -> bool:
    if not shutil.which("systemctl"):
        return False
    cmd = ["systemctl", "restart", "darwin-switch-agent.service"]
    # Non-interactive sudo (`-n`): over BatchMode SSH there is no TTY for a
    # password prompt, so a missing NOPASSWD rule fails fast (return False) and
    # the caller prints a clean "run this manually" hint instead of hanging.
    if os.geteuid() != 0 and shutil.which("sudo"):
        cmd[:0] = ["sudo", "-n"]
    proc = subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        if proc.stderr:
            print(proc.stderr.rstrip(), file=sys.stderr)
        return False
    return True


def cmd_enable_agent_ssh(cfg: RobotSshConfig, config_path: Path, restart: bool = True) -> int:
    try:
        write_agent_ssh_mode(config_path, cfg)
    except PermissionError:
        print(
            f"Cannot write {config_path}. Install sudo or run as an administrator.",
            file=sys.stderr,
        )
        return 2
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Cannot update {config_path}: {exc}", file=sys.stderr)
        return 2
    print(f"Agent config: mode=ssh · {cfg.user}@{cfg.host}:{cfg.port}")
    print(f"Agent config: identity_file={absolute_identity_file(cfg.identity_file)}")
    if restart:
        if restart_agent_service():
            print("Agent service: restarted")
        else:
            print("Agent service: restart skipped/failed; run `sudo systemctl restart darwin-switch-agent`.", file=sys.stderr)
            return 1
    return 0


def cmd_stabilize(cfg: RobotSshConfig, config_path: Path, restart: bool = True) -> int:
    """Apply the stability-first tuning (lower SSH/telemetry rates + gentler gait
    ramp) and an absolute identity path, then restart the agent."""
    try:
        write_stabilize_config(config_path, cfg)
    except PermissionError:
        print(f"Cannot write {config_path}. Install sudo or run as an administrator.", file=sys.stderr)
        return 2
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Cannot update {config_path}: {exc}", file=sys.stderr)
        return 2
    keys = ", ".join(f"{k}={v}" for k, v in STABILIZE_DEFAULTS.items())
    print(f"Agent config: stabilized ({keys})")
    print(f"Agent config: identity_file={absolute_identity_file(cfg.identity_file)}")
    if restart:
        if restart_agent_service():
            print("Agent service: restarted")
        else:
            print("Agent service: restart skipped/failed; run `sudo systemctl restart darwin-switch-agent`.", file=sys.stderr)
            return 1
    return 0


def cmd_all(cfg: RobotSshConfig, config_path: Path) -> int:
    key_result = cmd_keygen(cfg)
    if key_result != 0:
        return key_result
    probe_result = cmd_probe(cfg)
    if probe_result != 0:
        print("")
        print("Next: run this once, enter the robot password, then rerun `darwin-switch-robot-ready all`.")
        print(" ".join(copy_key_command(cfg)))
        return probe_result
    status_result = cmd_status(cfg)
    if status_result != 0:
        return status_result
    start_result = cmd_start_walklab(cfg)
    if start_result != 0:
        return start_result
    return cmd_enable_agent_ssh(cfg, config_path, restart=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Prepare and verify DarwinForge-compatible robot SSH control from Switch")
    parser.add_argument(
        "command",
        choices=(
            "plan",
            "keygen",
            "copy-key",
            "probe",
            "status",
            "start-walklab",
            "enable-agent-ssh",
            "reachability",
            "stabilize",
            "all",
        ),
    )
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="agent config path")
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="runtime root for config fallback")
    parser.add_argument("--no-restart", action="store_true", help="for enable-agent-ssh: update config without restarting the agent service")
    # Robot endpoint overrides — let the Mac wizard point the Switch at a robot
    # IP it can actually route to (and persist it via enable-agent-ssh).
    parser.add_argument("--robot-host", default=None, help="override robot SSH host (else use config)")
    parser.add_argument("--robot-user", default=None, help="override robot SSH user (else use config)")
    parser.add_argument("--robot-port", type=int, default=None, help="override robot SSH port (else use config)")
    # reachability inputs.
    parser.add_argument("--candidates", default="", help="for reachability: comma-separated robot IPs to probe")
    parser.add_argument("--reach-timeout", type=float, default=2.0, help="for reachability: per-candidate TCP timeout (s)")
    args = parser.parse_args(argv)

    config = load_config(Path(args.config), Path(args.root))
    cfg = robot_ssh_config(
        config,
        host_override=args.robot_host,
        user_override=args.robot_user,
        port_override=args.robot_port,
    )
    if args.command == "reachability":
        candidates = [c for c in args.candidates.split(",") if c.strip()]
        if not candidates:
            print("DF_REACHABLE=none")
            print("No --candidates provided.", file=sys.stderr)
            return 2
        return cmd_reachability(candidates, cfg.port, args.reach_timeout)
    if args.command == "plan":
        return cmd_plan(cfg)
    if args.command == "keygen":
        return cmd_keygen(cfg)
    if args.command == "copy-key":
        return cmd_copy_key(cfg)
    if args.command == "probe":
        return cmd_probe(cfg)
    if args.command == "status":
        return cmd_status(cfg)
    if args.command == "start-walklab":
        return cmd_start_walklab(cfg)
    if args.command == "enable-agent-ssh":
        return cmd_enable_agent_ssh(cfg, Path(args.config), restart=not args.no_restart)
    if args.command == "stabilize":
        return cmd_stabilize(cfg, Path(args.config), restart=not args.no_restart)
    if args.command == "all":
        return cmd_all(cfg, Path(args.config))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
