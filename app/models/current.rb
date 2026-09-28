# frozen_string_literal: true

# Task 37b-iii-s7c-2: per-request context that policies can read without every `authorize` call
# changing shape (Pundit hands a policy only `user` and `record`). `TenantScoped` sets `tenant` at
# the start of each request; Rails resets it after every request and job.
#
#   * `tenant`: the `Tenant` row of the request's host, or `nil` on the default host.
#
# `nil` also means "nothing set it": a job, a console session, or a controller that does not include
# `TenantScoped` (today `Api::BaseController`, until s7c-5). Those read as the default host, which is
# exactly how they behaved before this slice.
class Current < ActiveSupport::CurrentAttributes
  attribute :tenant
end
