--
-- OpenAudioFPGA - generic audio core for OpenX32 / OpenWING
-- Copyright 2025-2026 OpenMixerProject
-- https://github.com/OpenMixerProject/OpenAudioFPGA
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- version 3 as published by the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
--
-- Vendor-neutral audio core: audio clock tree, TDM8 serialisers, routing matrix,
-- SPI configuration bus and a configurable number of AES50 and AES67 cores.
--
-- This entity contains no vendor primitives (no PLLs, no DDR / IO registers, no
-- clock buffers). Everything that depends on the FPGA family or on the console
-- belongs into the layers above:
--
--   platforms/<console>_<fpga>   top level: pins, PLLs, IO registers, constraints
--   consoles/<console>           console specific, but vendor-neutral logic
--   rtl/core (this file)         generic core
--
-- Audio lines
-- -----------
-- The unit of the matrix is the "TDM line": one serial TDM8 stream with
-- 8 channels of 24 bit in 32 bit slots, clocked with 256 fs.
--
--   inputs  (sources):      G_TDM_LINES_IN  lines = 8 * G_TDM_LINES_IN  channels
--   outputs (destinations): G_TDM_LINES_OUT lines = 8 * G_TDM_LINES_OUT channels
--
-- The AES50 cores sit on the same lines: core k (0 .. G_AES50_PORTS - 1) uses the
-- 6 lines G_AES50_FIRST_LINE + 6 * k .. + 5 in both directions (48 channels).
-- The AES67 cores do the same with 4 lines each (32 channels), starting at
-- G_AES67_FIRST_LINE. For the lines of both the bits of tdm_i are ignored; tdm_o
-- still carries the data. All other lines are free for the layer above
-- (converters, DSPs, cards, ...).
--
-- The network cores are instantiated here, but they keep their own source
-- trees: rtl/aes50 for AES50, the AES67 repository for AES67 (component
-- top_rmii_tdm8_100m). With G_AES67_PORTS = 0 the AES67 sources are not needed.
-- Which vendor variant of their IO / RAM / SoC files is used is decided by the
-- file list of the platform, not here.
--
-- Routing
-- -------
-- 16 bit SPI words (mode 0, MSB first): DATA[15:8] ADDR[7:0]
--
--   ADDR 0 .. 8 * G_TDM_LINES_OUT - 1   destination channel (line * 8 + channel)
--   DATA 0                              off (silence)
--   DATA 1 .. 8 * G_TDM_LINES_IN        source channel (line * 8 + channel + 1)
--   ADDR 255                            configuration register (cfg_bits_o)
--
-- The decoded write strobe is exported (cfg_wr_*), so the layer above can add
-- its own registers on unused addresses.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity openaudio_core is
	generic (
		-- matrix size
		G_TDM_LINES_IN			: positive := 24;		-- TDM8 input lines (8 channels each)
		G_TDM_LINES_OUT			: positive := 24;		-- TDM8 output lines (8 channels each)

		-- AES50
		G_AES50_PORTS			: natural := 1;			-- number of AES50 cores (0 = none)
		G_AES50_FIRST_LINE		: natural := 14;		-- first TDM line of AES50 core 0
		G_AES50_SUPPORT_44K1	: boolean := false;		-- false: half-size sample RAMs, 48k only
		G_AES50_UART_AUX		: boolean := true;		-- aux channel over UART
		G_AES50_TDM_AUX			: boolean := true;		-- aux channel over the 7th TDM line
		G_AES50_UART_FIFO_AW	: natural := 11;		-- UART FIFOs: 2**n - 1 bytes
		G_AES50_UART_BAUD		: positive := 115200;	-- baudrate of the aux UARTs
		G_AES50_SIM_ASSM_SAMPLES	: natural := 2048;	-- simulation only: shorter ASSM period

		-- AES67
		G_AES67_PORTS			: natural := 0;			-- number of AES67 cores (0 = none)
		G_AES67_FIRST_LINE		: natural := 20;		-- first TDM line of AES67 core 0

		-- audio clock tree (see audioclk.vhd). With AES67 cores the divider follows the frame
		-- sync of AES67 core 0 (PTP), else fs_sync_i.
		G_FS_SYNC_CNT			: natural range 0 to 511 := 0;
		G_FS_ADVANCE			: natural range 0 to 511 := 3
	);
	port (
		-- audio clocks
		clk_fs1024_i		: in  std_logic;			-- 1024 fs (49.152 MHz at 48 kHz) from the audio PLL
		fs_sync_i			: in  std_logic := '0';		-- optional: frame sync of an external clock master, '0' = free running
														-- (not used if G_AES67_PORTS > 0)
		clk_fs512_o			: out std_logic;			-- 512 fs
		clk_fs256_o			: out std_logic;			-- 256 fs = TDM8 bit clock
		fsync_o				: out std_logic;			-- fs = TDM8 frame sync

		-- configuration (SPI slave, write only)
		spi_ncs_i			: in  std_logic;
		spi_clk_i			: in  std_logic;
		spi_mosi_i			: in  std_logic;
		cfg_wr_en_o			: out std_logic;			-- one clk_fs512_o pulse per received word
		cfg_wr_addr_o		: out std_logic_vector(7 downto 0);
		cfg_wr_data_o		: out std_logic_vector(7 downto 0);
		cfg_bits_o			: out std_logic_vector(7 downto 0);	-- register at address 255

		-- TDM8 lines
		tdm_i				: in  std_logic_vector(G_TDM_LINES_IN - 1 downto 0);
		tdm_o				: out std_logic_vector(G_TDM_LINES_OUT - 1 downto 0);
		-- the current channel of every output line as a parallel word (e.g. for UltraNet)
		tdm_par_o			: out std_logic_vector(G_TDM_LINES_OUT * 24 - 1 downto 0);

		-- AES50 (one element / pair per core, unused if G_AES50_PORTS = 0)
		clk50_i				: in  std_logic := '0';		-- 50 MHz RMII clock
		aes50_rst_i			: in  std_logic := '1';
		aes50_fs_mode_i		: in  std_logic_vector(1 downto 0) := "01";		-- "01" = 48 kHz
		aes50_sys_mode_i	: in  std_logic_vector(2 * G_AES50_PORTS - 1 downto 0) := (others => '0');
		aes50_aux_uart_sel_i	: in  std_logic_vector(G_AES50_PORTS - 1 downto 0) := (others => '1');	-- aux TX: '1' = UART, '0' = TDM

		aes50_rmii_crs_dv_i	: in  std_logic_vector(G_AES50_PORTS - 1 downto 0) := (others => '0');
		aes50_rmii_rxd_i	: in  std_logic_vector(2 * G_AES50_PORTS - 1 downto 0) := (others => '0');
		aes50_rmii_tx_en_o	: out std_logic_vector(G_AES50_PORTS - 1 downto 0);
		aes50_rmii_txd_o	: out std_logic_vector(2 * G_AES50_PORTS - 1 downto 0);
		aes50_phy_rst_n_o	: out std_logic_vector(G_AES50_PORTS - 1 downto 0);

		aes50_clk_a_rx_i	: in  std_logic_vector(G_AES50_PORTS - 1 downto 0) := (others => '0');
		aes50_clk_a_tx_o	: out std_logic_vector(G_AES50_PORTS - 1 downto 0);
		aes50_clk_a_tx_en_o	: out std_logic_vector(G_AES50_PORTS - 1 downto 0);
		aes50_clk_b_rx_i	: in  std_logic_vector(G_AES50_PORTS - 1 downto 0) := (others => '0');
		aes50_clk_b_tx_o	: out std_logic_vector(G_AES50_PORTS - 1 downto 0);
		aes50_clk_b_tx_en_o	: out std_logic_vector(G_AES50_PORTS - 1 downto 0);

		aes50_tdm_aux_i		: in  std_logic_vector(G_AES50_PORTS - 1 downto 0) := (others => '0');	-- 7th TDM line (aux data)
		aes50_tdm_aux_o		: out std_logic_vector(G_AES50_PORTS - 1 downto 0);
		aes50_uart_i		: in  std_logic_vector(G_AES50_PORTS - 1 downto 0) := (others => '1');
		aes50_uart_o		: out std_logic_vector(G_AES50_PORTS - 1 downto 0);
		aes50_ok_o			: out std_logic_vector(G_AES50_PORTS - 1 downto 0);

		-- AES67 (one element / pair per core, unused if G_AES67_PORTS = 0)
		-- RMII with clk50_i; register access over the SPI pins above with an own chip select per core
		clk100_i			: in  std_logic := '0';		-- 100 MHz system clock of the AES67 cores
		aes67_rst_n_i		: in  std_logic := '0';		-- '1' when the clocks are stable
		aes67_rmii_crs_dv_i	: in  std_logic_vector(G_AES67_PORTS - 1 downto 0) := (others => '0');
		aes67_rmii_rxd_i	: in  std_logic_vector(2 * G_AES67_PORTS - 1 downto 0) := (others => '0');
		aes67_rmii_tx_en_o	: out std_logic_vector(G_AES67_PORTS - 1 downto 0);
		aes67_rmii_txd_o	: out std_logic_vector(2 * G_AES67_PORTS - 1 downto 0);
		aes67_spi_ncs_i		: in  std_logic_vector(G_AES67_PORTS - 1 downto 0) := (others => '1');
		aes67_spi_miso_o	: out std_logic_vector(G_AES67_PORTS - 1 downto 0);
		aes67_irq_o			: out std_logic_vector(G_AES67_PORTS - 1 downto 0);
		-- PTP disciplined 512 fs clock of every core: reference for the audio PLL that generates clk_fs1024_i
		aes67_pll_ref_o		: out std_logic_vector(G_AES67_PORTS - 1 downto 0)
	);
