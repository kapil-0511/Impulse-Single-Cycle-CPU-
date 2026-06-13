`timescale 1ns/1ps
// ============================================================
// reg_file.v — 16 x 32-bit register file
//   R0-R12  : general purpose
//   R13     : Stack Pointer (SP)  — maintained externally in cpu_top
//   R14     : Link Register (LR)
//   R15     : general purpose (PC is a dedicated register in cpu_top)
//
// Two asynchronous read ports, one synchronous write port.
// ============================================================
`include "defines.v"

module reg_file (
    input         clk,
    input         rst_n,
    // Write port
    input  [3:0]  wr_addr,
    input  [31:0] wr_data,
    input         wr_en,
    // Read port A (Rs1 / Rd source)
    input  [3:0]  rd_addr_a,
    output reg [31:0] rd_data_a,
    // Read port B (Rs2 / Rd for store)
    input  [3:0]  rd_addr_b,
    output reg [31:0] rd_data_b
);

    reg [31:0] r0,  r1,  r2,  r3;
    reg [31:0] r4,  r5,  r6,  r7;
    reg [31:0] r8,  r9,  r10, r11;
    reg [31:0] r12, r13, r14, r15;

    // Synchronous write, synchronous reset
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r0  <= 32'd0; r1  <= 32'd0; r2  <= 32'd0; r3  <= 32'd0;
            r4  <= 32'd0; r5  <= 32'd0; r6  <= 32'd0; r7  <= 32'd0;
            r8  <= 32'd0; r9  <= 32'd0; r10 <= 32'd0; r11 <= 32'd0;
            r12 <= 32'd0; r13 <= 32'd0; r14 <= 32'd0; r15 <= 32'd0;
        end else if (wr_en) begin
            case (wr_addr)
                4'd0:  r0  <= wr_data;
                4'd1:  r1  <= wr_data;
                4'd2:  r2  <= wr_data;
                4'd3:  r3  <= wr_data;
                4'd4:  r4  <= wr_data;
                4'd5:  r5  <= wr_data;
                4'd6:  r6  <= wr_data;
                4'd7:  r7  <= wr_data;
                4'd8:  r8  <= wr_data;
                4'd9:  r9  <= wr_data;
                4'd10: r10 <= wr_data;
                4'd11: r11 <= wr_data;
                4'd12: r12 <= wr_data;
                4'd13: r13 <= wr_data;
                4'd14: r14 <= wr_data;
                4'd15: r15 <= wr_data;
            endcase
        end
    end

    // Asynchronous read — always @(*) so XSim re-evaluates on any register write
    always @(*) begin
        case (rd_addr_a)
            4'd0:  rd_data_a = r0;
            4'd1:  rd_data_a = r1;
            4'd2:  rd_data_a = r2;
            4'd3:  rd_data_a = r3;
            4'd4:  rd_data_a = r4;
            4'd5:  rd_data_a = r5;
            4'd6:  rd_data_a = r6;
            4'd7:  rd_data_a = r7;
            4'd8:  rd_data_a = r8;
            4'd9:  rd_data_a = r9;
            4'd10: rd_data_a = r10;
            4'd11: rd_data_a = r11;
            4'd12: rd_data_a = r12;
            4'd13: rd_data_a = r13;
            4'd14: rd_data_a = r14;
            4'd15: rd_data_a = r15;
            default: rd_data_a = 32'd0;
        endcase
    end

    always @(*) begin
        case (rd_addr_b)
            4'd0:  rd_data_b = r0;
            4'd1:  rd_data_b = r1;
            4'd2:  rd_data_b = r2;
            4'd3:  rd_data_b = r3;
            4'd4:  rd_data_b = r4;
            4'd5:  rd_data_b = r5;
            4'd6:  rd_data_b = r6;
            4'd7:  rd_data_b = r7;
            4'd8:  rd_data_b = r8;
            4'd9:  rd_data_b = r9;
            4'd10: rd_data_b = r10;
            4'd11: rd_data_b = r11;
            4'd12: rd_data_b = r12;
            4'd13: rd_data_b = r13;
            4'd14: rd_data_b = r14;
            4'd15: rd_data_b = r15;
            default: rd_data_b = 32'd0;
        endcase
    end

endmodule
