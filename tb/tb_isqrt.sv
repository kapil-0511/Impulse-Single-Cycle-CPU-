`timescale 1ns/1ps
`include "defines.v"
// tb_isqrt.sv — Integer square root via binary search: floor(sqrt(n)) for 10 values
//
// Tests: LSRI (mid = (lo+hi+1)>>1), MUL (mid*mid), SUBI (hi=mid-1),
//        MOV (lo=mid / result=lo), BGE (loop exit when lo>=hi), BLE (update branch)
//
// Algorithm — isqrt(R0=n) → result in R0:
//   lo=0, hi=32767
//   while lo < hi:
//     mid = (lo + hi + 1) >> 1        upper midpoint avoids infinite loop
//     if mid*mid <= n: lo = mid
//     else:            hi = mid - 1
//   return lo
//
// Register allocation (subroutine):
//   R0  — n (input/output: returns floor(sqrt(n)))
//   R1  — lo
//   R2  — hi
//   R3  — mid
//   R4  — mid*mid
//   R14 — LR
//
// Memory layout (DMEM):
//   Source : words  64..73  (byte 0x100..0x124) — 10 input values
//   Result : words 128..137 (byte 0x200..0x224) — 10 sqrt results
//
// Word map:
//   Word 32 = 0x080  MOVI R5,#256
//   Word 33 = 0x084  MOVI R6,#512
//   Word 34 = 0x088  MOVI R7,#10
//   Word 35 = 0x08C  LDR  R0,[R5,0] ← loop top
//   Word 36 = 0x090  BL +7          → word 43
//   Word 37 = 0x094  STR  R0,[R6,0]
//   Word 38 = 0x098  ADDI R5,R5,#4
//   Word 39 = 0x09C  ADDI R6,R6,#4
//   Word 40 = 0x0A0  DEC  R7
//   Word 41 = 0x0A4  BNE  -6        → word 35  (25'h1FFFFFA)
//   Word 42 = 0x0A8  B AL #0        halt
//   ──── isqrt subroutine ────
//   Word 43 = 0x0AC  PUSH R14
//   Word 44 = 0x0B0  MOVI R1,#0     lo = 0
//   Word 45 = 0x0B4  MOVI R2,#32767 hi = 0x7FFF (no sign-ext issue)
//   Word 46 = 0x0B8  CMP  R1,R2    ← loop top
//   Word 47 = 0x0BC  BGE  +12       → word 59 (done when lo>=hi)
//   Word 48 = 0x0C0  ADD  R3,R1,R2  lo+hi
//   Word 49 = 0x0C4  ADDI R3,R3,#1  lo+hi+1
//   Word 50 = 0x0C8  LSRI R3,R3,#1  mid = (lo+hi+1)>>1
//   Word 51 = 0x0CC  MUL  R4,R3,R3  mid*mid
//   Word 52 = 0x0D0  CMP  R4,R0     mid*mid vs n
//   Word 53 = 0x0D4  BLE  +3        → word 56 (mid*mid<=n: lo=mid)
//   Word 54 = 0x0D8  SUBI R2,R3,#1  hi = mid-1
//   Word 55 = 0x0DC  B AL -9        → word 46  (25'h1FFFFF7)
//   Word 56 = 0x0E0  MOV  R1,R3     lo = mid  (BLE target)
//   Word 57 = 0x0E4  B AL -11       → word 46  (25'h1FFFFF5)
//   Word 58 = (unused gap)
//   Word 59 = 0x0EC  MOV  R0,R1     result = lo  (BGE target)
//   Word 60 = 0x0F0  POP  R14
//   Word 61 = 0x0F4  BX   R14

