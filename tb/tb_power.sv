`timescale 1ns/1ps
`include "defines.v"
// tb_power.sv — Fast exponentiation: result = base^exp (8 pairs)
//
// Tests: MUL, AND (bit test), LSRI (exp >>= 1), TST+BEQ (exp==0 exit)
//
// Algorithm — power(R0=base, R1=exp) → result in R2:
//   R2 = 1
//   while exp != 0:
//     if exp & 1: result *= base
//     base *= base
//     exp >>= 1
//   return R2
//
// Register allocation (subroutine):
//   R0  — base (modified: base *= base each iteration)
//   R1  — exp  (modified: exp >>= 1 each iteration)
//   R2  — result (output, starts at 1)
//   R3  — temp  (exp & 1 bit test)
//   R14 — LR
//
// Memory layout (DMEM):
//   Input  : words  64..79  (byte 0x100..0x13C) — 8 pairs (base,exp) interleaved
//   Output : words 128..135 (byte 0x200..0x21C) — 8 results
//
// Word map:
//   Word  0 = 0x000  B AL +32
//   Word  6 = 0x018  RETI
//   Word  7 = 0x01C  RETI
//   Word 32 = 0x080  MOVI R5,#256   src base
//   Word 33 = 0x084  MOVI R6,#512   dst base
//   Word 34 = 0x088  MOVI R7,#8     loop count
//   Word 35 = 0x08C  LDR  R0,[R5,0] ← loop top
//   Word 36 = 0x090  LDR  R1,[R5,4]
//   Word 37 = 0x094  BL +7          LR=0x098, PC→0x0B0 (word 44)
//   Word 38 = 0x098  STR  R2,[R6,0] ← return path
//   Word 39 = 0x09C  ADDI R5,R5,#8
//   Word 40 = 0x0A0  ADDI R6,R6,#4
//   Word 41 = 0x0A4  DEC  R7
//   Word 42 = 0x0A8  BNE  -7        → word 35  (25'h1FFFFF9)
//   Word 43 = 0x0AC  B AL #0        halt
//   ──── power subroutine ────
//   Word 44 = 0x0B0  PUSH R14
//   Word 45 = 0x0B4  MOVI R2,#1     result = 1
//   Word 46 = 0x0B8  TST  R1,R1    ← loop top: check exp==0
//   Word 47 = 0x0BC  BEQ  +8        → word 55 (done)
//   Word 48 = 0x0C0  MOVI R3,#1     mask
//   Word 49 = 0x0C4  AND  R3,R1,R3  R3 = exp & 1  (Z=1 if bit0=0)
//   Word 50 = 0x0C8  BEQ  +2        → word 52 (skip result multiply)
//   Word 51 = 0x0CC  MUL  R2,R2,R0  result *= base
//   Word 52 = 0x0D0  MUL  R0,R0,R0  base *= base
//   Word 53 = 0x0D4  LSRI R1,R1,#1  exp >>= 1
//   Word 54 = 0x0D8  B AL -8        → word 46  (25'h1FFFFF8)
//   Word 55 = 0x0DC  POP  R14
//   Word 56 = 0x0E0  BX   R14

