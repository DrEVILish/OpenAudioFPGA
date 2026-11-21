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

The board, control wrapper and SS0 implementation were split from the local
WING port by Niklas Arnitz. SS1 reuses Mala's original [SPIBone/Wishbone
implementation](https://github.com/malarisch/OpenAudioFPGA/commit/7d2869acdcff4a0a1952b74bf9b5fe45e37ff7dd);
it does not import another SPIBone implementation or change the driver UAPI.
