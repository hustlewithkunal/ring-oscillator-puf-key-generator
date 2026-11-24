# Build the PUF characterisation bitstream in the RTL_Project_Vivado project.
#
# Run from the project root:
#   vivado -mode batch -nojournal -nolog -source scripts/build_char.tcl
# Output: build/top_char.bit, build/top_char.ltx (VIO probes), reports in docs/reports/char/

set root [file normalize [file dirname [info script]]/..]
cd $root
# open the project, or create it on a fresh system; other Vivado versions are
# handled in vivado_compat.tcl (separate project, VIO version of the installed tool)
source $root/scripts/vivado_compat.tcl
compat_open_project

proc add_if_missing {fileset files} {
    foreach f $files {
        set f [file normalize $f]
        if {[llength [get_files -quiet -of_objects [get_filesets $fileset] $f]] == 0} {
            add_files -norecurse -fileset $fileset $f
        }
    }
}

# ---- sources (referenced in place, so they stay under version control)
add_if_missing sources_1 {
    rtl/puf/ro_cell.v rtl/puf/ro_array.v rtl/puf/puf_measure.v rtl/puf/heater.v
    rtl/top/top_char.v
}
add_if_missing constrs_1 {constraints/zybo_z7_10.xdc constraints/puf_placement.xdc}
# fixed RO routing (scripts/export_puf_routes.tcl): identical RO loops in every build
if {[file exists constraints/puf_routes.xdc]} { add_if_missing constrs_1 {constraints/puf_routes.xdc} }
# the SoC-only pins (switches, buttons) do not exist in top_char
foreach f [get_files -quiet *zybo_soc_io.xdc] { set_property is_enabled false $f }

# ---- VIO core for JTAG control (created once, reconfigured on every build)
compat_vio vio_char
set_property -dict [list \
        CONFIG.C_NUM_PROBE_IN {7}  CONFIG.C_NUM_PROBE_OUT {11} CONFIG.C_EN_PROBE_IN_ACTIVITY {0} \
        CONFIG.C_PROBE_IN0_WIDTH {128} CONFIG.C_PROBE_IN1_WIDTH {1}   CONFIG.C_PROBE_IN2_WIDTH {16} \
        CONFIG.C_PROBE_IN3_WIDTH {20}  CONFIG.C_PROBE_IN4_WIDTH {20}  CONFIG.C_PROBE_IN5_WIDTH {192} \
        CONFIG.C_PROBE_IN6_WIDTH {192} \
        CONFIG.C_PROBE_OUT0_WIDTH {1} CONFIG.C_PROBE_OUT1_WIDTH {1} CONFIG.C_PROBE_OUT2_WIDTH {1} \
        CONFIG.C_PROBE_OUT3_WIDTH {2} CONFIG.C_PROBE_OUT4_WIDTH {4} CONFIG.C_PROBE_OUT5_WIDTH {3} \
        CONFIG.C_PROBE_OUT6_WIDTH {2} CONFIG.C_PROBE_OUT7_WIDTH {7} CONFIG.C_PROBE_OUT8_WIDTH {1} \
        CONFIG.C_PROBE_OUT9_WIDTH {192} CONFIG.C_PROBE_OUT10_WIDTH {192} \
        CONFIG.C_PROBE_OUT0_INIT_VAL {0x1} CONFIG.C_PROBE_OUT4_INIT_VAL {0xD} \
    ] [get_ips vio_char]
# regenerate the core and its out-of-context synthesis so a changed configuration is used
reset_target all [get_files vio_char.xci]
generate_target all [get_files vio_char.xci]
if {[llength [get_runs -quiet vio_char_synth_1]] > 0} { reset_run vio_char_synth_1 }

set_property top top_char [current_fileset]
update_compile_order -fileset sources_1

# ---- synthesis, implementation, bitstream
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }

# ---- collect outputs and reports
set rundir [get_property DIRECTORY [get_runs impl_1]]
file mkdir build docs/reports/char
file copy -force $rundir/top_char.bit build/top_char.bit
file copy -force $rundir/top_char.ltx build/top_char.ltx

open_run impl_1
report_utilization    -file docs/reports/char/utilization.rpt
report_timing_summary -file docs/reports/char/timing.rpt
report_drc            -file docs/reports/char/drc.rpt
report_power          -file docs/reports/char/power.rpt
set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -setup] 0]]
set util [report_utilization -return_string]
regexp {Slice LUTs\s*\|\s*(\d+)} $util -> luts
regexp {Slice Registers\s*\|\s*(\d+)} $util -> ffs
puts "BUILD_OK top_char LUTs=$luts FFs=$ffs WNS=$wns"
close_project
