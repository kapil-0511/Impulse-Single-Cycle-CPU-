`timescale 1ns/1ps
`include "defines.v"
// ============================================================
// alu.v — Arithmetic Logic Unit
//
// Input:  alu_op [3:0] — internal operation code from control unit
//                        (decoupled from ISA instruction encoding)
//         a — Port A data (Rs1, Rd for unary)
//         b — Port B data or sign-extended immediate
// Output: result, flags (Z/N/C/V), flags_we
// ============================================================
module alu (
    input      [3:0]  alu_op,
    input      [31:0] a,
    input      [31:0] b,
    output reg [31:0] result,
    output reg        alu_Z,
    output reg        alu_N,
    output reg        alu_C,
    output reg        alu_V,
    output reg        flags_we
);
    reg [32:0] tmp;
    wire [4:0] shamt = b[4:0];

    always @(*) begin
        result   = 32'd0;
        tmp      = 33'd0;
        alu_Z    = 1'b0;
        alu_N    = 1'b0;
        alu_C    = 1'b0;
        alu_V    = 1'b0;
        flags_we = 1'b0;

        case (alu_op)

            `ALU_ADD: begin
                tmp      = {1'b0, a} + {1'b0, b};
                result   = tmp[31:0];
                alu_C    = tmp[32];
                alu_V    = (~a[31] & ~b[31] & result[31]) |
                           ( a[31] &  b[31] & ~result[31]);
                flags_we = 1'b1;
            end

            `ALU_SUB: begin
                tmp      = {1'b0, a} - {1'b0, b};
                result   = tmp[31:0];
                alu_C    = ~tmp[32];   // C=1 means no borrow (a >= b unsigned)
                alu_V    = ( a[31] & ~b[31] & ~result[31]) |
                           (~a[31] &  b[31] &  result[31]);
                flags_we = 1'b1;
            end

            `ALU_MUL: begin
                result   = a * b;
                flags_we = 1'b1;
            end

            `ALU_AND: begin
                result   = a & b;
                flags_we = 1'b1;
            end

            `ALU_OR: begin
                result   = a | b;
                flags_we = 1'b1;
            end

            `ALU_XOR: begin
                result   = a ^ b;
                flags_we = 1'b1;
            end

            `ALU_NOT: begin
                result   = ~a;
                flags_we = 1'b1;
            end

            `ALU_LSL: begin
                result   = (shamt == 5'd0) ? a : (a << shamt);
                alu_C    = (shamt == 5'd0) ? 1'b0 :
                           (shamt <= 5'd31) ? a[32 - shamt] : 1'b0;
                flags_we = 1'b1;
            end

            `ALU_LSR: begin
                result   = (shamt == 5'd0) ? a : (a >> shamt);
                alu_C    = (shamt == 5'd0) ? 1'b0 :
                           (shamt <= 5'd31) ? a[shamt - 5'd1] : 1'b0;
                flags_we = 1'b1;
            end

            `ALU_ASR: begin
                result   = (shamt == 5'd0) ? a : ($signed(a) >>> shamt);
                alu_C    = (shamt == 5'd0) ? 1'b0 :
                           (shamt <= 5'd31) ? a[shamt - 5'd1] : a[31];
                flags_we = 1'b1;
            end

            `ALU_MOV:  result = a;          // MOV Rd, Rs1 — no flags

            `ALU_MOVB: result = b;          // MOVI Rd, #imm — no flags

            `ALU_INC: begin
                tmp      = {1'b0, a} + 33'd1;
                result   = tmp[31:0];
                alu_C    = tmp[32];
                alu_V    = ~a[31] & result[31];
                flags_we = 1'b1;
            end

            `ALU_DEC: begin
                tmp      = {1'b0, a} - 33'd1;
                result   = tmp[31:0];
                alu_C    = ~tmp[32];
                alu_V    = a[31] & ~result[31];
                flags_we = 1'b1;
            end

            default: result = 32'd0;
        endcase

        // Z and N always derived from result when flags_we is set
        if (flags_we) begin
            alu_Z = (result == 32'd0);
            alu_N = result[31];
        end
    end
endmodule
