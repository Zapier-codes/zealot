# frozen_string_literal: true

# Task 42c: swagger_helper declares a global `security: [{ token: [] }]` (an apiKey sent as the `token` query
# parameter). rswag reads that value with `example.token` for every operation that does not say `security []`,
# and no spec in spec/api defined one, so each of those requests raised "undefined method 'token'".
# A valid user token is the default; the shared :unauthorized_response examples override it with a bad one.
module SwaggerDefaultToken
  def token
    @swagger_default_token ||= FactoryBot.create(:user).token
  end
end

RSpec.configure do |config|
  config.include SwaggerDefaultToken, file_path: %r{spec/api/}
end
