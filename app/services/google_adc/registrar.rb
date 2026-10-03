# frozen_string_literal: true

# Task 36b-5: registers ONE Android package name, and the organisation's signing key for it, under
# the organisation's verified Google developer account. The decisions it applies are in
# handover.md, "Task 36b" (36-1 to 36-7), and the API it uses is in
# docs/android_developer_console_api.md.
#
#   GoogleAdc::Registrar.call(package_name: 'com.example.app', app: app)
#
# What it will do by itself:
#   * a package name Google does not know (policy USE_ANY_KEY): create the package and add the
#     organisation's key. No ownership proof is needed for that case.
#   * a package that already has our key registered: change nothing (it is idempotent).
#
# What it will NOT do by itself (decision 36-2): anything for a package name Google already knows
# (policy SELECT_KEY_FROM_LIST), which needs proof of key ownership and may need a written
# justification, or for a package that already has keys we did not register. It records
# `needs_review` with Google's words and stops. Those two steps are separate, person-started work
# (36b-8, 36b-9, not built).
#
# `ADC_DRY_RUN=true` does the reads, logs the writes it would have made and sends none. A dry run
# saves nothing in the database.
module GoogleAdc
  class Registrar
    Result = Struct.new(:outcome, :registration, :planned, keyword_init: true)

    REGISTERED_KEY_STATES = %w[REGISTERED REGISTERED_ACTIVE].freeze
    BLOCKED_STATES = %w[BLOCKED].freeze

    def self.call(**kwargs)
      new(**kwargs).call
    end

    # `fingerprint` and `client` exist for specs and for a console run; the defaults are the
    # organisation's key and a client built from the environment.
    def initialize(package_name:, app: nil, client: nil, fingerprint: nil, force: false)
      @package_name = package_name.to_s
      @app = app
      @client = client
      @fingerprint = fingerprint
      @force = force
    end

    def call
      return result(:invalid_package_name) unless GoogleAdc.valid_package_name?(@package_name)
      return result(:not_configured) unless client.configured?

      fingerprint = @fingerprint || organisation_fingerprint
      return result(:no_signing_key) if fingerprint.blank?

      # A dry run reads and logs only: it must not even create the row.
      return dry_run(fingerprint) if GoogleAdc.dry_run?

      registration = find_or_create_registration
      return result(:already_settled, registration) if settled_for?(registration, fingerprint) && !@force

      register(registration, fingerprint)
    rescue TemporaryError => e
      note_error(registration, e)
      raise
    rescue PermanentError => e
      note_failure(registration, e)
      result(:failed, registration)
    end

    private

    def client
      @client ||= Client.new
    end

    def organisation_fingerprint
      AndroidSigningKey.current&.certificate_sha256
    end

    def find_or_create_registration
      AndroidPackageRegistration.create_or_find_by!(package_name: @package_name) do |row|
        row.app = @app
        row.tenant_id = @app&.tenant_id
      end
    end

    # A package we already settled for the SAME key needs no call to Google. A different key means the
    # organisation's key was rotated; that is a person's decision (see #register).
    def settled_for?(registration, fingerprint)
      registration.settled? && same_fingerprint?(registration.key_fingerprint_sha256, fingerprint)
    end

    def register(registration, fingerprint)
      account = client.verified_account_name
      resource = "#{account}/androidPackages/#{@package_name}"

      package = client.get_package(resource) || client.create_package(account, @package_name)
      policy = client.get_policy(resource)
      strategy = policy['keySelectionStrategy']
      keys = client.list_keys(resource)
      existing = keys.find { |key| same_fingerprint?(key['certificateFingerprintSha256'], fingerprint) }

      attrs = { developer_account: account, google_package_state: package['state'], policy_strategy: strategy,
                key_fingerprint_sha256: fingerprint, last_error: nil, last_checked_at: Time.current,
                app_id: registration.app_id || @app&.id }

      if existing
        finish(registration, attrs, existing)
      elsif strategy == 'USE_ANY_KEY' && keys.empty?
        finish(registration, attrs, client.create_key(resource, fingerprint))
      else
        reason = if strategy == 'USE_ANY_KEY'
                   'the package already has keys that Zealot did not register; ' \
                   'a person decides whether to add the organisation key'
                 else
                   "Google already knows this package name (policy #{strategy.inspect}); " \
                   'registering needs proof of key ownership, which is not automated'
                 end
        registration.update!(attrs.merge(state: 'needs_review', last_error: reason))
        result(:needs_review, registration)
      end
    end

    def finish(registration, attrs, key)
      state = state_for(key['state'], attrs[:google_package_state])
      registration.update!(attrs.merge(state: state, key_state: key['state']))
      result(state.to_sym, registration)
    end

    def state_for(key_state, package_state)
      return 'needs_review' if BLOCKED_STATES.include?(key_state) || BLOCKED_STATES.include?(package_state)
      return 'registered' if REGISTERED_KEY_STATES.include?(key_state)

      'pending'
    end

    # Reads only. Says what a real run would send, in the log and in the result.
    def dry_run(fingerprint)
      planned = []
      account = client.verified_account_name
      resource = "#{account}/androidPackages/#{@package_name}"
      package = client.get_package(resource)

      if package.nil?
        planned << "create package #{@package_name}"
        planned << "read its registration policy; if USE_ANY_KEY, add key #{fingerprint[0, 8]}..."
      else
        policy = client.get_policy(resource)
        keys = client.list_keys(resource)
        if keys.any? { |key| same_fingerprint?(key['certificateFingerprintSha256'], fingerprint) }
          planned << 'nothing: the organisation key is already on the package'
        elsif policy['keySelectionStrategy'] == 'USE_ANY_KEY' && keys.empty?
          planned << "add key #{fingerprint[0, 8]}..."
        else
          planned << "stop: needs review (policy #{policy['keySelectionStrategy'].inspect}, #{keys.size} existing keys)"
        end
      end

      Rails.logger.info("[GoogleAdc::Registrar] dry run for #{@package_name}: #{planned.join('; ')}")
      Result.new(outcome: :dry_run, registration: nil, planned: planned)
    end

    def same_fingerprint?(first, second)
      first.to_s.delete(':').casecmp?(second.to_s.delete(':'))
    end

    def note_error(registration, error)
      registration&.update_columns(last_error: error.message.truncate(1000), last_checked_at: Time.current)
    end

    def note_failure(registration, error)
      registration&.update_columns(state: 'failed', last_error: error.message.truncate(1000),
                                   last_checked_at: Time.current)
    end

    def result(outcome, registration = nil)
      Result.new(outcome: outcome, registration: registration, planned: [])
    end
  end
end
