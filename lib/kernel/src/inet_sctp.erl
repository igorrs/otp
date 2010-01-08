%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 2007-2009. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%
%% SCTP protocol contribution by Leonid Timochouk and Serge Aleynikov.
%% See also: $ERL_TOP/lib/kernel/AUTHORS
%%
-module(inet_sctp).

%% This module provides functions for communicating with
%% sockets using the SCTP protocol.  The implementation assumes that
%% the OS kernel supports SCTP providing user-level SCTP Socket API:
%%     http://tools.ietf.org/html/draft-ietf-tsvwg-sctpsocket-13

-include("inet_sctp.hrl").
-include("inet_int.hrl").

-define(FAMILY, inet).
-export([getserv/1,getaddr/1,getaddr/2,translate_ip/1]).
-export([open/1,close/1,listen/2,connect/5,sendmsg/3,recv/2]).



getserv(Port) when is_integer(Port) -> {ok, Port};
getserv(Name) when is_atom(Name) ->
    inet:getservbyname(Name, sctp);
getserv(_) ->
    {error,einval}.

getaddr(Address) ->
    inet:getaddr(Address, ?FAMILY).
getaddr(Address, Timer) ->
    inet:getaddr_tm(Address, ?FAMILY, Timer).

translate_ip(IP) ->
    inet:translate_ip(IP, ?FAMILY).


    
open(Opts) ->
    case inet:sctp_options(Opts, ?MODULE) of
	{ok,#sctp_opts{fd=Fd,ifaddr=Addr,port=Port,opts=SOs}} ->
	    inet:open(Fd, Addr, Port, SOs, sctp, ?FAMILY, ?MODULE);
	Error -> Error
    end.

close(S) ->
    prim_inet:close(S).

listen(S, Flag) ->
    prim_inet:listen(S, Flag).

%% A non-blocking connect is implemented when the initial call is to
%% gen_sctp:connect_init which passes the value nowait as the Timer
connect(S, Addr, Port, Opts, Timer) ->
    case prim_inet:chgopts(S, Opts) of
	ok ->
	    case prim_inet:getopt(S, active) of
		{ok,Active} ->
		    Timeout = if Timer =:= nowait ->
				      infinity;		%% don't start driver timer in inet_drv
				 true ->
				      inet:timeout(Timer)
			      end,
		    case prim_inet:connect(S, Addr, Port, Timeout) of
			ok when Timer =/= nowait ->
			    connect_get_assoc(S, Addr, Port, Active, Timer);
			OkOrErr1 -> OkOrErr1
		    end;
		Err2 -> Err2
	    end;
	Err3 -> Err3
    end.

%% XXX race condition problem
%% 
%% If an incoming #sctp_assoc_change{} arrives after
%% prim_inet:getopt(S, alive) above but before the
%% #sctp_assoc_change{state=comm_up} originating from
%% prim_inet:connect(S, Addr, Port, Timeout) above,
%% connect_get_assoc/5 below mistakes it for an invalid response
%% for a socket in {active,false} or {active,once} modes.
%%
%% In {active,true} mode the window of time for the race is smaller,
%% but it is possible and also it is a blocking connect that is
%% implemented even for {active,true}, and that may be a
%% shortcoming.

connect_get_assoc(S, Addr, Port, false, Timer) ->
    case recv(S, inet:timeout(Timer)) of
	{ok, {Addr, Port, [], #sctp_assoc_change{state=St}=Ev}} ->
	    if St =:= comm_up ->
		    %% Yes, successfully connected, return the whole
		    %% sctp_assoc_change event (containing, in particular,
		    %% the AssocID).
		    %% NB: we consider the connection to be successful
		    %% even if the number of OutStreams is not the same
		    %% as requested by the user:
		    {ok,Ev};
	       true ->
		    {error,Ev}
	    end;
	%% Any other event: Error:
	{ok, Msg} ->
	    {error, Msg};
	{error,_}=Error ->
	    Error
    end;
connect_get_assoc(S, Addr, Port, Active, Timer) ->
    Timeout = inet:timeout(Timer),
    receive
	{sctp,S,Addr,Port,{[],#sctp_assoc_change{state=St}=Ev}} ->
	    case Active of
		once ->
		    prim_inet:setopt(S, active, once);
		_ -> ok
	    end,
	    if St =:= comm_up ->
		    {ok,Ev};
	       true ->
		    {error,Ev}
	    end
    after Timeout ->
	    {error,timeout}
    end.

sendmsg(S, SRI, Data) ->
    prim_inet:sendmsg(S, SRI, Data).

recv(S, Timeout) ->
    prim_inet:recvfrom(S, 0, Timeout).
