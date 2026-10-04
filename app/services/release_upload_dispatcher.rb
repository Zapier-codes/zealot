# frozen_string_literal: true

require 'json'

# Task 40i-a: asks the storage repo's stage-1 workflow (`read-upload.yml`) to read one staged upload: the
# manifest, the icon and the file's hash. A `workflow_dispatch` call, the same shape as `CiCompileDispatcher`
# (40b). The staged file sits in the R2 staging bucket, not in the storage repo, so unlike the compile dispatch
# this needs no particular storage adapter.
#
# The call carries no secret and no callback URL: only the upload id, the staging key and the file name. The
# workflow reads the file with its own R2 credentials and calls back with a GitHub OIDC token (never a shared
# secret), see `GithubOidcVerifier` and `Api::ReleaseUploadCallbacksController`.
#
# Configuration (read when the call is made; none is logged):
#   CI_COMPILE_DISPATCH_TOKEN   fine-grained token with "Actions: read and write" on the storage repo (the same
#                               one 40b uses)
#   CI_COMPILE_REPO             "owner/name" of the repo holding the workflow; defaults to GITHUB_STORAGE_REPO
#   CI_READ_UPLOAD_WORKFLOW     workflow file name, default read-upload.yml
#   CI_COMPILE_REF              branch the workflow runs from, default main
#   GITHUB_API_URL              default https://api.github.com
#
# One attempt, no retry: a failure raises DispatchError with a reason that is safe to show an operator, and the
# job records it on the upload as `failed`. Not verified against the live GitHub API; the spec uses a fake
# transport.
class ReleaseUploadDispatcher
  DEFAULT_WORKFLOW = 'read-upload.yml'

  # Reused from the compile dispatch so one failure type serves both.
  DispatchError = CiCompileDispatcher::DispatchError

  def self.workflow_name(env = ENV)
    name = env['CI_READ_UPLOAD_WORKFLOW'].to_s.strip
    name.empty? ? DEFAULT_WORKFLOW : name
  end

  def initialize(upload, transport: ReleaseStorage::GithubAdapter::HttpTransport.new, env: ENV)
    @upload = upload
    @transport = transport
    @env = env
  end

  # @raise [DispatchError]
  # @return [true]
  def call
    raise DispatchError, 'the upload has no staging key' if upload.staging_key.blank?

    repo = repository
    response = post(url_for(repo), dispatch_token, payload)
    return true if response.status == 204

    raise DispatchError, refusal(response, repo)
  end

  private

  attr_reader :upload, :transport, :env

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
    name = self.class.workflow_name(env)
    return name if CiCompileDispatcher::WORKFLOW_PATTERN.match?(name)

    raise DispatchError, "CI_READ_UPLOAD_WORKFLOW must be a workflow file name like #{DEFAULT_WORKFLOW}, " \
                         "got #{name.inspect}"
  end

  def ref
    value = env['CI_COMPILE_REF'].to_s.strip
    value.empty? ? CiCompileDispatcher::DEFAULT_REF : value
  end

  def url_for(repo)
    base = env['GITHUB_API_URL'].to_s.strip
    base = ReleaseStorage::GithubAdapter::DEFAULT_API_URL if base.empty?
    "#{base.chomp('/')}/repos/#{repo}/actions/workflows/#{workflow}/dispatches"
  end

  # workflow_dispatch inputs are strings. Nothing secret.
  def payload
    { ref: ref, inputs: { upload_id: upload.id.to_s, staging_key: upload.staging_key, filename: upload.filename } }
  end

  def post(url, token, body)
    headers = {
      'Accept' => 'application/vnd.github+json', 'Content-Type' => 'application/json',
      'User-Agent' => 'zealot-read-upload', 'X-GitHub-Api-Version' => ReleaseStorage::GithubAdapter::API_VERSION,
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
    when 422 then 'The workflow must have a workflow_dispatch trigger with upload_id, staging_key and filename ' \
                  "inputs, and ref #{ref.inspect} must exist in #{repo}."
    else 'Try again; if it persists, check GitHub status.'
    end
  end
end
