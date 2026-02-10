# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'nokogiri'
require 'json'
require 'base64'
require 'date'

module Truenorth
  # HTTP client for NorthStar facility booking systems
  # Handles Liferay portal authentication and PrimeFaces form submissions
  class Client
    LOGIN_PATH = '/en/web/pages/login'
    BOOKING_PATH = '/group/pages/facility-booking'
    RESERVATIONS_PATH = '/group/pages/my-reservations'

    # Use a desktop user agent - server may detect mobile based on UA
    USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' \
                 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

    # Activity type IDs
    ACTIVITIES = {
      'golf' => '4',
      'squash' => '5',
      'music' => '6',
      'room' => '8',
      'meeting' => '8'
    }.freeze

    # Court area IDs (from page column headers)
    COURTS = {
      '16' => 'Golf Simulator 1',
      '17' => 'Golf Simulator 2',
      '30' => 'Squash Court 1',
      '31' => 'Squash Court 2',
      '32' => 'Squash Court 3'
    }.freeze

    # Court IDs by activity
    COURT_IDS_BY_ACTIVITY = {
      'squash' => %w[30 31 32],
      'golf' => %w[16 17],
      'music' => %w[16 17],    # May need to update these
      'room' => %w[30 31 32],  # May need to update these
      'meeting' => %w[30 31 32]
    }.freeze

    attr_reader :cookies, :debug_log, :logged_in

    def initialize(base_url: nil, debug: false)
      @base_url = base_url || Config.base_url
      raise Error, 'No base URL configured. Run: truenorth configure' unless @base_url

      @cookies = Config.cookies || {}
      @debug = debug
      @debug_log = StringIO.new
      @logged_in = !@cookies.empty?  # If we have cookies, will verify on first use
      @last_verified_response = nil

      log "Loaded #{@cookies.length} cookies from cache" if @logged_in && @debug
    end

    # Login to the booking system
    def login(username = nil, password = nil)
      username ||= Config.username
      password ||= Config.password

      raise AuthenticationError, 'No credentials configured. Run: truenorth configure' unless username && password

      log '=== LOGIN ==='
      response = get(LOGIN_PATH)
      raise AuthenticationError, "Failed to fetch login page: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      html = Nokogiri::HTML(response.body)
      form = html.at_css('form[id*="LoginPortlet_loginForm"]')
      raise AuthenticationError, 'Login form not found' unless form

      action_url = form['action']
      p_auth = action_url[/p_auth=([^&]+)/, 1]

      form_date = html.at_css('input[name*="formDate"]')&.[]('value')
      save_last_path = html.at_css('input[name*="saveLastPath"]')&.[]('value') || 'false'
      redirect = html.at_css('input[name*="redirect"]')&.[]('value') || ''
      do_action = html.at_css('input[name*="doActionAfterLogin"]')&.[]('value') || 'false'
      checkbox_names = html.at_css('input[name*="checkboxNames"]')&.[]('value') || 'rememberMe,showPassword'

      # Liferay encodes password client-side with Base64
      encoded_password = Base64.strict_encode64(password)

      form_data = {
        '_com_liferay_login_web_portlet_LoginPortlet_formDate' => form_date,
        '_com_liferay_login_web_portlet_LoginPortlet_saveLastPath' => save_last_path,
        '_com_liferay_login_web_portlet_LoginPortlet_redirect' => redirect,
        '_com_liferay_login_web_portlet_LoginPortlet_doActionAfterLogin' => do_action,
        '_com_liferay_login_web_portlet_LoginPortlet_login' => username,
        '_com_liferay_login_web_portlet_LoginPortlet_password' => encoded_password,
        '_com_liferay_login_web_portlet_LoginPortlet_checkboxNames' => checkbox_names,
        'p_auth' => p_auth
      }

      response = post(action_url, form_data, follow_redirects: true)

      if response.body.include?('Sign Out') || response.body.include?('My Reservations')
        @logged_in = true
        Config.save_cookies(@cookies)
        log 'Login successful (cookies saved)'
        true
      else
        html = Nokogiri::HTML(response.body)
        error = html.at_css('.alert-error, .portlet-msg-error, .has-error')
        raise AuthenticationError, error&.text&.strip || 'Login failed'
      end
    end

    # Get available slots for a given date and activity
    def availability(date, activity: 'squash')
      ensure_logged_in!

      log "\n=== GET AVAILABILITY ==="
      log "Date: #{date}, Activity: #{activity}"

      response = get(BOOKING_PATH)
      html = Nokogiri::HTML(response.body)

      # Navigate to the requested date first if needed
      current_date = html.at_css('input[name*="sheetDate"]')&.[]('value')
      requested_date = date.strftime('%m/%d/%Y')
      activity_id = ACTIVITIES[activity.to_s.downcase] || '5'

      if current_date != requested_date
        log "Navigating from #{current_date} to #{requested_date}"
        html = change_date(html, requested_date, activity_id)
      end

      # Then change activity type - this should now return slots for the correct date
      current_activity = html.at_css('input[name*="activityId"]')&.[]('value')

      if current_activity && current_activity != activity_id
        log "Changing activity from #{current_activity} to #{activity_id}"
        html = change_activity(html, activity_id)
      end

      # Debug: Save HTML after activity change
      if @debug
        debug_file = "/tmp/truenorth_after_activity_#{Time.now.to_i}.html"
        File.write(debug_file, html.to_s)
        log "Saved HTML after activity change to: #{debug_file}"
      end

      # Court dropdown not available in HTML response - use hardcoded IDs
      court_ids = COURT_IDS_BY_ACTIVITY[activity.to_s.downcase] || []

      if court_ids.length >= 3
        log "Querying #{court_ids.length} courts individually (IDs: #{court_ids.join(', ')})"
        all_slots = {}

        court_ids.each do |court_id|
          court_name = COURTS[court_id] || "Court #{court_id}"
          log "Querying #{court_name} (ID: #{court_id})"

          # Set activityAreaId and refresh
          form_id = extract_form_id(html)
          view_state = extract_view_state(html)
          form_fields = extract_all_form_fields(html, form_id)
          form_fields["#{form_id}:activityAreaId"] = court_id

          # Make AJAX request to update table for this court
          result = change_date_ajax(form_id, view_state, requested_date, form_fields)
          if result[:success]
            court_html = Nokogiri::HTML(result[:body].scan(/<!\[CDATA\[(.*?)\]\]>/m).flatten.join("\n"))
            court_slots = parse_slots(court_html)

            # Merge slots
            court_slots.each do |time, courts|
              all_slots[time] ||= []
              all_slots[time].concat(courts)
              all_slots[time].uniq!
            end
          end
        end

        slots = all_slots
        log "Combined #{slots.count} time slots from all courts"
      else
        # Fallback to original parsing
        slots = parse_slots(html)
        log "Found #{slots.count} available time slots"
      end

      {
        success: true,
        date: date.to_s,
        activity: activity,
        slots: slots
      }
    end


    # Book a slot
    # If slot_info is provided, it should have: { area_id:, start_time:, end_time:, court: }
    def book(time, date: Date.today, court: nil, activity: 'squash', dry_run: false, slot_info: nil)
      ensure_logged_in!

      log "\n=== BOOK SLOT ==="
      log "Time: #{time}, Date: #{date}, Court: #{court || 'any'}, Activity: #{activity}"
      log 'DRY RUN MODE' if dry_run

      response = get(BOOKING_PATH)
      html = Nokogiri::HTML(response.body)

      view_state = extract_view_state(html)
      form_id = extract_form_id(html)
      components = extract_primefaces_components(html)
      form_fields = extract_all_form_fields(html, form_id)

      raise BookingError, 'Could not extract form state' unless view_state && form_id

      # Navigate to the requested date if needed
      activity_id = ACTIVITIES[activity.to_s.downcase] || '5'
      current_date = html.at_css('input[name*="sheetDate"]')&.[]('value')
      requested_date = date.strftime('%m/%d/%Y')

      if current_date != requested_date
        log "Navigating from #{current_date} to #{requested_date}"
        html = change_date(html, requested_date, activity_id)
        view_state = extract_view_state(html) || view_state
        form_id = extract_form_id(html) || form_id
        components = extract_primefaces_components(html)
        form_fields = extract_all_form_fields(html, form_id)
      end

      # Change activity if needed
      current_activity = form_fields["#{form_id}:activityId"]

      if current_activity != activity_id
        log "Changing activity from #{current_activity} to #{activity_id}"
        result = change_activity_ajax(form_id, view_state, activity_id, form_fields, components)
        raise BookingError, 'Failed to change activity type' unless result[:success]

        view_state = result[:view_state] || view_state
        html = Nokogiri::HTML(result[:body]) if result[:body]
        form_fields = extract_all_form_fields(html, form_id)
      end

      # Find the slot (or use provided slot_info)
      if slot_info
        log "Using provided slot info: #{slot_info[:court]} at #{slot_info[:start_time]}"
        # Convert slot_info keys from symbols if needed and ensure we have an id
        slot = {
          id: nil,  # We'll generate this or it's not needed for AJAX
          area_id: slot_info[:area_id],
          court: slot_info[:court],
          start_time: slot_info[:start_time] || slot_info[:time],
          end_time: slot_info[:end_time]
        }
      else
        slot = find_slot(html, time, court)
        raise BookingError, "No slot available at #{time}" unless slot
        log "Found slot: #{slot[:court]} at #{slot[:start_time]}"
      end

      # Select slot via AJAX
      select_result = select_slot_ajax(form_id, view_state, slot, components, form_fields)
      raise BookingError, 'Failed to select slot' unless select_result[:success]

      new_view_state = select_result[:view_state] || view_state
      new_components = select_result[:components] || components
      dialog_fields = extract_fields_from_ajax_response(select_result[:body], form_id) if select_result[:body]

      if dry_run
        return {
          success: true,
          dry_run: true,
          court: slot[:court],
          time: "#{slot[:start_time]} - #{slot[:end_time]}",
          message: 'Dry run completed - booking dialog opened successfully'
        }
      end

      # Save the booking
      save_result = save_booking_ajax(form_id, new_view_state, slot, new_components, dialog_fields)

      if save_result[:success]
        {
          success: true,
          court: slot[:court],
          time: "#{slot[:start_time]} - #{slot[:end_time]}",
          confirmation: save_result[:confirmation]
        }
      else
        raise BookingError, save_result[:error] || 'Booking failed'
      end
    end

    # Get current reservations
    def reservations
      ensure_logged_in!

      log "\n=== GET RESERVATIONS ==="

      # Reuse the response from session verification if available
      response = @last_verified_response || get(RESERVATIONS_PATH)
      @last_verified_response = nil
      html = Nokogiri::HTML(response.body)

      reservations = []

      # Remove script tags to avoid JavaScript in text extraction
      html.css('script').remove

      # Reservations are grouped by member in dt.ui-datalist-item elements
      html.css('dt.ui-datalist-item').each_with_index do |member_section, member_idx|
        # Extract member name from the header
        # Format: "Siegel, Jonathan's Reservations (50)" or "My Reservations(5)"
        header_text = member_section.text.gsub(/\s+/, ' ').strip
        member_match = header_text.match(/^(.+?)'s Reservations/)
        member_name = if member_match
                        member_match[1].strip
                      elsif header_text.start_with?('My Reservations')
                        nil  # nil means it's the logged-in user
                      end

        # Now find all tables within this member section
        member_section.css('table tbody tr').each_with_index do |row, row_idx|
          cells = row.css('td')
          next if cells.length < 2

          # Extract text and clean it
          text_parts = cells.map { |cell| clean_cell_text(cell) }
          next if text_parts.all?(&:empty?)

          # Find the cancel button link (title="Cancel Reservation")
          cancel_link = row.at_css('a[title="Cancel Reservation"]')
          cancel_id = cancel_link['id'] if cancel_link

          # Parse the reservation data
          reservation = parse_reservation_row(text_parts)
          if reservation && reservation[:date]
            reservation[:member] = member_name
            reservation[:member_idx] = member_idx
            reservation[:row_idx] = row_idx
            reservation[:cancel_id] = cancel_id
            reservations << reservation
          end
        end
      end

      log "Found #{reservations.count} reservations"

      # Sort by date
      reservations.sort_by! do |res|
        Date.strptime(res[:date], '%m/%d/%Y') rescue Date.today
      end

      reservations
    end

    # Cancel a reservation
    # reservation_id is the cancel button ID from the reservation
    def cancel(reservation_id, dry_run: false)
      ensure_logged_in!

      log "\n=== CANCEL RESERVATION ==="
      log "Cancel ID: #{reservation_id}"
      log 'DRY RUN MODE' if dry_run

      return { success: true, dry_run: true, message: 'Dry run - would cancel reservation' } if dry_run

      # Get the reservations page to extract form state
      response = get(RESERVATIONS_PATH)
      html = Nokogiri::HTML(response.body)

      view_state = extract_view_state(html)
      form_id = '_memberReservations_WAR_northstarportlet_:reservationsForm'

      raise BookingError, 'Could not extract view state' unless view_state

      # Step 1: Click the cancel button to open the confirmation dialog
      # The dialog button will be enabled in the AJAX response
      ajax_url = "#{@base_url}#{RESERVATIONS_PATH}?p_p_id=memberReservations_WAR_northstarportlet" \
                 '&p_p_lifecycle=2&p_p_state=normal&p_p_mode=view' \
                 '&p_p_cacheability=cacheLevelPage' \
                 '&_memberReservations_WAR_northstarportlet__jsfBridgeAjax=true'

      form_data = {
        'javax.faces.partial.ajax' => 'true',
        'javax.faces.source' => reservation_id,
        'javax.faces.partial.execute' => '@all',
        'javax.faces.partial.render' => form_id,
        form_id => form_id,
        'javax.faces.ViewState' => view_state,
        reservation_id => reservation_id
      }

      response = post_ajax(ajax_url, form_data)

      unless response.is_a?(Net::HTTPSuccess)
        return { success: false, error: "HTTP #{response.code}" }
      end

      body = response.body
      log "Step 1 response length: #{body.length}"

      # Check if a confirmation dialog was opened
      if body.include?("PF('cancelReservationDialog').show()") || body.include?('.show()')
        log "Confirmation dialog opened"

        # Extract the updated ViewState from the AJAX response
        new_view_state = extract_view_state_from_ajax(body) || view_state

        # Parse the AJAX response to find the enabled YES button
        response_html = Nokogiri::HTML(body)

        # Look for the YES button in the dialog (not in the reservation list!)
        # The YES button has specific characteristics:
        # 1. Contains text "YES"
        # 2. Has class "ui-area-btn-danger"
        # 3. Is inside the cancel dialog (j_idt274)
        confirm_button = response_html.css('div[id*="j_idt274"] a.ui-area-btn-danger').find do |link|
          link.text.strip.upcase.include?('YES')
        end

        # Fallback: look for any YES button with the right classes
        unless confirm_button
          confirm_button = response_html.css('a.ui-commandlink').find do |link|
            link_text = link.text.strip.upcase
            link_class = link['class'].to_s
            link_text == 'YES' && link_class.include?('ui-area-btn-danger') &&
              !link_class.include?('disabled')
          end
        end

        unless confirm_button
          log "Could not find enabled YES button in response"
          log "Response preview: #{body[0..2000]}"
          return { success: false, error: 'Could not find confirmation button' }
        end

        confirm_button_id = confirm_button['id']
        log "Found confirmation button in response: #{confirm_button_id}"

        # Step 2: Click the "Yes" button to actually cancel
        confirm_data = {
          'javax.faces.partial.ajax' => 'true',
          'javax.faces.source' => confirm_button_id,
          'javax.faces.partial.execute' => '@all',
          'javax.faces.partial.render' => form_id,
          form_id => form_id,
          'javax.faces.ViewState' => new_view_state,
          confirm_button_id => confirm_button_id
        }

        log "Clicking confirmation button: #{confirm_button_id}"
        confirm_response = post_ajax(ajax_url, confirm_data)

        if confirm_response.is_a?(Net::HTTPSuccess)
          confirm_body = confirm_response.body
          log "Step 2 response length: #{confirm_body.length}"
          log "Step 2 response preview: #{confirm_body[0..500]}"

          # Check for success indicators
          if confirm_body =~ /cancelled.*successfully/i ||
             confirm_body =~ /reservation.*cancelled/i ||
             confirm_body =~ /successfully.*cancelled/i ||
             confirm_body.include?('growl') ||
             confirm_body.length < 1000
            log 'Cancellation confirmed successfully'
            { success: true, message: 'Reservation cancelled' }
          else
            log "Warning: Uncertain confirmation response"
            { success: true, message: 'Cancellation likely succeeded (please verify)' }
          end
        else
          { success: false, error: "Confirmation failed: HTTP #{confirm_response.code}" }
        end
      else
        # No dialog - check if it was directly cancelled
        log "No confirmation dialog detected"

        if body =~ /cancelled.*successfully/i ||
           body =~ /reservation.*cancelled/i ||
           body.length < 500
          log 'Direct cancellation successful'
          { success: true, message: 'Reservation cancelled' }
        else
          log "Uncertain result (#{body.length} bytes)"
          { success: false, error: 'Uncertain if cancellation succeeded - please verify' }
        end
      end
    end

    private

    def ensure_logged_in!
      if @logged_in
        # Verify cached session is still valid with a lightweight check
        response = get(RESERVATIONS_PATH)
        if authenticated_response?(response)
          @last_verified_response = response
          return
        end

        # Session expired - clear stale state and re-login
        log 'Session expired, re-authenticating...'
        @logged_in = false
        @cookies = {}
      end

      login
    end

    # Check if a response is from an authenticated session (not a login page)
    def authenticated_response?(response)
      return false unless response.is_a?(Net::HTTPSuccess)

      body = response.body
      !body.include?('LoginPortlet') && body.include?('Sign Out')
    end

    def parse_slots(html)
      slots = {}

      # Debug: Count total columns found
      headers = html.css('thead th[role="columnheader"]')
      log "Found #{headers.length} column headers: #{headers.map { |h| h['aria-label'] }.join(', ')}"

      # Debug: Count slots by area-id
      area_counts = Hash.new(0)
      html.css('td.slot div[data-start-time]').each do |div|
        area_id = div['data-area-id']
        area_counts[area_id] += 1
      end
      log "Slots by area ID: #{area_counts.inspect}"

      # Find ALL slots with data-start-time
      html.css('td.slot div[data-start-time]').each do |div|
        td = div.parent
        while td && td.name != 'td'
          td = td.parent
        end
        next unless td

        classes = td['class'].to_s

        # Skip definitively unavailable slots
        next if classes.include?('reserved')
        next if classes.include?('restrict')
        next if classes.include?('blocked')

        # Include ANY slot that's marked as "open", even if it has past-time
        # The website shows past-time slots for future dates as bookable
        if classes.include?('open')
          start_time = div['data-start-time']
          area_id = div['data-area-id']
          court_name = COURTS[area_id] || "Court #{area_id}"

          slots[start_time] ||= []
          slots[start_time] << court_name unless slots[start_time].include?(court_name)
        end
      end

      # If we found very few slots, be more aggressive
      if slots.length < 10
        log "Found only #{slots.length} slots with strict parsing, trying relaxed parsing..."

        # Try including ALL non-reserved slots
        html.css('td.slot div[data-start-time]').each do |div|
          td = div.parent
          while td && td.name != 'td'
            td = td.parent
          end
          next unless td

          classes = td['class'].to_s
          # Only skip if explicitly reserved/restricted/blocked
          next if classes.include?('reserved') && !classes.include?('open')
          next if classes.include?('restrict')
          next if classes.include?('blocked')

          start_time = div['data-start-time']
          area_id = div['data-area-id']
          court_name = COURTS[area_id] || "Court #{area_id}"

          slots[start_time] ||= []
          slots[start_time] << court_name unless slots[start_time].include?(court_name)
        end
      end

      slots
    end

    def find_slot(html, target_time, preferred_court = nil)
      target_normalized = normalize_time(target_time)

      html.css('td.slot.open div[data-start-time]').each do |div|
        slot_time = normalize_time(div['data-start-time'])
        next unless slot_time == target_normalized

        area_id = div['data-area-id']
        court_name = COURTS[area_id] || "Court #{area_id}"

        next if preferred_court && !court_name.downcase.include?(preferred_court.downcase)

        return {
          id: div['id'],
          area_id: area_id,
          court: court_name,
          start_time: div['data-start-time'],
          end_time: div['data-end-time']
        }
      end

      nil
    end

    def normalize_time(time_str)
      return nil unless time_str

      time_str.strip.gsub(/^0/, '').upcase
    end

    def clean_cell_text(cell)
      # Remove script tags first
      cell_copy = cell.dup
      cell_copy.css('script').remove

      # Get text and clean it
      text = cell_copy.text

      # Remove JavaScript function calls and parameters
      text = text.gsub(/\$\(function\(\)\{.*?\}\);?/m, '')
      text = text.gsub(/PrimeFaces\.cw\([^)]+\);?/m, '')

      # Clean up whitespace
      text = text.gsub(/\s+/, ' ').strip

      text
    end

    def parse_reservation_row(text_parts)
      # The format is:
      # Cell 0: "Event scheduled On Dates:..."
      # Cell 1: "Activities (Court 2 | Squash) MM/DD/YYYY HH:MM AM - HH:MM AM"
      # Cell 2: Date

      return nil if text_parts.length < 2

      # Parse cell 1 which has the activity and time info
      cell1 = text_parts[1]

      # Extract activity/event type and details
      # Format: "Activities (Court 2 | Squash)" or "Events (Event Name (time) | Category)"
      # Use a greedy match that stops before the date pattern
      activity_match = cell1.match(/(Activities|Events)\s+\((.+?)\)\s*\d{2}\/\d{2}\/\d{4}/)
      activity = nil
      court = nil

      if activity_match
        activity_full = activity_match[2]
        # Parse "Court 2 | Squash" or "Event Name | Category"
        if activity_full.include?('|')
          parts = activity_full.split('|').map(&:strip)
          if parts[0] =~ /Court|Training|Room/
            court = parts[0]
            activity = parts[1]
          else
            activity = parts[0]
            court = parts[1] if parts[1]
          end
        else
          activity = activity_full
        end
      end

      # Extract dates in MM/DD/YYYY format from cell1
      dates = cell1.scan(/\b(\d{2}\/\d{2}\/\d{4})\b/).flatten

      # Extract times in HH:MM AM/PM format from cell1
      times = cell1.scan(/(\d{1,2}:\d{2}\s+[AP]M)/).flatten

      return nil if dates.empty?

      # Take the first date and construct time range
      date = dates.first
      time = if times.length >= 2
               "#{times[0]} - #{times[1]}"
             elsif times.length == 1
               times[0]
             end

      {
        date: date,
        time: time,
        activity: activity,
        court: court
      }
    end

    def change_activity(html, activity_id)
      form_id = extract_form_id(html)
      view_state = extract_view_state(html)
      components = extract_primefaces_components(html)
      form_fields = extract_all_form_fields(html, form_id)

      result = change_activity_ajax(form_id, view_state, activity_id, form_fields, components)
      return html unless result[:success]

      # Parse the response and check for Court 3
      parsed = Nokogiri::HTML(result[:body])
      court3_elements = parsed.css('th[aria-label*="Court 3"], div[data-area-id="18"], div[data-area-id="32"]')
      log "After change_activity: Found #{court3_elements.length} Court 3 elements in response"

      parsed
    end

    def change_court_dropdown(html, court_id)
      form_id = extract_form_id(html)
      view_state = extract_view_state(html)
      form_fields = extract_all_form_fields(html, form_id)

      # Find the court dropdown field dynamically (in .activity-areas div)
      court_dropdown = html.at_css('.activity-areas select, div[class*="area"] select[id*="j_idt"]')
      return html unless court_dropdown

      dropdown_id = court_dropdown['id']
      dropdown_source = dropdown_id.gsub(/_input$/, '')

      result = change_court_dropdown_ajax(form_id, view_state, court_id, dropdown_id, dropdown_source, form_fields)
      return html unless result[:success]

      # Parse CDATA content from response
      cdata_content = result[:body].scan(/<!\[CDATA\[(.*?)\]\]>/m).flatten.join("\n")
      if !cdata_content.empty?
        cdata_html = Nokogiri::HTML(cdata_content)
        slots = cdata_html.css('div[data-start-time]')
        log "Court #{court_id}: Found #{slots.length} slots in CDATA response"
        return cdata_html if slots.length > 0
      end

      Nokogiri::HTML(result[:body])
    end

    def change_court_area(html, area_id)
      form_id = extract_form_id(html)
      view_state = extract_view_state(html)
      form_fields = extract_all_form_fields(html, form_id)

      result = change_court_area_ajax(form_id, view_state, area_id, form_fields)
      return html unless result[:success]

      # Debug: Check response
      parsed = Nokogiri::HTML(result[:body])
      slot_divs = parsed.css('div[data-start-time]')
      log "Court area #{area_id} response: #{slot_divs.length} slot divs found"

      # Also check CDATA content
      cdata_content = result[:body].scan(/<!\[CDATA\[(.*?)\]\]>/m).flatten.join("\n")
      if !cdata_content.empty?
        cdata_html = Nokogiri::HTML(cdata_content)
        cdata_slots = cdata_html.css('div[data-start-time]')
        log "Court area #{area_id} CDATA: #{cdata_slots.length} slot divs in CDATA"
        return cdata_html if cdata_slots.length > 0
      end

      parsed
    end

    def change_date(html, date_str, activity_id = nil)
      # Extract what we can from the HTML
      form_id = extract_form_id(html)
      view_state = extract_view_state(html)

      # Build minimal form data manually to avoid extraction issues
      form_data = build_minimal_form_data(html, form_id, activity_id)

      result = change_date_ajax(form_id, view_state, date_str, form_data)
      return html unless result[:success]

      # Parse the AJAX response
      ajax_body = result[:body]
      cdata_content = ajax_body.scan(/<!\[CDATA\[(.*?)\]\]>/m).flatten.join("\n")

      if !cdata_content.empty? && cdata_content.include?('slot')
        parsed_html = Nokogiri::HTML(cdata_content)

        # Debug: Check if Court 3 is in the response
        court3_headers = parsed_html.css('th[aria-label*="Court 3"]')
        log "Court 3 headers found in AJAX response: #{court3_headers.length}"

        # Debug: Check for area ID 18 or 32 (Court 3 IDs)
        court3_slots = parsed_html.css('div[data-area-id="18"], div[data-area-id="32"]')
        log "Court 3 slots (area 18/32) found in AJAX response: #{court3_slots.length}"

        parsed_html
      else
        html
      end
    end

    def build_minimal_form_data(html, form_id, activity_id)
      # Build the minimum required form data from scratch
      # Only extract the fields we absolutely need
      data = {}

      # Try to find the form
      form = html.at_css("form[id='#{form_id}']")
      return data unless form

      # Extract only the essential hidden fields
      form.css('input[type="hidden"]').each do |input|
        name = input['name']
        value = input['value']
        next unless name

        # Only keep fields that belong to our form
        if name.to_s.start_with?(form_id)
          data[name] = value || ''
        end
      end

      # Override activity ID if provided
      if activity_id
        data["#{form_id}:activityId"] = activity_id.to_s
        data["#{form_id}:j_idt51_input"] = activity_id.to_s
      end

      data
    end

    def extract_view_state(html)
      html.at_css('input[name="javax.faces.ViewState"]')&.[]('value')
    end

    def extract_form_id(html)
      html.at_css('form[id*="activityForm"]')&.[]('id')
    end

    def extract_primefaces_components(html)
      components = {}
      page_source = html.to_s

      page_source.scan(/rc_(\w+)\s*=\s*function\(\)\s*\{PrimeFaces\.ab\(\{s:"([^"]+)"/) do |match|
        components[match[0]] = match[1]
      end

      if (save_match = page_source.match(/id="([^"]*j_idt\d+)"[^>]*class="[^"]*btn-save/))
        components['saveButton'] = save_match[1]
      end

      components
    end

    def extract_all_form_fields(html, form_id)
      form = html.at_css("form[id='#{form_id}']")
      return {} unless form

      fields = {}
      form.css('input').each do |input|
        fields[input['name']] = input['value'] || '' if input['name']
      end
      form.css('select').each do |select|
        next unless select['name']

        selected = select.at_css('option[selected]')
        fields[select['name']] = selected['value'] if selected

        # Debug: Log select options
        if select['name']&.include?('area') || select['name']&.include?('court') || select['name']&.include?('trainer')
          options = select.css('option').map { |opt| "#{opt.text.strip}=#{opt['value']}" }
          log "Found selector #{select['name']}: #{options.join(', ')}"
        end
      end

      # Force parameters to get all courts
      fields["#{form_id}:mobileViewDisplay"] = '0'  # 0 = full view

      # Debug: Log all field names and key values
      log "Form fields: #{fields.keys.join(', ')}"
      log "activityAreaId current value: #{fields["#{form_id}:activityAreaId"]}"
      log "showAllAreasOrTrainers: #{fields["#{form_id}:showAllAreasOrTrainers"]}"

      fields
    end

    def extract_fields_from_ajax_response(response_body, _form_id)
      fields = {}
      response_body.scan(/<update[^>]*>\s*<!\[CDATA\[(.*?)\]\]>/m) do |match|
        html = Nokogiri::HTML::DocumentFragment.parse(match[0])
        html.css('input').each do |input|
          fields[input['name']] = input['value'] || '' if input['name']
        end
        html.css('select').each do |select|
          next unless select['name']

          selected = select.at_css('option[selected]')
          fields[select['name']] = selected['value'] if selected
        end
      end
      fields
    end

    def change_activity_ajax(form_id, view_state, activity_id, form_fields, _components)
      activity_dropdown = "#{form_id}:j_idt57"
      ajax_url = build_ajax_url
      encoded_url = URI.encode_www_form_component(ajax_url)

      form_data = form_fields.dup
      form_data["#{form_id}:j_idt51_input"] = activity_id
      form_data["#{form_id}:activityId"] = activity_id
      form_data["#{form_id}:showAllAreasOrTrainers"] = 'true'  # Show all courts!

      # Debug: Log what we're sending
      log "Sending to #{form_id}:showAllAreasOrTrainers = #{form_data["#{form_id}:showAllAreasOrTrainers"]}"
      log "Sending to #{form_id}:mobileViewDisplay = #{form_data["#{form_id}:mobileViewDisplay"]}"

      form_data.merge!(
        'javax.faces.partial.ajax' => 'true',
        'javax.faces.source' => activity_dropdown,
        'javax.faces.partial.execute' => activity_dropdown,
        'javax.faces.partial.render' => form_id,
        'javax.faces.behavior.event' => 'change',
        'javax.faces.partial.event' => 'change',
        form_id => form_id,
        'javax.faces.encodedURL' => encoded_url,
        'javax.faces.ViewState' => view_state
      )

      response = post_ajax(ajax_url, form_data)
      if response.is_a?(Net::HTTPSuccess)
        { success: true, view_state: extract_view_state_from_ajax(response.body), body: response.body }
      else
        { success: false, error: "HTTP #{response.code}" }
      end
    end

    def change_court_dropdown_ajax(form_id, view_state, court_id, dropdown_input_id, dropdown_source, form_fields)
      ajax_url = build_ajax_url
      encoded_url = URI.encode_www_form_component(ajax_url)

      form_data = form_fields.dup
      form_data[dropdown_input_id] = court_id
      form_data.merge!(
        'javax.faces.partial.ajax' => 'true',
        'javax.faces.source' => dropdown_source,
        'javax.faces.partial.execute' => dropdown_source,
        'javax.faces.partial.render' => form_id,
        'javax.faces.behavior.event' => 'change',
        'javax.faces.partial.event' => 'change',
        form_id => form_id,
        'javax.faces.encodedURL' => encoded_url,
        'javax.faces.ViewState' => view_state
      )

      response = post_ajax(ajax_url, form_data)
      if response.is_a?(Net::HTTPSuccess)
        { success: true, view_state: extract_view_state_from_ajax(response.body), body: response.body }
      else
        { success: false, error: "HTTP #{response.code}" }
      end
    end

    def change_court_area_ajax(form_id, view_state, area_id, form_fields)
      ajax_url = build_ajax_url
      encoded_url = URI.encode_www_form_component(ajax_url)

      form_data = form_fields.dup
      form_data["#{form_id}:activityAreaId"] = area_id
      form_data.merge!(
        'javax.faces.partial.ajax' => 'true',
        'javax.faces.source' => form_id,
        'javax.faces.partial.execute' => form_id,
        'javax.faces.partial.render' => form_id,
        form_id => form_id,
        'javax.faces.encodedURL' => encoded_url,
        'javax.faces.ViewState' => view_state
      )

      response = post_ajax(ajax_url, form_data)
      if response.is_a?(Net::HTTPSuccess)
        { success: true, view_state: extract_view_state_from_ajax(response.body), body: response.body }
      else
        { success: false, error: "HTTP #{response.code}" }
      end
    end

    def change_date_ajax(form_id, view_state, date_str, form_data)
      return { success: false, error: 'No form_id' } unless form_id

      date_picker = "#{form_id}:j_idt57"
      ajax_url = build_ajax_url
      encoded_url = URI.encode_www_form_component(ajax_url)

      # Use form_data as-is (already built correctly by build_minimal_form_data)
      # Just add our date values and AJAX control parameters
      form_data = form_data.dup
      form_data["#{form_id}:sheetDate"] = date_str
      form_data["#{form_id}:j_idt57_input"] = date_str
      form_data["#{form_id}:showAllAreasOrTrainers"] = 'true'  # Show all courts!

      form_data.merge!(
        'javax.faces.partial.ajax' => 'true',
        'javax.faces.source' => date_picker,
        'javax.faces.partial.execute' => date_picker,
        'javax.faces.partial.render' => form_id,
        'javax.faces.behavior.event' => 'dateSelect',
        'javax.faces.partial.event' => 'dateSelect',
        form_id => form_id,
        'javax.faces.encodedURL' => encoded_url,
        'javax.faces.ViewState' => view_state
      )

      response = post_ajax(ajax_url, form_data)
      if response.is_a?(Net::HTTPSuccess)
        { success: true, view_state: extract_view_state_from_ajax(response.body), body: response.body }
      else
        { success: false, error: "HTTP #{response.code}" }
      end
    end

    def select_slot_ajax(form_id, view_state, slot, components, form_fields)
      source_id = components['showReservationScreen'] || "#{form_id}:j_idt146"
      ajax_url = build_ajax_url
      encoded_url = URI.encode_www_form_component(ajax_url)

      form_data = form_fields.dup
      form_data.merge!(
        'javax.faces.partial.ajax' => 'true',
        'javax.faces.source' => source_id,
        'javax.faces.partial.execute' => '@all',
        'javax.faces.partial.render' => form_id,
        source_id => source_id,
        form_id => form_id,
        'javax.faces.encodedURL' => encoded_url,
        'javax.faces.ViewState' => view_state,
        'activityAreaId' => slot[:area_id],
        'startTime' => slot[:start_time],
        'endTime' => slot[:end_time]
      )

      response = post_ajax(ajax_url, form_data)
      if response.is_a?(Net::HTTPSuccess)
        new_components = extract_components_from_ajax(response.body)
        { success: true, view_state: extract_view_state_from_ajax(response.body), components: new_components, body: response.body }
      else
        { success: false, error: "HTTP #{response.code}" }
      end
    end

    def save_booking_ajax(form_id, view_state, slot, components, dialog_fields)
      save_button_id = components['saveButton'] || "#{form_id}:j_idt378"
      ajax_url = build_ajax_url
      encoded_url = URI.encode_www_form_component(ajax_url)

      form_data = (dialog_fields || {}).dup
      form_data["#{form_id}:selectedSlotId"] = slot[:id]
      form_data["#{form_id}:selectedAreaId"] = slot[:area_id]
      form_data["#{form_id}:selectedStartTime"] = slot[:start_time]
      form_data["#{form_id}:selectedEndTime"] = slot[:end_time]
      form_data.merge!(
        'javax.faces.partial.ajax' => 'true',
        'javax.faces.source' => save_button_id,
        'javax.faces.partial.execute' => '@all',
        'javax.faces.partial.render' => "#{form_id} #{form_id}:growl",
        save_button_id => save_button_id,
        form_id => form_id,
        'javax.faces.encodedURL' => encoded_url,
        'javax.faces.ViewState' => view_state
      )

      response = post_ajax(ajax_url, form_data)
      if response.is_a?(Net::HTTPSuccess)
        body = response.body
        body_lower = body.downcase

        # Check for explicit error indicators
        if body_lower.include?('error') || body_lower.include?('failed') ||
           body_lower.include?('unable') || body_lower.include?('invalid')
          log "Booking save returned error indicators in response"
          { success: false, error: 'Booking save failed' }
        # Check for success indicators OR assume success if reasonable response
        elsif body_lower.include?('success') || body_lower.include?('confirmed') ||
              body_lower.include?('booked') || body_lower.include?('reserved') ||
              (body.length < 5000 && !body_lower.include?('exception'))
          log "Booking save appears successful (HTTP 200)"
          { success: true, confirmation: 'Booking confirmed' }
        else
          log "Uncertain booking result, response length: #{body.length}"
          { success: false, error: 'No confirmation in response' }
        end
      else
        { success: false, error: "HTTP #{response.code}" }
      end
    end

    def extract_components_from_ajax(response_body)
      components = {}
      if (save_match = response_body.match(/id="([^"]+)"[^>]*class="[^"]*btn-save/))
        components['saveButton'] = save_match[1]
      end
      response_body.scan(/rc_(\w+)\s*=\s*function\(\)\s*\{PrimeFaces\.ab\(\{s:"([^"]+)"/) do |match|
        components[match[0]] = match[1]
      end
      components
    end

    def extract_view_state_from_ajax(response_body)
      match = response_body.match(/ViewState[^>]*>(?:<!\[CDATA\[)?([^<\]]+)/)
      match&.[](1)
    end

    def build_ajax_url
      "#{@base_url}#{BOOKING_PATH}?p_p_id=activities_WAR_northstarportlet" \
        '&p_p_lifecycle=2&p_p_state=normal&p_p_mode=view' \
        '&p_p_cacheability=cacheLevelPage&p_p_col_id=column-2' \
        '&p_p_col_count=2&p_p_col_pos=1' \
        '&_activities_WAR_northstarportlet__jsfBridgeAjax=true' \
        '&_activities_WAR_northstarportlet__facesViewIdResource=' \
        '%2FWEB-INF%2Fviews%2Fsports%2Factivities%2FActivity.xhtml'
    end

    def post_ajax(url, data)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request['User-Agent'] = USER_AGENT
      request['Cookie'] = cookie_header
      request['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8'
      request['Accept'] = 'application/xml, text/xml, */*; q=0.01'
      request['X-Requested-With'] = 'XMLHttpRequest'
      request['Faces-Request'] = 'partial/ajax'
      request['Referer'] = "#{@base_url}#{BOOKING_PATH}"
      request.body = URI.encode_www_form(data)

      response = http.request(request)
      store_cookies(response)
      response
    end

    def get(path, headers = {}, max_redirects: 10)
      uri = path.start_with?('http') ? URI(path) : URI.join(@base_url, path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT
      request['Cookie'] = cookie_header
      request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
      headers.each { |k, v| request[k] = v }

      response = http.request(request)
      store_cookies(response)

      if response.is_a?(Net::HTTPRedirection) && max_redirects.positive?
        return get(response['location'], headers, max_redirects: max_redirects - 1)
      end

      response
    end

    def post(url, data, headers = {}, follow_redirects: false)
      uri = url.start_with?('http') ? URI(url) : URI.join(@base_url, url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request['User-Agent'] = USER_AGENT
      request['Cookie'] = cookie_header
      request['Content-Type'] = 'application/x-www-form-urlencoded'
      request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
      request['Origin'] = @base_url
      request['Referer'] = "#{@base_url}#{LOGIN_PATH}"
      headers.each { |k, v| request[k] = v }
      request.body = URI.encode_www_form(data)

      response = http.request(request)
      store_cookies(response)

      if follow_redirects && response.is_a?(Net::HTTPRedirection)
        return get(response['location'])
      end

      response
    end

    def cookie_header
      @cookies.map { |k, v| "#{k}=#{v}" }.join('; ')
    end

    def store_cookies(response)
      cookies = response.get_fields('set-cookie')
      return unless cookies

      cookies.each do |cookie|
        parts = cookie.split(';').first.split('=', 2)
        @cookies[parts[0]] = parts[1] if parts.length == 2
      end
    end

    def log(message)
      @debug_log.puts message
      puts message if @debug
    end
  end
end
