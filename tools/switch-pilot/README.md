# Darwin Switch Agent

Installable runtime bundle for a Nintendo Switch running Switchroot L4T Ubuntu.

This is not a replacement Nintendo firmware image. It is a Darwin-specific
Linux runtime package that can be copied onto the Switch after Switchroot
Ubuntu is booting and SSH is enabled.

## Current Scope

- Reads Linux input events from `/dev/input/event*`.
- Uses `ZL` as the deadman input by default.
- Maps the left stick to walk forward/back and turn.
- Maps the right stick to head pan/tilt values for future robot-direct support.
- Sends Mac relay commands over the DarwinForge `/mobile-relay` WebSocket.
- Sends robot-direct UDP line protocol packets for later onboard receiver work.
- Serves a Switch-sized local cockpit at `http://127.0.0.1:8765/`.
- Displays the robot MJPEG camera stream as a mecha-style cockpit HUD when a
  camera tunnel is open.
- Installs a desktop autostart launcher that opens the cockpit fullscreen.
- Installs as a systemd service.

The cockpit is intentionally implemented as a local web UI so the first
Switchroot Ubuntu install does not need Qt, Electron, or other heavy GUI
dependencies. It is laid out for the Switch's 1280x720 screen and exposes
safety state, command authority, stick axes, logs, and direct safety actions.

## Install On Switchroot Ubuntu

Copy this folder to the Switch:

```bash
scp -r tools/switch-pilot <switch-user>@<switch-ip>:~/switch-pilot
```

Install:

```bash
cd ~/switch-pilot
sudo ./install.sh
```

Edit configuration:

```bash
sudo nano /etc/darwin-switch-agent/config.json
```

Start:

```bash
sudo systemctl enable --now darwin-switch-agent
```

Open cockpit manually if the desktop autostart has not run yet:

```bash
darwin-switch-cockpit
```

Logs:

```bash
journalctl -u darwin-switch-agent -f
```

## Modes

`mode = "mac_relay"`:

Switch -> Mac DarwinForge MobileRelay -> robot.

`mode = "robot_udp"`:

Switch -> robot UDP line protocol. The robot receiver is not implemented yet,
so this is for protocol testing only.

`mode = "dry_run"`:

Prints mapped state without sending commands.

## Configuration

See `config.example.json`.

Important values:

- `camera.enabled`, `camera.stream_url`, `camera.snapshot_url`
- `mac.host`, `mac.port`, `mac.pairing_code`
- `robot.host`, `robot.port`, `robot.token`
- `input.event_globs`
- `mapping.deadman_key_codes`
- `gui.port`, normally `8765`

## Robot Camera

The cockpit is preconfigured to read the robot camera at:

```text
http://127.0.0.1:18080/?action=stream
```

That URL is local to the Switch. Open an SSH tunnel from the Switch to the
robot:

```bash
ROBOT_HOST=192.168.123.1 ROBOT_USER=robotis darwin-switch-camera-tunnel
```

The helper does two things:

1. SSH into the robot and start ROBOTIS `camera_tutorial` on port `8080`.
2. Forward Switch `127.0.0.1:18080` to robot `127.0.0.1:8080`.

The robot-side stream endpoints are:

```text
http://<robot-ip>:8080/?action=snapshot
http://<robot-ip>:8080/?action=stream
```

If the Switch and robot are on the same trusted network, the cockpit can point
directly to `http://<robot-ip>:8080/?action=stream`. The SSH tunnel is the
safer default because it does not require exposing the camera server beyond the
robot login path.

## Safety Defaults

- Movement is allowed only while deadman is held.
- Deadzone defaults to `0.12`.
- Mac relay heartbeat interval is `100ms`.
- Command send rate defaults to `20Hz`.
- On deadman release, the agent sends stop.
- The fullscreen cockpit has Arm, Stop, Recover, and E-stop controls.

Robot physical safety still matters. Keep the robot's independent stop or
power-cut path available during all tests.

## Package

From the repository root:

```bash
tools/switch-pilot/package.sh
```

The tarball is written to:

```text
dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz
```
