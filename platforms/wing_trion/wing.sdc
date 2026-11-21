create_clock -name audio -period 20.345052 [get_ports clk_audio]
# Asynchronous buffered SPI and forwarded DSP debug port.
set_false_path -from [get_ports {host_sck host_mosi dsp_cs_n ctrl_cs_n dsp*_dpi_miso}]
set_false_path -to [get_ports {host_miso_out host_miso_oe dsp*_dpi_sck dsp*_dpi_sel dsp*_dpi_mosi}]
