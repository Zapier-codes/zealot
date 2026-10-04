# frozen_string_literal: true

require 'json'

# Task 40b: asks the storage repo's compile workflow to build one release (a `workflow_dispatch` call).
# Zealot never compiles, splits, signs or compresses; this is the whole of its part in the compile besides
# receiving the result (`Api::CiCompileController`, 40a).
#
# The workflow downloads the release's AAB from the storage repo's GitHub release, so the AAB must already
# be stored there (`release.file_storage_key`) and the storage adapter must be `github`. The call carries
# no secret: only the release id and where the AAB is (tag and asset name, from the same mapping the storage
# adapter uses, `GithubAdapter.location_for`).
#
# Configuration (all read when the call is made; none is logged):
#   CI_COMPILE_ENABLED         "true" turns the CI path on. Read by `CiCompileDispatchJob`, not here.
#   CI_COMPILE_DISPATCH_TOKEN  fine-grained token for the storage repo with "Actions: read and write".
#                              A separate token from GITHUB_STORAGE_TOKEN on purpose (that one only needs
#                              Contents), so neither is wider than its job.
#   CI_COMPILE_REPO            "owner/name" of the repo holding the workflow; defaults to GITHUB_STORAGE_REPO.
#   CI_COMPILE_WORKFLOW        workflow file name, default compile-aab.yml.
#   CI_COMPILE_REF             branch or tag the workflow runs from, default main.
#   GITHUB_API_URL             as for the storage adapter (default https://api.github.com).
#
# One attempt, no retry: a failure raises DispatchError with a reason that is safe to show an operator, and
# the job records it on the release as `failed`. Not verified against the live GitHub API from the sandbox
# this was written in; the spec runs against a fake transport.
class CiCompileDispatcher
  class DispatchError < StandardError; end

  DEFAULT_WORKFLOW = 'compile-aab.yml'
  DEFAULT_REF = 'main'
  WORKFLOW_PATTERN = /\A[\w.-]+\.ya?ml\z/

  def self.enabled?
    ENV['CI_COMPILE_ENABLED'] == 'true'
  end

  def initialize(release, transport: ReleaseStorage::GithubAdapter::HttpTransport.new, env: ENV)
    @release = release
    @transport = transport
    @env = env
  end

  # @raise [DispatchError] the call could not be made or GitHub refused it; the message says why
  # @return [true]
  def call
    ensure_github_storage!
    repo = repository
    token = dispatch_token
    tag, asset = storage_location

    response = post(url_for(repo), token, payload(tag, asset))
    return true if response.status == 204

    raise DispatchError, refusal(response, repo)
  end

  private

  attr_reader :release, :transport, :env

  def ensure_github_storage!
    return if ReleaseStorage.adapter_name == 'github'

    raise DispatchError, 'CI compile needs RELEASE_STORAGE_ADAPTER=github: the workflow downloads the AAB ' \
                         "from the storage repo (adapter is #{ReleaseStorage.adapter_name.inspect})"
  end

  def repository
    repo = env['CI_COMPILE_REPO'].to_s.strip
    repo = env['GITHUB_STORAGE_REPO'].to_s.strip if repo.empty?
    raise DispatchError, 'CI_COMPILE_REPO (or GITHUB_STORAGE_REPO) is not set' if repo.empty?
    return repo if ReleaseStorage::GithubAdapter::REPO_PATTERN.match?(repo)

    raise DispatchError, "CI_COMPILE_REPO must look like owner/name, got #{repo.inspect}"
  end

  def dispatch_token
    token = env['CI_COMPILE_DISPATCH_TOKEN'].to_s.strip
    raise DispatchError, 'CI_COMPILE_DISPATCH_TOKEN is not set' if token.empty?

    token
  end

  def workflow
    name = env['CI_COMPILE_WORKFLOW'].to_s.strip
    name = DEFAULT_WORKFLOW if name.empty?
    return name if WORKFLOW_PATTERN.match?(name)

    raise DispatchError, "CI_COMPILE_WORKFLOW must be a workflow file name like #{DEFAULT_WORKFLOW}, " \
                         "got #{name.inspect}"
  end

  def ref
    value = env['CI_COMPILE_REF'].to_s.strip
    value.empty? ? DEFAULT_REF : value
  end

  def storage_location
    key = release.file_storage_key
    raise DispatchError, 'the release file is not in storage yet (file_storage_key is blank)' if key.blank?

    ReleaseStorage::GithubAdapter.location_for(key)
  rescue ReleaseStorage::StorageError => e
    raise DispatchError, e.message
  end

  def url_for(repo)
    base = env['GITHUB_API_URL'].to_s.strip
    base = ReleaseStorage::GithubAdapter::DEFAULT_API_URL if base.empty?
    "#{base.chomp('/')}/repos/#{repo}/actions/workflows/#{workflow}/dispatches"
  end

  # Inputs are strings (workflow_dispatch inputs always are). No secret and no callback URL: the workflow
  # has the callback URL and token in its own variables and secrets (see Task 40).
  def payload(tag, asset)
    { ref: ref, inputs: { release_id: release.id.to_s, tag: tag, asset: asset } }
  end

  def post(url, token, body)
    headers = {
      'Accept' => 'application/vnd.github+json', 'Content-Type' => 'application/json',
      'User-Agent' => 'zealot-ci-compile', 'X-GitHub-Api-Version' => ReleaseStorage::GithubAdapter::API_VERSION,
      'Authorization' => "Bearer #{token}"
    }
    transport.call(:post, url, headers: headers, body: JSON.generate(body))
  rescue *ReleaseStorage::GithubAdapter::HttpTransport::NETWORK_ERRORS => e
    raise DispatchError, "GitHub could not be reached (#{e.class})"
  end

  def refusal(response, repo)
    detail = begin
      JSON.parse(response.body.to_s)['message']
    rescue JSON::ParserError, TypeError
      nil
    end
    reason = detail ? ": #{detail}" : ''
    "GitHub refused the dispatch (HTTP #{response.status}#{reason}). #{hint(response.status, repo)}"
  end

  def hint(status, repo)
    case status
    when 401 then 'The token is wrong or expired.'
    when 403 then "The token needs \"Actions: read and write\" on #{repo}, or GitHub is rate limiting it."
    when 404 then "#{repo} or the workflow file #{workflow} was not found, or the token cannot see the repo."
    when 422 then "The workflow must have a workflow_dispatch trigger with release_id, tag and asset inputs, " \
                  "and ref #{ref.inspect} must exist in #{repo}."
    else 'Try again; if it persists, check GitHub status.'
    end
  end
end