module tb_power;

    logic        clk, pclk, rst_n, prst_n, irq, fiq;
    logic [31:0] paddr, pwdata, prdata;
    logic        psel, penable, pwrite, pready, pslverr;

    cpu_top dut (
        .clk(clk), .pclk(pclk), .rst_n(rst_n), .prst_n(prst_n),
        .irq(irq), .fiq(fiq),
        .paddr(paddr), .psel(psel), .penable(penable), .pwrite(pwrite),
        .pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr)
    );

    initial clk  = 0; always #5  clk  = ~clk;
    initial pclk = 0; always #8  pclk = ~pclk;

    task automatic apb_write(input logic [31:0] addr, data);
        @(negedge pclk);
        paddr=addr; pwdata=data; pwrite=1; psel=1; penable=0;
        @(negedge pclk); penable=1;
        @(posedge pclk); while(!pready) @(posedge pclk);
        @(negedge pclk); psel=0; penable=0; pwrite=0;
    endtask

    function automatic logic [31:0] enc_r(input logic [4:0] fn, input logic [3:0] rd,rs1,rs2);
        return {`FMT_R, fn, rd, rs1, rs2, 12'd0};
    endfunction
    function automatic logic [31:0] enc_i(input logic [4:0] fn, input logic [3:0] rd,rs1, input logic [15:0] imm);
        return {`FMT_I, fn, rd, rs1, imm};
    endfunction
    function automatic logic [31:0] enc_load(input logic [3:0] rd,rb, input logic [15:0] off);
        return {`FMT_LOAD, `FL_LDR, rd, rb, off};
    endfunction
    function automatic logic [31:0] enc_store(input logic [3:0] rs,rb, input logic [15:0] off);
        return {`FMT_STORE, `FS_STR, rs, rb, off};
    endfunction
    function automatic logic [31:0] enc_b(input logic [3:0] cond, input logic [24:0] imm25);
        return {`FMT_BRANCH, cond, imm25};
    endfunction
    function automatic logic [31:0] enc_u(input logic [4:0] fn, input logic [3:0] rd);
        return {`FMT_UNARY, fn, rd, 20'd0};
    endfunction
    function automatic logic [31:0] enc_ctrl(input logic [4:0] fn);
        return {`FMT_CTRL, fn, 24'd0};
    endfunction
    function automatic logic [31:0] enc_bl(input logic [19:0] imm20);
        return {`FMT_JUMP, `FJ_BL, 4'b0, imm20};
    endfunction
    function automatic logic [31:0] enc_bx(input logic [3:0] rd);
        return {`FMT_JUMP, `FJ_BX, rd, 20'b0};
    endfunction

    task automatic load_program();
        int addr;
        $display("[APB] Loading fast-power program (8 pairs)...");
        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));

        addr = 32'h080;
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'd256)); addr+=4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd6, 4'd0, 16'd512)); addr+=4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd7, 4'd0, 16'd8));   addr+=4;
        // loop top word 35
        apb_write(addr, enc_load(4'd0, 4'd5, 16'd0));           addr+=4; // LDR R0 base
        apb_write(addr, enc_load(4'd1, 4'd5, 16'd4));           addr+=4; // LDR R1 exp
        apb_write(addr, enc_bl(20'd7));                          addr+=4; // BL +7 → word 44
        apb_write(addr, enc_store(4'd2, 4'd6, 16'd0));          addr+=4; // STR R2
        apb_write(addr, enc_i(`FI_ADDI, 4'd5, 4'd5, 16'd8));   addr+=4;
        apb_write(addr, enc_i(`FI_ADDI, 4'd6, 4'd6, 16'd4));   addr+=4;
        apb_write(addr, enc_u(`FU_DEC, 4'd7));                  addr+=4;
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFF9));          addr+=4; // BNE -7
        apb_write(addr, enc_b(`COND_AL, 25'd0));                addr+=4; // halt
        // word 44 = 0x0B0
        apb_write(addr, enc_u(`FU_PUSH, 4'd14));                addr+=4; // PUSH R14
        apb_write(addr, enc_i(`FI_MOVI, 4'd2, 4'd0, 16'd1));   addr+=4; // MOVI R2,#1
        // loop top word 46
        apb_write(addr, enc_r(`FR_TST, 4'd0, 4'd1, 4'd1));     addr+=4; // TST R1,R1
        apb_write(addr, enc_b(`COND_EQ, 25'd8));                addr+=4; // BEQ +8 → word 55
        apb_write(addr, enc_i(`FI_MOVI, 4'd3, 4'd0, 16'd1));   addr+=4; // MOVI R3,#1
        apb_write(addr, enc_r(`FR_AND, 4'd3, 4'd1, 4'd3));     addr+=4; // AND R3,R1,R3
        apb_write(addr, enc_b(`COND_EQ, 25'd2));                addr+=4; // BEQ +2 → word 52
        apb_write(addr, enc_r(`FR_MUL, 4'd2, 4'd2, 4'd0));     addr+=4; // MUL R2,R2,R0
        apb_write(addr, enc_r(`FR_MUL, 4'd0, 4'd0, 4'd0));     addr+=4; // MUL R0,R0,R0
        apb_write(addr, enc_i(`FI_LSRI, 4'd1, 4'd1, 16'd1));   addr+=4; // LSRI R1,R1,#1
        apb_write(addr, enc_b(`COND_AL, 25'h1FFFFF8));          addr+=4; // B AL -8 → word 46
        apb_write(addr, enc_u(`FU_POP, 4'd14));                 addr+=4; // POP R14
        apb_write(addr, enc_bx(4'd14));                                   // BX R14
        $display("[APB] Program load complete");
    endtask

    task automatic load_inputs();
        // pairs: (base, exp) → expected
        dut.u_dmem.mem[64]=32'd2;  dut.u_dmem.mem[65]=32'd10; // 1024
        dut.u_dmem.mem[66]=32'd3;  dut.u_dmem.mem[67]=32'd7;  // 2187
        dut.u_dmem.mem[68]=32'd5;  dut.u_dmem.mem[69]=32'd6;  // 15625
        dut.u_dmem.mem[70]=32'd7;  dut.u_dmem.mem[71]=32'd5;  // 16807
        dut.u_dmem.mem[72]=32'd2;  dut.u_dmem.mem[73]=32'd20; // 1048576
        dut.u_dmem.mem[74]=32'd10; dut.u_dmem.mem[75]=32'd5;  // 100000
        dut.u_dmem.mem[76]=32'd4;  dut.u_dmem.mem[77]=32'd8;  // 65536
        dut.u_dmem.mem[78]=32'd2;  dut.u_dmem.mem[79]=32'd0;  // 1 (exp=0 edge)
        $display("[TB]  8 (base,exp) pairs loaded into DMEM[64..79]");
    endtask

    localparam logic [31:0] BASE[0:7] = '{32'd2,32'd3,32'd5,32'd7,32'd2,32'd10,32'd4,32'd2};
    localparam logic [31:0] EXP [0:7] = '{32'd10,32'd7,32'd6,32'd5,32'd20,32'd5,32'd8,32'd0};
    localparam logic [31:0] EXPECTED[0:7] = '{
        32'd1024, 32'd2187, 32'd15625, 32'd16807,
        32'd1048576, 32'd100000, 32'd65536, 32'd1
    };

    task automatic verify();
        int fail;
        logic [31:0] got;
        fail = 0;
        $display("[MEM] Source : DMEM words  64..79  (byte 0x100..0x13C) — 8 (base,exp) pairs");
        $display("[MEM] Result : DMEM words 128..135 (byte 0x200..0x21C) — 8 results");
        $display("------------------------------------------------------");
        $display("  i | base | exp |    expected |      actual | result");
        $display("------------------------------------------------------");
        for (int i = 0; i < 8; i++) begin
            got = dut.u_dmem.mem[128+i];
            if (got === EXPECTED[i])
                $display(" %0d |  %3d | %3d | %11d | %11d | PASS",
                         i, BASE[i], EXP[i], EXPECTED[i], got);
            else begin
                $display(" %0d |  %3d | %3d | %11d | %11d | FAIL ***",
                         i, BASE[i], EXP[i], EXPECTED[i], got);
                fail++;
            end
        end
        $display("------------------------------------------------------");
        if (fail==0) $display("*** PASS — all 8 powers correct ***");
        else         $display("!!! FAIL — %0d results wrong !!!", fail);
    endtask

    int cycle_count; logic [31:0] prev_pc;
    initial begin
        irq=0; fiq=0; rst_n=0; prst_n=1;
        psel=0; penable=0; pwrite=0; paddr=0; pwdata=0;
        cycle_count=0; prev_pc=32'hFFFF_FFFF;
        repeat(2) @(posedge pclk); #1;
        load_program(); load_inputs();
        @(negedge clk); rst_n=1;
        $display("[TB]  rst_n=1 — CPU starting");
        fork
            begin repeat(800) @(posedge clk); $display("TIMEOUT"); $finish; end
            begin
                forever @(posedge clk)
                    if (rst_n && dut.pc===prev_pc) begin
                        @(posedge clk);
                        $display("=== POWER COMPLETE === PC=0x%08h cycles=%0d", dut.pc, cycle_count);
                        verify(); $finish;
                    end else prev_pc=dut.pc;
            end
        join
    end
    always_ff @(posedge clk) if (rst_n) cycle_count++;
    initial begin $dumpfile("tb_power.vcd"); $dumpvars(0,tb_power); end
endmodule
