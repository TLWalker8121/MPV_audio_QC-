-- hello-test.lua
-- Simple MPV Lua script test

local mp = require "mp"

mp.msg.info("hello-test.lua loaded successfully")

mp.osd_message("Lua script loaded OK", 5)

mp.add_key_binding("F1", "hello-test-message", function()
    mp.osd_message("F1 works - Lua scripting is active", 3)
    mp.msg.info("F1 test key pressed")
end)