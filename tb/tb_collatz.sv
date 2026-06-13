`timescale 1ns/1ps
`include "defines.v"
// tb_collatz.sv — Collatz sequence step counter for 8 values
//
// Tests: AND (parity check), LSRI (n/=2 even path), ADD+ADDI (3n+1 odd path),
//        INC (steps++), MOV (save n before multiply), CMP+BEQ (loop exit)
//
// Algorithm — collatz(R0=n) → step count in R1:
//   steps = 0
//   while n != 1:
//     if n & 1: n = 3n + 1   (odd:  MOV tmp,n; n+=n; n+=tmp; n++)
//     else:     n >>= 1       (even: LSRI n,n,#1)
//     steps++
//   return steps
//
// Register allocation (subroutine):
//   R0  — n (modified in-place)
//   R1  — steps (output)
//   R2  — constant 1
//   R3  — temp for 3n+1 (saves original n)
//   R14 — LR
//
// Memory layout (DMEM):
//   Source : words  64..71  (byte 0x100..0x11C) — 8 input values
//   Result : words 128..135 (byte 0x200..0x21C) — 8 step counts
//
// Word map:
//   Word 32 = 0x080  MOVI R5,#256
//   Word 33 = 0x084  MOVI R6,#512
//   Word 34 = 0x088  MOVI R7,#8
//   Word 35 = 0x08C  LDR  R0,[R5,0] ← loop top
//   Word 36 = 0x090  BL +7          → word 43
//   Word 37 = 0x094  STR  R1,[R6,0]
//   Word 38 = 0x098  ADDI R5,R5,#4
//   Word 39 = 0x09C  ADDI R6,R6,#4
//   Word 40 = 0x0A0  DEC  R7
//   Word 41 = 0x0A4  BNE  -6        → word 35  (25'h1FFFFFA)
//   Word 42 = 0x0A8  B AL #0        halt
//   ──── collatz subroutine ────
//   Word 43 = 0x0AC  PUSH R14
//   Word 44 = 0x0B0  MOVI R1,#0     steps = 0
//   Word 45 = 0x0B4  MOVI R2,#1     constant 1
//   Word 46 = 0x0B8  CMP  R0,R2    ← loop top: n vs 1
//   Word 47 = 0x0BC  BEQ  +11       → word 58 (done, n==1)
//   Word 48 = 0x0C0  AND  R3,R0,R2  R3 = n & 1  (Z=1 if even)
//   Word 49 = 0x0C4  BEQ  +6        → word 55 (even: LSRI)
//   Word 50 = 0x0C8  MOV  R3,R0     R3 = n        (odd body)
//   Word 51 = 0x0CC  ADD  R0,R0,R0  R0 = 2n
//   Word 52 = 0x0D0  ADD  R0,R0,R3  R0 = 3n
//   Word 53 = 0x0D4  ADDI R0,R0,#1  R0 = 3n+1
//   Word 54 = 0x0D8  B AL +2        → word 56 (skip LSRI)
//   Word 55 = 0x0DC  LSRI R0,R0,#1  n >>= 1       (even body; BEQ+6 target)
//   Word 56 = 0x0E0  INC  R1         steps++       (common)
//   Word 57 = 0x0E4  B AL -11       → word 46  (25'h1FFFFF5)
//   Word 58 = 0x0E8  POP  R14       (BEQ+11 target)
//   Word 59 = 0x0EC  BX   R14

