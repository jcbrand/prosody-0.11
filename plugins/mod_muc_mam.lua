-- XEP-0313: Message Archive Management for Prosody MUC
-- Copyright (C) 2011-2017 Kim Alvefur
--
-- This file is MIT/X11 licensed.

if module:get_host_type() ~= "component" then
	module:log("error", "mod_%s should be loaded only on a MUC component, not normal hosts", module.name);
	return;
end

local xmlns_mam     = "urn:xmpp:mam:2";
local xmlns_delay   = "urn:xmpp:delay";
local xmlns_forward = "urn:xmpp:forward:0";
local xmlns_st_id   = "urn:xmpp:sid:0";
local xmlns_muc_user = "http://jabber.org/protocol/muc#user";
local muc_form_enable = "muc#roomconfig_enablearchiving"

local st = require "util.stanza";
local rsm = require "util.rsm";
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local jid_prep = require "util.jid".prep;
local dataform = require "util.dataforms".new;

local mod_muc = module:depends"muc";
local get_room_from_jid = mod_muc.get_room_from_jid;

local is_stanza = st.is_stanza;
local tostring = tostring;
local time_now = os.time;
local m_min = math.min;
local timestamp, timestamp_parse, datestamp = import( "util.datetime", "datetime", "parse", "date");
local default_max_items, max_max_items = 20, module:get_option_number("max_archive_query_results", 50);

local default_history_length = 20;
local max_history_length = module:get_option_number("max_history_messages", math.huge);

local function get_historylength(room)
	return math.min(room._data.history_length or default_history_length, max_history_length);
end

function schedule_cleanup()
	-- replaced by non-noop later if cleanup is enabled
end

local log_all_rooms = module:get_option_boolean("muc_log_all_rooms", false);
local log_by_default = module:get_option_boolean("muc_log_by_default", true);

local archive_store = "muc_log";
local archive = module:open_store(archive_store, "archive");

if archive.name == "null" or not archive.find then
	if not archive.find then
		module:log("error", "Attempt to open archive storage returned a driver without archive API support");
		module:log("error", "mod_%s does not support archiving",
			archive._provided_by or archive.name and "storage_"..archive.name.."(?)" or "<unknown>");
	else
		module:log("error", "Attempt to open archive storage returned null driver");
	end
	module:log("info", "See https://prosody.im/doc/storage and https://prosody.im/doc/archiving for more information");
	return false;
end

local function archiving_enabled(room)
	if log_all_rooms then
		return true;
	end
	local enabled = room._data.archiving;
	if enabled == nil then
		return log_by_default;
	end
	return enabled;
end

if not log_all_rooms then
	module:hook("muc-config-form", function(event)
		local room, form = event.room, event.form;
		table.insert(form,
		{
			name = muc_form_enable,
			type = "boolean",
			label = "Enable archiving?",
			value = archiving_enabled(room),
		}
		);
	end);

	module:hook("muc-config-submitted/"..muc_form_enable, function(event)
		event.room._data.archiving = event.value;
		event.status_codes[event.value and "170" or "171"] = true;
	end);
end

-- Note: We ignore the 'with' field as this is internally used for stanza types
local query_form = dataform {
	{ name = "FORM_TYPE"; type = "hidden"; value = xmlns_mam; };
	{ name = "with"; type = "jid-single"; };
	{ name = "start"; type = "text-single" };
	{ name = "end"; type = "text-single"; };
};

-- Serve form
module:hook("iq-get/bare/"..xmlns_mam..":query", function(event)
	local origin, stanza = event.origin, event.stanza;
	origin.send(st.reply(stanza):tag("query", { xmlns = xmlns_mam }):add_child(query_form:form()));
	return true;
end);


if rawget(_G, "setfenv") == nil then
	rawset(_G, "setfenv", false)
end
if rawget(_G, "getfenv") == nil then
	rawset(_G, "getfenv", false)
