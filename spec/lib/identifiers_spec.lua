-- Parsing and comparison only. No server and no redis are involved, so this
-- runs on its own wherever busted does.
local Identifiers = require "lib.identifiers"

describe("Identifiers", function()
    describe("#parse_list", function()
        it("keeps the order the client sent", function()
            local list = Identifiers.parse_list({
                { type = "content", value = "aaa" },
                { type = "structure", value = "bbb" },
                { type = "metadata", value = "ccc" },
            })
            assert.are.same({
                { type = "content", value = "aaa" },
                { type = "structure", value = "bbb" },
                { type = "metadata", value = "ccc" },
            }, list)
        end)

        it("rejects an absent, empty or oversized list", function()
            assert.is_nil(Identifiers.parse_list(nil))
            assert.is_nil(Identifiers.parse_list({}))
            assert.is_nil(Identifiers.parse_list("content:aaa"))
            local many = {}
            for index = 1, Identifiers.max_count + 1 do
                table.insert(many, { type = "t" .. index, value = "v" .. index })
            end
            assert.is_nil(Identifiers.parse_list(many))
        end)

        it("rejects malformed entries", function()
            assert.is_nil(Identifiers.parse_list({ "content:aaa" }))
            assert.is_nil(Identifiers.parse_list({ { type = "content" } }))
            assert.is_nil(Identifiers.parse_list({ { value = "aaa" } }))
            assert.is_nil(Identifiers.parse_list({ { type = "Content", value = "aaa" } }))
            assert.is_nil(Identifiers.parse_list({ { type = "content", value = "" } }))
            assert.is_nil(Identifiers.parse_list({ { type = "content", value = "a:b" } }))
            assert.is_nil(Identifiers.parse_list({ { type = "content", value = "a,b" } }))
            assert.is_nil(Identifiers.parse_list({ { type = "con:tent", value = "aaa" } }))
            assert.is_nil(Identifiers.parse_list({ { type = "content", value = 1 } }))
            assert.is_nil(Identifiers.parse_list({
                { type = "content", value = "aaa" },
                { type = "content", value = "bbb" },
            }))
        end)

        it("keeps the weak flag, and rejects one that is not a boolean", function()
            assert.are.same({
                { type = "content", value = "aaa" },
                { type = "metadata", value = "bbb", weak = true },
            }, Identifiers.parse_list({
                { type = "content", value = "aaa", weak = false },
                { type = "metadata", value = "bbb", weak = true },
            }))
            assert.is_nil(Identifiers.parse_list({
                { type = "metadata", value = "bbb", weak = "yes" },
            }))
        end)

        it("rejects a value longer than a digest", function()
            local long = string.rep("a", Identifiers.max_value_length + 1)
            assert.is_nil(Identifiers.parse_list({ { type = "content", value = long } }))
        end)
    end)

    describe("#parse_query", function()
        it("reads the same list from one query parameter", function()
            assert.are.same({
                { type = "content", value = "aaa" },
                { type = "metadata", value = "bbb" },
            }, Identifiers.parse_query("content:aaa,metadata:bbb"))
        end)

        it("rejects anything it cannot read exactly", function()
            assert.is_nil(Identifiers.parse_query(nil))
            assert.is_nil(Identifiers.parse_query(""))
            assert.is_nil(Identifiers.parse_query("aaa"))
            assert.is_nil(Identifiers.parse_query("content:"))
            assert.is_nil(Identifiers.parse_query(":aaa"))
            assert.is_nil(Identifiers.parse_query("content:aaa,"))
            assert.is_nil(Identifiers.parse_query("content:aaa:bbb"))
            assert.is_nil(Identifiers.parse_query("content:aaa,content:bbb"))
            assert.is_nil(Identifiers.parse_query(true))
        end)
    end)

    describe("#weak_flags", function()
        it("reports one flag per identifier, in list order", function()
            assert.are.same("010", Identifiers.weak_flags({
                { type = "content", value = "aaa" },
                { type = "metadata", value = "bbb", weak = true },
                { type = "filename", value = "ccc" },
            }))
        end)
    end)

    describe("#encode_list", function()
        it("round trips", function()
            local list = Identifiers.parse_query("content:aaa,metadata:bbb")
            assert.are.same("content:aaa,metadata:bbb", Identifiers.encode_list(list))
            assert.are.same(list, Identifiers.decode_list(Identifiers.encode_list(list)))
        end)

        it("reads an empty stored list as no list at all", function()
            assert.is_nil(Identifiers.decode_list(""))
            assert.is_nil(Identifiers.decode_list(nil))
        end)
    end)

    describe("#alias", function()
        it("carries the type it was registered under", function()
            assert.are.same("metadata:canonical",
                Identifiers.encode_alias("metadata", "canonical"))
            local alias_type, canonical = Identifiers.decode_alias("metadata:canonical")
            assert.are.same("metadata", alias_type)
            assert.are.same("canonical", canonical)
        end)

        it("refuses a value it cannot split", function()
            assert.is_nil(Identifiers.decode_alias("metadata:"))
            assert.is_nil(Identifiers.decode_alias("metadata"))
            assert.is_nil(Identifiers.decode_alias(nil))
        end)
    end)

    describe("#common", function()
        local reader = Identifiers.parse_query("content:C1,structure:S1,metadata:M")

        it("reports nothing when the writer shares no identifier", function()
            assert.is_nil(Identifiers.common(reader,
                Identifiers.parse_query("content:C2,structure:S2,metadata:N")))
        end)

        it("reports only the weak identifier for a different edition", function()
            assert.are.same("metadata", Identifiers.common(reader,
                Identifiers.parse_query("content:C2,structure:S2,metadata:M")))
        end)

        it("reports the structure of a repackaged but identically rendered copy", function()
            assert.are.same("structure", Identifiers.common(reader,
                Identifiers.parse_query("content:C2,structure:S1,metadata:M")))
        end)

        it("prefers the reader's own order, not the writer's", function()
            assert.are.same("content", Identifiers.common(reader,
                Identifiers.parse_query("metadata:M,structure:S1,content:C1")))
            assert.are.same("metadata", Identifiers.common(
                Identifiers.parse_query("metadata:M,content:C1"),
                Identifiers.parse_query("content:C1,metadata:M")))
        end)

        it("names an untyped reader digest by the writer's type", function()
            assert.are.same("content", Identifiers.common({ { value = "C1" } },
                Identifiers.parse_query("content:C1,metadata:M")))
        end)

        it("reports nothing when either side is unknown", function()
            assert.is_nil(Identifiers.common(nil, reader))
            assert.is_nil(Identifiers.common(reader, nil))
        end)
    end)
end)
