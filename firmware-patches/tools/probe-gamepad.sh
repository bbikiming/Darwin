#!/bin/bash
# probe-gamepad.sh — RG G01 게임패드 USB 호환성 프로브 (Wave H0)
#
# 대상: DARwIn-OP2, 커널 3.2.66-op2 (i686), evtest/jstest 미설치 환경.
# python2 로 evdev ioctl(EVIOCGABS/EVIOCGKEY/EVIOCGBIT)을 직접 호출한다.
# /dev/input/event* 는 root:root 0640 이므로 root 로 실행해야 한다:
#   echo <pw> | sudo -S -p "" bash /tmp/probe-gamepad.sh <subcommand>
#
# 읽기 전용. 영구 변경 없음 — 허용된 휘발성 조작은 xpad-newid(sysfs new_id)와
# modprobe(재부팅 시 원복)뿐이다. 설계: docs/design/handheld-direct-pilot-upgrade.md §4.
#
# Subcommands:
#   baseline                 — 동글 꽂기 전 스냅샷 저장 (/tmp/df-probe-gamepad/)
#   detect                   — 베이스라인 대비 diff: 신규 USB 장치/입력 노드/드라이버 바인딩
#   caps    <eventN>         — 장치 이름·VID/PID·축 범위(EVIOCGABS)·키 비트맵 덤프
#   rate    <eventN> <sec>   — 이벤트 레이트 측정 (타입별 분류, 기대 125–250Hz)
#   watch   <eventN> <sec>   — 이벤트 실시간 디코드 (코드 테이블 캡처용)
#   monitor <eventN> <sec>   — 링크 단절 시험: 이벤트 + 0.5s 주기 노드 존재/EVIOCGKEY 폴
#   keystate <eventN>        — 현재 눌린 키 1회 스냅샷 (EVIOCGKEY)
#   xpad-newid <VID> <PID>   — xpad 휘발성 바인딩 시도 (예: xpad-newid 045e 028e)

set -u
STATE=/tmp/df-probe-gamepad
mkdir -p "$STATE"
CMD="${1:-help}"