end

-- Handle archive queries
module:hook("iq-set/bare/"..xmlns_mam..":query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local room_jid = stanza.attr.to;
	local room_node = jid_split(room_jid);
	local orig_from = stanza.attr.from;
	local query = stanza.tags[1];

	local room = get_room_from_jid(room_jid);
	if not room then
		origin.send(st.error_reply(stanza, "cancel", "item-not-found"))
		return true;
	end
	local from = jid_bare(orig_from);

	-- Banned or not a member of a members-only room?
	local from_affiliation = room:get_affiliation(from);
	if from_affiliation == "outcast" -- banned
		or room:get_members_only() and not from_affiliation then -- members-only, not a member
		origin.send(st.error_reply(stanza, "auth", "forbidden"))
		return true;
	end

	local qid = query.attr.queryid;

	-- Search query parameters
	local qstart, qend;
	local form = query:get_child("x", "jabber:x:data");
	if form then
		local err;
		form, err = query_form:data(form);
		if err then
			origin.send(st.error_reply(stanza, "modify", "bad-request", select(2, next(err))));
			return true;
		end
		qstart, qend = form["start"], form["end"];
	end

	if qstart or qend then -- Validate timestamps
		local vstart, vend = (qstart and timestamp_parse(qstart)), (qend and timestamp_parse(qend))
		if (qstart and not vstart) or (qend and not vend) then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid timestamp"))
			return true;
		end
		qstart, qend = vstart, vend;
	end

	module:log("debug", "Archive query id %s from %s until %s)",
		tostring(qid),
		qstart and timestamp(qstart) or "the dawn of time",
		qend and timestamp(qend) or "now");

	-- RSM stuff
	local qset = rsm.get(query);
	local qmax = m_min(qset and qset.max or default_max_items, max_max_items);
	local reverse = qset and qset.before or false;

	local before, after = qset and qset.before, qset and qset.after;
	if type(before) ~= "string" then before = nil; end

	-- Load all the data!
	local data, err = archive:find(room_node, {
		start = qstart; ["end"] = qend; -- Time range
		limit = qmax + 1;
		before = before; after = after;
		reverse = reverse;
		with = "message<groupchat";
	});

	if not data then
		origin.send(st.error_reply(stanza, "cancel", "internal-server-error"));
		return true;
	end
	local total = tonumber(err);

	local msg_reply_attr = { to = stanza.attr.from, from = stanza.attr.to };

	local results = {};
	require("mobdebug").start()

	-- Wrap it in stuff and deliver
	local first, last;
	local count = 0;
	local complete = "true";
	for id, item, when in data do
		count = count + 1;
		if count > qmax then
			complete = nil;
			break;
		end
		local fwd_st = st.message(msg_reply_attr)
			:tag("result", { xmlns = xmlns_mam, queryid = qid, id = id })
				:tag("forwarded", { xmlns = xmlns_forward })
					:tag("delay", { xmlns = xmlns_delay, stamp = timestamp(when) }):up();

		-- Strip <x> tag, containing the original senders JID, unless the room makes this public
		if room:get_whois() ~= "anyone" then
			item:maptags(function (tag)
				if tag.name == "x" and tag.attr.xmlns == xmlns_muc_user then
					return nil;
				end
				return tag;
			end);
		end
		if not is_stanza(item) then
			item = st.deserialize(item);
		end
		require("mobdebug").start()
		item.attr.to = nil;
		item.attr.xmlns = "jabber:client";
		fwd_st:add_child(item);

		if not first then first = id; end
		last = id;

		if reverse then
			results[count] = fwd_st;
		else
			origin.send(fwd_st);
		end
	end

	if reverse then
		for i = #results, 1, -1 do
			origin.send(results[i]);
		end
		first, last = last, first;
	end

	-- That's all folks!
	module:log("debug", "Archive query %s completed", tostring(qid));

	origin.send(st.reply(stanza)
		:tag("fin", { xmlns = xmlns_mam, queryid = qid, complete = complete })
			:add_child(rsm.generate {
				first = first, last = last, count = total }));
	return true;
end);