end entity openaudio_core;

architecture rtl of openaudio_core is
	constant C_DATA_WIDTH	: integer := 24;
	-- the SPI protocol carries 8 bit addresses and 8 bit sources
	constant C_ADDR_WIDTH	: integer := 8;
	constant C_AES50_LINES	: natural := 6;		-- TDM lines per AES50 core (48 channels)
	constant C_AES67_LINES	: natural := 4;		-- TDM lines per AES67 core (32 channels)

	-- timer values of the AES50 cores, counted in clocks of the 50 MHz RMII clock
	constant C_CLK50_HZ			: natural := 50000000;
	constant C_AES50_UART_CLKS	: natural := (C_CLK50_HZ + G_AES50_UART_BAUD / 2) / G_AES50_UART_BAUD;
	constant C_AES50_10MS		: natural := C_CLK50_HZ / 100;
	constant C_AES50_1MS		: natural := C_CLK50_HZ / 1000;

	signal clk_fs512		: std_logic;
	signal clk_fs256		: std_logic;
	signal fsync			: std_logic;
	signal fs_sync			: std_logic;
	signal aes67_fsync		: std_logic_vector(G_AES67_PORTS - 1 downto 0);

	signal cfg_wr_en		: std_logic;
	signal cfg_wr_addr		: std_logic_vector(7 downto 0);
	signal cfg_wr_data		: std_logic_vector(7 downto 0);

	signal tdm_rx			: std_logic_vector(G_TDM_LINES_IN - 1 downto 0);
	signal tdm_tx			: std_logic_vector(G_TDM_LINES_OUT - 1 downto 0);
	signal rx_par			: std_logic_vector(G_TDM_LINES_IN * C_DATA_WIDTH - 1 downto 0);
	signal tx_par			: std_logic_vector(G_TDM_LINES_OUT * C_DATA_WIDTH - 1 downto 0);

	signal ram_wr_en		: std_logic;
	signal ram_wr_addr		: std_logic_vector(C_ADDR_WIDTH - 1 downto 0);
	signal ram_wr_data		: std_logic_vector(C_DATA_WIDTH - 1 downto 0);
	signal ram_rd_addr		: std_logic_vector(C_ADDR_WIDTH - 1 downto 0);
	signal ram_rd_data		: std_logic_vector(C_DATA_WIDTH - 1 downto 0);
	signal channel_idx		: std_logic_vector(C_ADDR_WIDTH - 1 downto 0);

	-- AES67 core (AES67 repository, FPGA/boards/integration/top_rmii_tdm8_100m.vhd).
	-- A component, so that the core compiles without the AES67 sources if G_AES67_PORTS = 0.
	component top_rmii_tdm8_100m
		port (
			sys_clk_i		: in  std_logic;
			rst_n_i			: in  std_logic;
			ext_mcu_clk_i	: in  std_logic;
			ext_locked_i	: in  std_logic;
			rmii_ref_clk_i	: in  std_logic;
			rmii_crs_dv_i	: in  std_logic;
			rmii_rxd_i		: in  std_logic_vector(1 downto 0);
			rmii_tx_en_o	: out std_logic;
			rmii_txd_o		: out std_logic_vector(1 downto 0);
			mclk_o			: out std_logic;
			bclk_o			: out std_logic;
			fsync_adc_o		: out std_logic;
			fsync_dac_o		: out std_logic;
			tdm_in_i		: in  std_logic_vector(3 downto 0);
			tdm_out_o		: out std_logic_vector(3 downto 0);
			pll_ref_o		: out std_logic;
			ext_mclk_i		: in  std_logic;
			spi_clk_i		: in  std_logic;
			spi_cs_n_i		: in  std_logic;
			spi_mosi_i		: in  std_logic;
			spi_miso_o		: out std_logic;
			irq_o			: out std_logic);
	end component;

	-- true if this line is driven by an AES50 / AES67 core instead of tdm_i
	function is_aes50_line(line : natural) return boolean is
	begin
		return (line >= G_AES50_FIRST_LINE) and (line < G_AES50_FIRST_LINE + C_AES50_LINES * G_AES50_PORTS);
	end function;

	function is_aes67_line(line : natural) return boolean is
	begin
		return (line >= G_AES67_FIRST_LINE) and (line < G_AES67_FIRST_LINE + C_AES67_LINES * G_AES67_PORTS);
	end function;
