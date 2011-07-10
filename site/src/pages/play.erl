-module(play).
-include_lib("nitrogen_core/include/wf.hrl").
-include("records.hrl").
-compile(export_all).

main() ->
	case game_server:exists(id()) of
		true ->
			#template{file="./site/templates/game.html"};
		false ->
			wf:wire(#alert{text="Invalid Game"}),
			wf:redirect("/")
	end.

id() ->	
	?PRINT(wf:state(gameid)),
	case wf:state(gameid) of
		undefined ->
			case string:to_integer(wf:path_info()) of
				{error,_} -> 0;
				{Int,_} -> 
					wf:state(gameid,Int),
					Int
			end;
		ID -> ID
	end.

title() ->
	game_server:title(id()).


main_interaction() ->
	%% initialize the api
	wf:wire(#api{name=pict_api,tag=unused}),

	case player:name() of
		Undef when Undef==undefined;Undef=="" ->
			username_form();
		Name -> 
			canvas(Name)
	end.
		
username_form() ->
	wf:wire(username_cont,name,#validate{validators=[
		#is_required{}
	]}),
	#panel{id=username_form,class=username_form,body=[
		#label{text="What's your name?"},
		#textbox{id=name,text=""},
		#br{},
		#button{text="Continue",id=username_cont,postback=username}
	]}.

canvas(Playername) ->
	{ok,CometPid} = wf:comet(fun() -> game_join(Playername) end),
	wf:state(cometpid,CometPid),

	[
		#panel{id=headermessage,text=["Welcome ",Playername]},
		"<canvas class=game_canvas width=640 height=480>Get a browser that doesn't suck</canvas>",
		#panel{id=controls,body=controls()},
		#br{},


		"<script>enable_drawing()</script>",
		#button{text="Erase",postback=erase}
	].
	

playerlist() ->
	Players = game_server:playerlist(id()),
	#table{id=playerlist,rows=[
		lists:map(fun(P=#player{}) ->
			#tablerow{cells=[
				#tablecell{text=P#player.name},
				#tablecell{text=P#player.score}
			]};
			(_) -> []	%% For outdated records
		end,Players)
	]}.

ready_button() ->
	#button{text="Ready",postback=ready}.

clock() ->
	#panel{id=clock,body=[
		ready_button()
	]}.


controls() ->
	[].


activitylog() ->
	#panel{id=activitylog}.


update_playerlist() ->
	wf:replace(playerlist,playerlist()).

%% -----------------actions and postbacksx-----------------------%%

event(username) ->
	Name = wf:q(name),
	player:name(Name),
	wf:replace(username_form,canvas(Name));
event(ready) ->
	send_to_comet(fun(GamePid) -> game_server:ready(GamePid) end);
event(unready) ->
	send_to_comet(fun(GamePid) -> game_server:unready(GamePid) end);
event(guess) ->
	Guess = wf:q(guess),
	send_to_comet(fun(GamePid) -> game_server:guess(GamePid,Guess) end);
event(erase) ->
	wf:wire("erase()");
event(_) -> 
	ok.

api_event(pict_api,_,ActionList) ->
	send_to_comet(fun(GamePid) -> game_server:queue(GamePid,ActionList) end).



%% ---------------comet game stuff--------------------%%

%% This will send a function to the comet process to be executed there, so that the pid is ready properly
%% The alternative would be to allow multiple pids per client, this way seems easier right now
%% Maybe it's a mistake
%% The fun must be arity 1 and the only argument should be GamePid, which will be passed in by the loop
send_to_comet(Fun) when is_function(Fun,1) ->
	Pid = wf:state(cometpid),
	Pid ! {from_page,Fun}.

%% Join the game and initiate the comet loop
game_join(Name) ->
	GamePid = game_master:get_pid(id()),
	game_server:join(GamePid,Name),
	game_loop(GamePid).

game_loop(GamePid) ->
	process_flag(trap_exit,true),

	receive 
		{'EXIT',_,Message} ->
			game_server:leave(GamePid),
			exit(done);
		{join,Player} ->
			in_join(Player);
		{leave,Player} ->
			in_leave(Player);
		{correct,Player,Points} ->
			in_correct(Player,Points);
		{ready,Player} ->
			in_ready(Player);
		{unready,Player} ->
			in_unready(Player);
		{all_correct} ->
			in_all_correct();
		{queue,ActionList} ->
			in_queue(ActionList);
		{new_round,Player} ->
			in_new_round(Player);
		{round_over} ->
			in_round_over();
		{you_are_up,Word} ->
			in_you_are_up(Word);
		{timer_update,SecondsLeft} ->
			in_timer_update(SecondsLeft);
		{from_page,Fun} ->
			Fun(GamePid)
	end,
	wf:flush(),
	game_loop(GamePid).

add_message(Class,Msg) ->
	wf:insert_bottom(activitylog,#panel{text=Msg,class=Class}).
	
in_join(Player) ->
	add_message(log_join,Player ++ " has joined the game"),
	update_playerlist().

in_leave(Player) ->
	add_message(log_leave,Player ++ " has left the game "),
	update_playerlist().

in_correct(Player,Points) ->
	add_message(log_correct,Player ++ " got it for " ++ wf:to_list(Points) ++ " points"),
	update_playerlist().

in_ready(Player) ->
	add_message(log_ready,Player ++ " is ready to start"),
	update_playerlist().

in_unready(Player) ->
	add_message(log_unready,Player ++ " is not ready to start"),
	update_playerlist().

in_all_correct() ->
	add_message(log_correct,"Everyone got it!").

in_queue(Queue) ->
	NewQueue = encode_queue(Queue),
	wf:wire("load_queue(" ++ NewQueue ++ ")").

in_you_are_up(Word) ->
	wf:update(headermessage,"It's your turn to draw. Your word: " ++ Word),
	wf:wire("enable_drawing()").

in_new_round(Player) ->
	wf:update(headermessage,"It's " ++ Player ++ "'s turn to draw"),
	wf:wire("start_round()").

in_round_over() ->
	wf:wire("round_over()").

in_timer_update(SecondsLeft) ->
	wf:wire("timer_update(" ++ wf:to_list(SecondsLeft) ++ ")").


%% I use a bunch of ++'s here. I know it's slow, so sue me
encode_queue(Queue) ->
	Q1 = lists:map(fun(Action) ->
		JSAction = string:join(lists:map(fun encode_queue_item/1,Action),","),
		"[" ++ JSAction ++ "]"
	end,Queue),
	"[" ++ string:join(Q1,",") ++ "]".


encode_queue_item(N) when is_integer(N) ->
	wf:to_list(N);
encode_queue_item(AS) when is_atom(AS);is_list(AS) ->
	"\"" ++ wf:to_list(AS) ++ "\"".
