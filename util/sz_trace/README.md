# Schnizo Trace visualisation
This uses the Perfetto synthetic TrackEvent approach.

Needs the following python packages:
- protobuf
- protos
- perfetto

## Run the trace generator
Use this VS Code launch configuration.
```
{
  "name": "SZ Tracer",
  "type": "debugpy",
  "request": "launch",
  "program": "${workspaceFolder}/util/sz_trace/sz_gen_trace.py",
  "console": "integratedTerminal",
  "cwd": "${workspaceFolder}/target/snitch_cluster",
  // "args": "${command:pickArgs}"
  "env": { // ${env:LLVM_BINROOT} not present in args?
    "LLVM_BINROOT": "/usr/scratch2/vulcano/colluca/tools/riscv32-snitch-llvm-almalinux8-15.0.0-snitch-0.1.0/bin"
  },
  "args": [
    "logs/sz_trace_hart_00000.dasm",
    "--mc-exec", "/usr/scratch2/vulcano/colluca/tools/riscv32-snitch-llvm-almalinux8-15.0.0-snitch-0.1.0/bin/llvm-mc",
    "--mc-flags", "\"-disassemble -mcpu=snitch\"",
    "--permissive",
    "--dma-trace", "dma_trace_00001_00000.log",
    "--dump-hart-perf", "logs/sz_hart_00000_perf.json",
    "--dump-dma-perf", "logs/sz_dma_00001_perf.json",
    "--perfetto-trace", "logs/sz_trace_hart_00000.tb",
    "-o", "logs/sz_trace_hart_00000.txt"
  ],
},
```