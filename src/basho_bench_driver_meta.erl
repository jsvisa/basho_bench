%% -------------------------------------------------------------------
%%
%% basho_bench: Benchmarking Suite
%%
%% Copyright (c) 2009-2013 Basho Techonologies
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
-module(basho_bench_driver_meta).

-export([new/1, run/4]).

-include("basho_bench.hrl").

-record(url, {abspath, host, port, username, password, path, protocol, host_type}).

-record(state, { base_urls,
                 logger,
                 base_urls_index,
                 path_params }).


%% ====================================================================
%% API
%% ====================================================================

new(Id) ->

    ?DEBUG("ID: ~p~n", [Id]),

    %% Make sure ibrowse is available
    case code:which(ibrowse) of
        non_existing ->
            ?FAIL_MSG("~s requires ibrowse to be installed.\n", [?MODULE]);
        _ ->
            ok
    end,

    application:start(ibrowse),

    Ips = basho_bench_config:get(meta_ips, ["127.0.0.1"]),
    DefaultPort = basho_bench_config:get(meta_port, 5000),
    Path = basho_bench_config:get(meta_path, "/metas"),
    Params = basho_bench_config:get(meta_params, ""),
    Disconnect = basho_bench_config:get(meta_disconnect_frequency, infinity),
    LogDir = basho_bench_config:get(meta_log_dir, "/tmp/meta-log"),

    case Disconnect of
        infinity ->
            ok;
        Seconds when is_integer(Seconds) ->
            ok;
        {ops, Ops} when is_integer(Ops) ->
            ok;
        _ ->
            ?FAIL_MSG("Invalid configuration for meta_disconnect_frequency: ~p~n", [Disconnect])
    end,

    %% Users pdict to avoid threading state record through lots of functions
    erlang:put(disconnect_freq, Disconnect),

    %% Convert the list to a tuple so we can efficiently round-robin
    %% through them.
    Targets = basho_bench_config:normalize_ips(Ips, DefaultPort),
    BaseUrls = list_to_tuple([#url{host=IP, port=Port, path=Path}
                              || {IP, Port} <- Targets]),
    BaseUrlsIndex = random:uniform(tuple_size(BaseUrls)),

    {ok, Logger} = basho_bench_logger:start(LogDir, Id),
    {ok, #state { base_urls = BaseUrls,
                  logger = Logger,
                  base_urls_index = BaseUrlsIndex,
                  path_params = Params }}.


