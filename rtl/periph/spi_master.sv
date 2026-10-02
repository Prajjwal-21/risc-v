// =============================================================================
// spi_master
// -----------------------------------------------------------------------------
// Purpose    : SPI master, modes 0-3, 8-bit frames, MSB or LSB first, 4-entry
//              TX and RX FIFOs, software chip select (docs/architecture.md
//              P6.5): TXDATA, RXDATA, STATUS, CTRL, CLKDIV, CS, IE.
// Interfaces : APB4 slave; sclk_o, mosi_o, cs_n_o, miso_i; irq_o, level, to
//              PLIC source 2.
// Timing     : zero wait states (PREADY = 1, D-034): a write to a full TX FIFO
//              is dropped and sets TXOVF; a read of an empty RX FIFO returns
//              RXDATA[31] = 1. A frame is 16 SCLK edges, CLKDIV clock cycles
//              apart (values below 1 act as 1), plus one half period after the
//              last edge. Odd edges are leading, even edges trailing.
//                CPHA = 0: bit 0 of the frame is on MOSI before edge 1; the
//                          master samples MISO on leading edges and shifts
//                          the next bit out on trailing edges.
//                CPHA = 1: the master shifts a bit out on each leading edge
//                          and samples MISO on each trailing edge.
//              MISO is sampled directly (it was launched by the slave half an
//              SCLK period earlier, on an edge this master generated).
//              irq_o is registered. Offsets without a register answer PSLVERR.
// =============================================================================
module spi_master
  import apb_pkg::*;
  import soc_pkg::*;
