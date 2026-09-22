local routes = require 'gin.core.routes'

-- define versions
local v1 = routes.version(1)
-- Same endpoints as version 1; the progress ones also take an identifier list
-- and report how the document matched.
local v2 = routes.version(2)

-- define routes
local enable_user_registration = os.getenv("ENABLE_USER_REGISTRATION")
if enable_user_registration == "true" or enable_user_registration == "1" then
    v1:POST("/users/create", { controller = "syncs", action = "create_user" })
    v2:POST("/users/create", { controller = "syncs", action = "create_user" })
else
    v1:POST("/users/create", { controller = "syncs", action = "create_user_disabled" })
    v2:POST("/users/create", { controller = "syncs", action = "create_user_disabled" })
end
v1:GET("/users/auth", { controller = "syncs", action = "auth_user" })
v1:DELETE("/users/me", { controller = "syncs", action = "delete_user" })
v1:PUT("/users/password", { controller = "syncs", action = "update_password" })
v1:PUT("/syncs/progress", { controller = "syncs", action = "update_progress" })
v1:GET("/syncs/progress/:document", { controller = "syncs", action = "get_progress" })
v1:GET("/healthcheck", { controller = "syncs", action = "healthcheck" })

v2:GET("/users/auth", { controller = "syncs", action = "auth_user" })
v2:DELETE("/users/me", { controller = "syncs", action = "delete_user" })
v2:PUT("/users/password", { controller = "syncs", action = "update_password" })
v2:PUT("/syncs/progress", { controller = "syncs", action = "update_progress" })
v2:GET("/syncs/progress/:document", { controller = "syncs", action = "get_progress" })
v2:GET("/healthcheck", { controller = "syncs", action = "healthcheck" })
return routes
