require 'spec.spec_helper'


local function clear_db()
    local redis = require("redis")
    local client = redis.connect("127.0.0.1", 6379)
    client:select(2)
    client:flushdb()
end

describe("SyncsController", function()
    before_each(function()
        clear_db()
    end)

    after_each(function()
        clear_db()
    end)

    local function register(username, userkey)
        local response = hit({
            scheme = "https",
            method = "POST",
            path = "/users/create",
            body = { username = username, password = userkey },
        })

        return response
    end

    local function authorize(username, userkey)
        local response = hit({
            scheme = "https",
            method = "GET",
            path = "/users/auth",
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
        })

        return response
    end

    local function delete_user(username, userkey)
        local response = hit({
            scheme = "https",
            method = "DELETE",
            path = "/users/me",
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
        })

        return response
    end

    local function update_password(username, userkey, password)
        local response = hit({
            scheme = "https",
            method = "PUT",
            path = "/users/password",
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
            body = { password = password },
        })

        return response
    end

    local function get(username, userkey, document)
        local response = hit({
            scheme = "https",
            method = "GET",
            path = "/syncs/progress/" .. document,
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
        })

        return response
    end

    local function update(username, userkey, document, percentage, progress, device, device_id)
        local response = hit({
            scheme = "https",
            method = "PUT",
            path = "/syncs/progress",
            headers = {
                ["x-auth-user"] = username,
                ["x-auth-key"] = userkey,
            },
            body = {
                document = document,
                progress = progress,
                percentage = percentage,
                device = device,
                device_id = device_id,
            }
        })

        return response
    end

    describe("#create", function()
        it("adds new user", function()
            local response = register("new-user", "passwd123")
            assert.are.same(201, response.status)
            assert.are.same({ username = "new-user" }, response.body)
        end)
        it("cannot add duplicated user", function()
            local response = register("new-user", "passwd123")
            assert.are.same(201, response.status)
            assert.are.same({ username = "new-user" }, response.body)
            response = register("new-user", "passwd123")
            assert.are.same(402, response.status)
            assert.are.same({
                code = 2002,
                message = "Username is already registered."
            }, response.body)
        end)
    end)

    describe("#auth", function()
        it("should authorize", function()
            local username, userkey = "user1", "passwd123"
            local response = register(username, userkey)
            response = authorize(username, "")
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
            response = authorize(username, "wrong_password")
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
            response = authorize(username, userkey)
            assert.are.same(200, response.status)
            assert.are.same("OK", response.body.authorized)
        end)
    end)

    describe("#delete", function()
        it("requires valid credentials", function()
            local username, userkey = "user1", "passwd123"
            register(username, userkey)

            local response = delete_user(username, "wrong_password")
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
            assert.are.same(200, authorize(username, userkey).status)
        end)

        it("deletes the user and all progress", function()
            local username, userkey = "user1", "passwd123"
            local doc1, doc2 = "document1", "document2"
            register(username, userkey)
            update(username, userkey, doc1, 0.32, "56", "my kpw")
            update(username, userkey, doc2, 0.64, "112", "my kpw")

            local response = delete_user(username, userkey)
            assert.are.same(200, response.status)
            assert.are.same({ deleted = true }, response.body)
            assert.are.same(401, authorize(username, userkey).status)

            -- Re-registering the username should start with no old progress.
            assert.are.same(201, register(username, "new-password").status)
            assert.are.same({}, get(username, "new-password", doc1).body)
            assert.are.same({}, get(username, "new-password", doc2).body)
        end)

        it("does not treat glob characters in usernames as wildcards", function()
            register("user*one", "password-one")
            register("userXone", "password-two")
            update("user*one", "password-one", "document1", 0.32, "56", "device one")
            update("userXone", "password-two", "document2", 0.64, "112", "device two")

            assert.are.same(200, delete_user("user*one", "password-one").status)
            assert.are.same(200, authorize("userXone", "password-two").status)
            assert.are.same("document2",
                get("userXone", "password-two", "document2").body.document)
        end)
    end)

    describe("#deletion retries", function()
        local function client()
            local connection = require("redis").connect("127.0.0.1", 6379)
            connection:select(2)
            return connection
        end

        it("distinguishes repeated and absent accounts without retaining records", function()
            register("reader", "key")
            update("reader", "key", "doc", 0.32, "56", "device")
            assert.are.same(200, delete_user("reader", "key").status)
            local retry = delete_user("reader", "key")
            assert.are.same(404, retry.status)
            assert.are.same({ code = 2006, message = "Account not found." }, retry.body)
            assert.are.same(404, delete_user("missing", "key").status)
            local redis = client()
            assert.are.same({}, redis:keys("*"))
            redis:quit()
        end)

        it("allows username reuse and rejects the old key after re-registration", function()
            register("reader", "old-key")
            delete_user("reader", "old-key")
            assert.are.same(401, update("reader", "old-key", "doc", 0.3, "56", "device").status)
            assert.are.same(201, register("reader", "new-key").status)
            assert.are.same(401, delete_user("reader", "old-key").status)
            assert.are.same(200, authorize("reader", "new-key").status)
            assert.are.same({}, get("reader", "new-key", "doc").body)
            assert.are.same(200, delete_user("reader", "new-key").status)
            assert.are.same(201, register("reader", "new-key").status)
        end)

        it("requires well-formed authentication even when the account is absent", function()
            for _, response in ipairs({ delete_user(nil, "key"), delete_user("", "key"),
                delete_user("reader:other", "key"), delete_user("reader", nil), delete_user("reader", "") }) do
                assert.are.same(401, response.status)
            end
        end)

        it("cleans orphaned progress for an absent account without touching another user", function()
            register("other", "other-key")
            local redis = client()
            redis:hmset("user:missing:document:doc", "progress", "56")
            redis:quit()
            assert.are.same(404, delete_user("missing", "key").status)
            redis = client()
            assert.are.same({}, redis:keys("user:missing:*"))
            redis:quit()
            assert.are.same(200, authorize("other", "other-key").status)
        end)

        it("fails closed on Redis type errors", function()
            local redis = client()
            redis:lpush("user:broken:key", "wrong-type")
            redis:quit()
            assert.are.same(502, delete_user("broken", "key").status)
            redis = client()
            assert.are.same({ "wrong-type" }, redis:lrange("user:broken:key", 0, -1))
            redis:quit()
        end)
    end)

    describe("#password", function()
        local function redis_client()
            local redis = require("redis")
            local client = redis.connect("127.0.0.1", 6379)
            client:select(2)
            return client
        end

        local function assert_unauthorized(response)
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
        end

        it("replaces the authentication key without changing the username", function()
            assert.are.same(201, register("reader", "old-key").status)
            local response = update_password("reader", "old-key", "new-key")
            assert.are.same(200, response.status)
            assert.are.same({ updated = true }, response.body)
            assert_unauthorized(authorize("reader", "old-key"))
            assert.are.same(200, authorize("reader", "new-key").status)
        end)

        it("rejects missing, empty, invalid and incorrect authentication", function()
            register("reader", "old-key")
            assert_unauthorized(update_password(nil, "old-key", "new-key"))
            assert_unauthorized(update_password("", "old-key", "new-key"))
            assert_unauthorized(update_password("reader:other", "old-key", "new-key"))
            assert_unauthorized(update_password("reader", nil, "new-key"))
            assert_unauthorized(update_password("reader", "", "new-key"))
            assert_unauthorized(update_password("reader", "wrong-key", "new-key"))
            assert.are.same(200, authorize("reader", "old-key").status)
            assert_unauthorized(authorize("reader", "new-key"))
        end)

        it("never creates a nonexistent account", function()
            assert_unauthorized(update_password("missing", "old-key", "new-key"))
            local client = redis_client()
            assert.is_nil(client:get("user:missing:key"))
            client:quit()
        end)

        it("rejects missing and invalid replacement keys without changing the account", function()
            register("reader", "old-key")
            local responses = {
                update_password("reader", "old-key", nil),
                update_password("reader", "old-key", ""),
                update_password("reader", "old-key", 123),
                update_password("reader", "old-key", false),
                update_password("reader", "old-key", {}),
            }
            for _, response in ipairs(responses) do
                assert.are.same(403, response.status)
                assert.are.same({ code = 2003, message = "Invalid request" }, response.body)
            end
            assert.are.same(200, authorize("reader", "old-key").status)
        end)

        it("rejects stale retries and allows confirmation using the replacement key", function()
            register("reader", "old-key")
            assert.are.same(200, update_password("reader", "old-key", "new-key").status)
            assert_unauthorized(update_password("reader", "old-key", "new-key"))
            assert_unauthorized(update_password("reader", "old-key", "different-key"))
            assert.are.same(200, authorize("reader", "new-key").status)
            assert_unauthorized(authorize("reader", "different-key"))
            assert.are.same(200, update_password("reader", "new-key", "next-key").status)
            assert_unauthorized(authorize("reader", "new-key"))
            assert.are.same(200, authorize("reader", "next-key").status)
        end)

        it("allows an authenticated request to retain its current key", function()
            register("reader", "same-key")
            assert.are.same(200, update_password("reader", "same-key", "same-key").status)
            assert.are.same(200, authorize("reader", "same-key").status)
        end)

        it("preserves every progress field and other accounts", function()
            register("reader", "old-key")
            register("reader-other", "other-key")
            local documents = { "document1", "document2" }
            local saved = {}
            for _, document in ipairs(documents) do
                assert.are.same(200, update("reader", "old-key", document,
                    0.32, "56", "reader device", "device1").status)
                saved[document] = get("reader", "old-key", document).body
            end
            local client = redis_client()
            client:set("user:reader:metadata", "unchanged")
            client:quit()
            assert.are.same(200, update_password("reader", "old-key", "new-key").status)
            for _, document in ipairs(documents) do
                local response = get("reader", "new-key", document)
                assert.are.same(200, response.status)
                assert.are.same(saved[document], response.body)
                assert_unauthorized(get("reader", "old-key", document))
            end
            assert_unauthorized(update("reader", "old-key", documents[1],
                0.99, "99", "old device"))
            assert.are.same(200, update("reader", "new-key", documents[1],
                0.4, "60", "new device").status)
            assert.are.same("60", get("reader", "new-key", documents[1]).body.progress)
            assert.are.same(200, authorize("reader-other", "other-key").status)
            client = redis_client()
            assert.are.same("unchanged", client:get("user:reader:metadata"))
            client:quit()
        end)

        it("does not use a body username to target a different account", function()
            register("reader", "old-key")
            register("other", "other-key")
            local response = hit({
                scheme = "https",
                method = "PUT",
                path = "/users/password",
                headers = {
                    ["x-auth-user"] = "reader",
                    ["x-auth-key"] = "old-key",
                },
                body = { username = "other", password = "new-key" },
            })
            assert.are.same(200, response.status)
            assert.are.same(200, authorize("reader", "new-key").status)
            assert.are.same(200, authorize("other", "other-key").status)
        end)

        it("returns a generic server error on Redis failure without replacing the key", function()
            local client = redis_client()
            client:lpush("user:reader:key", "wrong-type")
            client:quit()
            local response = update_password("reader", "old-key", "new-key")
            assert.are.same(502, response.status)
            assert.are.same({ code = 2000, message = "Unknown server error." }, response.body)
            client = redis_client()
            assert.are.same({ "wrong-type" }, client:lrange("user:reader:key", 0, -1))
            client:quit()
        end)
    end)

    describe("#sync", function()
        local username, userkey, doc = "user1", "passwd123", "89isjkdaj9j"
        before_each(function()
            register(username, userkey)
        end)
        it("should authorize itself before getting progress", function()
            local response = get(username, userkey.."wrong_pass", doc)
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
        end)
        it("should authorize itself before updating progress", function()
            local response = update(username, userkey.."wrong_pass",
                doc, 0.32, "56", "my kpw")
            assert.are.same(401, response.status)
            assert.are.same({code = 2001, message = "Unauthorized"}, response.body)
        end)
        it("should update document progress", function()
            local response = update(username, userkey, doc, 0.32, "56", "my kpw")
            assert.are.same(200, response.status)
            assert.are.same(doc, response.body.document)
            assert.truthy(response.body.timestamp)
        end)
        it("cannot get progress of non-existent document", function()
            update(username, userkey, doc, 0.32, "56", "my kpw")
            local response = get(username, userkey, doc .. "non_existent")
            assert.are.same(200, response.status)
            assert.are.same({}, response.body)
        end)
        it("should get document progress", function()
            update(username, userkey, doc, 0.32, "56", "my kpw")
            local response = get(username, userkey, doc)
            assert.are.same(200, response.status)
            assert.truthy(response.body.timestamp)
            -- Clear timestamp, it varies.
            response.body.timestamp = nil
            assert.are.same({
                document = doc,
                percentage = 0.32,
                progress = "56",
                device = "my kpw"
            }, response.body)
        end)
        it("should get the latest document progress", function()
            update(username, userkey, doc, 0.32, "56", "my kpw")
            -- 36 is writting later, so we should get it.
            update(username, userkey, doc, 0.22, "36", "my pb")
            local response = get(username, userkey, doc)
            assert.are.same(200, response.status)
            assert.truthy(response.body.timestamp)
            -- Clear timestamp, it varies.
            response.body.timestamp = nil
            assert.are.same({
                document = doc,
                percentage = 0.22,
                progress = "36",
                device = "my pb"
            }, response.body)
        end)
    end)
end)
