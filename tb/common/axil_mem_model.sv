// =============================================================================
// axil_mem_model  (testbench only, not synthesizable)
// -----------------------------------------------------------------------------
// Purpose    : Main memory on the SoC's external AXI4-Lite port (docs/
//              architecture.md P5.5): SIZE bytes at BASE, one read and one
//              write in flight at a time.
// Interfaces : AXI4-Lite slave (req_i from the SoC, rsp_o to it).
// Timing     : +mem=ideal  (default) AWREADY/WREADY/ARREADY always 1; B and R
//                          one cycle after the request is complete.
//              +mem=random each ready is dropped with probability 1/4 per
//                          cycle, independently; B and R come 1..6 cycles
//                          after the request. Seeded by +seed=N (xorshift32),
//                          so every run is reproducible.
//              A write takes effect once both AW and W have been received (in
//              either order); a read samples memory when AR is received. An
//              address outside [BASE, BASE+SIZE) answers SLVERR.
// Loading    : +hex=<file> is read with $readmemh (objcopy -O verilog output,
//              addresses relative to BASE).
// =============================================================================
module axil_mem_model
  import axil_pkg::*;
#(
  parameter logic [31:0] BASE = soc_pkg::MEM_BASE,
  parameter int unsigned SIZE = soc_pkg::MEM_SIZE
) (
  input  logic      clk_i,
  input  logic      rst_ni,
  input  axil_req_t req_i,
  output axil_rsp_t rsp_o
);

  localparam int MAX_LAT = 6;

  logic [7:0] mem [SIZE];

  bit          random_mode;
  int unsigned seed;

  initial begin
    string hex, mode;
    if ($value$plusargs("hex=%s", hex)) $readmemh(hex, mem);
    else $display("[axil_mem_model] warning: no +hex=, memory is uninitialised");
    mode = "ideal";
    void'($value$plusargs("mem=%s", mode));
    if (mode == "random")     random_mode = 1'b1;
    else if (mode == "ideal") random_mode = 1'b0;
    else $fatal(1, "[axil_mem_model] +mem=%s: expected ideal or random", mode);
    seed = 1;
    void'($value$plusargs("seed=%d", seed));
    $display("[axil_mem_model] mode=%s seed=%0d", mode, seed);
  end

  function automatic logic [31:0] xorshift32(logic [31:0] x);
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    return x;
  endfunction

  function automatic logic in_range(logic [31:0] a);
    return (a - BASE) < SIZE;
  endfunction

  // ---------------------------------------------------------------------------
  // State. Bookkeeping uses blocking updates inside one clocked process (a
  // behavioural model); the outputs are registered so the SoC samples them
  // race-free.
  // ---------------------------------------------------------------------------
  logic        aw_ready_q, w_ready_q, ar_ready_q;
  logic        b_valid_q, r_valid_q;
  axil_b_t     b_q;
  axil_r_t     r_q;
  logic [31:0] rng;
  bit          have_aw, have_w, have_ar;        // received, not yet answered
  // AxPROT is not used by the memory.
  /* verilator lint_off UNUSEDSIGNAL */
  axil_ax_t    aw, ar;
  /* verilator lint_on UNUSEDSIGNAL */
  axil_w_t     w;
  // Per direction: 0 = idle/collecting, 1 = waiting its latency, 2 = shown
  int          wr_state, rd_state;
  int          b_wait, r_wait;

  assign rsp_o = '{aw_ready: aw_ready_q, w_ready: w_ready_q, b_valid: b_valid_q, b: b_q,
                   ar_ready: ar_ready_q, r_valid: r_valid_q, r: r_q};

  // Extra cycles before B/R (0 = the cycle after the request is complete)
  function automatic int latency();
    if (!random_mode) return 0;
    rng = xorshift32(rng);
    return int'(rng % 32'(MAX_LAT));
  endfunction

  function automatic logic coin();                // 3/4 probability
    if (!random_mode) return 1'b1;
    rng = xorshift32(rng);
    return rng[1:0] != 2'b00;
  endfunction

  // Byte offset of the word holding address a (a[1:0] ignored: WSTRB selects).
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [31:0] word_addr(logic [31:0] a);
    return {a[31:2], 2'b00} - BASE;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  /* verilator lint_off BLKSEQ */
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      rng      = (seed * 32'h2545_F491) ^ 32'h0BAD_5EED;
      if (rng == '0) rng = 32'h1;
      have_aw  = 1'b0;
      have_w   = 1'b0;
      have_ar  = 1'b0;
      wr_state = 0;
      rd_state = 0;
      b_wait   = 0;
      r_wait   = 0;
      aw_ready_q <= 1'b0;
      w_ready_q  <= 1'b0;
      ar_ready_q <= 1'b0;
      b_valid_q  <= 1'b0;
      r_valid_q  <= 1'b0;
      b_q        <= '0;
      r_q        <= '0;
    end else begin
      // --- responses accepted by the SoC ---
      if (b_valid_q && req_i.b_ready) begin
        b_valid_q <= 1'b0;
        have_aw   = 1'b0;
        have_w    = 1'b0;
        wr_state  = 0;
      end
      if (r_valid_q && req_i.r_ready) begin
        r_valid_q <= 1'b0;
        have_ar   = 1'b0;
        rd_state  = 0;
      end

      // --- requests received this cycle ---
      if (req_i.aw_valid && aw_ready_q) begin aw = req_i.aw; have_aw = 1'b1; end
      if (req_i.w_valid  && w_ready_q)  begin w  = req_i.w;  have_w  = 1'b1; end
      if (req_i.ar_valid && ar_ready_q) begin
        ar      = req_i.ar;
        have_ar = 1'b1;
        if (in_range(ar.addr)) begin
          logic [31:0] a;
          a   = word_addr(ar.addr);
          r_q <= '{data: {mem[a + 3], mem[a + 2], mem[a + 1], mem[a]}, resp: AXI_RESP_OKAY};
        end else begin
          r_q <= '{data: '0, resp: AXI_RESP_SLVERR};
        end
        r_wait   = latency();
        rd_state = 1;
      end

      // --- write: performed once AW and W are both here ---
      if (wr_state == 0 && have_aw && have_w) begin
        if (in_range(aw.addr)) begin
          logic [31:0] a;
          a = word_addr(aw.addr);
          for (int i = 0; i < 4; i++)
            if (w.strb[i]) mem[a + 32'(i)] = w.data[8*i +: 8];
          b_q <= '{resp: AXI_RESP_OKAY};
        end else begin
          b_q <= '{resp: AXI_RESP_SLVERR};
        end
        b_wait   = latency();
        wr_state = 1;
      end

      // --- show B / R after their latency ---
      if (wr_state == 1) begin
        if (b_wait == 0) begin b_valid_q <= 1'b1; wr_state = 2; end
        else b_wait--;
      end
      if (rd_state == 1) begin
        if (r_wait == 0) begin r_valid_q <= 1'b1; rd_state = 2; end
        else r_wait--;
      end

      // --- readies for the next cycle: one transaction per direction ---
      aw_ready_q <= !have_aw && coin();
      w_ready_q  <= !have_w  && coin();
      ar_ready_q <= !have_ar && coin();
    end
  end
  /* verilator lint_on BLKSEQ */

endmodule : axil_mem_model
