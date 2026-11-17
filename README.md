# OpenAudioFPGA

Modular FPGA code base for the consoles of the [OpenMixerProject](https://github.com/OpenMixerProject).


## Layers

```
platforms/<console>_<fpga>/    top level: pin names, PLLs / DCMs, IO and DDR registers,
                               constraints, vendor project files
consoles/<console>/            console logic that every FPGA variant shares
rtl/core/                      generic audio core (openaudio_core)
rtl/periph/                    vendor-neutral building blocks for the console layers
rtl/aes50/                     AES50 core
ext/AES67/                     AES67 core
```

## The generic core

`rtl/core/openaudio_core.vhd` contains the audio clock divider, the TDM8 receivers and
senders, the routing matrix, the SPI configuration port and the network cores (AES50, AES67).
Console layers and top levels never instantiate a network core themselves: they set the
number of cores and connect the RMII signals.

| Generic | Meaning |
|---|---|
| `G_TDM_LINES_IN` | number of TDM8 input lines (8 channels each) = sources of the matrix |
| `G_TDM_LINES_OUT` | number of TDM8 output lines = destinations of the matrix |
| `G_AES50_PORTS` | number of AES50 cores (0 = none) |
| `G_AES50_FIRST_LINE` | AES50 core *k* occupies the 6 lines `FIRST + 6k .. FIRST + 6k + 5` in both directions |
| `G_AES50_SUPPORT_44K1`, `G_AES50_UART_AUX`, `G_AES50_TDM_AUX`, `G_AES50_UART_FIFO_AW`, `G_AES50_UART_BAUD` | passed to the AES50 cores |
| `G_AES67_PORTS` | number of AES67 cores (0 = none, then the AES67 sources are not needed) |
| `G_AES67_FIRST_LINE` | AES67 core *k* occupies the 4 lines `FIRST + 4k .. FIRST + 4k + 3` in both directions |
| `G_FS_SYNC_CNT`, `G_FS_ADVANCE` | alignment of the clock divider to the frame sync of AES67 core 0, without AES67 to `fs_sync_i` |

Limits: 2 to 31 lines per direction (the SPI protocol has 8 bit addresses and sources).

Routing is written with 16 bit SPI words `DATA[15:8] ADDR[7:0]`:

| ADDR | DATA |
|---|---|
| destination channel `line * 8 + channel` (0-based) | source channel `line * 8 + channel + 1`, 0 = off |
| 255 | configuration register (`cfg_bits_o`) |

## Behringer X32

`consoles/x32/x32_common.vhd`: startup sequence, CS2000 setup, AUX converter setup, UART
collector of the IO boards, UltraNet and the core.

| Line | Sources | Destinations |
|---|---|---|
| 0 - 1 | AD0 (XLR 1-16) | DA (XLR out 1-16) |
| 2 - 3 | AD1 (XLR 17-32) | UltraNet P16 A / B |
| 4 - 7 | expansion card | expansion card |
| 8 | AUX AD | AUX DA |
| 9 - 13 | DSP | DSP |
| 14 ... | AES50 cores, 6 lines each | |
| then | AES67 cores, 4 lines each | |

| `G_AES50_PORTS` | `G_AES67_PORTS` | Port A | Port B | Lines |
|---|---|---|---|---|
| 1 | 1 | AES50 | AES67 | 24 |
| 2 | 0 | AES50 | AES50 | 26 |
| 1 | 0 | AES50 | unused | 20 |
| 0 | 2 | AES67 | AES67 | 22 |

With an AES67 core the CS2000 follows the PTP disciplined clock of AES67 core 0 (x2), else the
16 MHz oscillator (x3.072).

| | `x32_lattice` | `x32_spartan` |
|---|---|---|
| Default | 1 x AES50 + 1 x AES67 | 1 x AES50 |
| AES67 | yes | wired up (`create_project.tcl aes67`), but XST stops in the AES67 sources (`'succ` in the MAC `framing.vhd`); no second SPI chip select on this board |
| AUX converters | M8000 ADC + PCM1690 DAC | CS42438 |
| Vendor parts | 2 PLLs, IO registers, DDR clock outputs (Clarity Designer, `ip/`) | DCM, BUFG, IDDR2 / ODDR2 (`ip/`) |

### Building

```
./build.sh lattice | xilinx | all
```

builds the bit files and prints resource utilisation and timing of each platform. Bit files,
reports and logs end up in `build/`.

| Variable | |
|---|---|
| `DIAMOND_DIR` | Lattice Diamond installation, e.g. `~/lscc/diamond/3.14` |
| `ISE_VM_HOST` | host name or IP address of the Xilinx ISE 14.7 VM |
| `ISE_VM_REPO` | path of this repository inside the VM |
| `ISE_VM_USER`, `ISE_VM_PASSWORD`, `ISE_VM_SETTINGS` | optional: user (default `ise`), password (default `xilinx`), ISE settings script |

By hand:

* Lattice: open `platforms/x32_lattice/x32_lattice.ldf` in Diamond, or `diamondc build.tcl [synth|map|par|bit]`
  in `platforms/x32_lattice`.
* Xilinx: `xtclsh create_project.tcl` in `platforms/x32_spartan` creates `build/x32_spartan.xise`,
  `xtclsh create_project.tcl build` also builds the bit file.
