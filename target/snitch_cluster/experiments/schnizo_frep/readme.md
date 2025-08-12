# Benchmarks for the Schnizo FREP mechanism

To run RTL experiments, first clean the current target build from the usual target folders.
This is required as the actual building is performed in the snitch_cluster space and not within the experiment folder.
The start the experiment with the desired steps (start from hw) from the experiment folder.
```
make clean-vsim
cd ./experiments/schnizo_frep/
./experiments.py --actions hw sw run traces roi perf --hw schnizo -j
```
