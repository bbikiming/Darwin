# 08 — Startup & Init Services (ROBOTIS-OP2 Factory Firmware)

## TL;DR

The factory image is **Ubuntu 12.04.5 LTS (Precise) / Lubuntu** running **upstart** as PID 1, with **LightDM** auto-logging in user `robotis` to an LXDE/Openbox session. There is **no dedicated ROBOTIS upstart job or systemd unit** — the demo binary is launched the simplest possible way: **a one-line append to `/etc/rc.local`** (`sleep 10; /robotis/Linux/project/demo/demo`) which runs as root at the end of runlevel 2, before the X session even comes up. So the "ROBOTIS demo" auto-runs from the SysV/upstart compatibility layer, not from any user-session autostart hook.

## Boot order

1. **GRUB 2** loads default entry 0 (`Ubuntu, with Linux 3.2.66-op2`) from `/boot/grub/grub.cfg`. Default kernel `vmlinuz-3.2.66-op2` is the ROBOTIS custom kernel; `vmlinuz-3.2.0-79-generic` is the fallback. `GRUB_DEFAULT=0`, `GRUB_TIMEOUT=10`, `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"` (`/etc/default/grub`).
2. **upstart** (`/sbin/init`) takes over — Ubuntu 12.04 uses upstart, not systemd. There is no `/etc/inittab`.
3. **rc-sysinit** runs `/etc/init.d/rcS` (the rcS.d scripts: `S37apparmor`, `S55urandom`, `S70x11-common`) then calls `telinit "${DEFAULT_RUNLEVEL}"` with `DEFAULT_RUNLEVEL=2` (`/etc/init/rc-sysinit.conf`).
4. **rc** invokes `/etc/init.d/rc 2`, which executes the runlevel-2 symlinks in `/etc/rc2.d/` in alphabetical order. The last script to run is `S99rc.local → /etc/init.d/rc.local`, which sources `/etc/rc.local`.
5. **`/etc/rc.local`** sleeps 10 seconds (to let the system settle / serial enumerate) and then `exec`s `/robotis/Linux/project/demo/demo` **as root**. This is the ROBOTIS demo autostart trigger.
6. In parallel, the upstart `lightdm` job starts on `(filesystem and runlevel [!06] and started dbus and plymouth-ready)`, brings up X, and **auto-logs in `robotis`** into the `Lubuntu` (LXDE / openbox-lubuntu) session. The user session has no ROBOTIS-specific autostart entries — the demo is already running under root.
7. Headless getty stays on tty1 (`/etc/init/tty1.conf`).

## Display manager autologin

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/lightdm/lightdm.conf` verbatim:

```ini
[SeatDefaults]
autologin-guest=false
autologin-user=robotis
autologin-user-timeout=0
autologin-session=lightdm-autologin
greeter-session=lightdm-gtk-greeter
user-session=Lubuntu
```

- `autologin-user-timeout=0` — log in immediately, no countdown.
- `user-session=Lubuntu` — selects LXDE-based session (Openbox WM via `~/.config/lxsession/Lubuntu/desktop.conf` → `window_manager=openbox-lubuntu`).
- `~/.dmrc` confirms `Session=Lubuntu`.

The `users.conf` allows `minimum-uid=500` to be shown; UID for `robotis` is 1000 (`/etc/passwd: robotis:x:1000:1000:robotis,,,:/home/robotis:/bin/bash`).

## ROBOTIS demo autostart

**Trigger**: `/etc/rc.local`. This is the cleanest possible install-anywhere hook — no upstart conf, no SysV script, no `.desktop` file, no `.bashrc` line.

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/rc.local` verbatim:

```sh
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.

sleep 10
/robotis/Linux/project/demo/demo

exit 0
```

Notes:
- The `sleep 10` is almost certainly there to wait for USB enumeration of the CM-730 sub-controller (which appears as `/dev/ttyUSB0`) so the demo doesn't race against udev.
- `set -e` (the `#!/bin/sh -e` shebang) means any failure aborts. The `exec`-style invocation of the demo is a normal foreground spawn; if the demo exits non-zero, rc.local won't reach `exit 0`. In practice rc.local does not wait for the demo to exit before continuing the rest of the boot — actually it *does* wait: there is no `&`. So rc.local effectively blocks here as long as the demo runs. Because `S99rc.local` is the *last* rc2.d script, this doesn't delay subsequent boot stages (there are no later rc2.d entries). Upstart's lightdm job ran in parallel earlier in the boot, so X is already up.
- Demo binary confirmed present at `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/demo` (ELF executable, ~182 KB, mtime 2015-03-25).
- The wrapper that actually runs it is `/etc/init.d/rc.local` (SysV) → invoked through `S99rc.local → ../init.d/rc.local` in `rc2.d`, `rc3.d`, `rc4.d`, `rc5.d`. So the demo would launch in all four multiuser runlevels.

