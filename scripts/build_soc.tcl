# Build the secure SoC bitstream (top_soc) in the RTL_Project_Vivado project.
# Assemble the firmware first:  python sw/rvasm.py sw/firmware.S sw/firmware.mem
#
# Run from the project root:
#   vivado -mode batch -nojournal -nolog -source scripts/build_soc.tcl
# Output: build/top_soc.bit, build/top_soc.ltx, reports in docs/reports/soc/

set root [file normalize [file dirname [info script]]/..]
cd $root
# open the project, or create it on a fresh system (only the part is needed)
if {[file exists RTL_Project_Vivado/RTL_Project_Vivado.xpr]} {
    open_project RTL_Project_Vivado/RTL_Project_Vivado.xpr
} else {
    create_project RTL_Project_Vivado RTL_Project_Vivado -part xc7z010clg400-1
}

proc add_if_missing {fileset files} {
    foreach f $files {
        set f [file normalize $f]
        if {[llength [get_files -quiet -of_objects [get_filesets $fileset] $f]] == 0} {
            add_files -norecurse -fileset $fileset $f
        }
    }
}

add_if_missing sources_1 {
    rtl/puf/ro_cell.v rtl/puf/ro_array.v rtl/puf/puf_measure.v
    rtl/gf/gf16_mul_sop.v rtl/gf/gf16_mul_xor.v rtl/gf/gf16_inv_sop.v rtl/gf/gf16_mul.v
    rtl/ecc/bch_syndrome.v rtl/ecc/bch_chien_x.v rtl/ecc/bch_dec_2mul.v
    rtl/ecc/bch_enc.v rtl/ecc/rep_codec.v
    rtl/crypto/siphash24.v rtl/fe/fuzzy_extractor.v
    rtl/soc/rv32_core.v rtl/soc/soc_ram.v rtl/soc/soc.v rtl/top/top_soc.v
    sw/firmware.mem
}
add_if_missing constrs_1 {constraints/zybo_z7_10.xdc constraints/puf_placement.xdc constraints/zybo_soc_io.xdc}
# fixed RO routing (scripts/export_puf_routes.tcl): identical RO loops in every build
if {[file exists constraints/puf_routes.xdc]} { add_if_missing constrs_1 {constraints/puf_routes.xdc} }
set_property is_enabled true [get_files [file normalize constraints/zybo_soc_io.xdc]]

if {[llength [get_ips -quiet vio_soc]] == 0} {
    create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name vio_soc
}
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN {6} CONFIG.C_NUM_PROBE_OUT {6} CONFIG.C_EN_PROBE_IN_ACTIVITY {0} \
    CONFIG.C_PROBE_IN0_WIDTH {8}   CONFIG.C_PROBE_IN1_WIDTH {32}  CONFIG.C_PROBE_IN2_WIDTH {256} \
    CONFIG.C_PROBE_IN3_WIDTH {256} CONFIG.C_PROBE_IN4_WIDTH {256} CONFIG.C_PROBE_IN5_WIDTH {6} \
    CONFIG.C_PROBE_OUT0_WIDTH {8}  CONFIG.C_PROBE_OUT1_WIDTH {8}  CONFIG.C_PROBE_OUT2_WIDTH {256} \
    CONFIG.C_PROBE_OUT3_WIDTH {256} CONFIG.C_PROBE_OUT4_WIDTH {256} CONFIG.C_PROBE_OUT5_WIDTH {1} \
] [get_ips vio_soc]
reset_target all [get_files vio_soc.xci]
generate_target all [get_files vio_soc.xci]
if {[llength [get_runs -quiet vio_soc_synth_1]] > 0} { reset_run vio_soc_synth_1 }

set_property top top_soc [current_fileset]
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }

set rundir [get_property DIRECTORY [get_runs impl_1]]
file mkdir build docs/reports/soc
file copy -force $rundir/top_soc.bit build/top_soc.bit
file copy -force $rundir/top_soc.ltx build/top_soc.ltx

open_run impl_1
report_utilization    -file docs/reports/soc/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file docs/reports/soc/utilization_hier.rpt
report_timing_summary -file docs/reports/soc/timing.rpt
report_drc            -file docs/reports/soc/drc.rpt
report_power          -file docs/reports/soc/power.rpt
set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -setup] 0]]
set util [report_utilization -return_string]
regexp {Slice LUTs\s*\|\s*(\d+)} $util -> luts
regexp {Slice Registers\s*\|\s*(\d+)} $util -> ffs
puts "BUILD_OK top_soc LUTs=$luts FFs=$ffs WNS=$wns"
close_project
