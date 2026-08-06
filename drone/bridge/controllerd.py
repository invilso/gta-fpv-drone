#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["pysdl2", "pysdl2-dll"]
# ///
# pysdl2-dll bundles the SDL2 binaries themselves -- without it, Windows and
# macOS machines with no system-wide SDL2 fail at import time.
"""controllerd -- generic joystick/gamepad/RC-transmitter -> UDP bridge for
GTA SA MoonLoader scripts (moonloader/tx12.lua and moonloader/drone.lua).

Reads any connected joystick/gamepad/RC transmitter via SDL2 (pysdl2), so
RC transmitters (RadioMaster TX12) and modern gamepads (DualSense, Xbox,
etc.) are all handled uniformly, cross-platform (Linux/Windows/macOS). See
moonloader/drone/docs/controller-bridge.md for the full design and why two
wire formats are sent.

Two UDP outputs, both little-endian:

  v1 (single-device format) -- exactly one "primary" device (first one
  discovered), sent to --legacy-ports
  (default 42012, consumed by moonloader/tx12.lua, unmodified):
    offset size field
    0      2    magic   "TX"
    2      1    version 1
    3      1    flags   bit0 = FAILSAFE (no device / daemon shutting down)
    4      4    seq     uint32, wraps
    8      16   axes[8] uint16 0..2047 (center ~1024)
    24     4    buttons uint32, bit i = SDL button index i

  v2 (new) -- one packet PER connected device, tagged with a small device id
  and name, streamed to every SUBSCRIBER (consumed by moonloader/drone.lua).
  The daemon binds one well-known port (--port, default 42013); a consumer
  binds an ephemeral port, sends the 5-byte magic b"TXSUB" to the daemon at
  least every ~3 s, and receives the stream back on its own port. Any number
  of game instances can subscribe at once -- only the daemon occupies a
  fixed port. Subscribers not heard from for SUBSCRIBER_TIMEOUT are dropped.
  v2 packet layout:
    offset size field
    0      2    magic   "TX"
    2      1    version 2
    3      1    flags   reserved, always 0
    4      4    seq     uint32, wraps (shared counter across all devices)
    8      16   axes[8] uint16 0..2047
    24     4    buttons uint32
    28     1    deviceId
    29     16   name (utf-8, NUL-padded/truncated)

SDL reports axes as signed int16 (-32768..32767); both outputs renormalize
to the legacy uint16 0..2047 space so moonloader's existing cfg.calib
(min/center/max around 0/1024/2047) keeps working unchanged.
"""
import argparse
import ctypes
import socket
import struct
import sys
import time

import sdl2

V1_FMT = "<2sBBI8HI"
V1_SIZE = struct.calcsize(V1_FMT)
V2_FMT = "<2sBBI8HIB16s"
V2_SIZE = struct.calcsize(V2_FMT)
FLAG_FAILSAFE = 0x01
NAME_FIELD_LEN = 16
MAX_AXES = 8
MAX_BUTTONS = 32
SUBSCRIBE_MAGIC = b"TXSUB"
SUBSCRIBER_TIMEOUT = 3.0


def log(msg):
    print(f"[controllerd] {msg}", flush=True)


def normalize_axis(raw_int16):
    # SDL's -32768..32767 -> the legacy 0..2047 space (center exactly 1024,
    # matching the default cfg.calib on the moonloader side). See
    # docs/controller-bridge.md.
    return max(0, min(2047, (raw_int16 + 32768) >> 5))


class Device:
    def __init__(self, device_id, joystick):
        self.id = device_id
        self.joystick = joystick
        name = sdl2.SDL_JoystickName(joystick)
        self.name = name.decode("utf-8", "replace") if name else f"device{device_id}"
        self.axes = [1024] * MAX_AXES
        self.buttons = 0

    def poll(self):
        n_axes = min(sdl2.SDL_JoystickNumAxes(self.joystick), MAX_AXES)
        for i in range(n_axes):
            raw = sdl2.SDL_JoystickGetAxis(self.joystick, i)
            self.axes[i] = normalize_axis(raw)
        n_buttons = min(sdl2.SDL_JoystickNumButtons(self.joystick), MAX_BUTTONS)
        mask = 0
        for i in range(n_buttons):
            if sdl2.SDL_JoystickGetButton(self.joystick, i):
                mask |= 1 << i
        self.buttons = mask

    def attached(self):
        return bool(sdl2.SDL_JoystickGetAttached(self.joystick))

    def close(self):
        sdl2.SDL_JoystickClose(self.joystick)


