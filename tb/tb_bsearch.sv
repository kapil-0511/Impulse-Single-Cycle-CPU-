`timescale 1ns/1ps
`include "defines.v"
// tb_bsearch.sv — Binary search over a 150-element sorted array (16 queries)
//
// Tests: LSRI (mid=(lo+hi)>>1), LSLI (byte offset mid*4), ADD (addr calc),
//        CMP+BEQ+BGT (comparison branches), ADDI (lo=mid+1), SUBI (hi=mid-1),
//        MOV (return index), MOVI #-1 (sign-ext 0xFFFF → not-found sentinel),
//        LDR with computed register address, BL/BX/PUSH/POP (subroutine)
//
// Array — 150 sorted integers in 4 groups with varying gap sizes:
//   Group 1 (idx   0.. 29): 3 + i*17          range     3..496   gap=17
//   Group 2 (idx  30.. 79): 600 + (i-30)*37   range   600..2413  gap=37
//   Group 3 (idx  80..119): 5000 + (i-80)*200 range  5000..12800 gap=200
//   Group 4 (idx 120..149): 20000+(i-120)*1000 range 20000..49000 gap=1000
//
// 16 search queries: 12 that hit the array + 4 that miss (expected = 0xFFFFFFFF)
//
// Subroutine bsearch(R0=target) → R0=index (0-based) or 0xFFFFFFFF if not found
//   Hardcodes array_base=0x100 (DMEM word 64) and N=150 internally.
//
// Register allocation (subroutine):
//   R0  — target (input) / result index (output)
//   R1  — lo
//   R2  — hi
//   R3  — array_base (0x100)
//   R4  — mid
//   R8  — mid*4 / byte address of arr[mid]
//   R9  — arr[mid] (loaded from DMEM)
//   R14 — LR
//
// Memory layout (DMEM):
//   Array   : words  64..213 (byte 0x100..0x354) — 150 sorted elements
//   Targets : words 216..231 (byte 0x360..0x39C) — 16 search keys
//   Results : words 232..247 (byte 0x3A0..0x3DC) — 16 found indices
//
// Word map:
//   Word 32 = 0x080  MOVI R5,#864           src (targets byte addr)
//   Word 33 = 0x084  MOVI R6,#928           dst (results byte addr)
//   Word 34 = 0x088  MOVI R7,#16            loop count
//   Word 35 = 0x08C  LDR  R0,[R5,0]        ← loop top
//   Word 36 = 0x090  BL +7                  → word 43
//   Word 37 = 0x094  STR  R0,[R6,0]
//   Word 38 = 0x098  ADDI R5,R5,#4
//   Word 39 = 0x09C  ADDI R6,R6,#4
//   Word 40 = 0x0A0  DEC  R7
//   Word 41 = 0x0A4  BNE  -6               → word 35  (25'h1FFFFFA)
//   Word 42 = 0x0A8  B AL #0               halt
//   ──── bsearch subroutine ────
//   Word 43 = 0x0AC  PUSH R14
//   Word 44 = 0x0B0  MOVI R1,#0            lo=0
//   Word 45 = 0x0B4  MOVI R2,#149          hi=N-1
//   Word 46 = 0x0B8  MOVI R3,#256          array_base=0x100
//   Word 47 = 0x0BC  CMP  R1,R2           ← loop top
//   Word 48 = 0x0C0  BGT  +16             → word 64 (not found: lo>hi)
//   Word 49 = 0x0C4  ADD  R4,R1,R2         lo+hi
//   Word 50 = 0x0C8  LSRI R4,R4,#1         mid=(lo+hi)>>1
//   Word 51 = 0x0CC  LSLI R8,R4,#2         mid*4
//   Word 52 = 0x0D0  ADD  R8,R8,R3         byte addr = base + mid*4
//   Word 53 = 0x0D4  LDR  R9,[R8,0]        arr[mid]
//   Word 54 = 0x0D8  CMP  R9,R0            arr[mid] vs target
//   Word 55 = 0x0DC  BEQ  +6              → word 61 (found)
//   Word 56 = 0x0E0  BGT  +3              → word 59 (arr[mid]>target → hi=mid-1)
//   Word 57 = 0x0E4  ADDI R1,R4,#1         lo=mid+1 (arr[mid]<target)
//   Word 58 = 0x0E8  B AL -11             → word 47  (25'h1FFFFF5)
//   Word 59 = 0x0EC  SUBI R2,R4,#1         hi=mid-1
//   Word 60 = 0x0F0  B AL -13             → word 47  (25'h1FFFFF3)
//   Word 61 = 0x0F4  MOV  R0,R4            return mid (BEQ target)
//   Word 62 = 0x0F8  POP  R14
//   Word 63 = 0x0FC  BX   R14
//   Word 64 = 0x100  MOVI R0,#0xFFFF       return -1 (BGT+16 target; sign-ext → 0xFFFFFFFF)
//   Word 65 = 0x104  POP  R14
//   Word 66 = 0x108  BX   R14

