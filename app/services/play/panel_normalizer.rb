# frozen_string_literal: true

module Play
  # Z-P25 (docs/PARITY-KANBAN.md): the one place a raw Play response becomes our labelled panel shape.
  # Both backends produce slightly different dicts (Aurora's Kotlin client and the Python `playstoreapi`
  # both follow `googleplay.proto`, but with different field names and nesting), so the adapter's runner
  # normalizes each backend's JSON just enough to call `call`; from there on the shape is fixed here and
  # the rest of Zealot never sees a backend-specific key.
  #
  # The output is the "Play panel" a listing may show beside its own data: `package`, `title`,
  # `developer`, `rating` (average 0-5), `rating_count`, `downloads` (the play string, verbatim),
  # `price_label`, `icon_url`, `screenshot_urls[]`, `short_description`, and `source: 'play'`. Every field
  # is optional and omitted when Play did not give it — nothing is invented, and a missing rating is
  # absent, not 0 (the same rule the storefront reads use).
  #
  # Pure: no Rails, no HTTP, no OpenSSL. Given the same dict it returns the same panel, so it is exercised
  # directly in the spec.
  module PanelNormalizer
    module_function

    # @param raw [Hash] a backend's parsed JSON (string keys, already a plain Hash)
    # @return [Hash] the labelled panel, `source: 'play'`, with only the fields we actually have
    def call(raw, package: nil)
      return nil unless raw.is_a?(Hash) && !raw.empty?

      panel = { 'source' => 'play' }
      panel['package']           = package || str(raw['package'] || raw['packageName'] || raw['docid'])
      panel['title']             = str(raw['title'] || raw['name'])
      panel['developer']         = str(raw['developer'] || raw['developerName'] || raw['author'])
      panel['short_description'] = str(raw['shortDescription'] || raw['summary'])
      panel['rating']            = rating(raw)
      panel['rating_count']      = count(raw['ratingCount'] || raw['ratingsCount'] || raw['numRatings'])
      panel['downloads']         = str(raw['installs'] || raw['downloads'] || raw['downloadCount'])
      panel['price_label']       = str(raw['price'] || raw['formattedPrice'] || raw['priceLabel'])
      panel['icon_url']          = image_url(raw['icon'] || raw['iconUrl'])
      panel['screenshot_urls']   = screenshot_urls(raw)
      panel.compact
    end

    def rating(raw)
      value = raw['rating'] || raw['score'] ||
              (raw['aggregateRating'].is_a?(Hash) ? raw['aggregateRating']['starRating'] : nil)
      value = value.to_f
      value.positive? ? value.round(2) : nil
    end

    def count(value)
      n = value.to_i
      n.positive? ? n : nil
    end

    # Play gives a download count as free text ("1,000,000+"); keep it verbatim rather than parse it into
    # a number we would then show as if it were exact.
    def str(value)
      s = value.to_s.strip
      s.empty? ? nil : s
    end

    def image_url(value)
      case value
      when Hash then str(value['url'] || value['src'])
      else str(value)
      end
    end

    # Backends give screenshots either as a bare array, a list of `{url:}` hashes, or a nested
    # `images`/`screenshots` object keyed by type. Keep the https ones in order; drop anything else.
    def screenshot_urls(raw)
      list = raw['screenshots'] || raw['images'] || []
      list = list.values.flatten if list.is_a?(Hash)
      Array(list).filter_map { |item| image_url(item) }.select { |u| u.start_with?('https://') }
    end
  end
end
