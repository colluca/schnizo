# Benchmarks for the Schnizo FREP mechanism

To run RTL experiments, first clean the current target build from the usual target folders.
This is required as the actual building is performed in the snitch_cluster space and not within the experiment folder.
The start the experiment with the desired steps (start from hw) from the experiment folder.
```
make clean-vsim
make vsim CFG_OVERRIDE=cfg/schnizo_xl.json DEBUG=ON -j
cd ./experiments/schnizo_frep/
./experiments.py --actions sw run roi -j
```

## Power
1. Run the experiments in a regular fashion
1. Place the Netlist, sdc and upf files from stage 15 at the place the bender.yml file expects it
1. Adapt the clock in the sdc to the desired clock.
1. Clean and regenerate the hw with the `--pls` option enabled.
1. Manually set the VCD range where the experiments are generated.
1. Then invoke the experiment script with the actions run and power as well as the `--pls` flag.

```
make clean-vsim
cd ./experiments/schnizo_frep/
rm -rf hw/
./experiments.py --actions hw run power --pls -j
```

The power action invokes the following from the nonfree repo.
```
make SIM_DIR=../target/snitch_cluster power
```

A manual process is explained in the Snitch tutorial.