## Other ROBOTIS-related services

There are **no ROBOTIS-specific upstart jobs, init.d scripts, or sudoers.d entries**. Grep confirms:

```bash
$ grep -l "robotis|demo|darwin|op2|dxl|dynamixel" etc/init/*.conf
(no matches)

$ ls etc/init.d/ | grep -iE 'robotis|demo|darwin|op2|dxl|dynamixel|mjpg'
(no matches)
```

The ROBOTIS toolchain is entirely user-space, owned by:
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Data/` — motion/walking data files
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/` — C++ framework source
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/` — built demo + `www/` MJPG streamer assets

mjpg-streamer-style web UI assets live at `robotis/Linux/project/demo/www/` but are served by the demo binary itself (linked in), not by a separate daemon — so there is no init script for it.

## Network services at boot

### Wired Ethernet — static IP

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/network/interfaces` verbatim:

```
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
  address    192.168.123.1
  netmask    255.255.255.0
  broadcast  192.168.123.255
  network    192.168.123.0
```

The robot hosts `192.168.123.1/24`. There is **no `wpa-conf …` directive** — Wi-Fi is not configured at the `/etc/network/interfaces` level. Wi-Fi, if used, would come up via NetworkManager (user-session) which is launched by `/etc/init/network-manager.conf` after dbus and `static-network-up`.

### DHCP server (the robot serves DHCP!)

`/etc/init/isc-dhcp-server.conf` is enabled (starts on runlevel 2345). `/etc/default/isc-dhcp-server`: `INTERFACES="eth0"`. The active `/etc/dhcp/dhcpd.conf`:

```
ddns-update-style none;
option domain-name "robotis.com";
option domain-name-servers 168.126.63.1, 8.8.8.8;
default-lease-time 600;
max-lease-time 7200;
authoritative;
log-facility local7;
subnet 192.168.123.0 netmask 255.255.255.0 {
    range 192.168.123.100 192.168.123.200;
    option subnet-mask 255.255.255.0;
    option broadcast-address 255.255.255.0;
    option routers 192.168.123.1;
}
```

Meaning: plug a laptop's Ethernet into the robot, and the robot hands out `192.168.123.100–.200`, advertising itself (`.1`) as both router and DNS-forwarder hop. This is the official "field debug" mode.

### SSH

`/etc/init/ssh.conf` starts `/usr/sbin/sshd -D` on `runlevel [2345]` with `respawn` (10 attempts in 5 s). So SSH-in is the supported remote management path.

### mjpg-streamer

No separate mjpg-streamer init script — the demo binary itself hosts the JPEG-over-HTTP feed (Framework: `Camera` → `LinuxCamera` + `HttpServer`-style). Anything served via `robotis/Linux/project/demo/www/` is produced from the same `demo` process started by rc.local.

### NTP

`/etc/init.d/ntp` is wired into `rc2.d/S23ntp`, `rc3.d/S23ntp`, `rc4.d/S23ntp`, `rc5.d/S23ntp`. NTP daemon `/usr/sbin/ntpd` runs at boot. `/etc/cron.daily/ntp` also exists for ntpdate-style sync.

## Display manager / X11

- **DM**: LightDM (typical Ubuntu 12.04 / Lubuntu choice)
- **Auto-login user**: `robotis` (UID 1000, member of `sudo` and `lpadmin`)
- **Default session**: `Lubuntu` (resolves to LXDE + Openbox via `openbox-lubuntu` window manager)
- **System XDG autostart** (`/etc/xdg/autostart/`): standard Lubuntu set — `blueman`, `gnome-keyring`, `nm-applet`, `notification-daemon`, `polkit-gnome-authentication-agent-1`, `print-applet`, `update-notifier`, `vino-server`, `xfce4-power-manager`. **None mention ROBOTIS.**
- **User XDG autostart** (`/home/robotis/.config/autostart/`): `blueman.desktop`, `jockey-gtk.desktop`, `lxrandr-autostart.desktop`, `print-applet.desktop`, `update-notifier.desktop`, `vino-server.desktop`. **None mention ROBOTIS.** Note: `vino-server.desktop` enables VNC.
- **LXSession user autostart** (`~/.config/lxsession/Lubuntu/`): only `desktop.conf` is present; no `autostart` file overrides the system one.
- **System LXSession autostart** (`/etc/xdg/lxsession/Lubuntu/autostart`) verbatim: `@lxpanel --profile Lubuntu`, `@xscreensaver -no-splash`, `@xfce4-power-manager`, `@pcmanfm --desktop --profile lubuntu`, `@/usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1`, `@/usr/lib/vino/vino-server --sm-disable`.

