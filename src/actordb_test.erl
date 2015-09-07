-module(actordb_test).
-export([batch/0, idtest/0, ins/0, read_timebin/0]).
-include_lib("eunit/include/eunit.hrl").
-include_lib("actordb_sqlproc.hrl").
% -include_lib("actordb.hrl").
% misc internal tests
% general tests are in actordb/test/dist_test.erl and run with detest


batch() ->
	Actor = butil:tobin(butil:epochsec()),
	{sql_error,A,B} = actordb_sqlproc:write({Actor,type1},[create],"insert into tab values (1,'a',2,3);",actordb_actor),
	?AINF("Create actor with error: {sql_error,~p,~p}",[A,B]),
	% Actor now exists with schema and no data (insert failed)
	Pid = distreg:whereis({Actor,type1}),
	% For every write create ref to match against (id and ref).
	W = [{{self(),make_ref()},#write{sql = "insert into tab values (1,'a',2);"}},
	{{self(),make_ref()},#write{sql = "insert into tab values (2,'b',3);"}},
	{{self(),make_ref()},#write{sql = "insert into tab values (3,'c',4,5);"}},
	{{self(),make_ref()},#write{sql = "insert into tab values (4,'d',5);"}},
	{{self(),make_ref()},#write{sql = "insert into tab values (5,'aa',1);"}}],
	Pid ! {batch,W},
	ok = recbatch(W,1),

	R = [{{self(),make_ref()}, #read{sql = "select * from tab where id=1;"}},
	{{self(),make_ref()}, #read{sql = "select * from tab where id=2;"}},
	{{self(),make_ref()}, #read{sql = "select * from tab where xid=3;"}},
	{{self(),make_ref()}, #read{sql = "select * from tab where id=4;"}},
	{{self(),make_ref()}, #read{sql = "select * from tab where id=5;"}}],
	Pid ! {batch,R},
	ok = recbatch(R,1),

	ok.

recbatch([{{_,Ref},R}|T],Id) ->
	receive
		{Ref,{sql_error,A,B}} when Id == 3 ->
			?AINF("Correctly received error for invalid sql in batch: ~p,~p",[A,B]),
			recbatch(T,Id+1);
		{Ref,{ok,{changes,Id,1}}} when element(1,R) == write ->
			?AINF("Received correct write response for id=~p",[Id]),
			recbatch(T,Id+1);
		{Ref,{ok,[{columns,{<<"id">>,<<"txt">>,<<"i">>}},{rows,[{Id,_,_}]}]}} when element(1,R) == read ->
			?AINF("Received correct read response for id=~p",[Id]),
			recbatch(T,Id+1)
		% X when element(1,R) == read ->
		% 	?AERR("REC read: ~p",[X]),
		% 	recbatch(T,Id+1)
	after 1000 ->
		timeout
	end;
recbatch([],_) ->
	ok.


idtest() ->
	N = 100,
	{ok,From} = actordb_idgen:getid(),
	ets:new(idtest,[named_table,public,set,{write_concurrency,true}]),
	Pids = [element(1,spawn_monitor(fun() -> idtest1(From+500000,0) end)) || _ <- lists:seq(1,N)],
	Res = idtest_wait(Pids),
	% io:format("list: ~p~n",[ets:tab2list(idtest)]),
	ets:delete(idtest),
	case Res of
		ok ->
			ok;
		_ ->
			throw(Res)
	end.

idtest_wait([]) ->
	ok;
idtest_wait(Pids) ->
	receive
		{'DOWN',_Monitor,_Ref,PID,Reason} when Reason == normal ->
			% io("Done ~p",[PID]),
			idtest_wait(lists:delete(PID,Pids));
		{'DOWN',_Monitor,_Ref,_PID,Reason} ->
			Reason
	end.

idtest1(Max,Run) when Run rem 1000 == 0 ->
	io:format("~p at ~p~n",[self(),Run]),
	idtest1(Max,Run+1);
idtest1(Max,Run) ->
	{ok,N} = actordb_idgen:getid(),
	case N < Max of
		true ->
			case catch ets:insert_new(idtest,{N,self()}) of
				true ->
					% io:format("ok: ~p me=~p~n",[N,self()]),
					idtest1(Max,Run+1);
				_ ->
					io:format("Failed on ~p, me=~p, ex=~p~n",[N,self(),ets:lookup(idtest,N)]),
					exit(error)
			end;
		false ->
			exit(normal)
	end.


ins() ->
	{ok,B} = file:read_file("inserts.sql"),
	Lines = binary:split(B,<<"\n">>,[global]),
	S = os:timestamp(),
	ins(Lines),
	io:format("Diff=~p, inserts=~p~n",[timer:now_diff(os:timestamp(),S),length(Lines)]).
ins([<<"[\"ACTORDB QUERY (mapl):\",<<\"",Rem/binary>>|T]) ->
	Sz = (byte_size(Rem)-5),
	<<Useful:Sz/binary,_/binary>> = Rem,
	% io:format("Useful: ~p~n",[Useful]),
	{ok,_} = actordb:exec(Useful),
	ins(T);
ins([<<>>]) ->
	[];
ins([]) ->
	ok.


read_timebin() ->
	{ok,<<Numer:64/unsigned-little,Delim:64/unsigned-little,Times/binary>>} = file:read_file("time.bin"),
	read_timebin(Numer,Delim,Times,[]).

read_timebin(N,D,<<Id,Val:64/unsigned-little,Rem/binary>>,L) ->
	Int = round((Val*N/D)/1000),
	case Id of
		0 ->
			print_times(lists:reverse(L)),
			read_timebin(N,D,Rem,[{0,Int}]);
		_ ->
			read_timebin(N,D,Rem,[{Id,Int}|L])
	end;
read_timebin(_,_,_,_) ->
	ok.

print_times([]) ->
	ok;
print_times([{0,Time}|T]) ->
	io:format("Start:~p~n",[Time]),
	print_times(T,Time,Time).

print_times([{Id,Int}|T],First,Prev) ->
	io:format("~p: ~p first_diff=~p prev_diff=~p~n",[Id,Int, Int-First, Int-Prev]),
	print_times(T,First,Int);
print_times([],_,_) ->
	ok.