class Bridge:
    def __init__(self, args):
        self.args = args
        # One socket for everything: bound to the well-known port so
        # subscribers have a fixed place to send TXSUB, used for all
        # outgoing sends too (legacy v1 and the v2 subscriber stream).
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", args.port))
        self.sock.setblocking(False)
        self.legacy_dests = [("127.0.0.1", p) for p in args.legacy_ports]
        self.subscribers = {}  # (ip, port) -> monotonic last-heard
        self.seq = 0
        self.devices = {}  # id -> Device
        self.next_id = 0
        self.running = True

    def poll_subscribers(self):
        while True:
            try:
                data, addr = self.sock.recvfrom(64)
            except (BlockingIOError, InterruptedError):
                break
            except ConnectionResetError:
                # Windows raises this on recvfrom after a previous sendto
                # hit a closed port (WSAECONNRESET) -- harmless here, the
                # timeout pruning below handles dead subscribers.
                continue
            if data == SUBSCRIBE_MAGIC:
                if addr not in self.subscribers:
                    log(f"subscriber added: {addr[0]}:{addr[1]}")
                self.subscribers[addr] = time.monotonic()
        now = time.monotonic()
        for addr in list(self.subscribers):
            if now - self.subscribers[addr] > SUBSCRIBER_TIMEOUT:
                del self.subscribers[addr]
                log(f"subscriber timed out: {addr[0]}:{addr[1]}")

    def rescan(self):
        # Periodic diff against SDL_NumJoysticks() rather than parsing
        # SDL_JOYDEVICEADDED/REMOVED events -- simpler to get right, and a
        # couple-second hotplug delay is fine for this use case.
        n = sdl2.SDL_NumJoysticks()

        # Drop devices that no longer report attached.
        for dev_id in list(self.devices):
            dev = self.devices[dev_id]
            if not dev.attached():
                log(f"device gone: id={dev_id} name={dev.name!r}")
                dev.close()
                del self.devices[dev_id]

        # SDL_JoystickOpen(index) is idempotent-ish (returns a new handle to
        # the same physical device if already open elsewhere), so track by
        # GUID to avoid opening the same physical device twice across rescans.
        open_guids = {
            bytes(sdl2.SDL_JoystickGetGUID(d.joystick).data) for d in self.devices.values()
        }
        for i in range(n):
            guid = bytes(sdl2.SDL_JoystickGetDeviceGUID(i).data)
            if guid in open_guids:
                continue
            joy = sdl2.SDL_JoystickOpen(i)
            if not joy:
                continue
            dev_id = self.next_id
            self.next_id += 1
            dev = Device(dev_id, joy)
            self.devices[dev_id] = dev
            open_guids.add(guid)
            log(f"device found: id={dev_id} name={dev.name!r} "
                f"axes={sdl2.SDL_JoystickNumAxes(joy)} buttons={sdl2.SDL_JoystickNumButtons(joy)}")

    def primary(self):
        if not self.devices:
            return None
        return self.devices[min(self.devices)]

    def send_to(self, pkt, dest):
        try:
            self.sock.sendto(pkt, dest)
        except OSError:
            # Windows surfaces an ICMP port-unreachable from an EARLIER send
            # as ConnectionResetError on a later sendto/recvfrom
            # (WSAECONNRESET) -- e.g. right after a game instance closes.
            # Nothing to handle: dead subscribers age out via the timeout,
            # and the legacy port is fire-and-forget by design.
            pass

    def send_v1(self, flags=0):
        prim = self.primary()
        axes = prim.axes if prim else [1024] * MAX_AXES
        buttons = prim.buttons if prim else 0
        pkt = struct.pack(V1_FMT, b"TX", 1, flags, self.seq & 0xFFFFFFFF, *axes, buttons)
        for dest in self.legacy_dests:
            self.send_to(pkt, dest)

    def send_v2(self, flags=0):
        for dev in self.devices.values():
            name_bytes = dev.name.encode("utf-8")[:NAME_FIELD_LEN].ljust(NAME_FIELD_LEN, b"\0")
            pkt = struct.pack(V2_FMT, b"TX", 2, flags, self.seq & 0xFFFFFFFF, *dev.axes, dev.buttons,
                               dev.id, name_bytes)
            for dest in self.subscribers:
                self.send_to(pkt, dest)

    def send_failsafe(self):
        for _ in range(3):
            self.send_v1(FLAG_FAILSAFE)
            self.send_v2(FLAG_FAILSAFE)
            time.sleep(0.01)

    def run(self):
        sdl2.SDL_Init(sdl2.SDL_INIT_JOYSTICK)
        interval = 1.0 / self.args.rate
        next_tick = time.monotonic()
        next_rescan = 0.0
        had_primary = False
        announced_empty = False

        while self.running:
            now = time.monotonic()
            if now >= next_rescan:
                # SDL only refreshes its joystick device list inside the event
                # pump -- without this, SDL_NumJoysticks() never changes after
                # init, and a controller plugged in while the daemon is already
                # running stays invisible until a restart.
                sdl2.SDL_PumpEvents()
                self.rescan()
                next_rescan = now + 2.0
                if self.devices:
                    announced_empty = False
                elif not announced_empty:
                    log("waiting for a controller (plug in a joystick/gamepad/RC transmitter)...")
                    announced_empty = True

            self.poll_subscribers()

            has_primary = self.primary() is not None
            if had_primary and not has_primary:
                log("primary device lost, sending FAILSAFE (legacy port)")
                self.send_failsafe()
            had_primary = has_primary

            # Required every tick -- SDL_JoystickGetAxis/GetButton otherwise
            # return the state from whenever the joystick was opened, not
            # the current state.
            sdl2.SDL_JoystickUpdate()
            for dev in self.devices.values():
                dev.poll()

            if now >= next_tick:
                self.send_v1()
                self.send_v2()
                if self.args.debug and self.devices:
                    for dev in self.devices.values():
                        ax = " ".join(f"{v:4d}" for v in dev.axes)
                        log(f"id={dev.id} {dev.name!r} axes[{ax}] btn={dev.buttons:08x}")
                self.seq += 1
                next_tick += interval
                if next_tick < now:  # fell behind, resync
                    next_tick = now + interval

            time.sleep(max(0.0, next_tick - time.monotonic()))

        sdl2.SDL_Quit()

    def stop(self, *_):
        self.running = False
        self.send_failsafe()
        log("stopped")
        sys.exit(0)


