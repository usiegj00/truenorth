# frozen_string_literal: true

require 'thor'
require 'date'
require_relative '../truenorth'

module Truenorth
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    desc 'configure', 'Set up credentials for the booking system'
    option :username, aliases: '-u', desc: 'Member ID (e.g., 12345-00)'
    option :password, aliases: '-p', desc: 'Password'
    option :url, desc: 'Base URL (e.g., https://your-club.com)'
    def configure
      url = options[:url] || ask('Base URL (e.g., https://your-club.com):')
      username = options[:username] || ask('Member ID:')
      password = options[:password] || ask('Password:', echo: false)
      puts '' if options[:password].nil? # newline after hidden input

      Config.setup(
        username: username,
        password: password,
        base_url: url
      )

      puts "Configuration saved to #{Config.config_dir}"
      puts 'Credentials stored securely (600 permissions)'
    end

    desc 'availability [DATE]', 'Check available slots'
    option :activity, aliases: '-a', default: 'squash', desc: 'Activity type (squash, golf, music, meeting)'
    option :json, type: :boolean, desc: 'Output as JSON'
    def availability(date = nil)
      date = parse_date(date)
      client = Client.new

      say "Checking availability for #{date}...", :cyan
      result = client.availability(date, activity: options[:activity])

      if options[:json]
        puts JSON.pretty_generate(result)
      else
        if result[:slots].empty?
          say 'No available slots found.', :yellow
        else
          say "\nAvailable #{options[:activity]} slots for #{date}:", :green
          result[:slots].each do |time, courts|
            say "  #{time}: #{courts.join(', ')}"
          end
        end
      end
    rescue Error => e
      say "Error: #{e.message}", :red
      exit 1
    end

    desc 'book TIME', 'Book a slot at the specified time'
    option :date, aliases: '-d', desc: 'Date (YYYY-MM-DD, or +N for days from today)'
    option :court, aliases: '-c', desc: 'Preferred court (e.g., "Court 1", "Squash Court 2")'
    option :activity, aliases: '-a', default: 'squash', desc: 'Activity type'
    option :dry_run, type: :boolean, aliases: '-n', desc: 'Test without actually booking'
    def book(time)
      date = parse_date(options[:date])
      client = Client.new

      mode = options[:dry_run] ? ' (DRY RUN)' : ''
      say "Booking #{options[:activity]} at #{time} on #{date}#{mode}...", :cyan

      result = client.book(
        time,
        date: date,
        court: options[:court],
        activity: options[:activity],
        dry_run: options[:dry_run]
      )

      if result[:success]
        if result[:dry_run]
          say "\nDry run successful!", :yellow
          say "Would book: #{result[:court]} at #{result[:time]}"
        else
          say "\nBooking confirmed!", :green
          say "Court: #{result[:court]}"
          say "Time: #{result[:time]}"
          say "Confirmation: #{result[:confirmation]}" if result[:confirmation]
        end
      end
    rescue Error => e
      say "Error: #{e.message}", :red
      exit 1
    end

    desc 'reservations', 'List your current reservations'
    option :json, type: :boolean, desc: 'Output as JSON'
    def reservations
      client = Client.new

      say 'Fetching reservations...', :cyan
      results = client.reservations

      if options[:json]
        puts JSON.pretty_generate(results)
      else
        if results.empty?
          say 'No reservations found.', :yellow
        else
          say "\nYour reservations:", :green
          results.each do |res|
            parts = [res[:date], res[:time], res[:activity], res[:court]].compact
            say "  #{parts.join(' - ')}"
          end
        end
      end
    rescue Error => e
      say "Error: #{e.message}", :red
      exit 1
    end

    desc 'cancel RESERVATION_ID', 'Cancel a reservation'
    option :dry_run, type: :boolean, aliases: '-n', desc: 'Test without actually canceling'
    def cancel(reservation_id)
      client = Client.new

      say "Canceling reservation #{reservation_id}...", :cyan
      client.cancel(reservation_id, dry_run: options[:dry_run])

      say 'Reservation canceled.', :green
    rescue Error => e
      say "Error: #{e.message}", :red
      exit 1
    end

    desc 'status', 'Check configuration and connection status'
    def status
      say 'Truenorth Configuration Status', :cyan
      say '=' * 35

      say "  Config dir: #{Config.config_dir}"
      say "  Base URL: #{Config.base_url || '(not set)'}", Config.base_url ? :green : :yellow
      say "  Username: #{Config.username || '(not set)'}", Config.username ? :green : :yellow
      say "  Password: #{Config.password ? '********' : '(not set)'}", Config.password ? :green : :yellow

      if Config.configured?
        say "\nTesting connection...", :cyan
        begin
          client = Client.new
          client.login
          say '  Login: SUCCESS', :green
        rescue Error => e
          say "  Login: FAILED - #{e.message}", :red
        end
      else
        say "\nNot fully configured. Run: truenorth configure", :yellow
      end
    end

    desc 'version', 'Show version'
    def version
      say "truenorth #{VERSION}"
    end

    private

    def parse_date(date_str)
      return Date.today if date_str.nil? || date_str.empty?

      case date_str
      when /^\+(\d+)$/
        Date.today + ::Regexp.last_match(1).to_i
      when 'today'
        Date.today
      when 'tomorrow'
        Date.today + 1
      else
        Date.parse(date_str)
      end
    rescue ArgumentError
      say "Invalid date: #{date_str}", :red
      exit 1
    end
  end
end
