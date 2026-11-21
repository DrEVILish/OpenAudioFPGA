-- SPDX-License-Identifier: GPL-3.0-only
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dsp_spi is
    port (
        clk, rst, cs_n, sck, mosi : in std_logic;
        miso : out std_logic;
        dsp_miso : in std_logic_vector(3 downto 0);
        dsp_cs_n, dsp_sck, dsp_mosi : out std_logic_vector(3 downto 0)
    );
end entity;

architecture rtl of dsp_spi is
    signal cs_meta, cs_sync : std_logic := '1';
    signal sck_meta, sck_sync, sck_prev, mosi_meta, mosi_sync : std_logic := '0';
    attribute async_reg : string;
    attribute async_reg of cs_meta, cs_sync, sck_meta, sck_sync, mosi_meta, mosi_sync : signal is "true";
    signal bits : natural range 0 to 8 := 0;
    signal header : unsigned(7 downto 0) := (others => '0');
    signal selected, pass : std_logic_vector(3 downto 0) := (others => '0');
begin
    -- Arm on the *falling* edge after header bit 8, while the physical SCK is
    -- already low. The next rising edge is then precisely payload bit 1.
    process(clk)
    begin
        if rising_edge(clk) then
            cs_meta <= cs_n; cs_sync <= cs_meta;
            sck_meta <= sck; sck_sync <= sck_meta; sck_prev <= sck_sync;
            mosi_meta <= mosi; mosi_sync <= mosi_meta;
            if cs_sync = '1' or rst = '1' then
                bits <= 0; selected <= (others => '0');
            elsif bits < 8 and sck_sync = '1' and sck_prev = '0' then
                header <= header(6 downto 0) & mosi_sync;
                bits <= bits + 1;
            elsif bits = 8 and sck_sync = '0' and sck_prev = '1' then
                for i in 0 to 3 loop
                    if header = i + 1 then selected(i) <= '1'; end if;
                end loop;
            end if;
        end if;
    end process;

    pass <= selected when cs_n = '0' and rst = '0' else "0000";
    lanes : for i in 0 to 3 generate
        dsp_cs_n(i) <= not pass(i);
        dsp_sck(i) <= sck and pass(i);
        dsp_mosi(i) <= mosi and pass(i);
    end generate;
    miso <= dsp_miso(0) when pass(0) = '1' else
            dsp_miso(1) when pass(1) = '1' else
            dsp_miso(2) when pass(2) = '1' else
            dsp_miso(3) when pass(3) = '1' else '1';
end architecture;
