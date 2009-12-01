%%% @author     Max Lapshin <max@maxidoors.ru>
%%% @copyright  2009 Max Lapshin
%%% @doc        Player module
%%% @reference  See <a href="http://github.com/maxlapshin/erlyvideo" target="_top">http://github.com/maxlapshin/erlyvideo</a> for more information
%%% @end
%%%
%%%
%%% Copyright (c) 2009 Max Lapshin
%%%    This program is free software: you can redistribute it and/or modify
%%%    it under the terms of the GNU Affero General Public License as
%%%    published by the Free Software Foundation, either version 3 of the
%%%    License, or any later version.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%%---------------------------------------------------------------------------------------

-module(stream_play).
-author('max@maxidoors.ru').

-include("../../include/ems.hrl").

-export([start_link/2, client/1]).

-export([init/2, ready/1]).



-record(stream_player, {
  consumer,
  media_info,
	stream_id,
	paused = false,
	send_audio = true,
	send_video = true
}).



start_link(MediaEntry, Options) ->
  {ok, spawn_link(?MODULE, init, [MediaEntry, Options])}.
  
client(Player) ->
  Ref = erlang:make_ref(),
  Player ! {client, self(), Ref},
  receive 
    {Info, Ref} -> Info
  after 100 ->
    {undefined, undefined}
  end.

  
init(MediaEntry, Options) ->
  ?D({"Starting stream play for consumer", proplists:get_value(consumer, Options)}),
  ready(#stream_player{consumer = proplists:get_value(consumer, Options),
                      stream_id = proplists:get_value(stream_id, Options, 1),
                      media_info = MediaEntry}).
  
	
ready(#stream_player{media_info = MediaInfo, 
                    consumer = Consumer} = State) ->
  receive
    {client_buffer, ClientBuffer} ->
      ?MODULE:ready(State);
      
    start ->
      ?MODULE:ready(State);
      
    {client, Pid, Ref} ->
      Pid ! {gen_fsm:sync_send_event(Consumer, info), Ref},
      ?MODULE:ready(State);
      
    pause ->
      ?D("Player paused"),
      ?MODULE:ready(State#stream_player{paused = true});

    resume ->
      ?D("Player resumed"),
      ?MODULE:ready(State#stream_player{paused = false});
      
    {send_audio, Audio} ->
      ?D({"Send audio", Audio}),
      ?MODULE:ready(State#stream_player{send_audio = Audio});

    {send_video, Video} ->
      ?D({"Send video", Video}),
      ?MODULE:ready(State#stream_player{send_video = Video});

    {seek, Timestamp} ->
      ?D({"Requested to seek in stream", Timestamp}),
      ?MODULE:ready(State);
      
    {data, Data} ->
      gen_fsm:send_event(Consumer, {send, Data}),
      ?MODULE:ready(State);      

    stop -> 
      ok;
  
    exit ->
      ok;
      
  	{tcp_closed, _Socket} ->
      error_logger:info_msg("~p Video player lost connection.\n", [self()]),
      ok;
  	Else ->
  	  ?D({"Unknown message", Else}),
  	  ?MODULE:ready(State)
  end.



% send_frame(#stream_player{consumer = Consumer, stream_id = StreamId} = Player, {ok, #video_frame{nextpos = NextPos} = Frame}) ->
%   TimeStamp = Frame#video_frame.timestamp_abs - Player#stream_player.ts_prev,
%   ems_play:send(Consumer, Frame#video_frame{timestamp=TimeStamp, streamid = StreamId}),
%   % ?D({"Frame", Player#stream_player.ts_prev, TimeStamp}),
%   Player1 = timeout_play(Frame, Player),
%   NextState = Player1#stream_player{ts_prev = Frame#video_frame.timestamp_abs, pos = NextPos},
%   ?MODULE:ready(NextState).

