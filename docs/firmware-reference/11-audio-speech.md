# 11 — Audio & Speech (ROBOTIS-OP2 Factory Firmware)

## TL;DR
The factory firmware has **no TTS engine** — all spoken output is pre-recorded MP3 clips played by `madplay` (libmad fixed-point MPEG player) via `fork()` + `execl()`. There are **25 MP3 assets** under `robotis/Data/mp3/` covering motion announcements, soccer/vision-demo modes, calibration results, and short verbal reactions ("Wow", "Oops", "Bye bye"). ALSA is installed (`alsa-base`, `alsa-utils`, `libasound2`) but **no `/etc/asound.conf` is present** — the system relies on ALSA defaults plus the standard `modprobe.d/alsa-base.conf` blacklist tuning.

## MP3 asset inventory
Path: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Data/mp3/`
All files dated 2015-03-25. Total: **25 MP3 files**.

| File | Size (bytes) | Likely purpose (inferred from name) |
|---|---|---|
| Autonomous soccer mode.mp3 | 11,441 | Mode announcement when entering autonomous soccer demo |
| Bye bye.mp3 | 5,956 | Farewell reaction (color/touch trigger) |
| Clap please.mp3 | 8,620 | Cue to audience to clap |
| Demonstration ready mode.mp3 | 12,382 | Boot/ready state announcement |
| Headstand.mp3 | 19,676 | Headstand motion narration |
| Interactive motion mode.mp3 | 11,912 | Mode announcement for interactive demo |
| Introduction.mp3 | 131,187 | Long-form self-introduction (largest clip) |
| Left kick.mp3 | 17,586 | Soccer-demo left kick narration |
| No.mp3 | 13,824 | Negative verbal reaction |
| Oops.mp3 | 6,583 | Error/failure exclamation |
| Right kick.mp3 | 18,840 | Soccer-demo right kick narration |
| Sensor calibration complete.mp3 | 14,263 | Calibration success notification |
| Sensor calibration fail.mp3 | 13,322 | Calibration failure notification |
| Shoot.mp3 | 15,914 | Soccer-demo shoot action narration |
| Sit down.mp3 | 7,680 | Sit-down motion announcement |
| Stand up.mp3 | 7,836 | Stand-up motion announcement |
| Start motion demonstration.mp3 | 13,479 | Mode-entry cue for motion demo |
| Start soccer demonstration.mp3 | 13,479 | Mode-entry cue for soccer demo |
| Start vision processing demonstration.mp3 | 16,927 | Mode-entry cue for vision demo |
| System shutdown.mp3 | 26,781 | Shutdown announcement |
| Thank you.mp3 | 6,583 | Positive verbal reaction |
| Vision processing mode.mp3 | 10,814 | Mode announcement for vision demo |
| Wow.mp3 | 9,717 | Positive surprise reaction |
| Yes go.mp3 | 9,561 | Affirmative + command verbal cue |
| Yes.mp3 | 17,168 | Affirmative verbal reaction |

## Playback mechanism
- **Tool**: `madplay` (MAD-library MPEG audio player, fixed-point). Hardcoded absolute path `/usr/bin/madplay` is used.
- **Invocation from C++**: `fork()` a child, then `execl("/usr/bin/madplay", "madplay", filename, "-q", (char*)0)` in the child. The parent stores the PID so a previous still-running player can be `kill(mp3_pid, SIGKILL)`-ed before a new clip starts. The `-q` flag suppresses madplay's stdout messages.
- **API surface** (`robotis/Linux/include/LinuxActionScript.h`):
  - `int LinuxActionScript::PlayMP3(const char* filename)` — fire-and-forget; returns immediately, child plays in background.
  - `int LinuxActionScript::PlayMP3Wait(const char* filename)` — same exec, but parent `waitpid()`s for the child to finish before returning. Used when subsequent code must not overlap audio (e.g. calibration-fail announcement before the next prompt).
- **Path convention**: callers pass relative paths like `"../../../Data/mp3/Demonstration ready mode.mp3"` because the demo binary runs from `robotis/Linux/project/demo/` and walks up three levels to reach `robotis/Data/mp3/`.

Code excerpt (`robotis/Linux/build/LinuxActionScript.cpp`, lines 116-138 — `PlayMP3`):
```cpp
int LinuxActionScript::PlayMP3(const char* filename)
{
    if(mp3_pid != -1)
        kill(mp3_pid, SIGKILL);

    mp3_pid = fork();

    switch(mp3_pid)
    {
    case -1:
        fprintf(stderr, "Fork failed!! \n");
        break;
    case 0:
        fprintf(stderr, "Playing MPEG stream from \"%s\" ...\n", filename);
        execl("/usr/bin/madplay", "madplay", filename, "-q", (char*)0);
        fprintf(stderr, "exec failed!! \n");
        break;
    default:
        break;
    }

    return 1;
}
```

`PlayMP3Wait` differs only in the parent branch, which calls `waitpid(mp3_pid, &status, 0)` instead of returning immediately.

Representative caller sites:
- `robotis/Linux/project/demo/main.cpp:148` — boot announcement `Demonstration ready mode.mp3`
- `robotis/Linux/project/demo/StatusCheck.cpp:82-254` — 11 call sites announcing soccer/motion/vision modes, calibration result, sub-mode transitions
- `robotis/Linux/project/demo/VisionMode.cpp:35-63` — color-detection-driven verbal reactions ("Thank you", "Wow", "Oops", "Sit down" + action page 15, "Stand up" + action page 1, etc.)

## TTS (if present)
**None.** No `espeak`, `festival`, `flite`, or any other speech-synthesis engine is installed (verified by `grep` over `dpkg/status` and the `robotis/` source tree — zero matches). All "speech" the robot emits is pre-recorded human-voice MP3 clips authored at ROBOTIS and shipped under `robotis/Data/mp3/`. Adding new utterances requires producing a new MP3 file and adding a `LinuxActionScript::PlayMP3()` call — there is no runtime text-to-speech path.

## ALSA config
- **`/etc/asound.conf`**: **does not exist** on this rootfs (no system-wide ALSA override). Default ALSA card-0 / device-0 routing applies.
- **`/etc/modprobe.d/alsa-base.conf`** (44 lines): standard Ubuntu 12.04 ALSA module-load tuning. Key behaviors:
  - Autoload helpers for `sound-slot-0` through `sound-slot-7` via `modprobe snd-card-N`.
  - When `snd` loads, also load `snd-ioctl32` and `snd-seq`.
  - **Forces non-priority index** (`index=-2`, i.e. never become card 0) for: `bt87x`, `cx88_alsa`, `saa7134-alsa`, `snd-atiixp-modem`, `snd-intel8x0m`, `snd-via82xx-modem`, `snd-usb-audio`, `snd-usb-caiaq`, `snd-usb-ua101`, `snd-usb-us122l`, `snd-usb-usx2y`, `snd-pcsp`. This keeps the internal Intel HDA (or similar) audio chip as card 0.
  - `snd-cmipci`: MPU port `0x330`, FM port `0x388`.
- **Init scripts**: `/etc/init/alsa-store.conf`, `/etc/init/alsa-restore.conf`, `/etc/init.d/alsa-store`, `/etc/init.d/alsa-restore` — standard `alsa-utils` boot/shutdown hooks that save and restore mixer state.
- **Default device**: ALSA's compiled-in default (`default` PCM → first card, first device). `madplay` opens this implicitly; no per-app routing override is configured.

## Audio packages installed
From `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/var/lib/dpkg/status`:

| Package | Version | Role |
|---|---|---|
| `madplay` | 0.15.2b-7build1 | MPEG audio player in fixed point — the actual MP3 playback binary used by `LinuxActionScript` |
| `libmad0` | (installed) | MAD MPEG audio decoder library backing madplay |
| `mpg321` | 0.2.13-4ubuntu1 | Alternate MP3 player; **installed but not referenced** by the demo source (madplay wins via the hardcoded `execl` path) |
| `alsa-base` | (installed) | ALSA module loader + base configuration |
| `alsa-utils` | (installed) | `aplay`, `amixer`, `alsactl` userspace tools |
| `libasound2` | (installed) | ALSA userspace library (linked by madplay and others) |
| `libsdl1.2debian` | (installed) | SDL 1.2 — present likely for unrelated demos/tools; not used by the audio path |

No `espeak*`, `festival*`, `flite*`, `speech-dispatcher*`, `pulseaudio*`, or `jackd*` packages are present.

## What this means for Darwin
- Darwin's current sprint is the Mac UI / Studio app, so on-robot audio is **out of scope**. If we ever ship a Darwin agent that runs on the robot, the established pattern is dead simple: drop MP3s into `robotis/Data/mp3/` and `fork`+`execl /usr/bin/madplay file.mp3 -q`. No daemons, no IPC, no ALSA tuning needed beyond the factory defaults.
- The **25-clip asset list above is a baseline vocabulary of robot state cues** — if we ever want feature parity with the factory demo (mode announcements, calibration outcomes, soccer narration, interactive reactions), this is the catalogue to mirror. A future Mac-side TTS feature (e.g. AVSpeechSynthesizer or an LLM-driven voice line generator) could replace the static MP3 set with a dynamic one — but the *trigger points* in `main.cpp`, `StatusCheck.cpp`, and `VisionMode.cpp` are the canonical map of "when does the robot speak."
- Because there is **no TTS engine on the robot**, any "speak this arbitrary string" capability must be generated off-board (Mac/cloud) and either streamed as audio or pre-rendered to MP3 — the robot itself can only play files. Plan accordingly if voice synthesis ever appears on the Darwin roadmap.

## Evidence
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Data/mp3/` (directory listing — 25 MP3 files)
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxActionScript.h` (API definition — `PlayMP3` / `PlayMP3Wait`)
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/LinuxActionScript.cpp` (implementation — `fork()` + `execl("/usr/bin/madplay", ...)`)
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/main.cpp` (line 148 — boot announcement call site)
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/StatusCheck.cpp` (lines 82-254 — 11 mode/calibration call sites)
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/VisionMode.cpp` (lines 35-63 — color-trigger verbal reactions)
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/modprobe.d/alsa-base.conf` (ALSA module config)
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/var/lib/dpkg/status` (package inventory — confirms madplay 0.15.2b-7build1, mpg321 0.2.13-4ubuntu1, alsa-base, alsa-utils, libasound2, libmad0; no TTS engines)
