# Schnizo Trace visualisation
This uses the Perfetto synthetic TrackEvent approach.

Needs the following python packages:
- protobuf
- protos
- perfetto

## Build the protobuf python module
There is a "merged" protobuf file in the official Perfetto protobuf definitions:
https://github.com/google/perfetto/blob/main/protos/perfetto/trace/perfetto_trace.proto

This protobuf must be compiled and then the module `perfetto_trace_pb2.py` can directly be used in python.

How to compile see official guide: https://protobuf.dev/getting-started/pythontutorial/

There are rumours that this extra step soon is not required anymore.
See https://github.com/google/perfetto/pull/1617.

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
    "--perfetto-trace", "logs/sz_trace_hart_00000.pb",
    "-o", "logs/sz_trace_hart_00000.txt"
  ],
},
```