# ── python2 evdev 헬퍼 (단일 heredoc, 모드 디스패치) ─────────────────────────
run_py() { # $1=mode $2=device-or-empty $3=seconds-or-empty
  python2 - "$1" "${2:-}" "${3:-0}" <<'PYEOF'
# -*- coding: utf-8 -*-
import sys, os, fcntl, struct, select, time, array

mode, dev, sec = sys.argv[1], sys.argv[2], float(sys.argv[3])

# i686 / kernel 3.2: struct input_event = timeval(4+4) + u16 type + u16 code + s32 value
EV_FMT = '<llHHi'
EV_SIZE = struct.calcsize(EV_FMT)  # 16

def IOC(d, t, nr, size):
    return (d << 30) | (size << 16) | (ord(t) << 8) | nr
def EVIOCGNAME(l):  return IOC(2, 'E', 0x06, l)
def EVIOCGID():     return IOC(2, 'E', 0x02, 8)
def EVIOCGBIT(ev, l): return IOC(2, 'E', 0x20 + ev, l)
def EVIOCGABS(ax):  return IOC(2, 'E', 0x40 + ax, 24)
def EVIOCGKEY(l):   return IOC(2, 'E', 0x18, l)

EV_NAMES = {0: 'SYN', 1: 'KEY', 2: 'REL', 3: 'ABS', 4: 'MSC', 17: 'LED', 21: 'FF'}
ABS_NAMES = {0: 'ABS_X', 1: 'ABS_Y', 2: 'ABS_Z', 3: 'ABS_RX', 4: 'ABS_RY', 5: 'ABS_RZ',
             6: 'ABS_THROTTLE', 7: 'ABS_RUDDER', 9: 'ABS_GAS', 10: 'ABS_BRAKE',
             16: 'ABS_HAT0X', 17: 'ABS_HAT0Y', 40: 'ABS_MISC'}
KEY_NAMES = {304: 'BTN_A/SOUTH', 305: 'BTN_B/EAST', 306: 'BTN_C', 307: 'BTN_X/NORTH',
             308: 'BTN_Y/WEST', 309: 'BTN_Z', 310: 'BTN_TL(LB)', 311: 'BTN_TR(RB)',
             312: 'BTN_TL2(LT)', 313: 'BTN_TR2(RT)', 314: 'BTN_SELECT', 315: 'BTN_START',
             316: 'BTN_MODE', 317: 'BTN_THUMBL', 318: 'BTN_THUMBR',
             544: 'BTN_DPAD_UP', 545: 'BTN_DPAD_DOWN', 546: 'BTN_DPAD_LEFT',
             547: 'BTN_DPAD_RIGHT', 288: 'BTN_TRIGGER', 289: 'BTN_THUMB'}

def key_name(c): return KEY_NAMES.get(c, 'KEY_%d' % c)
def abs_name(c): return ABS_NAMES.get(c, 'ABS_%d' % c)

def held_keys(fd):
    buf = array.array('B', [0] * 96)  # KEY_MAX 0x2ff/8 = 96 bytes
    fcntl.ioctl(fd, EVIOCGKEY(96), buf, True)
    return [i for i in range(96 * 8) if buf[i / 8] & (1 << (i % 8))]

def open_dev():
    return os.open(dev, os.O_RDONLY | os.O_NONBLOCK)

def close_quiet(fd):
    # 장치가 이미 분리됐으면(ENODEV) close 의 evdev flush 가 OSError 를 던진다 —
    # 데이터 손실은 없으므로 exit code 오염만 막는다.
    try:
        os.close(fd)
    except OSError:
        pass

if mode == 'caps':
    fd = open_dev()
    name = array.array('B', [0] * 256)
    fcntl.ioctl(fd, EVIOCGNAME(256), name, True)
    print('name    : %s' % name.tostring().split('\x00')[0])
    gid = array.array('B', [0] * 8)
    fcntl.ioctl(fd, EVIOCGID(), gid, True)
    bus, vid, pid, ver = struct.unpack('<4H', gid.tostring())
    print('id      : bus=0x%04x vendor=0x%04x product=0x%04x version=0x%04x' % (bus, vid, pid, ver))
    # 지원 이벤트 타입
    evbits = array.array('B', [0] * 4)
    fcntl.ioctl(fd, EVIOCGBIT(0, 4), evbits, True)
    evmask = struct.unpack('<I', evbits.tostring())[0]
    types = [EV_NAMES.get(i, str(i)) for i in range(32) if evmask & (1 << i)]
    print('ev types: %s' % ' '.join(types))
    # ABS 축: 비트맵 → 각 축 EVIOCGABS
    if evmask & (1 << 3):
        absbits = array.array('B', [0] * 8)  # ABS_MAX 0x3f
        fcntl.ioctl(fd, EVIOCGBIT(3, 8), absbits, True)
        print('--- ABS axes (value/min/max/fuzz/flat/res) ---')
        for ax in range(64):
            if absbits[ax / 8] & (1 << (ax % 8)):
                info = array.array('B', [0] * 24)
                fcntl.ioctl(fd, EVIOCGABS(ax), info, True)
                v, mn, mx, fz, fl, res = struct.unpack('<6i', info.tostring())
                print('%-12s code=%-3d value=%-6d min=%-7d max=%-6d fuzz=%-4d flat=%-4d res=%d'
                      % (abs_name(ax), ax, v, mn, mx, fz, fl, res))
    # KEY 비트맵
    if evmask & (1 << 1):
        keybits = array.array('B', [0] * 96)
        fcntl.ioctl(fd, EVIOCGBIT(1, 96), keybits, True)
        codes = [i for i in range(96 * 8) if keybits[i / 8] & (1 << (i % 8))]
        print('--- KEY codes (%d) ---' % len(codes))
        for c in codes:
            print('%-16s code=%d' % (key_name(c), c))
    close_quiet(fd)

elif mode == 'rate':
    fd = open_dev()
    t0 = time.time()
    counts = {}
    total = 0
    while time.time() - t0 < sec:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            data = os.read(fd, EV_SIZE * 64)
        except OSError:
            print('READ_ERROR (device gone?)')
            break
        n = len(data) / EV_SIZE
        total += n
        for i in range(n):
            _, _, etype, code, value = struct.unpack(EV_FMT, data[i * EV_SIZE:(i + 1) * EV_SIZE])
            counts[etype] = counts.get(etype, 0) + 1
    el = time.time() - t0
    print('elapsed=%.2fs total=%d events  rate=%.1f ev/s' % (el, total, total / el))
    for t in sorted(counts):
        print('  EV_%-4s %6d  (%.1f/s)' % (EV_NAMES.get(t, t), counts[t], counts[t] / el))
    close_quiet(fd)

elif mode in ('watch', 'monitor'):
    fd = open_dev()
    t0 = time.time()
    last_poll = 0.0
    while time.time() - t0 < sec:
        now = time.time()
        if mode == 'monitor' and now - last_poll >= 0.5:
            last_poll = now
            exists = os.path.exists(dev)
            try:
                held = held_keys(fd)
                state = 'held=%s' % (','.join(key_name(k) for k in held) if held else 'none')
            except (IOError, OSError) as e:
                state = 'EVIOCGKEY_FAIL(%s)' % e
            print('[%+8.3f] POLL node=%s %s' % (now - t0, 'OK' if exists else 'GONE', state))
            sys.stdout.flush()
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            continue
        try:
            data = os.read(fd, EV_SIZE * 64)
        except OSError as e:
            print('[%+8.3f] READ_ERROR %s' % (time.time() - t0, e))
            sys.stdout.flush()
            break
        for i in range(len(data) / EV_SIZE):
            _, _, etype, code, value = struct.unpack(EV_FMT, data[i * EV_SIZE:(i + 1) * EV_SIZE])
            if etype == 0:
                continue  # SYN 생략
            cname = key_name(code) if etype == 1 else (abs_name(code) if etype == 3 else str(code))
            print('[%+8.3f] EV_%-3s %-16s value=%d' % (time.time() - t0, EV_NAMES.get(etype, etype), cname, value))
            sys.stdout.flush()
    print('[%+8.3f] END' % (time.time() - t0))
    close_quiet(fd)

elif mode == 'keystate':
    fd = open_dev()
    held = held_keys(fd)
    print('held: %s' % (', '.join(key_name(k) for k in held) if held else '(none)'))
    close_quiet(fd)
PYEOF
}

