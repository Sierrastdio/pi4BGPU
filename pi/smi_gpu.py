#!/usr/bin/env python3
"""Minimal Raspberry Pi 4B userspace host for the TangNanoGPU SMI link.

This uses the Pi 4 BCM2711 SMI peripheral directly through /dev/mem, following
the register setup that was already exercised by the project's smi_test.py.
It is intentionally limited to write-only GPU commands.
"""

from __future__ import annotations

import mmap
import os
import subprocess
import time
from typing import Iterable


# BCM2711 ARM physical peripheral window in Raspberry Pi 4's low-peripheral
# mode. The SMI base/offsets are specified in the BCM2711 peripheral manual.
PERIPHERAL_BASE = 0xFE000000
SMI_BASE = PERIPHERAL_BASE + 0x00600000
CLOCK_BASE = PERIPHERAL_BASE + 0x00101000
GPIO_BASE = PERIPHERAL_BASE + 0x00200000

# SMI register word indices.
CS, LENGTH, ADDRESS, DATA, DSR0, DSW0 = range(6)
CLK_CTL, CLK_DIV = 44, 45

CLK_PASSWORD = 0x5A000000
CS_ENABLE = 1 << 0
CS_DONE = 1 << 1
CS_START = 1 << 3
CS_CLEAR = 1 << 4
CS_WRITE = 1 << 5
CS_ACTIVE = 1 << 2
CS_AFERR = 1 << 25
CLK_BUSY = 1 << 7
CLK_ENABLE = 1 << 4
CLK_KILL = 1 << 5
SMI_CLOCK_SOURCE_PLLD = 6

GPIO_LEVEL0 = 13  # GPIO level register for GPIO 0..31, offset 0x34.
BUSY_GPIO = 26

FRAME_MAGIC = 0xA5
OP_RESET = 0x02
OP_SET_TARGET = 0x10
OP_SHOW = 0x11
OP_WAIT_VSYNC = 0x12
OP_FILL_RECT = 0x20
OP_LINE = 0x21
OP_CIRCLE = 0x23

SMI_SETUP = 30
SMI_STROBE = 60
SMI_HOLD = 30
WORDS_PER_TRANSFER = 8


