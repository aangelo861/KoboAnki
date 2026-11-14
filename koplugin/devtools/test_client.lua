--[[
Desktop tests for the plugin's non-UI modules (kanki/json, kanki/client, kanki/cardhtml),
run against mock_server.py. See README.md in this folder.

    python3 mock_server.py --scenario fresh --sync-speed 0.1 --port 47399 &
    luajit test_client.lua 47399
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = table.concat({
    here .. "/stubs/?.lua",
    here .. "/../kanki.koplugin/?.lua",
    package.path,
}, ";")

local port = tonumber(arg[1]) or 47399

local JSON = require("kanki/json")
local Client = require("kanki/client")
local CardHtml = require("kanki/cardhtml")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
    end
end

local function sleep(s)
    local socket = require("socket")
    socket.sleep(s)
end

-- JSON ------------------------------------------------------------------------------------------
do
    local s = JSON.encode({ card_id = 1690000000004, rating = 3, ms_taken = 12345 })
    check("encode big int exactly", s == '{"card_id":1690000000004,"ms_taken":12345,"rating":3}', s)
    check("encode escapes", JSON.encode({ p = 'a"b\\c\n\1' }) == '{"p":"a\\"b\\\\c\\n\\u0001"}', JSON.encode({ p = 'a"b\\c\n\1' }))
    check("encode float", JSON.encode({ x = 1.5 }) == '{"x":1.5}')
    check("encode empty array", JSON.encode(JSON.array()) == "[]")
    local v = JSON.decode('{"a":null,"b":[1,2],"c":{"d":null,"e":"x"},"id":1690000000004}')
    check("decode strips nulls", v and v.a == nil and v.c.d == nil and v.c.e == "x")
    check("decode big int", v and v.id == 1690000000004 and string.format("%d", v.id) == "1690000000004")
    check("decode garbage -> nil", JSON.decode("<html>") == nil)
end

-- CardHtml --------------------------------------------------------------------------------------
do
    local k = 2
    check("scale px", CardHtml.scaleCssLengths(".card{font-size:20px}", k) == ".card{font-size:40px}")
    check("scale pt/rem", CardHtml.scaleCssLengths("a{b:12pt;c:1rem}", k) == "a{b:32px;c:32px}",
        CardHtml.scaleCssLengths("a{b:12pt;c:1rem}", k))
    check("keep url()", CardHtml.scaleCssLengths("a{background:url(x_10px.png)}", k) == "a{background:url(x_10px.png)}")
    check("keep identifiers", CardHtml.scaleCssLengths(".h10px{}", k) == ".h10px{}")
    check("negative", CardHtml.scaleCssLengths("a{margin:-5px}", k) == "a{margin:-10px}")
    check("inline double", CardHtml.scaleInlineStyles('<b style="font-size:10px">x 10px</b>', k)
        == '<b style="font-size:20px">x 10px</b>')
    check("inline single", CardHtml.scaleInlineStyles("<b style='width:3px'>", k) == "<b style='width:6px'>")
    check("src values protected", CardHtml.scaleInlineStyles('<img src="a+style=&quot;b 5px">x', k) == '<img src="a+style=&quot;b 5px">x')
    check("width attribute untouched", CardHtml.scaleInlineStyles('<img src="a.png" width="1181">', k) == '<img src="a.png" width="1181">')
    check("data-style untouched", CardHtml.scaleInlineStyles('<b data-style="width:3px">', k) == '<b data-style="width:3px">')
    check("wrap", CardHtml.wrapCard("x", 1) == '<div class="card card1">x</div>')
    check("no double wrap", CardHtml.wrapCard('<div class="card card2">x</div>') == '<div class="card card2">x</div>')
    local body, css = CardHtml.build("<p>Q</p>", ".card{font-size:20px}", { font_px = 47 })
    check("build", body == '<div class="card"><p>Q</p></div>' and css:find(".card{font-size:47px}", 1, true) ~= nil)
    check("hasImages", CardHtml.hasImages('<img src="a.png">') and not CardHtml.hasImages("<p>image</p>"))
end

-- Client against the mock ---------------------------------------------------------------------------
Client:setPort(port)

local st, err = Client:status()
if not st then
    print("Mock server not reachable on port " .. port .. ": " .. tostring(err))
    print("Start it with: python3 mock_server.py --scenario fresh --sync-speed 0.1 --port " .. port)
    os.exit(2)
end
check("status ok", st.version ~= nil)
check("fresh: logged out", st.logged_in == false and st.username == nil, st.username)

local res
res, err = Client:startSync("normal")
check("sync needs login (401 need_login)", res == nil and err.kind == "need_login" and err.status == 401, err and err.kind)

res, err = Client:login("doctor@example.com", "wrong")
check("bad credentials -> auth", res == nil and err.kind == "auth" and err.status == 401, err and err.kind)
check("error tostring", tostring(err) == err.message)

res, err = Client:login("doctor@example.com", "correct horse")
check("login ok", res and res.ok == true, err)

res, err = Client:startSync("normal")
check("start sync 202", res and res.started == true, err)

res, err = Client:startSync("normal")
check("second sync -> busy", res == nil and err.kind == "busy" and err.status == 409, err and err.kind)

res, err = Client:decks()
check("decks busy during collection stage", res == nil and err and err.kind == "busy", err and err.kind)

local seen = {}
local final
for _ = 1, 100 do
    local s = Client:syncStatus()
    if s then
        seen[s.state .. "/" .. tostring(s.stage)] = true
        if s.state ~= "running" then final = s break end
    end
    sleep(0.1)
end
check("sync passed through collection", seen["running/collection"])
check("sync passed through media", seen["running/media"])
check("sync done", final and final.state == "done" and final.last_success ~= nil, final and final.state)
check("stage null -> nil", final and final.stage == nil)

st = Client:status()
check("has collection now", st and st.has_collection == true)

local decks = Client:decks()
check("decks list", decks and #decks.decks > 3 and decks.decks[1].short_name ~= nil)

res, err = Client:selectDeck(11)
check("select deck", res and res.ok, err)

local n1 = Client:nextCard(1210)
check("next card", n1 and n1.state == "card" and n1.card and #n1.card.buttons == 4, n1 and n1.state)
check("undo null -> nil", n1 and n1.undo == nil)
check("answer has hr", n1 and n1.card.answer:find("<hr id=answer>", 1, true) ~= nil)
check("card has ord", n1 and n1.card.ord == 1)

-- GET /card: any card, queue untouched; width="img_max_px" only on images wider than that
local c3 = Client:card(1690000000003, 1181)
check("/card renders", c3 and c3.card and c3.card.id == 1690000000003)
check("/card width attr on wide image", c3 and c3.card.question:find('<img src="ecg_stemi.png" width="1181">', 1, true) ~= nil)
local n_again = Client:nextCard(1210)
check("/card did not touch the queue", n_again and n_again.card.id == n1.card.id)

-- Image occlusion: one big data: URI, which our HTML preparation must keep byte-for-byte
local occ = Client:card(1690000000008)
local uri = occ and occ.card.question:match('src="(data:image/[^"]+)"')
check("occlusion card is a big data URI", uri and #uri > 100000, uri and #uri)
if uri then
    local t0 = os.clock()
    local body = CardHtml.build(occ.card.answer .. '<span style="font-size:10px">x</span>', occ.card.css,
        { font_px = 47, ord = 2 }) -- /card is a preview without ord; test the wrapping itself
    local dt = os.clock() - t0
    check("data URI untouched by scaling", body:find(uri, 1, true) ~= nil)
    check("inline style next to it still scaled", body:find("font-size:23.5px", 1, true) ~= nil)
    check("wrapped with ord", body:find('^<div class="card card2">') ~= nil)
    check("build of a ~600 KB card is fast", dt < 0.5, dt)
end

local v = Client:verify()
check("/verify", v and type(v.cards) == "number" and type(v.notes) == "number" and v.media_files ~= nil)

res, err = Client:adopt(4242)
check("/adopt", res and res.ok, err)
st = Client:status()
check("adopt recorded (mock field)", st and st.mock_parent_pid == 4242)
res, err = Client:adopt(-1)
check("/adopt validates", res == nil and err.kind == "bad_request", err and err.kind)

local first_id = n1.card.id
local n2
n2, err = Client:answer(first_id, 3, 4321, 1210)
check("answer -> next", n2 and (n2.state == "card" or n2.state == "done"), err)
check("undo label", n2 and n2.undo == "Answer Card", n2 and n2.undo)

local n3
n3, err = Client:undo(1210)
check("undo brings card back", n3 and n3.card and n3.card.id == first_id, err)

res, err = Client:answer(first_id, 7, 10)
check("bad rating -> bad_request", res == nil and err.kind == "bad_request" and err.status == 400, err and err.kind)

res, err = Client:bury(first_id, 1210)
check("bury", res and res.undo == "Bury Card", err)

res, err = Client:request("GET", "/nope")
check("404 maps kind", res == nil and err.kind == "bad_request", err and err.kind)

res, err = Client:logout()
check("logout", res and res.ok, err)

res = Client:shutdown()
check("shutdown", res and res.ok)
sleep(0.8)
res, err = Client:status({ quiet = true })
check("after shutdown -> server_down", res == nil and err.kind == "server_down", err and err.kind)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
