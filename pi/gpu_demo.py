#!/usr/bin/env python3
"""Render a first geometric scene on Tang Nano GPU over Pi 4B SMI."""

import argparse
import time

from smi_gpu import Pi4Smi, TangNanoGPU


def draw_demo(gpu: TangNanoGPU) -> None:
    # RGB565 values are sent high byte first by TangNanoGPU's command protocol.
    black_blue = 0x0841
    white = 0xFFFF
    red = 0xF800
    green = 0x07E0
    blue = 0x001F
    yellow = 0xFFE0
    cyan = 0x07FF
    magenta = 0xF81F

    gpu.reset()
    time.sleep(0.05)  # allow the GPU reset pulse to flush its command FIFO

    # The active framebuffer is 320x240 and is doubled to 640x480 over HDMI.
    gpu.fill_rect(0, 0, 320, 240, black_blue)
    gpu.fill_rect(18, 18, 284, 204, 0x18E3)
    gpu.fill_rect(28, 28, 264, 38, blue)
    gpu.fill_rect(28, 74, 122, 132, 0x2104)
    gpu.fill_rect(170, 74, 122, 132, 0x2104)

    # Left: solid color blocks. Right: FPGA-rasterized lines and circles.
    gpu.fill_rect(42, 92, 42, 34, red)
    gpu.fill_rect(91, 92, 42, 34, green)
    gpu.fill_rect(42, 140, 42, 34, blue)
    gpu.fill_rect(91, 140, 42, 34, yellow)

    for i in range(8):
        gpu.line(180, 176, 280 - i * 7, 94, cyan if i % 2 == 0 else white)
    gpu.circle(230, 142, 42, magenta)
    gpu.circle(230, 142, 24, yellow, filled=True)
    gpu.circle(230, 142, 9, red, filled=True)

    gpu.fill_rect(18, 222, 284, 2, white)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--startup-wait", type=float, default=1.0,
                        help="seconds to wait for FPGA PLL/SDRAM startup (default: 1)")
    parser.add_argument("--chunk-words", type=int, default=8,
                        help="SMI payload words per transfer, 1..16 (default: 8)")
    args = parser.parse_args()

    print("Waiting for Tang Nano 20K startup...")
    time.sleep(max(0.0, args.startup_wait))
    with Pi4Smi(chunk_words=args.chunk_words) as smi:
        print(f"SMI ready; FPGA BUSY={int(smi.busy())}")
        gpu = TangNanoGPU(smi)
        draw_demo(gpu)
        print("Demo commands sent. Check the HDMI monitor for the geometric scene.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
