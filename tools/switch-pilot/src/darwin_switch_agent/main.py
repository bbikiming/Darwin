from __future__ import annotations

import argparse
import logging
import os
import signal
import sys
import time
from dataclasses import dataclass, replace

from .config import AgentConfig
from .cockpit import CockpitServer
from .control_bus import ControlAction, ControlBus
from .discovery import local_ip_hint
from .input_linux import LinuxInputReader, NullInputReader
from .mac_relay_client import MacRelayClient
from .mapping import MotionCommand
from .mapping import ControllerMapper
from .robot_udp_client import RobotUdpClient
from .safety import SafetyEdges, SafetyState
from .ssh_control_client import SshControlClient
from . import systemd_notify


def setup_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Darwin Switch Controller Agent")
    parser.add_argument("--config", default="/etc/darwin-switch-agent/config.json")
    args = parser.parse_args(argv)

    config = AgentConfig.load(args.config)
    setup_logging(config.log_level)
    log = logging.getLogger("agent")
    stop_requested = False

    def _stop(_signum: int, _frame: object) -> None:
        nonlocal stop_requested
        stop_requested = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    log.info("Darwin Switch Agent starting in mode=%s ip=%s", config.mode, local_ip_hint())

    bus = ControlBus(camera=config.section("camera"))
    cockpit = start_cockpit(config, bus, args.config)
    input_reader = make_input_reader(config)
    input_status = input_status_label(input_reader)
    mapper = ControllerMapper(config.section("mapping"), config.section("motion"))
    safety = SafetyState()
    mac_client: MacRelayClient | None = None
    robot_client: RobotUdpClient | None = None
    ssh_client: SshControlClient | None = None
    armed = False
    estopped = False

    send_hz = float(config.section("motion").get("send_hz", 20))
    send_interval = 1.0 / max(1.0, send_hz)
    last_send = 0.0
    last_status = 0.0
    last_moving = False
    last_connect_attempt = 0.0
    last_watchdog = 0.0
    # Follow systemd's WatchdogSec when present (pet at half the deadline);
    # fall back to 5s outside systemd (well under the unit's WatchdogSec=15).
    _wd_usec = os.environ.get("WATCHDOG_USEC")
    watchdog_interval = (
        max(1.0, int(_wd_usec) / 1_000_000 / 2) if (_wd_usec and _wd_usec.isdigit()) else 5.0
    )
    ip_hint = local_ip_hint()
    # SSH (walklab brokerage) cadence state: amplitudes are sent on a meaningful
    # change AND as a heartbeat so the daemon's 5s stale-stop never trips while
    # piloting. Cadence is read from the [ssh] config section; the heartbeat and
    # debounce use SEPARATE clocks and advance on ATTEMPT (not only success) so a
    # dead link throttles instead of busy-looping.
    _ssh_cfg = config.section("ssh")
    ssh_send_interval = 1.0 / max(1.0, float(_ssh_cfg.get("send_hz", 5)))
    ssh_heartbeat_interval = max(0.1, float(_ssh_cfg.get("heartbeat_ms", 1000)) / 1000.0)
    telemetry_interval = 1.0 / max(0.5, float(_ssh_cfg.get("telemetry_hz", 2)))
    last_sent_line: str | None = None
    last_heartbeat = 0.0
    last_estop_assert = 0.0
    last_telemetry_poll = 0.0

    try:
        if config.mode == "mac_relay":
            mac_client = MacRelayClient(config.section("mac"), config.device_name, config.device_id)
        elif config.mode == "robot_udp":
            robot_client = RobotUdpClient(config.section("robot"))
            log.info("robot UDP target %s:%s", config.section("robot").get("host"), config.section("robot").get("port"))
        elif config.mode == "ssh":
            # The [ssh] section owns the SSH/WalkLab gait defaults (period_ms,
            # foot_mm, hip_deg) — see config.example.json.
            ssh_client = SshControlClient(config.section("ssh"))
            log.info(
                "ssh walklab target %s@%s",
                config.section("ssh").get("user", "robotis"),
                config.section("ssh").get("host", "192.168.123.1"),
            )
        elif config.mode != "dry_run":
            log.warning("unknown mode %s; falling back to dry_run", config.mode)

        # Honest, mode-specific stop-watchdog label for the cockpit (no fake 500ms).
        bus.set_watchdog_label(watchdog_label_for(config.mode))

        # Cockpit + mode client are up: signal systemd readiness exactly once.
        # Type=notify keeps the unit 'activating' until this fires, so it must
        # be reached early (here, before the control loop blocks on input).
        systemd_notify.ready()

        while not stop_requested:
            controller = input_reader.poll(timeout=0.01)
            raw_command = mapper.map(controller)
            edges = safety.update(controller, raw_command)

            now = time.monotonic()
            if now - last_watchdog >= watchdog_interval:
                systemd_notify.watchdog()
                last_watchdog = now

            # --- Safety state is settled FIRST, from BOTH cockpit actions and
            # physical edges, BEFORE the final command is computed. This is the
            # safety gate: a Stop/E-stop this tick can never be followed by a
            # nonzero command in the same tick. (See settle_safety_state.)
            actions = bus.drain_actions()
            settlement = settle_safety_state(armed, estopped, actions, edges)
            armed = settlement.armed
            estopped = settlement.estopped
            force_stop = settlement.force_stop_this_tick

            # Final command — computed only after the safety state above is final.
            command = gate_motion(raw_command, armed=armed, estopped=estopped)
            if force_stop:
                command = zero_walk_motion(command)
            if estopped or force_stop:
                last_moving = False  # no trailing nonzero walk send this tick.

            if mac_client:
                connected = bool(mac_client.connected)
            elif ssh_client:
                connected = bool(ssh_client.connected)
            else:
                connected = config.mode in {"robot_udp", "dry_run"}
            target = target_label(config)

            # Cockpit action side-effects only (state already settled above).
            for action in actions:
                if action.action == "arm":
                    if mac_client and mac_client.connected:
                        try_control_call(log, "arm", mac_client.arm)
                    if ssh_client:
                        try_control_call(log, "recover", ssh_client.recover)
                    bus.log("조종 권한 켜짐")
                elif action.action == "recover":
                    if mac_client and mac_client.connected:
                        try_control_call(log, "recover", mac_client.recover)
                    if ssh_client:
                        try_control_call(log, "recover", ssh_client.recover)
                    bus.log("복구")
                elif action.action == "stop":
                    if mac_client and mac_client.connected:
                        try_control_call(log, "stop", lambda: mac_client.stop("screen"))
                    if ssh_client:
                        try_control_call(log, "stop", lambda: ssh_client.send(command))
                    bus.log("정지")
                elif action.action == "estop":
                    if mac_client and mac_client.connected:
                        try_control_call(log, "estop", lambda: mac_client.estop("switchScreen"))
                    if ssh_client:
                        try_control_call(log, "estop", ssh_client.estop)
                    bus.log("비상정지")
                elif action.action == "ping":
                    bus.log(f"점검 모드={config.mode} 대상={target}")
                elif action.action == "reconnect":
                    last_connect_attempt = 0.0
                    if mac_client:
                        mac_client.close()
                        bus.log("맥 릴레이 재연결 요청")
                    elif ssh_client:
                        ssh_client.close()
                        bus.log("SSH 재연결 요청")
                    elif robot_client:
                        bus.log("UDP 경로 점검 요청")
                    else:
                        bus.log("연습 모드 점검")

            if now - last_status > 2.0:
                log.info(
                    "state deadman=%s lx=%.2f ly=%.2f rx=%.2f ry=%.2f stride=%.1f side=%.1f turn=%.1f head=(%.1f,%.1f)",
                    controller.deadman,
                    controller.left_x,
                    controller.left_y,
                    controller.right_x,
                    controller.right_y,
                    command.stride_mm,
                    command.side_mm,
                    command.turn_deg,
                    command.head_pan_deg,
                    command.head_tilt_deg,
                )
                last_status = now

            # Publish the FINAL command so the UI shows exactly what could be sent.
            bus.publish(
                mode=config.mode,
                connected=connected,
                local_ip=ip_hint,
                target=target,
                input_status=input_status,
                controller=controller,
                command=command,
                armed=armed,
                estopped=estopped,
            )

            if config.mode == "mac_relay" and mac_client:
                if not mac_client.connected:
                    if now - last_connect_attempt >= 1.0:
                        last_connect_attempt = now
                        try:
                            mac_client.connect()
                            bus.log("맥 릴레이 연결됨")
                        except Exception as exc:  # noqa: BLE001
                            bus.log(f"맥 릴레이 대기 중: {exc}")
                            log.warning("Mac relay connect failed: %s", exc)
                    continue
                try:
                    mac_client.heartbeat("commandActive" if command.moving else "armedReady")
                except Exception as exc:  # noqa: BLE001
                    log.warning("Mac heartbeat failed: %s", exc)
                    bus.log(f"맥 릴레이 끊김: {exc}")
                    mac_client.close()
                    continue
                # Physical-edge transport side-effects (state already settled).
                if edges.arm_pressed:
                    log.info("arm pressed")
                    try_control_call(log, "arm", mac_client.arm)
                if edges.estop_pressed:
                    log.warning("estop pressed")
                    try_control_call(log, "estop", lambda: mac_client.estop("physical"))
                if edges.stop_pressed:
                    log.info("stop edge")
                    try_control_call(log, "stop", lambda: mac_client.stop("user"))
                if now - last_send >= send_interval:
                    # Never send a walk/head after Stop/E-stop in this tick.
                    if (command.moving or last_moving) and not (estopped or force_stop):
                        try:
                            mac_client.walk(command)
                            mac_client.head(command)
                        except Exception as exc:  # noqa: BLE001
                            log.warning("Mac relay send failed: %s", exc)
                            bus.log(f"맥 릴레이 전송 실패: {exc}")
                            mac_client.close()
                    last_send = now
                    last_moving = command.moving
            elif config.mode == "robot_udp" and robot_client:
                if edges.arm_pressed:
                    bus.log("조종 권한 켜짐")
                if edges.estop_pressed:
                    # Push an explicit zero datagram now; do not wait for the tick.
                    robot_client.send_stop(estop=True)
                    bus.log("비상정지")
                if edges.stop_pressed:
                    # Explicit immediate zero on the stop edge.
                    # The robot-side receiver also runs a ~500ms staleness
                    # watchdog (see RobotUdpClient docstring) as a second leg.
                    robot_client.send_stop()
                    bus.log("정지")
                if now - last_send >= send_interval:
                    # command is the final, safety-gated command (zeroed on stop/estop).
                    robot_client.send(controller, command)
                    last_send = now
            elif config.mode == "ssh" and ssh_client:
                if not ssh_client.connected:
                    if now - last_connect_attempt >= 1.0:
                        last_connect_attempt = now
                        ok = ssh_client.connect()
                        bus.log("SSH 연결됨" if ok else "SSH 연결 대기 중")
                    continue
                if edges.arm_pressed:
                    log.info("arm pressed")
                    try_control_call(log, "recover", ssh_client.recover)
                if edges.estop_pressed:
                    log.warning("estop pressed")
                    try_control_call(log, "estop", ssh_client.estop)
                    last_estop_assert = now
                if edges.stop_pressed:
                    log.info("stop edge")
                    try_control_call(log, "stop", lambda: ssh_client.send(command))
                if estopped:
                    # The estop FILE is the authoritative stop; re-assert it each
                    # heartbeat (idempotent touch) so a single dropped SSH 'touch'
                    # on the edge cannot leave the robot un-stopped. While estopped
                    # we send NO command line — the file is the source of truth.
                    if now - last_estop_assert >= ssh_heartbeat_interval:
                        last_estop_assert = now
                        try_control_call(log, "estop", ssh_client.estop)
                else:
                    # Debounced amplitude send: on a meaningful command change OR
                    # the heartbeat, throttled by ssh_send_interval. Separate
                    # clocks; both advance on ATTEMPT so a failing link throttles.
                    # last_sent_line advances only on success so a change keeps
                    # retrying (throttled) until it lands. command is final/gated.
                    line = ssh_command_line(command)
                    changed = line != last_sent_line
                    heartbeat_due = now - last_heartbeat >= ssh_heartbeat_interval
                    if (changed or heartbeat_due) and now - last_send >= ssh_send_interval:
                        last_send = now
                        last_heartbeat = now
                        if ssh_client.send(command):
                            last_sent_line = line
                if now - last_telemetry_poll >= telemetry_interval:
                    last_telemetry_poll = now
                    tel = ssh_client.poll_telemetry()
                    if tel:
                        bus.publish_telemetry(
                            ssh_connected=ssh_client.connected,
                            link_latency_ms=tel["latency_ms"],
                            battery_v=tel["voltage_v"],
                            battery_pct=tel["battery_pct"],
                            walking=tel["walking"],
                            fallen=tel["fallen"],
                            robot_state="fallen" if tel["fallen"] != 0 else "upright",
                            gyro=tel.get("gyro"),
                            accel=tel.get("accel"),
                        )
            else:
                time.sleep(0.02)

    finally:
        try:
            if mac_client:
                mac_client.stop("agentShutdown")
                mac_client.close()
        except Exception as exc:  # noqa: BLE001
            log.debug("shutdown stop failed: %s", exc)
        try:
            if ssh_client:
                ssh_client.stop()
                ssh_client.close()
        except Exception as exc:  # noqa: BLE001
            log.debug("ssh shutdown failed: %s", exc)
        input_reader.close()
        if cockpit:
            cockpit.stop()
        log.info("Darwin Switch Agent stopped")

    return 0


