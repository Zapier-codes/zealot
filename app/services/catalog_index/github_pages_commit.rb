# frozen_string_literal: true

require 'json'
require 'openssl'
require 'socket'
require 'timeout'

module CatalogIndex
  # Task 27b-iii: writes a set of files to the *Pages repository* as ONE git
  # commit, through GitHub's Git Data API (blob -> tree -> commit -> ref
  # update). One commit means a reader can never see a new index next to an
  # old signature or key; the ref update is a plain fast-forward (never
  # forced), so if anything else moved the branch the update is refused and we
  # start over from the new tip. A file whose content did not change costs
  # nothing (same blob -> same tree entry).
  #
  # Uses its OWN credentials (CATALOG_PAGES_REPO / CATALOG_PAGES_TOKEN), never
  # GITHUB_STORAGE_TOKEN: that token can write to the private build storage
  # and must not be reachable from code that publishes to a public repo. The
  # token should be a fine-grained one scoped to the Pages repo only, with
  # "Contents: read and write".
  #
  # The branch must already exist (GitHub Pages is switched on for it in the
  # repo settings); this class does not create branches.
  #
  # Not verified against the live GitHub API from the sandbox this was written
  # in: the specs and the harness run against an in-memory fake of exactly the
  # endpoints used below.
  class GithubPagesCommit
    class Error < StandardError; end
    class ConfigurationError < Error; end
    # Internal: the branch moved after we read it; start over from the new tip.
    class BranchMoved < StandardError; end

    DEFAULT_API_URL = 'https://api.github.com'
    API_VERSION = '2022-11-28'
    REPO_PATTERN = %r{\A[\w.-]+/[\w.-]+\z}
    RETRY_STATUSES = [429, 500, 502, 503, 504].freeze
    MAX_ATTEMPTS = 3            # per HTTP request (network errors / 5xx)
    MAX_PUBLISH_ATTEMPTS = 3    # whole flow, when the branch moved under us
    NETWORK_ERRORS = [
      Timeout::Error, SocketError, EOFError, IOError, Errno::ECONNRESET, Errno::ECONNREFUSED,
      Errno::EPIPE, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError
    ].freeze

    Result = Struct.new(:status, :commit_sha, keyword_init: true) # status: :published | :unchanged

    def self.configured?(env = ENV)
      !env['CATALOG_PAGES_REPO'].to_s.strip.empty? && !env['CATALOG_PAGES_TOKEN'].to_s.strip.empty?
    end

    def initialize(repo: ENV['CATALOG_PAGES_REPO'], token: ENV['CATALOG_PAGES_TOKEN'],
                   branch: ENV['CATALOG_PAGES_BRANCH'], api_url: ENV['GITHUB_API_URL'],
                   transport: nil, sleeper: ->(seconds) { sleep(seconds) })
      @repo = repo.to_s.strip
      @token = token.to_s.strip
      @branch = branch.to_s.strip.empty? ? 'gh-pages' : branch.to_s.strip
      @api_url = (api_url.to_s.strip.empty? ? DEFAULT_API_URL : api_url.to_s.strip).chomp('/')
      @transport = transport || ReleaseStorage::GithubAdapter::HttpTransport.new
      @sleeper = sleeper
      ensure_configured!
    end

    # files: { "index.json" => "...", "index.json.sig" => "..." } (UTF-8 text)
    def publish(files, message:)
      raise ArgumentError, 'no files to publish' if files.empty?

      attempts = 0
      begin
        attempts += 1
        publish_once(files, message)
      rescue BranchMoved
        raise Error, "the #{@branch} branch kept moving; gave up after #{MAX_PUBLISH_ATTEMPTS} tries" if attempts >= MAX_PUBLISH_ATTEMPTS

        retry
      end
    end

    private

    def publish_once(files, message)
      tip_sha = fetch_tip_sha
      base_tree_sha = fetch_tree_sha(tip_sha)

      entries = files.map do |path, content|
        { path: path, mode: '100644', type: 'blob', sha: create_blob(content) }
      end
      tree_sha = create_tree(base_tree_sha, entries)
      return Result.new(status: :unchanged, commit_sha: tip_sha) if tree_sha == base_tree_sha

      commit_sha = create_commit(message, tree_sha, tip_sha)
      move_branch(commit_sha)
      Result.new(status: :published, commit_sha: commit_sha)
    end

    def fetch_tip_sha
      response = request(:get, "#{repo_url}/git/ref/heads/#{@branch}")
      if response.status == 404
        raise Error, "branch #{@branch.inspect} not found in #{@repo}; create it and enable GitHub Pages for it first"
      end

      ok!(response, 'read the branch')
      parse(response).dig('object', 'sha') || raise(Error, 'GitHub returned no commit sha for the branch')
    end

    def fetch_tree_sha(commit_sha)
      response = request(:get, "#{repo_url}/git/commits/#{commit_sha}")
      ok!(response, 'read the tip commit')
      parse(response).dig('tree', 'sha') || raise(Error, 'GitHub returned no tree sha for the tip commit')
    end

    def create_blob(content)
      response = request(:post, "#{repo_url}/git/blobs", json: { content: content, encoding: 'utf-8' })
      ok!(response, 'create a blob')
      parse(response)['sha'] || raise(Error, 'GitHub returned no blob sha')
    end

    def create_tree(base_tree_sha, entries)
      response = request(:post, "#{repo_url}/git/trees", json: { base_tree: base_tree_sha, tree: entries })
      ok!(response, 'create the tree')
      parse(response)['sha'] || raise(Error, 'GitHub returned no tree sha')
    end

    def create_commit(message, tree_sha, parent_sha)
      response = request(:post, "#{repo_url}/git/commits", json: { message: message, tree: tree_sha, parents: [parent_sha] })
      ok!(response, 'create the commit')
      parse(response)['sha'] || raise(Error, 'GitHub returned no commit sha')
    end

    # Fast-forward only (force: false). GitHub answers 422 "Update is not a
    # fast forward" (and occasionally 409) when the branch moved after we
    # read it: start over from the new tip rather than overwrite anything.
    def move_branch(commit_sha)
      response = request(:patch, "#{repo_url}/git/refs/heads/#{@branch}", json: { sha: commit_sha, force: false })
      raise BranchMoved if [409, 422].include?(response.status)

      ok!(response, 'move the branch')
    end

    def repo_url
      "#{@api_url}/repos/#{@repo}"
    end

    def request(method, url, json: nil)
      headers = { 'Accept' => 'application/vnd.github+json', 'User-Agent' => 'zealot-catalog-index',
                  'X-GitHub-Api-Version' => API_VERSION, 'Authorization' => "Bearer #{@token}" }
      body = nil
      if json
        headers['Content-Type'] = 'application/json'
        body = JSON.generate(json)
      end

      attempts = 0
      loop do
        attempts += 1
        begin
          response = @transport.call(method, url, headers: headers, body: body)
        rescue *NETWORK_ERRORS => e
          raise Error, "GitHub request failed (#{method.to_s.upcase} #{url}): #{e.class}" if attempts >= MAX_ATTEMPTS

          @sleeper.call(2**(attempts - 1))
          next
        end

        if RETRY_STATUSES.include?(response.status) && attempts < MAX_ATTEMPTS
          @sleeper.call(2**(attempts - 1))
          next
        end
        return response
      end
    end

    def ok!(response, action)
      return if response.status.between?(200, 299)

      detail = begin
        JSON.parse(response.body.to_s)['message']
      rescue JSON::ParserError, TypeError
        nil
      end
      detail = "#{detail}; " if detail
      raise Error, "GitHub could not #{action}: #{detail}HTTP #{response.status}"
    end

    def parse(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      raise Error, "GitHub returned a non-JSON body (HTTP #{response.status})"
    end

    def ensure_configured!
      missing = []
      missing << 'CATALOG_PAGES_REPO' if @repo.empty?
      missing << 'CATALOG_PAGES_TOKEN' if @token.empty?
      raise ConfigurationError, "catalog publishing needs env vars: #{missing.join(', ')}" unless missing.empty?
      return if REPO_PATTERN.match?(@repo)

      raise ConfigurationError, "CATALOG_PAGES_REPO must look like owner/name, got #{@repo.inspect}"
    end
  end
end
