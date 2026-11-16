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
| `setup.jl` | the data pipeline: `fair`, the local registry, and `fair"init"` run in the clone, which makes its `.fair/` |
| `fair-user.yaml` | who the runs are registered as, copied to `$AFRICA_HPC_ROOT/fair/user.yaml` and filled in |
| `run.bash` | one stage as a job, configured by the `AFRICA_*` variables it is submitted with: a pipeline run given its config (`examples/paper/burnin.yaml`, `forward.yaml`), a plain run given its script |

The steps, in order: the clone and its data (once), the set-up job, the inputs, the replicates, and
the push. Everything is run from the root of the clone, with `env.sh` sourced first so that
`AFRICA_HPC_ROOT` is set.

## Once

1. On a login node, a Julia and a clone on project storage:

       module load apps/juliaup/1.18.9
       juliaup add 1.13.3
       cd /mnt/data/project0000/$USER
       git clone https://github.com/boydorr/AfricaPlants.jl AfricaPlants

2. From the root of a repository that has the data, its copy into the clone:

       rsync -av -r --files-from=examples/paper/hpc/transfer.txt . <host>:/mnt/data/project0000/<user>/AfricaPlants/

   Nothing in `data/` but its scripts is tracked, so after a `git pull` that stops tracking a file
   there, copy it again: the pull deletes the clone's copy.

3. Who the runs are registered as, in `$AFRICA_HPC_ROOT/fair/user.yaml` (`fair-user.yaml` says
   how). EcoSISTEM's paper set-up keeps it in the same place, so on an account that has run it
   there is nothing to do.

`fair` keeps one local registry for each user, and initialising a clone points all of that user's
clones at the one it names. So this set-up uses the registry, data store and port EcoSISTEM's paper
set-up uses, under `$AFRICA_HPC_ROOT/fair`, and either finds there what the other made.

## The set-up

The set-up job comes first, and again whenever the data, the package versions or the code change. A
new replicate does not need it. It ends with the blessing test, about half an hour, so a pass means
the data arrived intact and this machine gives the blessed values.

    source examples/paper/hpc/env.sh
    sbatch examples/paper/hpc/setup.bash

If `fetch.jl` cannot reach EarthEnv or Natural Earth from the compute node, run it on the login node
as its header says, and submit the set-up again. To set up the pipeline alone, run
`julia --project=examples/paper examples/paper/hpc/setup.jl` on the login node after `env.sh`.

The pipeline runs need `fair` 0.12.0 or later. The set-up keeps such a copy, as EcoSISTEM's set-up
does, and installs the newest release where there is none or an older one. It installs the local
registry only where there is none: a registry installed from an older release is moved on with
`fair"registry upgrade --version v1.5.0"`, the release `setup.jl` names.

## The inputs

A pipeline run reads every input from the local registry: the three tables, ERA5, Natural Earth, the
WFO release and the envelopes, which the laptop's runs registered and pushed to the remote
([`data/src/README.md`](../../../data/src/README.md)), and EarthEnv, which only these runs read, so it
is fetched here. Each file is put where the plain run reads it, so a file there already must have the
same bytes. Once the set-up has passed, and before the first replicate:

    source examples/paper/hpc/env.sh
    sbatch --wait --cpus-per-task=8 --mem=16G --time=01:00:00 \
        examples/paper/hpc/run.bash data/src/fetch-earthenv.yaml
    julia --project=examples/paper -e 'using DataPipeline
        fair"registry start"
        try fair"pull examples/paper/burnin.yaml" finally fair"registry stop" end'

The job registers EarthEnv's land cover, which the set-up put in the cache, so it asks for far less
than `run.bash`'s whole node: options given to `sbatch` override the script's `#SBATCH` lines.
`--wait` holds the shell until the job ends, since the registry runs on one node at a time. The pull
runs on the login node, which reaches the remote. It needs little CPU or memory, but brings every
other input the burn-in reads into the local registry, about 1.6 GB, which takes some minutes. The
forward run and the control read the same inputs.

A pull and a push use your token for the remote, from your account on `data.fairdatapipeline.org`,
in `$AFRICA_HPC_ROOT/fair/remote-token`, where `setup.jl` points `fair`. A run that finds a file of
other bytes where it would put its own stops and names it: delete the file and its
`.provenance.toml`, and the run puts its copy there.

## Replicates