def parse_ports(s):
    try:
        ports = [int(p) for p in s.split(",") if p.strip()]
    except ValueError:
        raise argparse.ArgumentTypeError(f"invalid ports value: {s!r}")
    if not ports:
        raise argparse.ArgumentTypeError("must list at least one port")
    return ports


def main():
    ap = argparse.ArgumentParser(description="Generic joystick/gamepad -> UDP bridge for GTA SA MoonLoader")
    ap.add_argument("--port", type=int, default=42013,
                     help="UDP port the daemon listens on for TXSUB subscriptions; the v2 multi-device "
                          "stream goes back to every subscriber's own (ephemeral) port, so any number of "
                          "game instances can consume it at once (moonloader/drone/net.lua). Default 42013")
    ap.add_argument("--legacy-ports", type=parse_ports, default=[42012],
                     help="UDP destination port(s) for the v1 single-device protocol (moonloader/tx12.lua, unmodified), default 42012")
    ap.add_argument("--rate", type=int, default=100, help="packets per second")
    ap.add_argument("--debug", action="store_true", help="print device state each packet")
    args = ap.parse_args()

    bridge = Bridge(args)
    import signal
    signal.signal(signal.SIGTERM, bridge.stop)
    signal.signal(signal.SIGINT, bridge.stop)
    bridge.run()


if __name__ == "__main__":
    main()
