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

That one build command runs Yosys synthesis, nextpnr placement/routing, `gowin_pack`, then openFPGALoader to write and verify the onboard flash. It does not invoke Arch, WSL, or Gowin IDE. The flash operation is persistent. For a temporary SRAM test, run `.\build.ps1 -Program` instead.

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

Edit `rtl/top.sv` and add Verilog/SystemVerilog files directly under `rtl/`. Update `constraints/tangnano20k.cst` when top-level ports change. Every external top-level port must be assigned to a valid FPGA pin.

## Starter design

The checked-in RTL is a heartbeat bring-up design: the 27 MHz board clock blinks onboard LED0. It checks the toolchain and programming path; it is not the GPU yet. The starter CST maps the clock and six onboard active-low LEDs (pins 15–20). The Tang Nano 20K clock input is pin 4 and LED0 is pin 15.

| File | Purpose |
| --- | --- |
| `rtl/top.sv` | FPGA top-level starter RTL |
| `constraints/tangnano20k.cst` | Tang Nano 20K pin constraints |
| `build.ps1` | Windows build/program script |
| `build/` | Generated JSON and `.fs`; ignored by Git |

Device setup: `GW2AR-LV18QN88C8/I7`; nextpnr and `gowin_pack` family database: `GW2A-18C`.

## What the script does

1. Collect `.v` and `.sv` files directly from `rtl/`, synthesize top module `top` to `build/top.json`.
2. Run nextpnr with the Tang Nano 20K device and CST to produce `build/top_pnr.json`.
3. Pack the routed design as `build/top.fs`.
4. With `-Program`, load SRAM. With `-Program -Flash`, write and verify onboard flash.

The 16-bit SMI signals from the project notes are not mapped in the starter CST. Their final assignments depend on the display output and board pin multiplexing. Confirm the Tang Nano 20K schematic, available pins, 3.3 V signaling, and Pi SMI timing before adding those constraints.

## Troubleshooting

- `yosys` not found: start `oss`, stay at the `[OSS CAD Suite]` prompt, and run the build script there. Do not exit the OSS shell first.
- `synth_gowin` unknown: the active Yosys build lacks Gowin support; use the OSS CAD Suite distribution with the Gowin backend.
- `gowin_pack` PLL error: update Apicula; designs using both PLLs need version 0.34 or newer.
- `Unconstrained IO`: assign the reported top-level port in CST or remove an unused port.
- openFPGALoader cannot detect JTAG: check Device Manager and the JTAG interface driver.
- SRAM works but the design disappears after power-off: expected behavior; use `-Program -Flash` after testing SRAM.
