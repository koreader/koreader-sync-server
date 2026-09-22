require 'spec.spec_helper'


local function clear_db()
    local redis = require("redis")
    local client = redis.connect("127.0.0.1", 6379)
    client:select(2)
    client:flushdb()
end

local function redis_client()
    local client = require("redis").connect("127.0.0.1", 6379)
    client:select(2)
    return client
end

describe("SyncsController v2", function()
    before_each(function()
        clear_db()
    end)

    after_each(function()
        clear_db()
    end)

    local function register(username, userkey)
        return hit({
            scheme = "https",
            method = "POST",
            path = "/users/create",
            body = { username = username, password = userkey },
        })
    end

    local function delete_user(username, userkey)
        return hit({
            scheme = "https",
            method = "DELETE",
            path = "/users/me",
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
        })
    end

    -- ids is "type:digest,type:digest", as a client sends it on a read.
    local function get(username, userkey, document, ids)
        return hit({
            scheme = "https",
            method = "GET",
            path = "/syncs/progress/" .. document,
            uri_params = ids and { ids = ids } or nil,
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
        })
    end

    local function update(username, userkey, document, identifiers, percentage, progress, device, device_id)
        return hit({
            scheme = "https",
            method = "PUT",
            path = "/syncs/progress",
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
            body = {
                document = document,
                identifiers = identifiers,
                progress = progress,
                percentage = percentage,
                device = device,
                device_id = device_id,
            }
        })
    end

    -- Three copies of one work: repack is original recompressed, edition
    -- shares only the metadata.
    local original = {
        { type = "content", value = "C1" },
        { type = "structure", value = "S1" },
        { type = "metadata", value = "M" },
    }
    local repack = {
        { type = "content", value = "C2" },
        { type = "structure", value = "S1" },
        { type = "metadata", value = "M" },
    }
    local edition = {
        { type = "content", value = "C3" },
        { type = "structure", value = "S3" },
        { type = "metadata", value = "M" },
    }
    local function ids(identifiers)
        local parts = {}
        for _, identifier in ipairs(identifiers) do
            table.insert(parts, identifier.type .. ":" .. identifier.value)
        end
        return table.concat(parts, ",")
    end

    local xpointer = "/body/DocFragment[20]/body/p[22]"

    describe("#compatibility", function()
        before_each(function()
            register("reader", "key")
        end)

        it("answers a lone identifier the way version 1 does, and says so", function()
            local response = update("reader", "key", "C1", nil, 0.32, xpointer, "my kpw")
            assert.are.same(200, response.status)
            assert.are.same("C1", response.body.document)
            assert.are.same("exact", response.body.match)

            response = get("reader", "key", "C1")
            assert.are.same(200, response.status)
            response.body.timestamp = nil
            assert.are.same({
                document = "C1",
                percentage = 0.32,
                progress = xpointer,
                device = "my kpw",
                match = "exact",
                progress_match = "exact",
            }, response.body)
        end)

        it("names the match by the type the request gave it", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            local response = get("reader", "key", "C1", ids(original))
            assert.are.same("content", response.body.match)
            assert.are.same("content", response.body.progress_match)
        end)

        it("answers an unknown document with an empty body", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            assert.are.same({}, get("reader", "key", "C9", "content:C9").body)
            assert.are.same({}, get("reader", "key", "C9").body)
        end)

        it("still authorizes before reading or writing", function()
            assert.are.same(401, get("reader", "wrong", "C1", ids(original)).status)
            assert.are.same(401, update("reader", "wrong", "C1", original, 0.32, xpointer, "d").status)
        end)
    end)

    describe("#aliases", function()
        before_each(function()
            register("reader", "key")
        end)

        it("finds a renamed and recompressed copy through an identifier it shares", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")

            local response = get("reader", "key", "C2", ids(repack))
            assert.are.same(200, response.status)
            assert.are.same("C1", response.body.document)
            assert.are.same("structure", response.body.match)
            assert.are.same(xpointer, response.body.progress)
        end)

        it("returns the canonical digest so the next read need not guess", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            local response = update("reader", "key", "C2", repack, 0.4, "/body/p[1]", "pb")
            assert.are.same("C1", response.body.document)
            assert.are.same("structure", response.body.match)
            assert.are.same("/body/p[1]", get("reader", "key", "C1", ids(original)).body.progress)
        end)

        it("keeps one account's aliases away from another", function()
            register("other", "other-key")
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            assert.are.same({}, get("other", "other-key", "C2", ids(repack)).body)
        end)

        it("forgets aliases when the account is deleted", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            local redis = redis_client()
            assert.are.same("structure:C1", redis:get("user:reader:alias:S1"))
            redis:quit()

            assert.are.same(200, delete_user("reader", "key").status)
            redis = redis_client()
            assert.are.same({}, redis:keys("user:reader:*"))
            redis:quit()
        end)

        it("never shadows a document that exists in its own right", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            update("reader", "key", "C2", { { type = "content", value = "C2" } }, 0.1, "/body/p[2]", "pb")
            -- C2 was known separately first, so it keeps its own record.
            update("reader", "key", "C2", repack, 0.5, "/body/p[3]", "pb")
            local response = get("reader", "key", "C2", "content:C2")
            assert.are.same("C2", response.body.document)
            assert.are.same("/body/p[3]", response.body.progress)
            assert.are.same(xpointer, get("reader", "key", "C1", "content:C1").body.progress)
        end)
    end)

    describe("#xpointers", function()
        before_each(function()
            register("reader", "key")
        end)

        it("separates how the document was found from who wrote the progress", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            update("reader", "key", "C3", edition, 0.5, "/body/DocFragment[3]/body/p[9]", "pb")

            local response = get("reader", "key", "C1", ids(original))
            assert.are.same(200, response.status)
            assert.are.same("C1", response.body.document)
            assert.are.same("content", response.body.match)
            assert.are.same("metadata", response.body.progress_match)
        end)

        it("vouches for a repackaged copy that renders the same", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            update("reader", "key", "C2", repack, 0.5, "/body/DocFragment[4]/body/p[1]", "pb")

            local response = get("reader", "key", "C1", ids(original))
            assert.are.same("content", response.body.match)
            assert.are.same("structure", response.body.progress_match)
        end)

        it("reports none when the reader shares nothing with the writer", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            local redis = redis_client()
            redis:hset("user:reader:document:C1", "identifiers", "content:ZZ,metadata:NN")
            redis:hset("user:reader:document:C1", "identifiers_for", xpointer)
            redis:quit()

            local response = get("reader", "key", "C1", ids(original))
            assert.are.same("content", response.body.match)
            assert.are.same("none", response.body.progress_match)
        end)

        it("answers in the reader's order of preference", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            -- The same three, weakest first.
            local response = get("reader", "key", "M", "metadata:M,structure:S1,content:C1")
            assert.are.same("metadata", response.body.match)
            assert.are.same("metadata", response.body.progress_match)
            response = get("reader", "key", "C1", ids(original))
            assert.are.same("content", response.body.match)
            assert.are.same("content", response.body.progress_match)
        end)
    end)

    describe("#legacy records", function()
        before_each(function()
            register("reader", "key")
        end)

        it("treats a version 1 record as written by the digest it is stored under", function()
            local redis = redis_client()
            redis:hmset("user:reader:document:C1",
                "percentage", "0.32", "progress", xpointer,
                "device", "my kpw", "timestamp", "1000")
            redis:quit()

            local response = get("reader", "key", "C1", ids(original))
            assert.are.same("content", response.body.match)
            assert.are.same("content", response.body.progress_match)
        end)

        it("stops trusting recorded identifiers once the progress is replaced", function()
            update("reader", "key", "C1", edition, 0.5, "/body/DocFragment[3]/body/p[9]", "pb")
            -- What a version 1 client does: the progress moves, the v2 fields
            -- beside it do not.
            local redis = redis_client()
            redis:hset("user:reader:document:C1", "progress", xpointer)
            redis:quit()

            local response = get("reader", "key", "C1", ids(original))
            assert.are.same("content", response.body.match)
            assert.are.same("content", response.body.progress_match)
        end)

        it("clears a stale identifier set when a later write names none", function()
            update("reader", "key", "C1", original, 0.32, xpointer, "my kpw")
            update("reader", "key", "C3", edition, 0.5, "/body/DocFragment[3]/body/p[9]", "pb")
            assert.are.same("metadata", get("reader", "key", "C1", ids(original)).body.progress_match)

            -- A client that names no identifiers must not leave the previous
            -- client's set attached to progress it did not write.
            update("reader", "key", "C1", nil, 0.4, "/body/p[7]", "pb")
            local redis = redis_client()
            assert.are.same("", redis:hget("user:reader:document:C1", "identifiers"))
            redis:quit()
            local response = get("reader", "key", "C1", ids(original))
            assert.are.same("content", response.body.match)
            assert.are.same("content", response.body.progress_match)
        end)
    end)

    describe("#validation", function()
        before_each(function()
            register("reader", "key")
        end)

        local function assert_invalid(response)
            assert.are.same(403, response.status)
            assert.are.same({ code = 2003, message = "Invalid request" }, response.body)
        end

        it("refuses an identifier list that does not begin with the document", function()
            assert_invalid(update("reader", "key", "C1", repack, 0.32, xpointer, "d"))
            assert_invalid(get("reader", "key", "C1", "metadata:M"))
        end)

        it("refuses a malformed or oversized list", function()
            assert_invalid(update("reader", "key", "C1", { "content:C1" }, 0.32, xpointer, "d"))
            assert_invalid(update("reader", "key", "C1",
                { { type = "content" } }, 0.32, xpointer, "d"))
            assert_invalid(update("reader", "key", "C1",
                { { type = "content", value = "C1" }, { type = "content", value = "C2" } },
                0.32, xpointer, "d"))
            assert_invalid(get("reader", "key", "C1", "content:C1,content:C2"))
            assert_invalid(get("reader", "key", "C1", "C1"))

            local many = { { type = "content", value = "C1" } }
            for index = 1, 8 do
                table.insert(many, { type = "t" .. index, value = "v" .. index })
            end
            assert_invalid(update("reader", "key", "C1", many, 0.32, xpointer, "d"))
        end)

        it("still requires a document and the progress fields", function()
            assert.are.same(403, update("reader", "key", nil, nil, 0.32, xpointer, "d").status)
            assert.are.same(403, update("reader", "key", "C1", original, nil, xpointer, "d").status)
        end)
    end)
    describe("#unservable document ids", function()
        local username, userkey = "user1", "passwd123"
        before_each(function()
            register(username, userkey)
        end)

        it("refuses a document the read route cannot serve, as version 1 does", function()
            local response = update(username, userkey, "has-a-hyphen",
                { { type = "content", value = "has-a-hyphen" } }, 0.5, "10", "kpw")
            assert.are.same(403, response.status)
            assert.are.same(2007, response.body.code)
        end)

        it("still accepts a digest", function()
            local doc = "0b229176d4e8db7f6d2b5a4952368d7a"
            local response = update(username, userkey, doc,
                { { type = "content", value = doc } }, 0.5, "10", "kpw")
            assert.are.same(200, response.status)
        end)
    end)

end)
