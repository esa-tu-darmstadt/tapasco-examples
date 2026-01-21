create_pblock memory_pblock
add_cells_to_pblock [get_pblocks memory_pblock] [get_cells -quiet [list system_i/arch/target_ip_00_000 system_i/memory/dma system_i/memory/mig]]
resize_pblock [get_pblocks memory_pblock] -add {SLR1}