run(get, _KeyGen, ValueGen, #state{logger = Logger}=State) ->
    Json = json_from_value(ValueGen),
    Key0 = proplists:get_value(<<"key">>, Json),
    Key = binary:bin_to_list(Key0),

    {NextUrl, S2} = next_url(State),
    Url = url(NextUrl, Key, State#state.path_params),
    case do_get(Url, [{body_on_success, true}], Json, Logger) of
        {ok, _Url, _Headers, _Body} ->
            {ok, S2};
        {ok, _Url, _Headers} ->
            {ok, S2};
        {error, {notfound, _Url}} ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;

run(put, KeyGen, ValueGen, #state{logger = Logger}=State) ->
    {NextUrl, S2} = next_url(State),
    Url0 = url(NextUrl, KeyGen, State#state.path_params),

    Val = if is_function(ValueGen) ->
                ValueGen();
            true ->
               ValueGen
          end,
    Key0 = proplists:get_value(<<"key">>, jsx:decode(Val), ""),
    Key = erlang:bitstring_to_list(Key0),
    Url = Url0#url{ path = lists:concat([Url0#url.path, '/', Key]) },

    case do_put(Url, [], Val, Logger) of
        {no_content, _Url} ->
            {error, {no_content, Url}, S2};
        ok ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;

run(delete, KeyGen, _ValueGen, #state{logger=Logger}=State) ->
    {NextUrl, S2} = next_url(State),
    Url = url(NextUrl, KeyGen, State#state.path_params),

    case do_delete(Url, [], Logger) of
        {not_found, _Url} ->
            %% {error, {not_found, Url}, S2};
            {ok, S2};
        ok ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;

run(putget, KeyGen, ValueGen, #state{logger=Logger}=State) ->
    {NextUrl, S2} = next_url(State),
    Url0 = url(NextUrl, KeyGen, State#state.path_params),

    Val = if is_function(ValueGen) ->
                ValueGen();
            true ->
               ValueGen
          end,
    Key = erlang:bitstring_to_list(proplists:get_value(<<"key">>, jsx:decode(Val), "")),
    Url = Url0#url{ path = lists:concat([Url0#url.path, '/', Key]) },

    case do_putget(Url, [], ValueGen, Logger) of
        ok ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end.

%% ====================================================================
%% Internal functions
%% ====================================================================

next_url(State) when is_record(State#state.base_urls, url) ->
    {State#state.base_urls, State};
next_url(State) when State#state.base_urls_index > tuple_size(State#state.base_urls) ->
    { element(1, State#state.base_urls),
      State#state { base_urls_index = 1 } };
next_url(State) ->
    { element(State#state.base_urls_index, State#state.base_urls),
      State#state { base_urls_index = State#state.base_urls_index + 1 }}.

url(BaseUrl, KeyGen, Params) when is_function(KeyGen) ->
    case KeyGen() of
        Key when is_binary(Key) ->
            url(BaseUrl, erlang:bin_to_list(Key), Params);
        Key when is_list(Key) ->
            url(BaseUrl, Key, Params)
    end;
url(BaseUrl, "", Params) ->
    BaseUrl#url { path = lists:concat([BaseUrl#url.path, Params]) };
url(BaseUrl, Key, Params) ->
    BaseUrl#url { path = lists:concat([BaseUrl#url.path, '/', Key, Params]) }.

do_get(Url, Logger, Opts) ->
    do_get(Url, Logger, [{body_on_success, false} | Opts], []).

do_get(Url, Opts, Json, Logger) ->
    case send_request(Url, [], get, [], [{response_format, binary}]) of
        {ok, Code, Header, Body} ->
            basho_bench_logger:log(Logger, {get, Url#url.path, Code}),
            case Code of
                "404" ->
                    {error, {notfound, Url}};
                "300" ->
                    {ok, Url, Header};
                "200" ->
                    case proplists:get_bool(body_on_success, Opts) of
                        true ->
                            case validate_meta(jsx:decode(Body), Json) of
                                [] -> {ok, Url, Header};
                                Error -> {error, Error}
                            end;
                        false ->
                            {ok, Url, Header}
                    end;
                Code ->
                    {error, {http_error, Code}}
            end;
        {error, Reason} ->
            basho_bench_logger:log(Logger, {get_error, Url#url.path, Reason}),
            {error, Reason}
    end.

do_put(Url, Headers, Val, Logger) ->
    case send_request(Url, Headers ++ [{'Content-Type', 'application/json'}],
                      post, Val, [{response_format, binary}]) of
        {ok, Code, _Header, _Body} ->
            basho_bench_logger:log(Logger, {put, Url#url.path, Code}),
            case Code of
                "200" -> ok;
                "201" -> ok;
                "204" -> ok;
                Code -> {error, {http_error, Code}}
            end;
        {error, Reason} ->
            basho_bench_logger:log(Logger, {put_error, Url#url.path, Reason}),
            {error, Reason}
    end.

do_putget(Url, Headers, Val, Logger) ->
    case send_request(Url, Headers ++ [{'Content-Type', 'application/octet-stream'}],
                     put, Val, [{response_format, binary}]) of
        {ok, Code, _Header, _Body} ->
            basho_bench_logger:log(Logger, {put, Url#url.path, Code}),
            if Code =:= "201" orelse Code =:= "204" ->
                    case do_get(Url, Logger, [{body_on_success, true}]) of
                        {ok, Url, _Header2, Body} ->
                            if Body =:= Val ->
                                    Log0 = io_lib:format("> GOT ~p Body the same as puted!~n", [Url#url.path]),
                                    basho_bench_logger:log(Logger, Log0),
                                    ok;
                                true ->
                                    Log0 = io_lib:format("> GOT ~p Body NOT THE Same as puted!~n", [Url#url.path]),
                                    basho_bench_logger:log(Logger, Log0),
                                    {error, get_body_error}
                            end;
                        Error ->
                            Error
                    end;
                true ->
                    {error, {http_error, Code}}
            end;
        {error, Reason} ->
            basho_bench_logger:log(Logger, {put_error, Url#url.path, Reason}),
            {error, Reason}
    end.

do_delete(Url, Headers, Logger) ->
    case send_request(Url, Headers, delete, [], []) of
        {ok, Code, _Header, _Body} ->
            basho_bench_logger:log(Logger, {delete, Url#url.path, Code}),
            case Code of
                "204" -> ok;
                "404" -> {not_found, Url};
                Code -> {error, {http_error, Code}}
            end;
        {error, Reason} ->
            basho_bench_logger:log(Logger, {delete_error, Url#url.path, Reason}),
            {error, Reason}
    end.


connect(Url) ->
    case erlang:get({ibrowse_pid, Url#url.host}) of
        undefined ->
            {ok, Pid} = ibrowse_http_client:start({Url#url.host, Url#url.port}),
            erlang:put({ibrowse_pid, Url#url.host}, Pid),
            Pid;
        Pid ->
            case is_process_alive(Pid) of
                true ->
                    Pid;
                false ->
                    erlang:erase({ibrowse_pid, Url#url.host}),
                    connect(Url)
            end
    end.

disconnect(Url) ->
    case erlang:get({ibrowse_pid, Url#url.host}) of
        undefined ->
            ok;
        OldPid ->
            catch(ibrowse_http_client:stop(OldPid))
    end,
    erlang:erase({ibrowse_pid, Url#url.host}),
    ok.

maybe_disconnect(Url) ->
    case erlang:get(disconnect_freq) of
        infinity ->
            ok;
        {ops, Count} ->
            should_disconnect_ops(Count, Url) andalso disconnect(Url);
        Seconds -> should_disconnect_secs(Seconds, Url) andalso disconnect(Url)
    end.

should_disconnect_ops(Count, Url) ->
    Key = {ops_since_disconnect, Url#url.host},
    case erlang:get(Key) of
        undefined ->
            erlang:put(Key, 1),
            false;
        Count ->
            erlang:put(Key, 0),
            true;
        Incr ->
            erlang:put(Key, Incr + 1),
            false
    end.

should_disconnect_secs(Seconds, Url) ->
    Key = {last_disconnect, Url#url.host},
    case erlang:get(Key) of
        undefined ->
            erlang:put(Key, erlang:timestamp()),
            false;
        Time when is_tuple(Time) andalso size(Time) == 3 ->
            Diff = time:now_diff(erlang:timestamp(), Time),
            if
                Diff >= Seconds * 1000000 ->
                    erlang:put(Key, erlang:timestamp()),
                    true;
                true -> false
            end
    end.

clear_disconnect_freq(Url) ->
    case erlang:get(disconnect_freq) of
        infinity ->
            ok;
        {ops, _Count} ->
            erlang:put({ops_since_disconnect, Url#url.host}, 0);
        _Seconds ->
            erlang:put({last_disconnect, Url#url.host}, erlang:timestamp())
    end.


send_request(Url, Headers, Method, Body, Options) ->
    send_request(Url, Headers, Method, Body, Options, 1).

send_request(_Url, _Headers, _Method, _Body, _Options, 0) ->
    {error, max_retries};
send_request(Url, Headers, Method, Body, Options, Count) ->
    Pid = connect(Url),
    case catch(ibrowse_http_client:send_req(Pid, Url,
                                            Headers ++ basho_bench_config:get(meta_append_headers, []),
                                            Method, Body, Options,
                                            basho_bench_config:get(meta_request_timeout, 5000))) of
        {ok, Status, RespHeaders, RespBody} ->
            maybe_disconnect(Url),
            {ok, Status, RespHeaders, RespBody};
        Error ->
            lager:error("ERROR ~p ~p ~p~n", [Method, Url#url.path, Error]),
            clear_disconnect_freq(Url),
            disconnect(Url),
            case should_retry(Error) of
                true ->
                    send_request(Url, Headers, Method, Body, Options, Count-1);
                false ->
                    normalize_error(Method, Error)
            end
    end.

should_retry({error, send_failed})          -> true;
should_retry({error, connection_closed})    -> true;
should_retry({error, connection_closing})   -> true;
should_retry({'EXIT', {normal, _}})         -> true;
should_retry({'EXIT', {noproc, _}})         -> true;
should_retry(_)                             -> false.

normalize_error(Method, {'EXIT', {timeout, _}}) ->
    {error, {Method, timeout}};
normalize_error(Method, {'EXIT', Reason}) ->
    {error, {Method, 'EXIT', Reason}};
normalize_error(Method, {error, Reason}) ->
    {error, {Method, Reason}}.

json_from_value(ValueGen) ->
    Body = case is_function(ValueGen) of
                true -> ValueGen();
                false -> ValueGen
            end,
    jsx:decode(Body).

validate_meta(Body0, Json0) ->
    Body = lists:map(fun({Key, Value}) -> {binary:bin_to_list(Key), Value} end, Body0),
    Json = lists:map(fun({Key, Value}) -> {binary:bin_to_list(Key), Value} end, Json0),

    Validater = fun(Key, Acc) ->
            {Key, CValue} = lists:keyfind(Key, 1, Body),
            {Key, EValue} = lists:keyfind(Key, 1, Json),
            case CValue == EValue of
                true -> Acc;
                false -> [{{lists:concat(["get_", Key]), CValue}, {lists:concat(["expect_", Key]), EValue}} | Acc]
            end
        end,
    Items = ["content_length", "content_type", "content_md5", "created_at", "block_size", "cluster_id"],
    Result1 = lists:foldl(Validater, [], Items),

    % block_uuid
    {"block_uuid", CUUID0} = lists:keyfind("block_uuid", 1, Body),
    {"block_uuid", EUUID}  = lists:keyfind("block_uuid", 1, Json),
    CUUID = binary:replace(CUUID0, <<"-">>, <<"">>, [global]),
    Result2 = case CUUID == EUUID of
                  true -> Result1;
                  false -> [{{"get_block_uuid", CUUID}, {"expect_block_uuid", EUUID}} | Result1]
              end,

    % metadata
    {"metadata", CMetadata0} = lists:keyfind("metadata", 1, Body),
    {"metadata", EMetadata0} = lists:keyfind("metadata", 1, Json),
    CMetadata = ordsets:from_list(CMetadata0),
    EMetadata = ordsets:from_list(EMetadata0),
    Result3 = case CMetadata == EMetadata of
                  true -> Result2;
                  false -> [{{"get_metadata", CMetadata}, {"expect_metadata", EMetadata}} | Result2]
              end,

    Result3.
