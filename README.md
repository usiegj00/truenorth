# Truenorth

A command-line client for NorthStar-powered facility booking systems (like club management portals built on Liferay with PrimeFaces).

## Installation

```bash
gem install truenorth
```

Or add to your Gemfile:

```ruby
gem 'truenorth'
```

## Configuration

First, configure your connection:

```bash
truenorth configure
```

You'll be prompted for:
- **Base URL**: Your club's portal URL (e.g., `https://your-club.com`)
- **Member ID**: Your login ID (e.g., `12345-00`)
- **Password**: Your password

This stores your credentials securely in `~/.config/truenorth/` with restricted permissions (600).

Alternatively, use environment variables:

```bash
export TRUENORTH_BASE_URL="https://your-club-portal.com"
export TRUENORTH_USERNAME="12345-00"
export TRUENORTH_PASSWORD="your-password"
```

## Usage

### Check availability

```bash
# Today's availability
truenorth availability

# Specific date
truenorth availability 2024-03-15

# Days from today
truenorth availability +5

# Different activity
truenorth availability --activity golf
truenorth availability -a music
```

### Make a booking

```bash
# Book a slot
truenorth book "7:30 AM"

# Book for a specific date
truenorth book "7:30 AM" --date 2024-03-15
truenorth book "7:30 AM" -d +5

# Specify court preference
truenorth book "7:30 AM" --court "Court 1"

# Dry run (test without booking)
truenorth book "7:30 AM" --dry-run
```

### View your reservations

```bash
truenorth reservations

# JSON output
truenorth reservations --json
```

### Check status

```bash
truenorth status
```

## Activities

Supported activity types:
- `squash` (default)
- `golf`
- `music`
- `meeting` / `room`

## Ruby API

```ruby
require 'truenorth'

client = Truenorth::Client.new
client.login('12345-00', 'password')

# Check availability
slots = client.availability(Date.today + 5, activity: 'squash')
puts slots[:slots]

# Book a slot
result = client.book('7:30 AM', date: Date.today + 5, activity: 'squash')
puts result[:confirmation]

# List reservations
reservations = client.reservations
```

## License

MIT License - see LICENSE file.
