# frozen_string_literal: true

# Task 42b: many request specs define `let(:app) { create(:app) }` (the Zealot App model). In a request spec
# the integration session is built from `app`, which Rack expects to be the Rack application, so every request
# in those specs raised "undefined method 'call' for an instance of App" (159 failures in the first CI run,
# https://github.com/Zapier-codes/zealot/actions/runs/37525170638). Build the session from Rails.application
# directly so a spec may name its own record `app`.
module RequestSpecRackApp
  def integration_session
    @integration_session ||= create_session(::Rails.application)
  end

  def reset!
    @integration_session = create_session(::Rails.application)
  end
end

RSpec.configure do |config|
  config.include RequestSpecRackApp, type: :request
end
