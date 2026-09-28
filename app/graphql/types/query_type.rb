# frozen_string_literal: true

module Types
  class QueryType < Types::BaseObject
    # Add `node(id: ID!) and `nodes(ids: [ID!]!)`
    include GraphQL::Types::Relay::HasNodeField
    include GraphQL::Types::Relay::HasNodesField

    # Add root-level fields here.
    # They will be entry points for queries on your schema.
    description 'The query root of this schema'

    # First describe the field signature:
    field :user, Types::UserType, null: true do
      description 'Find a user by ID'
      argument :id, ID, required: true
    end

    field :app, Types::AppType, null: true do
      description 'Find a app by ID'
      argument :id, ID, required: true
    end

    field :echo, String, null: false do
      description 'Testing endpoint to validate the API with'
      argument :message, String, required: false
    end

    # Then provide an implementation:
    def user(id:)
      user = User.find(id)
      authorize!(:show, user)
      user
    end

    def app(id:)
      # Task 37b-iii-s7c-6: find through the policy scope, so on a tenant's host another tenant's id
      # is "not found" like a missing one (rule 2), not "not authorized". Default host: `App.all`.
      app = Pundit.policy_scope!(context[:current_user], App).find(id)
      authorize!(:show, app)
      app
    end

    def echo(message: nil)
      current_user = context[:current_user]
      message ||= 'hello world'
      "#{current_user.username}说: #{message}"
    end
  end
end
