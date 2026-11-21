# WING Compact / Trion T55F484

This is an offline build target, not a released or board-qualified image. With the
pinned LiteX environment from `litex_soc/setup_venv.sh`, stage a new directory:

```sh
litex_soc/.venv/bin/python platforms/wing_trion/generate.py "$PWD/build/wing"
```

From that directory, run `efx_run wing-fpga.xml --flow compile` with Efinity
2026.1.132. The generator emits the project, pin table and actual LiteX CSR map.

- The 49.152 MHz input drives the fabric and divides by four for DSP CLKIN.
- SS0 (J2/GPIO58) consumes selector `01`–`04` while CS stays low; only the
  selected DSP sees subsequent mode-0 clocks/data. Use at most 2 MHz, with at
  least four fabric cycles of CS-high between transfers. Invalid selectors
  select no DSP. MISO is not driven with neither or both host selects asserted.
- SS1 (V6/GPIO59) uses the existing LiteX SPIBone/Wishbone bus. The WING bank
  starts at `0x1800`: magic, ABI, source-derived build ID, capabilities and ready
  are read-only. Reset release at `0x1814` powers up zero; only DSP1/2/4 are
  wired. Ready indicates fabric startup, not DSP readiness. Check live identity
  before writes. The X32 routing and AES67 windows are not present on this target.
- No DSP3 reset output is assigned. In particular, A9, AB9, A6 and D10 are not driven.

## DSP audio wire contract

The staged `dsp_board_profile.json` is byte-identical to the matching DSP export
(`3b29934cdc1c704de69b6b028bc71387ab7c50cb74e811fb35ca0f64664a3e9d`). The FPGA
drives phase-aligned RX and TX BCLK/FS at 24.576 MHz / 48 kHz. FS is high for one
bit before slot 0. Each lane carries 16 MSB-first signed Q4.28 words. Directions
are from the DSP perspective; lanes follow SPORT order, A before B. The local
index is `16 * lane + slot`, with 64/50/32/16 allocated slots per DSP, respectively.
Extra outbound slots are zero and unused DSP data pins are not driven by this image.

The two SS1 masks at `0x1818` (arm FS) and `0x181c` (accept returns) default to
zero. Reset release precedes FS on wired DSPs. Acceptance needs a previously
armed frame as well as the separate valid request. DSP3 has no FPGA reset pin;
the host must establish readiness independently before requesting its FS.

There is no mixer or AES50 I/O in this target. To verify the physical lanes
without a routing matrix, the SS1 bench probe selects one slot (`0x1820`, default
511 = none), supplies that slot's outbound word (`0x1824`, default zero), and
reads the last gated inbound word (`0x1828`). The selector adds the profile's
per-DSP `first_id` to the local slot index. All other outbound words are zero.
This is not a streaming or stock-control ABI. Leave the masks clear until CLKIN,
DSP PLL/speed grade, pad timing and boot/reset behavior are qualified on hardware.

The board, control wrapper and SS0 implementation were split from the local
WING port by Niklas Arnitz. SS1 reuses Mala's original [SPIBone/Wishbone
implementation](https://github.com/malarisch/OpenAudioFPGA/commit/7d2869acdcff4a0a1952b74bf9b5fe45e37ff7dd);
it does not import another SPIBone implementation or change the driver UAPI.
