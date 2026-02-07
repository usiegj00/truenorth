# frozen_string_literal: true

require 'thor'
require 'date'
require 'tty-table'
require 'io/console'
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
    option :debug, type: :boolean, desc: 'Show debug output'
    option :http, type: :boolean, desc: 'Use HTTP mode (faster, but only 2 courts)'
    def availability(date = nil)
      date = parse_date(date)

      client = if options[:http]
                 say 'Using HTTP mode (fast, 2 courts only)...', :yellow if !options[:json]
                 Client.new(debug: options[:debug])
               else
                 BrowserClient.new(debug: options[:debug])
               end

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

    desc 'book TIME_OR_DESCRIPTION', 'Book a slot (e.g., "10am", "feb 15 10am", "squash feb 15 10am")'
    option :date, aliases: '-d', desc: 'Date (YYYY-MM-DD, or +N for days from today)'
    option :court, aliases: '-c', desc: 'Preferred court (e.g., "Court 1", "Squash Court 2")'
    option :activity, aliases: '-a', default: 'squash', desc: 'Activity type'
    option :dry_run, type: :boolean, aliases: '-n', desc: 'Test without actually booking'
    option :http, type: :boolean, desc: 'Use HTTP mode (faster, but only 2 courts)'
    option :debug, type: :boolean, desc: 'Show debug output'
    def book(time_or_description)
      # Parse natural language input
      parsed = parse_booking_request(time_or_description, options[:date], options[:activity])

      date = parsed[:date]
      time = parsed[:time]
      activity = parsed[:activity]

      # Use browser mode unless --http flag is set (needed to see all 3 courts)
      client = if options[:http]
                 Client.new(debug: options[:debug])
               else
                 BrowserClient.new(debug: options[:debug])
               end

      mode = options[:dry_run] ? ' (DRY RUN)' : ''
      say "Booking #{activity} at #{time} on #{date}#{mode}...", :cyan

      result = client.book(
        time,
        date: date,
        court: options[:court],
        activity: activity,
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

      # If no slot available, show nearby available times
      if e.message.include?('No slot available')
        show_nearby_availability(client, date, time, activity)
      end

      exit 1
    end

    desc 'reservations', 'List your current reservations'
    option :json, type: :boolean, desc: 'Output as JSON'
    option :all, type: :boolean, aliases: '-a', desc: 'Show all family members (default: only you)'
    option :debug, type: :boolean, desc: 'Show debug output'
    def reservations
      # Use HTTP mode for reservations (works reliably)
      client = Client.new(debug: options[:debug])

      say 'Fetching reservations...', :cyan
      results = client.reservations

      if options[:json]
        puts JSON.pretty_generate(results)
      else
        if results.empty?
          say 'No reservations found.', :yellow
        else
          # Filter to only "You" unless --all is specified
          your_reservations = results.select { |r| r[:member].nil? }
          other_count = results.length - your_reservations.length

          if options[:all]
            display_reservations_table(results)
          else
            if your_reservations.empty?
              say 'You have no reservations.', :yellow
              if other_count > 0
                say "Note: #{other_count} reservation#{'s' if other_count != 1} for other family members", :cyan
                say "Use 'truenorth reservations --all' to see all", :cyan
              end
            else
              display_reservations_table(your_reservations)
              if other_count > 0
                say "\nNote: #{other_count} reservation#{'s' if other_count != 1} for other family members (use --all to show)", :cyan
              end
            end
          end
        end
      end
    rescue Error => e
      say "Error: #{e.message}", :red
      exit 1
    end

    desc 'cancel INDEX', 'Cancel a reservation by index (from reservations list)'
    option :dry_run, type: :boolean, aliases: '-n', desc: 'Test without actually canceling'
    option :all, type: :boolean, aliases: '-a', desc: 'Cancel from full list (use with --all view)'
    option :debug, type: :boolean, desc: 'Show debug output'
    def cancel(index)
      # Use HTTP mode for cancellation (works reliably)
      client = Client.new(debug: options[:debug])

      say 'Fetching reservations...', :cyan
      results = client.reservations

      # Apply same filter as reservations command
      unless options[:all]
        results = results.select { |r| r[:member].nil? }
        if results.empty?
          say 'You have no reservations to cancel.', :yellow
          say "Use 'truenorth cancel INDEX --all' to cancel family members' reservations", :cyan
          exit 1
        end
      end

      idx = index.to_i - 1
      if idx < 0 || idx >= results.length
        filter_note = options[:all] ? '' : ' (your reservations only)'
        say "Invalid index. Must be between 1 and #{results.length}#{filter_note}", :red
        exit 1
      end

      reservation = results[idx]
      unless reservation[:cancel_id]
        say 'This reservation cannot be cancelled (no cancel button found)', :red
        exit 1
      end

      say "\nCancelling:", :cyan
      say "  #{format_reservation_line(reservation)}"

      result = client.cancel(reservation[:cancel_id], dry_run: options[:dry_run])

      if result[:success]
        if result[:dry_run]
          say "\nDry run successful - would cancel this reservation", :yellow
        else
          say "\n✓ Reservation cancelled!", :green
        end
      else
        say "\nFailed: #{result[:error]}", :red
        exit 1
      end
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

    def show_nearby_availability(client, date, requested_time, activity)
      say "\nChecking available times for #{date}...", :cyan

      begin
        result = client.availability(date, activity: activity)

        if result[:slots].empty?
          say "No #{activity} slots available on #{date}", :yellow
        else
          say "\nAvailable #{activity} times:", :green

          # Parse requested time to find nearby slots
          requested_hour = parse_time_to_minutes(requested_time)

          # Sort slots by proximity to requested time
          sorted_slots = result[:slots].sort_by do |time_str, _courts|
            slot_minutes = parse_time_to_minutes(time_str)
            (slot_minutes - requested_hour).abs
          end

          # Show up to 10 nearest slots
          sorted_slots.first(10).each do |time_str, courts|
            say "  #{time_str}: #{courts.join(', ')}"
          end

          if result[:slots].length > 10
            say "\n  ... and #{result[:slots].length - 10} more times", :cyan
          end
        end
      rescue Error => e
        say "Could not fetch availability: #{e.message}", :yellow
      end
    end

    def parse_time_to_minutes(time_str)
      # Convert "10:00 AM" or "10am" to minutes since midnight
      if time_str =~ /(\d{1,2}):?(\d{2})?\s*(am|pm)/i
        hour = ::Regexp.last_match(1).to_i
        minute = ::Regexp.last_match(2)&.to_i || 0
        period = ::Regexp.last_match(3).upcase

        hour = 0 if hour == 12 && period == 'AM'
        hour += 12 if period == 'PM' && hour != 12

        hour * 60 + minute
      else
        0
      end
    end

    def display_reservations_table(results)
      # Get terminal width
      term_width = begin
                     IO.console.winsize[1]
                   rescue StandardError
                     120
                   end

      # Fixed column widths
      col_idx = 4      # Index column
      col_date = 6     # Date column (MM-DD)
      col_time = 16    # Time column (HH:MM (XXXmin))
      col_court = 18   # Court/Location column
      col_member = 17  # Member column
      fixed_width = col_idx + col_date + col_time + col_court + col_member + 12  # +12 for padding/borders

      # Activity column gets remaining space
      col_activity = [term_width - fixed_width, 15].max

      # Prepare table data
      rows = results.each_with_index.map do |res, idx|
        member_display = if res[:member].nil?
                           '● You'
                         else
                           "  #{truncate_text(res[:member], col_member - 2)}"
                         end

        [
          (idx + 1).to_s,
          format_compact_date(res[:date]),
          format_compact_time(res[:time]),
          truncate_text(res[:activity] || '', col_activity),
          truncate_text(res[:court] || '', col_court),
          member_display
        ]
      end

      # Create table
      table = TTY::Table.new(
        header: ['#', 'Date', 'Time', 'Activity', 'Court', 'Member'],
        rows: rows
      )

      # Render with unicode for full width
      renderer = :unicode
      puts table.render(renderer, padding: [0, 1], width: term_width)
    end

    def format_reservation_line(res)
      member = res[:member] || 'You'
      "#{format_compact_date(res[:date])} #{format_compact_time(res[:time])} - #{res[:activity]} - #{member}"
    end

    def format_compact_date(date_str)
      # Convert "02/11/2026" to "02-11"
      return '' unless date_str

      date = Date.strptime(date_str, '%m/%d/%Y')
      date.strftime('%m-%d')
    rescue StandardError
      date_str
    end

    def format_compact_time(time_str)
      # Convert "09:00 AM - 09:45 AM" to "09:00 (45min)"
      return '' unless time_str

      times = time_str.scan(/(\d{1,2}):(\d{2})\s*([AP]M)/)
      return time_str if times.length < 2

      start_h, start_m, start_period = times[0]
      end_h, end_m, end_period = times[1]

      # Convert to 24h format for calculation
      start_24h = start_h.to_i
      start_24h += 12 if start_period == 'PM' && start_24h != 12
      start_24h = 0 if start_period == 'AM' && start_24h == 12

      end_24h = end_h.to_i
      end_24h += 12 if end_period == 'PM' && end_24h != 12
      end_24h = 0 if end_period == 'AM' && end_24h == 12

      # Calculate duration in minutes
      duration = (end_24h * 60 + end_m.to_i) - (start_24h * 60 + start_m.to_i)

      "#{start_h.rjust(2, '0')}:#{start_m} (#{duration}min)"
    rescue StandardError
      time_str
    end

    def truncate_text(text, max_length)
      return '' unless text
      return text if text.length <= max_length

      "#{text[0...max_length - 1]}…"
    end

    def parse_booking_request(input, date_option, activity_option)
      # Extract activity if mentioned (squash, golf, music, room)
      activity = activity_option
      if input =~ /\b(squash|golf|music|room)\b/i
        activity = ::Regexp.last_match(1).downcase
        input = input.gsub(/\b(squash|golf|music|room)\b/i, '').strip
      end

      # Extract date if present
      date = nil
      input_lower = input.downcase

      # Try patterns like "feb 15", "february 15th", "2/15"
      if input_lower =~ /\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+(\d{1,2})(st|nd|rd|th)?\b/i
        month_str = ::Regexp.last_match(1)
        day = ::Regexp.last_match(2).to_i

        month_map = {
          'jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4,
          'may' => 5, 'jun' => 6, 'jul' => 7, 'aug' => 8,
          'sep' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12
        }

        month = month_map[month_str[0..2].downcase]
        year = Date.today.year
        year += 1 if month && month < Date.today.month # Next year if month has passed

        date = Date.new(year, month, day) if month
        input = input.gsub(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+(\d{1,2})(st|nd|rd|th)?\b/i, '').strip
      elsif input =~ %r{\b(\d{1,2})/(\d{1,2})\b}
        month = ::Regexp.last_match(1).to_i
        day = ::Regexp.last_match(2).to_i
        year = Date.today.year
        date = Date.new(year, month, day)
        input = input.gsub(%r{\b\d{1,2}/\d{1,2}\b}, '').strip
      end

      # Remove day names (monday, tuesday, etc.)
      input = input.gsub(/\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/i, '').strip

      # Extract time - look for patterns like "10am", "10:00am", "10:00 AM", "10"
      time = nil
      if input =~ /\b(\d{1,2})(:(\d{2}))?\s*(am|pm)?\b/i
        hour = ::Regexp.last_match(1).to_i
        minute = ::Regexp.last_match(3) || '00'
        period = ::Regexp.last_match(4) || (hour < 8 ? 'PM' : 'AM')

        time = "#{hour}:#{minute} #{period.upcase}"
      end

      # Use provided date option if date wasn't extracted
      date ||= parse_date(date_option)

      # If no time found, use the remaining input as-is
      time ||= input.strip

      { date: date, time: time, activity: activity }
    end

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
