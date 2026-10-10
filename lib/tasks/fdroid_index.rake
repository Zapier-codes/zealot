# frozen_string_literal: true

require 'fileutils'

# Z-P15 (Play Console parity): render Zealot's live catalog as an F-Droid repository (index-v2 + entry.json),
# so an F-Droid-style client (F-Droid, Droid-ify, Neo Store, Obtainium) can read our apps. This task only
# writes the two JSON documents and prints a summary; signing the `entry.jar` and publishing are Z-P15b.
#
#   rake fdroid_index:generate                 # writes to ./tmp/fdroid_repo (relative to the app root)
#   OUT=/path/to/repo rake fdroid_index:generate
#
# The address a client fetches the repo from is FDROID_REPO_ADDRESS (it becomes `repo.address` and the base
# the relative file names resolve against); it is required, because an index published without it is not
# reachable. The APK `file.name` values are absolute Zealot download URLs regardless (see the serializer).
namespace :fdroid_index do
  desc 'Render the live catalog as F-Droid index-v2 + entry.json (unsigned; Z-P15a)'
  task generate: :environment do
    out_dir = ENV['OUT'].to_s.strip
    out_dir = Rails.root.join('tmp', 'fdroid_repo').to_s if out_dir.empty?
    address = ENV['FDROID_REPO_ADDRESS'].to_s.strip
    abort 'Set FDROID_REPO_ADDRESS (the URL a client fetches the repo from, e.g. https://store.example.com/fdroid).' if address.empty?

    apps = CatalogIndex::Signer.default_apps
    result = FdroidIndex::Serializer.call(
      apps,
      repo_name: ENV['FDROID_REPO_NAME'].to_s.strip.empty? ? 'Zealot' : ENV['FDROID_REPO_NAME'].to_s.strip,
      repo_description: ENV['FDROID_REPO_DESCRIPTION'].presence,
      repo_address: address
    )

    FileUtils.mkdir_p(out_dir)
    File.write(File.join(out_dir, 'index-v2.json'), result.index_json)
    File.write(File.join(out_dir, 'entry.json'), result.entry_json)
    # Z-P15c: the signer index, when a certificate fingerprint is resolvable. Written unsigned here for
    # inspection; the Publisher signs it (signer-index.json.sig) into the Pages repo.
    if result.signer_index_json
      File.write(File.join(out_dir, 'signer-index.json'), result.signer_index_json)
      puts "wrote #{out_dir}/signer-index.json (#{result.signer_index_json.bytesize} bytes)"
    end

    puts "wrote #{out_dir}/index-v2.json (#{result.index_json.bytesize} bytes)"
    puts "wrote #{out_dir}/entry.json (#{result.entry_json.bytesize} bytes)"
    puts "packages: #{result.package_count}"
    puts "generated_at: #{result.generated_at.utc.iso8601}"
    puts
    puts 'Next: sign entry.json into entry.jar and publish (Z-P15b/Z-P15c/Z-P15d: FdroidIndex::Publisher /'
    puts 'FdroidIndexPublishJob, gated by ENABLE_FDROID_INDEX).'
  end
end
