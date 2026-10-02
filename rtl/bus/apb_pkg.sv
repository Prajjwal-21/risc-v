// =============================================================================
// apb_pkg
// -----------------------------------------------------------------------------
// Purpose    : APB4 channel types (docs/architecture.md P5.2, D-047): one
//              request struct (bridge -> peripheral, with that peripheral's
//              PSEL) and one response struct (peripheral -> bridge).
// Interfaces : none (package).
// Timing     : n/a.
// =============================================================================
package apb_pkg;

  typedef struct packed {
    logic [31:0] paddr;
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [31:0] pwdata;
    logic [3:0]  pstrb;
    logic [2:0]  pprot;
  } apb_req_t;

  typedef struct packed {
    logic [31:0] prdata;
    logic        pready;
    logic        pslverr;
  } apb_rsp_t;

endpackage : apb_pkg
