# Key session on the board (top_soc bitstream): enrol, reconstruct and record everything
# the host needs to recompute the key with the golden model (scripts/show_key.py).
#   vivado -mode batch -nojournal -nolog -source scripts/hw/soc_key.tcl -tclargs <base|cfg>
#
# The key itself never leaves the FPGA: there is no command that reads it. What the host
# does know is the enrolment secret it chose (the BCH messages) and the public helper
# data. From these the golden model recomputes the PUF response and the key, and the
# FPGA's own KCV and MAC tags prove that the key inside the chip is that same key.
#
# Steps (device 0 = RO array selected by the firmware, SW1:SW0 are not used):
#   1. ENROL with host-chosen messages        -> helper data (offset, KCV, configuration)
#   2. ENROL again                            -> must be refused (one-time lock)
#   3. RECONSTRUCT, 4 challenges              -> MAC tags of the key in the chip
#   4. SoC reset (key and RAM lost), restore the helper data, RECONSTRUCT, same 4
#      challenges                             -> tags must be identical (same key)
#   5. RECONSTRUCT on device 1 and device 2   -> must not give a valid key
# The record is written to <PUF_OUT_DIR or data/hw_soc>/key_<mode>.txt.

set root [file normalize [file dirname [info script]]/../..]
source $root/scripts/hw/puf_host.tcl
source $root/scripts/hw/soc_host.tcl

set mode [lindex $argv 0]
if {$mode ni {base cfg}} { error "mode must be base or cfg" }
set flags [expr {$mode eq "cfg" ? 1 : 0}]
set out [expr {[info exists env(PUF_OUT_DIR)] && $env(PUF_OUT_DIR) ne "" ? [file normalize $env(PUF_OUT_DIR)] : "$root/data/hw_soc"}]
file mkdir $out
set rec [open $out/key_$mode.txt w]
fconfigure $rec -translation lf
proc put {key args} { global rec; puts $rec "$key [join $args " "]"; flush $rec }
proc hx {words} { return [join [lmap w $words {format %08x [expr {$w & 0xFFFFFFFF}]}] " "] }
proc rnd32 {} { return [expr {int(rand() * 4294967296.0) & 0xFFFFFFFF}] }
expr {srand([clock milliseconds])}

if {![file exists $root/build/top_soc.bit] || ![file exists $root/build/top_soc.ltx]} {
    error "build/top_soc.bit or .ltx not found: run scripts/build_soc.tcl first"
}
hw_connect $root/build/top_soc.bit $root/build/top_soc.ltx
set_property OUTPUT_VALUE_RADIX HEX [probe h2d_seq]
soc_reset

put mode $mode
put temperature_c [temperature]
lassign [soc_cmd 1] st data
put ping [hx [lrange $data 0 1]]
lassign [soc_cmd 7] st data
put switches [format %x [expr {[lindex $data 0] & 0xF}]]
put status_after_reset [format %08x $st]

# 1. enrolment with host-chosen BCH messages (block i at bits [7i+6:7i])
set msg0 [rnd32]
set msg1 [expr {[rnd32] & 0xFFFFFF}]
put messages [hx [list $msg0 $msg1]]
lassign [soc_cmd 2 [list $msg0 $msg1 $flags 0]] st data
set helper [lrange $data 0 16]
put enrol_status [format %08x $st]
put helper [hx $helper]

# 2. second enrolment must be refused
lassign [soc_cmd 2 [list 1 2 $flags 0]] st data
put enrol_again_status [format %08x $st]

# 3. reconstruction and challenge-response
set chals {}
for {set k 0} {$k < 4} {incr k} { lappend chals [list [rnd32] [rnd32]] }
lassign [soc_cmd 4 [list 0]] st data
put recon_status [format %08x $st]
foreach c $chals {
    lassign [soc_cmd 5 $c] st data
    put tag [hx $c] [hx [lrange $data 0 1]]
}

# 4. power-up in the field: everything in the SoC is lost, the helper data is restored
soc_reset
lassign [soc_cmd 7] st data
put field_status_after_reset [format %08x $st]
lassign [soc_cmd 3 $helper] st data
lassign [soc_cmd 4 [list 0]] st data
put field_recon_status [format %08x $st]
foreach c $chals {
    lassign [soc_cmd 5 $c] st data
    put field_tag [hx $c] [hx [lrange $data 0 1]]
}

# 5. the same helper data on the other two RO arrays (other "chips")
foreach dev {1 2} {
    lassign [soc_cmd 4 [list $dev]] st data
    put other_device $dev [format %08x $st]
    lassign [soc_cmd 5 [lindex $chals 0]] st data
    put other_device_tag $dev [hx [lindex $chals 0]] [hx [lrange $data 0 1]]
}
put temperature_end_c [temperature]
close $rec
puts "KEY_SESSION_DONE $out/key_$mode.txt"
close_hw_target
