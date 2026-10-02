// =============================================================================
// crt0.S - C runtime start-up for the SoC tests (docs/architecture.md P6.7)
// -----------------------------------------------------------------------------
// _start      sets gp and sp, clears .bss, installs trap_entry in mtvec, calls
//             main() and reports its return value through tohost (the
//             riscv-tests convention): 0 -> tohost = 1 (PASS); n != 0 ->
//             tohost = (n << 1) | 1 (FAIL, test number n).
// trap_entry  saves the caller-saved registers, calls
//             trap_dispatch(mcause, mepc, mtval) (trap.c), writes the mepc it
//             returns back and returns with mret.
// =============================================================================
  .section .text.init, "ax"
  .globl _start
_start:
  .option push
  .option norelax
  la    gp, __global_pointer$
  .option pop
  la    sp, _stack_top
  la    t0, trap_entry
  csrw  mtvec, t0
  la    t0, _bss_start
  la    t1, _bss_end
1:bgeu  t0, t1, 2f
  sw    zero, 0(t0)
  addi  t0, t0, 4
  j     1b
2:call  main
  li    t0, 1
  beqz  a0, 3f
  slli  t0, a0, 1
  ori   t0, t0, 1
3:la    t1, tohost
  sw    t0, 0(t1)
4:j     4b

  .align 2
  .globl trap_entry
trap_entry:
  addi  sp, sp, -64
  sw    ra,  0(sp)
  sw    t0,  4(sp)
  sw    t1,  8(sp)
  sw    t2, 12(sp)
  sw    a0, 16(sp)
  sw    a1, 20(sp)
  sw    a2, 24(sp)
  sw    a3, 28(sp)
  sw    a4, 32(sp)
  sw    a5, 36(sp)
  sw    a6, 40(sp)
  sw    a7, 44(sp)
  sw    t3, 48(sp)
  sw    t4, 52(sp)
  sw    t5, 56(sp)
  sw    t6, 60(sp)
  csrr  a0, mcause
  csrr  a1, mepc
  csrr  a2, mtval
  call  trap_dispatch
  csrw  mepc, a0
  lw    ra,  0(sp)
  lw    t0,  4(sp)
  lw    t1,  8(sp)
  lw    t2, 12(sp)
  lw    a0, 16(sp)
  lw    a1, 20(sp)
  lw    a2, 24(sp)
  lw    a3, 28(sp)
  lw    a4, 32(sp)
  lw    a5, 36(sp)
  lw    a6, 40(sp)
  lw    a7, 44(sp)
  lw    t3, 48(sp)
  lw    t4, 52(sp)
  lw    t5, 56(sp)
  lw    t6, 60(sp)
  addi  sp, sp, 64
  mret

// tohost/fromhost, as in riscv-tests (the testbench finds tohost by symbol)
  .section .tohost, "aw", @progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
