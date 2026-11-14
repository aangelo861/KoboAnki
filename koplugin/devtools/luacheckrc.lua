-- luacheck config for kanki.koplugin (mirrors the KOReader globals the plugin may touch).
-- Usage: luacheck --config devtools/luacheckrc.lua kanki.koplugin
std = "luajit"
unused_args = false
self = false
max_line_length = false
read_globals = {
    "G_reader_settings",
    "G_defaults",
    "table.pack",
    "table.unpack",
}
ignore = {
    "212/_.*",  -- unused argument starting with _
    "211/_",    -- unused variable _
    "631",      -- line too long
}