(
  input  logic     clk_i,
  input  logic     rst_ni,
  // Only the offset bits of PADDR are decoded (the bridge selects the window).
  /* verilator lint_off UNUSEDSIGNAL */
  input  apb_req_t apb_req_i,
  /* verilator lint_on UNUSEDSIGNAL */
  output apb_rsp_t apb_rsp_o,
  output logic     sclk_o,
  output logic     mosi_o,
  output logic     cs_n_o,
  input  logic     miso_i,
  output logic     irq_o
);

  localparam int unsigned CNT_W = $clog2(SPI_FIFO_DEPTH + 1);

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic [3:0]  ctrl_q;             // EN, CPOL, CPHA, LSBFIRST
  logic [15:0] clkdiv_q;
  logic        cs_q;
  logic [1:0]  ie_q;
  logic        rxovr_q, txovf_q;

  logic en, cpol, cpha, lsb;
  assign en   = ctrl_q[SPI_CTRL_EN];
  assign cpol = ctrl_q[SPI_CTRL_CPOL];
  assign cpha = ctrl_q[SPI_CTRL_CPHA];
  assign lsb  = ctrl_q[SPI_CTRL_LSBFIRST];

  logic        access, wr, rd;
  logic [11:0] off;
  assign access = apb_req_i.psel && apb_req_i.penable;
  assign wr     = access &&  apb_req_i.pwrite;
  assign rd     = access && !apb_req_i.pwrite;
  assign off    = apb_req_i.paddr[11:0];

  logic [15:0] div;
  assign div = (clkdiv_q == '0) ? 16'd1 : clkdiv_q;

  // ---------------------------------------------------------------------------
  // FIFOs
  // ---------------------------------------------------------------------------
  logic       txf_push, txf_pop, txf_full, txf_empty;
  logic [7:0] txf_rdata;
  logic       rxf_push, rxf_pop, rxf_full, rxf_empty;
  logic [7:0] rxf_rdata;
  logic [CNT_W-1:0] txf_cnt, rxf_cnt;

  // Occupancy is not a register field.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [CNT_W-1:0] fifo_cnt_unused;
  assign fifo_cnt_unused = txf_cnt ^ rxf_cnt;
  /* verilator lint_on UNUSEDSIGNAL */

  logic [7:0] rx_shift_q;

  sync_fifo #(.DEPTH(SPI_FIFO_DEPTH), .WIDTH(8)) u_txf (
    .clk_i (clk_i), .rst_ni (rst_ni), .push_i (txf_push), .wdata_i (apb_req_i.pwdata[7:0]),
    .pop_i (txf_pop), .rdata_o (txf_rdata), .full_o (txf_full), .empty_o (txf_empty),
    .count_o (txf_cnt));

  sync_fifo #(.DEPTH(SPI_FIFO_DEPTH), .WIDTH(8)) u_rxf (
    .clk_i (clk_i), .rst_ni (rst_ni), .push_i (rxf_push), .wdata_i (rx_shift_q),
    .pop_i (rxf_pop), .rdata_o (rxf_rdata), .full_o (rxf_full), .empty_o (rxf_empty),
    .count_o (rxf_cnt));

  logic tx_write;
  assign tx_write = wr && (off == SPI_TXDATA) && apb_req_i.pstrb[0];
  assign txf_push = tx_write && !txf_full;
  assign rxf_pop  = rd && (off == SPI_RXDATA) && !rxf_empty;

  // ---------------------------------------------------------------------------
  // Frame engine
  // ---------------------------------------------------------------------------
  logic        busy_q;
  logic [4:0]  edge_q;             // edges done in this frame, 0..16
  logic [15:0] cnt_q;
  logic [7:0]  tx_shift_q;
  logic        sclk_q, mosi_q;
  logic        frame_done;
  logic        leading;            // the next edge, number edge_q+1, is odd (leading)
  assign leading = !edge_q[0];

  // Bit to put on MOSI next (an end bit of the shift register), and the shift
  // register after it is used.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic out_bit(logic [7:0] sh, logic lsb_first);
    return lsb_first ? sh[0] : sh[7];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  function automatic logic [7:0] after_out(logic [7:0] sh, logic lsb_first);
    return lsb_first ? {1'b0, sh[7:1]} : {sh[6:0], 1'b0};
  endfunction

  assign txf_pop    = en && !busy_q && !txf_empty;
  assign frame_done = busy_q && (edge_q == 5'd16) && (cnt_q == '0);
  assign rxf_push   = frame_done && !rxf_full;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q     <= 1'b0;
      edge_q     <= '0;
      cnt_q      <= '0;
      tx_shift_q <= '0;
      rx_shift_q <= '0;
      sclk_q     <= 1'b0;
      mosi_q     <= 1'b0;
    end else if (txf_pop) begin
      busy_q <= 1'b1;
      edge_q <= '0;
      cnt_q  <= div - 16'd1;
      sclk_q <= cpol;
      if (!cpha) begin                        // bit 0 before the first edge
        mosi_q     <= out_bit(txf_rdata, lsb);
        tx_shift_q <= after_out(txf_rdata, lsb);
      end else begin
        tx_shift_q <= txf_rdata;
      end
    end else if (busy_q) begin
      if (cnt_q != '0) begin
        cnt_q <= cnt_q - 16'd1;
      end else if (edge_q == 5'd16) begin    // trailing half period elapsed
        busy_q <= 1'b0;
      end else begin
        sclk_q  <= !sclk_q;
        edge_q  <= edge_q + 5'd1;
        cnt_q   <= div - 16'd1;
        if (leading == !cpha) begin           // sample MISO
          rx_shift_q <= lsb ? {miso_i, rx_shift_q[7:1]} : {rx_shift_q[6:0], miso_i};
        end else if (cpha || edge_q != 5'd15) begin
          // shift out: CPHA=1 on every leading edge; CPHA=0 on trailing edges
          // except the last
          mosi_q     <= out_bit(tx_shift_q, lsb);
          tx_shift_q <= after_out(tx_shift_q, lsb);
        end
      end
    end
  end

  assign sclk_o = busy_q ? sclk_q : cpol;
  assign mosi_o = mosi_q;
  assign cs_n_o = !cs_q;

  // ---------------------------------------------------------------------------
  // Register file
  // ---------------------------------------------------------------------------
  logic        busy;
  logic [31:0] status;
  assign busy = busy_q || !txf_empty;
  always_comb begin
    status                 = '0;
    status[SPI_ST_BUSY]    = busy;
    status[SPI_ST_TXFULL]  = txf_full;
    status[SPI_ST_RXVALID] = !rxf_empty;
    status[ST_RXOVR]       = rxovr_q;
    status[ST_TXOVF]       = txovf_q;
  end

  logic        known;
  logic [31:0] rdata;
  always_comb begin
    known = 1'b1;
    rdata = '0;
    unique case (off)
      SPI_TXDATA: rdata = '0;
      SPI_RXDATA: rdata = rxf_empty ? (32'd1 << RXDATA_EMPTY) : {24'b0, rxf_rdata};
      SPI_STATUS: rdata = status;
      SPI_CTRL:   rdata = {28'b0, ctrl_q};
      SPI_CLKDIV: rdata = {16'b0, clkdiv_q};
      SPI_CS:     rdata = {31'b0, cs_q};
      SPI_IE:     rdata = {30'b0, ie_q};
      default:    known = 1'b0;
    endcase
  end

  assign apb_rsp_o = '{prdata: rdata, pready: 1'b1, pslverr: access && !known};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctrl_q   <= '0;
      clkdiv_q <= SPI_CLKDIV_RESET;
      cs_q     <= 1'b0;
      ie_q     <= '0;
      rxovr_q  <= 1'b0;
      txovf_q  <= 1'b0;
      irq_o    <= 1'b0;
    end else begin
      if (wr) begin
        unique case (off)
          SPI_CTRL:   if (apb_req_i.pstrb[0]) ctrl_q <= apb_req_i.pwdata[3:0];
          SPI_CLKDIV: begin
            if (apb_req_i.pstrb[0]) clkdiv_q[7:0]  <= apb_req_i.pwdata[7:0];
            if (apb_req_i.pstrb[1]) clkdiv_q[15:8] <= apb_req_i.pwdata[15:8];
          end
          SPI_CS:     if (apb_req_i.pstrb[0]) cs_q <= apb_req_i.pwdata[0];
          SPI_IE:     if (apb_req_i.pstrb[0]) ie_q <= apb_req_i.pwdata[1:0];
          default: ;
        endcase
      end
      if (wr && off == SPI_STATUS && apb_req_i.pstrb[0]) begin
        if (apb_req_i.pwdata[ST_RXOVR]) rxovr_q <= 1'b0;
        if (apb_req_i.pwdata[ST_TXOVF]) txovf_q <= 1'b0;
      end
      if (frame_done && rxf_full) rxovr_q <= 1'b1;
      if (tx_write && txf_full)   txovf_q <= 1'b1;

      irq_o <= (ie_q[0] && !rxf_empty) || (ie_q[1] && !busy);
    end
  end

endmodule : spi_master
