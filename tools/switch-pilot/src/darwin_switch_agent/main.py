from __future__ import annotations

import argparse
import logging
import signal
import sys
import time
from dataclasses import replace

from .config import AgentConfig
from .cockpit import CockpitServer
from .control_bus import ControlBus
from .discovery import local_ip_hint
from .input_linux import LinuxInputReader, NullInputReader
from .mac_relay_client import MacRelayClient
from .mapping import MotionCommand
from .mapping import ControllerMapper
from .robot_udp_client import RobotUdpClient
from .safety import SafetyState
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
    watchdog_interval = 5.0  # pet well under the unit's WatchdogSec=15
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
            ssh_client = SshControlClient({**config.section("ssh"), "motion": config.section("motion")})
            log.info(
                "ssh walklab target %s@%s",
                config.section("ssh").get("user", "robotis"),
                config.section("ssh").get("host", "192.168.123.1"),
            )
        elif config.mode != "dry_run":
            log.warning("unknown mode %s; falling back to dry_run", config.mode)

        # Cockpit + mode client are up: signal systemd readiness exactly once.
        # Type=notify keeps the unit 'activating' until this fires, so it must
        # be reached early (here, before the control loop blocks on input).
        systemd_notify.ready()

        while not stop_requested:
            controller = input_reader.poll(timeout=0.01)
            raw_command = mapper.map(controller)
            command = gate_motion(raw_command, armed=armed, estopped=estopped)
            edges = safety.update(controller, command)

            now = time.monotonic()
            if now - last_watchdog >= watchdog_interval:
                systemd_notify.watchdog()
                last_watchdog = now
            if mac_client:
                connected = bool(mac_client.connected)
            elif ssh_client:
                connected = bool(ssh_client.connected)
            else:
                connected = config.mode in {"robot_udp", "dry_run"}
            target = target_label(config)

            for action in bus.drain_actions():
                if action.action == "arm":
                    armed = True
                    estopped = False
                    if mac_client and mac_client.connected:
                        try_mac(log, mac_client.arm)
                    if ssh_client:
                        try_mac(log, ssh_client.recover)
                    bus.log("armed")
                elif action.action == "recover":
                    estopped = False
                    armed = True
                    if mac_client and mac_client.connected:
                        try_mac(log, mac_client.recover)
                    if ssh_client:
                        try_mac(log, ssh_client.recover)
                    bus.log("recover")
                elif action.action == "stop":
                    if mac_client and mac_client.connected:
                        try_mac(log, lambda: mac_client.stop("screen"))
                    if ssh_client:
                        try_mac(log, ssh_client.stop)
                    bus.log("stop")
                    last_moving = False
                elif action.action == "estop":
                    estopped = True
                    armed = False
                    if mac_client and mac_client.connected:
                        try_mac(log, lambda: mac_client.estop("switchScreen"))
                    if ssh_client:
                        try_mac(log, ssh_client.estop)
                    bus.log("estop")
                    last_moving = False
                elif action.action == "ping":
                    bus.log(f"ping mode={config.mode} target={target}")

            if now - last_status > 2.0:
                log.info(
                    "state deadman=%s lx=%.2f ly=%.2f rx=%.2f ry=%.2f stride=%.1f turn=%.1f head=(%.1f,%.1f)",
                    controller.deadman,
                    controller.left_x,
                    controller.left_y,
                    controller.right_x,
                    controller.right_y,
                    command.stride_mm,
                    command.turn_deg,
                    command.head_pan_deg,
                    command.head_tilt_deg,
                )
                last_status = now

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
                            bus.log("Mac relay connected")
                        except Exception as exc:  # noqa: BLE001
                            bus.log(f"Mac relay waiting: {exc}")
                            log.warning("Mac relay connect failed: %s", exc)
                    continue
                try:
                    mac_client.heartbeat("commandActive" if command.moving else "armedReady")
                except Exception as exc:  # noqa: BLE001
                    log.warning("Mac heartbeat failed: %s", exc)
                    bus.log(f"Mac relay lost: {exc}")
                    mac_client.close()
                    continue
                if edges.arm_pressed:
                    log.info("arm pressed")
                    armed = True
                    estopped = False
                    try_mac(log, mac_client.arm)
                if edges.estop_pressed:
                    log.warning("estop pressed")
                    estopped = True
                    armed = False
                    try_mac(log, lambda: mac_client.estop("physical"))
                if edges.stop_pressed or edges.deadman_released:
                    log.info("stop edge")
                    try_mac(log, lambda: mac_client.stop("deadmanRelease" if edges.deadman_released else "user"))
                if now - last_send >= send_interval:
                    if command.moving or last_moving:
                        try:
                            mac_client.walk(command)
                            mac_client.head(command)
                        except Exception as exc:  # noqa: BLE001
                            log.warning("Mac relay send failed: %s", exc)
                            bus.log(f"Mac relay send failed: {exc}")
                            mac_client.close()
                    last_send = now
                    last_moving = command.moving
            elif config.mode == "robot_udp" and robot_client:
                if edges.arm_pressed:
                    armed = True
                    estopped = False
                    bus.log("armed")
                if edges.estop_pressed:
                    armed = False
                    estopped = True
                    # Push an explicit zero datagram now; do not wait for the tick.
                    robot_client.send_stop(estop=True)
                    bus.log("estop")
                if edges.stop_pressed or edges.deadman_released:
                    # Explicit immediate zero on the stop / deadman-release edge.
                    # The robot-side receiver also runs a ~500ms staleness
                    # watchdog (see RobotUdpClient docstring) as a second leg.
                    robot_client.send_stop()
                    bus.log("stop (deadman release)" if edges.deadman_released else "stop")
                if now - last_send >= send_interval:
                    robot_client.send(controller, command)
                    last_send = now
            elif config.mode == "ssh" and ssh_client:
                if not ssh_client.connected:
                    if now - last_connect_attempt >= 1.0:
                        last_connect_attempt = now
                        ok = ssh_client.connect()
                        bus.log("ssh connected" if ok else "ssh waiting")
                    continue
                if edges.arm_pressed:
                    log.info("arm pressed")
                    armed = True
                    estopped = False
                    try_mac(log, ssh_client.recover)
                if edges.estop_pressed:
                    log.warning("estop pressed")
                    estopped = True
                    armed = False
                    try_mac(log, ssh_client.estop)
                    last_estop_assert = now
                if edges.stop_pressed or edges.deadman_released:
                    log.info("stop edge")
                    try_mac(log, ssh_client.stop)
                if estopped:
                    # The estop FILE is the authoritative stop; re-assert it each
                    # heartbeat (idempotent touch) so a single dropped SSH 'touch'
                    # on the edge cannot leave the robot un-stopped.
                    if now - last_estop_assert >= ssh_heartbeat_interval:
                        last_estop_assert = now
                        try_mac(log, ssh_client.estop)
                # Debounced amplitude send: on a meaningful command change OR the
                # heartbeat, throttled by ssh_send_interval. Separate clocks; both
                # advance on ATTEMPT so a failing link throttles, not busy-loops.
                # last_sent_line advances only on success so a change keeps
                # retrying (throttled) until it lands.
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
    bus.log("cockpit ready")
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
        return f"{ssh.get('user', 'robotis')}@{ssh.get('host', '192.168.123.1')}"
    return "dry-run"


