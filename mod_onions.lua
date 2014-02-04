local wrapclient = require "net.server".wrapclient;
local s2s_new_outgoing = require "core.s2smanager".new_outgoing;
local initialize_filters = require "util.filters".initialize;
local st = require "util.stanza";

local portmanager = require "core.portmanager";

local softreq = require "util.dependencies".softreq;

local bit;
pcall(function() bit = require"bit"; end);
bit = bit or softreq"bit32"
if not bit then module:log("error", "No bit module found. Either LuaJIT 2, lua-bitop or Lua 5.2 is required"); end

local band = bit.band;
local rshift = bit.rshift;
local lshift = bit.lshift;

local byte = string.byte;
local c = string.char;

local proxy_ip = module:get_option("onions_socks5_host") or "127.0.0.1";
local proxy_port = module:get_option("onions_socks5_port") or 9050;
local forbid_else = module:get_option("onions_only") or false;
local torify_all = module:get_option("onions_tor_all") or false;

local sessions = module:shared("sessions");

-- The socks5listener handles connection while still connecting to the proxy,
-- then it hands them over to the normal listener (in mod_s2s)
local socks5listener = { default_port = proxy_port, default_mode = "*a", default_interface = "*" };

local function socks5_connect_sent(conn, data)
	
	local session = sessions[conn];

	if #data < 5 then
		session.socks5_buffer = data;
		return;
	end

	request_status = byte(data, 2);

	if not request_status == 0x00 then
		module:log("debug", "Failed to connect to the SOCKS5 proxy. :(");
		session:close(false);
		return;
	end

	module:log("debug", "Succesfully connected to SOCKS5 proxy.");
	
	local response = byte(data, 4);

	if response == 0x01 then
		if #data < 10 then
			-- let's try again when we have enough
			session.socks5_buffer = data;
			return;
		end

		-- this means the server tells us to connect on an IPv4 address
		local ip1 = byte(data, 5);
		local ip2 = byte(data, 6);
		local ip3 = byte(data, 7);
		local ip4 = byte(data, 8);
		local port = band(byte(data, 9), lshift(byte(data, 10), 8));
		module:log("debug", "Should connect to: "..ip1.."."..ip2.."."..ip3.."."..ip4..":"..port);

		if not (ip1 == 0 and ip2 == 0 and ip3 == 0 and ip4 == 0 and port == 0) then
			module:log("debug", "The SOCKS5 proxy tells us to connect to a different IP, don't know how. :(");
			session:close(false);
			return;
		end

		-- Now the real s2s listener can take over the connection.
		local listener = portmanager.get_service("s2s").listener;

		module:log("debug", "SOCKS5 done, handing over listening to "..tostring(listener));

		session.socks5_handler = nil;
		session.socks5_buffer = nil;

		local w, log = conn.send, session.log;

		local filter = initialize_filters(session);

		session.sends2s = function (t)
			log("debug", "sending (s2s over socks5): %s", (t.top_tag and t:top_tag()) or t:match("^[^>]*>?"));
			if t.name then
				t = filter("stanzas/out", t);
			end
			if t then
				t = filter("bytes/out", tostring(t));
				if t then
					return conn:write(tostring(t));
				end
			end
		end
		
		session.open_stream = function ()
			session.sends2s(st.stanza("stream:stream", {
				xmlns='jabber:server', ["xmlns:db"]='jabber:server:dialback',
				["xmlns:stream"]='http://etherx.jabber.org/streams',
				from=session.from_host, to=session.to_host, version='1.0', ["xml:lang"]='en'}):top_tag());
		end
	
		conn.setlistener(conn, listener);

		listener.register_outgoing(conn, session);

		listener.onconnect(conn);
	end
end

