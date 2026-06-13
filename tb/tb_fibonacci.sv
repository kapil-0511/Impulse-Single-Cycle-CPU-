`timescale 1ns/1ps
`include "defines.v"
// tb_fibonacci.sv — Compute F(n) for 8 values of n (0-indexed Fibonacci)
//
// Tests: ADD (F(i)+F(i+1)), MOV (shift rolling pair), DEC+BNE (loop),
//        TST+BEQ (n==0 edge case), BL/BX/PUSH/POP (subroutine)
//
// Algorithm — fib(R0=n) → F(n) in R1:
//   R1=0 (F(0)), R2=1 (F(1))
//   if n==0: return R1=0
//   repeat n times: R3=R1+R2; R1=R2; R2=R3
//   return R1
//
// Sequence: F(0)=0, F(1)=1, F(2)=1, F(3)=2, F(4)=3, F(5)=5, ...
//
// Memory layout (DMEM):
//   Source : words  64..71  (byte 0x100..0x11C) — 8 n values
//   Result : words 128..135 (byte 0x200..0x21C) — 8 F(n) values
//
// Word map:
//   Word 32 = 0x080  MOVI R5,#256
//   Word 33 = 0x084  MOVI R6,#512
//   Word 34 = 0x088  MOVI R7,#8
//   Word 35 = 0x08C  LDR  R0,[R5,0]  ← loop top
//   Word 36 = 0x090  BL +7           → word 43
//   Word 37 = 0x094  STR  R1,[R6,0]
//   Word 38 = 0x098  ADDI R5,R5,#4
//   Word 39 = 0x09C  ADDI R6,R6,#4
//   Word 40 = 0x0A0  DEC  R7
//   Word 41 = 0x0A4  BNE  -6         → word 35  (25'h1FFFFFA)
//   Word 42 = 0x0A8  B AL #0         halt
//   ──── fib subroutine ────
//   Word 43 = 0x0AC  PUSH R14
//   Word 44 = 0x0B0  MOVI R1,#0      F(0)
//   Word 45 = 0x0B4  MOVI R2,#1      F(1)
//   Word 46 = 0x0B8  TST  R0,R0      check n==0
//   Word 47 = 0x0BC  BEQ  +6         → word 53 (n==0: return 0)
//   Word 48 = 0x0C0  ADD  R3,R1,R2   F(i+2) = F(i)+F(i+1)  ← loop top
//   Word 49 = 0x0C4  MOV  R1,R2      R1 = F(i+1)
//   Word 50 = 0x0C8  MOV  R2,R3      R2 = F(i+2)
//   Word 51 = 0x0CC  DEC  R0
//   Word 52 = 0x0D0  BNE  -4         → word 48  (25'h1FFFFFC)
//   Word 53 = 0x0D4  POP  R14        ← BEQ target
//   Word 54 = 0x0D8  BX   R14

