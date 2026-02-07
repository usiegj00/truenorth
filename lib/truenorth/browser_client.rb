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

      # Find and click the slot
      slot_info = find_and_click_slot(time, court)
      raise BookingError, "No slot available at #{time}" unless slot_info

      log "Clicked slot: #{slot_info[:court]} at #{slot_info[:time]}"

      # Wait for dialogs to appear
      sleep 2

      # Check URL after click
      current_url = @browser.url
      page_title = @browser.title
      log "After slot click - URL: #{current_url}"
      log "After slot click - Title: #{page_title}"

      # Capture what dialog appeared (for debugging)
      if @debug
        dialog_info = @browser.evaluate(<<~JS)
          (function() {
            var result = {
              dialogsFound: 0,
              visibleDialogs: 0,
              dialogHtml: null,
              allDialogIds: []
            };

            var dialogs = document.querySelectorAll('.ui-dialog');
            result.dialogsFound = dialogs.length;

            for (var i = 0; i < dialogs.length; i++) {
              var dialog = dialogs[i];
              var content = dialog.querySelector('.ui-dialog-content');
              result.allDialogIds.push(content ? content.id : 'no-id');

              var style = window.getComputedStyle(dialog);
              if (style.display !== 'none' && style.visibility !== 'hidden') {
                result.visibleDialogs++;
                if (!result.dialogHtml) {
                  result.dialogHtml = dialog.outerHTML;
                }
              }
            }

            return result;
          })()
        JS

        log "Dialog capture info: #{dialog_info['dialogsFound']} total, #{dialog_info['visibleDialogs']} visible"
        log "Dialog IDs: #{dialog_info['allDialogIds'].join(', ')}"

        if dialog_info['dialogHtml']
          File.write('/tmp/first_dialog.html', dialog_info['dialogHtml'])
          log 'Saved first dialog HTML to /tmp/first_dialog.html'
        else
          log 'WARNING: No visible dialog HTML to capture!'
        end

        @browser.screenshot(path: '/tmp/first_dialog.png')
        log "Saved first dialog screenshot (URL: #{@browser.url}, Title: #{@browser.title})"
      end

      # Close legends dialog if it appears
      legends_closed = @browser.evaluate(<<~JS)
        (function() {
          var dialogs = document.querySelectorAll('.ui-dialog');
          for (var i = 0; i < dialogs.length; i++) {
            var dialog = dialogs[i];
            if (dialog.style.display === 'none') continue;
            var legendsContent = dialog.querySelector('[id*="legends_content"]');
            if (legendsContent) {
              var closeBtn = dialog.querySelector('a.cross');
              if (closeBtn) {
                closeBtn.click();
                return true;
              }
            }
          }
          return false;
        })()
      JS

      if legends_closed
        log 'Closed legends dialog, clicking slot again...'
        sleep 1

        # Click the slot again to open booking dialog
        click_result = @browser.evaluate(<<~JS)
          (function() {
            var div = document.querySelector('div[data-area-id="' + #{slot_info[:area_id]} + '"]');
            if (!div) return { clicked: false, reason: 'slot not found' };

            var td = div.parentElement;
            while (td && td.tagName !== 'TD') {
              td = td.parentElement;
            }
            if (!td) return { clicked: false, reason: 'td not found' };

            // Click and immediately check for dialog or auto-booking
            td.click();

            // Wait just a tiny bit for potential dialog
            var startTime = Date.now();
            while (Date.now() - startTime < 500) {
              // Busy wait for 500ms
            }

            // Check what happened
            var dialogs = document.querySelectorAll('.ui-dialog');
            var visibleDialogs = 0;
            var saveButton = null;

            for (var i = 0; i < dialogs.length; i++) {
              var dialog = dialogs[i];
              var style = window.getComputedStyle(dialog);
              if (style.display === 'none' || style.visibility === 'hidden') continue;

              visibleDialogs++;

              // Try to find and click save button immediately
              var btn =
                dialog.querySelector('a.btn-save') ||
                dialog.querySelector('button.btn-save') ||
                dialog.querySelector('a[id*="save"]') ||
                dialog.querySelector('button[id*="save"]') ||
                dialog.querySelector('a.ui-commandlink:not(.cross)') ||
                dialog.querySelector('.ui-button:not(.ui-dialog-titlebar-close):not(.cross)') ||
                dialog.querySelector('a.ui-area-btn-success') ||
                dialog.querySelector('button[type="submit"]');

              if (btn) {
                btn.click();
                saveButton = { id: btn.id, text: btn.textContent.trim() };
                break;
              }
            }

            return {
              clicked: true,
              visibleDialogs: visibleDialogs,
              saveButton: saveButton,
              saveClicked: !!saveButton
            };
          })()
        JS

        log "Second click result: #{click_result.inspect}"

        if click_result['saveClicked']
          log "Save button clicked immediately after dialog opened!"
          sleep 3
          page_text = @browser.evaluate('document.body.textContent')
          if page_text =~ /confirmed|success|booked|reservation.*created/i
            log 'Booking appears confirmed based on page content'
            return {
              success: true,
              court: slot_info[:court],
              time: "#{slot_info[:time]} - #{(Time.parse(slot_info[:time]) + 3600).strftime('%-I:%M %p').upcase}",
              confirmation: 'Booking confirmed'
            }
          end
        end

        # In debug mode, wait so user can see the browser
        if @debug
          log 'DEBUG: Waiting 10 seconds so you can see the browser state...'
          sleep 10
        else
          sleep 2
        end
      end

      # Check if booking dialog opened
      dialog_visible = @browser.evaluate(<<~JS)
        (function() {
          var dialogs = document.querySelectorAll('.ui-dialog');
          for (var i = 0; i < dialogs.length; i++) {
            var dialog = dialogs[i];
            if (dialog.style.display === 'none') continue;
            // Make sure it's not the legends dialog
            var isLegends = !!dialog.querySelector('[id*="legends_content"]');
            if (!isLegends) return true;
          }
          return false;
        })()
      JS

      unless dialog_visible
        log 'ERROR: Booking dialog did not open!'
        if @debug
          @browser.screenshot(path: '/tmp/no_dialog.png')
          log 'Saved screenshot to /tmp/no_dialog.png'
        end
        raise BookingError, 'Booking dialog did not open after clicking slot'
      end

      log 'Booking dialog opened'

      # Capture dialog HTML for debugging
      if @debug
        dialog_html = @browser.evaluate(<<~JS)
          (function() {
            var dialogs = document.querySelectorAll('.ui-dialog');
            for (var i = 0; i < dialogs.length; i++) {
              var dialog = dialogs[i];
              var style = window.getComputedStyle(dialog);
              if (style.display !== 'none' && style.visibility !== 'hidden') {
                return dialog.outerHTML;
              }
            }
            return null;
          })()
        JS

        if dialog_html
          File.write('/tmp/booking_dialog.html', dialog_html)
          log 'Saved booking dialog HTML to /tmp/booking_dialog.html'
        end

        @browser.screenshot(path: '/tmp/booking_dialog.png')
        log 'Saved screenshot to /tmp/booking_dialog.png'
      end

      if dry_run
        log 'Dry run - closing dialog without booking'
        close_dialog
        return {
          success: true,
          dry_run: true,
          court: slot_info[:court],
          time: time,
          message: 'Dry run completed - booking dialog opened successfully'
        }
      end

      # Try to find and click the save button in the browser
      log 'Looking for save button in dialog...'
      sleep 1  # Quick check before dialog might close

      # Check for save button immediately
      quick_check = @browser.evaluate(<<~JS)
        (function() {
          var dialogs = document.querySelectorAll('.ui-dialog');
          var visibleCount = 0;
          var saveButton = null;

          for (var i = 0; i < dialogs.length; i++) {
            var dialog = dialogs[i];
            var style = window.getComputedStyle(dialog);
            if (style.display === 'none' || style.visibility === 'hidden') continue;

            visibleCount++;

            // Try to find save button
            var btn =
              dialog.querySelector('a.btn-save') ||
              dialog.querySelector('button.btn-save') ||
              dialog.querySelector('a[id*="save"]') ||
              dialog.querySelector('button[id*="save"]') ||
              dialog.querySelector('a.ui-commandlink:not(.cross)') ||
              dialog.querySelector('.ui-button:not(.ui-dialog-titlebar-close):not(.cross)') ||
              dialog.querySelector('a.ui-area-btn-success') ||
              dialog.querySelector('button[type="submit"]');

            if (btn) {
              saveButton = {
                id: btn.id || '',
                text: btn.textContent.trim(),
                className: btn.className || ''
              };
              btn.click();
              return { found: true, clicked: true, button: saveButton, visibleCount: visibleCount };
            }
          }

          return { found: false, clicked: false, visibleCount: visibleCount };
        })()
      JS

      log "Quick check result: #{quick_check.inspect}"

      if quick_check['clicked']
        log "Save button clicked immediately!"
        sleep 3
        page_text = @browser.evaluate('document.body.textContent')
        if page_text =~ /confirmed|success|booked/i
          log 'Booking confirmed'
          return {
            success: true,
            court: slot_info[:court],
            time: "#{slot_info[:time]} - #{(Time.parse(slot_info[:time]) + 3600).strftime('%-I:%M %p').upcase}",
            confirmation: 'Booking confirmed'
          }
        end
      end

      sleep 2  # Wait a bit more

      # Get dialog info (any visible dialog)
      dialog_info = @browser.evaluate(<<~JS)
        (function() {
          var dialogs = document.querySelectorAll('.ui-dialog');
          var visibleDialogs = [];

          // Find all visible dialogs
          for (var i = 0; i < dialogs.length; i++) {
            var dialog = dialogs[i];
            var style = window.getComputedStyle(dialog);
            if (style.display !== 'none' && style.visibility !== 'hidden') {
              visibleDialogs.push(dialog);
            }
          }

          if (visibleDialogs.length === 0) return { found: false, count: 0 };

          // Use the last visible dialog (most recently opened)
          var dialog = visibleDialogs[visibleDialogs.length - 1];

          // Find all buttons in this dialog
          var buttons = [];
          var allBtns = dialog.querySelectorAll('a, button');
          for (var j = 0; j < allBtns.length; j++) {
            var btn = allBtns[j];
            buttons.push({
              tag: btn.tagName,
              id: btn.id || '',
              className: btn.className || '',
              text: btn.textContent.trim(),
              disabled: btn.disabled || btn.className.indexOf('disabled') > -1
            });
          }

          var content = dialog.querySelector('.ui-dialog-content');
          return {
            found: true,
            count: visibleDialogs.length,
            contentId: content ? content.id : '',
            buttons: buttons,
            html: dialog.innerHTML.substring(0, 1000)
          };
        })()
      JS

      log "Dialog info: #{dialog_info.inspect}"

      # Try multiple save button selectors (use last visible dialog)
      save_result = @browser.evaluate(<<~JS)
        (function() {
          // Find all visible dialogs
          var dialogs = document.querySelectorAll('.ui-dialog');
          var visibleDialogs = [];
          for (var i = 0; i < dialogs.length; i++) {
            var dialog = dialogs[i];
            var style = window.getComputedStyle(dialog);
            if (style.display !== 'none' && style.visibility !== 'hidden') {
              visibleDialogs.push(dialog);
            }
          }

          if (visibleDialogs.length === 0) return { clicked: false, reason: 'no visible dialogs' };

          // Use the last visible dialog (most recently opened)
          var targetDialog = visibleDialogs[visibleDialogs.length - 1];

          // Try to find save/submit button in this dialog
          var saveBtn =
            targetDialog.querySelector('a.btn-save') ||
            targetDialog.querySelector('button.btn-save') ||
            targetDialog.querySelector('a[id*="save"]') ||
            targetDialog.querySelector('button[id*="save"]') ||
            targetDialog.querySelector('a.ui-commandlink:not(.cross)') ||
            targetDialog.querySelector('.ui-button:not(.ui-dialog-titlebar-close):not(.cross)') ||
            targetDialog.querySelector('a.ui-area-btn-success') ||
            targetDialog.querySelector('button[type="submit"]');

          if (saveBtn) {
            var btnInfo = {
              id: saveBtn.id || '',
              className: saveBtn.className || '',
              text: saveBtn.textContent.trim(),
              disabled: saveBtn.disabled || saveBtn.className.indexOf('disabled') > -1
            };
            console.log('Found save button:', saveBtn.id || saveBtn.className);
            saveBtn.click();
            return { clicked: true, button: btnInfo };
          }
          return { clicked: false, reason: 'no save button found', dialogCount: visibleDialogs.length };
        })()
      JS

      save_clicked = save_result['clicked']
      log "Save button result: #{save_result.inspect}" if save_result['button']

      if save_clicked
        log 'Save button clicked, waiting for confirmation...'
        sleep 3

        # Check for success message
        page_text = @browser.evaluate('document.body.textContent')
        if page_text =~ /confirmed|success|booked/i
          log 'Booking confirmed'
          return {
            success: true,
            court: slot_info[:court],
            time: "#{slot_info[:time]} - #{(Time.parse(slot_info[:time]) + 3600).strftime('%-I:%M %p').upcase}",
            confirmation: 'Booking confirmed'
          }
        else
          log 'Warning: Save button clicked but no confirmation message detected'
          return {
            success: false,
            error: 'Booking uncertain - please check My Reservations'
          }
        end
      else
        log 'No save button found, falling back to HTTP client approach'

        # Fallback to HTTP client approach
        http_client = Client.new(debug: @debug)

        # Transfer cookies from browser to HTTP client
        browser_cookies = @browser.cookies.all
        browser_cookies.each do |name, cookie|
          http_client.cookies[name] = cookie.value
        end

        # Calculate end time (assuming 1-hour slots)
        start_time_obj = Time.parse(slot_info[:time])
        end_time = (start_time_obj + 3600).strftime('%-I:%M %p').upcase

        # Pass the slot info directly to avoid re-finding
        result = http_client.book(
          time,
          date: date,
          court: court,
          activity: activity,
          dry_run: false,
          slot_info: {
            area_id: slot_info[:area_id],
            court: slot_info[:court],
            start_time: slot_info[:time],
            end_time: end_time
          }
        )

        result
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

      # Select activity
      activity_id = Client::ACTIVITIES[activity.to_s.downcase] || '5'
      select_activity(activity_id)
      sleep 5

      # TODO: Navigate to specific date if not today
      current_url = @browser.url
      page_title = @browser.title
      log "Navigated to #{activity} for #{date}"
      log "Current URL: #{current_url}"
      log "Page title: #{page_title}"
    end

    def select_activity(activity_id)
      log "Selecting activity ID: #{activity_id}"
      @browser.execute(<<~JS)
        (function() {
          var select = document.querySelector('select[id*="j_idt51_input"]');
          if (select) {
            select.value = '#{activity_id}';
            PrimeFaces.ab({
              s: "_activities_WAR_northstarportlet_:activityForm:j_idt51",
              e: "change",
              f: "_activities_WAR_northstarportlet_:activityForm",
              p: "_activities_WAR_northstarportlet_:activityForm:j_idt51",
              u: "_activities_WAR_northstarportlet_:activityForm"
            });
          }
        })()
      JS
    end

    def find_and_click_slot(target_time, preferred_court)
      # Normalize time
      normalized_time = target_time.strip.gsub(/^0/, '').upcase

      # Find all open slots matching the time
      slots = @browser.evaluate(<<~JS)
        (function() {
          var openSlots = document.querySelectorAll('td.slot.open');
          var result = [];
          for (var i = 0; i < openSlots.length; i++) {
            var td = openSlots[i];
            var timeCell = td.parentElement.querySelector('td.interval');
            var time = timeCell ? timeCell.textContent.trim() : '';
            var div = td.querySelector('div[data-start-time]');
            var areaId = div ? div.getAttribute('data-area-id') : null;

            if (time && areaId) {
              result.push({
                time: time,
                areaId: areaId
              });
            }
          }
          return result;
        })()
      JS

      # Find matching slot
      matching_slot = slots.find do |slot|
        time_match = slot['time'].gsub(/^0/, '').upcase == normalized_time
        court_match = if preferred_court
                        court_name = Client::COURTS[slot['areaId']]
                        court_name&.downcase&.include?(preferred_court.downcase)
                      else
                        true
                      end
        time_match && court_match
      end

      return nil unless matching_slot

      # Click the slot
      court_name = Client::COURTS[matching_slot['areaId']]
      log "Clicking slot: #{court_name} at #{matching_slot['time']}"

      # Find and click using the area ID
      @browser.execute(<<~JS, matching_slot['areaId'])
        (function() {
          var div = document.querySelector('div[data-area-id="' + arguments[0] + '"]');
          if (div) {
            var td = div.parentElement;
            while (td && td.tagName !== 'TD') {
              td = td.parentElement;
            }
            if (td) td.click();
          }
        })()
      JS

      {
        court: court_name,
        time: matching_slot['time'],
        area_id: matching_slot['areaId']
      }
    end

    def close_dialog
      @browser.execute(<<~JS)
        (function() {
          var closeBtn = document.querySelector('.ui-dialog-titlebar-close');
          if (closeBtn) closeBtn.click();
        })()
      JS
    end

    def submit_booking
      log 'Submitting booking...'

      # Try to find and trigger the save button via PrimeFaces
      success = @browser.execute(<<~JS)
        (function() {
          // Look for the save button anywhere on the page
          var saveBtn = document.querySelector('a.btn-save, button.btn-save') ||
                       document.querySelector('a[id*="save"]') ||
                       document.querySelector('button[id*="save"]') ||
                       document.querySelector('.ui-dialog a.ui-commandlink') ||
                       document.querySelector('.ui-dialog button[type="button"]');

          if (saveBtn) {
            console.log('Clicking save button:', saveBtn.id);
            saveBtn.click();
            return true;
          }

          // If no button found, try submitting via form
          var form = document.querySelector('form[id*="activityForm"]');
          if (form) {
            console.log('Submitting form');
            form.submit();
            return true;
          }

          return false;
        })()
      JS

      log "Booking submission triggered: #{success}"
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
