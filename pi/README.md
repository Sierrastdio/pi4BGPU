# Raspberry Pi 4B SMI host and first GPU demo

`smi_gpu.py` uses Raspberry Pi 4B SMI registers from Linux userspace through
`/dev/mem`, matching the register setup in the project's previously exercised
SMI word-write script. It converts GPU commands into the frame format
documented in [`../docs/smi-protocol.md`](../docs/smi-protocol.md). The API is
write-only; it does not implement PING, STATUS, or framebuffer readback.

## Wiring

Connect the FPGA's HDMI output to a monitor. Connect the Pi and FPGA grounds.
All signals are 3.3 V; do not connect a 5 V GPIO source.

| Signal | Pi GPIO | Pi physical pin | Tang Nano 20K FPGA pin |
|---|---:|---:|---:|
| SWE_N | 7 | 26 | 77 |
| SA0 | 5 | 29 | 75 |
| SD0 | 8 | 24 | 73 |
| SD1 | 9 | 21 | 74 |
| SD2 | 10 | 19 | 27 |
| SD3 | 11 | 23 | 28 |
| SD4 | 12 | 32 | 26 |
| SD5 | 13 | 33 | 25 |
| SD6 | 14 | 8 | 29 |
| SD7 | 15 | 10 | 30 |
| SD8 | 16 | 36 | 31 |
| SD9 | 17 | 11 | 42 |
| SD10 | 18 | 12 | 41 |
| SD11 | 19 | 35 | 48 |
| SD12 | 20 | 38 | 49 |
| SD13 | 21 | 40 | 86 |
| SD14 | 22 | 15 | 72 |
| SD15 | 23 | 16 | 71 |
| BUSY (FPGA → Pi) | 26 | 37 | 76 |
| GND | — | any GND | GND |

## Prepare the FPGA

On the Windows build computer, program the Tang Nano 20K with the generated
SMI HDMI bitstream:

```powershell
oss
.\build.ps1 -Program -Flash
```

The programming computer and the Raspberry Pi can be different machines. The
board must be powered and connected to the Pi's SMI wiring before running the
demo. Release S2; holding S2 forces the FPGA colour-bar test pattern instead
of the framebuffer.

## Run the demo on Raspberry Pi OS (Pi 4B)

The program uses only Python's standard library and the Raspberry Pi OS
`pinctrl` command. Copy this repository to the Pi, then run:

```bash
cd pi4BGPU
sudo python3 pi/gpu_demo.py
```

The process needs root for `/dev/mem`. It configures GPIO4–23 to SMI ALT1,
reads FPGA BUSY on GPIO26, waits for the FPGA's PLL/SDRAM startup, sends a
RESET, then draws a 320×240 RGB565 pattern with rectangles, radial lines, and
circles. The FPGA scales that image to HDMI 640×480.

Optional settings:

```bash
sudo python3 pi/gpu_demo.py --startup-wait 2
sudo python3 pi/gpu_demo.py --chunk-words 4
```

Payloads are sent in small SMI bursts, with BUSY checked between bursts. If
BUSY remains high, check that the FPGA is powered and out of reset, and that
FPGA pin 76 is wired to Pi GPIO26. If the transfer times out, check SWE_N,
SA0, the data-bit order, the shared ground, and the live low-level SMI test on
that Pi.

The Pi host code has not been exercised on the physical Pi/FPGA pair yet. The
first board run is therefore an integration check of the tested electrical
SMI write path plus this new frame encoder and the GPU renderer.
