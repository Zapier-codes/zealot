# frozen_string_literal: true

# Task 44a: the one rule for "the slug" of an app. The operator's decision (2026-10-07) is that the slug and the
# name are the same thing, so a slug is the name cleaned: accents transliterated, lowercase, every run of
# characters outside `[a-z0-9]` becomes one hyphen, hyphens trimmed from both ends, at most MAX characters.
#
#   NameSlug.base('Vyxel Apps!')                       # => "vyxel-apps"
#   NameSlug.base('2048')                              # => "app-2048"  (all digits: friendly_id would read it as an id)
#   NameSlug.base('Admin')                             # => "admin-app" (a route word: the slug is a top-level URL path)
#   NameSlug.base('应用')                              # => ""          (nothing usable: the caller picks a fallback)
#   NameSlug.unique('appstore') { |s| taken?(s) }      # => "appstore", else "appstore-2", "appstore-3", ...
#
# There is no `apps.slug` column on purpose (see Task 44, D44-1): the slug is computed from the name when it is
# needed, and every stored object name is recorded as a key at upload, so renaming an app never orphans a file.
# `Channel` stores its slug (a unique column used in URLs) and uses `unique` to pick it.
#
# Pure: no database, no storage. `unique` only asks the block whether a candidate is taken.
class NameSlug
  MAX = 40

  # How many numbered candidates `unique` tries before it falls back to a random suffix.
  LIMIT = 1000

  # What a well-formed slug looks like (also what `Channel` checks a given slug against).
  FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  # A channel slug is a top-level path (`/<slug>/versions`, `scope path: ':channel'` in config/routes.rb), so a
  # name that cleans to one of these gets `-app` after it. Not read from the router on purpose: a fixed list
  # is predictable, and these are the words this app serves at its top level or reserves for itself.
  RESERVED = %w[
    admin api apps assets channels download downloads edit health install new overview rails releases
    schemes sessions sign-in sign-up up users versions
  ].freeze

  # @param name [#to_s, nil]
  # @return [String] a well-formed slug, or '' when the name has no usable character
  def self.base(name)
    slug = I18n.transliterate(name.to_s, replacement: '-').downcase.gsub(/[^a-z0-9]+/, '-')
    slug = slug.gsub(/\A-+|-+\z/, '')
    slug = slug[0, MAX].to_s.gsub(/-+\z/, '')
    return '' if slug.empty?

    slug = "app-#{slug}" if slug.match?(/\A\d+\z/)
    slug = "#{slug}-app" if RESERVED.include?(slug)
    slug
  end

  # The first of `base`, `base-2`, `base-3`, ... for which the block answers false. After `LIMIT` tries a random
  # suffix is used, so a pathological table can not loop for ever.
  #
  # @param base [String] a non-empty slug (from `base`)
  # @yieldparam candidate [String]
  # @yieldreturn [Boolean] true when the candidate is already taken
  # @return [String]
  def self.unique(base)
    return base unless yield(base)

    (2..LIMIT).each do |number|
      candidate = "#{base}-#{number}"
      return candidate unless yield(candidate)
    end
    "#{base}-#{SecureRandom.hex(3)}"
  end
end
