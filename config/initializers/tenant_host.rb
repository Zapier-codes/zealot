# frozen_string_literal: true

# Task 37b (host -> tenant resolution, Rack layer). Defined inline rather than in `lib/` because
# `config.middleware.use` runs during initialization, where referencing an autoloadable
# (reloadable) constant is not allowed. The class holds no logic -- everything lives in
# `Zealot::TenantResolver`, which is only referenced at request time, when autoloading is fine.
#
# Sets `env['zealot.tenant_host']` and `env['zealot.tenant']` (see TenantResolver). Nothing reads
# them yet: with no `Tenant` model every request resolves to the default tenant, so this is
# behaviour-neutral until 37b lands.
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
