// =============================================================================
// core_cov  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : Functional coverage of the core's hazard and trap scenarios
//              (CLAUDE.md section 6, docs/architecture.md P7.3), as SVA cover
//              points. Bound into every core_top instance (bind below); the
//              models are built with --coverage-user and each run writes its
//              counts to +cov=<file> (tb/common/wave_ctl.sv). make coverage
//              merges the runs and reports every point (scripts/coverage_report.py).
// Interfaces : core_top's own signals, connected by name (.*).
// =============================================================================
module core_cov
  import riscv_pkg::*;
(
  input logic      clk_i,
  input logic      rst_ni,
  // A monitor: it reads only some fields of the pipeline registers.
  /* verilator lint_off UNUSEDSIGNAL */
  input logic      stall, load_use, redirect, mem_wait, irq_block,
  input if_id_t    if_id_q,
  input id_ex_t    id_ex_q,
  input ex_mem_t   ex_mem_q,
  input mem_wb_t   mem_wb_q,
  input fwd_sel_e  fwd_rs1, fwd_rs2,
  input ctrl_t     id_ctrl,
  input reg_addr_t id_rs1, id_rs2,
  input logic      ex_redirect, ex_mem_op, ex_self_exc,
  input logic      trap_take, irq_take, irq_pend, can_commit, mret, fence_i_o,
  input exc_code_t trap_code,
  input logic      irq_software_i, irq_timer_i, irq_external_i
  /* verilator lint_on UNUSEDSIGNAL */
);

  logic ex_moves, id_moves, retire;
  assign ex_moves = !stall && id_ex_q.valid;
  assign id_moves = !stall && !load_use && !redirect && if_id_q.valid;
  assign retire   = can_commit && !stall;

  // Instruction classes from the encoding (the pipeline registers after ID
  // carry no decoded source-use bits); each looks at a few fields only.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic is_csr_insn(inst_t i);
    return i[6:0] == OPC_SYSTEM && i[13:12] != 2'b00;
  endfunction
  function automatic logic reads_rs1(inst_t i);
    return i[6:0] inside {OPC_OP, OPC_OP_IMM, OPC_BRANCH, OPC_STORE, OPC_LOAD, OPC_JALR}
        || (i[6:0] == OPC_SYSTEM && i[14] == 1'b0 && i[13:12] != 2'b00);
  endfunction
  function automatic logic reads_rs2(inst_t i);
    return i[6:0] inside {OPC_OP, OPC_BRANCH, OPC_STORE};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // Previous retired instruction was a CSR instruction writing rd (for "CSR
  // then use", "back-to-back CSR").
  logic      prev_csr_q;
  reg_addr_t prev_csr_rd_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_csr_q    <= 1'b0;
      prev_csr_rd_q <= '0;
    end else if (retire) begin
      prev_csr_q    <= is_csr_insn(ex_mem_q.instr);
      prev_csr_rd_q <= ex_mem_q.rd;
    end
  end

  // Interrupt lines, previous cycle (rising edge during a stall)
  logic [2:0] lines_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) lines_q <= '0;
    else         lines_q <= {irq_external_i, irq_timer_i, irq_software_i};
  end

  // --- Forwarding (4.1) ----------------------------------------------------------
  cp_fwd_exmem_rs1:  cover property (@(posedge clk_i) disable iff (!rst_ni)
                                     ex_moves && id_ex_q.ctrl.uses_rs1 && fwd_rs1 == FWD_EXMEM);
  cp_fwd_exmem_rs2:  cover property (@(posedge clk_i) disable iff (!rst_ni)
                                     ex_moves && id_ex_q.ctrl.uses_rs2 && fwd_rs2 == FWD_EXMEM);
  cp_fwd_memwb_rs1:  cover property (@(posedge clk_i) disable iff (!rst_ni)
                                     ex_moves && id_ex_q.ctrl.uses_rs1 && fwd_rs1 == FWD_MEMWB);
  cp_fwd_memwb_rs2:  cover property (@(posedge clk_i) disable iff (!rst_ni)
                                     ex_moves && id_ex_q.ctrl.uses_rs2 && fwd_rs2 == FWD_MEMWB);
  cp_fwd_both:       cover property (@(posedge clk_i) disable iff (!rst_ni)
                                     ex_moves && id_ex_q.ctrl.uses_rs1 && id_ex_q.ctrl.uses_rs2
                                     && fwd_rs1 != FWD_NONE && fwd_rs2 != FWD_NONE);
  cp_fwd_store_data: cover property (@(posedge clk_i) disable iff (!rst_ni)
                                     ex_moves && id_ex_q.ctrl.mem_op == MEM_STORE && fwd_rs2 != FWD_NONE);
  cp_wb_bypass:      cover property (@(posedge clk_i) disable iff (!rst_ni)
                                     id_moves && mem_wb_q.valid && mem_wb_q.rd_we && mem_wb_q.rd != '0
                                     && ((id_ctrl.uses_rs1 && id_rs1 == mem_wb_q.rd)
                                      || (id_ctrl.uses_rs2 && id_rs2 == mem_wb_q.rd)));

  // --- Load-use and branch after load (4.2, 4.3) ------------------------------
  logic lu;
  assign lu = load_use && !stall && !redirect;
  cp_load_use_rs1:        cover property (@(posedge clk_i) disable iff (!rst_ni)
                                          lu && id_ctrl.uses_rs1 && id_rs1 == id_ex_q.rd);
  cp_load_use_rs2:        cover property (@(posedge clk_i) disable iff (!rst_ni)
                                          lu && id_ctrl.uses_rs2 && id_rs2 == id_ex_q.rd);
  cp_load_use_store_data: cover property (@(posedge clk_i) disable iff (!rst_ni)
                                          lu && id_ctrl.mem_op == MEM_STORE && id_rs2 == id_ex_q.rd);
  cp_branch_after_load:   cover property (@(posedge clk_i) disable iff (!rst_ni)
                                          lu && id_ctrl.branch inside {BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU});
  cp_jalr_after_load:     cover property (@(posedge clk_i) disable iff (!rst_ni)
                                          lu && id_ctrl.branch == BR_JALR);
  cp_redirect_while_stalled: cover property (@(posedge clk_i) disable iff (!rst_ni)
                                             ex_redirect && stall);

  // --- CSR sequences (P2.3) --------------------------------------------------------
  cp_csr_back_to_back: cover property (@(posedge clk_i) disable iff (!rst_ni)
                                       retire && prev_csr_q && is_csr_insn(ex_mem_q.instr));
  cp_csr_then_use:     cover property (@(posedge clk_i) disable iff (!rst_ni)
                                       retire && prev_csr_q && prev_csr_rd_q != '0
                                       && ((reads_rs1(ex_mem_q.instr) && ex_mem_q.instr[19:15] == prev_csr_rd_q)
                                        || (reads_rs2(ex_mem_q.instr) && ex_mem_q.instr[24:20] == prev_csr_rd_q)));
  cp_mret:             cover property (@(posedge clk_i) disable iff (!rst_ni) mret);
  cp_fence_i:          cover property (@(posedge clk_i) disable iff (!rst_ni) fence_i_o);

  // --- Stalls ------------------------------------------------------------------------
  cp_stall_mem_wait:   cover property (@(posedge clk_i) disable iff (!rst_ni) mem_wait);
  cp_stall_issue_wait: cover property (@(posedge clk_i) disable iff (!rst_ni) stall && !mem_wait);

  // --- Interrupts arriving during a stall or flush (P2.13) ----------------------
  cp_irq_rise_during_stall: cover property (@(posedge clk_i) disable iff (!rst_ni)
                                            stall && ({irq_external_i, irq_timer_i, irq_software_i} & ~lines_q) != '0);
  cp_irq_take_on_redirect:  cover property (@(posedge clk_i) disable iff (!rst_ni) irq_take && ex_redirect);
  cp_irq_take_ex_memop:     cover property (@(posedge clk_i) disable iff (!rst_ni)
                                            irq_take && ex_mem_op && !ex_self_exc);
  cp_irq_take_on_ldst:      cover property (@(posedge clk_i) disable iff (!rst_ni)
                                            irq_take && ex_mem_q.mem_op != MEM_NONE);
  cp_irq_defer_serial:      cover property (@(posedge clk_i) disable iff (!rst_ni)
                                            irq_pend && can_commit && is_serializing(ex_mem_q.sys_op));
  cp_irq_defer_dreq_held:   cover property (@(posedge clk_i) disable iff (!rst_ni)
                                            irq_pend && can_commit && irq_block);
  cp_exc_with_irq_pending:  cover property (@(posedge clk_i) disable iff (!rst_ni) trap_take && irq_pend);

  // --- Every exception and interrupt cause (one point each: Verilator merges
  // the iterations of a generate loop into one cover point) -----------------
  cp_exc_instr_misaligned:  cover property (@(posedge clk_i) disable iff (!rst_ni) trap_take && trap_code == EXC_INSTR_MISALIGNED);
  cp_exc_instr_access:      cover property (@(posedge clk_i) disable iff (!rst_ni) trap_take && trap_code == EXC_INSTR_ACCESS);
  cp_exc_illegal:           cover property (@(posedge clk_i) disable iff (!rst_ni) trap_take && trap_code == EXC_ILLEGAL);
  cp_exc_breakpoint:        cover property (@(posedge clk_i) disable iff (!rst_ni) trap_take && trap_code == EXC_BREAKPOINT);
  cp_exc_load_misaligned:   cover property (@(posedge clk_i) disable iff (!rst_ni) trap_take && trap_code == EXC_LOAD_MISALIGNED);
  cp_exc_load_access:       cover property (@(posedge clk_i) disable iff (!rst_ni) trap_take && trap_code == EXC_LOAD_ACCESS);
  cp_exc_store_misaligned:  cover property (@(posedge clk_i) disable iff (!rst_ni) trap_take && trap_code == EXC_STORE_MISALIGNED);
  cp_exc_store_access:      cover property (@(posedge clk_i) disable iff (!rst_ni) trap_take && trap_code == EXC_STORE_ACCESS);
  cp_exc_ecall:             cover property (@(posedge clk_i) disable iff (!rst_ni) trap_take && trap_code == EXC_ECALL_M);
  cp_irq_software:          cover property (@(posedge clk_i) disable iff (!rst_ni) irq_take && trap_code == IRQ_MSI);
  cp_irq_timer:             cover property (@(posedge clk_i) disable iff (!rst_ni) irq_take && trap_code == IRQ_MTI);
  cp_irq_external:          cover property (@(posedge clk_i) disable iff (!rst_ni) irq_take && trap_code == IRQ_MEI);

endmodule : core_cov

bind core_top core_cov u_core_cov (.*);
