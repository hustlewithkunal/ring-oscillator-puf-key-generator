# Zybo Z7-10 pins used by the project (from the Digilent Zybo Z7 master XDC).

# 125 MHz clock (from the Ethernet PHY), pin K17
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports sysclk]
create_clock -name sys_clk -period 8.000 -waveform {0 4} [get_ports sysclk]

# user LEDs LD0..LD3
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
