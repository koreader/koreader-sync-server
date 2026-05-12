local routes = require 'gin.core.routes'

-- define version
local v1 = routes.version(1)

-- define routes
v1:POST("/users/create", { controller = "syncs", action = "create_user" })
v1:GET("/users/auth", { controller = "syncs", action = "auth_user" })
v1:PUT("/syncs/progress", { controller = "syncs", action = "update_progress" })
v1:GET("/syncs/progress/:document", { controller = "syncs", action = "get_progress" })
v1:GET("/healthcheck", { controller = "syncs", action = "healthcheck" })
v1:GET("/admin", { controller = "admin", action = "dashboard" })
v1:POST("/admin", { controller = "admin", action = "login" })
v1:GET("/admin/logout", { controller = "admin", action = "logout" })
v1:GET("/admin/logs", { controller = "admin", action = "logs" })
v1:POST("/admin/users/delete", { controller = "admin", action = "delete_user" })
v1:POST("/admin/users/reset", { controller = "admin", action = "reset_password" })
v1:GET("/admin/settings", { controller = "admin", action = "settings" })
v1:POST("/admin/settings", { controller = "admin", action = "save_settings" })
return routes