module tb_collatz;

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
        $display("[APB] Loading Collatz program (8 values)...");
        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));

        addr = 32'h080;
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'd256)); addr+=4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd6, 4'd0, 16'd512)); addr+=4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd7, 4'd0, 16'd8));   addr+=4;
        // loop top (word 35)
        apb_write(addr, enc_load(4'd0, 4'd5, 16'd0));           addr+=4;
        apb_write(addr, enc_bl(20'd7));                          addr+=4; // BL +7 → word 43
        apb_write(addr, enc_store(4'd1, 4'd6, 16'd0));          addr+=4;
        apb_write(addr, enc_i(`FI_ADDI, 4'd5, 4'd5, 16'd4));   addr+=4;
        apb_write(addr, enc_i(`FI_ADDI, 4'd6, 4'd6, 16'd4));   addr+=4;
        apb_write(addr, enc_u(`FU_DEC, 4'd7));                  addr+=4;
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFFA));          addr+=4; // BNE -6
        apb_write(addr, enc_b(`COND_AL, 25'd0));                addr+=4; // halt
        // word 43 = 0x0AC
        apb_write(addr, enc_u(`FU_PUSH, 4'd14));                addr+=4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd0));   addr+=4; // steps=0
        apb_write(addr, enc_i(`FI_MOVI, 4'd2, 4'd0, 16'd1));   addr+=4; // R2=1
        // loop top (word 46)
        apb_write(addr, enc_r(`FR_CMP, 4'd0, 4'd0, 4'd2));     addr+=4; // CMP R0,R2
        apb_write(addr, enc_b(`COND_EQ, 25'd11));               addr+=4; // BEQ +11 → word 58
        apb_write(addr, enc_r(`FR_AND, 4'd3, 4'd0, 4'd2));     addr+=4; // AND R3,R0,R2
        apb_write(addr, enc_b(`COND_EQ, 25'd6));                addr+=4; // BEQ +6 → word 55
        // odd body (words 50-54)
        apb_write(addr, enc_r(`FR_MOV, 4'd3, 4'd0, 4'd0));     addr+=4; // MOV R3,R0
        apb_write(addr, enc_r(`FR_ADD, 4'd0, 4'd0, 4'd0));     addr+=4; // ADD R0,R0,R0 (2n)
        apb_write(addr, enc_r(`FR_ADD, 4'd0, 4'd0, 4'd3));     addr+=4; // ADD R0,R0,R3 (3n)
        apb_write(addr, enc_i(`FI_ADDI, 4'd0, 4'd0, 16'd1));   addr+=4; // ADDI R0,R0,#1 (3n+1)
        apb_write(addr, enc_b(`COND_AL, 25'd2));                addr+=4; // B AL +2 → word 56
        // even body (word 55, BEQ+6 target)
        apb_write(addr, enc_i(`FI_LSRI, 4'd0, 4'd0, 16'd1));   addr+=4; // LSRI R0,R0,#1
        // common (word 56)
        apb_write(addr, enc_u(`FU_INC, 4'd1));                  addr+=4; // INC R1
        apb_write(addr, enc_b(`COND_AL, 25'h1FFFFF5));          addr+=4; // B AL -11 → word 46
        // done (word 58, BEQ+11 target)
        apb_write(addr, enc_u(`FU_POP, 4'd14));                 addr+=4;
        apb_write(addr, enc_bx(4'd14));
        $display("[APB] Program load complete");
    endtask

    task automatic load_inputs();
        // n=27 famously takes 111 steps
        dut.u_dmem.mem[64]=32'd1;
        dut.u_dmem.mem[65]=32'd2;
        dut.u_dmem.mem[66]=32'd3;
        dut.u_dmem.mem[67]=32'd6;
        dut.u_dmem.mem[68]=32'd7;
        dut.u_dmem.mem[69]=32'd11;
        dut.u_dmem.mem[70]=32'd27;
        dut.u_dmem.mem[71]=32'd100;
        $display("[TB]  8 values loaded into DMEM[64..71]");
    endtask

    localparam logic [31:0] INPUTS[0:7]   = '{32'd1,32'd2,32'd3,32'd6,32'd7,32'd11,32'd27,32'd100};
    localparam logic [31:0] EXPECTED[0:7] = '{32'd0,32'd1,32'd7,32'd8,32'd16,32'd14,32'd111,32'd25};

    task automatic verify();
        int fail; logic [31:0] got;
        fail=0;
        $display("[MEM] Source : DMEM words  64..71  (byte 0x100..0x11C) — 8 input values");
        $display("[MEM] Result : DMEM words 128..135 (byte 0x200..0x21C) — 8 step counts");
        $display("------------------------------------------");
        $display("  i |   n | expected | actual | result");
        $display("------------------------------------------");
        for (int i=0; i<8; i++) begin
            got = dut.u_dmem.mem[128+i];
            if (got===EXPECTED[i])
                $display(" %0d | %3d |      %3d |    %3d | PASS",i,INPUTS[i],EXPECTED[i],got);
            else begin
                $display(" %0d | %3d |      %3d |    %3d | FAIL ***",i,INPUTS[i],EXPECTED[i],got);
                fail++;
            end
        end
        $display("------------------------------------------");
        if (fail==0) $display("*** PASS — all 8 Collatz step counts correct ***");
        else         $display("!!! FAIL — %0d wrong !!!", fail);
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
            begin repeat(3000) @(posedge clk); $display("TIMEOUT"); $finish; end
            begin
                forever @(posedge clk)
                    if (rst_n && dut.pc===prev_pc) begin
                        @(posedge clk);
                        $display("=== COLLATZ COMPLETE === PC=0x%08h cycles=%0d", dut.pc, cycle_count);
                        verify(); $finish;
                    end else prev_pc=dut.pc;
            end
        join
    end
    always_ff @(posedge clk) if (rst_n) cycle_count++;
    initial begin $dumpfile("tb_collatz.vcd"); $dumpvars(0,tb_collatz); end
endmodule
