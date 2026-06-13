`timescale 1ns/1ps
`include "defines.v"
// control.v — Two-level decoder: fmt [31:29] selects class, funct [28:24] selects operation.
// alu_op is a 4-bit internal code decoupled from ISA encoding.
module control (
    input  [2:0] fmt,
    input  [4:0] funct,
    output reg        use_imm,
    output reg        use_rd_src,
    output reg        reg_write,
    output reg        mem_read,
    output reg        mem_write,
    output reg [1:0]  wb_sel,
    output reg        branch,
    output reg        bl_op,
    output reg        bx_op,
    output reg        push_op,
    output reg        pop_op,
    output reg        reti_op,
    output reg        cmp_tst_op,
    output reg [3:0]  alu_op
);
    always @(*) begin
        use_imm    = 1'b0; use_rd_src = 1'b0;
        reg_write  = 1'b0; mem_read   = 1'b0; mem_write  = 1'b0;
        wb_sel     = `WB_ALU;
        branch     = 1'b0; bl_op      = 1'b0; bx_op      = 1'b0;
        push_op    = 1'b0; pop_op     = 1'b0;
        reti_op    = 1'b0; cmp_tst_op = 1'b0;
        alu_op     = `ALU_ADD;

        case (fmt)
            `FMT_R: begin
                case (funct)
                    `FR_ADD: begin reg_write=1'b1; alu_op=`ALU_ADD; end
                    `FR_SUB: begin reg_write=1'b1; alu_op=`ALU_SUB; end
                    `FR_MUL: begin reg_write=1'b1; alu_op=`ALU_MUL; end
                    `FR_AND: begin reg_write=1'b1; alu_op=`ALU_AND; end
                    `FR_OR:  begin reg_write=1'b1; alu_op=`ALU_OR;  end
                    `FR_XOR: begin reg_write=1'b1; alu_op=`ALU_XOR; end
                    `FR_NOT: begin reg_write=1'b1; alu_op=`ALU_NOT; end
                    `FR_CMP: begin cmp_tst_op=1'b1; alu_op=`ALU_SUB; end
                    `FR_TST: begin cmp_tst_op=1'b1; alu_op=`ALU_AND; end
                    `FR_LSL: begin reg_write=1'b1; alu_op=`ALU_LSL; end
                    `FR_LSR: begin reg_write=1'b1; alu_op=`ALU_LSR; end
                    `FR_ASR: begin reg_write=1'b1; alu_op=`ALU_ASR; end
                    `FR_MOV: begin reg_write=1'b1; alu_op=`ALU_MOV; end
                    default: ;
                endcase
            end

            `FMT_I: begin
                use_imm = 1'b1;
                case (funct)
                    `FI_ADDI: begin reg_write=1'b1; alu_op=`ALU_ADD;  end
                    `FI_SUBI: begin reg_write=1'b1; alu_op=`ALU_SUB;  end
                    `FI_MOVI: begin reg_write=1'b1; alu_op=`ALU_MOVB; end
                    `FI_LSLI: begin reg_write=1'b1; alu_op=`ALU_LSL;  end
                    `FI_LSRI: begin reg_write=1'b1; alu_op=`ALU_LSR;  end
                    `FI_ASRI: begin reg_write=1'b1; alu_op=`ALU_ASR;  end
                    default: ;
                endcase
            end

            `FMT_LOAD: begin
                use_imm   = 1'b1;
                reg_write = 1'b1;
                mem_read  = 1'b1;
                wb_sel    = `WB_MEM;
                alu_op    = `ALU_ADD;
            end

            `FMT_STORE: begin
                use_imm   = 1'b1;
                mem_write = 1'b1;
                alu_op    = `ALU_ADD;
            end

            `FMT_BRANCH: begin
                branch = 1'b1;
            end

            `FMT_UNARY: begin
                use_rd_src = 1'b1;
                case (funct)
                    `FU_INC:  begin reg_write=1'b1; alu_op=`ALU_INC; end
                    `FU_DEC:  begin reg_write=1'b1; alu_op=`ALU_DEC; end
                    `FU_PUSH: begin mem_write=1'b1; push_op=1'b1; end
                    `FU_POP:  begin reg_write=1'b1; mem_read=1'b1;
                                    pop_op=1'b1; wb_sel=`WB_MEM; end
                    default: ;
                endcase
            end

            `FMT_JUMP: begin
                case (funct)
                    `FJ_BL: begin
                        bl_op     = 1'b1;
                        reg_write = 1'b1;
                        wb_sel    = `WB_PC4;
                    end
                    `FJ_BX: begin
                        bx_op      = 1'b1;
                        use_rd_src = 1'b1;
                    end
                    default: ;
                endcase
            end

            `FMT_CTRL: begin
                case (funct)
                    `FC_NOP:  ;
                    `FC_RETI: reti_op = 1'b1;
                    default:  ;
                endcase
            end

            default: ;
        endcase
    end
endmodule
