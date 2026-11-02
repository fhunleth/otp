%% SPDX-License-Identifier: Apache-2.0
-module(compartment).
-moduledoc """
Experimental, flat process compartments with normal-priority reduction reservations.

Each running OTP application with an application master defaults to the atom
that names the application. Processes inherit their parent's membership, not
the application owning the code they execute. Use the spawn option
`{compartment, Name}` to select another atom-named compartment before a child
runs. Names are global: several applications may explicitly select the same
compartment. A name such as `'my_app.control'` is a convention, not a hierarchy.
Included applications inherit their enclosing tree's membership.

New compartments are best effort and accumulate reduction counters even without
a reservation. There are 63 user compartments plus the reserved boot/system
compartment `'$compartment_system'`. Names, counters, and policies persist until
VM termination, including across application restarts. No deletion is supported.

The release owns resource policy. For example, in `sys.config`:

```erlang
[{kernel, [{compartments,
            [{capacity, 30000000},
             {reservations, [{motor_control, 5000000},
                             {'my_app.control', 10000000}]}]}]}].
```

In an Elixir/Nerves project's release configuration:

```elixir
config :kernel, :compartments,
  capacity: 30_000_000,
  reservations: [motor_control: 5_000_000, "my_app.control": 10_000_000]
```

Policy is applied before the kernel application starts. Runtime updates are
trusted administrative operations, not a security boundary, and are not persisted.
Environment variables are not used.

Capacity estimates reductions per normal scheduler per 100 ms. Reservations
specify aggregate reductions per 100 ms, not CPU time or maximum quotas. Only
normal-priority dispatches on normal schedulers are counted and charged.
Max/high precedence and OTP's normal/low weighting are unchanged; sustained
max/high work can starve reserved normal work. Dirty execution, shared services,
memory contention, and individual-process latency are not isolated.

Nonzero reservations and capacity must be at least 4000 and at most 4294967295.
Aggregate reservations must not exceed scheduler count times declared capacity.
While any reservation is nonzero, all normal schedulers must be online, process
scheduler bindings and multi-scheduling blocking are rejected. Activation also
rejects existing bindings or incompatible scheduler state.

Compaction keeps at least
`min(schedulers, max(1, ceil(2 * aggregate_reservations / capacity)))` run queues
active, counting idle compartments too. This is headroom, not core affinity.
Configuration briefly stops managed threads and resets all credit to zero.
Existing dispatches settle normally; service may be disturbed during the change.
Credit replenishes continuously, capped at one 100-ms budget. These are
experimental service preferences, not hard-real-time guarantees.
""".

-export([configure/1, configure/2, info/0, info/1]).

-type policy_option() :: {capacity, non_neg_integer()} |
                         {reservations, [{atom(), non_neg_integer()}]}.
-type configure_result() :: ok |
                            {error, compartment_capacity_exceeded |
                                    compartment_scheduler_configuration |
                                    system_limit}.

-doc """
Replaces all reservations atomically. Omitted names become best effort, but keep
their membership and counters. Omitted capacity retains the existing estimate;
zero capacity is allowed only with no nonzero reservations. Invalid terms raise
`badarg`; rejected updates leave the existing configuration and names unchanged.
""".
-spec configure([policy_option()]) -> configure_result().
configure(Options) ->
    {Capacity, Reservations} = policy(Options, undefined, [], []),
    erts_internal:compartment_configure(Capacity, Reservations, true).

policy([], Capacity, Reservations, _) ->
    {Capacity, Reservations};
policy([{capacity, Capacity} | Rest], _, Reservations, Seen) ->
    unique(capacity, Seen),
    policy(Rest, Capacity, Reservations, [capacity | Seen]);
policy([{reservations, Reservations} | Rest], Capacity, _, Seen) ->
    unique(reservations, Seen),
    policy(Rest, Capacity, Reservations, [reservations | Seen]);
policy(_, _, _, _) ->
    error(badarg).

unique(Key, Seen) ->
    case lists:member(Key, Seen) of
        true -> error(badarg);
        false -> ok
    end.

-doc """
Sets one compartment's reservation without changing other budgets or capacity.
Creates the compartment if necessary. All credit is reset, as for `configure/1`.
""".
-spec configure(atom(), [{reductions_per_100ms, non_neg_integer()}]) ->
          configure_result().
configure(Name, [{reductions_per_100ms, Budget}]) when is_atom(Name) ->
    erts_internal:compartment_configure(undefined, [{Name, Budget}], false);
configure(_, _) ->
    error(badarg).

-doc "Returns a service snapshot for every existing compartment.".
-spec info() -> [map()].
info() ->
    [info(Name) || Name <- erlang:system_info(compartments)].

-doc """
Returns a service snapshot. Unknown names raise `badarg`.

Use differences in `total_reductions` and monotonic sample times to measure rates.
Counters include borrowed normal-priority service, not just preferential service,
and are updated at scheduler accounting points. Active run queues are sampled
separately. Low credit alone does not establish that a reservation is inadequate.
""".
-spec info(atom()) -> map().
info(Name) ->
    {Budget, Reductions, Credit, Inflight, Period, Capacity, Floor, Active} =
        erlang:system_info({compartment_service, Name}),
    #{name => Name, reductions_per_100ms => Budget,
      total_reductions => Reductions, credit_reductions => Credit,
      inflight_reductions => Inflight, period_ms => Period,
      capacity => Capacity, compaction_floor => Floor, active_run_queues => Active}.