module tb_bsearch;

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
        $display("[APB] Loading binary search program (150-element array, 16 queries)...");
        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));

        addr = 32'h080;
        // MOVI R5,#864  (targets at DMEM word 216 = byte 0x360)
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'd864)); addr+=4;
        // MOVI R6,#928  (results at DMEM word 232 = byte 0x3A0)
        apb_write(addr, enc_i(`FI_MOVI, 4'd6, 4'd0, 16'd928)); addr+=4;
        apb_write(addr, enc_i(`FI_MOVI, 4'd7, 4'd0, 16'd16));  addr+=4;
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
        apb_write(addr, enc_i(`FI_MOVI, 4'd2, 4'd0, 16'd149)); addr+=4; // hi=149
        apb_write(addr, enc_i(`FI_MOVI, 4'd3, 4'd0, 16'd256)); addr+=4; // base=0x100
        // loop top (word 47 = 0x0BC)
        apb_write(addr, enc_r(`FR_CMP,  4'd0, 4'd1, 4'd2));    addr+=4; // CMP R1,R2
        apb_write(addr, enc_b(`COND_GT, 25'd16));               addr+=4; // BGT +16 → word 64
        apb_write(addr, enc_r(`FR_ADD,  4'd4, 4'd1, 4'd2));    addr+=4; // ADD R4,R1,R2
        apb_write(addr, enc_i(`FI_LSRI, 4'd4, 4'd4, 16'd1));   addr+=4; // LSRI R4,R4,#1 (mid)
        apb_write(addr, enc_i(`FI_LSLI, 4'd8, 4'd4, 16'd2));   addr+=4; // LSLI R8,R4,#2 (mid*4)
        apb_write(addr, enc_r(`FR_ADD,  4'd8, 4'd8, 4'd3));    addr+=4; // ADD  R8,R8,R3  (addr)
        apb_write(addr, enc_load(4'd9, 4'd8, 16'd0));           addr+=4; // LDR  R9,[R8,0]
        apb_write(addr, enc_r(`FR_CMP,  4'd0, 4'd9, 4'd0));    addr+=4; // CMP  R9,R0
        apb_write(addr, enc_b(`COND_EQ, 25'd6));                addr+=4; // BEQ  +6 → word 61
        apb_write(addr, enc_b(`COND_GT, 25'd3));                addr+=4; // BGT  +3 → word 59
        apb_write(addr, enc_i(`FI_ADDI, 4'd1, 4'd4, 16'd1));   addr+=4; // ADDI R1,R4,#1 (lo=mid+1)
        apb_write(addr, enc_b(`COND_AL, 25'h1FFFFF5));          addr+=4; // B AL -11 → word 47
        apb_write(addr, enc_i(`FI_SUBI, 4'd2, 4'd4, 16'd1));   addr+=4; // SUBI R2,R4,#1 (hi=mid-1)
        apb_write(addr, enc_b(`COND_AL, 25'h1FFFFF3));          addr+=4; // B AL -13 → word 47
        // word 61 = 0x0F4 (BEQ target: found)
        apb_write(addr, enc_r(`FR_MOV,  4'd0, 4'd4, 4'd0));    addr+=4; // MOV R0,R4 (return index)
        apb_write(addr, enc_u(`FU_POP,  4'd14));                addr+=4;
        apb_write(addr, enc_bx(4'd14));                          addr+=4; // word 63 = 0x0FC
        // word 64 = 0x100 (BGT+16 target: not found)
        apb_write(addr, enc_i(`FI_MOVI, 4'd0, 4'd0, 16'hFFFF)); addr+=4; // MOVI R0,#-1 (sign-ext)
        apb_write(addr, enc_u(`FU_POP,  4'd14));                addr+=4;
        apb_write(addr, enc_bx(4'd14));
        $display("[APB] Program load complete");
    endtask

    task automatic load_inputs();
        // Array: 4 groups of sorted integers with distinct gap sizes
        // Group 1 (idx 0..29):  val = 3 + i*17        (gap=17,  range 3..496)
        for (int i=0;   i<30;  i++) dut.u_dmem.mem[64+i] = 32'(3   + i*17);
        // Group 2 (idx 30..79): val = 600 + (i-30)*37 (gap=37,  range 600..2413)
        for (int i=30;  i<80;  i++) dut.u_dmem.mem[64+i] = 32'(600 + (i-30)*37);
        // Group 3 (idx 80..119): val = 5000+(i-80)*200 (gap=200, range 5000..12800)
        for (int i=80;  i<120; i++) dut.u_dmem.mem[64+i] = 32'(5000 + (i-80)*200);
        // Group 4 (idx 120..149): val = 20000+(i-120)*1000 (gap=1000, range 20000..49000)
        for (int i=120; i<150; i++) dut.u_dmem.mem[64+i] = 32'(20000 + (i-120)*1000);
        $display("[TB]  150-element sorted array loaded into DMEM[64..213]");

        // 16 search targets (12 present, 4 absent)
        dut.u_dmem.mem[216]=32'd3;      // arr[0]   = 3     → idx 0
        dut.u_dmem.mem[217]=32'd241;    // arr[14]  = 241   → idx 14
        dut.u_dmem.mem[218]=32'd496;    // arr[29]  = 496   → idx 29
        dut.u_dmem.mem[219]=32'd600;    // arr[30]  = 600   → idx 30
        dut.u_dmem.mem[220]=32'd1340;   // arr[50]  = 1340  → idx 50
        dut.u_dmem.mem[221]=32'd2413;   // arr[79]  = 2413  → idx 79
        dut.u_dmem.mem[222]=32'd5000;   // arr[80]  = 5000  → idx 80
        dut.u_dmem.mem[223]=32'd9000;   // arr[100] = 9000  → idx 100
        dut.u_dmem.mem[224]=32'd12800;  // arr[119] = 12800 → idx 119
        dut.u_dmem.mem[225]=32'd20000;  // arr[120] = 20000 → idx 120
        dut.u_dmem.mem[226]=32'd35000;  // arr[135] = 35000 → idx 135
        dut.u_dmem.mem[227]=32'd49000;  // arr[149] = 49000 → idx 149
        dut.u_dmem.mem[228]=32'd50;     // between arr[2]=37 and arr[3]=54  → NOT FOUND
        dut.u_dmem.mem[229]=32'd1000;   // between arr[40]=970 and arr[41]=1007 → NOT FOUND
        dut.u_dmem.mem[230]=32'd15000;  // between arr[119]=12800 and arr[120]=20000 → NOT FOUND
        dut.u_dmem.mem[231]=32'd30;     // between arr[1]=20 and arr[2]=37 → NOT FOUND
        $display("[TB]  16 search targets loaded into DMEM[216..231]");
    endtask

    localparam logic [31:0] TARGETS[0:15] = '{
        32'd3, 32'd241, 32'd496, 32'd600, 32'd1340, 32'd2413,
        32'd5000, 32'd9000, 32'd12800, 32'd20000, 32'd35000, 32'd49000,
        32'd50, 32'd1000, 32'd15000, 32'd30
    };
    localparam logic [31:0] EXPECTED[0:15] = '{
        32'd0,   32'd14,  32'd29,  32'd30,  32'd50,   32'd79,
        32'd80,  32'd100, 32'd119, 32'd120, 32'd135,  32'd149,
        32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF
    };

    task automatic verify();
        int fail; logic [31:0] got;
        fail=0;
        $display("[MEM] Array   : DMEM words  64..213 (byte 0x100..0x354) — 150 sorted elements");
        $display("[MEM] Targets : DMEM words 216..231 (byte 0x360..0x39C) — 16 search keys");
        $display("[MEM] Results : DMEM words 232..247 (byte 0x3A0..0x3DC) — 16 found indices");
        $display("--------------------------------------------------------------");
        $display("  i |  target |  expected  |    actual  | result");
        $display("--------------------------------------------------------------");
        for (int i=0; i<16; i++) begin
            got = dut.u_dmem.mem[232+i];
            if (got===EXPECTED[i]) begin
                if (EXPECTED[i]===32'hFFFF_FFFF)
                    $display(" %2d | %6d | NOT_FOUND  | NOT_FOUND  | PASS", i, TARGETS[i]);
                else
                    $display(" %2d | %6d |    idx=%3d |    idx=%3d | PASS", i, TARGETS[i], EXPECTED[i], got);
            end else begin
                $display(" %2d | %6d | 0x%08h | 0x%08h | FAIL ***", i, TARGETS[i], EXPECTED[i], got);
                fail++;
            end
        end
        $display("--------------------------------------------------------------");
        if (fail==0) $display("*** PASS — all 16 binary search results correct ***");
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
            begin repeat(5000) @(posedge clk); $display("TIMEOUT"); $finish; end
            begin
                forever @(posedge clk)
                    if (rst_n && dut.pc===prev_pc) begin
                        @(posedge clk);
                        $display("=== BSEARCH COMPLETE === PC=0x%08h cycles=%0d", dut.pc, cycle_count);
                        verify(); $finish;
                    end else prev_pc=dut.pc;
            end
        join
    end
    always_ff @(posedge clk) if (rst_n) cycle_count++;
    initial begin $dumpfile("tb_bsearch.vcd"); $dumpvars(0,tb_bsearch); end
endmodule
