%% @author Justin Sheehy <justin@basho.com>
%% @author Andy Gross <andy@basho.com>
%% @copyright 2007-2014 Basho Technologies
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

-module(webmachine_resource).
-author('Justin Sheehy <justin@basho.com>').
-author('Andy Gross <andy@basho.com>').
-export([new/4, wrap/2, wrap/3]).
-export([do/3,log_d/2,stop/1]).

-include("wm_resource.hrl").
-include("wm_reqdata.hrl").
-include("wm_reqstate.hrl").

new(R_Mod, R_ModState, R_ModExports, R_Trace) ->
    {?MODULE, R_Mod, R_ModState, R_ModExports, R_Trace}.

default(ping) ->
    no_default;
default(service_available) ->
    true;
default(resource_exists) ->
    true;
default(auth_required) ->
    true;
default(is_authorized) ->
    true;
default(forbidden) ->
    false;
default(allow_missing_post) ->
    false;
default(malformed_request) ->
    false;
default(uri_too_long) ->
    false;
default(known_content_type) ->
    true;
default(valid_content_headers) ->
    true;
default(valid_entity_length) ->
    true;
default(options) ->
    [];
default(allowed_methods) ->
    ['GET', 'HEAD'];
default(known_methods) ->
    ['GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'TRACE', 'CONNECT', 'OPTIONS'];
default(content_types_provided) ->
    [{"text/html", to_html}];
default(content_types_accepted) ->
    [];
default(delete_resource) ->
    false;
default(delete_completed) ->
    true;
default(post_is_create) ->
    false;
default(create_path) ->
    undefined;
default(base_uri) ->
        undefined;
default(process_post) ->
    false;
default(language_available) ->
    true;
default(charsets_provided) ->
    no_charset; % this atom causes charset-negotation to short-circuit
    % the default setting is needed for non-charset responses such as image/png
    %    an example of how one might do actual negotiation
    %    [{"iso-8859-1", fun(X) -> X end}, {"utf-8", make_utf8}];
default(encodings_provided) ->
    [{"identity", fun(X) -> X end}];
    % this is handy for auto-gzip of GET-only resources:
    %    [{"identity", fun(X) -> X end}, {"gzip", fun(X) -> zlib:gzip(X) end}];
default(variances) ->
    [];
default(is_conflict) ->
    false;
default(multiple_choices) ->
    false;
default(previously_existed) ->
    false;
default(moved_permanently) ->
    false;
default(moved_temporarily) ->
    false;
default(last_modified) ->
    undefined;
default(expires) ->
    undefined;
default(generate_etag) ->
    undefined;
default(finish_request) ->
    true;
default(validate_content_checksum) ->
    not_validated;
default(_) ->
    no_default.

wrap(Mod, Args, {?MODULE, _, _, _, _}) ->
    wrap(Mod, Args).

wrap(Mod, Args) ->
    case Mod:init(Args) of
        {ok, ModState} ->
            {ok, webmachine_resource:new(Mod, ModState,
                           orddict:from_list(Mod:module_info(exports)), false)};
        {{trace, Dir}, ModState} ->
            {ok, File} = open_log_file(Dir, Mod),
            log_decision(File, v3b14),
            log_call(File, attempt, Mod, init, Args),
            log_call(File, result, Mod, init, {{trace, Dir}, ModState}),
            {ok, webmachine_resource:new(Mod, ModState,
                orddict:from_list(Mod:module_info(exports)), File)};
        _ ->
            {stop, bad_init_arg}
    end.

do(#wm_resource{}=Res, Fun, ReqProps) ->
    #wm_resource{module=R_Mod, modstate=R_ModState,
                 modexports=R_ModExports, trace=R_Trace} = Res,
    do(Fun, ReqProps, {?MODULE, R_Mod, R_ModState, R_ModExports, R_Trace});
do(Fun, ReqProps, {?MODULE, R_Mod, _, R_ModExports, R_Trace}=Req)
  when is_atom(Fun) andalso is_list(ReqProps) ->
    case lists:keyfind(reqstate, 1, ReqProps) of
        false -> RState0 = undefined;
        {reqstate, RState0} -> ok
    end,
    put(tmp_reqstate, empty),
    {Reply, ReqData, NewModState} = handle_wm_call(Fun,
                    (RState0#wm_reqstate.reqdata)#wm_reqdata{wm_state=RState0},
                    Req),
    ReqState = case get(tmp_reqstate) of
                   empty -> RState0;
                   X -> X
               end,
    %% Do not need the embedded state anymore
    TrimData = ReqData#wm_reqdata{wm_state=undefined},
    {Reply,
     webmachine_resource:new(R_Mod, NewModState, R_ModExports, R_Trace),
     ReqState#wm_reqstate{reqdata=TrimData}}.

handle_wm_call(Fun, ReqData, {?MODULE,R_Mod,R_ModState,R_ModExports,R_Trace}=Req) ->
    case default(Fun) of
        no_default ->
            resource_call(Fun, ReqData, Req);
        Default ->
            case orddict:is_key(Fun, R_ModExports) of
                true ->
                    resource_call(Fun, ReqData, Req);
                false ->
                    if is_pid(R_Trace) ->
                            log_call(R_Trace,
                                     not_exported,
                                     R_Mod, Fun, [ReqData, R_ModState]);
                       true -> ok
                    end,
                    {Default, ReqData, R_ModState}
            end
    end.

trim_trace([{M,F,[RD = #wm_reqdata{},S],_}|STRest]) ->
    TrimState = (RD#wm_reqdata.wm_state)#wm_reqstate{reqdata='REQDATA'},
    TrimRD = RD#wm_reqdata{wm_state=TrimState},
    [{M,F,[TrimRD,S]}|STRest];
trim_trace(X) -> X.

resource_call(F, ReqData, {?MODULE, R_Mod, R_ModState, _, R_Trace}) ->
    case R_Trace of
        false -> nop;
        _ -> log_call(R_Trace, attempt, R_Mod, F, [ReqData, R_ModState])
    end,
    Result = try
        apply(R_Mod, F, [ReqData, R_ModState])
    catch C:R ->
            Reason = {C, R, trim_trace(erlang:get_log())},
            {{error, Reason}, ReqData, R_ModState}
    end,
        case R_Trace of
        false -> nop;
        _ -> log_call(R_Trace, result, R_Mod, F, Result)
    end,
    Result.

log_d(#wm_resource{}=Res, DecisionID) ->
    #wm_resource{module=R_Mod, modstate=R_ModState,
                 modexports=R_ModExports, trace=R_Trace} = Res,
    log_d(DecisionID, {?MODULE, R_Mod, R_ModState, R_ModExports, R_Trace});
log_d(DecisionID, {?MODULE, _, _, _, R_Trace}) ->
    case R_Trace of
        false -> nop;
        _ -> log_decision(R_Trace, DecisionID)
    end.

stop(#wm_resource{trace=R_Trace}) -> close_log_file(R_Trace);
stop({?MODULE, _, _, _, R_Trace}) -> close_log_file(R_Trace).

log_call(File, Type, M, F, Data) ->
    io:format(File,
              "{~p, ~p, ~p,~n ~p}.~n",
              [Type, M, F, escape_trace_data(Data)]).

escape_trace_data(Fun) when is_function(Fun) ->
    {'WMTRACE_ESCAPED_FUN',
     [erlang:fun_info(Fun, module),
      erlang:fun_info(Fun, name),
      erlang:fun_info(Fun, arity),
      erlang:fun_info(Fun, type)]};
escape_trace_data(Pid) when is_pid(Pid) ->
    {'WMTRACE_ESCAPED_PID', pid_to_list(Pid)};
escape_trace_data(Port) when is_port(Port) ->
    {'WMTRACE_ESCAPED_PORT', erlang:port_to_list(Port)};
escape_trace_data(List) when is_list(List) ->
    escape_trace_list(List, []);
escape_trace_data(R=#wm_reqstate{}) ->
    list_to_tuple(
      escape_trace_data(
        tuple_to_list(R#wm_reqstate{reqdata='WMTRACE_NESTED_REQDATA'})));
escape_trace_data(Tuple) when is_tuple(Tuple) ->
    list_to_tuple(escape_trace_data(tuple_to_list(Tuple)));
escape_trace_data(Other) ->
    Other.

escape_trace_list([Head|Tail], Acc) ->
    escape_trace_list(Tail, [escape_trace_data(Head)|Acc]);
escape_trace_list([], Acc) ->
    %% proper, nil-terminated list
    lists:reverse(Acc);
escape_trace_list(Final, Acc) ->
    %% non-nil-terminated list, like the dict module uses
    lists:reverse(tl(Acc))++[hd(Acc)|escape_trace_data(Final)].

log_decision(File, DecisionID) ->
    io:format(File, "{decision, ~p}.~n", [DecisionID]).

open_log_file(Dir, Mod) ->
    Now = {_,_,US} = os:timestamp(),
    {{Y,M,D},{H,I,S}} = calendar:now_to_universal_time(Now),
    Filename = io_lib:format(
                 "~s/~p-~4..0B-~2..0B-~2..0B"
                 "-~2..0B-~2..0B-~2..0B.~6..0B.wmtrace",
                 [Dir, Mod, Y, M, D, H, I, S, US]),
    file:open(Filename, [write]).

close_log_file(File) when is_pid(File) ->
    file:close(File);
close_log_file(_) ->
    ok.
