# frozen_string_literal: true

# Task 27b-ii. Never prints the private key.
namespace :catalog_index do
  desc 'Create the catalog-index Ed25519 signing key (once) and print its public key'
  task generate_key: :environment do
    abort 'A catalog-index signing key already exists; rotation is not designed yet (Task 27 ❓3).' if CatalogIndexSigningKey.exists?

    key = CatalogIndexSigningKey.generate!
    puts "key_id:     #{key.key_id}"
    puts "public_key: #{key.public_key}   (base64, raw Ed25519 — this is what D-store pins)"
  end

  desc 'Print the catalog-index public key and id'
  task public_key: :environment do
    key = CatalogIndexSigningKey.current or abort 'No key yet: run rake catalog_index:generate_key'
    puts "key_id:     #{key.key_id}"
    puts "public_key: #{key.public_key}"
  end

  desc 'Sign the catalog index and publish it to the Pages repo now (one commit), then ping D-store'
  task publish: :environment do
    unless CatalogIndex::GithubPagesCommit.configured?
      abort 'Set CATALOG_PAGES_REPO (owner/name) and CATALOG_PAGES_TOKEN first.'
    end
    abort 'No key yet: run rake catalog_index:generate_key' unless CatalogIndexSigningKey.current

    result = CatalogIndex::Publish.call
    puts "#{result.status}: generated_at=#{result.generated_at.iso8601} key_id=#{result.key_id} " \
         "commit=#{result.commit_sha} d-store hook=#{result.hook}"
  end
end
