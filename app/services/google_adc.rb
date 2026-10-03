# frozen_string_literal: true

# Task 36b: registering the packages Zealot signs with Google's Android Developer Console API, so
# the organisation's one verified developer account is the registrant of record for the signing
# key. Read `docs/android_developer_console_api.md` first: it holds the API's shape and what was
# and was not proved against the live service.
#
# This file is only the namespace, the error types and the two switches. Everything that talks to
# Google is in `GoogleAdc::Client`; everything that decides what to send is `GoogleAdc::Registrar`.
#
# The switches are environment variables, read at call time (not at boot), so changing one on
# Render needs no code change:
#
#   ADC_AUTO_REGISTER  "true" lets a newly signed release enqueue a registration. Anything else,
#                      or unset, is OFF. Off is the default on purpose: deploying this code must
#                      change nothing until the operator turns it on (decision 36-3).
#   ADC_DRY_RUN        "true" makes the Registrar do its reads and log the writes it would have
#                      made, sending none. Use it for the first real run.
#
# The credential variables (CLIENT_ID, CLIENT_SECRET, ADC_REFRESH_TOKEN) are read by the client.
module GoogleAdc
  class Error < StandardError; end

  # Worth retrying: network trouble, 429, 5xx.
  class TemporaryError < Error; end

  # Retrying cannot help: bad credential, refused request, missing configuration.
  class PermanentError < Error; end

  # A valid Android application id: at least two dot-separated segments, each starting with a
  # letter, then letters, digits or underscores. Used before a name is put into a URL.
  PACKAGE_NAME_FORMAT = /\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+\z/

  # `developerAccounts/<digits>`, and the resource names under it. Checked before a name is put into a URL.
  ACCOUNT_NAME_FORMAT = %r{\AdeveloperAccounts/\d+\z}
  PACKAGE_NAME_PART = '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+'
  PACKAGE_RESOURCE_FORMAT = %r{\AdeveloperAccounts/\d+/androidPackages/#{PACKAGE_NAME_PART}\z}
  KEY_RESOURCE_FORMAT = %r{\AdeveloperAccounts/\d+/androidPackages/#{PACKAGE_NAME_PART}/keys/[A-Za-z0-9_-]+\z}

  class << self
    def auto_register?
      flag('ADC_AUTO_REGISTER')
    end

    def dry_run?
      flag('ADC_DRY_RUN')
    end

    def valid_package_name?(name)
      name.is_a?(String) && name.length <= 255 && PACKAGE_NAME_FORMAT.match?(name)
    end

    private

    def flag(name)
      ENV[name].to_s.strip.casecmp?('true')
    end
  end
end
