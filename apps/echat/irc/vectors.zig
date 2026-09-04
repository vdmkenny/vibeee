//! IRC parser vectors, generated from third_party/irc-parser-tests by `make irctests`.
//! Do not edit: re-pin the reference and run it again.

/// One case every implementation must agree about.
pub const Case = struct {
    input: []const u8 = "",
    desc: []const u8 = "",
    tags: []const [2][]const u8 = &.{},
    source: ?[]const u8 = null,
    verb: ?[]const u8 = null,
    params: []const []const u8 = &.{},
    matches: []const []const u8 = &.{},
    nick: ?[]const u8 = null,
    user: ?[]const u8 = null,
    host: ?[]const u8 = null,
    /// False where the reference says the line cannot be parsed.
    atoms: bool = true,
};

/// A line and the atoms a parser must find in it.
pub const split = [_]Case{
    .{
        .input = "foo bar baz asdf",
        .verb = "foo",
        .params = &.{ "bar", "baz", "asdf" },
    },
    .{
        .input = ":coolguy foo bar baz asdf",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "asdf" },
    },
    .{
        .input = "foo bar baz :asdf quux",
        .verb = "foo",
        .params = &.{ "bar", "baz", "asdf quux" },
    },
    .{
        .input = "foo bar baz :",
        .verb = "foo",
        .params = &.{ "bar", "baz", "" },
    },
    .{
        .input = "foo bar baz ::asdf",
        .verb = "foo",
        .params = &.{ "bar", "baz", ":asdf" },
    },
    .{
        .input = ":coolguy foo bar baz :asdf quux",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "asdf quux" },
    },
    .{
        .input = ":coolguy foo bar baz :  asdf quux ",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "  asdf quux " },
    },
    .{
        .input = ":coolguy PRIVMSG bar :lol :) ",
        .source = "coolguy",
        .verb = "PRIVMSG",
        .params = &.{ "bar", "lol :) " },
    },
    .{
        .input = ":coolguy foo bar baz :",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "" },
    },
    .{
        .input = ":coolguy foo bar baz :  ",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "  " },
    },
    .{
        .input = "@a=b;c=32;k;rt=ql7 foo",
        .tags = &.{ .{ "a", "b" }, .{ "c", "32" }, .{ "k", "" }, .{ "rt", "ql7" } },
        .verb = "foo",
    },
    .{
        .input = "@a=b\\\\and\\nk;c=72\\s45;d=gh\\:764 foo",
        .tags = &.{ .{ "a", "b\\and\nk" }, .{ "c", "72 45" }, .{ "d", "gh;764" } },
        .verb = "foo",
    },
    .{
        .input = "@c;h=;a=b :quux ab cd",
        .tags = &.{ .{ "c", "" }, .{ "h", "" }, .{ "a", "b" } },
        .source = "quux",
        .verb = "ab",
        .params = &.{"cd"},
    },
    .{
        .input = ":src JOIN #chan",
        .source = "src",
        .verb = "JOIN",
        .params = &.{"#chan"},
    },
    .{
        .input = ":src JOIN :#chan",
        .source = "src",
        .verb = "JOIN",
        .params = &.{"#chan"},
    },
    .{
        .input = ":src AWAY",
        .source = "src",
        .verb = "AWAY",
    },
    .{
        .input = ":src AWAY ",
        .source = "src",
        .verb = "AWAY",
    },
    .{
        .input = ":cool\tguy foo bar baz",
        .source = "cool\tguy",
        .verb = "foo",
        .params = &.{ "bar", "baz" },
    },
    .{
        .input = ":coolguy!ag@net\x035w\x03ork.admin PRIVMSG foo :bar baz",
        .source = "coolguy!ag@net\x035w\x03ork.admin",
        .verb = "PRIVMSG",
        .params = &.{ "foo", "bar baz" },
    },
    .{
        .input = ":coolguy!~ag@n\x02et\x0305w\x0fork.admin PRIVMSG foo :bar baz",
        .source = "coolguy!~ag@n\x02et\x0305w\x0fork.admin",
        .verb = "PRIVMSG",
        .params = &.{ "foo", "bar baz" },
    },
    .{
        .input = "@tag1=value1;tag2;vendor1/tag3=value2;vendor2/tag4= :irc.example.com COMMAND param1 param2 :param3 param3",
        .tags = &.{ .{ "tag1", "value1" }, .{ "tag2", "" }, .{ "vendor1/tag3", "value2" }, .{ "vendor2/tag4", "" } },
        .source = "irc.example.com",
        .verb = "COMMAND",
        .params = &.{ "param1", "param2", "param3 param3" },
    },
    .{
        .input = ":irc.example.com COMMAND param1 param2 :param3 param3",
        .source = "irc.example.com",
        .verb = "COMMAND",
        .params = &.{ "param1", "param2", "param3 param3" },
    },
    .{
        .input = "@tag1=value1;tag2;vendor1/tag3=value2;vendor2/tag4 COMMAND param1 param2 :param3 param3",
        .tags = &.{ .{ "tag1", "value1" }, .{ "tag2", "" }, .{ "vendor1/tag3", "value2" }, .{ "vendor2/tag4", "" } },
        .verb = "COMMAND",
        .params = &.{ "param1", "param2", "param3 param3" },
    },
    .{
        .input = "COMMAND",
        .verb = "COMMAND",
    },
    .{
        .input = "@foo=\\\\\\\\\\:\\\\s\\s\\r\\n COMMAND",
        .tags = &.{.{ "foo", "\\\\;\\s \r\n" }},
        .verb = "COMMAND",
    },
    .{
        .input = ":gravel.mozilla.org 432  #momo :Erroneous Nickname: Illegal characters",
        .source = "gravel.mozilla.org",
        .verb = "432",
        .params = &.{ "#momo", "Erroneous Nickname: Illegal characters" },
    },
    .{
        .input = ":gravel.mozilla.org MODE #tckk +n ",
        .source = "gravel.mozilla.org",
        .verb = "MODE",
        .params = &.{ "#tckk", "+n" },
    },
    .{
        .input = ":services.esper.net MODE #foo-bar +o foobar  ",
        .source = "services.esper.net",
        .verb = "MODE",
        .params = &.{ "#foo-bar", "+o", "foobar" },
    },
    .{
        .input = "@tag1=value\\\\ntest COMMAND",
        .tags = &.{.{ "tag1", "value\\ntest" }},
        .verb = "COMMAND",
    },
    .{
        .input = "@tag1=value\\1 COMMAND",
        .tags = &.{.{ "tag1", "value1" }},
        .verb = "COMMAND",
    },
    .{
        .input = "@tag1=value1\\ COMMAND",
        .tags = &.{.{ "tag1", "value1" }},
        .verb = "COMMAND",
    },
    .{
        .input = "@tag1=1;tag2=3;tag3=4;tag1=5 COMMAND",
        .tags = &.{ .{ "tag1", "5" }, .{ "tag2", "3" }, .{ "tag3", "4" } },
        .verb = "COMMAND",
    },
    .{
        .input = "@tag1=1;tag2=3;tag3=4;tag1=5;vendor/tag2=8 COMMAND",
        .tags = &.{ .{ "tag1", "5" }, .{ "tag2", "3" }, .{ "tag3", "4" }, .{ "vendor/tag2", "8" } },
        .verb = "COMMAND",
    },
    .{
        .input = ":SomeOp MODE #channel :+i",
        .source = "SomeOp",
        .verb = "MODE",
        .params = &.{ "#channel", "+i" },
    },
    .{
        .input = ":SomeOp MODE #channel +oo SomeUser :AnotherUser",
        .source = "SomeOp",
        .verb = "MODE",
        .params = &.{ "#channel", "+oo", "SomeUser", "AnotherUser" },
    },
};

