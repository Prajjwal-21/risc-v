// =============================================================================
// icache
// -----------------------------------------------------------------------------
// Purpose    : Instruction cache (docs/architecture.md P4): 2 KB, direct-mapped,
//              16-byte lines, read-only. A miss refills the line with four
//              single-word reads. FENCE.I (flush_i) invalidates every line.
// Interfaces : core side: the core port protocol as a slave (valid/ready
//              request, valid-only in-order response, section 2);
//              memory side: the same protocol as a master;
//              flush_i: one-cycle pulse when FENCE.I commits (core fence_i_o);
//              sync_ok_i: the D-cache write buffer is idle (dcache wb_idle_o).
// Timing     : * hit: response one cycle after acceptance; one request per
//                cycle. rsp_valid_o depends only on registered state and the
//                SRAM outputs, never on the request (protocol rule 3).
//              * req_ready_o depends only on registered state (D-045). A
//                request accepted while the previous lookup misses is held in
//                nxt_q and looked up again after the refill (REPLAY).
//              * miss: refill of words 0..3 (several outstanding), then a
//                registered response. After flush_i the next refill waits
//                for sync_ok_i, and a refill in flight is not validated (P4.4).
//              * memory-side requests never depend on mem_req_ready_i and stay
//                stable until accepted (protocol rules 1 and 2).
// =============================================================================
module icache
  import riscv_pkg::*;