def make_input_reader(config: AgentConfig):
    try:
        reader = LinuxInputReader(config.section("input"), config.section("mapping"))
        if not reader.selector.get_map():
            logging.getLogger("agent").warning("no input devices opened; using null input")
            return NullInputReader()
        return reader
    except Exception as exc:  # noqa: BLE001
        logging.getLogger("agent").warning("input init failed: %s; using null input", exc)
        return NullInputReader()


def connect_with_retry(client: MacRelayClient, log: logging.Logger, should_stop) -> None:
    while not should_stop():
        try:
            client.connect()
            return
        except Exception as exc:  # noqa: BLE001
            log.warning("Mac relay connect failed: %s; retrying", exc)
            time.sleep(1.0)


def start_cockpit(config: AgentConfig, bus: ControlBus, config_path: str) -> CockpitServer | None:
    gui = config.section("gui")
    if not bool(gui.get("enabled", True)):
        return None
    server = CockpitServer(
        bus,
        host=str(gui.get("host", "127.0.0.1")),
        port=int(gui.get("port", 8765)),
        config_path=config_path,
    )
    server.start()
    bus.log("조종석 준비됨")
    return server


def target_label(config: AgentConfig) -> str:
    if config.mode == "mac_relay":
        mac = config.section("mac")
        return f"{mac.get('host', '127.0.0.1')}:{mac.get('port', 0)}"
    if config.mode == "robot_udp":
        robot = config.section("robot")
        return f"{robot.get('host', '192.168.0.100')}:{robot.get('port', 55310)}"
    if config.mode == "ssh":
        ssh = config.section("ssh")
        user = ssh.get("user", "robotis")
        host = ssh.get("host", "192.168.123.1")
        port = int(ssh.get("port", 22))
        return f"{user}@{host}" if port == 22 else f"{user}@{host}:{port}"
    return "dry-run"


