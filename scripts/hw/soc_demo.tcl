# Project demo on the board (top_soc bitstream): challenge-response authentication.
#   vivado -mode batch -nojournal -nolog -source scripts/hw/soc_demo.tcl -tclargs <base|cfg> [N]
#     base = baseline RO-PUF, cfg = configurable RO-PUF (research enhancement)
#     N    = number of field reconstructions for the reliability count (default 100)
#     an optional third argument names the bitstream in build/ (default top_soc)
#
# 1. link test (ECHO of 24 words) and PING
# 2. FACTORY: enrol device 0 -> helper data saved to data/hw_soc/helper_<mode>.txt;
#    a second enrolment must be refused (lock); reconstruct once and record a table of
#    challenge-response pairs (the verifier's database)
# 3. FIELD: reset the SoC (RAM and key are lost), the host restores the helper data,
#    reconstruct, answer unused challenges -> must match the table: AUTHENTICATED
# 4. IMPOSTOR: the same helper data on device 1 and device 2 -> must be REJECTED
# 5. RELIABILITY: N reconstructions on device 0, each checked with a known challenge
#    -> key-failure rate after ECC measured on the chip
# Everything is logged to data/hw_soc/demo_<mode>.txt, or to the folder named by the
# environment variable PUF_OUT_DIR when it is set (used by the .bat launchers, so the
# results shipped in data/hw_soc are not overwritten).

set root [file normalize [file dirname [info script]]/../..]
source $root/scripts/hw/puf_host.tcl
source $root/scripts/hw/soc_host.tcl

set mode [lindex $argv 0]
set nrel [expr {[llength $argv] > 1 ? [lindex $argv 1] : 100}]
set bit  [expr {[llength $argv] > 2 ? [lindex $argv 2] : "top_soc"}]
if {$mode ni {base cfg}} { error "mode must be base or cfg" }
set flags [expr {$mode eq "cfg" ? 1 : 0}]

set out [expr {[info exists env(PUF_OUT_DIR)] && $env(PUF_OUT_DIR) ne "" ? [file normalize $env(PUF_OUT_DIR)] : "$root/data/hw_soc"}]
file mkdir $out
set log [open $out/demo_$mode.txt w]
fconfigure $log -translation lf
proc say {msg} { global log; puts "DEMO $msg"; puts $log $msg; flush $log }
proc rnd32 {} { return [expr {int(rand() * 4294967296.0) & 0xFFFFFFFF}] }
expr {srand([clock milliseconds])}

if {![file exists $root/build/$bit.bit] || ![file exists $root/build/$bit.ltx]} {
    error "build/$bit.bit or .ltx not found: run scripts/build_soc.tcl first"
}
hw_connect $root/build/$bit.bit $root/build/$bit.ltx
set_property OUTPUT_VALUE_RADIX HEX [probe h2d_seq]
soc_reset
say "mode $mode, die temperature [temperature] C"

# ---------------------------------------------------------------- 1. link test
set words {}
for {set k 0} {$k < 24} {incr k} { lappend words [expr {(0x01010101 * ($k + 1)) ^ 0xA5000000}] }
lassign [soc_cmd 8 $words] st data
set echo_ok [expr {$data eq $words}]
lassign [soc_cmd 1] st data
say "LINK: echo of 24 words [expr {$echo_ok ? "OK" : "FAILED"}]; PING [format %08x [lindex $data 0]] version [format %08x [lindex $data 1]]"
if {!$echo_ok} { error "mailbox link test failed" }

# ---------------------------------------------------------------- 2. factory
set msg0 [rnd32]
set msg1 [expr {[rnd32] & 0xFFFFFF}]
lassign [soc_cmd 2 [list $msg0 $msg1 $flags 0]] st data
set helper [lrange $data 0 16]
say "ENROL device 0: [st_text $st]"
set f [open $out/helper_$mode.txt w]
fconfigure $f -translation lf
puts $f [join [lmap w $helper {format %08x $w}] " "]
close $f
say "  helper data (offset, kcv, configuration): [join [lmap w $helper {format %08x $w}] " "]"

lassign [soc_cmd 2 [list 1 2 $flags 0]] st2 data2
say "ENROL again: [st_text $st2] -> [expr {[st_bit $st2 2] ? "REFUSED (locked)" : "ACCEPTED (lock FAILED)"}]"

lassign [soc_cmd 4 [list 0]] st data
say "RECONSTRUCT device 0 (factory): [st_text $st]"
set crp {}
for {set k 0} {$k < 8} {incr k} {
    set c [list [rnd32] [rnd32]]
    lassign [soc_cmd 5 $c] st data
    lappend crp [list $c [lrange $data 0 1]]
}
say "  recorded 8 challenge-response pairs"

# ---------------------------------------------------------------- 3. field
soc_reset
lassign [soc_cmd 7] st data
say "FIELD: SoC reset (switches [format %x [lindex $data 0]]); key_valid after reset = [st_bit $st 4]"
lassign [soc_cmd 3 $helper] st data
lassign [soc_cmd 4 [list 0]] st data
say "RECONSTRUCT device 0 with restored helper data: [st_text $st]"
set match 0
foreach entry [lrange $crp 4 7] {
    lassign $entry c t
    lassign [soc_cmd 5 $c] st data
    if {[lrange $data 0 1] eq $t} { incr match }
}
say "AUTH device 0: $match/4 unused challenges answered correctly -> [expr {$match == 4 ? "AUTHENTICATED" : "FAILED"}]"

# ---------------------------------------------------------------- 4. impostor
foreach dev {1 2} {
    lassign [soc_cmd 4 [list $dev]] st data
    set rst_txt [st_text $st]
    lassign [lindex $crp 4] c t
    lassign [soc_cmd 5 $c] st data
    set ok [expr {[lrange $data 0 1] eq $t}]
    say "IMPOSTOR device $dev: reconstruct $rst_txt; AUTH [expr {$ok ? "ACCEPTED (!)" : "REJECTED"}]"
}

# ---------------------------------------------------------------- 5. reliability
set valid 0
set tag_ok 0
lassign [lindex $crp 0] c0 t0
for {set k 0} {$k < $nrel} {incr k} {
    lassign [soc_cmd 4 [list 0]] st data
    if {[st_bit $st 4]} {
        incr valid
        lassign [soc_cmd 5 $c0] st data
        if {[lrange $data 0 1] eq $t0} { incr tag_ok }
    }
}
say "RELIABILITY: $valid/$nrel reconstructions gave a valid key, $tag_ok/$nrel answered the reference challenge correctly; die temperature [temperature] C"
close $log
close_hw_target
