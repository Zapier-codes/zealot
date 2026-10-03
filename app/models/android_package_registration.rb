# frozen_string_literal: true

# Task 36b-3: the record of one Android package name's registration with Google (see the migration
# and `docs/android_developer_console_api.md`). Written by `GoogleAdc::Registrar`, read by the app
# page badge. Never holds a secret.
class AndroidPackageRegistration < ApplicationRecord
  # pending      we know the name but Google has not confirmed the package and key yet
  # registered   Google lists the package and our key as registered
  # needs_review Google needs more than we may do by ourselves (an existing package name needs
  #              proof of key ownership, a justification, or the key is blocked); a person decides
  # failed       Google refused and retrying cannot help; `last_error` says why
  STATES = %w[pending registered needs_review failed].freeze

  belongs_to :app, optional: true

  validates :package_name, presence: true, uniqueness: true,
                           format: { with: GoogleAdc::PACKAGE_NAME_FORMAT }
  validates :state, inclusion: { in: STATES }

  STATES.each do |name|
    define_method(:"#{name}?") { state == name }
  end

  # Nothing more to do automatically: re-running the Registrar would only repeat the same reads.
  def settled?
    registered? || needs_review?
  end
end
