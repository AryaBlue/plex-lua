-- lovec E:\PlexLove --selftest : offline unit checks + live HTTPS through the worker pool.

local json = require("lib.json")
local winhttp = require("lib.winhttp")
local http = require("lib.http")
local servers = require("plex.servers")
local client = require("plex.client")

local T = {}
local failures, checks = 0, 0

local function check(name, got, want)
    checks = checks + 1
    if got == want then
        print(("  ok   %-48s %s"):format(name, tostring(got)))
    else
        failures = failures + 1
        print(("  FAIL %-48s got %s, want %s"):format(name, tostring(got), tostring(want)))
    end
end

local function offline()
    print("json")
    local v = json.decode('{"a":[1,2.5,-3e2,true,false,null],"s":"x\\"y\\u00e9\\ud83d\\ude00","o":{}}')
    check("array length", #v.a, 6)
    check("number", v.a[3], -300)
    check("null sentinel", v.a[6], json.null)
    check("unicode escapes", v.s, 'x"y\195\169\240\159\152\128')
    check("round trip", json.decode(json.encode({ k = "v\n", n = 3 })).k, "v\n")
    check("bad json errors", pcall(json.decode, "{nope}"), false)

    print("url parsing")
    local u = winhttp.parse_url("https://10-0-0-5.abc123.plex.direct:32400/library/sections?x=1")
    check("host", u.host, "10-0-0-5.abc123.plex.direct")
    check("port", u.port, 32400)
    check("path+query", u.path, "/library/sections?x=1")
    local u6 = winhttp.parse_url("http://[fe80::1]:32400/identity")
    check("ipv6 host", u6.host, "fe80::1")
    check("default https port", winhttp.parse_url("https://plex.tv").port, 443)
    check("query encoding", http.withQuery("/a", { b = "x y&z" }), "/a?b=x%20y%26z")

    print("connection ranking (FINDINGS.md)")
    local I = servers._internal
    check("plex.direct -> ip", I.plex_direct_ip("192-168-1-20.0123abcd.plex.direct"), "192.168.1.20")
    check("private 172.20", I.is_private("172.20.1.1"), true)
    check("public 8.8.8.8", I.is_private("8.8.8.8"), false)
    check("loopback", I.is_loopback("127.0.0.1"), true)
    local function c(t) return t end
    local relay = c({ relay = true, loopback = false, private = false, https = true })
    local lan = c({ relay = false, loopback = false, private = true, https = true })
    local lanHttp = c({ relay = false, loopback = false, private = true, https = false })
    local wan = c({ relay = false, loopback = false, private = false, https = true })
    local loop = c({ relay = false, loopback = true, private = true, https = false })
    check("direct beats relay", servers.better(relay, wan), wan)
    check("loopback beats LAN", servers.better(lan, loop), loop)
    check("LAN beats WAN", servers.better(wan, lanHttp), lanHttp)
    check("https beats http (same class)", servers.better(lanHttp, lan), lan)

    local subs = require("plex.subtitles")
    local cues = subs.parseSrt("\239\187\191" .. "1\r\n00:00:01,500 --> 00:00:03,000\r\n<i>Hello</i> {\\an8}there\r\n\r\n" ..
        "2\n00:01:02.25 --> 00:01:04.000 X1:0\nTwo\\Nlines\n\n3\n00:00:02,000 --> 00:00:02,500\nOverlap\n")
    check("srt cue count", #cues, 3)
    check("srt sorted + ms", cues[2].start, 2)
    check("srt tags stripped", cues[1].text, "Hello there")
    check("vtt-style dot + \\N", cues[3].text, "Two\nlines")
    check("srt 2-digit fraction", cues[3].start, 62.25)
    check("cue at 1.0", (subs.at(cues, 1.0)), nil)
    check("overlapping cues", (subs.at(cues, 2.2)), "Hello there\nOverlap")
    check("cue after jump back", (subs.at(cues, 1.6, 3)), "Hello there")
    check("cue at 63", (subs.at(cues, 63, 1)), "Two\nlines")
end

local live = {}

function T.start()
    client.load()
    offline()
    print("live HTTPS via worker threads")
    local saved = client.settings.token
    client.settings.token = nil   -- don't send the real token in the 401 probe
    local headers = client.headers()
    client.settings.token = saved
    local doneCount = 0
    local function done() doneCount = doneCount + 1 end
    http.json({ url = "https://plex.tv/api/v2/user", headers = headers, timeout = 15 }, function(data, err, res)
        check("GET plex.tv/api/v2/user without token -> 401", res and res.status, 401)
        done()
    end)
    http.json({ url = "https://plex.tv/api/v2/pins", method = "POST", headers = headers, timeout = 15 },
        function(pin, err)
            check("POST pins returns id+code", pin and pin.id ~= nil and type(pin.code) == "string", true)
            done()
        end)
    http.request({ url = "https://does-not-exist.invalid/", timeout = 5 }, function(res, err)
        check("DNS failure reports an error", res == nil and type(err) == "string", true)
        print("       (" .. tostring(err) .. ")")
        done()
    end)
    live.wait = function()
        if doneCount >= 3 then
            print(("%d/%d checks passed"):format(checks - failures, checks))
            love.event.quit(failures == 0 and 0 or 1)
        end
    end
end

function T.update()
    if live.wait then live.wait() end
end

return T