module tb_fibonacci;

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
        $display("[APB] Loading Fibonacci program (8 values)...");
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
        apb_write(addr, enc_store(4'd1, 4'd6, 16'd0));          addr+=4; // STR R1 (subroutine returns F(n) in R1)
        apb_write(addr, enc_i(`FI_ADDI, 4'd5, 4'd5, 16'd4));   addr+=4;
        apb_write(addr, enc_i(`FI_ADDI, 4'd6, 4'd6, 16'd4));   addr+=4;
        apb_write(addr, enc_u(`FU_DEC, 4'd7));                  addr+=4;
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFFA));          addr+=4; // BNE -6
        apb_write(addr, enc_b(`COND_AL, 25'd0));                addr+=4; // halt
        // word 43 = 0x0AC
        apb_write(addr, enc_u(`FU_PUSH, 4'd14));                addr+=4; // PUSH R14
        apb_write(addr, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd0));   addr+=4; // R1=F(0)=0
        apb_write(addr, enc_i(`FI_MOVI, 4'd2, 4'd0, 16'd1));   addr+=4; // R2=F(1)=1
        apb_write(addr, enc_r(`FR_TST,  4'd0, 4'd0, 4'd0));    addr+=4; // TST R0,R0
        apb_write(addr, enc_b(`COND_EQ, 25'd6));                addr+=4; // BEQ +6 → word 53
        // loop top (word 48)
        apb_write(addr, enc_r(`FR_ADD,  4'd3, 4'd1, 4'd2));    addr+=4; // ADD R3,R1,R2
        apb_write(addr, enc_r(`FR_MOV,  4'd1, 4'd2, 4'd0));    addr+=4; // MOV R1,R2
        apb_write(addr, enc_r(`FR_MOV,  4'd2, 4'd3, 4'd0));    addr+=4; // MOV R2,R3
        apb_write(addr, enc_u(`FU_DEC,  4'd0));                 addr+=4; // DEC R0
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFFC));          addr+=4; // BNE -4 → word 48
        // word 53 = 0x0D4 (BEQ target)
        apb_write(addr, enc_u(`FU_POP,  4'd14));                addr+=4; // POP R14
        apb_write(addr, enc_bx(4'd14));
        $display("[APB] Program load complete");
    endtask

    task automatic load_inputs();
        dut.u_dmem.mem[64]=32'd0;   // F(0)=0
        dut.u_dmem.mem[65]=32'd1;   // F(1)=1
        dut.u_dmem.mem[66]=32'd2;   // F(2)=1
        dut.u_dmem.mem[67]=32'd5;   // F(5)=5
        dut.u_dmem.mem[68]=32'd8;   // F(8)=21
        dut.u_dmem.mem[69]=32'd10;  // F(10)=55
        dut.u_dmem.mem[70]=32'd14;  // F(14)=377
        dut.u_dmem.mem[71]=32'd19;  // F(19)=4181
        $display("[TB]  n values loaded into DMEM[64..71]");
    endtask

    localparam logic [31:0] N_VAL[0:7]   = '{32'd0,32'd1,32'd2,32'd5,32'd8,32'd10,32'd14,32'd19};
    localparam logic [31:0] EXPECTED[0:7] = '{32'd0,32'd1,32'd1,32'd5,32'd21,32'd55,32'd377,32'd4181};

    task automatic verify();
        int fail; logic [31:0] got;
        fail=0;
        $display("[MEM] Source : DMEM words  64..71  (byte 0x100..0x11C) — 8 n values");
        $display("[MEM] Result : DMEM words 128..135 (byte 0x200..0x21C) — 8 F(n) values");
        $display("---------------------------------------------");
        $display("  i |  n | expected |   actual | result");
        $display("---------------------------------------------");
        for (int i=0; i<8; i++) begin
            got = dut.u_dmem.mem[128+i];
            if (got===EXPECTED[i])
                $display(" %0d | %2d |     %4d |     %4d | PASS",i,N_VAL[i],EXPECTED[i],got);
            else begin
                $display(" %0d | %2d |     %4d |     %4d | FAIL ***",i,N_VAL[i],EXPECTED[i],got);
                fail++;
            end
        end
        $display("---------------------------------------------");
        if (fail==0) $display("*** PASS — all 8 Fibonacci values correct ***");
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
            begin repeat(800) @(posedge clk); $display("TIMEOUT"); $finish; end
            begin
                forever @(posedge clk)
                    if (rst_n && dut.pc===prev_pc) begin
                        @(posedge clk);
                        $display("=== FIBONACCI COMPLETE === PC=0x%08h cycles=%0d", dut.pc, cycle_count);
                        verify(); $finish;
                    end else prev_pc=dut.pc;
            end
        join
    end
    always_ff @(posedge clk) if (rst_n) cycle_count++;
    initial begin $dumpfile("tb_fibonacci.vcd"); $dumpvars(0,tb_fibonacci); end
endmodule