def watchdog_label_for(mode: str) -> str:
    """Honest stop-watchdog label per mode. Reflects what the ACTIVE control path
    actually enforces — not a fixed number that implies a guarantee it lacks.
      - mac_relay: the Mac MobileRelayServer enforces a ~500ms command watchdog.
      - robot_udp: the robot-side receiver should run ~500ms, but it is not yet
        verified to exist, so it is labelled accordingly.
      - ssh: the onboard WalkLab daemon stops on ~5s command staleness.
    """
    return {
        "mac_relay": "맥 릴레이 500ms",
        "robot_udp": "로봇 500ms·미검증",
        "ssh": "로봇 정지 5s",
    }.get(mode, "—")


def ssh_command_line(command: MotionCommand) -> str:
    """A stable, comparable fingerprint of the command fields the SSH walklab
    line carries (enabled + amplitudes + head). Used only to detect a
    *meaningful* change so we don't spam identical lines over SSH; the actual
    14-token line is built inside SshControlClient.send with a fresh cmd_id.
    """
    return (
        f"{1 if command.enabled else 0} "
        f"{command.stride_mm:.1f} {command.side_mm:.1f} {command.turn_deg:.1f} "
        f"{command.head_pan_deg:.1f} {command.head_tilt_deg:.1f}"
    )


