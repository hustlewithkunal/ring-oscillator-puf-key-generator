# Mailbox diagnostics for top_soc: raw sequence numbers, status and data around commands.
#   vivado -mode batch -nojournal -nolog -source scripts/hw/soc_debug.tcl -tclargs [bitname]
set root [file normalize [file dirname [info script]]/../..]
source $root/scripts/hw/puf_host.tcl
source $root/scripts/hw/soc_host.tcl
set bit [expr {[llength $argv] > 0 ? [lindex $argv 0] : "top_soc"}]
hw_connect $root/build/$bit.bit $root/build/$bit.ltx

proc snap {tag} {
    refresh_hw_vio [vio]
    puts "DBG $tag: h2d_seq=[get_property OUTPUT_VALUE [probe h2d_seq]] (radix [get_property OUTPUT_VALUE_RADIX [probe h2d_seq]]) d2h_seq=[vget_hex d2h_seq] status=[vget_hex d2h_status] data0=[string range [vget_hex d2h_data] end-7 end] trap=[vget_hex trap] key_valid=[vget_hex key_valid] leds=[vget_hex led_OBUF]"
}
puts "DBG probes: [get_hw_probes -of_objects [vio]]"
snap "after program"
soc_reset
snap "after reset"
foreach cmd {1 7 1} {
    lassign [soc_cmd $cmd] st data
    puts "DBG cmd $cmd -> status [format %08x $st] data0 [format %08x [lindex $data 0]] data1 [format %08x [lindex $data 1]]"
    snap "after cmd $cmd"
}
close_hw_target
