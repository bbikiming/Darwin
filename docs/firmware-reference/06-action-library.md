# 06 — Action Library + Scripts (ROBOTIS-OP2 Factory Firmware)

## TL;DR

Motion pages stored in `motion_4096.bin` are invoked by code via a single C++
call: `Action::GetInstance()->Start(pageNumber)`. The factory ships two ways to
trigger them — a terminal-based `action_editor` (ncurses TUI for authoring/
playing pages live) and a `script.asc` text format (page-number + MP3 pairs,
played sequentially by `LinuxActionScript`). On boot, `/etc/rc.local` waits 10s
then launches `/robotis/Linux/project/demo/demo`, which plays page 15 ("sit /
init") as its startup pose, then drives a state machine where the user picks
modes via the CM-740 hardware buttons (READY → SOCCER → MOTION → VISION).

## Action.h class API

The Action class is a singleton motion module — only one instance, accessed via
`Action::GetInstance()`. It inherits from `MotionModule` and is registered with
`MotionManager` to receive periodic `Process()` ticks at the 8ms motion-control
rate.

Public surface (verbatim from
`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Action.h`):

```cpp
namespace Robot
{
    class Action : public MotionModule
    {
    public:
        enum {
            MAXNUM_PAGE = 256,   // 256 pages (index 0 reserved, 1..255 usable)
            MAXNUM_STEP = 7,     // 7 keyframes per page
            MAXNUM_NAME = 13     // page name max length
        };

        enum {
            SPEED_BASE_SCHEDULE = 0,     // playback speed driven by Page.speed
            TIME_BASE_SCHEDULE  = 0x0a   // playback driven by Step.time (x8ms)
        };

        enum {
            INVALID_BIT_MASK    = 0x4000,  // joint position is "don't care"
            TORQUE_OFF_BIT_MASK = 0x2000   // joint torque is off (free-swing)
        };

        // Singleton
        static Action* GetInstance();

        // Lifecycle / file ops
        void Initialize();
        void Process();                          // called by MotionManager every 8ms
        bool LoadFile(char* filename);           // open motion_4096.bin
        bool CreateFile(char* filename);         // build a fresh empty binary

        // Playback
        bool Start(int iPage);                   // play page by index 1..255
        bool Start(char* namePage);              // play page by name (linear scan)
        bool Start(int index, PAGE *pPage);      // play an in-memory page
        void Stop();                             // request stop after current step
        void Brake();                            // hard stop (joints freeze in place)
        bool IsRunning();                        // returns m_Playing
        bool IsRunning(int *iPage, int *iStep);  // also reports current page+step

        // Page CRUD (action_editor uses these)
        bool LoadPage(int index, PAGE *pPage);
        bool SavePage(int index, PAGE *pPage);
        void ResetPage(PAGE *pPage);

        bool DEBUG_PRINT;  // toggles stderr logging
    };
}
```

Key behaviors from the implementation
(`firmware-backups/sda1-rootfs/robotis/Framework/src/motion/modules/Action.cpp`):

- `Start(int iPage)` calls `LoadPage()` then the three-arg `Start()`. Returns
  `false` if (a) the index is out of range, (b) `m_Playing` is already true,
  (c) page repeat-count is 0 or stepnum is 0.
- `Start(char* namePage)` does a linear scan over all 256 pages comparing
  `page.header.name` to the string — so name-based lookup is O(N) and re-reads
  the file each call.
- `Stop()` only sets a flag; the run actually ends after the current step
  completes. `Brake()` flips `m_Playing` to false immediately.
- After a page finishes, the engine can chain to `header.next` (a page index)
  for sequence playback. `header.exit` is the page to jump to when Stop() is
  requested — typically a "return to neutral" page.

## action_editor project

Source: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/action_editor/`

```
action_editor/
├── Makefile          (links ncurses + darwin.a, builds binary `action_editor`)
├── cmd_process.h     (UI constants + command function prototypes)
├── cmd_process.cpp   (~1376 lines — all the screen drawing + command logic)
└── main.cpp          (signal handlers, command dispatcher loop)
```

### What main.cpp does

1. Accepts an optional motion-file path argument (defaults to
   `../../../Data/motion_4096.bin` or `motion_1024.bin` if compiled with the
   legacy MX-28 resolution flag).
2. If the file doesn't exist, prompts the user to create a new one
   (`Action::CreateFile()`).
3. Initializes `MotionManager` against `/dev/ttyUSB0` and registers the Action
   module — but stops the motion timer (`motion_timer->Stop()`). Live motion is
   only resumed when the user issues the `play` command.
4. Enters a key-driven editing loop with arrow-key navigation, `[`/`]` to
   nudge values by 1, `{`/`}` by 10, and space to toggle torque on the
   currently-selected joint.

### Build target

Output binary: `action_editor` in the same directory. Depends on
`../../lib/darwin.a` (the framework static lib) and links against
`-lpthread -lncurses -lrt`.

### Terminal UI

Requires an 80x24 terminal (constants `SCREEN_COL=80`, `SCREEN_ROW=24` in
`cmd_process.h`). The layout dedicates columns 19-55 to the 8 step columns
(STP7 = current live pose, STP0-6 = saved keyframes for the page), columns
60-61 to per-joint compliance slope (CW/CCW, 1-7), and the right edge to
page header fields (name, number, repeat, stepnum, speed, accel, next, exit).

### Command set

Commands are typed on the bottom row. Full list from the in-app `help` output
(`firmware-backups/sda1-rootfs/robotis/Linux/project/action_editor/cmd_process.cpp:884-913`):

| Command | Args | Effect |
|---|---|---|
| `exit` | — | Quit (prompts to save if edited) |
| `re` | — | Refresh screen |
| `n` / `b` | — | Next / previous page |
| `page` | `<index>` | Jump to page index |
| `list` | — | Show 3-page grid of all 256 page names |
| `new` | — | Clear current page to defaults |
| `copy` | `<index>` | Copy contents of page `<index>` into current |
| `set` | `<value>` | Set value at cursor |
| `save` | — | Write current page back to the .bin file |
| `play` | — | Execute the current page on the robot |
| `g` | `<index>` | "Goto step" — drive joints toward STP[index] |
| `name` | (interactive) | Set the 13-char page name |
| `time` / `speed` | — | Switch page between time-base / speed-base schedule |
| `w` | `<index>` | Write the live pose (STP7) into STP[index] |
| `i` | `[index]` | Insert live pose at step index (shift rest right) |
| `m` | `<src> <dst>` | Move a step from src to dst slot |
| `d` | `<index>` | Delete step (shift rest left) |
| `on` / `off` | `[id1 id2 ...]` | Torque on/off — all joints or listed IDs |

### Live playback flow inside the editor

`PlayCmd()` (`cmd_process.cpp:966-1049`) is interesting because it shows the
minimum surface to play a page in-process:

1. Validate that no step contains `INVALID_BIT_MASK` joints.
2. Sync the current joint positions into `MotionStatus::m_CurrentJoints` so
   the action interpolates from where the robot actually is.
3. `timer->Start()` resumes the 8ms motion tick.
4. Enable the body joints: `Action::GetInstance()->m_Joint.SetEnableBody(true, true)`.
5. Enable the motion manager: `MotionManager::GetInstance()->SetEnable(true)`.
6. Kick off: `Action::GetInstance()->Start(indexPage, &Page)`.
7. Poll `IsRunning()` at 10ms while listening for `s` (Stop) or `b` (Brake).
8. Disable motion manager and stop the timer when done.

This same recipe applies to any external invoker.

## action_script tutorial

The tutorial proves you only need ~30 lines to wire up motion playback.

### `tutorial/action_script/config.ini` — verbatim

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/config.ini`:

```ini
[Camera]
# -1 : reset control
Brightness  = -1    # reset value
Contrast    = -1    # reset value
Saturation  = -1    # reset value
Gain        = 255
Exposure    = 1000

[Find Color]
hue             = 355
hue_tolerance   = 15
min_saturation  = 60
min_value       = 15
min_percent     = 0.2
max_percent     = 10.0

[Head Pan/Tilt]
pan_p_gain      = 0.2
pan_d_gain      = 0.75
tilt_p_gain     = 0.2
tilt_d_gain     = 0.75
left_limit      = 80.0
right_limit     = -80.0
top_limit       = 0.0
bottom_limit    = -68.0
pan_home        = 0.0
tilt_home       = -30.0

[Walking Config]
x_offset                    = 0.0;
y_offset                    = 5.0;
z_offset                    = 10.0;
a_offset                    = 0.0;
p_offset                    = 0.0;
r_offset                    = 0.0;
period_time                 = 600.0;
dsp_ratio                   = 0.1;
z_move_amplitude            = 35.0;
balance_knee_gain           = 0.2;
balance_ankle_pitch_gain    = 0.6;
balance_hip_roll_gain       = 0.6;
balance_ankle_roll_gain     = 1.2;
y_swap_amplitude            = 19.0;
z_swap_amplitude            = 6.0;
arm_swing_gain              = 0.8;
pelvis_offset               = 10;
hip_pitch_offset            = 60;
```

Note: the action_script tutorial loads this config but only the `[Head Pan/Tilt]`
and walking config sections are actually unused by Action — they're inherited
from the demo template.

### `tutorial/action_script/main.cpp` — the canonical "play a motion" recipe

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/main.cpp`:

```cpp
#include "Action.h"
#include "MotionManager.h"
#include "LinuxMotionTimer.h"
#include "LinuxCM730.h"
#include "LinuxActionScript.h"

#define MOTION_FILE_PATH    "../../../../Data/motion_4096.bin"
#define INI_FILE_PATH       "../../../../Data/config.ini"

int main(void)
{
    printf("\n===== Action script Tutorial for DARwIn =====\n\n");

    minIni* ini = new minIni(INI_FILE_PATH);

    change_current_dir();
    Action::GetInstance()->LoadFile(MOTION_FILE_PATH);

    // ---- Framework Init ----
    LinuxCM730 linux_cm730("/dev/ttyUSB0");
    CM730 cm730(&linux_cm730);
    if(MotionManager::GetInstance()->Initialize(&cm730) == false) {
        printf("Fail to initialize Motion Manager!\n");
        return 0;
    }
    MotionManager::GetInstance()->LoadINISettings(ini);
    MotionManager::GetInstance()->AddModule((MotionModule*)Action::GetInstance());

    LinuxMotionTimer *motion_timer = new LinuxMotionTimer(MotionManager::GetInstance());
    motion_timer->Start();

    MotionManager::GetInstance()->SetEnable(true);

    // ---- Boot pose ----
    Action::GetInstance()->Start(1);  /* Init(stand up) pose */
    while(Action::GetInstance()->IsRunning()) usleep(8*1000);

    printf("Press the ENTER key to begin!\n");
    getchar();

    // ---- Play the script.asc sequence ----
    LinuxActionScript::ScriptStart("script.asc");
    while(LinuxActionScript::m_is_running == 1) sleep(10);

    return 0;
}
```

Takeaways:

- A single `Action::GetInstance()->Start(1)` plays a complete motion page.
- The 8ms `usleep` is the conventional poll interval (matches the motion-tick
  rate).
- Page `1` is the universal "stand up / init pose" by convention.

### The `script.asc` sequence format

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/script.asc`:

```
(4,../../../../Data/mp3/Thank you.mp3)
(41,../../../../Data/mp3/Introduction.mp3)
(24,../../../../Data/mp3/Wow.mp3)
(23,../../../../Data/mp3/Yes go.mp3)
(15,../../../../Data/mp3/Sit down.mp3)
(1,../../../../Data/mp3/Stand up.mp3)
(54,../../../../Data/mp3/Clap please.mp3)
(27,../../../../Data/mp3/Oops.mp3)
(38,../../../../Data/mp3/Bye bye.mp3)
```

Each line is `(<page_number>,<mp3_path>)`. The format is parsed by
`LinuxActionScript::ParseLine()` — see
`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/LinuxActionScript.cpp:34-59`.
The script thread (`ScriptThreadProc`) forks `madplay` for the MP3, then
calls `Action::GetInstance()->Start(pagenumber)` and waits for it to finish
before advancing.

The demo binary uses the same format at
`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/script.asc`
(identical content, different relative paths).

## Predefined action sequences (hardcoded page numbers in source)

There are **no `#define PAGE_X` constants in the headers**. Page numbers are
inlined as magic numbers in the source files, with brief `//` comments giving
their meaning. Below is the complete map of every page reference in the project
tree (excluding `.svn` and `.o` build artifacts):

| Page | Used by | Meaning (inferred from code comments + script.asc + MP3 names) |
|---:|---|---|
| 1 | `tutorial/action_script/main.cpp:69`, `demo/StatusCheck.cpp:246, 259`, `demo/VisionMode.cpp:58`, `script.asc` | **Init / stand up** — the canonical boot pose |
| 4 | `demo/VisionMode.cpp:34`, `script.asc` | "Thank you" gesture (RED color detected) |
| 9 | `demo/StatusCheck.cpp:89, 210` | Pre-soccer ready pose (called before walking) |
| 10 | `demo/StatusCheck.cpp:49` | **Forward get-up** (recovery from face-down fall) |
| 11 | `demo/StatusCheck.cpp:51` | **Backward get-up** (recovery from face-up fall) |
| 12 | `demo/main.cpp:282` | **Right kick** |
| 13 | `demo/main.cpp:287` | **Left kick** |
| 15 | `demo/main.cpp:149`, `demo/StatusCheck.cpp:68, 86, 155`, `demo/VisionMode.cpp:54`, `script.asc` | **Sit down / rest pose** — used as both startup and end-of-mode posture |
| 23 | `script.asc` | "Yes go" gesture |
| 24 | `demo/VisionMode.cpp:42`, `script.asc` | "Wow" gesture (BLUE color detected) |
| 27 | `demo/VisionMode.cpp:62`, `script.asc` | "Oops" gesture (RED+YELLOW+BLUE all detected) |
| 38 | `demo/VisionMode.cpp:46`, `script.asc` | "Bye bye" gesture (RED+YELLOW detected) |
| 41 | `demo/VisionMode.cpp:38`, `script.asc` | "Introduction" gesture (YELLOW detected) |
| 54 | `demo/VisionMode.cpp:50`, `script.asc` | "Clap please" gesture (RED+BLUE detected) |

All other 240 pages exist on disk (`motion_4096.bin` is a fixed 256-page array)
but are not invoked from any C++ code. They are accessible only via the
`action_editor`'s `page <N>` command or via custom user scripts.

### Why no PAGE_X macros?

The factory's convention is that motion authors edit `motion_4096.bin` with
`action_editor`, name each page (13-char string in `page.header.name`), and
either (a) reference by page-number magic in their own code or (b) call
`Action::Start(char* namePage)` for a slower string-based lookup. There's no
generated header that bridges page names to compile-time constants.

## Boot-time action sequence

The autostart wiring is **dead simple**.

### `/etc/rc.local`

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/rc.local`:

```sh
#!/bin/sh -e
#
# rc.local

sleep 10
/robotis/Linux/project/demo/demo

exit 0
```

The 10s sleep gives the kernel time to enumerate `/dev/ttyUSB0` and let other
boot services settle. Then the `demo` binary launches with no arguments.

### What the demo binary does on startup

From `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/main.cpp:51-150`:

1. Set up signal handlers (SIGABRT/SIGTERM/SIGQUIT/SIGINT → clean exit).
2. Load `../../../Data/config.ini`.
3. Initialize camera, mjpg_streamer (web preview), color finders for ball /
   red / yellow / blue.
4. Try `MotionManager::Initialize(&cm730)` against `/dev/ttyUSB0`; if it fails,
   fall back to `/dev/ttyUSB1`.
5. Register Action, Head, and Walking modules with MotionManager. Start the
   8ms motion timer.
6. Load `motion_4096.bin` (or `motion_1024.bin` if MX-28 firmware is older
   than 0x1B).
7. Enable body joints + motion manager.
8. Light up all three LEDs on the CM-740 panel (`0x01|0x02|0x04`).
9. **Play boot MP3**: `LinuxActionScript::PlayMP3("../../../Data/mp3/Demonstration ready mode.mp3")`.
10. **Play boot motion**: `Action::GetInstance()->Start(15)` (the sit/rest pose).
11. Wait for that motion to finish, then enter the main mode loop.

So the boot animation = MP3 announcement + page 15 sit-down. There's no
elaborate "wave-and-stand" intro — the robot simply settles into the sit pose
with verbal confirmation.

### Mode state machine (button-driven, not auto)

After boot, the demo binary's main loop polls `StatusCheck::Check()`. The
CM-740's hardware buttons (BTN_MODE, BTN_START) drive a 4-state cycle:

- **READY** (default after boot): LEDs `0x01|0x02|0x04`, MP3 "Demonstration ready mode"
- **SOCCER**: LED `0x01`, MP3 "Autonomous soccer mode" — ball tracking + walking + kicks (pages 9, 10, 11, 12, 13, 15)
- **MOTION**: LED `0x02`, MP3 "Interactive motion mode" — plays `script.asc` (pages 1, 4, 15, 23, 24, 27, 38, 41, 54)
- **VISION**: LED `0x04`, MP3 "Vision processing mode" — color-triggered gestures (pages 1, 4, 15, 24, 27, 38, 41, 54)

Mode-change handler at `StatusCheck.cpp:142-187`. Start-button handler at
`StatusCheck.cpp:189-267`.

There is also a hidden "CHICAGO MODE" — if the user holds the User button for
90+ ticks while in READY, the robot enters a self-cycling soccer demo that
plays for 120s, rests for 60s, recalibrates the gyro, and repeats.

## Page registry — what's "used"

Cross-reference with the motion-library agent's page catalog. Pages explicitly
invoked by Start() calls in C++ source (i.e., shipped behavior, not just
content-on-disk):

| Page | Status | Role |
|---:|---|---|
| 1 | **USED** | Init / stand up |
| 4 | **USED** | "Thank you" gesture |
| 9 | **USED** | Pre-soccer ready |
| 10 | **USED** | Forward get-up |
| 11 | **USED** | Backward get-up |
| 12 | **USED** | Right kick |
| 13 | **USED** | Left kick |
| 15 | **USED** | Sit / rest (boot pose) |
| 23 | **USED** | "Yes go" |
| 24 | **USED** | "Wow" |
| 27 | **USED** | "Oops" |
| 38 | **USED** | "Bye bye" |
| 41 | **USED** | "Introduction" |
| 54 | **USED** | "Clap please" |
| 2-3, 5-8, 14, 16-22, 25-26, 28-37, 39-40, 42-53, 55-255 | **unused** by code | Content exists in `.bin` but no code references — author intent unknown without inspecting each page's name in `action_editor` |

14 of 256 pages are wired up. The remaining 242 are either (a) intermediate
build-up pages chained via `header.next`, (b) test/development pages, or
(c) factory placeholders awaiting customization.

## What this means for Darwin (our project)

### Should Darwin's Mac app expose an "action button" UI?

Yes — this is the single highest-value affordance from the factory firmware
that maps cleanly to our SwiftUI Studio. The factory shipped exactly 14
human-facing motions (the table above), each invokable with one C function
call. We should expose those 14 as preset action buttons (with the same MP3
labels for clarity: "Thank you", "Wow", "Introduction", "Bye bye", "Sit down",
"Stand up", "Clap please", "Oops", "Yes go", plus the 5 utility poses).

The "play arbitrary page 1-255" command should also be exposed for advanced
users (matches the action_editor's `play` command).

### Suggested Rust API

Drop-in replacement for the C++ `Action::GetInstance()->Start(int)`:

```rust
pub mod action {
    use crate::motion::page::MotionPage;
    use crate::cm730::Cm730;

    pub struct Action {
        loaded_file: Option<MotionFile>,  // motion_4096.bin parsed into pages
        playing: Option<PlaybackState>,
    }

    impl Action {
        /// Load motion_4096.bin from disk into memory.
        pub fn load_file(&mut self, path: &Path) -> Result<()>;

        /// Play page by index (1..=255). Returns immediately;
        /// poll `is_running()` to wait for completion.
        pub fn start(&mut self, page: u8) -> Result<()>;

        /// Play page by name (linear scan over header.name).
        pub fn start_named(&mut self, name: &str) -> Result<()>;

        /// Stop after the current step completes.
        pub fn stop(&mut self);

        /// Immediate hard stop — joints freeze in place.
        pub fn brake(&mut self);

        pub fn is_running(&self) -> bool;
        pub fn current_page(&self) -> Option<u8>;
        pub fn current_step(&self) -> Option<u8>;
    }
}
```

A convenient higher-level wrapper for the UI:

```rust
pub enum PresetAction {
    StandUp,         // page 1
    SitDown,         // page 15
    ThankYou,        // page 4
    Wow,             // page 24
    Introduction,    // page 41
    YesGo,           // page 23
    ClapPlease,      // page 54
    Oops,            // page 27
    ByeBye,          // page 38
    KickRight,       // page 12
    KickLeft,        // page 13
    GetUpForward,    // page 10
    GetUpBackward,   // page 11
    SoccerReady,     // page 9
}

impl PresetAction {
    pub const fn page(&self) -> u8 { ... }
    pub const fn label(&self) -> &'static str { ... }
    pub const fn mp3(&self) -> Option<&'static str> { ... }
}
```

### Boot animation — should Darwin mimic the factory?

**Yes, but adapt**. The factory does:

```
sleep(10s) → demo binary launches → MP3 "Demonstration ready mode" + page 15 (sit pose)
```

Recommendation for Darwin:

1. **Keep the page-15 sit pose** as the safe starting posture — it's what every
   ROBOTIS-OP2 owner expects, and it's the most stable joint configuration for
   power-on. Replacing it would risk torque spikes if the bot is in a different
   pose when our app connects.
2. **Drop the 10s rc.local sleep** — Darwin connects over WiFi/USB on demand,
   not at boot, so this is moot.
3. **Replace the MP3 announcement** with a Mac system sound (or skip
   entirely) — the factory MP3s are Korean-accented English and clash with
   our Conversational UX direction.
4. Consider playing page 1 (stand up) on user-initiated "Connect" rather than
   auto-stand on boot, since the bot may be docked or in storage when first
   powered.

## Evidence

All paths are absolute, all confirmed to exist at the time of writing.

1. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Action.h`
2. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/motion/modules/Action.cpp`
3. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/action_editor/Makefile`
4. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/action_editor/main.cpp`
5. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/action_editor/cmd_process.h`
6. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/action_editor/cmd_process.cpp`
7. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/main.cpp`
8. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/config.ini`
9. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/script.asc`
10. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/Makefile`
11. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxActionScript.h`
12. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/LinuxActionScript.cpp`
13. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/main.cpp`
14. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/StatusCheck.cpp`
15. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/VisionMode.cpp`
16. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/script.asc`
17. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/rc.local`
