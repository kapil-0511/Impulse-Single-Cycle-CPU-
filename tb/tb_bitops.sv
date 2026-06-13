`timescale 1ns/1ps
`include "defines.v"
// tb_bitops.sv — Bit-manipulation suite: AND, OR, XOR, NOT, LSLI, LSRI (N=8 values)
//
// Tests: AND, OR, XOR, NOT, LSLI, LSRI (all untested by existing testbenches)
//
// For each of 8 input values, the program computes and stores 6 results:
//   result[0] = val & 0x0F
//   result[1] = val | 0xF0
//   result[2] = val ^ 0xFF
//   result[3] = ~val
//   result[4] = val << 4
//   result[5] = val >> 4
//
// Register allocation:
//   R0  — current value
//   R1  — AND result  (val & 0x0F)
//   R2  — OR  result  (val | 0xF0)
//   R3  — XOR result  (val ^ 0xFF)
//   R4  — NOT result  (~val)
//   R5  — LSL result  (val << 4)
//   R6  — LSR result  (val >> 4)
//   R7  — src pointer (advances +4 per element)
//   R8  — dst pointer (advances +24 per element; 6 results × 4 bytes)
//   R9  — loop count (8)
//   R10 — mask / temp
//
// Memory layout (DMEM):
//   Input  : words  64..71  (byte 0x100) — 8 values
//   Output : words 128..175 (byte 0x200) — 8×6 results (6 per element, packed)
//
// Word map:
//   Word  0 = 0x000  B AL +32
//   Word  6 = 0x018  RETI
//   Word  7 = 0x01C  RETI
//   Word 32 = 0x080  MOVI R7, #256   src base
//   Word 33 = 0x084  MOVI R8, #512   dst base
//   Word 34 = 0x088  MOVI R9, #8     loop count
//   Word 35 = 0x08C  LDR  R0,[R7,0] ← loop top
//   Word 36 = 0x090  MOVI R10,#0x0F
//   Word 37 = 0x094  AND  R1,R0,R10
//   Word 38 = 0x098  MOVI R10,#0xF0
//   Word 39 = 0x09C  OR   R2,R0,R10
//   Word 40 = 0x0A0  MOVI R10,#0xFF
//   Word 41 = 0x0A4  XOR  R3,R0,R10
//   Word 42 = 0x0A8  NOT  R4,R0
//   Word 43 = 0x0AC  LSLI R5,R0,#4
//   Word 44 = 0x0B0  LSRI R6,R0,#4
//   Word 45 = 0x0B4  STR  R1,[R8, 0]
//   Word 46 = 0x0B8  STR  R2,[R8, 4]
//   Word 47 = 0x0BC  STR  R3,[R8, 8]
//   Word 48 = 0x0C0  STR  R4,[R8,12]
//   Word 49 = 0x0C4  STR  R5,[R8,16]
//   Word 50 = 0x0C8  STR  R6,[R8,20]
//   Word 51 = 0x0CC  ADDI R7,R7,#4
//   Word 52 = 0x0D0  ADDI R8,R8,#24
//   Word 53 = 0x0D4  DEC  R9
//   Word 54 = 0x0D8  BNE  -19  → word 35  (25'h1FFFFED)
//   Word 55 = 0x0DC  B AL #0   halt

