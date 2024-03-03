# ExFdbmonitor

ExFdbmonitor is an Elixir application that manages the starting and stopping of
`fdbmonitor`, which is the management process for FoundationDB.

The goal of ExFdbmonitor is to allow a FoundationDB cluster to bootstrap itself
using the distributed capabilities of the Erlang VM.

With a correctly crafted set of application environment variables, a cluster
can be brought up from zero as long as each node is started individually.

Once the cluster is established, node restarts are equivalent to restarts of
`fdbmonitor` itself.

**Work in progress.**
