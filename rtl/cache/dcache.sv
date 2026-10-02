// =============================================================================
// dcache
// -----------------------------------------------------------------------------
// Purpose    : Data cache (docs/architecture.md P4): 2 KB, direct-mapped,
//              16-byte lines, write-through, no-write-allocate, with a 2-entry
//              write buffer. Only main memory is cached (D-045); every other
//              address bypasses the cache and gets its bus response, so access
//              faults stay precise.
// Interfaces : core side: the core port protocol as a slave (section 2);
//              memory side: the same protocol as a master, shared by the
//              write buffer and the miss/uncached FSM;
//              wb_idle_o: the write buffer is empty and every buffered store
//              has been acknowledged (the I-cache waits for it after FENCE.I).
// Timing     : * load hit: response one cycle after acceptance. Cacheable
//                store: pushed into the write buffer, the line updated on a
//                hit, and acknowledged in its lookup cycle. rsp_valid_o
//                depends only on registered state and the SRAM outputs.
//              * req_ready_o depends only on registered state (D-045): low in
//                MISS/UNC/REPLAY, while a store is in its lookup (the data
//                SRAM is being written) and while the write buffer is full.
//              * load miss / uncached access: waits for wb_idle_o, then the
//                refill (4 reads) or the single access; registered response.
//              * the FSM takes the memory side only when the write buffer is
//                idle, and nothing is pushed while the FSM is busy, so neither
//                ever withdraws a request (rule 1) and every memory response
//                belongs to exactly one of them.
// =============================================================================
module dcache
  import riscv_pkg::*;
