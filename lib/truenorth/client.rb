# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'nokogiri'
require 'json'
require 'base64'

module Truenorth
  # HTTP client for NorthStar facility booking systems
  # Handles Liferay portal authentication and PrimeFaces form submissions
  class Client
    LOGIN_PATH = '/en/web/pages/login'
    BOOKING_PATH = '/group/pages/facility-booking'
    RESERVATIONS_PATH = '/group/pages/my-reservations'

    USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' \
                 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

    # Activity type IDs
    ACTIVITIES = {
      'golf' => '4',
      'squash' => '5',
      'music' => '6',
      'room' => '8',
      'meeting' => '8'
    }.freeze

    # Court area IDs
    COURTS = {
      '16' => 'Squash Court 1',
      '17' => 'Squash Court 2',
      '18' => 'Squash Court 3',
      '30' => 'Court 1',
      '31' => 'Court 2',
      '32' => 'Court 3'
    }.freeze

    attr_reader :cookies, :debug_log, :logged_in

    def initialize(base_url: nil, debug: false)
      @base_url = base_url || Config.base_url
      raise Error, 'No base URL configured. Run: truenorth configure' unless @base_url

      @cookies = {}
      @debug = debug
      @debug_log = StringIO.new
      @logged_in = false
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
        log 'Login successful'
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

      # Check if we need to change activity type first
      activity_id = ACTIVITIES[activity.to_s.downcase] || '5'
      current_activity = html.at_css('input[name*="activityId"]')&.[]('value')

      if current_activity && current_activity != activity_id
        # Need to change activity via AJAX
        html = change_activity(html, activity_id)
      end

      # TODO: Handle date navigation if needed

      slots = parse_slots(html)
      log "Found #{slots.count} available time slots"

      {
        success: true,
        date: date.to_s,
        activity: activity,
        slots: slots
      }
    end

    # Book a slot
    def book(time, date: Date.today, court: nil, activity: 'squash', dry_run: false)
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

      # Change activity if needed
      activity_id = ACTIVITIES[activity.to_s.downcase] || '5'
      current_activity = form_fields["#{form_id}:activityId"]

      if current_activity != activity_id
        log "Changing activity from #{current_activity} to #{activity_id}"
        result = change_activity_ajax(form_id, view_state, activity_id, form_fields, components)
        raise BookingError, 'Failed to change activity type' unless result[:success]

        view_state = result[:view_state] || view_state
        html = Nokogiri::HTML(result[:body]) if result[:body]
        form_fields = extract_all_form_fields(html, form_id)
      end

      # Find the slot
      slot = find_slot(html, time, court)
      raise BookingError, "No slot available at #{time}" unless slot

      log "Found slot: #{slot[:court]} at #{slot[:start_time]}"

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

      response = get(RESERVATIONS_PATH)
      html = Nokogiri::HTML(response.body)

      reservations = []
      html.css('.reservation-item, .res-item, tr.reservation').each do |item|
        reservation = parse_reservation(item)
        reservations << reservation if reservation
      end

      # Alternative: look for table rows with reservation data
      if reservations.empty?
        html.css('table tbody tr').each do |row|
          cells = row.css('td')
          next if cells.length < 3

          reservations << {
            date: cells[0]&.text&.strip,
            time: cells[1]&.text&.strip,
            activity: cells[2]&.text&.strip,
            court: cells[3]&.text&.strip,
            status: cells[4]&.text&.strip
          }
        end
      end

      log "Found #{reservations.count} reservations"
      reservations
    end

    # Cancel a reservation
    def cancel(reservation_id, dry_run: false)
      ensure_logged_in!
      raise BookingError, 'Cancel not yet implemented'
    end

    private

    def ensure_logged_in!
      return if @logged_in

      login
    end

    def parse_slots(html)
      slots = {}

      html.css('td.slot.open').each do |td|
        div = td.at_css('div[data-start-time]')
        next unless div
        next if td['class']&.include?('reserved')

        start_time = div['data-start-time']
        area_id = div['data-area-id']
        court_name = COURTS[area_id] || "Court #{area_id}"

        slots[start_time] ||= []
        slots[start_time] << court_name
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

    def parse_reservation(item)
      # Try various selectors for reservation details
      date = item.at_css('.date, .res-date')&.text&.strip
      time = item.at_css('.time, .res-time')&.text&.strip
      court = item.at_css('.court, .location, .res-location')&.text&.strip
      activity = item.at_css('.activity, .res-activity')&.text&.strip

      return nil unless date || time

      { date: date, time: time, court: court, activity: activity }
    end

    def change_activity(html, activity_id)
      form_id = extract_form_id(html)
      view_state = extract_view_state(html)
      components = extract_primefaces_components(html)
      form_fields = extract_all_form_fields(html, form_id)

      result = change_activity_ajax(form_id, view_state, activity_id, form_fields, components)
      return html unless result[:success]

      Nokogiri::HTML(result[:body])
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
      end
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
        body = response.body.downcase
        if body.include?('success') || body.include?('confirmed') || body.include?('booked')
          { success: true, confirmation: 'Booking confirmed' }
        else
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
