# Impulse — Single-Cycle 32-bit CPU

A fully functional single-cycle RISC CPU implemented in Verilog, capable of executing a custom 32-bit ISA. Every instruction completes in one clock cycle (CPI = 1). The design includes a complete datapath, APB-based program loader, interrupt controller, and a suite of 13 SystemVerilog testbenches covering a wide range of algorithms.

---

## Features

- 32-bit custom RISC ISA
- Single-cycle datapath — CPI = 1
- 16 general-purpose 32-bit registers (R0–R15)
- Dedicated SP (R13), LR (R14), PC (R15 alias)
- ALU: ADD, SUB, MUL, AND, OR, XOR, NOT, LSL, LSR, CMP
- 7 condition codes: AL, EQ, NE, GT, LT, GE, LE
- APB slave interface for program and data loading
- IRQ / FIQ interrupt support with RETI return
- 256-word instruction memory and 256-word data memory
- 13 algorithm testbenches — all verified PASS

---

## Architecture

```
         ┌──────────┐     ┌─────────┐     ┌──────────┐
 APB ───►│ inst_mem │     │ control │◄───►│ cond_chk │
         └────┬─────┘     └────┬────┘     └──────────┘
              │                │
              ▼                ▼
         ┌─────────────────────────────────────────┐
         │              cpu_top (datapath)          │
         │  ┌──────────┐   ┌─────┐   ┌──────────┐  │
         │  │ reg_file │──►│ ALU │──►│ data_mem │  │
         │  └──────────┘   └─────┘   └──────────┘  │
         └─────────────────────────────────────────┘
```

| Property | Value |
|---|---|
| Architecture | Single-cycle |
| CPI | 1 |
| Register file | 16 × 32-bit (flat, r0–r15) |
| Instruction memory | 256 × 32-bit, APB write-loaded |
| Data memory | 256 × 32-bit, word-addressed |
| Interrupt modes | SYS / IRQ / FIQ |

---

## Instruction Set Summary

| Format | Instructions |
|---|---|
| R-type | ADD, SUB, MUL, AND, OR, XOR, NOT, LSL, LSR, CMP |
| I-type | MOVI, ADDI, SUBI |
| Load / Store | LDR, STR |
| Branch | B {cond}, BL, BX |
| Unary | INC, DEC, PUSH, POP |
| Control | NOP, RETI |

---

## Repository Structure

```
custom_cpu/
├── rtl/
│   ├── cpu_top.v        # Top-level datapath
│   ├── alu.v            # 32-bit ALU
│   ├── control.v        # Instruction decoder
│   ├── reg_file.v       # 16×32 register file
│   ├── cond_check.v     # Condition code evaluator
│   ├── inst_mem.v       # Instruction SRAM (APB-loaded)
│   ├── data_mem.v       # Data SRAM
│   └── defines.v        # ISA constants and opcodes
├── tb/
│   ├── tb_cpu.sv        # ISA integration test
│   ├── tb_memcpy.sv     # Memory copy loop
│   ├── tb_array_sum.sv  # Element-wise vector addition
│   ├── tb_minmax.sv     # Min / max linear scan
│   ├── tb_sort.sv       # Bubble sort
│   ├── tb_factorial.sv  # Factorial via BL/BX subroutine
│   ├── tb_bitops.sv     # Bitwise operations
│   ├── tb_gcd.sv        # GCD (Euclidean)
│   ├── tb_power.sv      # Fast exponentiation
│   ├── tb_isqrt.sv      # Integer square root
│   ├── tb_collatz.sv    # Collatz sequence
│   ├── tb_fibonacci.sv  # Fibonacci sequence
│   └── tb_bsearch.sv    # Binary search
└── sim/
    ├── setup_project.tcl  # Vivado / ModelSim project setup
    └── run_all.tcl        # Run all 13 testbenches in sequence
```

---

## Getting Started

### Requirements

- Vivado 2020.1 or later (for xsim behavioral simulation)  
  **or** ModelSim / Questa

### Vivado (GUI or Tcl console)

```tcl
# 1. Open Vivado, then in the Tcl console:
source C:/path/to/custom_cpu/sim/setup_project.tcl

# 2. Run all testbenches:
source C:/path/to/custom_cpu/sim/run_all.tcl
```

### ModelSim / Questa

```tcl
vsim -c -do "source sim/setup_project.tcl" -do "quit -f"
vsim -c -do "source sim/run_all.tcl"       -do "quit -f"
```

### Run a single testbench manually (Vivado)

```tcl
set_property top tb_sort [get_filesets sim_1]
launch_simulation
run all
close_simulation
```

---

## Testbench Results

| # | Testbench | Description | Timeout | Result |
|---|---|---|---|---|
| 1 | tb_cpu | ISA integration — all instruction categories | 500 cycles | PASS |
| 2 | tb_memcpy | 10-word memory copy loop | 500 cycles | PASS |
| 3 | tb_array_sum | C[i] = A[i] + B[i], N=25 | 700 cycles | PASS |
| 4 | tb_minmax | Min / max scan, N=25 | 600 cycles | PASS |
| 5 | tb_sort | Bubble sort ascending, N=25 | 3000 cycles | PASS |
| 6 | tb_factorial | 0! through 12! via BL/BX subroutine | 1200 cycles | PASS |
| 7 | tb_bitops | AND/OR/XOR/NOT/LSL/LSR × 8 inputs | 500 cycles | PASS |
| 8 | tb_gcd | Euclidean GCD × 6 pairs | 1000 cycles | PASS |
| 9 | tb_power | Binary exponentiation × 8 pairs | 800 cycles | PASS |
| 10 | tb_isqrt | Integer square root × 10 values | 2500 cycles | PASS |
| 11 | tb_collatz | Collatz steps-to-1 × 8 values | 3000 cycles | PASS |
| 12 | tb_fibonacci | Fibonacci F(n) × 8 values | 800 cycles | PASS |
| 13 | tb_bsearch | Binary search, 16 queries / 150-element array | 5000 cycles | PASS |

All 13 testbenches verified using Vivado 2025.1 xsim behavioral simulation.

---

## Simulation Notes

- Programs are loaded into instruction memory via the APB interface while `rst_n = 0`, `prst_n = 1`.
- Set `rst_n = 1` to start CPU execution.
- All testbenches call `$stop` (not `$finish`) so Vivado can cleanly close the simulation session between runs.
- Halt is detected when `dut.pc` is unchanged between two consecutive clock edges.
- VCD waveform files are generated automatically for each testbench.

---

## License

This project is released for educational and academic use.
