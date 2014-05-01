% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
-include_lib("actordb.hrl").
-include_lib("kernel/include/file.hrl").

% since sqlproc gets called so much, logging from here often makes it more difficult to find a bug.
% -define(NOLOG,1).
-define(EVNUM,<<"1">>).
-define(EVCRC,<<"2">>).
-define(SCHEMA_VERS,<<"3">>).
-define(ATYPE,<<"4">>).
-define(COPYFROM,<<"5">>).
-define(MOVEDTO,<<"6">>).
-define(ANUM,<<"7">>).
-define(WLOG_STATUS,<<"8">>).
-define(EVTERM,<<"9">>).
-define(EVNUMI,1).
-define(EVCRCI,2).
-define(SCHEMA_VERSI,3).
-define(ATYPEI,4).
-define(COPYFROMI,5).
-define(MOVEDTOI,6).
-define(ANUMI,7).
-define(WLOG_STATUSI,8).
-define(EVTERMI,9).

-define(WLOG_NONE,0).
-define(WLOG_ABANDONDED,-1).
-define(WLOG_ACTIVE,1).

-define(FLAG_CREATE,1).
-define(FLAG_ACTORNUM,2).
-define(FLAG_EXISTS,4).
-define(FLAG_NOVERIFY,8).
-define(FLAG_TEST,16).
-define(FLAG_STARTLOCK,32).
-define(FLAG_NOHIBERNATE,64).


% Log events to the actual sqlite db file. For debugging.
% When shards are being moved across nodes it often may not be clear what exactly has been happening
% to an actor.
% -define(DODBLOG,1).
% -compile(export_all).

-record(flw,{node,match_index, match_term, next_index, file}).

-record(dp,{db, actorname,actortype, evnum = 0,evterm = 0,prev_evnum = 0, prev_evterm = 0, 
			activity = 0, timerref, start_time,
			activity_now,schemanum,schemavers,flags = 0,
	% Raft parameters  (lastApplied = evnum)
	% follower_indexes: [#flw,..]
	current_term = 0,voted_for, commit_index = 0, follower_indexes = [],
	% leader parameters
	start_write = {0,0,0},confirmations_left = 0,
	% EvNum,EvTerm of first item in wal
	wal_from = {0,0},
	% locked is a list of pids or markers that needs to be empty for actor to be unlocked.
	locked = [],
	% Multiupdate id, set to {Multiupdateid,TransactionNum} if in the middle of a distributed transaction
	transactionid, transactioncheckref,
  % actordb_sqlproc is not used directly, it always has a callback module that sits in front of it,
  %  providing an external interface
  %  to a sqlite backed process.
  cbmod, cbstate,
  % callfrom is who is calling, callres result of sqlite call (need to replicate before replying)
  callfrom,callres,
  % queue which holds gen_server:calls that can not be processed immediately because db has not 
  %  been verified, is in the middle of a 2phase commit
  %  or is being restored from another node.
  callqueue,
  % (short for masterorslave): slave/master
  % mors = slave                     -> follower
  % mors = master, verified == false -> candidate
  % mors == master, verified == true -> leader
  mors, 
  % Sql statement received from master in first step of 2 phase commit. Only kept in memory.
  replicate_sql = <<>>,
  % Local copy of db needs to be verified with all nodes. It might be stale or in a conflicted state.
  % If local db is being restored, verified will be on false.
  % Possible values: true, false, failed (there is no majority of nodes with the same db state)
  verified = false,
  % Verification of db is done asynchronously in a monitored process. This holds pid.
  electionpid,
  % Path to sqlite file.
  dbpath,
  % Which nodes current process is sending dbfile to.
  % [{Node,Pid,Ref,IsMove},..]
  dbcopy_to = [],
  % If node is sending us a complete copy of db, this identifies the operation
  dbcopyref,
  % Where is master sqlproc.
  masternode, masternodedist,
  % If db has been moved completely over to a new node. All calls will be redirected to that node.
  % Once this has been set, db files will be deleted on process timeout.
  movedtonode,
  % Will cause actor not to do any DB initialization, but will take the db from another node
  copyfrom,copyreset = false,copyproc}). 
% -define(R2P(Record), butil:rec2prop(Record#dp{writelog = byte_size(P#dp.writelog)}, record_info(fields, dp))).
-define(R2P(Record), butil:rec2prop(Record, record_info(fields, dp))).
-define(P2R(Prop), butil:prop2rec(Prop, dp, #dp{}, record_info(fields, dp))).	

-ifndef(NOLOG).
-define(DBG(F),lager:debug([$~,$p,$\s|F],[P#dp.actorname])).
-define(DBG(F,A),lager:debug([$~,$p,$\s|F],[P#dp.actorname|A])).
-define(INF(F),lager:info([$~,$p,$\s|F],[P#dp.actorname])).
-define(INF(F,A),lager:info([$~,$p,$\s|F],[P#dp.actorname|A])).
-define(ERR(F),lager:error([$~,$p,$\s|F],[P#dp.actorname])).
-define(ERR(F,A),lager:error([$~,$p,$\s|F],[P#dp.actorname|A])).
-else.
-define(DBG(F),ok).
-define(DBG(F,A),ok).
-define(INF(F),ok).
-define(INF(F,A),ok).
-define(ERR(F),ok).
-define(ERR(F,A),ok).
-endif.

-ifdef(DODBLOG).
-define(DBLOG(Db,LogFormat,LogArgs),actordb_sqlite:exec(Db,<<"INSERT INTO __evlog (line,pid,node,actor,type,txt) ",
											  "VALUES (",(butil:tobin(?LINE))/binary,",",
											  	"'",(list_to_binary(pid_to_list(self())))/binary,"',",
											  	"'",(bkdcore:node_name())/binary,"',",
											  	"'",(butil:tobin(P#dp.actorname))/binary,"',",
											  	"'",(butil:tobin(P#dp.actortype))/binary,"',",
											  "'",(butil:tobin(io_lib:fwrite(LogFormat,LogArgs)))/binary,"');">>)).
-define(LOGTABLE,<<"CREATE TABLE __evlog (id INTEGER PRIMARY KEY AUTOINCREMENT,line INTEGER,pid TEXT, node TEXT,",
						" actor TEXT, type TEXT, txt TEXT);">>).
-define(COPYTRASH,actordb_sqlite:copy_to_trash(P#dp.dbpath),actordb_sqlite:copy_to_trash(P#dp.dbpath++"-wal")).
-else.
-define(LOGTABLE,<<>>).
-define(DBLOG(_a,_b,_c),ok).
-define(COPYTRASH,ok).
-endif.