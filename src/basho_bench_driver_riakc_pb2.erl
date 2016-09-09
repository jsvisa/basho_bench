% -------------------------------------------------------------------
%%
%% basho_bench_driver_riakc_pb: Driver for riak protocol buffers client
%%
%% Copyright (c) 2009 Basho Techonologies
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(basho_bench_driver_riakc_pb2).

-export([new/1,
         run/4
        ]).

-include("basho_bench.hrl").

-record(state, { pid,
                 bucket,
                 r,
                 pr,
                 w,
                 dw,
                 pw,
                 rw,
                 content_type,
                 timeout_general,
                 timeout_read,
                 timeout_write
               }).

-define(TIMEOUT_GENERAL, 62*1000).              % Riak PB default + 2 sec

%% ====================================================================
%% API
%% ====================================================================

new(Id) ->
    %% Make sure the path is setup such that we can get at riak_client
    case code:which(riakc_pb_socket) of
        non_existing ->
            ?FAIL_MSG("~s requires riakc_pb_socket module to be available on code path.\n",
                      [?MODULE]);
        _ ->
            ok
    end,

    Ips  = basho_bench_config:get(riakc_pb_ips, [{127,0,0,1}]),
    Port  = basho_bench_config:get(riakc_pb_port, 8087),
    %% riakc_pb_replies sets defaults for R, W, DW and RW.
    %% Each can be overridden separately
    Replies = basho_bench_config:get(riakc_pb_replies, quorum),
    R = basho_bench_config:get(riakc_pb_r, Replies),
    W = basho_bench_config:get(riakc_pb_w, Replies),
    DW = basho_bench_config:get(riakc_pb_dw, Replies),
    RW = basho_bench_config:get(riakc_pb_rw, Replies),
    PW = basho_bench_config:get(riakc_pb_pw, Replies),
    PR = basho_bench_config:get(riakc_pb_pr, Replies),
    Bucket  = basho_bench_config:get(riakc_pb_bucket, <<"test">>),
    CT = basho_bench_config:get(riakc_pb_content_type, "application/octet-stream"),

    %% Choose the target node using our ID as a modulus
    Targets = basho_bench_config:normalize_ips(Ips, Port),
    {TargetIp, TargetPort} = lists:nth((Id rem length(Targets)+1), Targets),
    ?INFO("Using target ~p:~p for worker ~p\n", [TargetIp, TargetPort, Id]),
    case riakc_pb_socket:start_link(TargetIp, TargetPort, get_connect_options()) of
        {ok, Pid} ->
            {ok, #state { pid = Pid,
                          bucket = Bucket,
                          r = R,
                          pr = PR,
                          w = W,
                          dw = DW,
                          rw = RW,
                          pw = PW,
                          content_type = CT,
                          timeout_general = get_timeout_general(),
                          timeout_read = get_timeout(pb_timeout_read),
                          timeout_write = get_timeout(pb_timeout_write)
                        }};
        {error, Reason2} ->
            ?FAIL_MSG("Failed to connect riakc_pb_socket to ~p:~p: ~p\n",
                      [TargetIp, TargetPort, Reason2])
    end.

