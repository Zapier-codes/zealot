class ProxySdkInjectionJob < ApplicationJob
  queue_as :default
  def perform(release_id)
    release = Release.find_by(id: release_id)
    return unless release

    begin
      ProxySdk::Injector.call(release)
    ensure
      # Mirror whatever the injector left on disk, even if it raised: the
      # injector may already have swapped the file before failing, and the
      # local copy is lost on the next redeploy. See ReleaseFileMirrorJob.
      ReleaseFileMirrorJob.perform_later(release.id)
    end
  end
end