begin
	-- the matrix needs at least two lines (the RAM writer always handles a second receiver),
	-- source 0 is "off" and address 255 is the configuration register
	assert G_TDM_LINES_IN >= 2 and G_TDM_LINES_OUT >= 2
		report "openaudio_core: at least 2 TDM lines per direction are required" severity failure;
	assert 8 * G_TDM_LINES_IN <= 2**C_ADDR_WIDTH - 1
		report "openaudio_core: too many input lines for 8 bit source numbers (max. 31)" severity failure;
	assert 8 * G_TDM_LINES_OUT <= 2**C_ADDR_WIDTH - 1
		report "openaudio_core: too many output lines for 8 bit addresses (max. 31)" severity failure;
	assert G_AES50_PORTS = 0 or
		(G_AES50_FIRST_LINE + C_AES50_LINES * G_AES50_PORTS <= G_TDM_LINES_IN and
		 G_AES50_FIRST_LINE + C_AES50_LINES * G_AES50_PORTS <= G_TDM_LINES_OUT)
		report "openaudio_core: the AES50 lines do not fit into the matrix" severity failure;
	assert G_AES67_PORTS = 0 or
		(G_AES67_FIRST_LINE + C_AES67_LINES * G_AES67_PORTS <= G_TDM_LINES_IN and
		 G_AES67_FIRST_LINE + C_AES67_LINES * G_AES67_PORTS <= G_TDM_LINES_OUT)
		report "openaudio_core: the AES67 lines do not fit into the matrix" severity failure;
	assert G_AES50_PORTS = 0 or G_AES67_PORTS = 0 or
		G_AES50_FIRST_LINE + C_AES50_LINES * G_AES50_PORTS <= G_AES67_FIRST_LINE or
		G_AES67_FIRST_LINE + C_AES67_LINES * G_AES67_PORTS <= G_AES50_FIRST_LINE
		report "openaudio_core: the AES50 and AES67 lines overlap" severity failure;

	------------------------------------------------------------------------
	-- audio clock tree
	------------------------------------------------------------------------
	gen_fs_sync_aes67 : if G_AES67_PORTS > 0 generate
		fs_sync <= aes67_fsync(0);
	end generate;

	gen_fs_sync_ext : if G_AES67_PORTS = 0 generate
		fs_sync <= fs_sync_i;
	end generate;

	u_audioclk : entity work.audioclk
		generic map (
			AES67_SYNC_CNT => G_FS_SYNC_CNT,
			FS_ADVANCE => G_FS_ADVANCE)
		port map (
			clock_to_aes67_i => '1',
			aes67_fs_i => fs_sync,
			aes67_bclk_i => '0',
			fs_x_1024_i => clk_fs1024_i,
			fs_x_512_o => clk_fs512,
			fs_x_256_o => clk_fs256,
			fs_x_128_o => open,
			fs_x_64_o => open,
			fs_o => fsync);

	clk_fs512_o <= clk_fs512;
	clk_fs256_o <= clk_fs256;
	fsync_o <= fsync;

	------------------------------------------------------------------------
	-- configuration bus
	------------------------------------------------------------------------
	u_spi : entity work.spi_rx_routing
		port map (
			clk => clk_fs512,
			i_spi_ncs => spi_ncs_i,
			i_spi_clk => spi_clk_i,
			i_spi_data => spi_mosi_i,
			o_cfg_wr_addr => cfg_wr_addr,
			o_cfg_wr_data => cfg_wr_data,
			o_cfg_wr_en => cfg_wr_en);

	u_config : entity work.config_rxd
		port map (
			clk => clk_fs512,
			cfg_wr_addr => cfg_wr_addr,
			cfg_wr_data => cfg_wr_data,
			cfg_wr_en => cfg_wr_en,
			config_bits => cfg_bits_o);

	cfg_wr_en_o <= cfg_wr_en;
	cfg_wr_addr_o <= cfg_wr_addr;
	cfg_wr_data_o <= cfg_wr_data;

	------------------------------------------------------------------------
	-- TDM8 receivers -> audio RAM -> routing -> TDM8 senders
	------------------------------------------------------------------------
	gen_ext_in : for i in 0 to G_TDM_LINES_IN - 1 generate
		gen_pin : if not is_aes50_line(i) and not is_aes67_line(i) generate
			tdm_rx(i) <= tdm_i(i);
		end generate;
	end generate;

	u_tdm_rx : entity work.tdm_multichan_rx
		generic map (
			TDM_RECEIVER => G_TDM_LINES_IN,
			DATA_WIDTH => C_DATA_WIDTH)
		port map (
			bclk => clk_fs256,
			fsync => fsync,
			tdm_in => tdm_rx,
			data_out => rx_par);

	u_ram_write : entity work.audiomatrix_ram_write
		generic map (
			TDM_RECEIVER => G_TDM_LINES_IN,
			DATA_WIDTH => C_DATA_WIDTH,
			NUM_INPUT_PORTS => 8 * G_TDM_LINES_IN,
			ADDR_WIDTH => C_ADDR_WIDTH)
		port map (
			clk => clk_fs512,
			bclk => clk_fs256,
			fsync => fsync,
			input_data => rx_par,
			o_ram_write_addr => ram_wr_addr,
			o_ram_data => ram_wr_data,
			o_ram_wr_en => ram_wr_en);

	u_ram : entity work.audiomatrix_ram
		generic map (
			DATA_WIDTH => C_DATA_WIDTH,
			RAM_DEPTH => 2**C_ADDR_WIDTH,
			ADDR_WIDTH => C_ADDR_WIDTH)
		port map (
			clk => clk_fs512,
			write_addr => ram_wr_addr,
			i_data => ram_wr_data,
			wr_en => ram_wr_en,
			read_addr => ram_rd_addr,
			o_data => ram_rd_data);

	u_routing_ram : entity work.audiomatrix_routing_ram
		generic map (
			RAM_DEPTH => 2**C_ADDR_WIDTH,
			ADDR_WIDTH => C_ADDR_WIDTH)
		port map (
			clk => clk_fs512,
			cfg_wr_addr => cfg_wr_addr,
			cfg_wr_data => cfg_wr_data,
			cfg_wr_en => cfg_wr_en,
			channel_idx => channel_idx,
			read_addr => ram_rd_addr);

	u_ram_read : entity work.audiomatrix_ram_read
		generic map (
			TDM_SENDER => G_TDM_LINES_OUT,
			DATA_WIDTH => C_DATA_WIDTH,
			NUM_OUTPUT_PORTS => 8 * G_TDM_LINES_OUT,
			ADDR_WIDTH => C_ADDR_WIDTH)
		port map (
			clk => clk_fs512,
			bclk => clk_fs256,
			fsync => fsync,
			ram_data => ram_rd_data,
			channel_idx_out => channel_idx,
			data_out => tx_par);

	u_tdm_tx : entity work.tdm_multichan_tx
		generic map (
			TDM_RECEIVER => G_TDM_LINES_OUT,
			DATA_WIDTH => C_DATA_WIDTH)
		port map (
			bclk => clk_fs256,
			fsync => fsync,
			data_in => tx_par,
			tdm_out => tdm_tx);

	tdm_o <= tdm_tx;
	tdm_par_o <= tx_par;

	------------------------------------------------------------------------
	-- AES50 cores
	------------------------------------------------------------------------
	gen_aes50 : for k in 0 to G_AES50_PORTS - 1 generate
		constant C_LINE	: natural := G_AES50_FIRST_LINE + C_AES50_LINES * k;
		signal aes50_tdm_in		: std_logic_vector(6 downto 0);
		signal aes50_tdm_out	: std_logic_vector(6 downto 0);
	begin
		aes50_tdm_in <= aes50_tdm_aux_i(k) & tdm_tx(C_LINE + C_AES50_LINES - 1 downto C_LINE);
		tdm_rx(C_LINE + C_AES50_LINES - 1 downto C_LINE) <= aes50_tdm_out(C_AES50_LINES - 1 downto 0);
		aes50_tdm_aux_o(k) <= aes50_tdm_out(6);

		u_aes50 : entity work.aes50_core
			generic map (
				G_SUPPORT_44K1 => G_AES50_SUPPORT_44K1,
				G_UART_AUX => G_AES50_UART_AUX,
				G_TDM_AUX => G_AES50_TDM_AUX,
				G_UART_FIFO_AW => G_AES50_UART_FIFO_AW,
				-- tdm_multichan_rx / _tx: MSB one BCLK after the first rising BCLK edge that sees fsync high
				G_FSYNC_DELAY => 1,
				G_TX_LEAD_ADJ => 0,
				G_SIM_ASSM_SAMPLES => G_AES50_SIM_ASSM_SAMPLES)
			port map (
				clk50_i => clk50_i,
				rst_i => aes50_rst_i,
				fs_mode_i => aes50_fs_mode_i,
				sys_mode_i => aes50_sys_mode_i(2 * k + 1 downto 2 * k),
				tdm8_i2s_mode_i => '0',
				aux_tx_tdm_uart_select_i => aes50_aux_uart_sel_i(k),
				rmii_crs_dv_i => aes50_rmii_crs_dv_i(k),
				rmii_rxd_i => aes50_rmii_rxd_i(2 * k + 1 downto 2 * k),
				rmii_tx_en_o => aes50_rmii_tx_en_o(k),
				rmii_txd_o => aes50_rmii_txd_o(2 * k + 1 downto 2 * k),
				phy_rst_n_o => aes50_phy_rst_n_o(k),
				aes50_clk_a_rx_i => aes50_clk_a_rx_i(k),
				aes50_clk_a_tx_o => aes50_clk_a_tx_o(k),
				aes50_clk_a_tx_en_o => aes50_clk_a_tx_en_o(k),
				aes50_clk_b_rx_i => aes50_clk_b_rx_i(k),
				aes50_clk_b_tx_o => aes50_clk_b_tx_o(k),
				aes50_clk_b_tx_en_o => aes50_clk_b_tx_en_o(k),
				-- the audio PLL is controlled by the layer above, the core only follows it
				clk_1024xfs_from_pll_i => clk_fs1024_i,
				pll_lock_n_i => '0',
				clk_to_pll_o => open,
				pll_mult_value_o => open,
				pll_init_busy_i => '0',
				mclk_o => open,
				wclk_o => open,
				bclk_o => open,
				wclk_readback_i => fsync,
				bclk_readback_i => clk_fs256,
				wclk_out_en_o => open,
				bclk_out_en_o => open,
				tdm_i => aes50_tdm_in,
				tdm_o => aes50_tdm_out,
				i2s_i => '0',
				i2s_o => open,
				aes_ok_o => aes50_ok_o(k),
				rx_blk_drop_o => open,
				dbg_o => open,
				uart_o => aes50_uart_o(k),
				uart_i => aes50_uart_i(k),
				debug_out_signal_pulse_len_i => C_AES50_10MS,
				first_transmit_start_counter_48k_i => 0,				-- not used in v2
				first_transmit_start_counter_44k1_i => 0,				-- not used in v2
				wd_aes_clk_timeout_i => 25,								-- 0.5 us
				wd_aes_rx_dv_timeout_i => 7500,							-- 150 us
				mdix_timer_1ms_reference_i => C_AES50_1MS,
				aes_clk_ok_counter_reference_i => C_AES50_10MS,
				mult_clk625_48k_i => 8246337,
				mult_clk625_44k1_i => 7576322,
				uart_clks_per_bit_i => C_AES50_UART_CLKS,
				uart_timeout_clks_i => C_AES50_10MS,
				uart_overflow_o => open);
	end generate;

	------------------------------------------------------------------------
	-- AES67 cores
	------------------------------------------------------------------------
	gen_aes67 : for k in 0 to G_AES67_PORTS - 1 generate
		constant C_LINE	: natural := G_AES67_FIRST_LINE + C_AES67_LINES * k;
	begin
		u_aes67 : top_rmii_tdm8_100m
			port map (
				sys_clk_i => clk100_i,
				rst_n_i => aes67_rst_n_i,
				ext_mcu_clk_i => clk50_i,
				ext_locked_i => aes67_rst_n_i,
				rmii_ref_clk_i => clk50_i,
				rmii_crs_dv_i => aes67_rmii_crs_dv_i(k),
				rmii_rxd_i => aes67_rmii_rxd_i(2 * k + 1 downto 2 * k),
				rmii_tx_en_o => aes67_rmii_tx_en_o(k),
				rmii_txd_o => aes67_rmii_txd_o(2 * k + 1 downto 2 * k),
				mclk_o => open,
				bclk_o => open,
				fsync_adc_o => aes67_fsync(k),
				fsync_dac_o => open,
				tdm_in_i => tdm_tx(C_LINE + C_AES67_LINES - 1 downto C_LINE),
				tdm_out_o => tdm_rx(C_LINE + C_AES67_LINES - 1 downto C_LINE),
				pll_ref_o => aes67_pll_ref_o(k),
				ext_mclk_i => clk_fs512,
				spi_clk_i => spi_clk_i,
				spi_cs_n_i => aes67_spi_ncs_i(k),
				spi_mosi_i => spi_mosi_i,
				spi_miso_o => aes67_spi_miso_o(k),
				irq_o => aes67_irq_o(k));
	end generate;
end architecture rtl;
