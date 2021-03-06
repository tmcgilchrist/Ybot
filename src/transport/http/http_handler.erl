%%%-----------------------------------------------------------------------------
%%% @author 0xAX <anotherworldofworld@gmail.com>
%%% @doc
%%% Ybot http requests handler.
%%% @end
%%%-----------------------------------------------------------------------------
-module(http_handler).

-export([init/3]).
-export([handle/2]).
-export([terminate/3]).

init(_Transport, Req, []) ->
    {ok, Req, undefined}.

handle(Req, State) ->
    % Get request method
    {Method, Req2} = cowboy_req:method(Req),
    % Check method
    case Method of
        % Post request. Execute plugin.
        <<"POST">> ->
            % Try to get body request
            HasBody = cowboy_req:has_body(Req2),
            % Check body
            case HasBody of
                true ->
                    % Get body
                    {ok, [{Body, _}], _} = cowboy_req:body_qs(Req2),
                    % Get headers
                    {Headers, _} = cowboy_req:headers(Req2),
                    % handle requets
                    do_post(Body, Headers, Req2);
                false ->
                    % Send error message
                    cowboy_req:reply(400, [], <<"Missing body.">>, Req)
            end;
        % Other methods
        _ ->
            % do nothing
            pass
    end,
    {ok, Req2, State}.

terminate(_Reason, _Req, _State) ->
    ok.

%% @doc Handle post requets
do_post(Data, Headers, Req) ->
    % Check content type
    Message = case lists:keyfind(<<"content-type">>, 1, Headers) of
                false ->
                    % do nothing
                    Data;
                {_, ContentType} ->
                    case lists:member("application/json", string:tokens(binary_to_list(ContentType), ",")) of
                        true ->
                            % try to decode json
                            try
                                {DecodeJson} = jiffy:decode(Data),
                                % Get type
                                {_, Type} = lists:keyfind(<<"type">>, 1, DecodeJson),
                                %% Get command
                                {_, JsonCommand} = lists:keyfind(<<"content">>, 1, DecodeJson),
                                % return
                                {Type, JsonCommand}
                            catch _ : _ ->
                                wrong_json
                            end;
                        false ->
                            Data
                    end
            end,
    case Message of
        wrong_json ->
            cowboy_req:reply(400, [], "Wrong json data", Req);
        {CommandType, Command} ->
            % Check command type
            case CommandType of
                <<"broadcast">> ->
                    ybot_utils:broadcast(Command);
                <<"response">> ->
                    handle_data(Command, Req);
                % Send error message
                _ ->
                    cowboy_req:reply(400, [], "Wrong command type", Req)
                end;
        _ ->
            handle_data(Data, Req)
    end.

%% doc Handle incoming data
handle_data(Data, Req) ->
    % Match incoming message
    case string:tokens(binary_to_list(Data), " \r\n") of
        [_BotNick, "hi"] ->
            % Send response
            cowboy_req:reply(200, [], "Hello :)", Req);
        [_BotNick, "bye"] ->
            % Send response
            cowboy_req:reply(200, [], "Good bue", Req);
        [_BotNick, "history"] ->
            % Get history
            History = gen_server:call(ybot_history, {get_history, self()}),
            % Send response
            cowboy_req:reply(200, [], History, Req);
        [_BotNick, "plugins?"] ->
            % Get plugins
            Plugins = gen_server:call(ybot_manager, get_plugins),
            PluginNames = lists:map(fun({_, _, Pl, _}) -> Pl end, Plugins),
            % Send plugins label
            cowboy_req:reply(200, [], "Plugins: " ++ string:join(PluginNames, ", ") ++ "\n" ++ "That's all :)", Req);
        [_BotNick, Command | _] ->
                % Get command arguments
                Args = string:tokens(ybot_utils:split_at_end(binary_to_list(Data), Command), "\r\n"),
                % Try to execute plugin and resend result
                case handle_command(Command, Args, self()) of
                    wrong_plugin ->
                        % send response
                        cowboy_req:reply(200, [], <<"I don't know anything about ">>, Req);
                    Result ->
                        % send response
                        cowboy_req:reply(200, [], Result, Req)
                end;
        % this is not our command
        _ ->
            % do nothing
            pass
    end.

%% @doc Try to find plugin and execute it
handle_command(Command, Args, TransportPid) ->
    % Get plugin metadata
    TryToFindPlugin = gen_server:call(ybot_manager, {get_plugin, Command}),
    % Check plugin
    case TryToFindPlugin of
        wrong_plugin ->
            % plugin not found
            wrong_plugin;
        {plugin, "erlang", PluginName, AppModule} ->
            % execute plugin
            Result = AppModule:execute(Args),
            % Save command to history
            ok = gen_server:cast(ybot_history, {update_history, TransportPid, "Ybot " ++ PluginName ++ " " ++ Args ++ "\n"}),
            % send result to chat
            Result;
        {plugin, Lang, _PluginName, PluginPath} ->
            % execute plugin
            Result = os:cmd(Lang ++ " " ++ PluginPath ++ " \'" ++ Args ++ "\'"),
            % Save command to history
            ok = gen_server:cast(ybot_history, {update_history, TransportPid, "Ybot " ++ Command ++ " " ++ Args ++ "\n"}),
            % return result
            Result
    end.