run(get, KeyGen, _ValueGen, State) ->
    Key = KeyGen(),
    case riakc_pb_socket:get(State#state.pid, State#state.bucket, Key,
                             [{r, State#state.r}], State#state.timeout_read) of
        {ok, _} ->
            {ok, State};
        {error, notfound} ->
            {ok, State};
        {error, disconnected} ->
            run(get, KeyGen, _ValueGen, State);
        {error, Reason} ->
            {error, Reason, State}
    end;
run(get_existing, KeyGen, _ValueGen, State) ->
    Key0 = KeyGen(),
    Key1 = binary_to_list(Key0),
    [Key, Md5] = string:tokens(Key1, " "),
    RequestKey = basho_uuid:to_binary(Key),

    case riakc_pb_socket:get(State#state.pid, State#state.bucket, RequestKey,
                             [{r, State#state.r}], State#state.timeout_read) of
        {ok, Obj} ->
            Value = riakc_obj:get_value(Obj),
            case base64:encode_to_string(crypto:hash(md5, Value)) of
                Md5 -> {ok, State};
                Not -> {error, {md5_error, Key}, {log, io_lib:format("md5error ~s ~s ~s~n", [Key, Md5, Not])}, State}
            end;
        {error, notfound} ->
            Log = io_lib:format("notfound ~s~n", [Key]),
            {error, {not_found, Key}, {log, Log}, State};
        {error, disconnected} ->
            run(get_existing, KeyGen, _ValueGen, State);
        {error, Reason} ->
            {error, Reason, {log, [Reason, Key]}, State}
    end;
run(put, _KeyGen, ValueGen, State) ->
    Key = basho_uuid:v4(),
    Val = ValueGen(),
    Robj = riakc_obj:new(State#state.bucket, Key, Val, State#state.content_type),
    case riakc_pb_socket:put(State#state.pid, Robj, [{w, State#state.w},
                                                     {dw, State#state.dw}], State#state.timeout_write) of
        ok ->
            Log = io_lib:format("~s ~s~n", [basho_uuid:to_string(Key), base64:encode_to_string(crypto:hash(md5, Val))]),
            {ok, {log, Log}, State};
        {error, disconnected} ->
            run(put, _KeyGen, ValueGen, State);  % suboptimal, but ...
        {error, Reason} ->
            {error, Reason, {log, io_lib:format("~p ~s~n", [Reason, basho_uuid:to_string(Key)])}, State}
    end;
run(update, KeyGen, ValueGen, State) ->
    Key = KeyGen(),
    case riakc_pb_socket:get(State#state.pid, State#state.bucket,
                             Key, [{r, State#state.r}], State#state.timeout_read) of
        {ok, Robj} ->
            [M | _] = riakc_obj:get_metadatas(Robj),
            Robj1 = riakc_obj:update_metadata(Robj, M),
            Robj2 = riakc_obj:update_value(Robj1, ValueGen(), State#state.content_type),
            case riakc_pb_socket:put(State#state.pid, Robj2, [{w, State#state.w},
                                                              {dw, State#state.dw}], State#state.timeout_write) of
                ok ->
                    {ok, State};
                {error, disconnected} ->
                    run(update, KeyGen, ValueGen, State);  % suboptimal, but ...
                {error, Reason} ->
                    {error, Reason, State}
            end;
        {error, notfound} ->
            Robj = riakc_obj:new(State#state.bucket, Key, ValueGen(), State#state.content_type),
            case riakc_pb_socket:put(State#state.pid, Robj, [{w, State#state.w},
                                                             {dw, State#state.dw}], State#state.timeout_write) of
                ok ->
                    {ok, State};
                {error, disconnected} ->
                    run(update, KeyGen, ValueGen, State);  % suboptimal, but ...
                {error, Reason} ->
                    {error, Reason, State}
            end;
        {error, disconnected} ->
            run(update, KeyGen, ValueGen, State);
        {error, Reason} ->
            {error, Reason, State}
    end;
run(update_existing, KeyGen, ValueGen, State) ->
    Key = KeyGen(),
    case riakc_pb_socket:get(State#state.pid, State#state.bucket,
                             Key, [{r, State#state.r}], State#state.timeout_read) of
        {ok, Robj} ->
            [M | _] = riakc_obj:get_metadatas(Robj),
            Robj1 = riakc_obj:update_metadata(Robj, M),
            Robj2 = riakc_obj:update_value(Robj1, ValueGen(), State#state.content_type),
            case riakc_pb_socket:put(State#state.pid, Robj2, [{w, State#state.w},
                                                              {dw, State#state.dw}], State#state.timeout_write) of
                ok ->
                    {ok, State};
                {error, disconnected} ->
                    run(update_existing, KeyGen, ValueGen, State);  % suboptimal, but ...
                {error, Reason} ->
                    {error, Reason, State}
            end;
        {error, notfound} ->
            {error, {not_found, Key}, State};
        {error, disconnected} ->
            run(update_existing, KeyGen, ValueGen, State);
        {error, Reason} ->
            {error, Reason, State}
    end;
run(delete, KeyGen, _ValueGen, State) ->
    %% Pass on rw
    case riakc_pb_socket:delete(State#state.pid, State#state.bucket, KeyGen(),
                                [{rw, State#state.rw}], State#state.timeout_write) of
        ok ->
            {ok, State};
        {error, notfound} ->
            {ok, State};
        {error, disconnected} ->
            run(delete, KeyGen, _ValueGen, State);
        {error, Reason} ->
            {error, Reason, State}
    end.


%% ====================================================================
%% Internal functions
%% ====================================================================

get_timeout_general() ->
    basho_bench_config:get(pb_timeout_general, ?TIMEOUT_GENERAL).

get_timeout(Name) when Name == pb_timeout_read;
                       Name == pb_timeout_write;
                       Name == pb_timeout_listkeys;
                       Name == pb_timeout_mapreduce ->
    basho_bench_config:get(Name, get_timeout_general()).

get_connect_options() ->
    basho_bench_config:get(pb_connect_options, [{auto_reconnect, true}]).
