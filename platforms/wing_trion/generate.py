#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Stage the WING Compact T55 project for Efinity (no programming)."""
import argparse
import hashlib
import shutil
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "litex_soc"))
from generate import build

NAME = "wing-fpga"
DEVICE = "T55F484"
VERSION = "2026.1.132"
HOST = {
    "clk_audio": ("in", "R2", "GPIOL_15"),
    "host_sck": ("in", "W1", "GPIOL_01"), "host_mosi": ("in", "V2", "GPIOL_08"),
    "host_miso": ("inout", "V1", "GPIOL_09"), "ctrl_cs_n": ("in", "V6", "GPIOL_04"),
    "dsp_cs_n": ("in", "J2", "GPIOL_117"),
}
# Per DSP: MOSI, MISO, SCK, select, CLKIN, reset. DSP3 reset is not qualified.
CONTROL = (
    ("B20:GPIOR_175", "T14:GPIOB_RXP18", "C21:GPIOR_178", "B21:GPIOR_177", "H11:GPIOT_RXN03", "U12:GPIOB_RXN06"),
    ("D11:GPIOT_RXN02", "A10:GPIOT_TXP25", "E9:GPIOT_TXP21", "G9:GPIOT_TXP22", "C6:GPIOT_TXP10", "B14:GPIOT_RXP15"),
    ("C4:GPIOT_TXN03", "A4:GPIOT_TXP06", "A5:GPIOT_TXP07", "B5:GPIOT_TXN07", "A3:GPIOT_TXN06", None),
    ("K5:GPIOL_81", "H3:GPIOL_131", "E1:GPIOT_TXN01", "F1:GPIOL_151", "V15:GPIOB_RXP29", "A2:GPIOT_TXP05"),
)


def emit_top(out):
    pins = dict(HOST)
    assignments = []

    def pin(name, mode, location, signal):
        ball, resource = location
        if (name in pins or ball in {"A9", "AB9", "A6", "D10"}
                or any(ball == p[1] or resource == p[2] for p in pins.values())):
            raise ValueError(f"reserved or duplicate pin: {name} at {ball}/{resource}")
        pins[name] = (mode, ball, resource)
        left, right = (signal, name) if mode == "in" else (name, signal)
        assignments.append(f"    {left} <= {right};")

    for i, locations in enumerate(CONTROL):
        signals = ("dpi_mosi", "dpi_miso", "dpi_sck", "dpi_sel", "clkin", "reset_n")
        for signal, location in zip(signals, locations):
            if location:
                pin(f"dsp{i+1}_{signal}", "in" if signal == "dpi_miso" else "out",
                    location.split(":"), "clkin" if signal == "clkin" else f"{signal}({i})")

    ports = []
    for name, (mode, _, _) in pins.items():
        ports.extend(("host_miso_out : out std_logic", "host_miso_oe : out std_logic", "host_miso_in : in std_logic")
                     if mode == "inout" else (f"{name} : {mode} std_logic",))
    (out / "wing_fpga.vhd").write_text(f"""-- SPDX-License-Identifier: GPL-3.0-only
library ieee;
use ieee.std_logic_1164.all;
entity wing_fpga is
    port ({'; '.join(ports)});
end entity;
architecture rtl of wing_fpga is
    signal clkin : std_logic;
    signal dpi_miso, dpi_sel, dpi_sck, dpi_mosi, reset_n : std_logic_vector(3 downto 0);
begin
    console : entity work.wing_common
        port map (clk_audio, host_sck, host_mosi, ctrl_cs_n, dsp_cs_n,
                  host_miso_out, host_miso_oe, clkin, dpi_miso, dpi_sel, dpi_sck, dpi_mosi, reset_n);
{chr(10).join(assignments)}
end architecture;
""")
    (out / "board-pins.tsv").write_text("signal\tdirection\tball\tresource\n" + "".join(
        f"{name}\t{mode}\t{ball}\t{resource}\n" for name, (mode, ball, resource) in pins.items()))
    return pins


def xml(prefix, uri, tag, **attrs):
    return ET.Element(f"{prefix}:{tag}", {f"xmlns:{prefix}": uri, **attrs})


def write_xml(out, name, tree):
    ET.indent(tree)
    ET.ElementTree(tree).write(out / name, encoding="UTF-8", xml_declaration=True)