local function socks5_handshake_sent(conn, data)

	local session = sessions[conn];

	if #data < 2 then
		session.socks5_buffer = data;
		return;
	end

	-- version, method
	local request_status = byte(data, 2);

	module:log("debug", "SOCKS version: "..byte(data, 1));
	module:log("debug", "Response: "..request_status);

	if not request_status == 0x00 then
		module:log("debug", "Failed to connect to the SOCKS5 proxy. :( It seems to require authentication.");
		session:close(false);
		return;
	end

	module:log("debug", "Sending connect message.");

	-- version 5, connect, (reserved), type: domainname, (length, hostname), port
	conn:write(c(5) .. c(1) .. c(0) .. c(3) .. c(#session.socks5_to) .. session.socks5_to);
	conn:write(c(rshift(session.socks5_port, 8)) .. c(band(session.socks5_port, 0xff)));

	session.socks5_handler = socks5_connect_sent;
end

function socks5listener.onconnect(conn)
	module:log("debug", "Connected to SOCKS5 proxy, sending SOCKS5 handshake.");

	-- Socks version 5, 1 method, no auth
	conn:write(c(5) .. c(1) .. c(0));
	
	sessions[conn].socks5_handler = socks5_handshake_sent;
end

function socks5listener.register_outgoing(conn, session)
	session.direction = "outgoing";
	sessions[conn] = session;
end

function socks5listener.ondisconnect(conn, err)
	sessions[conn]  = nil;
end

function socks5listener.onincoming(conn, data)
	local session = sessions[conn];

	if session.socks5_buffer then
		data = session.socks5_buffer .. data;
	end

	if session.socks5_handler then
		session.socks5_handler(conn, data);
	end
end

local function connect_socks5(host_session, connect_host, connect_port)
	
	local conn, handler = socket.tcp();

	module:log("debug", "Connecting to " .. connect_host .. ":" .. connect_port);

	-- this is not necessarily the same as .to_host (it can be that this is a SRV record)
	host_session.socks5_to = connect_host;
	host_session.socks5_port = connect_port;

	conn:settimeout(0);

	local success, err = conn:connect(proxy_ip, proxy_port);

	conn = wrapclient(conn, connect_host, connect_port, socks5listener, "*a");

	socks5listener.register_outgoing(conn, host_session);

	host_session.conn = conn;
end

local function bounce_sendq(session, reason)
	local sendq = session.sendq;
	if not sendq then return; end
	session.log("info", "sending error replies for "..#sendq.." queued stanzas because of failed outgoing connection to "..tostring(session.to_host));
	local dummy = {
		type = "s2sin";
		send = function(s)
			(session.log or log)("error", "Replying to to an s2s error reply, please report this! Traceback: %s", traceback());
		end;
		dummy = true;
	};
	for i, data in ipairs(sendq) do
		local reply = data[2];
		if reply and not(reply.attr.xmlns) then
			reply.attr.type = "error";
			reply:tag("error", {type = "cancel"})
				:tag("remote-server-not-found", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}):up();
			if reason then
				reply:tag("text", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"})
						:text("Server-to-server connection failed: "..reason):up();
			end
			core_process_stanza(dummy, reply);
		end
		sendq[i] = nil;
	end
	session.sendq = nil;
end

-- Try to intercept anything to *.onion
local function route_to_onion(event)

	if not event.to_host:find(".onion(.?)$") then
		if forbid_else then
	                module:log("debug", event.to_host .. " is not an onion. Blocking it.");
			return false;
		elseif not torify_all then
			return;
		end
	end

	module:log("debug", "Onion routing something to ".. event.to_host);

	if hosts[event.from_host].s2sout[event.to_host] then
		return;
	end

	local host_session = s2s_new_outgoing(event.from_host, event.to_host);

	host_session.bounce_sendq = bounce_sendq;
	host_session.sendq = { {tostring(stanza), stanza.attr and stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza)} };

	hosts[event.from_host].s2sout[event.to_host] = host_session;

	connect_socks5(host_session, event.to_host, 5269);

	return true;
end

module:log("debug", "Onions ready and loaded");

hosts[module.host].events.add_handler("route/remote", route_to_onion, 200);