case "$CMD" in
baseline)
  lsusb > "$STATE/lsusb.base"
  ls /dev/input > "$STATE/input.base"
  cat /proc/bus/input/devices > "$STATE/procbus.base" 2>/dev/null
  dmesg | wc -l > "$STATE/dmesg.lines"
  echo "baseline saved to $STATE"
  ;;

detect)
  echo "=== lsusb diff (new devices) ==="
  lsusb > "$STATE/lsusb.now"
  diff "$STATE/lsusb.base" "$STATE/lsusb.now" | grep '^>' || echo "(no new USB device)"
  echo
  echo "=== dmesg tail (since baseline) ==="
  BASE_LINES=$(cat "$STATE/dmesg.lines" 2>/dev/null || echo 0)
  dmesg | tail -n +"$((BASE_LINES + 1))" | tail -60
  echo
  echo "=== /dev/input diff ==="
  ls /dev/input > "$STATE/input.now"
  diff "$STATE/input.base" "$STATE/input.now" | grep '^>' || echo "(no new input node)"
  echo
  echo "=== /proc/bus/input/devices (full) ==="
  cat /proc/bus/input/devices
  echo
  echo "=== USB interface classes + driver binding ==="
  for d in /sys/bus/usb/devices/*:*; do
    [ -e "$d/bInterfaceClass" ] || continue
    cls=$(cat "$d/bInterfaceClass")
    sub=$(cat "$d/bInterfaceSubClass" 2>/dev/null)
    proto=$(cat "$d/bInterfaceProtocol" 2>/dev/null)
    drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)
    echo "$d  class=$cls sub=$sub proto=$proto driver=${drv:-UNBOUND}"
  done
  echo
  echo "=== input modules ==="
  lsmod | grep -E "xpad|joydev|usbhid|hid" || echo "(none)"
  ;;

caps)     run_py caps "/dev/input/${2:?usage: caps eventN}" ;;
rate)     run_py rate "/dev/input/${2:?usage: rate eventN sec}" "${3:-5}" ;;
watch)    run_py watch "/dev/input/${2:?usage: watch eventN sec}" "${3:-15}" ;;
monitor)  run_py monitor "/dev/input/${2:?usage: monitor eventN sec}" "${3:-30}" ;;
keystate) run_py keystate "/dev/input/${2:?usage: keystate eventN}" ;;

xpad-newid)
  VID="${2:?usage: xpad-newid VID PID}"
  PID="${3:?usage: xpad-newid VID PID}"
  modprobe xpad 2>/dev/null
  if [ ! -e /sys/bus/usb/drivers/xpad/new_id ]; then
    echo "xpad driver not present"; exit 1
  fi
  echo "$VID $PID" > /sys/bus/usb/drivers/xpad/new_id
  echo "new_id written (volatile). dmesg tail:"
  sleep 1
  dmesg | tail -15
  ;;

*)
  grep '^#   ' "$0" | sed 's/^#   //'
  ;;
esac
