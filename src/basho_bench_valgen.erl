%% -------------------------------------------------------------------
%%
%% basho_bench: Benchmarking Suite
%%
%% Copyright (c) 2009-2010 Basho Techonologies
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
-module(basho_bench_valgen).

-export([new/2,
         dimension/2]).

-include("basho_bench.hrl").

%% ====================================================================
%% API
%% ====================================================================

new({fixed_bin, Size}, Id)
  when is_integer(Size), Size >= 0 ->
    Source = init_source(Id),
    fun() -> data_block(Source, Size) end;
new({fixed_bin, Size, Val}, _Id)
  when is_integer(Size), Size >= 0, is_integer(Val), Val >= 0, Val =< 255 ->
    Data = list_to_binary(lists:duplicate(Size, Val)),
    fun() -> Data end;
new({fixed_char, Size}, _Id)
  when is_integer(Size), Size >= 0 ->
    fun() -> list_to_binary(lists:map(fun (_) -> random:uniform(95)+31 end, lists:seq(1,Size))) end;
new({exponential_bin, MinSize, Mean}, Id)
  when is_integer(MinSize), MinSize >= 0, is_number(Mean), Mean > 0 ->
    Source = init_source(Id),
    fun() -> data_block(Source, MinSize + trunc(basho_bench_stats:exponential(1 / Mean))) end;
new({uniform_bin, MinSize, MaxSize}, Id)
  when is_integer(MinSize), is_integer(MaxSize), MinSize < MaxSize ->
    Source = init_source(Id),
    Diff = MaxSize - MinSize,
    fun() -> data_block(Source, MinSize + random:uniform(Diff)) end;
new({function, Module, Function, Args}, Id)
  when is_atom(Module), is_atom(Function), is_list(Args) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            erlang:apply(Module, Function, [Id] ++ Args);
        _Error ->
            ?FAIL_MSG("Could not find valgen function: ~p:~p\n", [Module, Function])
    end;
new({uniform_int, MaxVal}, _Id)
  when is_integer(MaxVal), MaxVal >= 1 ->
    fun() -> random:uniform(MaxVal) end;
new({uniform_int, MinVal, MaxVal}, _Id)
  when is_integer(MinVal), is_integer(MaxVal), MaxVal > MinVal ->
    fun() -> random:uniform(MinVal, MaxVal) end;
new({file_line_bin, Path}, Id) ->
    new({file_line_bin, Path, repeat}, Id);
new({file_line_bin, Path, DoRepeat}, Id) ->
    Open = fun(File) ->
               Opts = [read, raw, binary, {read_ahead, 16*1024*1024}],
               R0 = io_lib:format("~p open ~p ~n", [calendar:local_time(), File]),
               file:write_file("/tmp/basho.record", R0, [append]),
               {ok, FileH} = file:open(File, Opts),
               FileH
           end,
    Chomp = fun(LineBin) ->
                WantedLen = byte_size(LineBin) - 1,
                <<Chomped:WantedLen/binary, _/binary>> = LineBin,
                Chomped
            end,
    Loop = fun(L, FH, Repeat) ->
            {Line, FH2, NewRepeat}  = case file:read_line(FH) of
                {ok, LineBin} ->
                    {Chomp(LineBin), FH, Repeat};
                eof when Repeat == norepeat ->
                    file:close(FH),
                    {empty_valgen, FH, Repeat};
                eof when Repeat == [] ->
                    file:close(FH),
                    {empty_valgen, FH, []};
                eof when is_list(Repeat) ->
                    [Seq | RestRepeat] = Repeat,
                    file:close(FH),
                    FH_ = Open(filename:join(Path, Seq)),
                    {ok, LineBin} = file:read_line(FH_),
                    {Chomp(LineBin), FH_, RestRepeat};
                eof ->
                    ?INFO("CURRENT EOF, REOPEN!", []),
                    file:close(FH),
                    FH_ = Open(Path),
                    {ok, LineBin} = file:read_line(FH_),
                    {Chomp(LineBin), FH_}
            end,
            receive
                {val_req, From} -> From ! {val_reply, Line}
            end,
            L(L, FH2, NewRepeat)
    end,
    if Id == 1 ->
            spawn(fun() ->
                        register(file_valgen, self()),
                        {FH, Repeat} = case filelib:is_dir(Path) of
                            true ->
                                [First | Rest] = DoRepeat,
                                {Open(filename:join(Path, First)), Rest};
                            false ->
                                {Open(Path), DoRepeat}
                        end,
                        Loop(Loop, FH, Repeat)
                end);
        true ->
            ok
    end,
    fun() ->
            file_valgen ! {val_req, self()},
            receive
                {val_reply, empty_valgen} ->
                    throw({stop, empty_valgen});
                {val_reply, Bin} ->
                    Bin
            end
    end;
new(Bin, _Id) when is_binary(Bin) ->
    fun() -> Bin end;
new(List, _Id) when is_list(List) ->
    List;
new(Other, _Id) ->
    ?FAIL_MSG("Invalid value generator requested: ~p\n", [Other]).

dimension({fixed_bin, Size}, KeyDimension) ->
    Size * KeyDimension;
dimension(_Other, _) ->
    0.0.



%% ====================================================================
%% Internal Functions
%% ====================================================================

-define(TAB, valgen_bin_tab).

init_source(Id) ->
    init_source(Id, basho_bench_config:get(?VAL_GEN_BLOB_CFG, undefined)).

init_source(1, undefined) ->
    SourceSz = basho_bench_config:get(?VAL_GEN_SRC_SIZE, 96*1048576),
    ?INFO("Random source: calling crypto:rand_bytes(~w) (override with the '~w' config option\n", [SourceSz, ?VAL_GEN_SRC_SIZE]),
    Bytes = crypto:rand_bytes(SourceSz),
    try
        ?TAB = ets:new(?TAB, [public, named_table]),
        true = ets:insert(?TAB, {x, Bytes})
    catch _:_ -> rerunning_id_1_init_source_table_already_exists
    end,
    ?INFO("Random source: finished crypto:rand_bytes(~w)\n", [SourceSz]),
    {?VAL_GEN_SRC_SIZE, SourceSz, Bytes};
init_source(_Id, undefined) ->
    [{_, Bytes}] = ets:lookup(?TAB, x),
    {?VAL_GEN_SRC_SIZE, size(Bytes), Bytes};
init_source(Id, Path) ->
    {Path, {ok, Bin}} = {Path, file:read_file(Path)},
    if Id == 1 -> ?DEBUG("path source ~p ~p\n", [size(Bin), Path]);
       true    -> ok
    end,
    {?VAL_GEN_BLOB_CFG, size(Bin), Bin}.

data_block({SourceCfg, SourceSz, Source}, BlockSize) ->
    case SourceSz - BlockSize > 0 of
        true ->
            Offset = random:uniform(SourceSz - BlockSize),
            <<_:Offset/bytes, Slice:BlockSize/bytes, _Rest/binary>> = Source,
            Slice;
        false ->
            ?WARN("~p is too small ~p < ~p\n",
                  [SourceCfg, SourceSz, BlockSize]),
            Source
    end.