#(
  parameter int unsigned CACHE_BYTES = soc_pkg::CACHE_BYTES,
  parameter int unsigned LINE_BYTES  = soc_pkg::CACHE_LINE_BYTES,
  parameter word_t       CACHE_BASE  = soc_pkg::MEM_BASE,   // cached range (D-045)
  parameter word_t       CACHE_SIZE  = soc_pkg::MEM_SIZE
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
  input  mem_req_t req_i,
  output logic     rsp_valid_o,
  output mem_rsp_t rsp_o,

  output logic     wb_idle_o,

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
  typedef logic [WRD_W:0]   cnt_t;

  // Address field extractors: each uses only its own bits of the address.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic idx_t idx_of(word_t a); return a[OFF_W +: IDX_W]; endfunction
  function automatic wrd_t wrd_of(word_t a); return a[2 +: WRD_W];     endfunction
  function automatic tag_t tag_of(word_t a); return a[XLEN-1 -: TAG_W]; endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  function automatic logic cacheable(word_t a); return (a - CACHE_BASE) < CACHE_SIZE; endfunction

  typedef enum logic [1:0] { S_RUN, S_MISS, S_UNC, S_REPLAY } state_e;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  state_e            state_q;
  logic [NLINES-1:0] valid_q;
  logic              lk_valid_q;
  mem_req_t          lk_req_q;
  logic              nxt_valid_q;
  mem_req_t          nxt_req_q;
  mem_req_t          miss_req_q;       // request being refilled / sent uncached
  cnt_t              req_cnt_q;
  cnt_t              rsp_cnt_q;
  logic              started_q;        // this FSM access has asserted its first request
  logic              any_err_q;
  mem_rsp_t          crit_q;
  logic              rsp_valid_q;
  mem_rsp_t          rsp_q;

  // ---------------------------------------------------------------------------
  // Write buffer
  // ---------------------------------------------------------------------------
  logic     wb_push, wb_full, wb_idle, wb_busy;
  logic     wb_req_valid, wb_rsp_valid;
  mem_req_t wb_req;

  write_buffer u_wbuf (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .push_i          (wb_push),
    .push_req_i      (lk_req_q),
    .full_o          (wb_full),
    .idle_o          (wb_idle),
    .busy_o          (wb_busy),
    .mem_req_valid_o (wb_req_valid),
    .mem_req_ready_i (mem_req_ready_i),
    .mem_req_o       (wb_req),
    .mem_rsp_valid_i (wb_rsp_valid),
    .mem_rsp_i       (mem_rsp_i)
  );

  assign wb_idle_o = wb_idle;

  // ---------------------------------------------------------------------------
  // Lookup
  // ---------------------------------------------------------------------------
  tag_t  tag_rdata;
  word_t data_rdata;
  logic  accept, lk_cache, tag_hit, ld_hit, ld_miss, st_cache, st_hit, unc;

  assign req_ready_o = (state_q == S_RUN) && !(lk_valid_q && lk_req_q.we) && !wb_full;
  assign accept      = req_valid_i && req_ready_o;

  assign lk_cache = cacheable(lk_req_q.addr);
  assign tag_hit  = valid_q[idx_of(lk_req_q.addr)] && (tag_rdata == tag_of(lk_req_q.addr));
  assign ld_hit   = lk_valid_q && !lk_req_q.we &&  lk_cache && tag_hit;
  assign ld_miss  = lk_valid_q && !lk_req_q.we &&  lk_cache && !tag_hit;
  assign st_cache = lk_valid_q &&  lk_req_q.we &&  lk_cache;
  assign st_hit   = st_cache && tag_hit;
  assign unc      = lk_valid_q && !lk_cache;
  assign wb_push  = st_cache;

  assign rsp_valid_o = rsp_valid_q || ld_hit || st_cache;
  always_comb begin
    if (rsp_valid_q)  rsp_o = rsp_q;
    else if (ld_hit)  rsp_o = '{rdata: data_rdata, err: 1'b0};
    else              rsp_o = '0;                          // store acknowledgement
  end

  // ---------------------------------------------------------------------------
  // Miss / uncached FSM on the memory side
  // ---------------------------------------------------------------------------
  logic     fsm_req_valid, fsm_fire, fsm_rsp, last_beat, unc_done, fill_ok;
  mem_req_t fsm_req;
  mem_rsp_t crit_now;

  // The FSM starts only once the write buffer is idle (P4.3 rules 1 and 2).
  always_comb begin
    fsm_req_valid = 1'b0;
    fsm_req       = miss_req_q;
    if (state_q == S_MISS) begin
      fsm_req_valid = (req_cnt_q != cnt_t'(WORDS)) && (started_q || wb_idle);
      fsm_req       = '{addr: {miss_req_q.addr[XLEN-1:OFF_W], req_cnt_q[WRD_W-1:0], 2'b00},
                        we: 1'b0, be: 4'b1111, wdata: '0};
    end else if (state_q == S_UNC) begin
      fsm_req_valid = (req_cnt_q == '0) && (started_q || wb_idle);
    end
  end

  assign mem_req_valid_o = fsm_req_valid || wb_req_valid;
  assign mem_req_o       = fsm_req_valid ? fsm_req : wb_req;
  assign fsm_fire        = fsm_req_valid && mem_req_ready_i;

  // Responses belong to the write buffer while it has writes outstanding.
  assign wb_rsp_valid = mem_rsp_valid_i && wb_busy;
  assign fsm_rsp      = mem_rsp_valid_i && !wb_busy;
  assign last_beat    = (state_q == S_MISS) && fsm_rsp && (rsp_cnt_q == cnt_t'(WORDS - 1));
  assign unc_done     = (state_q == S_UNC) && fsm_rsp;
  assign crit_now     = (rsp_cnt_q[WRD_W-1:0] == wrd_of(miss_req_q.addr)) ? mem_rsp_i : crit_q;
  assign fill_ok      = !any_err_q && !mem_rsp_i.err;

  // ---------------------------------------------------------------------------
  // SRAMs. Reads on acceptance and in REPLAY; data writes for store hits (in
  // the lookup cycle, when ready is 0) and refill beats; tag write on the last
  // beat. None of these coincide.
  // ---------------------------------------------------------------------------
  logic       tag_en, tag_we, data_en, data_we, beat;
  logic [3:0] data_be;
  word_t      data_wdata;
  idx_t       rd_idx, wr_idx;
  wrd_t       rd_wrd, wr_wrd;

  assign beat    = (state_q == S_MISS) && fsm_rsp;
  assign rd_idx  = (state_q == S_REPLAY) ? idx_of(nxt_req_q.addr) : idx_of(req_i.addr);
  assign rd_wrd  = (state_q == S_REPLAY) ? wrd_of(nxt_req_q.addr) : wrd_of(req_i.addr);
  assign tag_we  = last_beat;
  assign tag_en  = accept || (state_q == S_REPLAY) || tag_we;
  assign data_we = beat || st_hit;
  assign data_en = accept || (state_q == S_REPLAY) || data_we;

  always_comb begin
    if (beat) begin
      wr_idx     = idx_of(miss_req_q.addr);
      wr_wrd     = rsp_cnt_q[WRD_W-1:0];
      data_be    = 4'b1111;
      data_wdata = mem_rsp_i.rdata;
    end else begin                                         // store hit
      wr_idx     = idx_of(lk_req_q.addr);
      wr_wrd     = wrd_of(lk_req_q.addr);
      data_be    = lk_req_q.be;
      data_wdata = lk_req_q.wdata;
    end
  end

  sram_wrapper #(
    .DEPTH (NLINES),
    .WIDTH (TAG_W),
    .GRAN  (TAG_W)
  ) u_tag (
    .clk_i   (clk_i),
    .en_i    (tag_en),
    .we_i    (tag_we),
    .be_i    (1'b1),
    .addr_i  (tag_we ? idx_of(miss_req_q.addr) : rd_idx),
    .wdata_i (tag_of(miss_req_q.addr)),
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
    .be_i    (data_be),
    .addr_i  (data_we ? {wr_idx, wr_wrd} : {rd_idx, rd_wrd}),
    .wdata_i (data_wdata),
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
      lk_req_q    <= '0;
      nxt_valid_q <= 1'b0;
      nxt_req_q   <= '0;
      miss_req_q  <= '0;
      req_cnt_q   <= '0;
      rsp_cnt_q   <= '0;
      started_q   <= 1'b0;
      any_err_q   <= 1'b0;
      crit_q      <= '0;
      rsp_valid_q <= 1'b0;
      rsp_q       <= '0;
    end else begin
      rsp_valid_q <= 1'b0;

      unique case (state_q)
        S_RUN: begin
          if (ld_miss || unc) begin
            state_q    <= ld_miss ? S_MISS : S_UNC;
            miss_req_q <= lk_req_q;
            lk_valid_q <= 1'b0;
            if (accept) begin
              nxt_valid_q <= 1'b1;
              nxt_req_q   <= req_i;
            end
          end else begin
            lk_valid_q <= accept;
            if (accept) lk_req_q <= req_i;
          end
        end

        S_MISS, S_UNC: begin
          // Once asserted, the request stays asserted until accepted (rule 1),
          // even if a FENCE.I raises sync_q meanwhile.
          if (fsm_req_valid) started_q <= 1'b1;
          if (fsm_fire)  req_cnt_q <= req_cnt_q + cnt_t'(1);
          if (beat) begin
            rsp_cnt_q <= rsp_cnt_q + cnt_t'(1);
            crit_q    <= crit_now;
            any_err_q <= any_err_q || mem_rsp_i.err;
          end
          if (last_beat || unc_done) begin
            rsp_valid_q <= 1'b1;
            rsp_q       <= unc_done ? mem_rsp_i : crit_now;
            req_cnt_q   <= '0;
            rsp_cnt_q   <= '0;
            started_q   <= 1'b0;
            any_err_q   <= 1'b0;
            state_q     <= nxt_valid_q ? S_REPLAY : S_RUN;
          end
        end

        S_REPLAY: begin
          lk_valid_q  <= 1'b1;
          lk_req_q    <= nxt_req_q;
          nxt_valid_q <= 1'b0;
          state_q     <= S_RUN;
        end

        default: state_q <= S_RUN;
      endcase

      // The refilled line's data words were overwritten: it is valid only if
      // every beat was clean.
      if (last_beat) valid_q[idx_of(miss_req_q.addr)] <= fill_ok;
    end
  end

`ifndef SYNTHESIS
  // Statistics events, counted by the testbench (P4.5) through hierarchical
  // references, hence unused here.
  /* verilator lint_off UNUSEDSIGNAL */
  logic ev_ld_hit, ev_ld_miss, ev_st_hit, ev_st_miss, ev_unc, ev_wb_full;
  assign ev_ld_hit  = ld_hit;
  assign ev_ld_miss = ld_miss;
  assign ev_st_hit  = st_hit;
  assign ev_st_miss = st_cache && !tag_hit;
  assign ev_unc     = unc;
  assign ev_wb_full = (state_q == S_RUN) && req_valid_i && wb_full;
  /* verilator lint_on UNUSEDSIGNAL */

  a_rsp_excl: assert property (@(posedge clk_i) disable iff (!rst_ni)
                               !(rsp_valid_q && (ld_hit || st_cache)))
    else $fatal(1, "[dcache] registered response and lookup response in the same cycle");
  a_port_excl: assert property (@(posedge clk_i) disable iff (!rst_ni) !(fsm_req_valid && wb_req_valid))
    else $fatal(1, "[dcache] FSM and write buffer drive the memory side together");
  a_fsm_rsp: assert property (@(posedge clk_i) disable iff (!rst_ni)
                              fsm_rsp |-> ((state_q == S_MISS || state_q == S_UNC) && rsp_cnt_q < req_cnt_q))
    else $fatal(1, "[dcache] memory response with no FSM request outstanding");
  a_mreq_stable: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                  (mem_req_valid_o && !mem_req_ready_i) |=>
                                  (mem_req_valid_o && $stable(mem_req_o)))
    else $fatal(1, "[dcache] memory request withdrawn or changed before acceptance");
`endif

endmodule : dcache
