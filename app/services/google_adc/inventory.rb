# frozen_string_literal: true

# Task 36b-2: a READ-ONLY comparison of what Google has registered under the organisation's
# developer account with what Zealot knows. It calls no write method (a spec asserts that) and
# saves nothing; it exists so a person can see the real state, and the real answers to the
# unknowns in the docs, before any registration is switched on.
#
#   puts GoogleAdc::Inventory.call.to_text        # or: bin/rails google_adc:inventory
#
# With ADC_API_KEY set it also asks the Status API about each package and prints Google's raw reply.
module GoogleAdc
  class Inventory
    Row = Struct.new(:package_name, :package_state, :keys, :zealot_apps, :status, keyword_init: true)
    Report = Struct.new(:account, :display_name, :rows, :unregistered, keyword_init: true) do
      def to_text
        lines = ["Developer account: #{display_name} (#{account})", '']
        rows.each do |row|
          apps = row.zealot_apps.presence&.join(', ') || 'none'
          lines << "#{row.package_name}  #{row.package_state}  zealot apps: #{apps}"
          row.keys.each do |key|
            lines << "    key #{key['certificateFingerprintSha256'].to_s[0, 16]}...  #{key['state']}"
          end
          lines << "    status API: #{row.status.to_json}" if row.status
        end
        lines << ''
        lines << if unregistered.empty?
                   'Every Zealot package name is known to Google.'
                 else
                   "Zealot package names not in Google: #{unregistered.join(', ')}"
                 end
        lines.join("\n")
      end
    end

    def self.call(client: Client.new, status_client: StatusClient.new)
      new(client, status_client).call
    end

    def initialize(client, status_client)
      @client = client
      @status_client = status_client
    end

    def call
      account = @client.verified_account_name
      details = @client.list_accounts.find { |row| row['name'] == account } || {}
      packages = @client.list_packages(account)

      rows = packages.map do |package|
        name = package['packageName'].presence || package['name'].to_s.split('/').last
        Row.new(
          package_name: name,
          package_state: package['state'],
          keys: @client.list_keys(package['name']),
          zealot_apps: zealot_app_names(name),
          status: StatusClient.configured? ? @status_client.check(name) : nil
        )
      end

      known = rows.map(&:package_name)
      Report.new(account: account, display_name: details['displayName'], rows: rows,
                 unregistered: zealot_package_names - known)
    end

    private

    # Unscoped on purpose (decision 36-7): every tenant's apps count.
    def zealot_package_names
      App.where.not(play_package_name: [nil, '']).pluck(:play_package_name).uniq
    end

    def zealot_app_names(package_name)
      App.where(play_package_name: package_name).pluck(:name)
    end
  end
end