module tb_isqrt;

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
        $display("[APB] Loading isqrt program (10 values)...");
        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));

        addr = 32'h080;
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'd256)); addr+=4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd6, 4'd0, 16'd512)); addr+=4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd7, 4'd0, 16'd10));  addr+=4;
        // loop top (word 35)
        apb_write(addr, enc_load(4'd0, 4'd5, 16'd0));           addr+=4;
        apb_write(addr, enc_bl(20'd7));                          addr+=4; // BL +7 → word 43
        apb_write(addr, enc_store(4'd0, 4'd6, 16'd0));          addr+=4;
        apb_write(addr, enc_i(`FI_ADDI, 4'd5, 4'd5, 16'd4));   addr+=4;
        apb_write(addr, enc_i(`FI_ADDI, 4'd6, 4'd6, 16'd4));   addr+=4;
        apb_write(addr, enc_u(`FU_DEC, 4'd7));                  addr+=4;
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFFA));          addr+=4; // BNE -6
        apb_write(addr, enc_b(`COND_AL, 25'd0));                addr+=4; // halt
        // word 43 = 0x0AC
        apb_write(addr, enc_u(`FU_PUSH, 4'd14));                addr+=4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd0));   addr+=4; // lo=0
        apb_write(addr, enc_i(`FI_MOVI, 4'd2, 4'd0, 16'd32767));addr+=4; // hi=32767
        // loop top (word 46)
        apb_write(addr, enc_r(`FR_CMP, 4'd0, 4'd1, 4'd2));     addr+=4; // CMP R1,R2
        apb_write(addr, enc_b(`COND_GE, 25'd12));               addr+=4; // BGE +12 → word 59
        apb_write(addr, enc_r(`FR_ADD, 4'd3, 4'd1, 4'd2));     addr+=4; // ADD R3,R1,R2
        apb_write(addr, enc_i(`FI_ADDI, 4'd3, 4'd3, 16'd1));   addr+=4; // ADDI R3,R3,#1
        apb_write(addr, enc_i(`FI_LSRI, 4'd3, 4'd3, 16'd1));   addr+=4; // LSRI R3,R3,#1
        apb_write(addr, enc_r(`FR_MUL, 4'd4, 4'd3, 4'd3));     addr+=4; // MUL R4,R3,R3
        apb_write(addr, enc_r(`FR_CMP, 4'd0, 4'd4, 4'd0));     addr+=4; // CMP R4,R0
        apb_write(addr, enc_b(`COND_LE, 25'd3));                addr+=4; // BLE +3 → word 56
        apb_write(addr, enc_i(`FI_SUBI, 4'd2, 4'd3, 16'd1));   addr+=4; // SUBI R2,R3,#1
        apb_write(addr, enc_b(`COND_AL, 25'h1FFFFF7));          addr+=4; // B AL -9 → word 46
        apb_write(addr, enc_r(`FR_MOV, 4'd1, 4'd3, 4'd0));     addr+=4; // MOV R1,R3 (lo=mid)
        apb_write(addr, enc_b(`COND_AL, 25'h1FFFFF5));          addr+=4; // B AL -11 → word 46
        // word 58 gap — write NOP (B NV)
        apb_write(addr, enc_b(4'h0, 25'd0));                    addr+=4; // NOP (COND_NV)
        // word 59 (BGE target)
        apb_write(addr, enc_r(`FR_MOV, 4'd0, 4'd1, 4'd0));     addr+=4; // MOV R0,R1 (result=lo)
        apb_write(addr, enc_u(`FU_POP, 4'd14));                 addr+=4;
        apb_write(addr, enc_bx(4'd14));
        $display("[APB] Program load complete");
    endtask

    task automatic load_inputs();
        dut.u_dmem.mem[64]=32'd0;       // isqrt=0
        dut.u_dmem.mem[65]=32'd1;       // isqrt=1
        dut.u_dmem.mem[66]=32'd2;       // isqrt=1
        dut.u_dmem.mem[67]=32'd9;       // isqrt=3
        dut.u_dmem.mem[68]=32'd16;      // isqrt=4
        dut.u_dmem.mem[69]=32'd100;     // isqrt=10
        dut.u_dmem.mem[70]=32'd255;     // isqrt=15
        dut.u_dmem.mem[71]=32'd10000;   // isqrt=100
        dut.u_dmem.mem[72]=32'd123456;  // isqrt=351
        dut.u_dmem.mem[73]=32'd1000000; // isqrt=1000
        $display("[TB]  10 values loaded into DMEM[64..73]");
    endtask

    localparam logic [31:0] INPUTS[0:9] = '{
        32'd0,32'd1,32'd2,32'd9,32'd16,32'd100,32'd255,32'd10000,32'd123456,32'd1000000};
    localparam logic [31:0] EXPECTED[0:9] = '{
        32'd0,32'd1,32'd1,32'd3,32'd4,32'd10,32'd15,32'd100,32'd351,32'd1000};

    task automatic verify();
        int fail; logic [31:0] got;
        fail=0;
        $display("[MEM] Source : DMEM words  64..73  (byte 0x100..0x124) — 10 input values");
        $display("[MEM] Result : DMEM words 128..137 (byte 0x200..0x224) — floor(sqrt(n))");
        $display("--------------------------------------------------");
        $display("  i |       n | expected | actual | result");
        $display("--------------------------------------------------");
        for (int i=0; i<10; i++) begin
            got = dut.u_dmem.mem[128+i];
            if (got===EXPECTED[i])
                $display(" %2d | %7d |      %3d |    %3d | PASS",i,INPUTS[i],EXPECTED[i],got);
            else begin
                $display(" %2d | %7d |      %3d |    %3d | FAIL ***",i,INPUTS[i],EXPECTED[i],got);
                fail++;
            end
        end
        $display("--------------------------------------------------");
        if (fail==0) $display("*** PASS — all 10 square roots correct ***");
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
            begin repeat(2500) @(posedge clk); $display("TIMEOUT"); $finish; end
            begin
                forever @(posedge clk)
                    if (rst_n && dut.pc===prev_pc) begin
                        @(posedge clk);
                        $display("=== ISQRT COMPLETE === PC=0x%08h cycles=%0d", dut.pc, cycle_count);
                        verify(); $finish;
                    end else prev_pc=dut.pc;
            end
        join
    end
    always_ff @(posedge clk) if (rst_n) cycle_count++;
    initial begin $dumpfile("tb_isqrt.vcd"); $dumpvars(0,tb_isqrt); end
endmodule