The user's `~/.bashrc` is the stock Ubuntu version with no ROBOTIS lines. `~/.profile` is also stock (just sources `.bashrc` and adds `~/bin` to PATH if present). There is no `.bash_profile`. So nothing about the demo lives in the user's shell startup.

## Time / NTP

- `/etc/timezone`: **`Asia/Seoul`** (Korea — Robotis HQ).
- `/etc/default/rcS`: **`UTC=yes`** — hardware clock is treated as UTC (recommended).
- NTP daemon active on multi-user runlevels.

## What this means for Darwin

- The **Darwin macOS app does not run on the robot's onboard PC** at all. Darwin runs on a Mac, controls the robot over USB-serial to the CM-730 sub-controller. So none of this upstart machinery is "ours" — but it is informative.
- The factory autostart pattern is **delightfully simple**: two lines in `/etc/rc.local`. If we ever ship a replacement onboard daemon (e.g., a custom serial bridge, telemetry forwarder, mjpg streamer), the same hook works on any Ubuntu/Debian and matches the existing operator mental model.
- The factory **expects** the demo to be the foreground onboard process. Our app, by contrast, expects the onboard PC to be either powered off or running the demo — not running our own software. We can probe for "demo is alive" by checking for the LED/sound behavior the factory demo emits at startup ("ROBOTIS!" voice clip), or by SSH-ing in (the demo opens a TCP control port).
- **Network footprint to remember**: when a Mac is connected via Ethernet, the robot becomes a DHCP server on `192.168.123.0/24` and claims `.1`. If the user's Mac is on the same VLAN, the robot's DHCP may compete with their home/office router. The factory expects a **direct-attached Ethernet cable** between Mac and robot. We should document this in the user guide.
- **SSH is always-on** — `respawn` on runlevels 2–5. The factory password (per ROBOTIS docs) is `111111` for `robotis`. For any future "Darwin Studio remote upload" feature, SSH+SFTP is the supported path.
- **Custom kernel `3.2.66-op2`** is loaded by default (`GRUB_DEFAULT=0`). Replacing the kernel would require updating `/etc/default/grub` + `update-grub`. We should never need to do this from the Mac app.
- The 10-second sleep in rc.local is a hint: any onboard hardware-dependent service we deploy should similarly tolerate a settle window for USB serial enumeration.

## Evidence

Absolute paths cited:

1. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/rc.local`
2. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init.d/rc.local`
3. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/rc2.d/S99rc.local`
4. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/lightdm/lightdm.conf`
5. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/lightdm/users.conf`
6. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init/lightdm.conf`
7. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init/rc-sysinit.conf`
8. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init/rc.conf`
9. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init/ssh.conf`
10. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init/networking.conf`
11. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init/network-manager.conf`
12. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init/isc-dhcp-server.conf`
13. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init/tty1.conf`
14. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init/failsafe.conf`
15. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/network/interfaces`
16. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/dhcp/dhcpd.conf`
17. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/default/isc-dhcp-server`
18. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/default/grub`
19. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/default/rcS`
20. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/boot/grub/grub.cfg`
21. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/boot/vmlinuz-3.2.66-op2`
22. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/timezone`
23. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/hostname`
24. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/lsb-release`
25. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/passwd`
26. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/group`
27. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init.d/ntp`
28. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/rc2.d/S23ntp`
29. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/init.d/networking`
30. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/home/robotis/.bashrc`
31. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/home/robotis/.profile`
32. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/home/robotis/.dmrc`
33. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/home/robotis/.config/autostart/`
34. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/home/robotis/.config/lxsession/Lubuntu/desktop.conf`
35. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/xdg/autostart/`
36. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/xdg/lxsession/Lubuntu/autostart`
37. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/demo` — the demo binary launched by rc.local
