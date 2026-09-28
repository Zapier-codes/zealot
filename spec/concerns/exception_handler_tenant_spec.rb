# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-2b: on a tenant's host a denial about another tenant's saved record answers 404,
# every other denial stays 403. The handler is exercised on an anonymous controller with the
# response methods stubbed, so no route, session or view is needed. Needs Postgres for the rows.
# Written by imitating tenant_scoped_spec.rb; NOT run in the sandbox that wrote it (no Rails boot or
# database there).
RSpec.describe ExceptionHandler do
  let(:acme) { create(:tenant, tenant_id: 'acme') }
  let(:globex) { create(:tenant, tenant_id: 'globex') }
  let(:key) { Zealot::TenantResolver::ENV_TENANT_KEY }

  let(:aware_class) do
    Class.new(ActionController::Base) do
      include ExceptionHandler
      include TenantScoped
    end
  end
  let(:unaware_class) do
    Class.new(ActionController::Base) do
      include ExceptionHandler
    end
  end

  def controller_on(klass, tenant_ref)
    klass.new.tap do |controller|
      request = instance_double(ActionDispatch::Request, env: { key => tenant_ref })
      allow(controller).to receive(:request).and_return(request)
      allow(controller).to receive(:respond_with_error)
    end
  end

  def deny(record, query = :show?)
    Pundit::NotAuthorizedError.new(query: query, record: record, policy: AppPolicy.new(nil, record))
  end

  let(:default_ref) { Zealot::TenantResolver::DEFAULT_TENANT }
  let(:acme_ref) { Zealot::TenantResolver::Ref.new('acme', []) }

  let!(:default_app) { create(:app) }
  let!(:acme_app) { create(:app, tenant: acme) }
  let!(:globex_app) { create(:app, tenant: globex) }

  describe 'on the default host' do
    it 'keeps every denial a 403, cross-tenant records included' do
      controller = controller_on(aware_class, default_ref)
      error = deny(globex_app)

      controller.send(:forbidden, error)

      expect(controller).to have_received(:respond_with_error).with(403, error)
    end
  end

  describe 'on a tenant host' do
    let(:controller) { controller_on(aware_class, acme_ref) }

    it 'answers 404 for a record of another tenant, in the message a plain find would give' do
      controller.send(:forbidden, deny(globex_app))

      expect(controller).to have_received(:respond_with_error).with(
        404, an_instance_of(ActiveRecord::RecordNotFound).and(
          have_attributes(message: "Couldn't find App with 'id'=#{globex_app.id}")
        )
      )
    end

    it 'answers 404 for a record of the default catalog' do
      controller.send(:forbidden, deny(default_app))

      expect(controller).to have_received(:respond_with_error).with(404, an_instance_of(ActiveRecord::RecordNotFound))
    end

    it 'keeps a denial about the tenant\'s own record a 403' do
      error = deny(acme_app, :update?)

      controller.send(:forbidden, error)

      expect(controller).to have_received(:respond_with_error).with(403, error)
    end

    it 'keeps a class-level denial (index?) a 403' do
      error = deny(App, :index?)

      controller.send(:forbidden, error)

      expect(controller).to have_received(:respond_with_error).with(403, error)
    end

    it 'keeps a denial about a new, unsaved record (create?) a 403' do
      error = deny(App.new, :create?)

      controller.send(:forbidden, error)

      expect(controller).to have_received(:respond_with_error).with(403, error)
    end

    it 'keeps a denial about a Tenant row a 403 (its tenant_id is a slug, not a foreign key)' do
      error = deny(globex, :edit?)

      controller.send(:forbidden, error)

      expect(controller).to have_received(:respond_with_error).with(403, error)
    end

    it 'keeps a denial with no record a 403' do
      error = deny(nil, :show?)

      controller.send(:forbidden, error)

      expect(controller).to have_received(:respond_with_error).with(403, error)
    end
  end

  describe 'on a controller that does not know the request tenant (Api::BaseController today)' do
    it 'keeps the denial a 403' do
      controller = controller_on(unaware_class, acme_ref)
      error = deny(globex_app)

      controller.send(:forbidden, error)

      expect(controller).to have_received(:respond_with_error).with(403, error)
    end
  end
end