module:hook("muc-get-history", function (event)
	local room = event.room;
	if not archiving_enabled(room) then return end
	local room_jid = room.jid;
	local maxstanzas = event.maxstanzas;
	local maxchars = event.maxchars;
	local since = event.since;
	local to = event.to;

	if maxstanzas == 0 or maxchars == 0 then
		return -- No history requested
	end

	if not maxstanzas or maxstanzas > get_historylength(room) then
		maxstanzas = get_historylength(room);
	end

	if room._history and #room._history >= maxstanzas then
		return -- It can deal with this itself
	end

	-- Load all the data!
	local query = {
		limit = maxstanzas;
		start = since;
		reverse = true;
		with = "message<groupchat";
	}
	local data, err = archive:find(jid_split(room_jid), query);

	if not data then
		module:log("error", "Could not fetch history: %s", tostring(err));
		return
	end

	local history, i = {}, 1;

	for id, item, when in data do
		item.attr.to = to;
		item:tag("delay", { xmlns = "urn:xmpp:delay", from = room_jid, stamp = timestamp(when) }):up(); -- XEP-0203
		item:tag("stanza-id", { xmlns = xmlns_st_id, by = room_jid, id = id }):up();
		if room:get_whois() ~= "anyone" then
			item:maptags(function (tag)
				if tag.name == "x" and tag.attr.xmlns == xmlns_muc_user then
					return nil;
				end
				return tag;
			end);
		end
		if maxchars then
			local chars = #tostring(item);
			if maxchars - chars < 0 then
				break
			end
			maxchars = maxchars - chars;
		end
		history[i], i = item, i+1;
		-- module:log("debug", tostring(item));
	end
	function event.next_stanza()
		i = i - 1;
		return history[i];
	end
	return true;
end, 1);

module:hook("muc-broadcast-messages", function (event)
	local room, stanza = event.room, event.stanza;

	-- Filter out <stanza-id> that claim to be from us
	stanza:maptags(function (tag)
		if tag.name == "stanza-id" and tag.attr.xmlns == xmlns_st_id
		and jid_prep(tag.attr.by) == room.jid then
			return nil;
		end
		if tag.name == "x" and tag.attr.xmlns == xmlns_muc_user then
			return nil;
		end
		return tag;
	end);

end, 0);

-- Handle messages
local function save_to_history(self, stanza)
	local room_node, room_host = jid_split(self.jid);

	local stored_stanza = stanza;

	if stanza.name == "message" and self:get_whois() == "anyone" then
		stored_stanza = st.clone(stanza);
		stored_stanza.attr.to = nil;
		local actor = jid_bare(self._occupants[stanza.attr.from].jid);
		local affiliation = self:get_affiliation(actor) or "none";
		local role = self:get_role(actor) or self:get_default_role(affiliation);
		stored_stanza:add_direct_child(st.stanza("x", { xmlns = xmlns_muc_user })
			:tag("item", { affiliation = affiliation; role = role; jid = actor }));
	end

	-- Policy check
	if not archiving_enabled(self) then return end -- Don't log

	-- Save the type in the 'with' field, allows storing presence without conflicts
	local with = stanza.name
	if stanza.attr.type then
		with = with .. "<" .. stanza.attr.type
	end

	-- And stash it
	local id, err = archive:append(room_node, nil, stored_stanza, time_now(), with);

	if id then
		schedule_cleanup(room_node);
		stanza:add_direct_child(st.stanza("stanza-id", { xmlns = xmlns_st_id, by = self.jid, id = id }));
	else
		module:log("error", "Could not archive stanza: %s", err);
	end
end

module:hook("muc-add-history", function (event)
	local room, stanza = event.room, event.stanza;
	save_to_history(room, stanza);
end);

