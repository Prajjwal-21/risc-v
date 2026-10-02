// =============================================================================
// plic
// -----------------------------------------------------------------------------
// Purpose    : Simplified platform-level interrupt controller (docs/
//              architecture.md P6.3): NSRC level-sensitive sources (IDs
//              1..NSRC), one context, standard offsets for priority, pending,
//              enable, threshold and claim/complete.
// Interfaces : APB4 slave; src_i[i] is source i's level (bit 0 unused: ID 0
//              means "no interrupt"); irq_o to the core's MEIP line.
// Timing     : zero wait states (PREADY = 1, D-034). Gateway: a source becomes
//              pending when its line is high and it is not in service; a
//              claim (read of CLAIM in its ACCESS cycle) clears the pending
//              bit and puts the source in service; a complete (write of the
//              ID) ends service. irq_o is registered. Offsets without a
//              register answer PSLVERR.
// =============================================================================
module plic
  import apb_pkg::*;
  import soc_pkg::*;
#(
  parameter int unsigned NSRC   = PLIC_NSRC,
  parameter int unsigned PRIO_W = PLIC_PRIO_W,
  localparam int unsigned ID_W  = $clog2(NSRC + 1)
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  // Only the offset bits of PADDR are decoded (the bridge selects the window).
  /* verilator lint_off UNUSEDSIGNAL */
  input  apb_req_t      apb_req_i,
  input  logic [NSRC:0] src_i,
  /* verilator lint_on UNUSEDSIGNAL */
  output apb_rsp_t      apb_rsp_o,
  output logic          irq_o
);

  typedef logic [PRIO_W-1:0] prio_t;
  typedef logic [ID_W-1:0]   id_t;

  prio_t         prio_q [NSRC+1];     // index 0 unused
  logic [NSRC:0] enable_q, pending_q, in_service_q;
  prio_t         threshold_q;

  logic        access, wr, rd;
  logic [21:0] off;
  assign access = apb_req_i.psel && apb_req_i.penable;
  assign wr     = access &&  apb_req_i.pwrite;
  assign rd     = access && !apb_req_i.pwrite;
  assign off    = apb_req_i.paddr[21:0];

  // PRIORITYn at offset 4 * n, n = 1..NSRC
  logic prio_hit;
  id_t  prio_id;
  assign prio_hit = (off[21:12] == '0) && (off[1:0] == 2'b00) && (off[11:2] >= 10'd1)
                 && (off[11:2] <= 10'(NSRC));
  assign prio_id  = id_t'(off[11:2]);

  // ---------------------------------------------------------------------------
  // Best candidate: pending, enabled, priority above the threshold; highest
  // priority wins, ties go to the lower ID (scan from ID 1 up, strictly
  // greater replaces).
  // ---------------------------------------------------------------------------
  id_t   best_id;
  prio_t best_prio;
  always_comb begin
    best_id   = '0;
    best_prio = '0;
    for (int i = 1; i <= int'(NSRC); i++) begin
      if (pending_q[i] && enable_q[i] && (prio_q[i] > threshold_q) && (prio_q[i] > best_prio)) begin
        best_id   = id_t'(i);
        best_prio = prio_q[i];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Register file
  // ---------------------------------------------------------------------------
  logic        known;
  logic [31:0] rdata;
  always_comb begin
    known = 1'b1;
    rdata = '0;
    if (off == PLIC_PENDING) begin
      rdata = 32'(pending_q) & ~32'd1;
    end else if (off == PLIC_ENABLE) begin
      rdata = 32'(enable_q) & ~32'd1;
    end else if (off == PLIC_THRESHOLD) begin
      rdata = 32'(threshold_q);
    end else if (off == PLIC_CLAIM) begin
      rdata = 32'(best_id);
    end else if (prio_hit) begin
      rdata = 32'(prio_q[prio_id]);
    end else begin
      known = 1'b0;
    end
  end

  assign apb_rsp_o = '{prdata: rdata, pready: 1'b1, pslverr: access && !known};

  logic claim, complete;
  id_t  complete_id;
  assign claim       = rd && (off == PLIC_CLAIM) && (best_id != '0);
  assign complete    = wr && (off == PLIC_CLAIM);
  assign complete_id = id_t'(apb_req_i.pwdata);

  // Gateway in-service bits after this cycle's claim and complete
  logic [NSRC:0] in_service_d;
  always_comb begin
    in_service_d = in_service_q;
    for (int i = 1; i <= int'(NSRC); i++) begin
      if (claim && best_id == id_t'(i)) in_service_d[i] = 1'b1;
      if (complete && complete_id == id_t'(i) && in_service_q[i]) in_service_d[i] = 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prio_q       <= '{default: '0};
      enable_q     <= '0;
      pending_q    <= '0;
      in_service_q <= '0;
      threshold_q  <= '0;
      irq_o        <= 1'b0;
    end else begin
      // Configuration writes
      if (wr) begin
        if (off == PLIC_ENABLE)
          enable_q <= apb_req_i.pwdata[NSRC:0] & ~(NSRC+1)'(1);
        else if (off == PLIC_THRESHOLD)
          threshold_q <= apb_req_i.pwdata[PRIO_W-1:0];
        else if (prio_hit)
          prio_q[prio_id] <= apb_req_i.pwdata[PRIO_W-1:0];
      end

      // Gateways, claim and complete
      in_service_q <= in_service_d;
      for (int i = 1; i <= int'(NSRC); i++) begin
        if (claim && best_id == id_t'(i)) pending_q[i] <= 1'b0;
        else if (src_i[i] && !in_service_q[i])   pending_q[i] <= 1'b1;
      end

      irq_o <= (best_id != '0) && !claim;
    end
  end

`ifndef SYNTHESIS
  initial if (NSRC < 1 || NSRC > 1023) $fatal(1, "[plic] NSRC %0d out of range", NSRC);
`endif

endmodule : plic