def ssh_command_line(command: MotionCommand) -> str:
    """A stable, comparable fingerprint of the command fields the SSH walklab
    line carries (enabled + amplitudes + head). Used only to detect a
    *meaningful* change so we don't spam identical lines over SSH; the actual
    14-token line is built inside SshControlClient.send with a fresh cmd_id.
    """
    return (
        f"{1 if command.enabled else 0} "
        f"{command.stride_mm:.1f} {command.turn_deg:.1f} "
        f"{command.head_pan_deg:.1f} {command.head_tilt_deg:.1f}"
    )


def gate_motion(command: MotionCommand, *, armed: bool, estopped: bool) -> MotionCommand:
    if armed and not estopped:
        return command
    return replace(command, enabled=False, stride_mm=0.0, turn_deg=0.0, head_pan_deg=0.0, head_tilt_deg=0.0)


def try_mac(log: logging.Logger, fn) -> None:
    try:
        fn()
    except Exception as exc:  # noqa: BLE001
        log.warning("Mac relay command failed: %s", exc)


def input_status_label(reader) -> str:
    paths = getattr(reader, "device_paths", [])
    if not paths:
        return "No input device"
    if len(paths) == 1:
        return paths[0]
    return f"{len(paths)} input devices"


if __name__ == "__main__":
    sys.exit(main())
