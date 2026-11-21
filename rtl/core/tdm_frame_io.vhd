-- SPDX-License-Identifier: GPL-3.0-only
-- Frame-mode TDM endpoint. RAM addresses are stable lane-major channel IDs;
-- the slot clock is always a divide of the matrix clock, never a CDC.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tdm_frame_io is
    generic (
        G_LANES, G_SLOTS, G_FIRST, G_IO_FIRST, G_PAYLOAD_BITS : natural;
        -- Lane descriptor: 9-bit base ID and 6-bit used slots, lane 0 at LSB.
        G_RX_USED, G_TX_USED : std_logic_vector(15 * G_LANES - 1 downto 0)
    );
    port (
        clk, rst : in std_logic;
        phase : in unsigned(9 downto 0);
        lane_in, lane_valid : in std_logic_vector(G_LANES - 1 downto 0);
        lane_out : out std_logic_vector(G_LANES - 1 downto 0);
        rx_we, tx_req : out std_logic;
        rx_addr, tx_addr : out unsigned(8 downto 0);
        rx_sample : out std_logic_vector(31 downto 0);
        tx_sample : in std_logic_vector(31 downto 0);
        tx_valid : in std_logic;
        lane_tx_enable : in std_logic_vector(G_LANES - 1 downto 0) := (others => '1')
    );
end entity;

architecture rtl of tdm_frame_io is
    constant SLOT_CLOCKS : positive := 1024 / G_SLOTS;
    constant BIT_CLOCKS : positive := SLOT_CLOCKS / 32;
    -- SPORT's rising drive edge starts the current bit; the AES50 TDM
    -- falling drive edge starts the next bit after the current sample.
    function first_tx_bit return natural is
    begin
        if G_SLOTS = 16 then return 0; else return 31; end if;
    end;
    type words is array (0 to G_LANES - 1) of std_logic_vector(G_PAYLOAD_BITS - 1 downto 0);
    signal in_shift, in_words, out_shift, out_words : words := (others => (others => '0'));
    signal lane_d : natural range 0 to G_LANES - 1 := 0;
    signal req_d, used_d : std_logic := '0';
    signal slot, cycle, bitpos : natural;

    function used(lanes : std_logic_vector; lane : natural) return natural is
    begin
        return to_integer(unsigned(lanes(15 * lane + 5 downto 15 * lane)));
    end;

    function first(lanes : std_logic_vector; lane : natural) return natural is
    begin
        return G_FIRST + to_integer(unsigned(lanes(15 * lane + 14 downto 15 * lane + 6)));
    end;

    function to_q428(w : std_logic_vector) return std_logic_vector is
    begin
        if G_PAYLOAD_BITS = 32 then return w; end if;
        return std_logic_vector(shift_left(resize(signed(w), 32), 5));
    end;

    function from_q428(w : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        if G_PAYLOAD_BITS = 32 then return w; end if;
        if signed(w) >= to_signed(2**28, 32) then return x"7FFFFF"; end if;
        if signed(w) < -to_signed(2**28, 32) then return x"800000"; end if;
        return w(28 downto 5);
    end;
begin
    assert G_IO_FIRST + G_LANES + 1 < SLOT_CLOCKS - BIT_CLOCKS severity failure;
    assert G_PAYLOAD_BITS = 24 or G_PAYLOAD_BITS = 32 severity failure;
    slot <= to_integer(phase) / SLOT_CLOCKS;
    cycle <= to_integer(phase) mod SLOT_CLOCKS;
    bitpos <= cycle / BIT_CLOCKS;

    process (all)
        variable prev_slot, next_slot, lane : natural;
    begin
        rx_we <= '0'; tx_req <= '0';
        rx_addr <= (others => '0'); tx_addr <= (others => '0');
        rx_sample <= (others => '0');
        if cycle >= G_IO_FIRST and cycle < G_IO_FIRST + G_LANES and rst = '0' then
            lane := cycle - G_IO_FIRST;
            prev_slot := (slot + G_SLOTS - 1) mod G_SLOTS;
            next_slot := (slot + 1) mod G_SLOTS;
            if prev_slot < used(G_RX_USED, lane) then
                rx_we <= '1';
                rx_addr <= to_unsigned(first(G_RX_USED, lane) + prev_slot, 9);
                rx_sample <= to_q428(in_words(lane));
            end if;
            if next_slot < used(G_TX_USED, lane) then
                tx_req <= '1';
                tx_addr <= to_unsigned(first(G_TX_USED, lane) + next_slot, 9);
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                in_words <= (others => (others => '0'));
                out_words <= (others => (others => '0'));
                out_shift <= (others => (others => '0'));
                req_d <= '0';
            else
                req_d <= '0';
                if cycle >= G_IO_FIRST and cycle < G_IO_FIRST + G_LANES then
                    lane_d <= cycle - G_IO_FIRST;
                    req_d <= '1';
                    used_d <= tx_req and tx_valid;
                end if;
                if req_d = '1' then
                    if used_d = '1' then out_words(lane_d) <= from_q428(tx_sample);
                    else out_words(lane_d) <= (others => '0'); end if;
                end if;
                if cycle mod BIT_CLOCKS = BIT_CLOCKS - 1 then
                    for i in 0 to G_LANES - 1 loop
                        if bitpos < G_PAYLOAD_BITS then
                            in_shift(i) <= in_shift(i)(G_PAYLOAD_BITS - 2 downto 0) & lane_in(i);
                        end if;
                        if bitpos = G_PAYLOAD_BITS - 1 then
                            if lane_valid(i) = '1' then
                                in_words(i) <= in_shift(i)(G_PAYLOAD_BITS - 2 downto 0) & lane_in(i);
                            else in_words(i) <= (others => '0'); end if;
                        end if;
                    end loop;
                end if;
                if cycle mod BIT_CLOCKS = BIT_CLOCKS / 2 - 1 then
                    for i in 0 to G_LANES - 1 loop
                        if bitpos = first_tx_bit then
                            if lane_tx_enable(i) = '1' then out_shift(i) <= out_words(i);
                            else out_shift(i) <= (others => '0'); end if;
                        else out_shift(i) <= out_shift(i)(G_PAYLOAD_BITS - 2 downto 0) & '0'; end if;
                    end loop;
                end if;
            end if;
        end if;
    end process;

    gen_out : for i in lane_out'range generate
        lane_out(i) <= out_shift(i)(G_PAYLOAD_BITS - 1);
    end generate;
end architecture;
