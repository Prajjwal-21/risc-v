// =============================================================================
// uart
// -----------------------------------------------------------------------------
// Purpose    : 8N1 UART with 8-entry TX and RX FIFOs (docs/architecture.md
//              P6.4): TXDATA, RXDATA, STATUS, CTRL, BAUDDIV, IE.
// Interfaces : APB4 slave; tx_o / rx_i serial pins (idle high); irq_o, level,
//              to PLIC source 1.
// Timing     : zero wait states (PREADY = 1, D-034): a write to a full TX FIFO
//              is dropped and sets TXOVF; a read of an empty RX FIFO returns
//              RXDATA[31] = 1. One bit lasts BAUDDIV clock cycles (values
//              below 2 act as 2). RX passes through a 2-flop synchronizer,
//              starts on a falling edge and samples in the middle of each bit.
//              irq_o is registered. Offsets without a register answer PSLVERR.
// =============================================================================
module uart
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
  output logic     tx_o,
  input  logic     rx_i,
  output logic     irq_o
);

  localparam int unsigned CNT_W = $clog2(UART_FIFO_DEPTH + 1);

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic        txen_q, rxen_q;
  logic [15:0] bauddiv_q;
  logic [1:0]  ie_q;
  logic        rxovr_q, txovf_q, framerr_q;

  logic        access, wr, rd;
  logic [11:0] off;
  assign access = apb_req_i.psel && apb_req_i.penable;
  assign wr     = access &&  apb_req_i.pwrite;
  assign rd     = access && !apb_req_i.pwrite;
  assign off    = apb_req_i.paddr[11:0];

  logic [15:0] div;
  assign div = (bauddiv_q < 16'd2) ? 16'd2 : bauddiv_q;

  // ---------------------------------------------------------------------------
  // FIFOs
  // ---------------------------------------------------------------------------
  logic       txf_push, txf_pop, txf_full, txf_empty;
  logic [7:0] txf_rdata;
  logic       rxf_push, rxf_pop, rxf_full, rxf_empty;
  logic [7:0] rxf_rdata, rx_byte;
  logic [CNT_W-1:0] txf_cnt, rxf_cnt;

  // Occupancy is not a register field.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [CNT_W-1:0] fifo_cnt_unused;
  assign fifo_cnt_unused = txf_cnt ^ rxf_cnt;
  /* verilator lint_on UNUSEDSIGNAL */

  sync_fifo #(.DEPTH(UART_FIFO_DEPTH), .WIDTH(8)) u_txf (
    .clk_i (clk_i), .rst_ni (rst_ni), .push_i (txf_push), .wdata_i (apb_req_i.pwdata[7:0]),
    .pop_i (txf_pop), .rdata_o (txf_rdata), .full_o (txf_full), .empty_o (txf_empty),
    .count_o (txf_cnt));

  sync_fifo #(.DEPTH(UART_FIFO_DEPTH), .WIDTH(8)) u_rxf (
    .clk_i (clk_i), .rst_ni (rst_ni), .push_i (rxf_push), .wdata_i (rx_byte),
    .pop_i (rxf_pop), .rdata_o (rxf_rdata), .full_o (rxf_full), .empty_o (rxf_empty),
    .count_o (rxf_cnt));

  logic tx_write;
  assign tx_write = wr && (off == UART_TXDATA) && apb_req_i.pstrb[0];
  assign txf_push = tx_write && !txf_full;
  assign rxf_pop  = rd && (off == UART_RXDATA) && !rxf_empty;

  // ---------------------------------------------------------------------------
  // Transmitter: start bit, 8 data bits LSB first, stop bit
  // ---------------------------------------------------------------------------
  logic        tx_busy_q;
  logic [9:0]  tx_shift_q;
  logic [3:0]  tx_bits_q;         // bits still to send, including the current
  logic [15:0] tx_cnt_q;

  assign txf_pop = txen_q && !tx_busy_q && !txf_empty;
  assign tx_o    = tx_busy_q ? tx_shift_q[0] : 1'b1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_busy_q  <= 1'b0;
      tx_shift_q <= '1;
      tx_bits_q  <= '0;
      tx_cnt_q   <= '0;
    end else if (txf_pop) begin
      tx_busy_q  <= 1'b1;
      tx_shift_q <= {1'b1, txf_rdata, 1'b0};
      tx_bits_q  <= 4'd10;
      tx_cnt_q   <= div - 16'd1;
    end else if (tx_busy_q) begin
      if (tx_cnt_q == '0) begin
        tx_shift_q <= {1'b1, tx_shift_q[9:1]};
        tx_cnt_q   <= div - 16'd1;
        tx_bits_q  <= tx_bits_q - 4'd1;
        if (tx_bits_q == 4'd1) tx_busy_q <= 1'b0;
      end else begin
        tx_cnt_q <= tx_cnt_q - 16'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Receiver
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] { RX_IDLE, RX_START, RX_DATA, RX_STOP } rx_state_e;

  logic        rx_s, rx_prev_q;
  rx_state_e   rx_state_q;
  logic [15:0] rx_cnt_q;
  logic [2:0]  rx_bit_q;
  logic [7:0]  rx_shift_q;
  logic        rx_done, rx_frame_ok;

  sync_2ff #(.RESET_VAL(1'b1)) u_rx_sync (.clk_i (clk_i), .rst_ni (rst_ni), .d_i (rx_i), .q_o (rx_s));

  assign rx_done     = (rx_state_q == RX_STOP) && (rx_cnt_q == '0);
  assign rx_frame_ok = rx_done && rx_s;
  assign rx_byte     = rx_shift_q;
  assign rxf_push    = rx_frame_ok && !rxf_full;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_prev_q  <= 1'b1;
      rx_state_q <= RX_IDLE;
      rx_cnt_q   <= '0;
      rx_bit_q   <= '0;
      rx_shift_q <= '0;
    end else begin
      rx_prev_q <= rx_s;
      unique case (rx_state_q)
        RX_IDLE: if (rxen_q && rx_prev_q && !rx_s) begin
          rx_state_q <= RX_START;
          rx_cnt_q   <= (div >> 1) - 16'd1;        // to the middle of the start bit
        end
        RX_START: if (rx_cnt_q == '0) begin
          if (rx_s) rx_state_q <= RX_IDLE;          // glitch, not a start bit
          else begin
            rx_state_q <= RX_DATA;
            rx_cnt_q   <= div - 16'd1;
            rx_bit_q   <= '0;
          end
        end else rx_cnt_q <= rx_cnt_q - 16'd1;
        RX_DATA: if (rx_cnt_q == '0) begin
          rx_shift_q <= {rx_s, rx_shift_q[7:1]};    // LSB first
          rx_cnt_q   <= div - 16'd1;
          rx_bit_q   <= rx_bit_q + 3'd1;
          if (rx_bit_q == 3'd7) rx_state_q <= RX_STOP;
        end else rx_cnt_q <= rx_cnt_q - 16'd1;
        RX_STOP: if (rx_cnt_q == '0) rx_state_q <= RX_IDLE;
                 else rx_cnt_q <= rx_cnt_q - 16'd1;
        default: rx_state_q <= RX_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Register file
  // ---------------------------------------------------------------------------
  logic [31:0] status;
  always_comb begin
    status                  = '0;
    status[UART_ST_TXFULL]  = txf_full;
    status[UART_ST_TXEMPTY] = txf_empty && !tx_busy_q;
    status[UART_ST_RXVALID] = !rxf_empty;
    status[ST_RXOVR]        = rxovr_q;
    status[ST_TXOVF]        = txovf_q;
    status[UART_ST_FRAMERR] = framerr_q;
  end

  logic        known;
  logic [31:0] rdata;
  always_comb begin
    known = 1'b1;
    rdata = '0;
    unique case (off)
      UART_TXDATA:  rdata = '0;
      UART_RXDATA:  rdata = rxf_empty ? (32'd1 << RXDATA_EMPTY) : {24'b0, rxf_rdata};
      UART_STATUS:  rdata = status;
      UART_CTRL:    rdata = {30'b0, rxen_q, txen_q};
      UART_BAUDDIV: rdata = {16'b0, bauddiv_q};
      UART_IE:      rdata = {30'b0, ie_q};
      default:      known = 1'b0;
    endcase
  end

  assign apb_rsp_o = '{prdata: rdata, pready: 1'b1, pslverr: access && !known};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      txen_q    <= 1'b0;
      rxen_q    <= 1'b0;
      bauddiv_q <= UART_BAUDDIV_RESET;
      ie_q      <= '0;
      rxovr_q   <= 1'b0;
      txovf_q   <= 1'b0;
      framerr_q <= 1'b0;
      irq_o     <= 1'b0;
    end else begin
      if (wr) begin
        unique case (off)
          UART_CTRL: if (apb_req_i.pstrb[0]) begin
            txen_q <= apb_req_i.pwdata[0];
            rxen_q <= apb_req_i.pwdata[1];
          end
          UART_BAUDDIV: begin
            if (apb_req_i.pstrb[0]) bauddiv_q[7:0]  <= apb_req_i.pwdata[7:0];
            if (apb_req_i.pstrb[1]) bauddiv_q[15:8] <= apb_req_i.pwdata[15:8];
          end
          UART_IE: if (apb_req_i.pstrb[0]) ie_q <= apb_req_i.pwdata[1:0];
          default: ;
        endcase
      end
      // Sticky flags: set by the event, cleared by writing 1 (W1C); an event
      // in the same cycle wins.
      if (wr && off == UART_STATUS && apb_req_i.pstrb[0]) begin
        if (apb_req_i.pwdata[ST_RXOVR])        rxovr_q   <= 1'b0;
        if (apb_req_i.pwdata[ST_TXOVF])        txovf_q   <= 1'b0;
        if (apb_req_i.pwdata[UART_ST_FRAMERR]) framerr_q <= 1'b0;
      end
      if (rx_frame_ok && rxf_full) rxovr_q   <= 1'b1;
      if (tx_write && txf_full)    txovf_q   <= 1'b1;
      if (rx_done && !rx_s)        framerr_q <= 1'b1;

      irq_o <= (ie_q[0] && !rxf_empty) || (ie_q[1] && txf_empty && !tx_busy_q);
    end
  end

endmodule : uart
