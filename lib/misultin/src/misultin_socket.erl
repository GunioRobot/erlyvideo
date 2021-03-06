% ==========================================================================================================
% MISULTIN - Socket
%
% >-|-|-(°>
% 
% Copyright (C) 2009, Roberto Ostinelli <roberto@ostinelli.net>, Sean Hinde.
% All rights reserved.
%
% Code portions from Sean Hinde have been originally taken under BSD license from Trapexit at the address:
% <http://www.trapexit.org/A_fast_web_server_demonstrating_some_undocumented_Erlang_features>
%
% BSD License
% 
% Redistribution and use in source and binary forms, with or without modification, are permitted provided
% that the following conditions are met:
%
%  * Redistributions of source code must retain the above copyright notice, this list of conditions and the
%	 following disclaimer.
%  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and
%	 the following disclaimer in the documentation and/or other materials provided with the distribution.
%  * Neither the name of the authors nor the names of its contributors may be used to endorse or promote
%	 products derived from this software without specific prior written permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
% WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
% PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
% ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
% TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
% POSSIBILITY OF SUCH DAMAGE.
% ==========================================================================================================
-module(misultin_socket).
-vsn('0.3').

% API
-export([start_link/4]).

% callbacks
-export([listener/4]).

% internale
-export([socket_loop/1, request/2, headers/3, headers/4, body/2]).

% macros
-define(MAX_HEADERS_COUNT, 100).

% records
-record(c, {
	sock,
	port,
	loop,
	recv_timeout
}).

% includes
-include("../include/misultin.hrl").


% ============================ \/ API ======================================================================

% Function: {ok,Pid} | ignore | {error, Error}
% Description: Starts the socket.
start_link(ListenSocket, ListenPort, Loop, RecvTimeout) ->
	proc_lib:spawn_link(?MODULE, listener, [ListenSocket, ListenPort, Loop, RecvTimeout]).

% Function: {ok,Pid} | ignore | {error, Error}
% Description: Starts the socket.
listener(ListenSocket, ListenPort, Loop, RecvTimeout) ->
	case catch gen_tcp:accept(ListenSocket) of
		{ok, Sock} ->
			?DEBUG(debug, "accepted an incoming TCP connection, spawning controlling process", []),
			Pid = spawn(fun () ->
				receive
					set ->
						inet:setopts(Sock, [{active, once}]),
						?DEBUG(debug, "activated controlling process", [])
				after 60000 ->
					exit({error, controlling_failed})
				end,
				% build connection record
				{ok, {Addr, Port}} = inet:peername(Sock),
				C = #c{sock = Sock, port = ListenPort, loop = Loop, recv_timeout = RecvTimeout},
				% jump to state 'request'
				?DEBUG(debug, "jump to state request", []),
				?MODULE:request(C, #req{peer_addr = Addr, peer_port = Port})
			end),
			% set controlling process
			gen_tcp:controlling_process(Sock, Pid),
			Pid ! set,
			% get back to accept loop
			?MODULE:listener(ListenSocket, ListenPort, Loop, RecvTimeout);
		_Else ->
			?DEBUG(error, "accept failed error: ~p", [_Else]),
			exit({error, accept_failed})
	end.

% ============================ /\ API ======================================================================


% ============================ \/ INTERNAL FUNCTIONS =======================================================

% REQUEST: wait for a HTTP Request line. Transition to state headers if one is received. 
request(#c{sock = Sock, recv_timeout = RecvTimeout} = C, Req) ->
	inet:setopts(Sock, [{active, once}]),
	receive
		{http, Sock, {http_request, Method, Path, Version}} ->
			?DEBUG(debug, "received full headers of a new HTTP packet", []),
			?MODULE:headers(C, Req#req{vsn = Version, method = Method, uri = Path, connection = default_connection(Version)}, []);
		{http, Sock, {http_error, "\r\n"}} ->
			?MODULE:request(C, Req);
		{http, Sock, {http_error, "\n"}} ->
			?MODULE:request(C, Req);
		{http, Sock, _Other} ->
			?DEBUG(debug, "tcp normal error treating request: ~p", [_Other]),
			exit(normal)	
	after RecvTimeout ->
		?DEBUG(debug, "request timeout, sending error", []),
		send(Sock, ?REQUEST_TIMEOUT_408)
	end.

% HEADERS: collect HTTP headers. After the end of header marker transition to body state.
headers(C, Req, H) ->
	headers(C, Req, H, 0).
headers(#c{sock = Sock, recv_timeout = RecvTimeout} = C, Req, H, HeaderCount) when HeaderCount =< ?MAX_HEADERS_COUNT ->
	inet:setopts(Sock, [{active, once}]),
	receive
		{http, Sock, {http_header, _, 'Content-Length', _, Val}} ->
			?MODULE:headers(C, Req#req{content_length = Val}, [{'Content-Length', Val}|H], HeaderCount + 1);
		{http, Sock, {http_header, _, 'Connection', _, Val}} ->
			KeepAlive = keep_alive(Req#req.vsn, Val),
			?MODULE:headers(C, Req#req{connection = KeepAlive}, [{'Connection', Val}|H], HeaderCount + 1);
		{http, Sock, {http_header, _, 'Host', _, Val}} ->
		  Host = list_to_binary(hd(string:tokens(Val, ":"))),
			?MODULE:headers(C, Req#req{host = Host}, [{'Host', Host}|H], HeaderCount + 1);
		{http, Sock, {http_header, _, Header, _, Val}} ->
			?MODULE:headers(C, Req, [{Header, Val}|H], HeaderCount + 1);
		{http, Sock, {http_error, "\r\n"}} ->
			?MODULE:headers(C, Req, H, HeaderCount);
		{http, Sock, {http_error, "\n"}} ->
			?MODULE:headers(C, Req, H, HeaderCount);
		{http, Sock, http_eoh} ->
			?MODULE:body(C, Req#req{headers = lists:reverse(H)});
		{http, Sock, _Other} ->
			?DEBUG(debug, "tcp normal error treating headers: ~p", [_Other]),
			exit(normal)
	after RecvTimeout ->
		?DEBUG(debug, "headers timeout, sending error", []),
		send(Sock, ?REQUEST_TIMEOUT_408)
	end;
headers(C, Req, H, _HeaderCount) ->
	?MODULE:body(C, Req#req{headers = lists:reverse(H)}).

% default connection
default_connection({1,1}) -> keep_alive;
default_connection(_) -> close.

% Shall we keep the connection alive? Default case for HTTP/1.1 is yes, default for HTTP/1.0 is no.
keep_alive({1,1}, "close")		-> close;
keep_alive({1,1}, "Close")		-> close;
% string:to_upper is used only as last resort.
keep_alive({1,1}, Head) ->
	case string:to_upper(Head) of
		"CLOSE" -> close;
		_		-> keep_alive
	end;
keep_alive({1,0}, "Keep-Alive") -> keep_alive;
keep_alive({1,0}, Head) ->
	case string:to_upper(Head) of
		"KEEP-ALIVE"	-> keep_alive;
		_				-> close
	end;
keep_alive({0,9}, _)			-> close;
keep_alive(_Vsn, _KA)			-> close.

% BODY: collect the body of the HTTP request if there is one, and lookup and call the implementation callback.
% Depending on whether the request is persistent transition back to state request to await the next request or exit.
body(#c{sock = Sock, recv_timeout = RecvTimeout} = C, Req) ->
	case Req#req.method of
		'GET' ->
			Close = handle_get(C, Req),
			case Close of
				close ->
					gen_tcp:close(Sock);
				keep_alive ->
					% TODO: REMOVE inet:setopts(Sock, [{packet, http}]),
					% inet:setopts(Sock, [{active, false}, {packet, 0}]),
					?MODULE:request(C, #req{peer_addr = Req#req.peer_addr, peer_port = Req#req.peer_port})
			end;
		'POST' ->
			case catch list_to_integer(Req#req.content_length) of 
				{'EXIT', _} ->
					% TODO: provide a fallback when content length is not or wrongly specified
					?DEBUG(debug, "specified content length is not a valid integer number: ~p", [Req#req.content_length]),
					send(Sock, ?CONTENT_LENGTH_REQUIRED_411),
					exit(normal);
				Len ->
					inet:setopts(Sock, [{packet, raw}, {active, false}]),
					case gen_tcp:recv(Sock, Len, RecvTimeout) of
						{ok, Bin} ->
							Close = handle_post(C, Req#req{body = Bin}),
							case Close of
								close ->
									gen_tcp:close(Sock);
								keep_alive ->
									inet:setopts(Sock, [{packet, http}]),
									?MODULE:request(C, #req{peer_addr = Req#req.peer_addr, peer_port = Req#req.peer_port})
							end;
						{error, timeout} ->
							?DEBUG(debug, "request timeout, sending error", []),
							send(Sock, ?REQUEST_TIMEOUT_408);	
						_Other ->
							?DEBUG(debug, "tcp normal error treating post: ~p", [_Other]),
							exit(normal)
					end
			end;
		'PUT' ->
		  inet:setopts(Sock, [{packet, raw}, {active, false}]),
			Close = handle_get(C, Req#req{socket = Sock}),
			case Close of
				close ->
					gen_tcp:close(Sock);
				keep_alive ->
					% TODO: REMOVE inet:setopts(Sock, [{packet, http}]),
					% inet:setopts(Sock, [{active, false}, {packet, 0}]),
					request(C, #req{peer_addr = Req#req.peer_addr, peer_port = Req#req.peer_port})
			end;
		_Other ->
			?DEBUG(debug, "method not implemented: ~p", [_Other]),
			send(Sock, ?NOT_IMPLEMENTED_501),
			exit(normal)
	end.

% handle a get request
handle_get(C, #req{connection = Conn} = Req) ->
	case Req#req.uri of
		{abs_path, Path} ->
			{F, Args} = split_at_q_mark(Path, []),
			call_mfa(C, Req#req{args = Args, uri = {abs_path, F}}),
			Conn;
		{absoluteURI, http, _Host, _, Path} ->
			{F, Args} = split_at_q_mark(Path, []),
			call_mfa(C, Req#req{args = Args, uri = {absoluteURI, F}}),
			Conn;
		{absoluteURI, _Other_method, _Host, _, _Path} ->
			send(C#c.sock, ?NOT_IMPLEMENTED_501),
			close;
		{scheme, _Scheme, _RequestString} ->
			send(C#c.sock, ?NOT_IMPLEMENTED_501),
			close;
		_  ->
			send(C#c.sock, ?FORBIDDEN_403),
			close
	end.

% handle a post request
handle_post(C, #req{connection = Conn} = Req) ->
	case Req#req.uri of
		{abs_path, _Path} ->
			call_mfa(C, Req),
			Conn;
		{absoluteURI, http, _Host, _, _Path} ->
			call_mfa(C, Req),
			Conn;
		{absoluteURI, _Other_method, _Host, _, _Path} ->
			send(C#c.sock, ?NOT_IMPLEMENTED_501),
			close;
		{scheme, _Scheme, _RequestString} ->
			send(C#c.sock, ?NOT_IMPLEMENTED_501),
			close;
		_  ->
			send(C#c.sock, ?FORBIDDEN_403),
			close
	end.

% Description: Main dispatcher
call_mfa(#c{sock = Sock, loop = Loop} = C, Request) ->
	% spawn listening process for Request messages [only used to support stream requests]
	SocketPid = spawn(?MODULE, socket_loop, [C]),
	% create request
	Req = misultin_req:new(Request, SocketPid),
	% call loop
	try Loop(Req) of
	  {HttpCode, Headers0, Body} ->
			% received normal response
			?DEBUG(debug, "sending response", []),
			% flatten body [optimization since needed for content length]
			BodyBinary = convert_to_binary(Body),
			% provide response
			Headers = add_content_length(Headers0, BodyBinary),
			Enc_headers = enc_headers(Headers),
			Resp = ["HTTP/1.1 ", integer_to_list(HttpCode), " OK\r\n", Enc_headers, <<"\r\n">>, BodyBinary],
			send(Sock, Resp),
			% kill listening socket
			SocketPid ! shutdown;
		{raw, Body} ->
			send(Sock, Body);
		_ ->
			% loop exited normally, kill listening socket
			SocketPid ! shutdown
	catch	
		exit:leave ->
		  exit(normal);
		_Class:_Error ->
			?DEBUG(error, "worker crash: ~p:~p:~p", [_Class, _Error, erlang:get_stacktrace()]),
      error_logger:error_msg("FAIL ~p ~p~n~p:~p:~p", [Req:get(method), Req:get(uri), _Class, _Error, erlang:get_stacktrace()]),
			% kill listening socket
			SocketPid ! shutdown,
			% send response
      % send(Sock, [[?INTERNAL_SERVER_ERROR_500], io_lib:format("~p:~p", [_Class:_Error])]),
      send(Sock, [?INTERNAL_SERVER_ERROR_500, io_lib:format("~p:~p:~p", [_Class, _Error, erlang:get_stacktrace()])]),
			% force exit
			exit(normal)
	end.

% Description: Ensure Body is binary.
convert_to_binary(Body) when is_list(Body) ->
	list_to_binary(lists:flatten(Body));
convert_to_binary(Body) when is_binary(Body) ->
	Body;
convert_to_binary(Body) when is_atom(Body) ->
	list_to_binary(atom_to_list(Body)).

% Description: Socket loop for stream responses
socket_loop(#c{sock = Sock} = C) ->
	receive
		{stream_head, HttpCode, Headers} ->
			?DEBUG(debug, "sending stream head", []),
			Enc_headers = enc_headers(Headers),
			Resp = ["HTTP/1.1 ", integer_to_list(HttpCode), " OK\r\n", Enc_headers, <<"\r\n">>],
			send(Sock, Resp),
			?MODULE:socket_loop(C);
		{stream_data, Body} ->
			?DEBUG(debug, "sending stream data", []),
			send(Sock, Body),
			?MODULE:socket_loop(C);
		stream_close ->
			?DEBUG(debug, "closing stream", []),
			close(Sock);
		shutdown ->
			?DEBUG(debug, "shutting down socket loop", []),
			shutdown
	end.

% Description: Add content length
add_content_length(Headers, Body) ->
	case proplists:get_value('Content-Length', Headers) of
		undefined ->
			[{'Content-Length', size(Body)}|Headers];
		false ->
			Headers
	end.

% Description: Encode headers
enc_headers([{Tag, Val}|T]) when is_atom(Tag) ->
	[atom_to_list(Tag), ": ", enc_header_val(Val), "\r\n"|enc_headers(T)];
enc_headers([{Tag, Val}|T]) when is_list(Tag) ->
	[Tag, ": ", enc_header_val(Val), "\r\n"|enc_headers(T)];
enc_headers([]) ->
	[].
enc_header_val(Val) when is_atom(Val) ->
	atom_to_list(Val);
enc_header_val(Val) when is_integer(Val) ->
	integer_to_list(Val);
enc_header_val(Val) ->
	Val.

% Split the path at the ?
split_at_q_mark([$?|T], Acc) ->
	{lists:reverse(Acc), T};
split_at_q_mark([H|T], Acc) ->
	split_at_q_mark(T, [H|Acc]);
split_at_q_mark([], Acc) ->
	{lists:reverse(Acc), []}.

% TCP send
send(Sock, Data) ->
	case gen_tcp:send(Sock, Data) of
		ok ->
			ok;
		{error, _Reason} ->
			?DEBUG(debug, "worker crash: ~p", [_Reason]),
			exit(normal)
	end.

% TCP close
close(Sock) ->
	?DEBUG(debug, "closing socket", []),
	case gen_tcp:close(Sock) of
		ok ->
			ok;
		{error, _Reason} ->
			?DEBUG(debug, "could not close socket: ~p", [_Reason]),
			exit(normal)
	end.
	
% ============================ /\ INTERNAL FUNCTIONS =======================================================
