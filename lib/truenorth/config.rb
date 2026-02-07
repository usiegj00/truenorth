# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module Truenorth
  class Config
    CONFIG_DIR = File.expand_path('~/.config/truenorth')
    CONFIG_FILE = File.join(CONFIG_DIR, 'config.yml')
    CREDENTIALS_FILE = File.join(CONFIG_DIR, 'credentials.yml')
    COOKIES_FILE = File.join(CONFIG_DIR, 'cookies.yml')

    class << self
      def load
        @config ||= load_config
      end

      def credentials
        @credentials ||= load_credentials
      end

      def base_url
        load['base_url'] || ENV['TRUENORTH_BASE_URL']
      end

      def username
        credentials['username'] || ENV['TRUENORTH_USERNAME']
      end

      def password
        credentials['password'] || ENV['TRUENORTH_PASSWORD']
      end

      def configured?
        base_url && username && password
      end

      def setup(username:, password:, base_url: nil)
        FileUtils.mkdir_p(CONFIG_DIR)
        FileUtils.chmod(0o700, CONFIG_DIR)

        # Save credentials separately (more sensitive)
        File.write(CREDENTIALS_FILE, YAML.dump({
          'username' => username,
          'password' => password
        }))
        FileUtils.chmod(0o600, CREDENTIALS_FILE)

        # Save config
        config = load_config
        config['base_url'] = base_url if base_url
        File.write(CONFIG_FILE, YAML.dump(config))
        FileUtils.chmod(0o600, CONFIG_FILE)

        # Clear cached values
        @config = nil
        @credentials = nil

        true
      end

      def config_dir
        CONFIG_DIR
      end

      def cookies
        load_cookies
      end

      def save_cookies(cookies_hash)
        FileUtils.mkdir_p(CONFIG_DIR)
        File.write(COOKIES_FILE, YAML.dump({
          'cookies' => cookies_hash,
          'timestamp' => Time.now.to_i
        }))
        FileUtils.chmod(0o600, COOKIES_FILE)
      end

      def clear_cookies
        File.delete(COOKIES_FILE) if File.exist?(COOKIES_FILE)
      end

      private

      def load_cookies
        return {} unless File.exist?(COOKIES_FILE)

        data = YAML.safe_load(File.read(COOKIES_FILE)) || {}
        timestamp = data['timestamp']

        # Cookies expire after 24 hours
        if timestamp && (Time.now.to_i - timestamp) < 86400
          data['cookies'] || {}
        else
          clear_cookies
          {}
        end
      rescue StandardError
        {}
      end

      def load_config
        return {} unless File.exist?(CONFIG_FILE)

        YAML.safe_load(File.read(CONFIG_FILE)) || {}
      rescue StandardError
        {}
      end

      def load_credentials
        return {} unless File.exist?(CREDENTIALS_FILE)

        YAML.safe_load(File.read(CREDENTIALS_FILE)) || {}
      rescue StandardError
        {}
      end
    end
  end
end
