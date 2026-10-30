# The paper's runs on an HPC

Job scripts for MARS, the University of Glasgow's cluster (Slurm, the `smp` partition of 128-core,
1 TB nodes, project `project0000`), adapted from EcoSISTEM's `examples/paper/hpc/`. Each job is one
threaded process on one node. Edit the `#SBATCH` lines, or override them on the command line, for
another machine.

| file | what |
| --- | --- |
| `env.sh` | the settings every job shares: Julia from juliaup, the depot and the runs on project storage (`AFRICA_HPC_ROOT`), threads from Slurm |
| `transfer.txt` | what a run reads that the repository does not hold, for `rsync` to copy into the clone |
| `setup.bash` | the one-off job: the environments instantiated and precompiled, `fetch.jl`, then the blessing test |
| `fetch.jl` | EarthEnv's land cover and Natural Earth's outline, into EcoSISTEM's cache in the depot |
| `run.bash` | one stage as a job, the script named, configured by the `AFRICA_*` variables it is submitted with |

## Once

1. On a login node, a Julia and a clone on project storage:

       module load apps/juliaup/1.18.9
       juliaup add 1.13.3
       cd /mnt/data/project0000/$USER
       git clone https://github.com/boydorr/AfricaPlants.jl AfricaPlants

2. From the root of a repository that has the data, its copy into the clone:

       rsync -av -r --files-from=examples/paper/hpc/transfer.txt . <host>:/mnt/data/project0000/<user>/AfricaPlants/

3. From the root of the clone, the set-up job:

       sbatch examples/paper/hpc/setup.bash

   It ends with the blessing test, so a pass means the data arrived intact and this machine gives
   the blessed values. If `fetch.jl` cannot reach EarthEnv or Natural Earth from the compute node,
   run it on the login node as its header says, and submit the set-up again.

## Runs

Every job names its cell size, and each experiment its own `AFRICA_SAVEDIR`, since a run's files
are named by seed alone. A job loads the clone as it starts, so leave the checkout alone while one
is queued. Source `env.sh` first, so that `AFRICA_HPC_ROOT` is set.

The **25 km trial** measures the memory a full-scale run needs: the burn-in at 25 km, stopped after
its first yearly records.

    source examples/paper/hpc/env.sh
    AFRICA_CELLSIZE=25km AFRICA_SAVEDIR=$AFRICA_HPC_ROOT/runs/trial-25km \
        sbatch --job-name=africa-trial --time=0-08:00:00 examples/paper/hpc/run.bash examples/paper/burnin.jl

The run builds the grid and its layers, then adds a row to `diversity_burnin_seed1.csv` in that
directory for every simulated year. Once two or more are there, `scancel` it. Its memory every five
minutes is in `africa-trial-<job ID>.memory`, and afterwards
`sacct -j <job ID> --format=JobID,MaxRSS,Elapsed,State` gives the peak; `OUT_OF_MEMORY` means
asking for more with `--mem`. `MaxRSS` is a high-water mark, and building the layers alone reaches
about 40 GiB on a laptop even at small scale, so the readings from before the first yearly record
are the build's: what the run and its recordings need is what rises above them.

A **replicate** is a burn-in, then the forward run and the control, which start from the same
settled state and can run side by side. Each stage is a job of its own, since one process running
two holds the first's ecosystem through the second:

    export AFRICA_CELLSIZE=50km AFRICA_SEED=1 AFRICA_SAVEDIR=$AFRICA_HPC_ROOT/runs/50km
    burnin=$(sbatch --parsable examples/paper/hpc/run.bash examples/paper/burnin.jl)
    sbatch --dependency=afterok:$burnin examples/paper/hpc/run.bash examples/paper/forward.jl
    AFRICA_NEUTRAL=true sbatch --dependency=afterok:$burnin examples/paper/hpc/run.bash examples/paper/forward.jl