#(
  parameter int unsigned CACHE_BYTES = soc_pkg::CACHE_BYTES,
  parameter int unsigned LINE_BYTES  = soc_pkg::CACHE_LINE_BYTES
) (
  input  logic     clk_i,
  // rst_ni is also sampled by the simulation-only assertions (disable iff),
  // which Verilator reports as a synchronous use of an async reset.
  /* verilator lint_off SYNCASYNCNET */
  input  logic     rst_ni,
  /* verilator lint_on SYNCASYNCNET */

  // Core side
  input  logic     req_valid_i,
  output logic     req_ready_o,
  // Only .addr is used: the fetch unit always reads a whole word.
  /* verilator lint_off UNUSEDSIGNAL */
  input  mem_req_t req_i,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic     rsp_valid_o,
  output mem_rsp_t rsp_o,

  // Invalidate (FENCE.I) and the D-side write-buffer sync
  input  logic     flush_i,
  input  logic     sync_ok_i,

  // Memory side
  output logic     mem_req_valid_o,
  input  logic     mem_req_ready_i,
  output mem_req_t mem_req_o,
  input  logic     mem_rsp_valid_i,
  input  mem_rsp_t mem_rsp_i
);

  localparam int unsigned NLINES = CACHE_BYTES / LINE_BYTES;
  localparam int unsigned WORDS  = LINE_BYTES / 4;
  localparam int unsigned IDX_W  = $clog2(NLINES);
  localparam int unsigned WRD_W  = $clog2(WORDS);
  localparam int unsigned OFF_W  = $clog2(LINE_BYTES);
  localparam int unsigned TAG_W  = XLEN - IDX_W - OFF_W;

  typedef logic [IDX_W-1:0] idx_t;
  typedef logic [WRD_W-1:0] wrd_t;
  typedef logic [TAG_W-1:0] tag_t;
  typedef logic [WRD_W:0]   cnt_t;       // 0..WORDS

  // Address field extractors: each uses only its own bits of the address.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic idx_t idx_of(word_t a); return a[OFF_W +: IDX_W]; endfunction
  function automatic wrd_t wrd_of(word_t a); return a[2 +: WRD_W];     endfunction
  function automatic tag_t tag_of(word_t a); return a[XLEN-1 -: TAG_W]; endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  typedef enum logic [1:0] { S_RUN, S_MISS, S_REPLAY } state_e;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  state_e            state_q;
  logic [NLINES-1:0] valid_q;
  logic              lk_valid_q;       // a request is in its lookup cycle
  word_t             lk_addr_q;
  logic              nxt_valid_q;      // accepted during a missing lookup: replay
  word_t             nxt_addr_q;
  word_t             miss_addr_q;      // request being refilled
  cnt_t              req_cnt_q;        // refill words requested
  cnt_t              rsp_cnt_q;        // refill words received
  logic              started_q;        // this refill has asserted its first request
  logic              nofill_q;         // invalidated during the refill
  logic              any_err_q;
  mem_rsp_t          crit_q;           // the requested word, once received
  logic              sync_q;           // after FENCE.I: wait for sync_ok_i
  logic              rsp_valid_q;      // registered response of a refill
  mem_rsp_t          rsp_q;

  // ---------------------------------------------------------------------------
  // Lookup
  // ---------------------------------------------------------------------------
  tag_t  tag_rdata;
  word_t data_rdata;
  logic  accept, hit, miss;

  assign req_ready_o = (state_q == S_RUN);
  assign accept      = req_valid_i && req_ready_o;
  assign hit         = lk_valid_q && valid_q[idx_of(lk_addr_q)] && (tag_rdata == tag_of(lk_addr_q));
  assign miss        = lk_valid_q && !hit;

  assign rsp_valid_o = rsp_valid_q || hit;
  assign rsp_o       = rsp_valid_q ? rsp_q : '{rdata: data_rdata, err: 1'b0};

  // ---------------------------------------------------------------------------
  // Refill
  // ---------------------------------------------------------------------------
  logic     mreq_fire, beat, last_beat, fill_ok;
  mem_rsp_t crit_now;

  assign mem_req_valid_o = (state_q == S_MISS) && (req_cnt_q != cnt_t'(WORDS))
                        && (started_q || !sync_q);
  assign mem_req_o = '{
    addr:  {miss_addr_q[XLEN-1:OFF_W], req_cnt_q[WRD_W-1:0], 2'b00},
    we:    1'b0,
    be:    4'b1111,
    wdata: '0
  };
  assign mreq_fire = mem_req_valid_o && mem_req_ready_i;
  assign beat      = (state_q == S_MISS) && mem_rsp_valid_i;
  assign last_beat = beat && (rsp_cnt_q == cnt_t'(WORDS - 1));
  assign crit_now  = (rsp_cnt_q[WRD_W-1:0] == wrd_of(miss_addr_q)) ? mem_rsp_i : crit_q;
  // Validate only a clean refill that no FENCE.I overlapped.
  assign fill_ok   = !any_err_q && !mem_rsp_i.err && !nofill_q && !flush_i;

  // ---------------------------------------------------------------------------
  // SRAMs. Reads: on acceptance (at the request's index) and in REPLAY. Writes:
  // refill beats (data) and the last beat (tag). They never coincide: ready is
  // 0 in MISS and REPLAY.
  // ---------------------------------------------------------------------------
  logic tag_en, tag_we, data_en, data_we;
  idx_t rd_idx;
  wrd_t rd_wrd;

  assign rd_idx  = (state_q == S_REPLAY) ? idx_of(nxt_addr_q) : idx_of(req_i.addr);
  assign rd_wrd  = (state_q == S_REPLAY) ? wrd_of(nxt_addr_q) : wrd_of(req_i.addr);
  assign tag_we  = last_beat;
  assign tag_en  = accept || (state_q == S_REPLAY) || tag_we;
  assign data_we = beat;
  assign data_en = accept || (state_q == S_REPLAY) || data_we;

  sram_wrapper #(
    .DEPTH (NLINES),
    .WIDTH (TAG_W),
    .GRAN  (TAG_W)
  ) u_tag (
    .clk_i   (clk_i),
    .en_i    (tag_en),
    .we_i    (tag_we),
    .be_i    (1'b1),
    .addr_i  (tag_we ? idx_of(miss_addr_q) : rd_idx),
    .wdata_i (tag_of(miss_addr_q)),
    .rdata_o (tag_rdata)
  );

  sram_wrapper #(
    .DEPTH (NLINES * WORDS),
    .WIDTH (XLEN),
    .GRAN  (8)
  ) u_data (
    .clk_i   (clk_i),
    .en_i    (data_en),
    .we_i    (data_we),
    .be_i    (4'b1111),
    .addr_i  (data_we ? {idx_of(miss_addr_q), rsp_cnt_q[WRD_W-1:0]} : {rd_idx, rd_wrd}),
    .wdata_i (mem_rsp_i.rdata),
    .rdata_o (data_rdata)
  );

  // ---------------------------------------------------------------------------
  // Next state
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= S_RUN;
      valid_q     <= '0;
      lk_valid_q  <= 1'b0;
      lk_addr_q   <= '0;
      nxt_valid_q <= 1'b0;
      nxt_addr_q  <= '0;
      miss_addr_q <= '0;
      req_cnt_q   <= '0;
      rsp_cnt_q   <= '0;
      started_q   <= 1'b0;
      nofill_q    <= 1'b0;
      any_err_q   <= 1'b0;
      crit_q      <= '0;
      sync_q      <= 1'b0;
      rsp_valid_q <= 1'b0;
      rsp_q       <= '0;
    end else begin
      rsp_valid_q <= 1'b0;

      // FENCE.I: invalidate, and make the next refill wait for the D side.
      if (flush_i) begin
        sync_q <= 1'b1;
        if (state_q == S_MISS) nofill_q <= 1'b1;
      end else if (sync_ok_i) begin
        sync_q <= 1'b0;
      end

      unique case (state_q)
        S_RUN: begin
          if (miss) begin
            state_q     <= S_MISS;
            miss_addr_q <= lk_addr_q;
            lk_valid_q  <= 1'b0;
            if (accept) begin
              nxt_valid_q <= 1'b1;
              nxt_addr_q  <= req_i.addr;
            end
          end else begin
            lk_valid_q <= accept;
            if (accept) lk_addr_q <= req_i.addr;
          end
        end

        S_MISS: begin
          // Once asserted, the request stays asserted until accepted (rule 1),
          // even if a FENCE.I raises sync_q meanwhile.
          if (mem_req_valid_o) started_q <= 1'b1;
          if (mreq_fire)  req_cnt_q <= req_cnt_q + cnt_t'(1);
          if (beat) begin
            rsp_cnt_q <= rsp_cnt_q + cnt_t'(1);
            crit_q    <= crit_now;
            any_err_q <= any_err_q || mem_rsp_i.err;
          end
          if (last_beat) begin
            rsp_valid_q <= 1'b1;
            rsp_q       <= crit_now;
            req_cnt_q   <= '0;
            rsp_cnt_q   <= '0;
            started_q   <= 1'b0;
            nofill_q    <= 1'b0;
            any_err_q   <= 1'b0;
            state_q     <= nxt_valid_q ? S_REPLAY : S_RUN;
          end
        end

        S_REPLAY: begin
          lk_valid_q  <= 1'b1;
          lk_addr_q   <= nxt_addr_q;
          nxt_valid_q <= 1'b0;
          state_q     <= S_RUN;
        end

        default: state_q <= S_RUN;
      endcase

      // Valid bits: FENCE.I clears them all; the end of a refill sets (or,
      // after an error or an overlapping FENCE.I, clears) the refilled line,
      // whose data words were overwritten.
      if (flush_i)        valid_q                     <= '0;
      else if (last_beat) valid_q[idx_of(miss_addr_q)] <= fill_ok;
    end
  end

`ifndef SYNTHESIS
  // Statistics events, counted by the testbench (P4.5) through hierarchical
  // references, hence unused here.
  /* verilator lint_off UNUSEDSIGNAL */
  logic ev_hit, ev_miss;
  assign ev_hit  = hit;
  assign ev_miss = miss;
  /* verilator lint_on UNUSEDSIGNAL */

  a_ro: assert property (@(posedge clk_i) disable iff (!rst_ni) !(accept && req_i.we))
    else $fatal(1, "[icache] write request");
  a_rsp_excl: assert property (@(posedge clk_i) disable iff (!rst_ni) !(rsp_valid_q && hit))
    else $fatal(1, "[icache] refill response and hit in the same cycle");
  a_mrsp: assert property (@(posedge clk_i) disable iff (!rst_ni)
                           mem_rsp_valid_i |-> (state_q == S_MISS && rsp_cnt_q < req_cnt_q))
    else $fatal(1, "[icache] memory response with no refill request outstanding");
  a_mreq_stable: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                  (mem_req_valid_o && !mem_req_ready_i) |=>
                                  (mem_req_valid_o && $stable(mem_req_o)))
    else $fatal(1, "[icache] memory request withdrawn or changed before acceptance");
`endif

endmodule : icache
