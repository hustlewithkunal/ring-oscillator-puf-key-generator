# Check that a configuration vector read from the design (SELECT result) and loaded
# back by the host behaves exactly like the original, and that the probe halves are
# in the right order (a swapped load must give a different response).
#   vivado -mode batch -nojournal -nolog -source scripts/hw/char_cfg_check.tcl

set root [file normalize [file dirname [info script]]/../..]
source $root/scripts/hw/puf_host.tcl
hw_connect $root/build/top_char.bit $root/build/top_char.ltx
puf_reset

proc hd {a b} {
    set d 0
    for {set i 0} {$i < 32} {incr i} {
        set x [expr "0x[string index $a $i] ^ 0x[string index $b $i]"]
        while {$x} { incr d [expr {$x & 1}]; set x [expr {$x >> 1}] }
    }
    return $d
}

puf_run 1 0 13 0 0
# read the SELECT result by VIO port (probe_in6 = bits 383:192, probe_in5 = 191:0):
# probe names of bus slices are not in port order, so never select them by name
refresh_hw_vio [vio]
set cfg "[padhex [vget_port_hex cfg_best 6] 48][padhex [vget_port_hex cfg_best 5] 48]"
puts "CFG $cfg"
set r_internal [padhex [puf_response 0 13 1 0] 32]
load_cfg $cfg
set r_loaded   [padhex [puf_response 0 13 2 0] 32]
load_cfg "[string range $cfg 48 95][string range $cfg 0 47]"
set r_swapped  [padhex [puf_response 0 13 2 0] 32]
set r_base     [padhex [puf_response 0 13 0 0] 32]
puts "CHECK internal vs loaded : [hd $r_internal $r_loaded] bits differ (expect ~0)"
puts "CHECK internal vs swapped: [hd $r_internal $r_swapped] bits differ (expect clearly > 0)"
puts "CHECK selected vs baseline: [hd $r_internal $r_base] bits differ"
close_hw_target
