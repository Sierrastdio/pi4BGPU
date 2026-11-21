# TangNanoGPU SMI adapter transplant notes

This document describes the write-only SMI adapter in `rtl/smi_gpu.v`, which
is connected by the GPU build (`build.ps1`) to `rtl/top_tangnano20k.v`. Its
framing has not been validated against a Raspberry Pi host implementation.

## Signals

| Signal | Direction | Purpose |
|---|---|---|
| `smi_swe_n` | Pi → FPGA | Active-low write strobe; receiver captures at its falling edge |
| `smi_a0` | Pi → FPGA | 1 for header/length words, 0 for payload words |
| `smi_data[15:0]` | Pi → FPGA | 16-bit SMI data |
| `gpu_busy` (SMI BUSY) | FPGA → Pi | Flow-control output on FPGA pin 76 |

The adapter assumes the three `SA0=1` words are the marker/opcode, payload
length low word, and payload length high word. Payload bytes are packed low
byte first, then high byte; odd final high bytes are ignored.

## Frame words

1. `SA0=1`: `{8'hA5, opcode}`
2. `SA0=1`: payload byte count `[15:0]`
3. `SA0=1`: payload byte count `[31:16]`
4. `SA0=0`: `ceil(length/2)` payload words

The receiver emits opcode then payload bytes to `cmd_push/cmd_data`. RESET
(opcode `02`) with zero payload asserts `soft_reset`. PING, STATUS, READ_DATA,
and READ_RECT are unsupported because no read response path exists.

The Pi 4B userspace implementation is [`pi/smi_gpu.py`](../pi/smi_gpu.py).
Its MMIO bases follow the BCM2711 low-peripheral address map in the
[Raspberry Pi 4 peripheral manual](https://pip-assets.raspberrypi.com/categories/545-raspberry-pi-4-model-b/documents/RP-008248-DS-1-bcm2711-peripherals.pdf),
and the SMI register offsets match the
[Linux BCM2835 SMI header](https://chromium.googlesource.com/chromiumos/third_party/kernel-raspberrypi/+/ae161617d7a4552fa91d03626b8d9f3696d17481/include/linux/broadcom/bcm2835_smi.h).

## Integration gaps

- `rtl/top.sv` remains the heartbeat example; the active GPU build explicitly
  selects `rtl/top_tangnano20k.v`, which instantiates this adapter and GPU.
- The Pi SMI test shown in the project conversation checks electrical word
  writes but does not prove this framing format.
- SMI BUSY behavior during an in-flight write, SMI setup/hold timing,
  clock-domain crossing, and FIFO overflow recovery have not had functional
  simulation or physical validation.
- The HDMI/SMI constraints passed nextpnr together, but the wiring and signal
  timing still need board-level confirmation.
- `pi/smi_gpu.py` implements a Pi 4B userspace encoder for these frames, but
  it has not yet been exercised with the FPGA.
- SMI readback and corresponding host APIs are absent.
