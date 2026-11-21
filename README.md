# pi4BGPU

Raspberry Pi 4B + Sipeed Tang Nano 20K (GW2AR-18C) GPU project. RTL editing, FPGA build, and programming are driven from Windows PowerShell. WSL/Arch and Gowin IDE are not part of this open-source flow.

## One-command build and upload

The `oss` command opens a dedicated OSS CAD Suite shell. **Run the build inside that shell before typing `exit`**, because its PATH changes belong to that session.

1. Connect the Tang Nano 20K to the Windows PC over USB.
2. In PowerShell, enter the project directory and start the OSS shell:

   ```powershell
   cd C:\Users\sierra\Documents\pi4BGPU
   oss
   ```

3. At the `[OSS CAD Suite]` prompt, run:

   ```powershell
   .\build.ps1 -Program -Flash
   ```

That command builds the SMI-connected TangNanoGPU HDMI design, then uses
openFPGALoader to write and verify onboard flash. It does not invoke Arch,
WSL, or Gowin IDE. The flash operation is persistent. For a temporary SRAM
load, run `.\build.ps1 -Program` instead. Without `-Program`, the bitstream
is built at `build/gpu-smi/top.fs`.

Other commands, also from the `[OSS CAD Suite]` prompt:

```powershell
.\build.ps1                 # build .fs only
.\build.ps1 -Program        # build and load FPGA SRAM
.\build.ps1 -Program -Flash # build and write onboard flash
.\build.ps1 -Clean -Program # clean generated output, rebuild, load SRAM
```

`openFPGALoader` must be available in the OSS shell's PATH. If it is not, add its Windows executable to PATH or install it separately. If the board's JTAG is not detected, check the Windows USB driver for the JTAG interface; keep the separate UART interface on its normal driver.

## Setup

Install a current Windows OSS CAD Suite with Yosys `synth_gowin`, `nextpnr-himbaechel` with the Gowin backend, and Apicula `gowin_pack` 0.34 or newer. The `oss` shell wrapper must activate that suite. No USB forwarding into WSL is needed.

The GPU build selects `top_tangnano20k` and its explicit RTL source list in
`build.ps1`. `rtl/top.sv` remains the small heartbeat bring-up design and is
not used by this GPU build. Update the GPU constraint files in `constraints/`
when GPU top-level ports change.

## Heartbeat reference design

`rtl/top.sv` is retained as a minimal heartbeat bring-up example. The active
GPU build uses `rtl/top_tangnano20k.v`, the renderer, SDRAM controller, HDMI
scanout, and the SMI adapter below.

| File | Purpose |
| --- | --- |
| `rtl/top.sv` | Heartbeat reference top (not selected by `build.ps1`) |
| `rtl/top_tangnano20k.v` | Active GPU/SMI integration top selected by the build |
| `constraints/gpu_*.cst` | GPU board, HDMI, and SMI pin constraints |
| `build.ps1` | Windows GPU build/program script |
| `build/gpu-smi/` | Generated GPU JSON, logs, reports, and `.fs`; ignored by Git |

Device setup: `GW2AR-LV18QN88C8/I7`; nextpnr and `gowin_pack` family database: `GW2A-18C`.

## What the script does

1. Synthesize the selected SMI GPU RTL source list with `synth_gowin` and the BRAM OCE fix to `build/gpu-smi/top.json`.
2. Run nextpnr with the Tang Nano 20K device, merged GPU constraints, and seed 1 to produce `build/gpu-smi/top_pnr.json`.
3. Pack the routed design as `build/gpu-smi/top.fs`.
4. With `-Program`, load SRAM. With `-Program -Flash`, write and verify onboard flash.

## SMI porting materials

The Raspberry Pi host transport and a first drawing demo are in [`pi/`](pi/).
See [`pi/README.md`](pi/README.md) for wiring and the Pi-side run command.

The following required GPU and SMI files were copied selectively from
TangNanoGPU and are used by the active build:

| File | Role |
| --- | --- |
| `rtl/smi_gpu.v`, `rtl/async_fifo.v` | SMI receiver and its clock-domain crossing FIFO |
| `rtl/gpu_exec.v`, `rtl/byte_fifo.v`, `rtl/bram_sdp.v` | Drawing command parser/engine and command/response FIFO storage |
| `rtl/scanout.v`, `rtl/video_timing.v`, `rtl/dvi_tx.v`, `rtl/tmds_encoder.v` | Framebuffer scanout and HDMI output path |
| `rtl/sdram_ctrl.v`, `rtl/clocks.v` | SDRAM controller and board clocks/PLLs |
| `rtl/top_tangnano20k.v` | TangNanoGPU integration top, retained as source reference |
| `constraints/gpu_base.cst`, `constraints/gpu_hdmi.cst`, `constraints/gpu_link_hdmi_smi.cst` | GPU clock/board, HDMI, and SMI pin constraints used by the active build |
| `tools/fix_bram_oce.py` | Yosys netlist adjustment used by the upstream GPU build |
| `LICENSE-TangNanoGPU` | Upstream Apache 2.0 license for the imported RTL/build utility |

**The GPU RTL source set is selected by `build.ps1`, and synthesis, placement,
routing, and bitstream packing have succeeded.** The current SMI receiver is
write-only. A Raspberry Pi 4B userspace sender is in `pi/`, but the design
has not been tested on a physical Tang Nano 20K. The current pin map keeps
the HDMI pins separate from the listed SMI pins.
Functional simulation was skipped at your request, so SMI frame behavior has
not been verified in simulation. The Pi sender has not yet been exercised on
physical hardware.

The proposed pin mapping is: SWE_N FPGA 77, SA0 75, SD[0:15] =
73, 74, 27, 28, 26, 25, 29, 30, 31, 42, 41, 48, 49, 86, 72, 71.
FPGA pin 76 is assigned to the top-level `gpu_busy` output (SMI BUSY).
nextpnr completed with these constraints for the HDMI design.
The current receiver is write-only: PING, STATUS, and pixel readback are not
implemented over SMI.

The local build generated `build/gpu-smi/top.fs` (4,620,140 bytes). An upload
attempt reported `unable to open ftdi device: -3 (device not found)`; the FPGA
board was not connected, so no hardware programming or display check occurred.

## Troubleshooting

- `yosys` not found: start `oss`, stay at the `[OSS CAD Suite]` prompt, and run the build script there. Do not exit the OSS shell first.
- `synth_gowin` unknown: the active Yosys build lacks Gowin support; use the OSS CAD Suite distribution with the Gowin backend.
- `gowin_pack` PLL error: update Apicula; designs using both PLLs need version 0.34 or newer.
- `Unconstrained IO`: assign the reported top-level port in CST or remove an unused port.
- openFPGALoader cannot detect JTAG: check Device Manager and the JTAG interface driver.
- SRAM works but the design disappears after power-off: expected behavior; use `-Program -Flash` after testing SRAM.
