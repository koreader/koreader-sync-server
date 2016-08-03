-------------------------------------------------------------------------------------------------------------------
-- Define all of your application errors in here. They should have the format:
--
-- local Errors = {
--     [1000] = { status = 400, message = "My Application error.", headers = { ["X-Header"] = "header" } },
-- }
--
-- where:
--     '1000'                is the error number that can be raised from controllers with `self:raise_error(1000)
--     'status'  (required)  is the http status code
--     'message' (required)  is the error description
--     'headers' (optional)  are the headers to be returned in the response
-------------------------------------------------------------------------------------------------------------------

local Errors = {
    [1000] = { status = 503, message = "Cannot connect to redis server.", },
    [2000] = { status = 503, message = "Unknown server error.", },
    [2001] = { status = 401, message = "Unauthorized", },
    [2002] = { status = 401, message = "Username is already registered.", },
    [2003] = { status = 403, message = "Invalid request", },
    [2004] = { status = 403, message = "Field 'document' not provided.", },
}

return Errors
