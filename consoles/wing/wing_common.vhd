-- SPDX-License-Identifier: GPL-3.0-only
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity wing_common is
    port (
        clk_audio, host_sck, host_mosi, ctrl_cs_n, dsp_cs_n : in std_logic;
        host_miso, host_miso_oe, dsp_clkin : out std_logic;
        dpi_miso : in std_logic_vector(3 downto 0);
        dpi_sel, dpi_sck, dpi_mosi, dsp_reset_n : out std_logic_vector(3 downto 0)
    );
end entity;

architecture rtl of wing_common is
    component openaudio_soc is
        port (
            clk_sys, spibone_clk, spibone_cs_n, spibone_mosi, wing_ready : in std_logic;
            spibone_miso : out std_logic;
            wing_reset_release : out std_logic_vector(3 downto 0)
        );
    end component;
    signal phase : unsigned(1 downto 0) := (others => '0');
    signal started : std_logic_vector(3 downto 0) := (others => '0');
    signal rst, ctrl_sel, dsp_sel, ctrl_miso, dsp_miso : std_logic;
    signal req_reset : std_logic_vector(3 downto 0);
begin
    rst <= not started(3);
    process(clk_audio)
    begin
        if rising_edge(clk_audio) then
            started <= started(2 downto 0) & '1';
            phase <= phase + 1;
        end if;
    end process;
    dsp_clkin <= not phase(1);
    dsp_reset_n <= req_reset when rst = '0' else "0000";

    ctrl_sel <= ctrl_cs_n or not dsp_cs_n or rst;
    dsp_sel <= dsp_cs_n or not ctrl_cs_n or rst;
    host_miso <= ctrl_miso when ctrl_sel = '0' else dsp_miso;
    host_miso_oe <= not (ctrl_sel and dsp_sel);
    passthrough : entity work.dsp_spi
        port map (clk_audio, rst, dsp_sel, host_sck, host_mosi, dsp_miso, dpi_miso, dpi_sel, dpi_sck, dpi_mosi);
    control : openaudio_soc
        port map (clk_sys => clk_audio, spibone_clk => host_sck, spibone_cs_n => ctrl_sel,
                  spibone_mosi => host_mosi, spibone_miso => ctrl_miso, wing_ready => not rst,
                  wing_reset_release => req_reset);
end architecture;
