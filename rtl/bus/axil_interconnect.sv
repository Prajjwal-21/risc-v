// =============================================================================
// axil_interconnect
// -----------------------------------------------------------------------------
// Purpose    : AXI4-Lite crossbar, 1 master to NSLV slaves (architecture.md
//              P5.1). The address decode is a list of NRULES rules
//              {base, size, port}; an address that matches no rule is
//              answered by an internal error slave with SLVERR (CLAUDE.md 5.4).
// Interfaces : s_req_i/s_rsp_o: the master's link. m_req_o[i]/m_rsp_i[i]: the
//              link to slave i.
// Timing     : * the write path and the read path are independent FSMs with
//                one transaction in flight each.
//              * every output is driven from registers: AW, W and AR are
//                captured before they are forwarded, and B and R are captured
//                before they are returned. No combinational path crosses the
//                interconnect, and no valid depends on a ready.
//              * AW and W are accepted in either order.
// =============================================================================
module axil_interconnect
  import axil_pkg::*;
#(
  parameter int unsigned                   NSLV      = 2,
  parameter int unsigned                   NRULES    = 1,
  parameter logic [NRULES-1:0][31:0]       RULE_BASE = '0,
  parameter logic [NRULES-1:0][31:0]       RULE_SIZE = '0,
  parameter logic [NRULES-1:0][7:0]        RULE_PORT = '0,
  localparam int unsigned                  SEL_W     = (NSLV > 1) ? $clog2(NSLV) : 1
) (
  input  logic                  clk_i,
  // rst_ni is also sampled by the simulation-only assertions (disable iff),
  // which Verilator reports as a synchronous use of an async reset.
  /* verilator lint_off SYNCASYNCNET */
  input  logic                  rst_ni,
  /* verilator lint_on SYNCASYNCNET */

  input  axil_req_t             s_req_i,
  output axil_rsp_t             s_rsp_o,

  output axil_req_t [NSLV-1:0]  m_req_o,
  input  axil_rsp_t [NSLV-1:0]  m_rsp_i
);

  typedef logic [SEL_W-1:0] sel_t;

  // ---------------------------------------------------------------------------
  // Address decode
  // ---------------------------------------------------------------------------
  function automatic logic dec_hit(logic [31:0] a);
    for (int r = 0; r < int'(NRULES); r++)
      if ((a - RULE_BASE[r]) < RULE_SIZE[r]) return 1'b1;
    return 1'b0;
  endfunction

  function automatic sel_t dec_port(logic [31:0] a);
    for (int r = 0; r < int'(NRULES); r++)
      if ((a - RULE_BASE[r]) < RULE_SIZE[r]) return sel_t'(RULE_PORT[r]);
    return '0;
  endfunction

  // ---------------------------------------------------------------------------
  // Write path: IDLE (collect AW and W) -> SEND -> RESP -> BACK
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] { W_IDLE, W_SEND, W_RESP, W_BACK } wstate_e;

  wstate_e  wstate_q;
  axil_ax_t aw_q;
  axil_w_t  w_q;
  logic     have_aw_q, have_w_q, aw_done_q, w_done_q, werr_q;
  sel_t     wsel_q;
  logic [1:0] bresp_q;

  logic s_aw_fire, s_w_fire, m_aw_fire, m_w_fire;
  assign s_aw_fire = s_req_i.aw_valid && s_rsp_o.aw_ready;
  assign s_w_fire  = s_req_i.w_valid  && s_rsp_o.w_ready;
  assign m_aw_fire = m_req_o[wsel_q].aw_valid && m_rsp_i[wsel_q].aw_ready;
  assign m_w_fire  = m_req_o[wsel_q].w_valid  && m_rsp_i[wsel_q].w_ready;

  // ---------------------------------------------------------------------------
  // Read path: IDLE -> SEND -> RESP -> BACK
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] { R_IDLE, R_SEND, R_RESP, R_BACK } rstate_e;

  rstate_e  rstate_q;
  axil_ax_t ar_q;
  sel_t     rsel_q;
  axil_r_t  r_q;

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------
  always_comb begin
    s_rsp_o          = '0;
    s_rsp_o.aw_ready = (wstate_q == W_IDLE) && !have_aw_q;
    s_rsp_o.w_ready  = (wstate_q == W_IDLE) && !have_w_q;
    s_rsp_o.b_valid  = (wstate_q == W_BACK);
    s_rsp_o.b.resp   = bresp_q;
    s_rsp_o.ar_ready = (rstate_q == R_IDLE);
    s_rsp_o.r_valid  = (rstate_q == R_BACK);
    s_rsp_o.r        = r_q;

    m_req_o = '0;
    for (int i = 0; i < int'(NSLV); i++) begin
      m_req_o[i].aw       = aw_q;
      m_req_o[i].w        = w_q;
      m_req_o[i].ar       = ar_q;
    end
    m_req_o[wsel_q].aw_valid = (wstate_q == W_SEND) && !aw_done_q;
    m_req_o[wsel_q].w_valid  = (wstate_q == W_SEND) && !w_done_q;
    m_req_o[wsel_q].b_ready  = (wstate_q == W_RESP);
    m_req_o[rsel_q].ar_valid = (rstate_q == R_SEND);
    m_req_o[rsel_q].r_ready  = (rstate_q == R_RESP);
  end

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wstate_q  <= W_IDLE;
      aw_q      <= '0;
      w_q       <= '0;
      have_aw_q <= 1'b0;
      have_w_q  <= 1'b0;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
      werr_q    <= 1'b0;
      wsel_q    <= '0;
      bresp_q   <= AXI_RESP_OKAY;
      rstate_q  <= R_IDLE;
      ar_q      <= '0;
      rsel_q    <= '0;
      r_q       <= '0;
    end else begin
      // --- write ---
      unique case (wstate_q)
        W_IDLE: begin
          if (s_aw_fire) begin
            aw_q      <= s_req_i.aw;
            have_aw_q <= 1'b1;
            wsel_q    <= dec_port(s_req_i.aw.addr);
            werr_q    <= !dec_hit(s_req_i.aw.addr);
          end
          if (s_w_fire) begin
            w_q      <= s_req_i.w;
            have_w_q <= 1'b1;
          end
          if (have_aw_q && have_w_q) begin
            if (werr_q) begin
              bresp_q  <= AXI_RESP_SLVERR;
              wstate_q <= W_BACK;
            end else begin
              wstate_q <= W_SEND;
            end
          end
        end
        W_SEND: begin
          if (m_aw_fire) aw_done_q <= 1'b1;
          if (m_w_fire)  w_done_q  <= 1'b1;
          if ((m_aw_fire || aw_done_q) && (m_w_fire || w_done_q)) begin
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
            wstate_q  <= W_RESP;
          end
        end
        W_RESP: if (m_rsp_i[wsel_q].b_valid) begin
          bresp_q  <= m_rsp_i[wsel_q].b.resp;
          wstate_q <= W_BACK;
        end
        W_BACK: if (s_req_i.b_ready) begin
          have_aw_q <= 1'b0;
          have_w_q  <= 1'b0;
          wstate_q  <= W_IDLE;
        end
        default: wstate_q <= W_IDLE;
      endcase

      // --- read ---
      unique case (rstate_q)
        R_IDLE: if (s_req_i.ar_valid) begin
          ar_q   <= s_req_i.ar;
          rsel_q <= dec_port(s_req_i.ar.addr);
          if (!dec_hit(s_req_i.ar.addr)) begin
            r_q      <= '{data: '0, resp: AXI_RESP_SLVERR};
            rstate_q <= R_BACK;
          end else begin
            rstate_q <= R_SEND;
          end
        end
        R_SEND: if (m_rsp_i[rsel_q].ar_ready) rstate_q <= R_RESP;
        R_RESP: if (m_rsp_i[rsel_q].r_valid) begin
          r_q      <= m_rsp_i[rsel_q].r;
          rstate_q <= R_BACK;
        end
        R_BACK: if (s_req_i.r_ready) rstate_q <= R_IDLE;
        default: rstate_q <= R_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // Every rule points at an existing port.
  initial begin
    for (int r = 0; r < int'(NRULES); r++)
      if (int'(RULE_PORT[r]) >= int'(NSLV)) $fatal(1, "[axil_interconnect] rule %0d port %0d >= NSLV %0d", r, RULE_PORT[r], NSLV);
  end
  // A slave's response arrives only for a request forwarded to it.
  for (genvar i = 0; i < int'(NSLV); i++) begin : g_chk
    a_b_owned: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                m_rsp_i[i].b_valid |-> (wstate_q == W_RESP && wsel_q == sel_t'(i)))
      else $fatal(1, "[axil_interconnect] slave %0d: B without an outstanding write", i);
    a_r_owned: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                m_rsp_i[i].r_valid |-> (rstate_q == R_RESP && rsel_q == sel_t'(i)))
      else $fatal(1, "[axil_interconnect] slave %0d: R without an outstanding read", i);
  end
`endif

endmodule : axil_interconnect
