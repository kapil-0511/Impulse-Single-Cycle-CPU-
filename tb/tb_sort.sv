`timescale 1ns/1ps
`include "defines.v"
// tb_sort.sv — In-place bubble sort, ascending (N=25)
//
// Algorithm:
//   for pass = N-1 downto 1:
//     ptr = base
//     for j = 0 to pass-1:
//       if A[j] > A[j+1]: swap(A[j], A[j+1])
//       ptr += 4
//
// Register allocation:
//   R0 — array base (byte, fixed = 256)
//   R1 — outer counter (N-1=24 downto 1)
//   R2 — inner counter (copy of R1 each pass)
//   R3 — inner pointer (byte, = R0 each pass, +4 per step)
//   R4 — A[j]
//   R5 — A[j+1]
//
// Memory layout (DMEM):
//   Source : words 64..88 (byte 0x100) — 25 unsorted elements (backdoor loaded)
//   Result : words 64..88 (byte 0x100) — sorted in-place, same location
//
// Word map:
//   Word  0 = 0x000  B AL +32
//   Word  6 = 0x018  RETI
//   Word  7 = 0x01C  RETI
//   Word 32 = 0x080  MOVI R0, #256
//   Word 33 = 0x084  MOVI R1, #24        outer counter = N-1
//   Word 34 = 0x088  MOV  R2, R1         ← OUTER LOOP TOP
//   Word 35 = 0x08C  MOV  R3, R0
//   Word 36 = 0x090  LDR  R4,[R3, 0]    ← INNER LOOP TOP
//   Word 37 = 0x094  LDR  R5,[R3, 4]
//   Word 38 = 0x098  CMP  R4, R5
//   Word 39 = 0x09C  BLE  +3             if A[j]<=A[j+1] skip swap → word 42
//   Word 40 = 0x0A0  STR  R5,[R3, 0]    swap
//   Word 41 = 0x0A4  STR  R4,[R3, 4]    swap
//   Word 42 = 0x0A8  ADDI R3,R3,#4      ← SKIP_SWAP
//   Word 43 = 0x0AC  DEC  R2
//   Word 44 = 0x0B0  BNE  -8            → word 36
//   Word 45 = 0x0B4  DEC  R1
//   Word 46 = 0x0B8  BNE  -12           → word 34
//   Word 47 = 0x0BC  B AL #0            halt
//
// Bubble sort comparisons: N*(N-1)/2 = 25*24/2 = 300  (~2400 cycles worst case)

