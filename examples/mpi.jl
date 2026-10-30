# SPDX-License-Identifier: LGPL-3.0-or-later
#
# The whole experiment across MPI ranks, which divide the species between them: the backwards
# burn-in and the years of held climate that settle it, then the forward run recording diversity.
# `examples/paper.jl` is the same experiment in one process, the way the paper runs it; this runs
# the paper's stages from `examples/paper/`, in its environment.
#
#     mpiexecjl --project=examples/paper -n 12 julia --project=examples/paper examples/mpi.jl
#     AFRICA_SCALE=small mpiexecjl --project=examples/paper -n 2 \
#         julia --project=examples/paper examples/mpi.jl
#
# The environment variables are `examples/paper/burnin.jl`'s and `examples/paper/forward.jl`'s,
# which this runs in turn; `AFRICA_DISTRIBUTED` is set here and must not be.
#
# Every rank reads the records and builds the same layers, so the memory a run needs is a rank's
# share of the abundances plus one whole set of layers per rank: run fewer ranks than the memory
# allows rather than more. Ranks and threads combine - `-n 12` with `julia -t 2` - but a rank's own
# threads and its neighbours compete for the same cores.
#
# MPICH cannot always resolve a Mac's own hostname, and then `MPI.Init` fails with
# `gethostbyname failed`. Starting the run with `MPIR_CVAR_CH3_INTERFACE_HOSTNAME=127.0.0.1` in the
# environment tells it to use the loopback interface instead.

haskey(ENV, "AFRICA_DISTRIBUTED") &&
    error("`examples/mpi.jl` sets AFRICA_DISTRIBUTED itself; unset it, or run " *
          "`examples/paper/burnin.jl` and `examples/paper/forward.jl` directly.")
ENV["AFRICA_DISTRIBUTED"] = "mpi"

using MPI
MPI.Initialized() || MPI.Init()
const RANKS = MPI.Comm_size(MPI.COMM_WORLD)
RANKS > 1 ||
    error("`examples/mpi.jl` is for a multi-rank run: start it with `mpiexecjl -n <ranks>`, " *
          "or use `examples/paper.jl` for one process.")
MPI.Comm_rank(MPI.COMM_WORLD) == 0 &&
    (
     println("Africa across ", RANKS, " MPI ranks of ", Threads.nthreads(),
             " thread", Threads.nthreads() == 1 ? "" : "s", " each");
     flush(stdout))

# Each stage is a script of its own, so each goes in its own module: they name the same constants,
# and a bare `include` of both would redefine them.
module Burnin
include(joinpath("paper", "burnin.jl"))
end

module Forward
include(joinpath("paper", "forward.jl"))
end