A **replicate** is a burn-in, then the forward run and the control, which start from the same
settled state. Each stage is a job of its own, since one process running two holds the first's
ecosystem through the second. The three share one `AFRICA_SEED`, which seeds the replicate and
names what it writes. Every job names its cell size, and each experiment its own `AFRICA_SAVEDIR`,
since a run's files are named by seed alone.

Once the inputs are in the registry, one loop submits every replicate, listing its seeds:

    source examples/paper/hpc/env.sh
    export AFRICA_CELLSIZE=50km AFRICA_SAVEDIR=$AFRICA_HPC_ROOT/runs/50km
    for seed in 1 2; do
        export AFRICA_SEED=$seed
        burnin=$(sbatch --parsable examples/paper/hpc/run.bash examples/paper/burnin.yaml)
        sbatch --dependency=afterok:$burnin,singleton examples/paper/hpc/run.bash examples/paper/forward.yaml
        AFRICA_NEUTRAL=true sbatch --dependency=afterok:$burnin,singleton \
            examples/paper/hpc/run.bash examples/paper/forward.yaml
    done

- Slurm copies the environment when a job is submitted, so each job keeps the seed it was
  submitted with, and the loop moves on to the next seed at once.
- `sbatch --parsable` prints only the job's ID. The forward run and the control wait for their
  burn-in to succeed (`afterok`), and never start if it fails. A job whose dependency failed stays
  queued, `DependencyNeverSatisfied` in `squeue --me`: `scancel` it.
- Every pipeline job is named `paper`, and `singleton` lets only one job of a name run at a time,
  so the registry never runs on two nodes: each job starts it and stops it. The jobs therefore run
  one after another, whatever order Slurm takes them in. A `--dependency` given on the command line
  replaces `run.bash`'s own, so the two lines that wait on a burn-in add `singleton` back. A job of
  another name, EcoSISTEM's included, is not held back by it.
- Run one replicate alone first, `for seed in 1`, and read its time and memory before submitting
  the rest: `sacct -j <job ID> --format=JobID,MaxRSS,Elapsed,State` for each job, and its memory
  every five minutes in `paper-<job ID>.memory`.

**One step at a time** - each job submitted once the one before has finished and its logs look
right - it is the same commands without the loop and the `--dependency` flags:

    source examples/paper/hpc/env.sh
    export AFRICA_CELLSIZE=50km AFRICA_SEED=1 AFRICA_SAVEDIR=$AFRICA_HPC_ROOT/runs/50km
    sbatch examples/paper/hpc/run.bash examples/paper/burnin.yaml
    sbatch examples/paper/hpc/run.bash examples/paper/forward.yaml
    AFRICA_NEUTRAL=true sbatch examples/paper/hpc/run.bash examples/paper/forward.yaml

A **pipeline run** - `run.bash` given `burnin.yaml` or `forward.yaml` - registers what it writes as
`AfricaPlants:CaseStudy/<grid>/<Stage>/<Output>_<seed>` (`examples/paper/pipeline.jl` says which),
the forward run and the control reading the settled state the burn-in registered. It records the
commit it ran, so the clone must be clean and its commit pushed. A job loads the clone as it starts,
so leave the checkout alone while one is queued. A job Slurm kills cannot stop the registry, which
then stays recorded on that job's node; the next job is refused with a message naming the record to
delete. What a run registered stays in the registry on MARS until it is pushed.

## Pushing the runs

The laptop's runs must reach the remote first, since these runs read what they made. Then, on the
login node, in `julia --project=examples/paper`, list the runs, stage every finished one the remote
lacks, and push them:

    using DataPipeline
    fair"registry start"
    foreach(println, DataPipeline.code_runs())
    fair"add --all"
    fair"push"
    fair"registry stop"

`DataPipeline.code_runs()` lists every run of the local registry, each with whether it finished,
whether it is staged, and how much of it the remote holds. Read the list before staging. A push sends,
with each data product, every finished run that read it, staged or not, so a run that must not reach
the remote, such as a trial, is deleted from the local registry first, with `fair"rm <UUID> --yes"`.
A push that stops part way can be run again: what reached the remote is found there, not sent twice.
The listing, `fair add --all` and `fair rm` need `fair` 0.12.0 or later and DataPipeline 0.59.4 or
later.

## The 25 km trial

A **plain run** - `run.bash` given a script - registers nothing. The 25 km trial was one: it
measured the memory a full-scale run needs, the burn-in at 25 km stopped after its first yearly
records.

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
