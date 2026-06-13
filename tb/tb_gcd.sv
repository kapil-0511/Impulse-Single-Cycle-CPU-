`timescale 1ns/1ps
`include "defines.v"
// tb_gcd.sv — GCD via Euclidean subtraction, called as subroutine for 6 pairs
//
// Tests: SUB (R-type), BEQ, BGT, BL (multi-call loop), BX, PUSH, POP
//        Also tests that LR is correctly saved/restored across loop iterations.
//
// Algorithm — gcd(R0, R1):
//   while R0 != R1:
//     if R0 > R1: R0 -= R1
//     else:       R1 -= R0
//   return R0
//
// Register allocation (main):
//   R5 — src pointer (each pair = 8 bytes)
//   R6 — dst pointer (4 bytes per result)
//   R7 — loop count (6)
//
// Register allocation (subroutine):
//   R0 — a (first argument / return value)
//   R1 — b (second argument)
//   R14 — LR (PUSHed on entry, POPped on exit)
//
// Memory layout (DMEM):
//   Input  : words  64..75  (byte 0x100) — 6 pairs: a[0],b[0], a[1],b[1], ...
//   Output : words 128..133 (byte 0x200) — 6 GCD results
//
// Word map:
//   Word  0 = 0x000  B AL +32
//   Word  6 = 0x018  RETI
//   Word  7 = 0x01C  RETI
//   Word 32 = 0x080  MOVI R5, #256   src base
//   Word 33 = 0x084  MOVI R6, #512   dst base
//   Word 34 = 0x088  MOVI R7, #6     loop count
//   Word 35 = 0x08C  LDR  R0,[R5,0]  ← loop top
//   Word 36 = 0x090  LDR  R1,[R5,4]
//   Word 37 = 0x094  BL +7           LR=0x098, PC→0x0B0 (word 44)
//   Word 38 = 0x098  STR  R0,[R6,0]
//   Word 39 = 0x09C  ADDI R5,R5,#8
//   Word 40 = 0x0A0  ADDI R6,R6,#4
//   Word 41 = 0x0A4  DEC  R7
//   Word 42 = 0x0A8  BNE  -7         → word 35  (25'h1FFFFF9)
//   Word 43 = 0x0AC  B AL #0         halt
//   ──── gcd subroutine ────
//   Word 44 = 0x0B0  PUSH R14
//   Word 45 = 0x0B4  CMP  R0,R1      ← gcd loop top
//   Word 46 = 0x0B8  BEQ  +6         → word 52 (done)
//   Word 47 = 0x0BC  BGT  +3         → word 50 (a>b: a-=b)
//   Word 48 = 0x0C0  SUB  R1,R1,R0   b -= a  (a < b path)
//   Word 49 = 0x0C4  B AL -4         → word 45  (25'h1FFFFFC)
//   Word 50 = 0x0C8  SUB  R0,R0,R1   a -= b  (a > b path; reached via BGT)
//   Word 51 = 0x0CC  B AL -6         → word 45  (25'h1FFFFFA)
//   Word 52 = 0x0D0  POP  R14
//   Word 53 = 0x0D4  BX   R14

