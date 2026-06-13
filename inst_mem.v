`timescale 1ns/1ps
`include "defines.v"
// ============================================================
// inst_mem.v — Instruction memory, APB completer
//
// Clocks:
//   pclk   — APB bus clock (program loader)
//   clk    — CPU clock     (instruction fetch, async read)
//
// Reset policy:
//   prst_n — APB-side reset (PRESETn in APB spec)
//            blocks APB transactions when low
//            does NOT clear memory contents — data persists across reset
//
// Slave behavior (IHI0024D):
//   pready = prst_n & psel & penable  (stalled when prst_n=0)
//   write  : posedge pclk, gated by prst_n & psel & penable & pwrite
//   read   : cpu_inst and prdata are combinational (no clock)
// ============================================================
module inst_mem (
    input         pclk,      // APB clock
    input         prst_n,    // APB reset — blocks transactions only, no memory clear
    // --- CPU instruction fetch (asynchronous read) ---
    input  [31:0] cpu_addr,
    output [31:0] cpu_inst,
    // --- APB completer ---
    input  [31:0] paddr,
    input         psel,
    input         penable,
    input         pwrite,
    input  [31:0] pwdata,
    output [31:0] prdata,
    output        pready,
    output        pslverr
);
    reg [31:0] mem [`IMEM_DEPTH-1:0];

    // CPU async read — no reset dependency
    assign cpu_inst = mem[cpu_addr[11:2]];

    // APB slave outputs — stall (pready=0) when prst_n=0
    assign pready  = prst_n & psel & penable;
    assign prdata  = mem[paddr[11:2]];
    assign pslverr = 1'b0;

    // Write on APB ACCESS phase — blocked when prst_n=0
    always @(posedge pclk) begin
        if (prst_n & psel & penable & pwrite)
            mem[paddr[11:2]] <= pwdata;
    end

endmodule
