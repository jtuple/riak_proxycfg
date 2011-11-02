-module(riak_proxycfg_server).
-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, check/0]).
-compile([export_all]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {nodes,
                ready,
                configs}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

check() ->
    gen_server:call(?MODULE, check).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_) ->
    FName = filename:join([code:lib_dir(riak_proxycfg, priv), "config3.et"]),
    erltl:compile(FName),
    Opts = [{seed_nodes, #state.nodes, []},
            {config, #state.configs, []}],
    {ok, State} = load_options(Opts, #state{ready=[]}),
    compile_templates(State),
    State2 = scheduled_check_nodes(State),
    {ok, State2}.

handle_call(check, _From, State) ->
    State2 = check_nodes(State),
    {reply, ok, State2};

handle_call(_Request, _From, State) ->
    {noreply, ok, State}.

handle_cast(scheduled_check, State) ->
    State2 = scheduled_check_nodes(State),
    {noreply, State2};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

load_options([], State) ->
    {ok, State};
load_options([{Opt, Setting, Default}|Rest], State) ->
    case application:get_env(riak_proxycfg, Opt) of
        undefined ->
            Val = Default;
        {ok, Val} ->
            Val = Val
    end,
    State2 = setelement(Setting, State, Val),
    load_options(Rest, State2).

compile_templates(State) ->
    [begin
         FName = filename:join([code:lib_dir(riak_proxycfg, priv), Template]),
         erltl:compile(FName)
     end || {Template, _, _, _} <- State#state.configs].

scheduled_check_nodes(State) ->
    %% Schedule next check
    timer:apply_after(30000, gen_server, cast, [?MODULE, scheduled_check]),
    check_nodes(State).

check_nodes(State=#state{nodes=Nodes, ready=OldReady}) ->
    ReadyNodes = query_ready_nodes(Nodes),
    case ReadyNodes of
        OldReady ->
            State;
        _ ->
            update_configs(ReadyNodes, State),
            Nodes2 = lists:usort(Nodes ++ ReadyNodes),
            State#state{nodes=Nodes2, ready=ReadyNodes}
    end.

update_configs(ReadyNodes, #state{configs=Configs}) ->
    Connections = get_connections(ReadyNodes),
    [update_config(Connections, Config) || Config <- Configs].

update_config(Connections, {Template, Replace, Out, ReloadCmd}) ->
    Info = printable(Connections, Replace),
    Mod = template_module(Template),
    Config = Mod:render(Info),
    ok = filelib:ensure_dir(Out),
    ok = file:write_file(Out, Config),
    os:cmd(ReloadCmd),
    ok.

template_module(FName) ->
    list_to_atom(filename:rootname(filename:basename(FName))).

query_ready_nodes([]) ->
    lager:warning("Unable to reach any known Riak nodes"),
    [];
query_ready_nodes([Node|Nodes]) ->
    case rpc:call(Node, riak_core_ring_manager, get_raw_ring, []) of
        {badrpc, _} ->
            query_ready_nodes(Nodes);
        {ok, Ring} ->
            case rpc:call(Node, riak_core_ring, ready_members, [Ring]) of
                {badrpc, _} ->
                    query_ready_nodes(Nodes);
                ReadyNodes ->
                    ReadyNodes
            end
    end.

get_connections(Nodes) ->
    lists:flatmap(fun get_connection/1, Nodes).
get_connection(Node) ->
    try
        {ok, PB_IP} = rpc:call(Node, application, get_env, [riak_kv, pb_ip]),
        {ok, PB_Port} = rpc:call(Node, application, get_env, [riak_kv, pb_port]),
        {ok, [{HTTP_IP, HTTP_Port}]} =
            rpc:call(Node, application, get_env, [riak_core, http]),
        [{Node, {http, HTTP_IP, HTTP_Port}, {pb, PB_IP, PB_Port}}]
    catch
        _:_ ->
            []
    end.

printable(Info, Replace) ->
    lists:map(fun(X) -> to_printable(X, Replace) end, Info).

to_printable({Node, {http, HTTP_IP, HTTP_Port}, {pb, PB_IP, PB_Port}},
             Replace) ->
    Name = lists:foldl(fun({A,B}, Acc) ->
                               binary:replace(Acc, A, B)
                       end, atom_to_binary(Node, latin1), Replace),
    {Name,
     {http, HTTP_IP, integer_to_list(HTTP_Port)},
     {pb, PB_IP, integer_to_list(PB_Port)}}.
