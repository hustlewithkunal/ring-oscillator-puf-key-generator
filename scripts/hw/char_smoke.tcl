# Smoke test of the characterisation bitstream on the board:
# program, list VIO probes, read temperature, measure each array twice, show some counts.
#   vivado -mode batch -nojournal -nolog -source scripts/hw/char_smoke.tcl

set root [file normalize [file dirname [info script]]/../..]
source $root/scripts/hw/puf_host.tcl

hw_connect $root/build/top_char.bit $root/build/top_char.ltx
puts "PROBES: [get_hw_probes -of_objects [vio]]"
puts "TEMP: [temperature] C"
puf_reset

foreach arr {0 1 2} {
    set r1 [puf_response $arr]
    set r2 [puf_response $arr]
    puts "ARRAY $arr read1 $r1"
    puts "ARRAY $arr read2 $r2"
}
puf_response 0
vset v_rd_pair 0;  puts "PAIR 0 counts: [vget rd_a UNSIGNED] [vget rd_b UNSIGNED]"
vset v_rd_pair 77; puts "PAIR 77 counts: [vget rd_a UNSIGNED] [vget rd_b UNSIGNED]"
puts "TEMP: [temperature] C"
close_hw_target
