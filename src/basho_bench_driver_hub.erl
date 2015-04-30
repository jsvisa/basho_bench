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
-module(basho_bench_driver_hub).

-export([new/1,
         run/4,
         valgen/1]).

-include("basho_bench.hrl").

-record(url, {abspath, host, port, username, password, path, protocol, host_type}).

-record(state, { base_urls,
                 base_urls_index,
                 path_params,
                 iter }).


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

    Ips = basho_bench_config:get(hub_ips, ["127.0.0.1"]),
    DefaultPort = basho_bench_config:get(hub_port, 8098),
    Path = basho_bench_config:get(hub_path, "/hub"),
    Params = basho_bench_config:get(hub_params, ""),
    Disconnect = basho_bench_config:get(hub_disconnect_frequency, infinity),

    case Disconnect of
        infinity ->
            ok;
        Seconds when is_integer(Seconds) ->
            ok;
        {ops, Ops} when is_integer(Ops) ->
            ok;
        _ ->
            ?FAIL_MSG("Invalid configuration for hub_disconnect_frequency: ~p~n", [Disconnect])
    end,

    %% Users pdict to avoid threading state record through lots of functions
    erlang:put(disconnect_freq, Disconnect),

    %% Convert the list to a tuple so we can efficiently round-robin
    %% through them.
    Targets = basho_bench_config:normalize_ips(Ips, DefaultPort),
    BaseUrls = list_to_tuple([#url{host=IP, port=Port, path=Path}
                              || {IP, Port} <- Targets]),
    BaseUrlsIndex = random:uniform(tuple_size(BaseUrls)),

    {ok, #state { base_urls = BaseUrls,
                  base_urls_index = BaseUrlsIndex,
                  path_params = Params,
                  iter = ''}}.


