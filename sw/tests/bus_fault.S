# =============================================================================
# bus_fault.S - access faults at every memory-map boundary (architecture.md P5.6)
# -----------------------------------------------------------------------------
# Loads and stores to addresses just outside each region of the memory map
# (CLAUDE.md 5.4). On the SoC they reach the interconnect's error slave, which
# answers SLVERR; on the core testbench mem_model answers err. Each must trap
# precisely: mcause 5 (load) or 7 (store), mepc = the instruction, mtval = the
# address, the destination register unchanged. The APB windows themselves are
# not accessed (Phase 6 fills them).
#
#   CLINT 0x0200_0000..0x0200_FFFF   below: 0x01FF_FFFC   above: 0x0201_0000
#   PLIC  0x0C00_0000..0x0C3F_FFFF   below: 0x0BFF_FFFC   above: 0x0C40_0000
#   UART  0x1000_0000..0x1000_0FFF   below: 0x0FFF_FFFC
#   SPI   0x1000_1000..0x1000_1FFF   above: 0x1000_2000   (UART and SPI adjoin)
#   main  0x8000_0000..0x8000_FFFF   above: 0x8001_0000 (store; the load is in
#                                    tr_access_fault)
#   top of the address space:        0xFFFF_FFFC
#
# Stock environment + sw/common/irq_handler.h, interrupts enabled. Registers
# t5/t6 and s5-s11 belong to the trap handler.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

#define COMMA ,

# One faulting access at `addr`; the handler resumes at label 2.
#define BF_CASE(n, access, cause, addr)                                 \
  li   TESTNUM, n;                                                      \
  li   a1, addr;                                                        \
  li   a0, 0x5a5a;                                                      \
  li   a3, 0x77777777;                                                  \
  la   s11, 2f;                                                         \
1:access;                                                               \
  j    fail;                                                            \
2:bnez s11, fail;                                                       \
  li   t0, cause; bne s8, t0, fail;                                     \
  la   t0, 1b; bne s9, t0, fail;                                        \
  bne  s10, a1, fail;                                                   \
  li   t0, 0x5a5a; bne a0, t0, fail;

#define BF_LOAD(n, inst, addr)  BF_CASE(n, inst a0 COMMA 0(a1), CAUSE_LOAD_ACCESS, addr)
#define BF_STORE(n, inst, addr) BF_CASE(n, inst a3 COMMA 0(a1), CAUSE_STORE_ACCESS, addr)

RVTEST_RV32M
RVTEST_CODE_BEGIN

  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL

  BF_LOAD ( 2, lw,  0x01fffffc)      # below CLINT
  BF_STORE( 3, sw,  0x01fffffc)
  BF_LOAD ( 4, lw,  0x02010000)      # above CLINT
  BF_STORE( 5, sb,  0x02010000)
  BF_LOAD ( 6, lw,  0x0bfffffc)      # below PLIC
  BF_STORE( 7, sw,  0x0bfffffc)
  BF_LOAD ( 8, lhu, 0x0c400000)      # above PLIC
  BF_STORE( 9, sw,  0x0c400000)
  BF_LOAD (10, lw,  0x0ffffffc)      # below UART
  BF_STORE(11, sh,  0x0ffffffe)
  BF_LOAD (12, lbu, 0x10002000)      # above SPI
  BF_STORE(13, sw,  0x10002000)
  BF_STORE(14, sw,  0x80010000)      # above main memory
  BF_LOAD (15, lw,  0xfffffffc)      # top of the address space
  BF_STORE(16, sw,  0xfffffffc)

  # One exception per case above
  li   TESTNUM, 17
  li   t0, 15
  bne  s7, t0, fail

  TEST_PASSFAIL

  .align 2
trap_handler:
  DIRECTED_TRAP_HANDLER

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  IRQ_DATA

RVTEST_DATA_END
