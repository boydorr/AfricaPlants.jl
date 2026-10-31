# SPDX-License-Identifier: LGPL-3.0-or-later
#
# The data pipeline for the paper's runs on an HPC, set up once by `setup.bash`: DataPipeline's own
# copy of `fair`, a local registry, and this clone initialised with a CLI configuration written here.
# Run from the root of the clone, in `examples/paper`'s environment, after `env.sh`; run again, it
# brings the copy of `fair` up to date and leaves the rest as it is.
#
# `fair` keeps one local registry for each user, in `~/.fair`, and initialising a clone points every
# clone of that user's at the registry it names. So the registry, its data store and who the runs
# are registered as are those under `$AFRICA_HPC_ROOT/fair`, as EcoSISTEM's paper set-up has them on
# the same account: either set-up finds there what the other made.

using DataPipeline

# The releases installed: those EcoSISTEM's paper set-up installs.
const CLI_VERSION = "0.11.0"
const REGISTRY_VERSION = "v1.4.0"

const FAIR = joinpath(ENV["AFRICA_HPC_ROOT"], "fair")
const PORT = ENV["AFRICA_HPC_PORT"]
const REGISTRY = ENV["FAIR_REGISTRY_DIR"]
const USERFILE = joinpath(FAIR, "user.yaml")

isfile(joinpath("examples", "paper", "burnin.yaml")) ||
    error("run this from the root of the AfricaPlants clone, not ", pwd())
isfile(USERFILE) ||
    error("no $USERFILE: copy examples/paper/hpc/fair-user.yaml there and fill it in")
any(line -> occursin(r"^[^#]*<", line), eachline(USERFILE)) &&
    error("$USERFILE still has a `<...>` to replace")

DataPipeline.install_cli(version = CLI_VERSION)

if !isfile(joinpath(REGISTRY, "manage.py"))
    mkpath(dirname(REGISTRY))
    fair"registry install --directory $REGISTRY --version $REGISTRY_VERSION"
end

# The CLI configuration: the local registry on its port and its store beside it, the public registry
# as the remote, this clone, and the user from `USERFILE`.
remote = try
    readchomp(`git remote get-url origin`)
catch
    "https://github.com/boydorr/AfricaPlants.jl"
end
user = read(USERFILE, String)
config = joinpath(FAIR, "africaplants-cli-config.yaml")
write(config, """
      namespaces:
        input: AfricaPlants
        output: AfricaPlants
      registries:
        local:
          uri: http://127.0.0.1:$PORT/api/
          directory: $REGISTRY
          data_store: $(joinpath(FAIR, "data_store"))/
          token: $(joinpath(REGISTRY, "token"))
        origin:
          uri: https://data.fairdatapipeline.org/api/
          data_store: https://data.fairdatapipeline.org/data/
          token: $(joinpath(FAIR, "remote-token"))
      git:
        local_repo: $(pwd())
        remote: origin
        remote_repo: $remote
      $user""")

# Asks nothing, given the configuration; for a clone already initialised, registers its user again.
fair"init --using $config --local"
println("The pipeline is set up: registry at ", REGISTRY, ", data store at ",
        joinpath(FAIR, "data_store"))