/// Atoms and every line a writer may render them as.
pub const join = [_]Case{
    .{
        .desc = "Simple test with verb and params.",
        .verb = "foo",
        .params = &.{ "bar", "baz", "asdf" },
        .matches = &.{ "foo bar baz asdf", "foo bar baz :asdf" },
    },
    .{
        .desc = "Simple test with source and no params.",
        .source = "src",
        .verb = "AWAY",
        .matches = &.{":src AWAY"},
    },
    .{
        .desc = "Simple test with source and empty trailing param.",
        .source = "src",
        .verb = "AWAY",
        .params = &.{""},
        .matches = &.{":src AWAY :"},
    },
    .{
        .desc = "Simple test with source.",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "asdf" },
        .matches = &.{ ":coolguy foo bar baz asdf", ":coolguy foo bar baz :asdf" },
    },
    .{
        .desc = "Simple test with trailing param.",
        .verb = "foo",
        .params = &.{ "bar", "baz", "asdf quux" },
        .matches = &.{"foo bar baz :asdf quux"},
    },
    .{
        .desc = "Simple test with empty trailing param.",
        .verb = "foo",
        .params = &.{ "bar", "baz", "" },
        .matches = &.{"foo bar baz :"},
    },
    .{
        .desc = "Simple test with trailing param containing colon.",
        .verb = "foo",
        .params = &.{ "bar", "baz", ":asdf" },
        .matches = &.{"foo bar baz ::asdf"},
    },
    .{
        .desc = "Test with source and trailing param.",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "asdf quux" },
        .matches = &.{":coolguy foo bar baz :asdf quux"},
    },
    .{
        .desc = "Test with trailing containing beginning+end whitespace.",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "  asdf quux " },
        .matches = &.{":coolguy foo bar baz :  asdf quux "},
    },
    .{
        .desc = "Test with trailing containing what looks like another trailing param.",
        .source = "coolguy",
        .verb = "PRIVMSG",
        .params = &.{ "bar", "lol :) " },
        .matches = &.{":coolguy PRIVMSG bar :lol :) "},
    },
    .{
        .desc = "Simple test with source and empty trailing.",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "" },
        .matches = &.{":coolguy foo bar baz :"},
    },
    .{
        .desc = "Trailing contains only spaces.",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "  " },
        .matches = &.{":coolguy foo bar baz :  "},
    },
    .{
        .desc = "Param containing tab (tab is not considered SPACE for message splitting).",
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "b\tar", "baz" },
        .matches = &.{ ":coolguy foo b\tar baz", ":coolguy foo b\tar :baz" },
    },
    .{
        .desc = "Tag with empty value and space-filled trailing.",
        .tags = &.{.{ "asd", "" }},
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "  " },
        .matches = &.{ "@asd :coolguy foo bar baz :  ", "@asd= :coolguy foo bar baz :  " },
    },
    .{
        .desc = "Tag with no value and space-filled trailing.",
        .tags = &.{.{ "asd", "" }},
        .source = "coolguy",
        .verb = "foo",
        .params = &.{ "bar", "baz", "  " },
        .matches = &.{"@asd :coolguy foo bar baz :  "},
    },
    .{
        .desc = "Tags with escaped values.",
        .tags = &.{ .{ "a", "b\\and\nk" }, .{ "d", "gh;764" } },
        .verb = "foo",
        .matches = &.{ "@a=b\\\\and\\nk;d=gh\\:764 foo", "@d=gh\\:764;a=b\\\\and\\nk foo" },
    },
    .{
        .desc = "Tags with escaped values and params.",
        .tags = &.{ .{ "a", "b\\and\nk" }, .{ "d", "gh;764" } },
        .verb = "foo",
        .params = &.{ "par1", "par2" },
        .matches = &.{ "@a=b\\\\and\\nk;d=gh\\:764 foo par1 par2", "@a=b\\\\and\\nk;d=gh\\:764 foo par1 :par2", "@d=gh\\:764;a=b\\\\and\\nk foo par1 par2", "@d=gh\\:764;a=b\\\\and\\nk foo par1 :par2" },
    },
    .{
        .desc = "Tag with long, strange values (including LF and newline).",
        .tags = &.{.{ "foo", "\\\\;\\s \r\n" }},
        .verb = "COMMAND",
        .matches = &.{"@foo=\\\\\\\\\\:\\\\s\\s\\r\\n COMMAND"},
    },
};

/// A source and the three names inside it.
pub const userhost = [_]Case{
    .{
        .input = "coolguy",
        .nick = "coolguy",
    },
    .{
        .input = "coolguy!ag@127.0.0.1",
        .nick = "coolguy",
        .user = "ag",
        .host = "127.0.0.1",
    },
    .{
        .input = "coolguy!~ag@localhost",
        .nick = "coolguy",
        .user = "~ag",
        .host = "localhost",
    },
    .{
        .input = "coolguy@127.0.0.1",
        .nick = "coolguy",
        .host = "127.0.0.1",
    },
    .{
        .input = "coolguy!ag",
        .nick = "coolguy",
        .user = "ag",
    },
    .{
        .input = "coolguy!ag@net\x035w\x03ork.admin",
        .nick = "coolguy",
        .user = "ag",
        .host = "net\x035w\x03ork.admin",
    },
    .{
        .input = "coolguy!~ag@n\x02et\x0305w\x0fork.admin",
        .nick = "coolguy",
        .user = "~ag",
        .host = "n\x02et\x0305w\x0fork.admin",
    },
};
