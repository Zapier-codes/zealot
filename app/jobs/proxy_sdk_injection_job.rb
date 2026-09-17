class ProxySdkInjectionJob < ApplicationJob
  queue_as :default
  def perform(release_id)
    release = Release.find_by(id: release_id)
    return unless release
    ProxySdk::Injector.call(release)
  end
end
