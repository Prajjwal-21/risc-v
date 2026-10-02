// =============================================================================
// dcache_cov  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : Functional coverage of the D-cache's corner cases (docs/
//              architecture.md P4, P7.3), as SVA cover points bound into every
//              dcache instance (bind below). Counted like core_cov.
// Interfaces : the cache's own signals, connected by name (.*). The state enum
//              arrives as its 2-bit encoding (S_RUN = 0, S_MISS = 1, S_UNC = 2,
//              S_REPLAY = 3).
// Note       : a request accepted during a missing lookup (replay) is not a
//              cover point: the core never issues one then (its MEM stage waits
//              for the response), so it is unreachable in this SoC.
// =============================================================================
module dcache_cov (
  input logic       clk_i,
  input logic       rst_ni,
  input logic [1:0] state_q,
  input logic       ld_hit, ld_miss, st_hit, st_cache, unc, wb_idle, wb_full, started_q, req_valid_i,
  input logic       unc_done, lk_valid_q
);
  cp_dc_ld_hit:          cover property (@(posedge clk_i) disable iff (!rst_ni) ld_hit);
  cp_dc_ld_miss:         cover property (@(posedge clk_i) disable iff (!rst_ni) ld_miss);
  cp_dc_st_hit:          cover property (@(posedge clk_i) disable iff (!rst_ni) st_hit);
  cp_dc_st_miss:         cover property (@(posedge clk_i) disable iff (!rst_ni) st_cache && !st_hit);
  cp_dc_uncached:        cover property (@(posedge clk_i) disable iff (!rst_ni) unc);
  cp_dc_miss_waits_wb:   cover property (@(posedge clk_i) disable iff (!rst_ni)
                                         state_q == 2'd1 && !wb_idle && !started_q);
  cp_dc_unc_waits_wb:    cover property (@(posedge clk_i) disable iff (!rst_ni)
                                         state_q == 2'd2 && !wb_idle && !started_q);
  cp_dc_wb_full:         cover property (@(posedge clk_i) disable iff (!rst_ni)
                                         state_q == 2'd0 && req_valid_i && wb_full);
  cp_dc_back_to_back_hit:cover property (@(posedge clk_i) disable iff (!rst_ni)
                                         ld_hit && lk_valid_q && req_valid_i);
  cp_dc_unc_done:        cover property (@(posedge clk_i) disable iff (!rst_ni) unc_done);
endmodule : dcache_cov

bind dcache dcache_cov u_dcache_cov (.*);
