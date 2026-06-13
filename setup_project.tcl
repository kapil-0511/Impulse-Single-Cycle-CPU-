# setup_project.tcl — Create Vivado project for ARIA-32
#
# Usage (Vivado Tcl console):
#   source {C:/Users/kapily/Downloads/aria32/vivado/setup_project.tcl}
#
# RTL and TB files are discovered automatically via glob — no need to edit
# this file when adding new .sv/.v files to rtl/ or tb/ directories.
#
# Change PART to match your FPGA:
#   xc7a35tcpg236-1   — Arty A7-35
#   xc7a100tcsg324-1  — Arty A7-100
#   xc7z020clg484-1   — Zynq-7020 (ZedBoard / PYNQ)
#   xc7k325tffg900-2  — Kintex-7

set PART      xc7a35tcpg236-1
set PROJ_DIR  C:/Users/kapily/Downloads/aria32/vivado/project
set PROJ_NAME aria32
set RTL_DIR   C:/Users/kapily/Downloads/aria32/rtl
set TB_DIR    C:/Users/kapily/Downloads/aria32/tb

# ============================================================================
# 1. Create project
# ============================================================================
create_project $PROJ_NAME $PROJ_DIR -part $PART -force
set_property target_language    Verilog [current_project]
set_property simulator_language Mixed   [current_project]

# ============================================================================
# 2. RTL sources → sources_1
#    Glob all .v files, exclude defines.v (header — resolved via include_dirs)
# ============================================================================
set rtl_files [glob -nocomplain -directory $RTL_DIR *.v]
set rtl_files [lsearch -all -inline -not $rtl_files *defines.v]

if {[llength $rtl_files] == 0} {
    error "No RTL .v files found in $RTL_DIR"
}
add_files -fileset sources_1 -norecurse $rtl_files
set_property include_dirs $RTL_DIR [get_filesets sources_1]
update_compile_order -fileset sources_1
set_property top cpu_top [get_filesets sources_1]

puts "  RTL files added ([llength $rtl_files]):"
foreach f $rtl_files { puts "    [file tail $f]" }

# ============================================================================
# 3. Simulation sources → sim_1
#    Glob all tb_*.sv files — any new testbench is picked up automatically
# ============================================================================
set_property include_dirs $RTL_DIR [get_filesets sim_1]

set tb_files [glob -nocomplain -directory $TB_DIR tb_*.sv]

if {[llength $tb_files] == 0} {
    error "No tb_*.sv files found in $TB_DIR"
}
add_files -fileset sim_1 -norecurse $tb_files

update_compile_order -fileset sim_1

# Set top AFTER update_compile_order
set_property top     tb_cpu [get_filesets sim_1]
set_property top_lib work   [get_filesets sim_1]

set_property -name {xsim.elaborate.xelab.more_options} \
             -value {-debug all} -objects [get_filesets sim_1]

puts "  TB files added ([llength $tb_files]):"
foreach f $tb_files { puts "    [file tail $f]" }

# ============================================================================
# 4. Safety check — ensure no TB leaked into sources_1
# ============================================================================
foreach tb_file [get_files -of_objects [get_filesets sim_1]] {
    set matched [get_files -of_objects [get_filesets sources_1] -quiet $tb_file]
    if {$matched ne ""} {
        puts "WARNING: [file tail $tb_file] found in sources_1 — removing"
        remove_files -fileset sources_1 $matched
    }
}

# ============================================================================
# 5. Report
# ============================================================================
puts ""
puts "========================================================"
puts "  Project  : $PROJ_DIR/$PROJ_NAME.xpr"
puts "  Syn top  : [get_property top [get_filesets sources_1]]"
puts "  Sim top  : [get_property top [get_filesets sim_1]]"
puts ""
puts "  All TBs in sim_1:"
foreach f [get_files -of_objects [get_filesets sim_1]] {
    puts "    [file tail $f]"
}
puts ""
puts "  Switch top:  set_property top <tb_name> \[get_filesets sim_1\]"
puts "  Reload files (open project): source refresh_sim.tcl"
puts "========================================================"
