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

    local function update(username, userkey, document, percentage, progress, device)
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
            assert.are.same("OK", response.body)
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
            assert.are.same({
                percentage = 0.32,
                progress = "56",
                device = "my kpw"
            }, response.body)
        end)
        it("cannot get non-existent document progres", function()
            update(username, userkey, doc, 0.32, "56", "my kpw")
            local response = get(username, userkey, doc .. "non_existent")
            assert.are.same(200, response.status)
            assert.are.same({}, response.body)
        end)
        it("should get document progress", function()
            update(username, userkey, doc, 0.32, "56", "my kpw")
            local response = get(username, userkey, doc)
            assert.are.same(200, response.status)
            assert.are.same({
                percentage = "0.32",
                progress = "56",
                device = "my kpw"
            }, response.body)
        end)
        it("should get the furthest document progress", function()
            update(username, userkey, doc, 0.32, "56", "my kpw")
            update(username, userkey, doc, 0.22, "36", "my pb")
            local response = get(username, userkey, doc)
            assert.are.same(200, response.status)
            assert.are.same({
                percentage = "0.32",
                progress = "56",
                device = "my kpw"
            }, response.body)
        end)
    end)
end)
