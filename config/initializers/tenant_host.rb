# frozen_string_literal: true

# Task 37b (host -> tenant resolution, Rack layer). Defined inline rather than in `lib/` because
# `config.middleware.use` runs during initialization, where referencing an autoloadable
# (reloadable) constant is not allowed. The class holds no logic -- everything lives in
# `Zealot::TenantResolver`, which is only referenced at request time, when autoloading is fine.
#
# Sets `env['zealot.tenant_host']` and `env['zealot.tenant']` (see TenantResolver). Nothing reads
# them yet (37b-iii), so this changes no response.
#
# Task 37b-ii-t2: the resolver's registry is the DB-backed, cached `Zealot::TenantRegistry`.
# With no `tenants` rows -- or any error reading them, including the table not existing yet
# because migrations run at container start -- every request resolves to the default tenant.
class TenantHostMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    Zealot::TenantResolver.annotate!(env)
    @app.call(env)
  end
end

Rails.application.config.middleware.use TenantHostMiddleware

# `to_prepare` (not a bare assignment) because it runs after autoloading is available and again
# on every code reload, when `Zealot::TenantResolver` is re-defined with its default empty
# registry. The lambda defers the `TenantRegistry` lookup to request time.
Rails.application.config.to_prepare do
  Zealot::TenantResolver.registry = -> { Zealot::TenantRegistry.call }
end
