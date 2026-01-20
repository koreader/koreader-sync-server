local routes = require 'gin.core.routes'

-- define version
local v1 = routes.version(1)

-- define routes
if os.getenv("ENABLE_USER_REGISTRATION") or os.getenv("ENABLE_USER_REGISTRATION") == "true" then
    v1:POST("/users/create", { controller = "syncs", action = "create_user" })
else
    v1:POST("/users/create", { controller = "syncs", action = "create_user_disabled" })
end
v1:GET("/users/auth", { controller = "syncs", action = "auth_user" })
v1:PUT("/syncs/progress", { controller = "syncs", action = "update_progress" })
v1:GET("/syncs/progress/:document", { controller = "syncs", action = "get_progress" })
v1:GET("/healthcheck", { controller = "syncs", action = "healthcheck" })
return routes
