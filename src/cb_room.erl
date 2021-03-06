-module(cb_room).

-behaviour(gen_server).

%% API
-export([start_link/3,
         marine_report/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("../include/cb.hrl").
-record(state, {roomid, mapid, owner, observers=[], players=[], refs=sets:new(), marines=dict:new()}).

-define(BATTLETIME, 1000 * 600).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(OwnerPid, RoomId, MapId) ->
    gen_server:start_link(?MODULE, [OwnerPid, RoomId, MapId], []).

marine_report(RoomPid, Report) ->
    gen_server:cast(RoomPid, {marine_report, Report}).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([OwnerPid, RoomId, MapId]) ->
    % io:format("Create Room: roomid = ~p,  mapid = ~p~n", [RoomId, MapId]),
    Ref = erlang:monitor(process, OwnerPid),
    R = sets:add_element(Ref, sets:new()),
    {ok, #state{roomid=RoomId, mapid=MapId, owner=OwnerPid, observers=[OwnerPid], refs=R}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({join, ai, PlayerPid}, _From, #state{players=Players, refs=R} = State) ->
    {NewPlayers, NewRefs} =
    case length(Players) - (?PLAYERNUMS - 1) of
        N when N =:= 0 ->
            %% send startbattle message
            Ref = erlang:monitor(process, PlayerPid),
            Ps = [PlayerPid | Players],
            lists:foreach(
                fun(P) ->
                    gen_server:cast(P, startbattle)
                end,
                Ps
                ),
            timer:send_after(?BATTLETIME, self(), endbattle),
            {Ps, sets:add_element(Ref, R)};
        N when N < 0 ->
            Ref = erlang:monitor(process, PlayerPid),
            {[PlayerPid | Players], sets:add_element(Ref, R)};
        N when N > 0 ->
            %% room full
            {Players, R}
    end,

    Reply =
    case length(NewPlayers) > length(Players) of
        true -> ok;
        false -> full
    end,

    {reply, Reply, State#state{players=NewPlayers, refs=NewRefs}};

handle_call({join, ob, PlayerPid}, _From, #state{observers=Observers} = State) ->
    {reply, ok, State#state{observers=[PlayerPid | Observers]}}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_cast({to_observer, Data}, #state{observers=Observers} = State) ->
    broadcast(Data, Observers),
    {noreply, State};

handle_cast({to_observer, createmarine, Marine, Color}, #state{observers=Observers} = State) ->
    lists:foreach(
        fun(Ob) -> gen_server:cast(Ob, {createmarine, Marine, Color}) end,
        Observers
        ),
    {noreply, State};

handle_cast({broadcast, Data}, #state{players=Players} = State) ->
    broadcast(Data, Players),
    {noreply, State};

handle_cast({broadcast, Role, Marine}, #state{players=Players} = State) ->
    lists:foreach(
        fun(P) -> gen_server:cast(P, {broadcast, Role, Marine}) end,
        Players
        ),
    {noreply, State};


handle_cast({marine_report, Report}, #state{players=Players} = State) ->
    report(Report, Players),
    {noreply, State};


handle_cast({flares_report, CallerPid, M}, #state{players=Players} = State) ->
    timer:sleep(50),
    OtherPlayers = lists:delete(CallerPid, Players),
    broadcast(M, OtherPlayers),
    Marines = lists:flatten( [gen_server:call(P, all_marines) || P <- OtherPlayers] ),
    gen_server:cast(CallerPid, {broadcast, Marines}),
    {noreply, State};


handle_cast({flares2_report, CallerPid}, #state{players=Players} = State) ->
    timer:sleep(50),
    Marines = lists:flatten( [gen_server:call(P, all_marines) || P <- lists:delete(CallerPid, Players)] ),
    gen_server:cast(CallerPid, {broadcast, Marines}),
    {noreply, State};


handle_cast({gunattack_report, CallerPid, M}, #state{players=Players} = State) ->
    broadcast(M, lists:delete(CallerPid, Players)),
    {noreply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(endbattle, #state{refs=Refs, observers=Ob, players=Players} = State) ->
    lists:foreach(
        fun(R) -> erlang:demonitor(R, [flush]) end,
        sets:to_list(Refs)
        ),

    broadcast("Battle Time is expired", Players ++ Ob, 'DOWN'),
    {stop, normal, State};


handle_info({'DOWN', Ref, process, Pid, Reason}, #state{players=Players, observers=Ob, refs=Refs} = State) ->
    case sets:is_element(Ref, Refs) of
        false -> {noreply, State};
        true -> 
            lists:foreach(
                fun(R) -> erlang:demonitor(R, [flush]) end,
                sets:to_list(Refs)
                ),
            broadcast(Reason, lists:delete(Pid, Players) ++ Ob, 'DOWN'),
            {stop, normal, State}
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

report(Data, Players) ->
    broadcast(Data, Players, report).

broadcast(Data, Players) ->
    broadcast(Data, Players, broadcast).

broadcast(Data, Players, MessageType) ->
    lists:foreach(
        fun(PlayerPid) ->
            gen_server:cast(PlayerPid, {MessageType, Data})
        end,
        Players
        ),
    ok.
