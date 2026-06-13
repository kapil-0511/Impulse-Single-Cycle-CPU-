`timescale 1ns/1ps
// ============================================================
// cond_check.v — Evaluate condition code against status flags
// Returns 1 if condition is satisfied.
// ============================================================
`include "defines.v"

module cond_check (
    input  [3:0] cond,    // branch instruction[28:25]
    input        Z,       // Zero flag
    input        N,       // Negative flag
    input        C,       // Carry flag
    input        V,       // Overflow flag
    output reg   pass     // 1 = condition satisfied
);
    always @(*) begin
        case (cond)
            `COND_EQ: pass = Z;
            `COND_NE: pass = ~Z;
            `COND_GT: pass = ~Z & (N == V);
            `COND_LT: pass = (N != V);
            `COND_GE: pass = (N == V);
            `COND_LE: pass = Z | (N != V);
            `COND_CS: pass = C;
            `COND_CC: pass = ~C;
            `COND_AL: pass = 1'b1;
            default:  pass = 1'b0;   // COND_NV and reserved
        endcase
    end
endmodule
