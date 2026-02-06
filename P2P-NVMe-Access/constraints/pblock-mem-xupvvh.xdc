create_pblock memory_pblock
add_cells_to_pblock [get_pblocks memory_pblock] [get_cells -quiet [list system_i/memory/dma]]
resize_pblock [get_pblocks memory_pblock] -add {SLR2}
