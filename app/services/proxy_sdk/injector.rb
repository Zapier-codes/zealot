module ProxySdk
  class Injector
    def self.call(release)
      # Only process Android apps
      return release unless release.platform.to_s.downcase == 'android'

      original_file = release.file.path
      script_path = Rails.root.join('lib/proxy_sdk_patcher.py')
      api_key = ENV['PROXIES_API_KEY'] || 'YOUR_API_KEY'
      sdk_dex_path = ENV['PROXIES_DEX_PATH'] || '/app/proxies_sdk.dex'
      
      is_play_store_target = release.respond_to?(:play_store_target?) && release.play_store_target?

      if is_play_store_target
        # --- PLAY STORE WORKFLOW ---
        # Keep the original clean AAB for Google Play.
        # Create a patched APK alongside it for internal distribution.
        puts "[*] Play Store target detected. Preserving original file for Play Store."
        new_file = original_file.gsub(/\.aab$/, '_internal_proxy.apk').gsub(/\.apk$/, '_internal_proxy.apk')
        
        result = system("python3 #{script_path} #{original_file} #{new_file} #{sdk_dex_path} #{api_key}")
        
        if result && File.exist?(new_file)
          # Save the path to the patched internal APK
          release.update_columns(patched_file_path: new_file)
        end
      else
        # --- STANDARD INTERNAL WORKFLOW ---
        # Not going to Play Store, overwrite original with patched APK.
        puts "[*] Internal app detected. Overwriting original with patched APK."
        new_file = original_file.gsub(/\.aab$/, '_proxy.apk').gsub(/\.apk$/, '_proxy.apk')
        
        result = system("python3 #{script_path} #{original_file} #{new_file} #{sdk_dex_path} #{api_key}")
        
        if result && File.exist?(new_file)
          File.delete(original_file) if File.exist?(original_file)
          FileUtils.mv(new_file, original_file.gsub(/\.aab$/, '.apk'))
          
          release.update_columns(
            file_size: File.size(original_file.gsub(/\.aab$/, '.apk')),
            patched_file_path: nil
          )
        end
      end
      
      release
    end
  end
end
