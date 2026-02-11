# frozen_string_literal: true

require 'ferrum'
require 'base64'

module Truenorth
  # Browser-based client using Ferrum for JavaScript-heavy operations
  class BrowserClient
    attr_reader :browser, :debug

    def initialize(base_url: nil, debug: false)
      @base_url = base_url || Config.base_url
      raise Error, 'No base URL configured. Run: truenorth configure' unless @base_url

      @debug = debug
      @browser = nil
    end

    def start
      @browser = Ferrum::Browser.new(
        headless: !@debug,
        timeout: 30,
        window_size: [1920, 1080],
        browser_options: {
          'no-sandbox': nil,
          'window-size': '1920,1080'
        }
      )
      log 'Browser started'

      # Auto-accept any alert dialogs (e.g., "Please create reservation for the future")
      @browser.on(:dialog) { |dialog| dialog.accept }

      # Maximize window in debug mode
      if @debug && @browser
        @browser.resize(width: 1920, height: 1080)
        log 'Browser window resized to 1920x1080'
      end
    end

    def quit
      @browser&.quit
      log 'Browser quit'
    end

    def login
      start unless @browser

      # Try using cached cookies first
      cookies = Config.cookies
      if !cookies.empty?
        log "Loading #{cookies.length} cached cookies"
        @browser.go_to(@base_url)

        cookies.each do |name, value|
          @browser.cookies.set(
            name: name,
            value: value,
            domain: URI.parse(@base_url).host
          )
        end

        # Test if cookies work
        @browser.go_to("#{@base_url}/group/pages/facility-booking")
        sleep 2

        if @browser.body.include?('Sign Out') || @browser.title.include?('Facility Booking')
          log 'Logged in with cached cookies'
          return true
        end

        log 'Cached cookies expired, logging in...'
      end

      # Login via HTTP client to get fresh cookies
      http_client = Client.new(base_url: @base_url, debug: @debug)
      http_client.login

      # Get cookies from HTTP client
      @browser.go_to(@base_url)
      http_client.cookies.each do |name, value|
        @browser.cookies.set(
          name: name,
          value: value,
          domain: URI.parse(@base_url).host
        )
      end

      log 'Logged in via HTTP client, cookies transferred to browser'
      true
    end

    def availability(date, activity: 'squash')
      login unless @browser

      log "\n=== BROWSER GET AVAILABILITY ==="
      log "Date: #{date}, Activity: #{activity}"

      navigate_to_date_and_activity(date, activity)

      # Parse the availability table
      slots = parse_availability_table
      log "Found #{slots.count} time slots across all courts"

      {
        success: true,
        date: date.to_s,
        activity: activity,
        slots: slots
      }
    ensure
      quit
    end

    def book(time, date: Date.today, court: nil, activity: 'squash', dry_run: false)
      login unless @browser

      log "\n=== BROWSER BOOK SLOT ==="
      log "Time: #{time}, Date: #{date}, Court: #{court || 'any'}, Activity: #{activity}"
      log 'DRY RUN MODE' if dry_run

      navigate_to_date_and_activity(date, activity)

      # Find and click the slot (dispatches mousedown+mouseup, triggers reservation AJAX)
      slot_info = find_and_click_slot(time, court, date)
      raise BookingError, "No slot available at #{time}" unless slot_info

      log "Clicked slot: #{slot_info[:court]} at #{slot_info[:time]}"

      # Wait for reservation panel to appear with Save button (poll up to 10 seconds)
      panel_state = nil
      10.times do |i|
        sleep 1
        panel_state = @browser.evaluate(<<~JS)
          (function() {
            var panel = document.querySelector('[id*="reservationPanel"]');
            var saveBtn = document.querySelector('.btn-save');
            var fromTime = document.querySelector('select[name*="fromTime_input"]');
            return {
              hasPanel: !!panel,
              panelVisible: panel ? panel.offsetWidth > 0 : false,
              hasSaveBtn: !!saveBtn,
              saveBtnVisible: saveBtn ? saveBtn.offsetWidth > 0 : false,
              saveBtnId: saveBtn ? saveBtn.id : null,
              fromTime: fromTime ? fromTime.value : null
            };
          })()
        JS
        log "Panel check #{i + 1}/10: #{panel_state.inspect}"

        break if panel_state['saveBtnVisible']
      end

      unless panel_state['saveBtnVisible']
        log 'Save button not visible after 10s of waiting'
        @browser.screenshot(path: '/tmp/no_save_btn.png', full: true)
        log 'Saved screenshot to /tmp/no_save_btn.png'
        raise BookingError, 'Reservation panel did not appear after clicking slot'
      end

      if dry_run
        log 'Dry run - not clicking Save'
        return {
          success: true,
          dry_run: true,
          court: slot_info[:court],
          time: slot_info[:time],
          message: "Dry run - reservation panel opened for #{slot_info[:court]} at #{slot_info[:time]}"
        }
      end

      # Click the Save button
      log 'Clicking Save button...'
      save_btn_id = panel_state['saveBtnId']
      @browser.evaluate(<<~JS)
        (function() {
          var btn = document.getElementById('#{save_btn_id}');
          if (btn) btn.click();
        })()
      JS

      # Wait for save AJAX to complete
      wait_for_ajax(timeout: 10)
      sleep 2

      # Check for success or error
      result_state = @browser.evaluate(<<~JS)
        (function() {
          var body = document.body.textContent;

          // Check for PrimeFaces error messages
          var msgs = document.querySelectorAll('.ui-messages-error, .ui-message-error');
          var errors = [];
          for (var i = 0; i < msgs.length; i++) {
            var txt = msgs[i].textContent.trim();
            if (txt) errors.push(txt);
          }

          // Check PrimeFaces Growl notifications (success/error popups)
          var growlMsgs = document.querySelectorAll('.ui-growl-message, .ui-growl-item');
          var growls = [];
          for (var i = 0; i < growlMsgs.length; i++) {
            var summary = growlMsgs[i].querySelector('.ui-growl-title');
            var detail = growlMsgs[i].querySelector('.ui-growl-message');
            var text = (summary ? summary.textContent : '') + ' ' + (detail ? detail.textContent : '');
            if (!text.trim()) text = growlMsgs[i].textContent.trim();
            if (text.trim()) growls.push(text.trim());
          }

          // Check if reservation panel is gone (success) or still showing (error)
          var panel = document.querySelector('[id*="reservationPanel"]');
          var panelVisible = panel ? panel.offsetWidth > 0 : false;
          var saveBtn = document.querySelector('.btn-save');
          var saveBtnVisible = saveBtn ? saveBtn.offsetWidth > 0 : false;

          // Check for Back button (visible means we're still on the reservation form)
          var backBtn = document.querySelector('.btn-back');
          var backBtnVisible = backBtn ? backBtn.offsetWidth > 0 : false;

          var bodyLower = body.toLowerCase();
          return {
            errors: errors,
            growls: growls,
            panelStillVisible: panelVisible,
            saveBtnStillVisible: saveBtnVisible,
            backBtnStillVisible: backBtnVisible,
            hasConfirmation: bodyLower.indexOf('confirmed') > -1 ||
                             bodyLower.indexOf('success') > -1 ||
                             bodyLower.indexOf('booked') > -1 ||
                             bodyLower.indexOf('reservation has been') > -1
          };
        })()
      JS
      log "After save: #{result_state.inspect}"

      if @debug
        @browser.screenshot(path: '/tmp/after_save.png', full: true)
        log 'Saved screenshot to /tmp/after_save.png'
      end

      if result_state['errors'].any?
        raise BookingError, "Booking failed: #{result_state['errors'].join(', ')}"
      end

      # Check growl messages for errors
      growl_errors = result_state['growls'].select { |g| g =~ /error|fail|unable|invalid/i }
      if growl_errors.any?
        raise BookingError, "Booking failed: #{growl_errors.join(', ')}"
      end

      # Success indicators:
      # 1. Save button disappeared (panel closed after successful save)
      # 2. Confirmation text in body or growl
      # 3. Back button gone (returned to slot view)
      growl_success = result_state['growls'].any? { |g| g =~ /success|confirm|booked|reserved/i }

      if !result_state['saveBtnStillVisible'] || result_state['hasConfirmation'] || growl_success
        confirmation_msg = result_state['growls'].first || 'Booking confirmed'
        log "Booking confirmed: #{confirmation_msg}"
        {
          success: true,
          court: slot_info[:court],
          time: slot_info[:time],
          confirmation: confirmation_msg
        }
      else
        log 'Booking status uncertain - check My Reservations'
        {
          success: false,
          error: 'Booking uncertain - please check My Reservations'
        }
      end
    ensure
      quit
    end

    def reservations
      login unless @browser

      log "\n=== BROWSER GET RESERVATIONS ==="

      @browser.go_to("#{@base_url}/group/pages/my-reservations")
      sleep 3

      reservations = parse_reservations_table
      log "Found #{reservations.count} reservations"

      reservations
    ensure
      quit
    end

    def cancel(reservation_id, dry_run: false)
      login unless @browser

      log "\n=== BROWSER CANCEL RESERVATION ==="
      log "Cancel ID: #{reservation_id}"
      log 'DRY RUN MODE' if dry_run

      return { success: true, dry_run: true, message: 'Dry run - would cancel reservation' } if dry_run

      @browser.go_to("#{@base_url}/group/pages/my-reservations")
      sleep 3

      # Click the cancel button
      log "Clicking cancel button: #{reservation_id}"
      @browser.execute(<<~JS, reservation_id)
        (function() {
          var cancelBtn = document.getElementById(arguments[0]);
          if (cancelBtn) {
            cancelBtn.click();
          } else {
            throw new Error('Cancel button not found');
          }
        })()
      JS

      # Wait for confirmation dialog
      sleep 2

      # Click YES in the confirmation dialog
      log 'Clicking YES to confirm cancellation'
      @browser.execute(<<~JS)
        (function() {
          var yesBtn = document.querySelector('a.ui-area-btn-danger, button.ui-area-btn-danger');
          if (yesBtn && yesBtn.textContent.indexOf('YES') > -1) {
            yesBtn.click();
          } else {
            throw new Error('YES button not found');
          }
        })()
      JS

      # Wait for cancellation to complete
      sleep 3

      # Check for success
      success_msg = @browser.evaluate("document.body.textContent")
      if success_msg.include?('cancelled') || success_msg.include?('canceled') || success_msg.include?('success')
        log 'Cancellation confirmed'
        { success: true, message: 'Reservation cancelled' }
      else
        { success: false, error: 'Cancellation uncertain - please verify' }
      end
    ensure
      quit
    end

    private

    def navigate_to_date_and_activity(date, activity)
      @browser.go_to("#{@base_url}/group/pages/facility-booking")
      sleep 3

      activity_id = Client::ACTIVITIES[activity.to_s.downcase] || '5'

      # Step 1: Change activity via PrimeFaces SelectOneMenu widget (triggers AJAX)
      # This updates the server-side activity. Do NOT reload - that resets to default (golf).
      select_activity_ui(activity_id)
      wait_for_ajax

      # Step 2: Navigate to correct date - the dateSelect AJAX renders the table
      # with the correct activity from the session updated in step 1
      navigate_to_date(date, force: true)
      wait_for_ajax

      # No extra sheetDate fix needed - the Calendar widget properly updates the server

      # Verify correct activity courts are shown
      verify = @browser.evaluate(<<~JS)
        (function() {
          var slots = document.querySelectorAll('td.slot div[data-area-id]');
          var areaIds = {};
          for (var i = 0; i < slots.length; i++) {
            var aid = slots[i].getAttribute('data-area-id');
            areaIds[aid] = (areaIds[aid] || 0) + 1;
          }
          return { totalSlots: slots.length, areaIds: areaIds };
        })()
      JS
      log "After navigation - slots: #{verify['totalSlots']}, areas: #{verify['areaIds']}"

      log "Navigated to #{activity} for #{date}"
    end

    def wait_for_ajax(timeout: 15)
      timeout.times do |i|
        sleep 1
        idle = @browser.evaluate(<<~JS)
          (function() {
            try {
              if (typeof PrimeFaces !== 'undefined' && PrimeFaces.ajax) {
                if (PrimeFaces.ajax.Queue && PrimeFaces.ajax.Queue.isEmpty) {
                  return PrimeFaces.ajax.Queue.isEmpty();
                }
                // Older PrimeFaces versions
                if (PrimeFaces.ajax.QUEUE && PrimeFaces.ajax.QUEUE.isEmpty) {
                  return PrimeFaces.ajax.QUEUE.isEmpty();
                }
              }
              return true;
            } catch(e) { return true; }
          })()
        JS
        if idle
          log "AJAX completed after #{i + 1} seconds" if @debug
          break
        end
      end
      sleep 1 # Extra buffer for DOM rendering
    end

    def select_activity_ui(activity_id)
      log "Selecting activity ID: #{activity_id}"

      # Use PrimeFaces SelectOneMenu widget's selectItem method (non-silent)
      # This fires the change behavior AJAX, properly updating the server session
      result = @browser.evaluate(<<~JS)
        (function() {
          for (var key in PrimeFaces.widgets) {
            var w = PrimeFaces.widgets[key];
            if (!w.input || !w.input[0] || w.input[0].tagName !== 'SELECT') continue;
            var sel = w.input[0];

            var targetIdx = -1;
            for (var i = 0; i < sel.options.length; i++) {
              if (sel.options[i].value === '#{activity_id}') {
                targetIdx = i;
                break;
              }
            }
            if (targetIdx === -1) continue;

            var oldValue = sel.value;
            if (oldValue === '#{activity_id}') {
              return { success: true, method: 'already_selected', value: oldValue };
            }

            // selectItem without silent flag triggers the change behavior AJAX
            w.selectItem(w.items.eq(targetIdx));

            return {
              success: true, method: 'ui_click',
              oldValue: oldValue, newValue: sel.value,
              targetIdx: targetIdx, widgetKey: key
            };
          }
          return { error: 'widget not found' };
        })()
      JS
      log "Activity select result: #{result.inspect}"
    end

    def navigate_to_date(date, force: false)
      target_str = date.strftime('%m/%d/%Y')

      current_date = @browser.evaluate(<<~JS)
        (function() {
          var input = document.querySelector('input[name*="sheetDate"]');
          return input ? input.value : null;
        })()
      JS

      if current_date == target_str && !force
        log "Already on correct date: #{target_str}"
        return
      end

      log "Navigating from #{current_date} to #{target_str}"

      # Use the Calendar widget (j_idt79) which has setDate + dateSelect behavior.
      # This properly updates the server's session date, unlike directly setting
      # the sheetDate input which only updates the display.
      result = @browser.evaluate(<<~JS)
        (function() {
          var parts = '#{target_str}'.split('/');
          var targetDate = new Date(parseInt(parts[2]), parseInt(parts[0]) - 1, parseInt(parts[1]));

          // Find the Calendar widget with setDate + dateSelect behavior
          for (var key in PrimeFaces.widgets) {
            var w = PrimeFaces.widgets[key];
            if (typeof w.setDate !== 'function') continue;
            if (!w.cfg || !w.cfg.behaviors || !w.cfg.behaviors.dateSelect) continue;

            w.setDate(targetDate);
            w.cfg.behaviors.dateSelect.call(w, {
              params: [{ name: w.id + '_selectedDate', value: targetDate.getTime() }]
            });
            return { success: true, method: 'setDate+behavior', widgetKey: key };
          }

          // Fallback: click the day tab link if target is within the visible week
          var dayLinks = document.querySelectorAll('a[id*="j_idt98"]');
          for (var i = 0; i < dayLinks.length; i++) {
            var dayNum = dayLinks[i].textContent.match(/\\b(\\d{1,2})\\b/);
            if (dayNum && parseInt(dayNum[1]) === parseInt(parts[1])) {
              dayLinks[i].click();
              return { success: true, method: 'dayTab_click', day: dayNum[1] };
            }
          }

          return { error: 'No Calendar widget or matching day tab found' };
        })()
      JS
      log "Date navigation result: #{result.inspect}"
    end

    def find_and_click_slot(target_time, preferred_court, booking_date = Date.today)
      # Normalize time
      normalized_time = target_time.strip.gsub(/^0/, '').upcase

      # Only filter past-time slots for today/past dates.
      # The page erroneously applies past-time class to future dates based on current time of day,
      # but the server accepts bookings for those slots fine.
      is_today = booking_date <= Date.today
      slot_selector = is_today ? 'td.slot.open:not(.past-time)' : 'td.slot.open'

      # Find all open slots
      slots = @browser.evaluate(<<~JS)
        (function() {
          var openSlots = document.querySelectorAll('#{slot_selector}');
          var result = [];
          for (var i = 0; i < openSlots.length; i++) {
            var td = openSlots[i];
            var timeCell = td.parentElement.querySelector('td.interval');
            var time = timeCell ? timeCell.textContent.trim() : '';
            var div = td.querySelector('div[data-start-time]');
            var areaId = div ? div.getAttribute('data-area-id') : null;

            if (areaId) {
              result.push({
                time: time,
                areaId: areaId,
                startTime: div ? div.getAttribute('data-start-time') : '',
                endTime: div ? div.getAttribute('data-end-time') : ''
              });
            }
          }
          return result;
        })()
      JS

      # Debug: show available times
      unique_times = slots.map { |s| s['startTime'] }.uniq.sort
      log "Available times (#{slots.length} bookable slots): #{unique_times.first(10).join(', ')}#{unique_times.length > 10 ? '...' : ''}"
      log "Looking for: '#{normalized_time}'"

      # Find matching slot by time display or data-start-time
      matching_slot = slots.find do |slot|
        time_match = slot['time'].gsub(/^0/, '').upcase == normalized_time ||
                     slot['startTime'].gsub(/^0/, '').upcase == normalized_time
        court_match = if preferred_court
                        court_name = Client::COURTS[slot['areaId']]
                        court_name&.downcase&.include?(preferred_court.downcase)
                      else
                        true
                      end
        time_match && court_match
      end

      return nil unless matching_slot

      court_name = Client::COURTS[matching_slot['areaId']]
      log "Clicking slot: #{court_name} at #{matching_slot['startTime']}"

      # Call rc_showReservationScreen directly with slot parameters.
      # This bypasses the client-side past-time check (which erroneously blocks
      # future-date slots) and fires the PrimeFaces AJAX to open the reservation panel.
      click_result = @browser.evaluate(<<~JS)
        (function() {
          rc_showReservationScreen([
            {name: 'activityAreaId', value: '#{matching_slot['areaId']}'},
            {name: 'startTime', value: '#{matching_slot['startTime']}'},
            {name: 'endTime', value: '#{matching_slot['endTime']}'}
          ]);
          return { success: true, areaId: '#{matching_slot['areaId']}', startTime: '#{matching_slot['startTime']}' };
        })()
      JS
      log "Slot click result: #{click_result.inspect}"

      wait_for_ajax
      sleep 1

      {
        court: court_name,
        time: matching_slot['startTime'],
        area_id: matching_slot['areaId']
      }
    end


    def parse_reservations_table
      reservations = []

      # Get all reservation sections (by member)
      member_sections = @browser.css('dt.ui-datalist-item')

      member_sections.each_with_index do |section, member_idx|
        # Extract member name
        header_text = @browser.evaluate("arguments[0].textContent.trim()", section)
        member_name = if header_text.include?("'s Reservations")
                        header_text[/^(.+?)'s Reservations/, 1]
                      else
                        nil
                      end

        # Get all reservation rows for this member
        rows = @browser.evaluate(<<~JS, section)
          (function() {
            var tables = arguments[0].parentElement.querySelectorAll('table tbody tr');
            var result = [];
            for (var i = 0; i < tables.length; i++) {
              var row = tables[i];
              var cellElements = row.querySelectorAll('td');
              var cells = [];
              for (var j = 0; j < cellElements.length; j++) {
                cells.push(cellElements[j].textContent.trim());
              }
              var cancelLink = row.querySelector('a[title="Cancel Reservation"]');
              var cancelId = cancelLink ? cancelLink.id : null;
              result.push({ cells: cells, cancelId: cancelId, rowIdx: i });
            }
            return result;
          })()
        JS

        rows.each do |row|
          next if row['cells'].length < 2

          # Parse reservation data
          res_data = parse_reservation_row(row['cells'])
          next unless res_data && res_data[:date]

          res_data[:member] = member_name
          res_data[:member_idx] = member_idx
          res_data[:row_idx] = row['rowIdx']
          res_data[:cancel_id] = row['cancelId']

          reservations << res_data
        end
      end

      # Sort by date
      reservations.sort_by! do |res|
        Date.strptime(res[:date], '%m/%d/%Y') rescue Date.today
      end

      reservations
    end

    def parse_reservation_row(text_parts)
      return nil if text_parts.length < 2

      cell1 = text_parts[1]

      # Extract activity/court info
      activity_match = cell1.match(/(Activities|Events)\s+\((.+?)\)\s*\d{2}\/\d{2}\/\d{4}/)
      activity = nil
      court = nil

      if activity_match
        activity_full = activity_match[2]
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

      # Extract dates and times
      dates = cell1.scan(/\b(\d{2}\/\d{2}\/\d{4})\b/).flatten
      times = cell1.scan(/(\d{1,2}:\d{2}\s+[AP]M)/).flatten

      return nil if dates.empty?

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

    def parse_availability_table
      slots = {}

      # Get table rows using a safer approach
      rows = @browser.evaluate(<<~JS)
        (function() {
          var tbody = document.querySelector('tbody.ui-datatable-data');
          if (!tbody) return [];

          var rows = tbody.querySelectorAll('tr');
          var result = [];

          for (var i = 0; i < rows.length; i++) {
            var row = rows[i];
            var timeCell = row.querySelector('td.interval');
            if (!timeCell) continue;

            var time = timeCell.textContent.trim();
            if (!time) continue;

            var courtCells = [];
            var slots = row.querySelectorAll('td.slot');

            for (var j = 0; j < slots.length; j++) {
              var td = slots[j];
              var classes = td.className || '';
              var isOpen = classes.indexOf('open') > -1;
              var isReserved = classes.indexOf('reserved') > -1;
              var areaDiv = td.querySelector('div[data-area-id]');
              var areaId = areaDiv ? areaDiv.getAttribute('data-area-id') : null;

              if (isOpen && !isReserved && areaId) {
                courtCells.push({
                  areaId: areaId
                });
              }
            }

            if (courtCells.length > 0) {
              result.push({
                time: time,
                courts: courtCells
              });
            }
          }

          return result;
        })()
      JS

      log "Found #{rows.length} time slots with availability"

      # Process the results
      rows.each do |row_data|
        time = row_data['time']
        row_data['courts'].each do |court|
          area_id = court['areaId']
          court_name = Client::COURTS[area_id] || "Court #{area_id}"

          slots[time] ||= []
          slots[time] << court_name unless slots[time].include?(court_name)
        end
      end

      slots
    end

    def log(message)
      puts message if @debug
    end
  end
end