run(get, KeyGen, _ValueGen, State) ->
    {NextUrl, S2} = next_url(State),
    Url = url(NextUrl, KeyGen, State#state.path_params),
    case do_get(Url) of
        {not_found, _Url} ->
            {error, {not_found, Url}, S2};
        {ok, _Url, _Headers} ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;
run(getx, KeyGen, _ValueGen, State) ->
    {NextUrl, S2} = next_url(State),
    Url = url(NextUrl, KeyGen, State#state.path_params),
    case do_get(Url) of
        {not_found, _Url} ->
            {ok, S2};
        {ok, _Url, _Headers} ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;
run(getlist, KeyGen, _ValueGen, State) ->
    {NextUrl, S2} = next_url(State),
    Url = url(NextUrl, KeyGen, State#state.path_params, State#state.iter),
    case do_getlist(Url, []) of
        {not_found, _Url} ->
            {ok, S2};
        {ok, _Url, _Headers, Iter} ->
            {ok, S2#state{iter = Iter}};
        {error, Reason} ->
            {error, Reason, S2}
    end;
run(put, KeyGen, ValueGen, State) ->
    {NextUrl, S2} = next_url(State),
    Url = url(NextUrl, KeyGen, State#state.path_params),
    case do_put(Url, [], ValueGen) of
        {no_content, _Url} ->
            {error, {no_content, Url}, S2};
        ok ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;
run(putx, KeyGen, ValueGen, State) ->
    {NextUrl, S2} = next_url(State),
    Url = url(NextUrl, KeyGen, State#state.path_params),
    case do_put(Url, [], ValueGen) of
        {no_content, _Url} ->
            {ok, S2};
        ok ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;
run(delete, KeyGen, _ValueGen, State) ->
    {NextUrl, S2} = next_url(State),
    Url = url(NextUrl, KeyGen, State#state.path_params),
    case do_delete(Url, []) of
        {not_found, _Url} ->
            {error, {not_found, Url}, S2};
        ok ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;
run(deletex, KeyGen, _ValueGen, State) ->
    {NextUrl, S2} = next_url(State),
    Url = url(NextUrl, KeyGen, State#state.path_params),
    case do_delete(Url, []) of
        {not_found, _Url} ->
            {ok, S2};
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
    BaseUrl#url { path = lists:concat([BaseUrl#url.path, '/', KeyGen(), Params]) };
url(BaseUrl, Key, Params) ->
    BaseUrl#url { path = lists:concat([BaseUrl#url.path, '/', Key, Params]) }.

url(BaseUrl0, Key, Params, Iter) when is_binary(Iter)->
    url(BaseUrl0, Key, Params, erlang:binary_to_list(Iter));
url(BaseUrl0, Key, Params, Iter) ->
    BaseUrl = url(BaseUrl0, Key, Params),
    BaseUrl#url { path = lists:concat([BaseUrl#url.path, '?ls=true&iter=', Iter]) }.

do_get(Url) ->
    do_get(Url, []).

do_get(Url, Opts) ->
    case send_request(Url, [], get, [], [{response_format, binary}]) of
        {ok, "404", _Header, _Body} ->
            {not_found, Url};
        {ok, "300", Header, _Body} ->
            {ok, Url, Header};
        {ok, "200", Header, Body} ->
            case proplists:get_bool(body_on_success, Opts) of
                true ->
                    {ok, Url, Header, Body};
                false ->
                    {ok, Url, Header}
            end;
        {ok, Code, _Header, _Body} ->
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

do_getlist(Url, Opts) ->
    case send_request(Url, [], get, [], [{response_format, binary}]) of
        {ok, "404", _Header, _Body} ->
            {not_found, Url};
        {ok, "300", Header, _Body} ->
            {ok, Url, Header};
        {ok, "200", Header, Body} ->
            case catch mochijson2:decode(Body) of
                {struct, Fields} ->
                    %% ?DEBUG("Fields is ~p~n", [Fields]),
                    Iter = proplists:get_value(<<"iter">>, Fields),
                    case proplists:get_bool(body_on_success, Opts) of
                        true  -> {ok, Url, Header, Body, Iter};
                        false -> {ok, Url, Header, Iter}
                    end;
                Error ->
                    {error, Error}
            end;
        {ok, Code, _Header, _Body} ->
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

do_put(Url, Headers, ValueGen) ->
    Val = if is_function(ValueGen) ->
                  ValueGen();
             true ->
                  ValueGen
          end,
    case send_request(Url, Headers ++ [{'Content-Type', 'application/json'}],
                     put, Val, [{response_format, binary}]) of
        {ok, "204", _Header, _Body} ->
            {no_content, Url};
        {ok, "201", _Header, _Body} ->
            ok;
        {ok, Code, _Header, _Body} ->
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

do_delete(Url, Headers) ->
    case send_request(Url, Headers, delete, [], []) of
        {ok, "404", _Header, _Body} ->
            {not_found, Url};
        {ok, "204", _Header, _Body} ->
            ok;
        {ok, Code, _Header, _Body} ->
            {error, {http_error, Code}};
        {error, Reason} ->
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
            erlang:put(Key, erlang:now()),
            false;
        Time when is_tuple(Time) andalso size(Time) == 3 ->
            Diff = time:now_diff(erlang:now(), Time),
            if
                Diff >= Seconds * 1000000 ->
                    erlang:put(Key, erlang:now()),
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
            erlang:put({last_disconnect, Url#url.host}, erlang:now())
    end.


send_request(Url, Headers, Method, Body, Options) ->
    send_request(Url, Headers, Method, Body, Options, 3).

send_request(_Url, _Headers, _Method, _Body, _Options, 0) ->
    {error, max_retries};
send_request(Url, Headers, Method, Body, Options, Count) ->
    Pid = connect(Url),
    case catch(ibrowse_http_client:send_req(Pid, Url,
                                            Headers ++ basho_bench_config:get(hub_append_headers, []),
                                            Method, Body, Options,
                                            basho_bench_config:get(hub_request_timeout, 5000))) of
        {ok, Status, RespHeaders, RespBody} ->
            maybe_disconnect(Url),
            {ok, Status, RespHeaders, RespBody};
        Error ->
            clear_disconnect_freq(Url),
            disconnect(Url),
            case should_retry(Error) of
                true ->
                    send_request(Url, Headers, Method, Body, Options, Count-1);
                false ->
                    normalize_error(Method, Error)
            end
    end.


should_retry({error, send_failed}) ->
    true;
should_retry({error, connection_closed}) ->
    true;
should_retry({'EXIT', {normal, _}}) ->
    true;
should_retry({'EXIT', {noproc, _}}) ->
    true;
should_retry(_) ->
    false.

normalize_error(Method, {'EXIT', {timeout, _}}) ->
    {error, {Method, timeout}};
normalize_error(Method, {'EXIT', Reason}) ->
    {error, {Method, 'EXIT', Reason}};
normalize_error(Method, {error, Reason}) ->
    {error, {Method, Reason}}.

valgen(_) ->
    fun() -> <<"{\"type\":\"image/webp\",\"length\":100,\"props\":{}}">> end.
