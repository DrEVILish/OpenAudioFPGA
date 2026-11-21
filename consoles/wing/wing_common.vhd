-- SPDX-License-Identifier: GPL-3.0-only
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity wing_common is
    generic (
        G_LANES : positive;
        G_RX_USED, G_TX_USED : std_logic_vector(15 * G_LANES - 1 downto 0);
        G_RX_DSP, G_TX_DSP : std_logic_vector(2 * G_LANES - 1 downto 0)
    );
    port (
        clk_audio, host_sck, host_mosi, ctrl_cs_n, dsp_cs_n : in std_logic;
        host_miso, host_miso_oe, dsp_clkin : out std_logic;
        dpi_miso : in std_logic_vector(3 downto 0);
        dpi_sel, dpi_sck, dpi_mosi, dsp_reset_n : out std_logic_vector(3 downto 0);
        dsp_bclk : out std_logic;
        dsp_fs : out std_logic_vector(3 downto 0) := (others => '0');
        dsp_return : in std_logic_vector(G_LANES - 1 downto 0);
        dsp_send : out std_logic_vector(G_LANES - 1 downto 0)
    );
end entity;

architecture rtl of wing_common is
    component openaudio_soc is
        port (
            clk_sys, spibone_clk, spibone_cs_n, spibone_mosi, wing_ready : in std_logic;
            spibone_miso : out std_logic;
            wing_reset_release, wing_audio_enable, wing_audio_valid : out std_logic_vector(3 downto 0);
            wing_sport_slot : out std_logic_vector(8 downto 0);
            wing_sport_send : out std_logic_vector(31 downto 0);
            wing_sport_return : in std_logic_vector(31 downto 0)
        );
    end component;
    signal phase : unsigned(9 downto 0) := (others => '0');
    signal started : std_logic_vector(3 downto 0) := (others => '0');
    signal rst, ctrl_sel, dsp_sel, ctrl_miso, dsp_miso : std_logic;
    signal req_reset, req_enable, req_valid : std_logic_vector(3 downto 0);
    constant RESET_MASK : std_logic_vector(3 downto 0) := "1011";
    signal released, release_next, armed, accepting, valid_next : std_logic_vector(3 downto 0) := (others => '0');
    signal rx_valid, tx_enable : std_logic_vector(G_LANES - 1 downto 0);
    signal rx_we, tx_req, tx_valid : std_logic;
    signal rx_addr, tx_addr : unsigned(8 downto 0);
    signal sport_slot : std_logic_vector(8 downto 0);
    signal slot_active : unsigned(8 downto 0) := (others => '1');
    signal rx_word, tx_word, sport_send : std_logic_vector(31 downto 0);
    signal sport_return : std_logic_vector(31 downto 0) := (others => '0');

    function owner(packed : std_logic_vector; lane : natural) return natural is
    begin
        return to_integer(unsigned(packed(2*lane+1 downto 2*lane)));
    end;
begin
    rst <= not started(3);
    process(clk_audio)
        variable accept_next : std_logic_vector(3 downto 0);
    begin
        if rising_edge(clk_audio) then
            accept_next := valid_next and armed and (release_next or not RESET_MASK);
            started <= started(2 downto 0) & '1';
            phase <= phase + 1;
            if phase = 1019 then
                -- A DSP must already be out of reset before it can see FS.
                release_next <= req_reset and RESET_MASK;
                armed <= req_enable and (req_reset or not RESET_MASK) and (released or not RESET_MASK);
                valid_next <= req_valid and armed;
            end if;
            if phase = 1022 and rst = '0' then dsp_fs <= armed;
            elsif phase = 0 or rst = '1' then dsp_fs <= (others => '0'); end if;
            if phase = 0 then
                released <= release_next;
                accepting <= accept_next;
            end if;

            -- One diagnostic word in each direction; no mixer or cross-DSP route.
            -- The transmit word is sampled with tx_req for the following slot.
            if tx_req = '1' then tx_word <= sport_send; end if;
            if slot_active /= unsigned(sport_slot) or accepting = "0000"
                or (phase = 0 and accepting /= accept_next) then
                sport_return <= (others => '0');
                slot_active <= unsigned(sport_slot);
            elsif rx_we = '1' and rx_addr = slot_active then
                sport_return <= rx_word;
            end if;
        end if;
    end process;
    dsp_clkin <= not phase(1);
    dsp_bclk <= phase(0);
    dsp_reset_n <= released;
    tx_valid <= '1' when tx_addr = unsigned(sport_slot) else '0';
    lanes : for lane in 0 to G_LANES - 1 generate
        rx_valid(lane) <= accepting(owner(G_RX_DSP, lane));
        tx_enable(lane) <= armed(owner(G_TX_DSP, lane));
    end generate;
    sport : entity work.tdm_frame_io
        generic map (G_LANES, 16, 0, 0, 32, G_RX_USED, G_TX_USED)
        port map (clk_audio, rst, phase, dsp_return, rx_valid, dsp_send,
                  rx_we, tx_req, rx_addr, tx_addr, rx_word, tx_word, tx_valid, tx_enable);

    ctrl_sel <= ctrl_cs_n or not dsp_cs_n or rst;
    dsp_sel <= dsp_cs_n or not ctrl_cs_n or rst;
    host_miso <= ctrl_miso when ctrl_sel = '0' else dsp_miso;
    host_miso_oe <= not (ctrl_sel and dsp_sel);
    passthrough : entity work.dsp_spi
        port map (clk_audio, rst, dsp_sel, host_sck, host_mosi, dsp_miso, dpi_miso, dpi_sel, dpi_sck, dpi_mosi);
    control : openaudio_soc
        port map (clk_sys => clk_audio, spibone_clk => host_sck, spibone_cs_n => ctrl_sel,
                  spibone_mosi => host_mosi, spibone_miso => ctrl_miso, wing_ready => not rst,
                  wing_reset_release => req_reset, wing_audio_enable => req_enable,
                  wing_audio_valid => req_valid, wing_sport_slot => sport_slot,
                  wing_sport_send => sport_send, wing_sport_return => sport_return);
end architecture;