class Pi4Smi:
    """PIO SMI writer for Raspberry Pi 4B, BUSY on GPIO26."""

    def __init__(self, timeout: float = 1.0, chunk_words: int = WORDS_PER_TRANSFER):
        if os.geteuid() != 0:
            raise PermissionError("Run with sudo: direct SMI access needs /dev/mem")
        if not 1 <= chunk_words <= 16:
            raise ValueError("chunk_words must be between 1 and 16")

        self.timeout = timeout
        self.chunk_words = chunk_words
        self._fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self._maps: list[mmap.mmap] = []
        self._regs: list[memoryview] = []
        try:
            self.smi = self._map_words(SMI_BASE)
            self.clock = self._map_words(CLOCK_BASE)
            self.gpio = self._map_words(GPIO_BASE)
            self._configure_pins()
            self._configure_smi_clock()
            self._reset_smi()
        except Exception:
            self.close()
            raise

    def _map_words(self, physical_address: int) -> memoryview:
        mapping = mmap.mmap(
            self._fd,
            mmap.PAGESIZE,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
            offset=physical_address,
        )
        words = memoryview(mapping).cast("I")
        self._maps.append(mapping)
        self._regs.append(words)
        return words

    @staticmethod
    def _pinctrl(*arguments: str) -> None:
        subprocess.run(["pinctrl", *arguments], check=True)

    def _configure_pins(self) -> None:
        # Pi GPIO4..23 are the SMI ALT1 bus. GPIO26 is an input from FPGA BUSY.
        self._pinctrl("set", "4-23", "a1")
        self._pinctrl("set", str(BUSY_GPIO), "ip")

    def _configure_smi_clock(self) -> None:
        source = self.clock[CLK_CTL] & 0xF
        self.clock[CLK_CTL] = CLK_PASSWORD | source
        deadline = time.monotonic() + 0.2
        while self.clock[CLK_CTL] & CLK_BUSY:
            if time.monotonic() >= deadline:
                self.clock[CLK_CTL] = CLK_PASSWORD | CLK_KILL
                time.sleep(0.01)
                break

        # Keep the existing divider, matching the project's proven Pi test.
        self.clock[CLK_CTL] = CLK_PASSWORD | SMI_CLOCK_SOURCE_PLLD
        self.clock[CLK_CTL] = CLK_PASSWORD | SMI_CLOCK_SOURCE_PLLD | CLK_ENABLE
        time.sleep(0.01)

    def _reset_smi(self) -> None:
        self.smi[CS] = 0
        self.smi[LENGTH] = 0
        self.smi[ADDRESS] = 0
        self.smi[DSR0] = 0
        self.smi[DSW0] = (
            (1 << 30)
            | (SMI_SETUP << 24)
            | (SMI_HOLD << 16)
            | SMI_STROBE
        )
        self.smi[CS] = CS_ENABLE | CS_CLEAR | CS_WRITE
        time.sleep(0.0005)

    def busy(self) -> bool:
        return bool(self.gpio[GPIO_LEVEL0] & (1 << BUSY_GPIO))

    def wait_ready(self) -> None:
        deadline = time.monotonic() + self.timeout
        while self.busy():
            if time.monotonic() >= deadline:
                raise TimeoutError("FPGA BUSY stayed high; check power, reset, and GPIO26 wiring")
            time.sleep(0.0005)

    def transfer_words(self, address: int, words: Iterable[int]) -> None:
        values = list(words)
        if address not in (0, 1):
            raise ValueError("SA0 address must be 0 or 1")
        if not values:
            return
        if len(values) > 0xFFFF:
            raise ValueError("SMI transfer is too long")

        self._reset_smi()
        self.smi[ADDRESS] = address
        self.smi[LENGTH] = len(values)
        # Match the start-first sequence used by the working Pi register test.
        self.smi[CS] = CS_ENABLE | CS_WRITE | CS_START
        for word in values:
            self.smi[DATA] = word & 0xFFFF

        deadline = time.monotonic() + self.timeout
        while not (self.smi[CS] & CS_DONE):
            if time.monotonic() >= deadline:
                status = self.smi[CS]
                raise TimeoutError(f"SMI transfer timed out (CS=0x{status:08x})")
            time.sleep(0.0001)
        status = self.smi[CS]
        if status & CS_AFERR:
            raise IOError(f"SMI FIFO error (CS=0x{status:08x})")

    def send_frame(self, opcode: int, payload: bytes = b"") -> None:
        if not 0 <= opcode <= 0xFF:
            raise ValueError("opcode must fit in one byte")
        if len(payload) > 0xFFFFFFFF:
            raise ValueError("payload exceeds the SMI frame length field")

        self.wait_ready()
        length = len(payload)
        header = (
            (FRAME_MAGIC << 8) | opcode,
            length & 0xFFFF,
            (length >> 16) & 0xFFFF,
        )
        # All three words use SA0=1 and fit safely in the SMI FIFO.
        self.transfer_words(1, header)

        if not payload:
            return

        padded = payload if len(payload) % 2 == 0 else payload + b"\x00"
        words = [padded[i] | (padded[i + 1] << 8) for i in range(0, len(padded), 2)]
        for start in range(0, len(words), self.chunk_words):
            self.wait_ready()
            self.transfer_words(0, words[start : start + self.chunk_words])

    def close(self) -> None:
        if getattr(self, "_fd", None) is None:
            return
        try:
            if hasattr(self, "smi"):
                self.smi[CS] = 0
            if hasattr(self, "clock"):
                source = self.clock[CLK_CTL] & 0xF
                self.clock[CLK_CTL] = CLK_PASSWORD | source
            if hasattr(self, "_regs"):
                self._pinctrl("set", "4-23", "ip")
        except (OSError, subprocess.SubprocessError):
            pass
        for view in reversed(self._regs):
            view.release()
        for mapping in reversed(self._maps):
            mapping.close()
        os.close(self._fd)
        self._fd = None

    def __enter__(self) -> "Pi4Smi":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        self.close()


class TangNanoGPU:
    """Small write-only drawing API for the implemented SMI opcodes."""

    def __init__(self, transport: Pi4Smi):
        self.transport = transport

    def reset(self) -> None:
        self.transport.send_frame(OP_RESET)
        time.sleep(0.01)

    def set_target(self, buffer: int) -> None:
        self.transport.send_frame(OP_SET_TARGET, bytes((buffer & 1,)))

    def show(self, buffer: int) -> None:
        self.transport.send_frame(OP_SHOW, bytes((buffer & 1,)))

    def wait_vsync(self) -> None:
        self.transport.send_frame(OP_WAIT_VSYNC)

    def fill_rect(self, x: int, y: int, width: int, height: int, color: int) -> None:
        payload = (
            int(x).to_bytes(2, "little", signed=True)
            + int(y).to_bytes(2, "little", signed=True)
            + int(width).to_bytes(2, "little")
            + int(height).to_bytes(2, "little")
            + int(color).to_bytes(2, "big")
        )
        self.transport.send_frame(OP_FILL_RECT, payload)

    def line(self, x0: int, y0: int, x1: int, y1: int, color: int) -> None:
        payload = (
            int(x0).to_bytes(2, "little", signed=True)
            + int(y0).to_bytes(2, "little", signed=True)
            + int(x1).to_bytes(2, "little", signed=True)
            + int(y1).to_bytes(2, "little", signed=True)
            + int(color).to_bytes(2, "big")
        )
        self.transport.send_frame(OP_LINE, payload)

    def circle(self, x: int, y: int, radius: int, color: int, filled: bool = False) -> None:
        payload = (
            int(x).to_bytes(2, "little", signed=True)
            + int(y).to_bytes(2, "little", signed=True)
            + int(radius).to_bytes(2, "little")
            + int(color).to_bytes(2, "big")
            + bytes((1 if filled else 0,))
        )
        self.transport.send_frame(OP_CIRCLE, payload)
