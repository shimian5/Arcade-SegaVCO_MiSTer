project_open Arcade-SegaVCO
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 2 -detail path_only -panel_name "worst" -file output_files/worst_setup_now.rpt
project_close