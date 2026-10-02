/* =============================================================================
 * link.ld - SoC C programs (docs/architecture.md P6.7)
 * Main memory: 64 KB at 0x8000_0000 (soc_pkg MEM_BASE/MEM_SIZE). The stack
 * grows down from the top of main memory.
 * ===========================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS
{
  .text.init : { *(.text.init) } > RAM
  .text      : { *(.text .text.*) } > RAM
  .rodata    : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data      : { *(.data .data.*) } > RAM
  .sdata     : {
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
  } > RAM
  .tohost    : { *(.tohost) } > RAM
  .bss (NOLOAD) : {
    _bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > RAM
  _end = .;
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
