-module(basho_bench_influxdb).

-include("basho_bench.hrl").
-export([new/0,
         write/4]).

-record(conn, {host, port, dbname, request_url, client}).

new() ->
    Host0 = basho_bench_config:get(influxdb_host, "127.0.0.1"),
    Port0 = basho_bench_config:get(influxdb_port, 8086),
    Dbname = basho_bench_config:get(influxdb_dbname, "bashobench"),

    application:start(ibrowse),

    [{Host, Port}] = basho_bench_config:normalize_ips([Host0], Port0),
    {ok, request_url(#conn{host=Host, port=Port, dbname=Dbname})}.

write(Name, Tags, Fields, #conn{request_url=Url}=Conn) ->
    Body = format_body(Name, Tags, Fields),
    ?DEBUG("POST ~p ~p", [Url, Body]),
    send_request(Conn, Body, 3).

send_request(_Conn, _Body, 0) ->
    {error, max_retries};
send_request(#conn{request_url=Url}=Conn, Body, Count) ->
    case ibrowse:send_req(Url, [], post, Body) of
        {ok, "204", _RespHeaders, _RespBody} ->
            ok;
        Error ->
            ?ERROR("POST influxdb: ~p failed: ~p~n", [Url, Error]),
            timer:sleep(50),
            send_request(Conn, Body, Count-1)
    end.

request_url(#conn{host=Host, port=Port, dbname=Dbname}=Conn) ->
    Conn#conn{request_url = lists:flatten(io_lib:format("http://~s:~p/write?db=~s",
                                                        [Host, Port, Dbname]))}.

format_body(Name, Tags, Fields) when is_list(Tags), is_list(Fields) ->
    <<(normalize_key(Name))/binary,
      (binary_join(Tags, left))/binary,
      $\s,
      (binary_join(Fields, right))/binary>>.

normalize_key(K) when is_list(K) ->
    normalize_key(list_to_binary(K));
normalize_key(K) when is_atom(K) ->
    normalize_key(atom_to_list(K));
normalize_key(K) when is_binary(K) ->
    K.

normalize_value(V) when is_atom(V) ->
    normalize_value(atom_to_list(V));
normalize_value(V) when is_list(V) ->
    normalize_value(list_to_binary(V));
normalize_value(V) when is_integer(V) ->
    normalize_value(integer_to_binary(V));
normalize_value(V) when is_float(V) ->
    normalize_value(io_lib:format("~.4f", [V]));
normalize_value(V) when is_binary(V) ->
    V.


binary_join([], _Pos) ->
    <<>>;
binary_join(List, left) ->
    lists:foldl(fun ({K, V}, A) ->
                        <<A/binary, $,, (normalize_key(K))/binary, $=, (normalize_value(V))/binary>>
                end, <<>>, List);
binary_join(List, right) ->
    Full =
        lists:foldl(fun ({K, V}, A) ->
                            <<A/binary, (normalize_key(K))/binary, $=, (normalize_value(V))/binary, $,>>
                    end, <<>>, List),
    Len = byte_size(Full) - 1,
    <<Part:Len/bytes, $,>> = Full,
    Part.
