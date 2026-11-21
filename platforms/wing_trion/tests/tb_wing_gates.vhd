-- SPDX-License-Identifier: GPL-3.0-only
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package wing_test is
    signal release_req, enable_req, valid_req : std_logic_vector(3 downto 0) := "0000";
    signal probe_slot : std_logic_vector(8 downto 0) := (others => '0');
    signal captured : std_logic_vector(31 downto 0);
    constant PATTERN : std_logic_vector(31 downto 0) := x"829A04B7";
end package;

library ieee;
use ieee.std_logic_1164.all;
use work.wing_test.all;

-- Replace the mixed-language CSR component; tb_ss1 verifies the generated SoC separately.
entity openaudio_soc is
    port (
        clk_sys, spibone_clk, spibone_cs_n, spibone_mosi, wing_ready : in std_logic;
        spibone_miso : out std_logic;
        wing_reset_release, wing_audio_enable, wing_audio_valid : out std_logic_vector(3 downto 0);
        wing_sport_slot : out std_logic_vector(8 downto 0);
        wing_sport_send : out std_logic_vector(31 downto 0);
        wing_sport_return : in std_logic_vector(31 downto 0)
    );
end entity;
architecture mock of openaudio_soc is
begin
    spibone_miso <= '0';
    wing_reset_release <= release_req;
    wing_audio_enable <= enable_req;
    wing_audio_valid <= valid_req;
    wing_sport_slot <= probe_slot;
    wing_sport_send <= PATTERN;
    captured <= wing_sport_return;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.wing_test.all;

entity tb_wing_gates is end;
architecture test of tb_wing_gates is
    constant LANES : std_logic_vector(29 downto 0) :=
        std_logic_vector(to_unsigned(48 * 64 + 2, 15)) & std_logic_vector(to_unsigned(16, 15));
    signal clk : std_logic := '0';
    signal bclk, oe, ss0, ss1 : std_logic := '1';
    signal fs, reset_n : std_logic_vector(3 downto 0);
    signal incoming : std_logic_vector(1 downto 0) := "11";
    signal outgoing : std_logic_vector(1 downto 0);
begin
    clk <= not clk after 10 ns;
    dut : entity work.wing_common
        generic map (2, LANES, LANES, "0100", "0100")
        port map (clk, '0', '0', ss1, ss0, open, oe, open, "1111", open, open, open,
                  reset_n, bclk, fs, incoming, outgoing);

    process
        procedure next_frame is
        begin
            wait until rising_edge(fs(0));
            wait for 1 ns;
            assert bclk = '1' and fs = "0011" report "FS must rise on BCLK for armed DSPs only" severity failure;
            wait until falling_edge(bclk);
            assert fs = "0011" report "FS must last one bit" severity failure;
            wait until rising_edge(bclk);
            wait for 1 ns;
            assert fs = "0000" report "FS must end on slot 0 MSB" severity failure;
        end procedure;
        procedure read_slot(lane : natural; expected : std_logic_vector(31 downto 0)) is
            variable word : std_logic_vector(31 downto 0);
        begin
            for i in word'range loop
                wait until falling_edge(bclk);
                word(i) := outgoing(lane);
            end loop;
            assert word = expected report "wrong wire word: " & to_hstring(word) severity failure;
        end procedure;
    begin
        wait for 500 ns;
        assert fs = "0000" and reset_n = "0000" and outgoing = "00" and oe = '0' severity failure;
        ss0 <= '0'; ss1 <= '0'; wait for 100 ns;
        assert oe = '0' report "two selects must not drive MISO" severity failure;
        ss1 <= '1'; wait for 100 ns;
        assert oe = '1' severity failure;
        ss0 <= '1';

        enable_req <= "0011";
        wait for 25 us;
        assert fs = "0000" and reset_n = "0000" and captured = x"00000000" severity failure;
        release_req <= "0011";
        wait until reset_n = "0011";
        assert fs = "0000" report "release must precede first FS" severity failure;
        next_frame;
        read_slot(0, PATTERN);
        wait for 100 ns;
        assert captured = x"00000000" report "arming cannot imply return valid" severity failure;
        valid_req <= "0001";
        next_frame;
        read_slot(0, PATTERN);
        wait for 100 ns;
        assert captured = x"FFFFFFFF" report "valid return missing or wrong DSP lane" severity failure;

        probe_slot <= std_logic_vector(to_unsigned(49, 9));
        next_frame;
        read_slot(1, x"00000000");
        read_slot(1, PATTERN);
        read_slot(1, x"00000000");
        assert captured = x"00000000" report "DSP2 data escaped without its own valid bit" severity failure;
        probe_slot <= std_logic_vector(to_unsigned(50, 9));
        next_frame;
        for slot in 0 to 2 loop read_slot(1, x"00000000"); end loop;
        release_req <= "0000";
        wait until reset_n = "0000";
        assert fs = "0000" and captured = x"00000000" severity failure;
        report "WING SPORT: FS alignment, per-DSP gates, slot/lane ordering and unused slot zeros passed";
        std.env.stop;
    end process;
end architecture;
