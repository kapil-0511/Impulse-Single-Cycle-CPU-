`timescale 1ns/1ps
// ============================================================
// data_mem.v — Data RAM (synchronous write, asynchronous read)
// 1024 x 32-bit words (4 KB), word-aligned access
// ============================================================
`include "defines.v"

module data_mem (
    input         clk,
    input  [31:0] addr,       // byte address; lower 2 bits ignored
    input  [31:0] wdata,
    input         we,         // write enable
    output [31:0] rdata       // asynchronous read
);
    reg [31:0] mem [`DMEM_DEPTH-1:0];

    // Synchronous write
    always @(posedge clk) begin
        if (we)
            mem[addr[11:2]] <= wdata;
    end

    // Asynchronous read
    assign rdata = mem[addr[11:2]];
endmodule
