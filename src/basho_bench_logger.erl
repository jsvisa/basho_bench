%%%-------------------------------------------------------------------
%%% @author zhengdelweng
%%% @copyright (C) 2016, zhengdelweng
%%% @doc
%%%
%%% @end
%%% Created : 2016-02-29 20:38:28.981202
%%%-------------------------------------------------------------------
-module(basho_bench_logger).

-behaviour(gen_server).

%% API
-export([start/2, start_link/2, log/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {device}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start(LogDir, Id) ->
    gen_server:start(?MODULE, [LogDir, Id], []).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(LogDir, Id) ->
    gen_server:start_link(?MODULE, [LogDir, Id], []).

log(Pid, Msg) ->
    gen_server:cast(Pid, {log, Msg}).

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
init([LogDir, Id]) ->
    case LogDir of
        none ->
            {ok, #state{device = undefined}};
        LogDir ->
            LogFile = lists:concat([LogDir, '/', Id]),
            ok = filelib:ensure_dir(LogFile),
            {ok, Device} = file:open(LogFile, [write, append]),
            {ok, #state{device = Device}}
    end.

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
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

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
handle_cast({log, _Msg}, #state{device = undefined} = State) ->
    {noreply, State};
handle_cast({log, Msg}, #state{device = Device} = State) ->
    logging(Msg, Device),
    {noreply, State};
handle_cast(_Msg, State) ->
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
logging(Msg, Device) when is_list(Msg) orelse is_binary(Msg) ->
    ok = file:write(Device, Msg);
logging({get, Path, Code}, Device) ->
    logging(io_lib:format("> GET ~p '~p' ~n", [Path, Code]), Device);
logging({put, Path, Code}, Device) ->
    logging(io_lib:format("> PUT ~p '~p' ~n", [Path, Code]), Device).

