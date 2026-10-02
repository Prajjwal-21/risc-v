// =============================================================================
// axil2apb
// -----------------------------------------------------------------------------
// Purpose    : AXI4-Lite slave to APB4 master bridge (architecture.md P5.1).
//              One transaction at a time; a complete write (AW and W) and a
//              read waiting together are served alternately. Each APB
//              transfer is a SETUP cycle then ACCESS cycles until PREADY;
//              PSLVERR becomes SLVERR. PSEL is decoded from the address
//              (NSLV windows); an address in no window gets SLVERR without an
//              APB transfer.
// Interfaces : AXI4-Lite slave (s_req_i/s_rsp_o); APB4 master, one request
//              struct per peripheral (apb_req_o[i], with its own PSEL) and one
//              response struct per peripheral. PADDR is the full address.
// Timing     : every output comes from registers. A read or write takes at
//              least 4 cycles on the AXI side (capture, SETUP, ACCESS, B/R).
//              The bridge relies on every APB slave asserting PREADY within a
//              bounded time (D-034); it has no timeout.
// =============================================================================
module axil2apb
  import axil_pkg::*;
  import apb_pkg::*;
#(
  parameter int unsigned             NSLV     = 4,
  parameter logic [NSLV-1:0][31:0]   SLV_BASE = '0,
  parameter logic [NSLV-1:0][31:0]   SLV_SIZE = '0,
  localparam int unsigned            SEL_W    = (NSLV > 1) ? $clog2(NSLV) : 1
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,

  input  axil_req_t            s_req_i,
  output axil_rsp_t            s_rsp_o,

  output apb_req_t [NSLV-1:0]  apb_req_o,
  input  apb_rsp_t [NSLV-1:0]  apb_rsp_i
);

  typedef logic [SEL_W-1:0] sel_t;

  function automatic logic dec_hit(logic [31:0] a);
    for (int i = 0; i < int'(NSLV); i++)
      if ((a - SLV_BASE[i]) < SLV_SIZE[i]) return 1'b1;
    return 1'b0;
  endfunction

  function automatic sel_t dec_sel(logic [31:0] a);
    for (int i = 0; i < int'(NSLV); i++)
      if ((a - SLV_BASE[i]) < SLV_SIZE[i]) return sel_t'(i);
    return '0;
  endfunction

  typedef enum logic [2:0] { S_IDLE, S_SETUP, S_ACCESS, S_WBACK, S_RBACK } state_e;

  state_e      state_q;
  axil_ax_t    aw_q, ar_q;
  axil_w_t     w_q;
  logic        have_aw_q, have_w_q, have_ar_q;
  logic        last_wr_q;                // the last transfer served was a write
  logic        cur_wr_q;                 // the transfer in progress is a write
  sel_t        sel_q;
  logic [31:0] paddr_q;
  logic [2:0]  pprot_q;
  logic [31:0] rdata_q;
  logic [1:0]  resp_q;

  logic wr_ok, rd_ok, pick_wr;
  assign wr_ok   = have_aw_q && have_w_q;
  assign rd_ok   = have_ar_q;
  assign pick_wr = wr_ok && (!rd_ok || !last_wr_q);

  logic [31:0] pick_addr;          // address of the transaction started next
  assign pick_addr = pick_wr ? aw_q.addr : ar_q.addr;

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------
  always_comb begin
    s_rsp_o          = '0;
    s_rsp_o.aw_ready = !have_aw_q;
    s_rsp_o.w_ready  = !have_w_q;
    s_rsp_o.ar_ready = !have_ar_q;
    s_rsp_o.b_valid  = (state_q == S_WBACK);
    s_rsp_o.b.resp   = resp_q;
    s_rsp_o.r_valid  = (state_q == S_RBACK);
    s_rsp_o.r        = '{data: rdata_q, resp: resp_q};

    for (int i = 0; i < int'(NSLV); i++) begin
      apb_req_o[i]         = '0;
      apb_req_o[i].paddr   = paddr_q;
      apb_req_o[i].pwrite  = cur_wr_q;
      apb_req_o[i].pwdata  = cur_wr_q ? w_q.data : '0;
      apb_req_o[i].pstrb   = cur_wr_q ? w_q.strb : '0;     // APB4: 0 for reads
      apb_req_o[i].pprot   = pprot_q;
      apb_req_o[i].psel    = (state_q == S_SETUP || state_q == S_ACCESS) && (sel_q == sel_t'(i));
      apb_req_o[i].penable = (state_q == S_ACCESS) && (sel_q == sel_t'(i));
    end
  end

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= S_IDLE;
      aw_q      <= '0;
      ar_q      <= '0;
      w_q       <= '0;
      have_aw_q <= 1'b0;
      have_w_q  <= 1'b0;
      have_ar_q <= 1'b0;
      last_wr_q <= 1'b0;
      cur_wr_q  <= 1'b0;
      sel_q     <= '0;
      paddr_q   <= '0;
      pprot_q   <= '0;
      rdata_q   <= '0;
      resp_q    <= AXI_RESP_OKAY;
    end else begin
      // Capture AW, W and AR independently while their holding register is free.
      if (s_req_i.aw_valid && !have_aw_q) begin aw_q <= s_req_i.aw; have_aw_q <= 1'b1; end
      if (s_req_i.w_valid  && !have_w_q)  begin w_q  <= s_req_i.w;  have_w_q  <= 1'b1; end
      if (s_req_i.ar_valid && !have_ar_q) begin ar_q <= s_req_i.ar; have_ar_q <= 1'b1; end

      unique case (state_q)
        S_IDLE: if (wr_ok || rd_ok) begin
          cur_wr_q  <= pick_wr;
          last_wr_q <= pick_wr;
          paddr_q   <= pick_addr;
          pprot_q   <= pick_wr ? aw_q.prot : ar_q.prot;
          sel_q     <= dec_sel(pick_addr);
          if (dec_hit(pick_addr)) begin
            state_q <= S_SETUP;
          end else begin
            rdata_q <= '0;
            resp_q  <= AXI_RESP_SLVERR;
            state_q <= pick_wr ? S_WBACK : S_RBACK;
          end
        end
        S_SETUP: state_q <= S_ACCESS;
        S_ACCESS: if (apb_rsp_i[sel_q].pready) begin
          rdata_q <= cur_wr_q ? '0 : apb_rsp_i[sel_q].prdata;
          resp_q  <= apb_rsp_i[sel_q].pslverr ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
          state_q <= cur_wr_q ? S_WBACK : S_RBACK;
        end
        S_WBACK: if (s_req_i.b_ready) begin
          have_aw_q <= 1'b0;
          have_w_q  <= 1'b0;
          state_q   <= S_IDLE;
        end
        S_RBACK: if (s_req_i.r_ready) begin
          have_ar_q <= 1'b0;
          state_q   <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule : axil2apb
