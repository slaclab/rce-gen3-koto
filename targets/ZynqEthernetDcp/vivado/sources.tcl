set VIVADO_BUILD_DIR $::env(VIVADO_BUILD_DIR)
source -quiet ${VIVADO_BUILD_DIR}/vivado_env_var_v1.tcl
source -quiet ${VIVADO_BUILD_DIR}/vivado_proc_v1.tcl

## Set the top level file
set_property top zynq_gige_block [current_fileset]

## Set the Secure IP library 
set_property library gig_ethernet_pcs_pma_v14_3 [get_files ${PROJ_DIR}/hdl/gig_ethernet_pcs_pma_v14_3_rfs.vhd]