def emit_efinity(out, pins, sources):
    peri = xml("efxpt", "http://www.efinixinc.com/peri_design_db", "design_db",
               name=NAME, device_def=DEVICE, version=VERSION, db_version="20261009")
    banks = ET.SubElement(ET.SubElement(peri, "efxpt:device_info"), "efxpt:iobank_info")
    for bank in "1A 1B_1C 1D_1E 1F_1G 2A 2B 2C 2D 2E 2F 3D_TR_BR 4A 4B 4C 4D 4E 4F BL TL".split():
        ET.SubElement(banks, "efxpt:iobank", name=bank, iostd="1.2 V" if bank in ("BL", "TL") else "3.3 V LVTTL / LVCMOS")
    gpio = ET.SubElement(peri, "efxpt:gpio_info", device_def=DEVICE)
    for name, (mode, _, resource) in pins.items():
        io = ET.SubElement(gpio, "efxpt:gpio", name=name, gpio_def=resource,
                           mode={"in": "input", "out": "output", "inout": "inout"}[mode],
                           is_lvds_gpio=str("_RX" in resource or "_TX" in resource).lower(),
                           io_standard="3.3 V LVTTL / LVCMOS")
        if mode != "out":
            ET.SubElement(io, "efxpt:input_config", name=name + "_in" if mode == "inout" else name,
                          conn_type="normal", pull_option="weak pullup" if name in ("ctrl_cs_n", "dsp_cs_n") else "none",
                          is_register="false", ddio_type="none")
        if mode != "in":
            ET.SubElement(io, "efxpt:output_config", name=name + "_out" if mode == "inout" else name,
                          register_option="none", clock_name="", drive_strength="1", tied_option="none", ddio_type="none")
        if mode == "inout":
            ET.SubElement(io, "efxpt:output_enable_config", name=name + "_oe", is_register="false")
    ET.SubElement(gpio, "efxpt:global_unused_config", state="input with weak pullup")
    for kind in ("pll", "lvds", "jtag", "ddr"):
        ET.SubElement(peri, f"efxpt:{kind}_info")
    write_xml(out, NAME + ".peri.xml", peri)
    project = xml("efx", "http://www.efinixinc.com/enf_proj", "project", name=NAME, sw_version=VERSION)
    dev = ET.SubElement(project, "efx:device_info")
    for tag, name in (("family", "Trion"), ("device", DEVICE), ("timing_model", "C4")):
        ET.SubElement(dev, f"efx:{tag}", name=name)
    design = ET.SubElement(project, "efx:design_info", def_veri_version="verilog_2k", def_vhdl_version="vhdl_2008")
    ET.SubElement(design, "efx:top_module", name="wing_fpga")
    for source in sources:
        ET.SubElement(design, "efx:design_file", name=source, version="default", library="default")
    interface = ET.SubElement(project, "efx:interface_info")
    for tag in ("default_peri_file", "peri_file"):
        ET.SubElement(interface, "efx:" + tag, name=NAME + ".peri.xml")
    ET.SubElement(ET.SubElement(project, "efx:constraint_info"), "efx:sdc_file", name="wing.sdc")
    for stage, tool, options in (
        ("synthesis", "efx_map", (("work_dir", "work_syn", "string"), ("max_threads", "4", "integer"))),
        ("place_and_route", "efx_pnr", (("work_dir", "work_pnr", "string"), ("seed", "1", "integer"),
                                       ("max_threads", "4", "integer"))),
        ("bitstream_generation", "efx_pgm", (("mode", "passive", "option"), ("width", "1", "option"),
            ("generate_bit", "on", "bool"), ("generate_hexbin", "on", "bool"), ("bitstream_compression", "off", "bool"))),
    ):
        section = ET.SubElement(project, "efx:" + stage, tool_name=tool)
        for key, value, kind in options:
            ET.SubElement(section, "efx:param", name=key, value=value, value_type="e_" + kind)
    write_xml(out, NAME + ".xml", project)


def generate(out):
    sources = [ROOT / "consoles/wing" / name for name in ("dsp_spi.vhd", "wing_common.vhd")]
    sdc = HERE / "wing.sdc"
    digest = hashlib.sha256()
    for source in [Path(__file__), sdc, *sources,
                   *(ROOT / "litex_soc" / name for name in ("generate.py", "spi_bone.py", "requirements.txt"))]:
        digest.update(hashlib.sha256(source.read_bytes()).digest())
    out.mkdir(parents=True, exist_ok=False)
    build("wing", str(out), int.from_bytes(digest.digest()[:4], "big"))
    pins = emit_top(out)
    for source in [*sources, sdc]:
        shutil.copyfile(source, out / source.name)
    names = [source.name for source in sources] + ["wing_fpga.vhd", "gateware/openaudio_soc.v"]
    emit_efinity(out, pins, names)
    (out / "sources.txt").write_text("\n".join(names) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    generate(parser.parse_args().output.resolve())