module tb_gcd;

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

    // BL #imm20 — word offset; LR = PC+4, PC = PC + imm20*4
    function automatic logic [31:0] enc_bl(input logic [19:0] imm20);
        return {`FMT_JUMP, `FJ_BL, 4'b0, imm20};
    endfunction

    // BX Rd — PC = Rd
    function automatic logic [31:0] enc_bx(input logic [3:0] rd);
        return {`FMT_JUMP, `FJ_BX, rd, 20'b0};
    endfunction

    // ---- Program loader ----
    task automatic load_program();
        int addr;
        $display("[APB] Loading GCD program (6 pairs)...");

        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));

        // Main (word 32)
        addr = 32'h080;
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'd256)); addr += 4; // MOVI R5,#256
        apb_write(addr, enc_i(`FI_MOVI, 4'd6, 4'd0, 16'd512)); addr += 4; // MOVI R6,#512
        apb_write(addr, enc_i(`FI_MOVI, 4'd7, 4'd0, 16'd6));   addr += 4; // MOVI R7,#6

        // loop top (word 35)
        apb_write(addr, enc_load(4'd0, 4'd5, 16'd0));           addr += 4; // LDR  R0,[R5,0]
        apb_write(addr, enc_load(4'd1, 4'd5, 16'd4));           addr += 4; // LDR  R1,[R5,4]
        apb_write(addr, enc_bl(20'd7));                          addr += 4; // BL +7 → word 44
        apb_write(addr, enc_store(4'd0, 4'd6, 16'd0));          addr += 4; // STR  R0,[R6,0]
        apb_write(addr, enc_i(`FI_ADDI, 4'd5, 4'd5, 16'd8));   addr += 4; // ADDI R5,R5,#8
        apb_write(addr, enc_i(`FI_ADDI, 4'd6, 4'd6, 16'd4));   addr += 4; // ADDI R6,R6,#4
        apb_write(addr, enc_u(`FU_DEC, 4'd7));                  addr += 4; // DEC  R7
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFF9));          addr += 4; // BNE -7 → word 35
        apb_write(addr, enc_b(`COND_AL, 25'd0));                addr += 4; // B AL #0  halt
        // addr is now 0x0B0 = word 44 ✓

        // GCD subroutine (word 44)
        apb_write(addr, enc_u(`FU_PUSH, 4'd14));                addr += 4; // PUSH R14
        // gcd loop top (word 45)
        apb_write(addr, enc_r(`FR_CMP, 4'd0, 4'd0, 4'd1));     addr += 4; // CMP  R0,R1
        apb_write(addr, enc_b(`COND_EQ, 25'd6));                addr += 4; // BEQ +6 → word 52
        apb_write(addr, enc_b(`COND_GT, 25'd3));                addr += 4; // BGT +3 → word 50
        apb_write(addr, enc_r(`FR_SUB, 4'd1, 4'd1, 4'd0));     addr += 4; // SUB R1,R1,R0  (b-=a)
        apb_write(addr, enc_b(`COND_AL, 25'h1FFFFFC));          addr += 4; // B AL -4 → word 45
        // word 50 (BGT target)
        apb_write(addr, enc_r(`FR_SUB, 4'd0, 4'd0, 4'd1));     addr += 4; // SUB R0,R0,R1  (a-=b)
        apb_write(addr, enc_b(`COND_AL, 25'h1FFFFFA));          addr += 4; // B AL -6 → word 45
        // word 52 (BEQ target)
        apb_write(addr, enc_u(`FU_POP, 4'd14));                 addr += 4; // POP  R14
        apb_write(addr, enc_bx(4'd14));                                     // BX   R14

        $display("[APB] Program load complete");
    endtask

    // ---- Input loader ----
    // 6 pairs: (a, b) at DMEM words 64..75
    // Expected GCDs: 6, 21, 25, 120, 1, 36
    task automatic load_inputs();
        dut.u_dmem.mem[64]  = 32'd48;   dut.u_dmem.mem[65]  = 32'd18;   // gcd=6
        dut.u_dmem.mem[66]  = 32'd252;  dut.u_dmem.mem[67]  = 32'd105;  // gcd=21
        dut.u_dmem.mem[68]  = 32'd100;  dut.u_dmem.mem[69]  = 32'd75;   // gcd=25
        dut.u_dmem.mem[70]  = 32'd360;  dut.u_dmem.mem[71]  = 32'd240;  // gcd=120
        dut.u_dmem.mem[72]  = 32'd17;   dut.u_dmem.mem[73]  = 32'd13;   // gcd=1
        dut.u_dmem.mem[74]  = 32'd144;  dut.u_dmem.mem[75]  = 32'd36;   // gcd=36
        $display("[TB]  6 input pairs loaded into DMEM[64..75]");
    endtask

    // ---- Checker ----
    localparam logic [31:0] EXPECTED [0:5] = '{32'd6, 32'd21, 32'd25, 32'd120, 32'd1, 32'd36};
    localparam logic [31:0] PAIR_A   [0:5] = '{32'd48, 32'd252, 32'd100, 32'd360, 32'd17, 32'd144};
    localparam logic [31:0] PAIR_B   [0:5] = '{32'd18, 32'd105, 32'd75,  32'd240, 32'd13, 32'd36};

    task automatic verify();
        int fail;
        logic [31:0] got;
        fail = 0;
        $display("[MEM] Source : DMEM words  64..75  (byte 0x100..0x12C) — 6 pairs (a,b)");
        $display("[MEM] Result : DMEM words 128..133 (byte 0x200..0x214) — 6 GCD results");
        $display("----------------------------------------------");
        $display("  i |   a |   b | expected | actual | result");
        $display("----------------------------------------------");
        for (int i = 0; i < 6; i++) begin
            got = dut.u_dmem.mem[128 + i];
            if (got === EXPECTED[i])
                $display(" %0d | %3d | %3d |      %3d |    %3d | PASS",
                         i, PAIR_A[i], PAIR_B[i], EXPECTED[i], got);
            else begin
                $display(" %0d | %3d | %3d |      %3d |    %3d | FAIL ***",
                         i, PAIR_A[i], PAIR_B[i], EXPECTED[i], got);
                fail++;
            end
        end
        $display("----------------------------------------------");
        if (fail == 0) $display("*** PASS — all 6 GCDs correct ***");
        else           $display("!!! FAIL — %0d GCDs wrong !!!", fail);
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
        load_inputs();

        @(negedge clk); rst_n = 1'b1;
        $display("[TB]  rst_n=1 — CPU starting");

        fork
            begin
                repeat(1000) @(posedge clk);
                $display("TIMEOUT: 1000 cycles");
                $finish;
            end
            begin
                forever @(posedge clk) begin
                    if (rst_n && (dut.pc === prev_pc)) begin
                        @(posedge clk);
                        $display("=== GCD COMPLETE ===");
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
        $dumpfile("tb_gcd.vcd");
        $dumpvars(0, tb_gcd);
    end

endmodule
