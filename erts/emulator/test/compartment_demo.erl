-module(compartment_demo).
-moduledoc """
Experimental normal-scheduler and local-message isolation.

Build OTP, then compile this module into a temporary directory:

    mkdir -p /tmp/compartment_demo
    bin/erlc -o /tmp/compartment_demo erts/emulator/test/compartment_demo.erl

Run the same workload with shared scheduling, then with compartments:

    bin/erl +S 4:4 -pa /tmp/compartment_demo -noshell -s compartment_demo run -s init stop
    ERL_COMPARTMENTS=1:0:1,2:4:2,3:0:3 bin/erl +S 4:4 -pa /tmp/compartment_demo -noshell -s compartment_demo run -s init stop

ERL_COMPARTMENTS is a comma-separated list of id:scheduler:zones.
IDs are 1..63, scheduler 0 means the shared, unreserved scheduler pool,
and zones is a nonzero 32-bit decimal bitmask. A nonzero scheduler is
exclusive to that compartment. At least one scheduler must remain shared;
all normal schedulers must start online. Omit the variable to disable the
experiment and retain ordinary scheduling and messaging.

Compartment 0 is the trusted controller: it uses the shared scheduler pool,
shares all zones, and is inherited by boot/runtime services. Only its processes
may use spawn_opt's {compartment, Id} option. Other children inherit membership.
system_info(compartment) returns {Id, ReservedSchedulerOrZero, ZoneMask}, or
undefined when disabled. Membership and configuration cannot be changed.
Scheduler overrides cannot escape placement, and changing schedulers_online
or blocking multi_scheduling is rejected while compartments are enabled.

The sample configuration gives best effort (1) zone 1, critical (2) zone 2 and
scheduler 4, and the gatekeeper (3) both zones on shared schedulers.

Only local ! and send/2,3 are filtered, including names, aliases and priority
sends. A disjoint-zone send is discarded before copying into the receiver and
retains its normal return value. Timer, native, runtime-generated and distributed
messages, process-control operations, shared-service relays, memory pressure,
dirty schedulers, ports and OS interference are NOT contained. Controller
processes and native code are trusted. This is not a security sandbox, a physical
CPU reservation, or a hard-real-time guarantee.

The critical workload measures lateness of 1,000 absolute 2 ms deadlines under
128 high-priority CPU-bound best-effort processes that run for three seconds.
This intentionally demonstrates that best-effort priority cannot take the
reserved scheduler; the critical process retains normal priority.
The demonstration also checks scheduler placement and
counts direct versus gatekeeper messages. Latency is an observation, not a
pass/fail bound; compare repeated runs on an otherwise idle machine. Bridge
forwarding is checked before starting the overload; the bridge has no progress
guarantee under best-effort overload.
""".

-export([run/0]).

run() ->
    Enabled = erlang:system_info(compartment) =/= undefined,
    case {Enabled, erlang:system_info(schedulers_online)} of
        {true, 4} -> ok;
        {false, _} -> ok;
        _ -> error(use_the_documented_four_scheduler_configuration)
    end,
    Parent = self(),
    Critical = spawn_role(Enabled, 2,
                          fun() ->
                                  receive
                                      {start, Start} ->
                                          critical(Parent, Enabled, Start, 1000,
                                                   [], [], 0, 0)
                                  end
                          end),
    Gate = spawn_role(Enabled, 3, fun() -> gatekeeper(Critical) end),
    Workers = [spawn_role(Enabled, 1, fun() -> best_effort(Parent, Critical, Enabled) end)
               || _ <- lists:seq(1, 128)],
    try
        lists:foreach(fun(Pid) -> receive {ready, Pid} -> ok end end, Workers),
        Critical ! {start, erlang:monotonic_time(microsecond) + 100000},
        Gate ! {forward, hello},
        receive gatekeeper_ready -> ok after 5000 -> error(gatekeeper_timeout) end,
        lists:foreach(fun(Pid) -> Pid ! go end, Workers),
        receive
            {critical_result, Latencies, Schedulers, Direct, Bridged} ->
                Sorted = lists:sort(Latencies),
                io:format("~p~n",
                          [#{mode => case Enabled of true -> compartments; false -> shared end,
                            workers => length(Workers),
                            critical_schedulers => lists:usort(Schedulers),
                            direct_messages_received => Direct,
                            gatekeeper_messages_received => Bridged,
                            latency_us => #{p50 => lists:nth(500, Sorted),
                                            p99 => lists:nth(990, Sorted),
                                            max => lists:last(Sorted)}}]);
            {placement_violation, Pid, Scheduler} ->
                error({placement_violation, Pid, Scheduler})
        after 30000 ->
            error(critical_workload_timeout)
        end
    after
        lists:foreach(fun(Pid) -> unlink(Pid), exit(Pid, kill) end,
                      [Critical, Gate | Workers])
    end.

spawn_role(false, _, Fun) ->
    spawn_link(Fun);
spawn_role(true, Id, Fun) ->
    spawn_opt(Fun, [link, {compartment, Id}]).

gatekeeper(Critical) ->
    receive
        {forward, Payload} ->
            Critical ! {gatekeeper, Payload},
            gatekeeper(Critical)
    end.

best_effort(Parent, Critical, Enabled) ->
    process_flag(priority, high),
    Parent ! {ready, self()},
    receive go -> ok end,
    Critical ! {best_effort, hello},
    busy(Parent, Enabled, erlang:monotonic_time(microsecond) + 3000000, 1).

busy(Parent, Enabled, Until, Acc) ->
    Scheduler = erlang:system_info(scheduler_id),
    case Enabled andalso Scheduler =:= 4 of
        true -> Parent ! {placement_violation, self(), Scheduler};
        false -> ok
    end,
    case erlang:monotonic_time(microsecond) < Until of
        true -> busy(Parent, Enabled, Until, burn(1000, Acc));
        false -> ok
    end.

burn(0, Acc) ->
    Acc;
burn(N, Acc) ->
    burn(N - 1, (Acc * 1664525 + 1013904223) band 16#ffffffff).

critical(Parent, _, _, 0, Latencies, Schedulers, Direct, Bridged) ->
    Parent ! {critical_result, Latencies, Schedulers, Direct, Bridged};
critical(Parent, Enabled, Deadline, Left, Latencies, Schedulers, Direct, Bridged) ->
    Delay = max(0, (Deadline - erlang:monotonic_time(microsecond) + 999) div 1000),
    receive
        {best_effort, _} ->
            critical(Parent, Enabled, Deadline, Left, Latencies, Schedulers,
                     Direct + 1, Bridged);
        {gatekeeper, _} ->
            Parent ! gatekeeper_ready,
            critical(Parent, Enabled, Deadline, Left, Latencies, Schedulers,
                     Direct, Bridged + 1)
    after Delay ->
        Now = erlang:monotonic_time(microsecond),
        Scheduler = erlang:system_info(scheduler_id),
        case Enabled andalso Scheduler =/= 4 of
            true -> Parent ! {placement_violation, self(), Scheduler};
            false -> ok
        end,
        burn(500, 1),
        critical(Parent, Enabled, Deadline + 2000, Left - 1,
                 [max(0, Now - Deadline) | Latencies],
                 [Scheduler | Schedulers], Direct, Bridged)
    end.