def gate_motion(command: MotionCommand, *, armed: bool, estopped: bool) -> MotionCommand:
    if armed and not estopped:
        return command
    return zero_walk_motion(command)


def zero_motion(command: MotionCommand) -> MotionCommand:
    """Force every controllable output to neutral.

    Use this only for hard shutdown / e-stop style cleanup. Normal stop should
    not recenter the head, because manual head aim is expected to
    hold its last commanded pose.
    """
    return replace(
        command, enabled=False, stride_mm=0.0, side_mm=0.0, turn_deg=0.0,
        head_pan_deg=0.0, head_tilt_deg=0.0,
    )


def zero_walk_motion(command: MotionCommand) -> MotionCommand:
    """Stop walking while preserving the held head pan/tilt command."""
    return replace(command, enabled=False, stride_mm=0.0, side_mm=0.0, turn_deg=0.0)


@dataclass(frozen=True)
class SafetySettlement:
    armed: bool
    estopped: bool
    force_stop_this_tick: bool


def settle_safety_state(
    armed: bool,
    estopped: bool,
    actions: list[ControlAction],
    edges: SafetyEdges,
) -> SafetySettlement:
    """Resolve the tick's final safety state from cockpit actions AND physical
    edges, BEFORE any motion command is computed. Safety-first: within a tick
    E-stop dominates Arm/Recover, and Stop forces zero motion for the tick
    (without necessarily latching E-stop). Pure + testable.
    """
    arm_now = edges.arm_pressed
    estop_now = edges.estop_pressed
    force_stop = bool(edges.stop_pressed)
    for action in actions:
        if action.action in ("arm", "recover"):
            arm_now = True
        elif action.action == "estop":
            estop_now = True
        elif action.action == "stop":
            force_stop = True
    if arm_now:
        armed = True
        estopped = False
    if estop_now:  # applied last so E-stop wins over a same-tick Arm/Recover.
        estopped = True
        armed = False
    return SafetySettlement(armed=armed, estopped=estopped, force_stop_this_tick=force_stop)


def try_control_call(log: logging.Logger, label: str, fn) -> None:
    """Run a transport control call (Mac relay OR SSH OR UDP); log on failure.
    Transport-neutral — the label says which call failed during debugging."""
    try:
        fn()
    except Exception as exc:  # noqa: BLE001
        log.warning("control call '%s' failed: %s", label, exc)


def input_status_label(reader) -> str:
    paths = getattr(reader, "device_paths", [])
    if not paths:
        return "입력장치 없음"
    if len(paths) == 1:
        return paths[0]
    return f"입력장치 {len(paths)}개"


if __name__ == "__main__":
    sys.exit(main())
