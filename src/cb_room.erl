-module(cb_room).

-behaviour(gen_server).

%% API
-export([start_link/3,
         all_players/1,
         marine_action/3,
         marine_report/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


-include("../include/cb.hrl").
-record(state, {roomid, mapid, owner, observers=[], players=[], marines=dict:new()}).

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


all_players(RoomPid) ->
    gen_server:call(RoomPid, all_players).

marine_action(RoomPid, Marine, Sock) ->
    gen_server:cast(RoomPid, {marine_action, Marine, Sock, self()}).

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
    io:format("Create Room: roomid = ~p,  mapid = ~p~n", [RoomId, MapId]),
    {ok, #state{roomid=RoomId, mapid=MapId, owner=OwnerPid, observers=[OwnerPid]}}.

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
handle_call({join, ai, PlayerPid}, _From, #state{players=Players} = State) ->
    {reply, ok, State#state{players=[PlayerPid | Players]}};

handle_call({join, ob, PlayerPid}, _From, #state{observers=Observers} = State) ->
    {reply, ok, State#state{observers=[PlayerPid | Observers]}};

handle_call(all_players, _From, #state{players=Players} = State) ->
    {reply, {ok, Players}, State}.

% handle_call({get_marine_owner_pid, MarineId}, _From, #state{marines=Marines} = State) ->
%     Reply = dict:find(MarineId, Marines),
%     {reply, Reply, State}.


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
handle_cast({to_observer, Marine}, #state{observers=Observers} = State) ->
    io:format("cb_room to_observer messages, observers = ~p~n", [Observers]),
    broadcast(Marine, Observers),
    {noreply, State};


handle_cast({broadcast, Marine}, #state{players=Players} = State) ->
    broadcast(Marine, Players),
    {noreply, State};

handle_cast({broadcast, Marine, IgnorePid}, #state{players=Players} = State) ->
    io:format("cb_room broadcasting messages, players = ~p, IgnorePid = ~p~n", [Players, IgnorePid]),
    broadcast(Marine, lists:delete(IgnorePid, Players)),
    {noreply, State};


% handle_cast({new_marine, MarineId, PlayerPid}, #state{marines=Marines} = State) when is_list(MarineId) ->
%     Fun = fun(Mid, Ms) ->
%         dict:store(Mid, PlayerPid, Ms)
%     end,
%     NewMarines = lists:foldl(Fun, Marines, MarineId),
%     {noreply, State#state{marines=NewMarines}};

% handle_cast({new_marine, MarineId, PlayerPid}, #state{marines=Marines} = State) ->
%     {noreply, State#state{marines=dict:store(MarineId, PlayerPid, Marines)}};


handle_cast({marine_action, #marine{status='Flares'} = M, Sock, CallerPid}, #state{players=Players} = State) ->
    Marines = lists:flatten( [gen_server:call(P, all_marines) || P <- Players] ),
    io:format("cb_room, 'Flares', ALL Marines = ~p~n", [Marines]),
    ok = cb_player:notify(Marines, Sock),

    %% notify other players that this marins's state
    broadcast(M, lists:delete(CallerPid, Players)),
    {noreply, State};


handle_cast({marine_action, #marine{status='GunAttack'} = M, _Sock, CallerPid}, #state{players=Players} = State) ->
    %% other players know this marine's state
    broadcast(M, lists:delete(CallerPid, Players)),
    {noreply, State};


handle_cast({marine_report, Report}, #state{players=Players} = State) ->
    report(Report, Players),
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
handle_info(_Info, State) ->
    {noreply, State}.

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

broadcast(Marine, Players) ->
    broadcast(Marine, Players, broadcast).

broadcast(Data, Players, MessageType) ->
    lists:foreach(
        fun(PlayerPid) ->
            gen_server:cast(PlayerPid, {MessageType, Data})
        end,
        Players
        ),
    ok.