module tb_sort;

    // ---- DUT signals ----
    logic        clk, pclk, rst_n, prst_n, irq, fiq;
    logic [31:0] paddr, pwdata, prdata;
    logic        psel, penable, pwrite, pready, pslverr;

    cpu_top dut (
        .clk     (clk),
        .pclk    (pclk),
        .rst_n   (rst_n),
        .prst_n  (prst_n),
        .irq     (irq),
        .fiq     (fiq),
        .paddr   (paddr),
        .psel    (psel),
        .penable (penable),
        .pwrite  (pwrite),
        .pwdata  (pwdata),
        .prdata  (prdata),
        .pready  (pready),
        .pslverr (pslverr)
    );

    initial clk  = 0; always #5  clk  = ~clk;
    initial pclk = 0; always #8  pclk = ~pclk;

    // ---- APB master task ----
    task automatic apb_write(input logic [31:0] addr, data);
        @(negedge pclk);
        paddr = addr; pwdata = data; pwrite = 1'b1; psel = 1'b1; penable = 1'b0;
        @(negedge pclk);
        penable = 1'b1;
        @(posedge pclk);
        while (!pready) @(posedge pclk);
        @(negedge pclk);
        psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
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
        $display("[APB] Loading bubble-sort program (N=25)...");

        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));

        addr = 32'h080;
        apb_write(addr, enc_i(`FI_MOVI, 4'd0, 4'd0, 16'd256));   addr += 4; // MOVI R0,#256
        apb_write(addr, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd24));    addr += 4; // MOVI R1,#24

        // outer loop top (word 34)
        apb_write(addr, enc_r(`FR_MOV, 4'd2, 4'd1, 4'd0));       addr += 4; // MOV  R2,R1
        apb_write(addr, enc_r(`FR_MOV, 4'd3, 4'd0, 4'd0));       addr += 4; // MOV  R3,R0

        // inner loop top (word 36)
        apb_write(addr, enc_load(4'd4, 4'd3, 16'd0));             addr += 4; // LDR  R4,[R3,0]
        apb_write(addr, enc_load(4'd5, 4'd3, 16'd4));             addr += 4; // LDR  R5,[R3,4]
        apb_write(addr, enc_r(`FR_CMP, 4'd0, 4'd4, 4'd5));       addr += 4; // CMP  R4,R5
        apb_write(addr, enc_b(`COND_LE, 25'd3));                  addr += 4; // BLE  +3 → word 42

        // swap (words 40-41)
        apb_write(addr, enc_store(4'd5, 4'd3, 16'd0));            addr += 4; // STR  R5,[R3,0]
        apb_write(addr, enc_store(4'd4, 4'd3, 16'd4));            addr += 4; // STR  R4,[R3,4]

        // skip_swap (word 42)
        apb_write(addr, enc_i(`FI_ADDI, 4'd3, 4'd3, 16'd4));     addr += 4; // ADDI R3,R3,#4
        apb_write(addr, enc_u(`FU_DEC, 4'd2));                    addr += 4; // DEC  R2
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFF8));            addr += 4; // BNE  -8 → word 36

        // outer loop end (words 45-46)
        apb_write(addr, enc_u(`FU_DEC, 4'd1));                    addr += 4; // DEC  R1
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFF4));            addr += 4; // BNE  -12 → word 34

        // halt (word 47)
        apb_write(addr, enc_b(`COND_AL, 25'd0));

        $display("[APB] Program load complete");
    endtask

    // ---- Array loader ----
    // 25 elements, range 18-951
    // Expected sorted: {18,29,38,57,83,127,162,204,245,315,398,427,472,534,581,
    //                   612,667,690,723,743,776,841,889,936,951}
    task automatic load_array();
        dut.u_dmem.mem[64]  = 32'd427; dut.u_dmem.mem[65]  = 32'd83;
        dut.u_dmem.mem[66]  = 32'd612; dut.u_dmem.mem[67]  = 32'd951;
        dut.u_dmem.mem[68]  = 32'd38;  dut.u_dmem.mem[69]  = 32'd776;
        dut.u_dmem.mem[70]  = 32'd245; dut.u_dmem.mem[71]  = 32'd18;
        dut.u_dmem.mem[72]  = 32'd534; dut.u_dmem.mem[73]  = 32'd889;
        dut.u_dmem.mem[74]  = 32'd162; dut.u_dmem.mem[75]  = 32'd723;
        dut.u_dmem.mem[76]  = 32'd57;  dut.u_dmem.mem[77]  = 32'd398;
        dut.u_dmem.mem[78]  = 32'd841; dut.u_dmem.mem[79]  = 32'd127;
        dut.u_dmem.mem[80]  = 32'd690; dut.u_dmem.mem[81]  = 32'd315;
        dut.u_dmem.mem[82]  = 32'd472; dut.u_dmem.mem[83]  = 32'd936;
        dut.u_dmem.mem[84]  = 32'd204; dut.u_dmem.mem[85]  = 32'd581;
        dut.u_dmem.mem[86]  = 32'd743; dut.u_dmem.mem[87]  = 32'd29;
        dut.u_dmem.mem[88]  = 32'd667;
        $display("[TB]  Array[0..24] loaded into DMEM[64..88]");
    endtask

    // ---- Checker ----
    localparam logic [31:0] SORTED [0:24] = '{
        32'd18,  32'd29,  32'd38,  32'd57,  32'd83,
        32'd127, 32'd162, 32'd204, 32'd245, 32'd315,
        32'd398, 32'd427, 32'd472, 32'd534, 32'd581,
        32'd612, 32'd667, 32'd690, 32'd723, 32'd743,
        32'd776, 32'd841, 32'd889, 32'd936, 32'd951
    };

    task automatic verify();
        int fail;
        fail = 0;
        $display("[MEM] Source : DMEM words 64..88 (byte 0x100..0x15F) — unsorted input");
        $display("[MEM] Result : DMEM words 64..88 (byte 0x100..0x15F) — sorted in-place");
        $display("--------------------------------------------------");
        $display("  i | expected | actual | result");
        $display("--------------------------------------------------");
        for (int i = 0; i < 25; i++) begin
            logic [31:0] got;
            got = dut.u_dmem.mem[64 + i];
            if (got === SORTED[i])
                $display(" %2d |     %4d |   %4d | PASS", i, SORTED[i], got);
            else begin
                $display(" %2d |     %4d |   %4d | FAIL ***", i, SORTED[i], got);
                fail++;
            end
        end
        $display("--------------------------------------------------");
        if (fail == 0) $display("*** PASS — all 25 elements sorted correctly ***");
        else           $display("!!! FAIL — %0d elements out of order !!!", fail);
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

        @(negedge clk);
        rst_n = 1'b1;
        $display("[TB]  rst_n=1 — CPU starting");

        fork
            begin
                repeat(3000) @(posedge clk);
                $display("TIMEOUT: 3000 cycles");
                $finish;
            end
            begin
                forever @(posedge clk) begin
                    if (rst_n && (dut.pc === prev_pc)) begin
                        @(posedge clk);
                        $display("=== SORT COMPLETE ===");
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

    always_ff @(posedge clk)
        if (rst_n) cycle_count++;

    initial begin
        $dumpfile("tb_sort.vcd");
        $dumpvars(0, tb_sort);
    end

endmodule
