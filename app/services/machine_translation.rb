# frozen_string_literal: true

# Z-P21 (Play Console parity): produce the machine translations of an app's listing free text, one locale
# at a time, and store them on `App#listing_translations`. This is the "assemble, do not write" half: the
# translation itself is MachineTranslatorClient (LibreTranslate / Argos), this class only decides what to
# send, what to keep, and when a stored translation is stale.
#
# A translation is stored as machine-made (`machine: true`, `reviewed: false`) and carries the digest of the
# source text it was made from. A later edit to the app's description changes that digest, so the stored
# translation reads as stale and the Console shows it as needing a re-translate / re-review rather than
# publishing text for wording that no longer exists. Only reviewed, non-stale translations reach the index
# (`CatalogIndex::Serializer`).
#
#   MachineTranslation.new(app, editor: user).translate!(locales: %w[de fr])
#   # => { translated: %w[de], failed: { 'fr' => 'translation 500 ...' }, skipped: [] }
#
# Nothing here raises for a locale that cannot be translated: one failure leaves the others intact and is
# reported. It does nothing at all when translation is not configured, so a sandbox or an un-set deployment
# stores nothing.
class MachineTranslation
  FIELDS = %w[description short_description].freeze

  Result = Struct.new(:translated, :failed, :skipped, keyword_init: true)

  def initialize(app, editor: nil)
    @app = app
    @editor = editor
  end

  def self.configured?
    MachineTranslatorClient.configured?
  end

  def translate!(locales:, source: 'en')
    result = Result.new(translated: [], failed: {}, skipped: [])
    locales = Array(locales).map(&:to_s).map(&:strip).reject(&:empty?).uniq
    return result unless self.class.configured?

    locales.each do |locale|
      if locale == source.to_s
        result.skipped << locale
        next
      end

      begin
        result.translated << translate_one(locale, source.to_s)
      rescue MachineTranslatorClient::Error => e
        result.failed[locale] = e.message
      end
    end
    result
  end

  # Approve a stored translation so the index publishes it. Only a translation that exists and is not stale
  # can be approved; approving a stale one is refused (the text it was made from is gone).
  def review!(locale)
    locale = locale.to_s
    entry = stored[locale]
    return false if entry.blank?
    return false if stale?(entry)

    entry['reviewed'] = true
    entry['reviewed_by_id'] = @editor&.id
    entry['reviewed_at'] = Time.current.utc.iso8601
    save
  end

  def discard!(locale)
    return false unless stored.key?(locale.to_s)

    stored.delete(locale.to_s)
    save
  end

  # The translations of this app's listing that the index may publish: reviewed and not stale.
  def self.publishable(app)
    raw = app.respond_to?(:listing_translations) ? app.listing_translations : nil
    return {} unless raw.is_a?(Hash)

    raw.each_with_object({}) do |(locale, entry), out|
      next unless entry.is_a?(Hash)
      next unless entry['reviewed']
      next if stale_entry?(app, entry)

      text = FIELDS.each_with_object({}) do |field, fields|
        value = entry[field]
        fields[field] = value if value.is_a?(String) && value.present?
      end
      out[locale] = text if text.any?
    end
  end

  # True when the stored translation was made from source text that has since changed.
  def self.stale_entry?(app, entry)
    digest = source_digest(app)
    recorded = entry['source_digest'].to_s
    !recorded.empty? && recorded != digest
  end

  private

  def translate_one(locale, source)
    texts = FIELDS.each_with_object({}) do |field, out|
      value = @app.respond_to?(field) ? @app.public_send(field) : nil
      next if value.to_s.strip.empty?

      out[field] = MachineTranslatorClient.translate(value, from: source, to: locale)
    end
    raise MachineTranslatorClient::PermanentError, 'listing has no text to translate' if texts.empty?

    entry = stored[locale] || {}
    entry = entry.merge(texts)
    entry['machine'] = true
    entry['reviewed'] = false
    entry['source_digest'] = self.class.source_digest(@app)
    entry['translated_at'] = Time.current.utc.iso8601
    stored[locale] = entry
    save
    locale
  end

  def stored
    @stored ||= begin
      raw = @app.listing_translations
      raw.is_a?(Hash) ? raw.deep_dup : {}
    end
  end

  def stale?(entry)
    self.class.stale_entry?(@app, entry)
  end

  def save
    @app.update_column(:listing_translations, stored)
  end

  # sha256 over the source listing text, field-and-locale independent: any change to what would be
  # translated makes every stored translation stale, which is what a re-translate should be offered for.
  def self.source_digest(app)
    parts = FIELDS.map { |field| app.respond_to?(field) ? app.public_send(field).to_s : '' }
    Digest::SHA256.hexdigest(parts.join("\u0000"))
  end
end
