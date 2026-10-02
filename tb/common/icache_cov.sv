// =============================================================================
// icache_cov  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : Functional coverage of the I-cache's corner cases (docs/
//              architecture.md P4, P7.3), as SVA cover points bound into every
//              icache instance (bind below). Counted like core_cov.
// Interfaces : the cache's own signals, connected by name (.*). The state enum
//              arrives as its 2-bit encoding (S_RUN = 0, S_MISS = 1,
//              S_REPLAY = 2).
// =============================================================================
module icache_cov (
  input logic       clk_i,
  input logic       rst_ni,
  input logic [1:0] state_q,
  input logic       hit, miss, accept, flush_i, sync_q, started_q
);
  cp_ic_hit:                cover property (@(posedge clk_i) disable iff (!rst_ni) hit);
  cp_ic_miss:               cover property (@(posedge clk_i) disable iff (!rst_ni) miss);
  cp_ic_accept_during_miss: cover property (@(posedge clk_i) disable iff (!rst_ni) miss && accept);
  cp_ic_replay:             cover property (@(posedge clk_i) disable iff (!rst_ni) state_q == 2'd2);
  cp_ic_flush_during_refill:cover property (@(posedge clk_i) disable iff (!rst_ni) flush_i && state_q == 2'd1);
  cp_ic_refill_waits_sync:  cover property (@(posedge clk_i) disable iff (!rst_ni)
                                            state_q == 2'd1 && sync_q && !started_q);
endmodule : icache_cov

bind icache icache_cov u_icache_cov (.*);