module tb_bitops;

    // ---- DUT signals ----
    logic        clk, pclk, rst_n, prst_n, irq, fiq;
    logic [31:0] paddr, pwdata, prdata;
    logic        psel, penable, pwrite, pready, pslverr;

    cpu_top dut (
        .clk     (clk),   .pclk    (pclk),
        .rst_n   (rst_n), .prst_n  (prst_n),
        .irq     (irq),   .fiq     (fiq),
        .paddr   (paddr), .psel    (psel),
        .penable (penable),.pwrite (pwrite),
        .pwdata  (pwdata), .prdata (prdata),
        .pready  (pready), .pslverr(pslverr)
    );

    initial clk  = 0; always #5  clk  = ~clk;
    initial pclk = 0; always #8  pclk = ~pclk;

    // ---- APB master task ----
    task automatic apb_write(input logic [31:0] addr, data);
        @(negedge pclk);
        paddr = addr; pwdata = data; pwrite = 1'b1; psel = 1'b1; penable = 1'b0;
        @(negedge pclk); penable = 1'b1;
        @(posedge pclk); while (!pready) @(posedge pclk);
        @(negedge pclk); psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
    endtask

    // ---- Encoding helpers ----
    function automatic logic [31:0] enc_r(input logic [4:0] funct, input logic [3:0] rd, rs1, rs2);
        return {`FMT_R, funct, rd, rs1, rs2, 12'd0};
    endfunction

    function automatic logic [31:0] enc_i(input logic [4:0] funct, input logic [3:0] rd, rs1, input logic [15:0] imm);
        return {`FMT_I, funct, rd, rs1, imm};
    endfunction

    function automatic logic [31:0] enc_load(input logic [3:0] rd, rb, input logic [15:0] off);
        return {`FMT_LOAD, `FL_LDR, rd, rb, off};
    endfunction

    function automatic logic [31:0] enc_store(input logic [3:0] rs, rb, input logic [15:0] off);
        return {`FMT_STORE, `FS_STR, rs, rb, off};
    endfunction

    function automatic logic [31:0] enc_b(input logic [3:0] cond, input logic [24:0] imm25);
        return {`FMT_BRANCH, cond, imm25};
    endfunction

    function automatic logic [31:0] enc_u(input logic [4:0] funct, input logic [3:0] rd);
        return {`FMT_UNARY, funct, rd, 20'd0};
    endfunction

    function automatic logic [31:0] enc_ctrl(input logic [4:0] funct);
        return {`FMT_CTRL, funct, 24'd0};
    endfunction

    // ---- Program loader ----
    task automatic load_program();
        int addr;
        $display("[APB] Loading bit-ops program (N=8)...");

        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));

        addr = 32'h080;
        apb_write(addr, enc_i(`FI_MOVI, 4'd7,  4'd0, 16'd256)); addr += 4; // MOVI R7,#256
        apb_write(addr, enc_i(`FI_MOVI, 4'd8,  4'd0, 16'd512)); addr += 4; // MOVI R8,#512
        apb_write(addr, enc_i(`FI_MOVI, 4'd9,  4'd0, 16'd8));   addr += 4; // MOVI R9,#8

        // loop top (word 35)
        apb_write(addr, enc_load(4'd0, 4'd7, 16'd0));                       addr += 4; // LDR R0,[R7,0]
        apb_write(addr, enc_i(`FI_MOVI, 4'd10, 4'd0, 16'h000F));           addr += 4; // MOVI R10,#0x0F
        apb_write(addr, enc_r(`FR_AND,  4'd1,  4'd0, 4'd10));               addr += 4; // AND  R1,R0,R10
        apb_write(addr, enc_i(`FI_MOVI, 4'd10, 4'd0, 16'h00F0));           addr += 4; // MOVI R10,#0xF0
        apb_write(addr, enc_r(`FR_OR,   4'd2,  4'd0, 4'd10));               addr += 4; // OR   R2,R0,R10
        apb_write(addr, enc_i(`FI_MOVI, 4'd10, 4'd0, 16'h00FF));           addr += 4; // MOVI R10,#0xFF
        apb_write(addr, enc_r(`FR_XOR,  4'd3,  4'd0, 4'd10));               addr += 4; // XOR  R3,R0,R10
        apb_write(addr, enc_r(`FR_NOT,  4'd4,  4'd0, 4'd0));                addr += 4; // NOT  R4,R0
        apb_write(addr, enc_i(`FI_LSLI, 4'd5,  4'd0, 16'd4));              addr += 4; // LSLI R5,R0,#4
        apb_write(addr, enc_i(`FI_LSRI, 4'd6,  4'd0, 16'd4));              addr += 4; // LSRI R6,R0,#4
        apb_write(addr, enc_store(4'd1,  4'd8, 16'd0));                     addr += 4; // STR  R1,[R8, 0]
        apb_write(addr, enc_store(4'd2,  4'd8, 16'd4));                     addr += 4; // STR  R2,[R8, 4]
        apb_write(addr, enc_store(4'd3,  4'd8, 16'd8));                     addr += 4; // STR  R3,[R8, 8]
        apb_write(addr, enc_store(4'd4,  4'd8, 16'd12));                    addr += 4; // STR  R4,[R8,12]
        apb_write(addr, enc_store(4'd5,  4'd8, 16'd16));                    addr += 4; // STR  R5,[R8,16]
        apb_write(addr, enc_store(4'd6,  4'd8, 16'd20));                    addr += 4; // STR  R6,[R8,20]
        apb_write(addr, enc_i(`FI_ADDI, 4'd7,  4'd7,  16'd4));             addr += 4; // ADDI R7,R7,#4
        apb_write(addr, enc_i(`FI_ADDI, 4'd8,  4'd8,  16'd24));            addr += 4; // ADDI R8,R8,#24
        apb_write(addr, enc_u(`FU_DEC,  4'd9));                             addr += 4; // DEC  R9
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFED));                     addr += 4; // BNE -19 → word 35
        apb_write(addr, enc_b(`COND_AL, 25'd0));                                       // B AL #0  halt

        $display("[APB] Program load complete");
    endtask

    // ---- Array loader ----
    // 8 diverse values spanning 0x0001..0xABCD
    task automatic load_array();
        dut.u_dmem.mem[64] = 32'h000000A5;
        dut.u_dmem.mem[65] = 32'h00005A5A;
        dut.u_dmem.mem[66] = 32'h000000FF;
        dut.u_dmem.mem[67] = 32'h00001234;
        dut.u_dmem.mem[68] = 32'h0000ABCD;
        dut.u_dmem.mem[69] = 32'h00000001;
        dut.u_dmem.mem[70] = 32'h0000F0F0;
        dut.u_dmem.mem[71] = 32'h00000000;
        $display("[TB]  Input[0..7] loaded into DMEM[64..71]");
    endtask

    // ---- Checker ----
    task automatic verify();
        int fail;
        logic [31:0] val, got_and, got_or, got_xor, got_not, got_lsl, got_lsr;
        logic [31:0] exp_and, exp_or,  exp_xor, exp_not, exp_lsl, exp_lsr;
        fail = 0;
        $display("[MEM] Source : DMEM words  64..71  (byte 0x100..0x11C) — 8 input values");
        $display("[MEM] Result : DMEM words 128..175 (byte 0x200..0x2BF) — 6 results per element");
        $display("-------------------------------------------------------------------------");
        $display(" i |   val    | AND_0F | OR_F0  | XOR_FF  |   NOT    | LSL4   | LSR4   ");
        $display("-------------------------------------------------------------------------");
        for (int i = 0; i < 8; i++) begin
            int base;
            base    = 128 + i*6;
            val     = dut.u_dmem.mem[64 + i];
            got_and = dut.u_dmem.mem[base + 0];
            got_or  = dut.u_dmem.mem[base + 1];
            got_xor = dut.u_dmem.mem[base + 2];
            got_not = dut.u_dmem.mem[base + 3];
            got_lsl = dut.u_dmem.mem[base + 4];
            got_lsr = dut.u_dmem.mem[base + 5];

            exp_and = val & 32'h0F;
            exp_or  = val | 32'hF0;
            exp_xor = val ^ 32'hFF;
            exp_not = ~val;
            exp_lsl = val << 4;
            exp_lsr = val >> 4;

            if (got_and !== exp_and) begin $display("  i=%0d AND FAIL: got %08h exp %08h", i, got_and, exp_and); fail++; end
            if (got_or  !== exp_or)  begin $display("  i=%0d OR  FAIL: got %08h exp %08h", i, got_or,  exp_or);  fail++; end
            if (got_xor !== exp_xor) begin $display("  i=%0d XOR FAIL: got %08h exp %08h", i, got_xor, exp_xor); fail++; end
            if (got_not !== exp_not) begin $display("  i=%0d NOT FAIL: got %08h exp %08h", i, got_not, exp_not); fail++; end
            if (got_lsl !== exp_lsl) begin $display("  i=%0d LSL FAIL: got %08h exp %08h", i, got_lsl, exp_lsl); fail++; end
            if (got_lsr !== exp_lsr) begin $display("  i=%0d LSR FAIL: got %08h exp %08h", i, got_lsr, exp_lsr); fail++; end

            if (got_and===exp_and && got_or===exp_or && got_xor===exp_xor &&
                got_not===exp_not && got_lsl===exp_lsl && got_lsr===exp_lsr)
                $display(" %0d | %08h | PASS   | PASS   | PASS    | PASS     | PASS   | PASS   ", i, val);
        end
        $display("-------------------------------------------------------------------------");
        if (fail == 0) $display("*** PASS — all 8 elements, all 6 operations correct ***");
        else           $display("!!! FAIL — %0d operation results wrong !!!", fail);
    endtask

    // ---- Simulation driver ----
    int          cycle_count;
    logic [31:0] prev_pc;

    initial begin
        irq = 0; fiq = 0;
        rst_n = 0; prst_n = 1;
        psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
        cycle_count = 0;
        prev_pc = 32'hFFFF_FFFF;

        repeat(2) @(posedge pclk); #1;
        load_program();
        load_array();

        @(negedge clk); rst_n = 1'b1;
        $display("[TB]  rst_n=1 — CPU starting");

        fork
            begin
                repeat(500) @(posedge clk);
                $display("TIMEOUT: 500 cycles");
                $finish;
            end
            begin
                forever @(posedge clk) begin
                    if (rst_n && (dut.pc === prev_pc)) begin
                        @(posedge clk);
                        $display("=== BITOPS COMPLETE ===");
                        $display("PC stopped at : 0x%08h", dut.pc);
                        $display("Cycles        : %0d",    cycle_count);
                        verify();
                        $finish;
                    end
                    prev_pc = dut.pc;
                end
            end
        join
    end

    always_ff @(posedge clk) if (rst_n) cycle_count++;

    initial begin
        $dumpfile("tb_bitops.vcd");
        $dumpvars(0, tb_bitops);
    end

endmodule
