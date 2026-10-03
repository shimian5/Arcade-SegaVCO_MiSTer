# Focused post-fit timing-path extraction for the playercar-v2 review.
# Run from the project worktree with Quartus Prime 17.0:
#   quartus_sta -t tools/timequest_playercar_paths.tcl

project_open Arcade-SegaVCO
create_timing_netlist -model slow
read_sdc
update_timing_netlist

report_timing -setup -npaths 20 -detail full_path \
    -panel_name "Worst Setup Paths (20)" \
    -file "output_files/playercar_worst_setup_paths.rpt"
report_timing -hold -npaths 10 -detail full_path \
    -panel_name "Worst Hold Paths (10)" \
    -file "output_files/playercar_worst_hold_paths.rpt"
report_timing -setup -from_clock {emu*} -to_clock {emu*} -npaths 20 \
    -detail full_path -panel_name "emu Setup Paths (20)" \
    -file "output_files/playercar_emu_setup_paths.rpt"

project_close
