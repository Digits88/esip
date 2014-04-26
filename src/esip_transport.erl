%%%-------------------------------------------------------------------
%%% File    : esip_transport.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Transport layer
%%%
%%% Created : 14 Jul 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(esip_transport).

%% API
-export([recv/2, send/1, send/2, start_link/0,
         register_socket/3, unregister_socket/3,
         register_udp_listener/1, unregister_udp_listener/1,
         make_via_hdr/2, connect/1,
         register_route/3, unregister_route/3,
         make_contact/1, have_route/3, via_transport_to_atom/1]).

-behaviour(gen_server).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("esip.hrl").
-include("esip_lib.hrl").
-include_lib("kernel/include/inet.hrl").

-record(route, {transport, host, port}).
-record(state, {}).

%%====================================================================
%% API
%%====================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

recv(SIPSock, #sip{type = request} = Req) ->
    case prepare_request(SIPSock, Req) of
        #sip{} = NewReq ->
            case esip:callback(message_in, [NewReq, SIPSock]) of
                drop ->
                    ok;
                #sip{type = request} = NewReq1 ->
                    esip_transaction:process(SIPSock, NewReq1);
                #sip{type = response} = Resp ->
                    send(SIPSock, Resp);
                _ ->
                    esip_transaction:process(SIPSock, NewReq)
            end;
        _ ->
            ok
    end;
recv(SIPSock, #sip{type = response} = Resp) ->
    case prepare_response(SIPSock, Resp) of
        #sip{} = NewResp ->
            case esip:callback(message_in, [NewResp, SIPSock]) of
                drop ->
                    ok;
                #sip{type = response} = NewResp1 ->
                    esip_transaction:process(SIPSock, NewResp1);
                _ ->
                    esip_transaction:process(SIPSock, NewResp)
            end;
        _ ->
            ok
    end.

send(Msg) ->
    send(Msg, []).

send(#sip_socket{} = SIPSock, Msg) ->
    NewMsg = case esip:callback(message_out, [Msg, SIPSock]) of
                 drop -> ok;
                 Msg1 = #sip{} -> Msg1;
                 _ -> Msg
             end,
    do_send(SIPSock, NewMsg);
send(#sip{} = SIPMsg, Opts) ->
    case lists:keysearch(socket, 1, Opts) of
        {value, {_, SIPSocket}} ->
            send(SIPSocket, SIPMsg);
        _ ->
            case connect(SIPMsg) of
                {ok, SIPSock} ->
                    send(SIPSock, SIPMsg);
                Err ->
                    Err
            end
    end.

connect(#sip{type = request, uri = URI, hdrs = Hdrs} = Req) ->
    NewURI = case esip:callback(locate, [Req]) of
                 U = #uri{} ->
                     U;
                 _ ->
                     case esip:get_hdrs('route', Hdrs) of
                         [{_, RouteURI, _}|_] ->
                             RouteURI;
                         _ ->
                             URI
                     end
             end,
    do_connect(NewURI);
connect(#sip{type = response, hdrs = Hdrs} = Resp) ->
    NewVia = case esip:callback(locate, [Resp]) of
                 Via = #via{} ->
                     Via;
                 _ ->
                     [Via|_] = esip:get_hdrs('via', Hdrs),
                     Via
             end,
    do_connect(NewVia).

do_connect(URIorVia) ->
    case resolve(URIorVia) of
        {ok, AddrsPorts, Transport} ->
            case lookup_socket(AddrsPorts, Transport) of
                {ok, Sock} ->
                    {ok, Sock};
                _ ->
                    case Transport of
                        tcp ->
                            esip_socket:connect(AddrsPorts);
			udp ->
                            case get_udp_listener() of
                                {ok, UDPSock} ->
                                    esip_socket:connect(AddrsPorts, UDPSock);
                                _ ->
                                    {error, eprotonosupport}
                            end;
			_ ->
			    {error, eprotonosupport}
                    end
            end;
        Err ->
            Err
    end.

via_transport_to_atom(<<"TLS">>) -> tls;
via_transport_to_atom(<<"TCP">>) -> tcp;
via_transport_to_atom(<<"UDP">>) -> udp;
via_transport_to_atom(<<"SCTP">>) -> sctp;
via_transport_to_atom(<<"TLS-SCTP">>) -> tls_sctp;
via_transport_to_atom(_) -> unknown.

atom_to_via_transport(tls) -> <<"TLS">>;
atom_to_via_transport(tcp) -> <<"TCP">>;
atom_to_via_transport(udp) -> <<"UDP">>;
atom_to_via_transport(sctp) -> <<"SCTP">>;
atom_to_via_transport(tls_sctp) -> <<"TLS-SCTP">>;
atom_to_via_transport(_) -> <<>>.

register_socket(Addr, Transport, Sock) ->
    ets:insert(esip_socket, {{Addr, Transport}, Sock}).

unregister_socket(Addr, Transport, Sock) ->
    ets:delete_object(esip_socket, {{Addr, Transport}, Sock}).

lookup_socket([Addr|Rest], Transport) ->
    case lookup_socket(Addr, Transport) of
        {ok, Sock} ->
            {ok, Sock};
        _ ->
            lookup_socket(Rest, Transport)
    end;
lookup_socket([], _) ->
    error;
lookup_socket(Addr, Transport) ->
    case ets:lookup(esip_socket, {Addr, Transport}) of
        [{_, Sock}|_] ->
            {ok, Sock};
        _ ->
            error
    end.

register_udp_listener(SIPSock) ->
    ets:insert(esip_socket, {udp, SIPSock}).

unregister_udp_listener(SIPSock) ->
    ets:delete_object(esip_socket, {udp, SIPSock}).

get_udp_listener() ->
    case ets:lookup(esip_socket, udp) of
        [{_, SIPSock}|_] ->
            {ok, SIPSock};
        _ ->
            error
    end.

register_route(Transport, Host, Port) ->
    ets:insert(esip_route, #route{transport = Transport,
                                  host = Host,
                                  port = Port}).

unregister_route(Transport, Host, Port) ->
    ets:delete_object(esip_route, #route{transport = Transport,
                                         host = Host,
                                         port = Port}).

have_route(Transport, Host, Port) ->
    case ets:match_object(esip_route, #route{transport = Transport,
                                             host = Host,
                                             port = Port}) of
        [_|_] ->
            true;
        _ ->
            false
    end.

get_route(Transport) ->
    case ets:lookup(esip_route, Transport) of
        [#route{host = Host, port = Port}|_] ->
	    {ok, Transport, Host, Port};
	[] ->
	    error
    end.

get_all_routes() ->
    ets:tab2list(esip_route).

make_via_hdr(#sip_socket{type = Transport, sock = Sock}, Branch) ->
    Res = case get_route(Transport) of
	      {ok, _, Host, Port} when Host /= undefined ->
		  {Host, Port};
	      {ok, _, undefined, Port} ->
		  case inet:sockname(Sock) of
		      {ok, {IP, _}} ->
			  case lists:sum(tuple_to_list(IP)) of
			      0 ->
				  {<<"127.0.0.1">>, Port};
			      _ ->
				  {ip_to_host(IP), Port}
			  end;
		      Err ->
			  Err
		  end;
	      error ->
		  {error, unsupported_transport}
	  end,
    case Res of
	{error, Why} ->
	    {error, Why};
	{Host1, Port1} ->
	    {ok, [#via{transport = atom_to_via_transport(Transport),
		       host = Host1,
		       port = Port1,
		       params = [{<<"branch">>, Branch},
				 {<<"rport">>, <<>>}]}]}
    end.

make_contact(Transport) ->
    Res = get_route(Transport),
    case Res of
        {ok, Transport1, Host, Port} ->
            Scheme = case Transport1 of
                         tls -> <<"sips">>;
                         tls_sctp -> <<"sips">>;
                         _ -> <<"sip">>
                     end,
            Params = case Transport1 of
                         udp -> [{<<"transport">>, <<"udp">>}];
                         sctp -> [{<<"transport">>, <<"stcp">>}];
                         tcp -> [{<<"transport">>, <<"tcp">>}];
                         _ -> []
                     end,
            [{<<>>, #uri{scheme = Scheme, host = Host,
                         port = Port, params = Params}, []}];
        _ ->
            []
    end.

supported_transports() ->
    supported_transports(all).

supported_transports(Type) ->
    lists:flatmap(
      fun(#route{transport = Transport}) ->
              case Transport of
                  tls when Type == tls ->
                      [Transport];
                  tls_sctp when Type == tls ->
                      [Transport];
                  _ when Type == tls ->
                      [];
                  _ ->
                      [Transport]
              end
      end, get_all_routes()).

supported_uri_schemes() ->
    case supported_transports(tls) of
        [] ->
            [<<"sip">>];
        _ ->
            [<<"sips">>, <<"sip">>]
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
    ets:new(esip_socket, [public, named_table, bag]),
    ets:new(esip_route, [public, named_table, bag, {keypos, #route.transport}]),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, bad_request, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================
prepare_request(#sip_socket{peer = {Addr, Port}, type = SockType},
                #sip{hdrs = Hdrs} = Request) ->
    case esip:split_hdrs('via', Hdrs) of
        {[#via{params = Params, host = Host} = Via|Vias], RestHdrs} ->
            case is_valid_via(Via, SockType)
                andalso is_valid_hdrs(RestHdrs) of
                true ->
                    Params1 = case host_to_ip(Host) of
                                  {ok, Addr} ->
                                      Params;
                                  _ ->
                                      esip:set_param(<<"received">>,
                                                     ip_to_host(Addr),
                                                     Params)
                              end,
                    Params2 = case esip:get_param(<<"rport">>, Params1, false) of
                                  <<>> ->
                                      esip:set_param(<<"rport">>,
                                                     list_to_binary(
                                                       integer_to_list(Port)),
                                                     Params1);
                                  _ ->
                                      Params1
                              end,
                    NewVia = {'via', [Via#via{params = Params2}|Vias]},
                    NewRestHdrs = case esip:get_hdr('max-forwards', RestHdrs) of
                                      undefined ->
                                          MF = esip:get_config_value(max_forwards),
                                          [{'max-forwards', MF}|RestHdrs];
                                      _ ->
                                          RestHdrs
                                  end,
                    Request#sip{hdrs = [NewVia|NewRestHdrs]};
                false ->
                    error
            end;
        _ ->
            error
    end.

prepare_response(#sip_socket{type = SockType}, #sip{hdrs = Hdrs} = Response) ->
    case esip:get_hdrs('via', Hdrs) of
        [#via{host = Host, port = Port, transport = Transport} = Via|_] ->
            case is_valid_via(Via, SockType) andalso is_valid_hdrs(Hdrs) of
                true ->
                    case have_route(via_transport_to_atom(Transport),
                                    Host, Port) of
                        true ->
                            Response;
                        _ ->
                            error
                    end;
                false ->
                    error
            end;
        _ ->
            error
    end.

is_valid_hdrs(Hdrs) ->
    try
        From = esip:get_hdr('from', Hdrs),
        To = esip:get_hdr('to', Hdrs),
        CSeq = esip:get_hdr('cseq', Hdrs),
        CallID = esip:get_hdr('call-id', Hdrs),
        has_from(From) and has_to(To)
            and (CSeq /= undefined) and (CallID /= undefined)
    catch _:_ ->
            false
    end.

is_valid_via(#via{transport = _Transport,
                  params = Params}, _SockType) ->
    case esip:get_param(<<"branch">>, Params) of
        <<>> ->
            false;
        _ ->
            true
    end.

has_from({_, #uri{}, _}) -> true;
has_from(_) -> false.

has_to({_, #uri{}, _}) -> true;
has_to(_) -> false.

do_send(#sip_socket{type = Type, sock = Sock,
                    peer = Peer} = SIPSock, Msg) ->
    case catch esip_codec:encode(Msg) of
        {'EXIT', _} = Err ->
            ?ERROR_MSG("failed to encode:~n"
		       "** Packet: ~p~n** Reason: ~p",
		       [Msg, Err]);
        Data ->
            esip:callback(data_out, [Data, SIPSock]),
            case Type of
                udp -> esip_socket:send(Sock, Peer, Data);
                _ -> esip_socket:send(Sock, Data)
            end
    end.

host_to_ip(Host) when is_binary(Host) ->
    host_to_ip(binary_to_list(Host));
host_to_ip(Host) ->
    case Host of
        "[" ->
            {error, einval};
        "[" ++ Rest ->
            inet_parse:ipv6_address(string:substr(Rest, 1, length(Rest)-1));
        _ ->
            inet_parse:address(Host)
    end.

ip_to_host({0,0,0,0,0,16#ffff,X,Y}) ->
    <<A, B, C, D>> = <<X:16, Y:16>>,
    ip_to_host({A, B, C, D});
ip_to_host({_, _, _, _} = Addr) ->
    list_to_binary(inet_parse:ntoa(Addr));
ip_to_host(IPv6Addr) ->
    iolist_to_binary(
      [$[, esip_codec:to_lower(list_to_binary(inet_parse:ntoa(IPv6Addr))), $]]).

srv_prefix(tls) -> "_sips._tcp.";
srv_prefix(tls_sctp) -> "_sips._sctp.";
srv_prefix(tcp) -> "_sip._tcp.";
srv_prefix(sctp) -> "_sip._sctp.";
srv_prefix(udp) -> "_sip._udp.".

default_port(tls) -> 5061;
default_port(tls_sctp) -> 5061;
default_port(_) -> 5060.

resolve(#uri{scheme = Scheme} = URI) ->
    case lists:member(Scheme, supported_uri_schemes()) of
        true ->
            SupportedTransports = case Scheme of
                                      <<"sips">> ->
                                          supported_transports(tls);
                                      _ ->
                                          supported_transports()
                                  end,
            case SupportedTransports of
                [] ->
                    {error, unsupported_transport};
                _ ->
                    do_resolve(URI, SupportedTransports)
            end;
        false ->
            {error, unsupported_uri_scheme}
    end;
resolve(#via{transport = ViaTransport} = Via) ->
    Transport = via_transport_to_atom(ViaTransport),
    case lists:member(Transport, supported_transports()) of
        true ->
            do_resolve(Via, Transport);
        false ->
            {error, unsupported_transport}
    end.

do_resolve(#uri{host = Host, port = Port, params = Params}, SupportedTransports) ->
    case esip:to_lower(esip:get_param(<<"transport">>, Params)) of
        <<>> ->
            [FallbackTransport|_] = lists:reverse(SupportedTransports),
            case host_to_ip(Host) of
                {ok, Addr} ->
                    select_host_port(Addr, Port, FallbackTransport);
                _ when is_integer(Port) ->
                    select_host_port(Host, Port, FallbackTransport);
                _ ->
                    case naptr_srv_lookup(Host, SupportedTransports) of
                        {ok, _, _} = Res ->
                            Res;
                        _Err ->
                            select_host_port(Host, Port, FallbackTransport)
                    end
            end;
        TransportBinary ->
            Transport = (catch erlang:binary_to_existing_atom(
                                 TransportBinary, utf8)),
            case lists:member(Transport, SupportedTransports) of
                true ->
                    case host_to_ip(Host) of
                        {ok, Addr} ->
                            select_host_port(Addr, Port, Transport);
                        _ when is_integer(Port) ->
                            select_host_port(Host, Port, Transport);
                        _ ->
                            case srv_lookup(Host, [Transport]) of
                                {ok, _, _} = Res ->
                                    Res;
                                _Err ->
                                    select_host_port(Host, Port, Transport)
                            end
                    end;
                false ->
                    {error, unsupported_transport}
            end
    end;
do_resolve(#via{transport = ViaTransport, host = Host,
             port = Port, params = Params}, Transport) ->
    NewPort = if ViaTransport == <<"UDP">> ->
                      case esip:get_param(<<"rport">>, Params) of
                          <<>> ->
                              Port;
                          RPort ->
                              case esip_codec:to_integer(RPort, 1, 65535) of
                                  {ok, PortInt} -> PortInt;
                                  _ -> Port
                              end
                      end;
                 true ->
                      Port
              end,
    NewHost = case esip:get_param(<<"received">>, Params) of
                  <<>> -> Host;
                  Host1 -> Host1
              end,
    case host_to_ip(NewHost) of
        {ok, Addr} ->
            select_host_port(Addr, NewPort, Transport);
        _ when is_integer(NewPort) ->
            select_host_port(NewHost, NewPort, Transport);
        _ ->
            case srv_lookup(NewHost, [Transport]) of
                {ok, _, _} = Res ->
                    Res;
                _Err ->
                    select_host_port(NewHost, NewPort, Transport)
            end
    end.

select_host_port(Addr, Port, Transport) when is_tuple(Addr) ->
    NewPort = if is_integer(Port) ->
                      Port;
                 true ->
                      default_port(Transport)
              end,
    {ok, [{Addr, NewPort}], Transport};
select_host_port(Host, Port, Transport) when is_integer(Port) ->    
    case a_lookup(Host) of
        {error, _} = Err ->
            Err;
        {ok, Addrs} ->
            {ok, [{Addr, Port} || Addr <- Addrs], Transport}
    end;
select_host_port(Host, Port, Transport) ->
    NewPort = if is_integer(Port) ->
                      Port;
                 true ->
                      default_port(Transport)
              end,
    case a_lookup(Host) of
        {ok, Addrs} ->
            {ok, [{Addr, NewPort} || Addr <- Addrs], Transport};
        Err ->
            Err
    end.

naptr_srv_lookup(Host, Transports) when is_binary(Host) ->
    naptr_srv_lookup(binary_to_list(Host), Transports);
naptr_srv_lookup(Host, Transports) ->
    case naptr_lookup(Host) of
        {error, _Err} ->
            srv_lookup(Host, Transports);
        SRVHosts ->
            case lists:filter(
                   fun({_, T}) ->
                           lists:member(T, Transports)
                   end, SRVHosts) of
                [{SRVHost, Transport}|_] ->
                    case srv_lookup(SRVHost) of
                        {error, _} = Err ->
                            Err;
                        AddrsPorts ->
                            {ok, AddrsPorts, Transport}
                    end;
                _ ->
                    srv_lookup(Host, Transports)
            end
    end.

srv_lookup(Host, Transports) when is_binary(Host) ->
    srv_lookup(binary_to_list(Host), Transports);
srv_lookup(Host, Transports) ->
    lists:foldl(
      fun(_Transport, {ok, _, _} = Acc) ->
              Acc;
         (Transport, Err) ->
              SRVHost = srv_prefix(Transport) ++ Host,
              case srv_lookup(SRVHost) of
                  {error, _} = Err ->
                      Err;
                  AddrsPorts ->
                      {ok, AddrsPorts, Transport}
              end
      end, {error, nxdomain}, Transports).

naptr_lookup(Host) when is_binary(Host) ->
    naptr_lookup(binary_to_list(Host));
naptr_lookup(Host) ->
    case inet_res:getbyname(Host, naptr) of
        {ok, #hostent{h_addr_list = Addrs}} ->
            lists:flatmap(
              fun({_Order, _Pref, _Flags, Service, _Regexp, SRVHost}) ->
                      case Service of
                          "sips+d2t" -> [{SRVHost, tls}];
                          "sips+d2s" -> [{SRVHost, tls_sctp}];
                          "sip+d2t" -> [{SRVHost, tcp}];
                          "sip+d2u" -> [{SRVHost, udp}];
                          "sip+d2s" -> [{SRVHost, sctp}];
                          _ -> []
                      end
              end, lists:keysort(1, Addrs));
        Err ->
            Err
    end.

srv_lookup(Host) when is_binary(Host) ->
    srv_lookup(binary_to_list(Host));
srv_lookup(Host) ->
    case inet_res:getbyname(Host, srv) of
        {ok, #hostent{h_addr_list = Rs}} ->
            case lists:flatmap(
                   fun({_, _, Port, HostName}) ->
                           case a_lookup(HostName) of
                               {ok, Addrs} ->
                                   [{Addr, Port} || Addr <- Addrs];
                               _ ->
                                   []
                           end
                   end, lists:keysort(1, Rs)) of
                [] ->
                    {error, nxdomain};
                Res ->
                    Res
            end;
        Err ->
            Err
    end.

a_lookup(Host) when is_binary(Host) ->
    a_lookup(binary_to_list(Host));
a_lookup(Host) ->
    case inet_res:getbyname(Host, a) of
        {ok, #hostent{h_addr_list = Addrs}} ->
            {ok, Addrs};
        Err ->
            case inet_res:getbyname(Host, aaaa) of
                {ok, #hostent{h_addr_list = Addrs}} ->
                    {ok, Addrs};
                Err ->
                    Err
            end
    end.