if module:get_option_boolean("muc_log_presences", false) then
	module:hook("muc-occupant-joined", function (event)
		save_to_history(event.room, st.stanza("presence", { from = event.nick }):tag("x", { xmlns = "http://jabber.org/protocol/muc" }));
	end);
	module:hook("muc-occupant-left", function (event)
		save_to_history(event.room, st.stanza("presence", { type = "unavailable", from = event.nick }));
	end);
end

if not archive.delete then
	module:log("warn", "Storage driver %s does not support deletion", archive._provided_by);
	module:log("warn", "Archived message will persist after a room has been destroyed");
else
	module:hook("muc-room-destroyed", function(event)
		local room_node = jid_split(event.room.jid);
		archive:delete(room_node);
	end);
end

-- And role/affiliation changes?

module:add_feature(xmlns_mam);

module:hook("muc-disco#info", function(event)
	event.reply:tag("feature", {var=xmlns_mam}):up();
end);

-- Cleanup

local cleanup_after = module:get_option_string("muc_log_expires_after", "1w");
local cleanup_interval = module:get_option_number("muc_log_cleanup_interval", 4 * 60 * 60);

if cleanup_after ~= "never" then
	local cleanup_storage = module:open_store("muc_log_cleanup");
	local cleanup_map = module:open_store("muc_log_cleanup", "map");

	local day = 86400;
	local multipliers = { d = day, w = day * 7, m = 31 * day, y = 365.2425 * day };
	local n, m = cleanup_after:lower():match("(%d+)%s*([dwmy]?)");
	if not n then
		module:log("error", "Could not parse muc_log_expires_after string %q", cleanup_after);
		return false;
	end

	cleanup_after = tonumber(n) * ( multipliers[m] or 1 );

	module:log("debug", "muc_log_expires_after = %d -- in seconds", cleanup_after);

	if not archive.delete then
		module:log("error", "muc_log_expires_after set but mod_%s does not support deleting", archive._provided_by);
		return false;
	end

	-- For each day, store a set of rooms that have new messages. To expire
	-- messages, we collect the union of sets of rooms from dates that fall
	-- outside the cleanup range.

	local last_date = require "util.cache".new(module:get_option_number("muc_log_cleanup_date_cache_size", 1000));
	function schedule_cleanup(roomname, date)
		date = date or datestamp();
		if last_date:get(roomname) == date then return end
		local ok = cleanup_map:set(date, roomname, true);
		if ok then
			last_date:set(roomname, date);
		end
	end

	cleanup_runner = require "util.async".runner(function ()
		local rooms = {};
		local cut_off = datestamp(os.time() - cleanup_after);
		for date in cleanup_storage:users() do
			if date <= cut_off then
				module:log("debug", "Messages from %q should be expired", date);
				local messages_this_day = cleanup_storage:get(date);
				if messages_this_day then
					for room in pairs(messages_this_day) do
						rooms[room] = true;
					end
					if date < cut_off then
						-- Messages from the same day as the cut-off might not have expired yet,
						-- but all earlier will have, so clear storage for those days.
						cleanup_storage:set(date, nil);
					end
				end
			end
		end
		local sum, num_rooms = 0, 0;
		for room in pairs(rooms) do
			local ok, err = archive:delete(room, { ["end"] = os.time() - cleanup_after; })
			if ok then
				num_rooms = num_rooms + 1;
				sum = sum + (tonumber(ok) or 0);
			else
				cleanup_map:set(cut_off, room, true);
				module:log("error", "Could not delete messages for room '%s': %s", room, err);
			end
		end
		module:log("info", "Deleted %d expired messages for %d rooms", sum, num_rooms);
	end);

	cleanup_task = module:add_timer(1, function ()
		cleanup_runner:run(true);
		return cleanup_interval;
	end);
else
	module:log("debug", "Archive expiry disabled");
end
