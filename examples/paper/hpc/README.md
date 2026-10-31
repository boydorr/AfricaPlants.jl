# The paper's runs on an HPC

Job scripts for MARS, the University of Glasgow's cluster (Slurm, the `smp` partition of 128-core,
1 TB nodes, project `project0000`), adapted from EcoSISTEM's `examples/paper/hpc/`. Each job is one
threaded process on one node. Edit the `#SBATCH` lines, or override them on the command line, for
another machine.

| file | what |
| --- | --- |
| `env.sh` | the settings every job shares: Julia from juliaup, the depot, the registry and the runs on project storage (`AFRICA_HPC_ROOT`), the registry's port, threads from Slurm |
| `transfer.txt` | what a run reads that the repository does not hold, for `rsync` to copy into the clone |
| `setup.bash` | the one-off job: the environments instantiated and precompiled, `fetch.jl`, `setup.jl`, then the blessing test |
| `fetch.jl` | EarthEnv's land cover and Natural Earth's outline, into EcoSISTEM's cache in the depot |
| `setup.jl` | the data pipeline: `fair`, the local registry, and `fair init` run in the clone, which makes its `.fair/` |
| `fair-user.yaml` | who the runs are registered as, copied to `$AFRICA_HPC_ROOT/fair/user.yaml` and filled in |
| `run.bash` | one stage as a job, configured by the `AFRICA_*` variables it is submitted with: a pipeline run given its config (`examples/paper/burnin.yaml`, `forward.yaml`), a plain run given its script |

## Once

1. On a login node, a Julia and a clone on project storage:

       module load apps/juliaup/1.18.9
       juliaup add 1.13.3
       cd /mnt/data/project0000/$USER
       git clone https://github.com/boydorr/AfricaPlants.jl AfricaPlants

2. From the root of a repository that has the data, its copy into the clone:

       rsync -av -r --files-from=examples/paper/hpc/transfer.txt . <host>:/mnt/data/project0000/<user>/AfricaPlants/

3. Who the runs are registered as, in `$AFRICA_HPC_ROOT/fair/user.yaml` (`fair-user.yaml` says
   how). EcoSISTEM's paper set-up keeps it in the same place, so on an account that has run it
   there is nothing to do.

4. From the root of the clone, the set-up job:

       sbatch examples/paper/hpc/setup.bash

   It ends with the blessing test, so a pass means the data arrived intact and this machine gives
   the blessed values. If `fetch.jl` cannot reach EarthEnv or Natural Earth from the compute node,
   run it on the login node as its header says, and submit the set-up again. To set up the pipeline
   alone, `source examples/paper/hpc/env.sh` and run
   `julia --project=examples/paper examples/paper/hpc/setup.jl` on the login node.

`fair` keeps one local registry for each user, and initialising a clone points all of that user's
clones at the one it names. So this set-up uses the registry, data store and port EcoSISTEM's paper
set-up uses, under `$AFRICA_HPC_ROOT/fair`, and either finds there what the other made.

## Runs

Every job names its cell size, and each experiment its own `AFRICA_SAVEDIR`, since a run's files
are named by seed alone. A job loads the clone as it starts, so leave the checkout alone while one
is queued. Source `env.sh` first, so that `AFRICA_HPC_ROOT` is set.

A **pipeline run** - `run.bash` given `burnin.yaml` or `forward.yaml` - registers what it writes as
`AfricaPlants:CaseStudy/<grid>/<Stage>/<Output>_<seed>` (`examples/paper/pipeline.jl` says which),
the forward run and the control reading the settled state the burn-in registered. It records the
commit it ran, so the clone must be clean and its commit pushed. The registry runs on one node at a
time, EcoSISTEM's jobs' included, so pipeline jobs must not overlap: `run.bash` asks Slurm to run one
job of its name at a time (`--dependency=singleton`), and a `--dependency` given on the command line
replaces that, so add `singleton` to it. A job Slurm kills cannot stop the registry, which then stays
recorded on that job's node; the next job is refused with a message naming the record to delete.
What a run registered stays in the registry on MARS until it is pushed.

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
settled state. Each stage is a job of its own, since one process running two holds the first's
ecosystem through the second, and the three run one after another:

    export AFRICA_CELLSIZE=50km AFRICA_SEED=1 AFRICA_SAVEDIR=$AFRICA_HPC_ROOT/runs/50km
    burnin=$(sbatch --parsable examples/paper/hpc/run.bash examples/paper/burnin.yaml)
    sbatch --dependency=afterok:$burnin,singleton examples/paper/hpc/run.bash examples/paper/forward.yaml
    AFRICA_NEUTRAL=true sbatch --dependency=afterok:$burnin,singleton \
        examples/paper/hpc/run.bash examples/paper/forward.yaml
