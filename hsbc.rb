#!/usr/bin/env ruby
require 'dotenv/load'
require 'capybara'
require 'date'
require 'capybara/dsl'
require 'logger'
require 'selenium/webdriver'

statements_directory = File.join(__dir__, 'statements')
FileUtils.mkdir_p statements_directory

Capybara.register_driver :chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.prefs['download.default_directory'] = statements_directory
  options.prefs['download.prompt_for_download'] = false
  options.prefs['profile.default_content_settings.popups'] = 0
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

Capybara.default_driver = Capybara.javascript_driver = :chrome

module Bank
  class HSBC
    include Capybara::DSL

    attr_reader :dir, :logger
    def initialize(username:, memorable:, token:, dir:, logger: )
      @username = username
      @memorable = memorable
      @token = token
      @dir = dir
      @logger = logger || Logger.new($stdout)
      @popups = []
    end

    def accept_cookies
      if page.has_content? 'Accept all cookies'
        click_on 'Accept all cookies' rescue nil
      end
    end

    def login
      logger.debug "Logging in"
      visit 'https://www.hsbc.co.uk/'
      accept_cookies
      click_on 'Log on'
      accept_cookies
      fill_in('username', with: @username)
      click_on 'Continue'
      accept_cookies
      fill_in('offlineotp', with: @token)
      click_on 'Log on'
      # fill_in('memorableAnswer', with: @memorable)
      # click_on 'Continue'
      accept_cookies
      if page.has_content? 'View more'
        logger.debug 'Logged in.'
      end
    end

    def download_statement(account_name = nil)
      select_account(account_name) if account_name
      logger.debug "Selecting #{account_name.inspect}"
      if page.has_content? 'Show next 100 transactions'
        click_on 'Show next 100 transactions'
      end
      begin
        click_on 'Download'
      rescue Capybara::ElementNotFound
        logger.info 'Download element not available.'
        click_on "Back to your accounts"
        return :not_downloaded
      end
      find('label[for="ofx"]').click
      sleep 1
      within('.modal-footer') do
        click_on 'Continue'
        block_until_downloaded
      end
      click_on "Back to your accounts"
    end

    def block_until_downloaded
      Timeout.timeout(15) do
        loop do
          return if File.exist?(File.join(dir, 'TransactionHistory.ofx'))
          sleep 0.2
        end
      end
    end

    def rename_statement(name)
      date = Date.today.iso8601
      clean_account_name = name.gsub(' ', '_').gsub('/', '_')
      src = File.join(dir, 'TransactionHistory.ofx')
      dstdir = File.join(dir, date.to_s)
      FileUtils.mkdir_p dstdir
      dst = File.join(dstdir, "#{clean_account_name}_#{date}.ofx")
      logger.debug "Renaming #{src} to #{dst}"
      FileUtils.mv src, dst
    end

    def select_account(name)
      find("span", text: name, match: :prefer_exact).click
    end

    def logout
      click_on 'Log off'
    end

    def console
      require 'pry'; binding.pry
    end
  end
end

if $PROGRAM_NAME == __FILE__
  logger = Logger.new($stdout)
  logger.level = Logger::DEBUG

  username =  ENV.fetch('BANK_USERNAME')
  memorable = ENV.fetch('BANK_MEMORABLE')

  puts 'Provide one time token: '
  token = gets.chomp
  bank = Bank::HSBC.new(
    username: username,
    memorable: memorable,
    token: token,
    dir: statements_directory,
    logger: logger
  )

  bank.login
  sleep 1.0

  begin
    accounts = ENV.fetch('ACCOUNTS').split(',')
    accounts.each do |account|
      logger.info "Downloading statement for: #{account}"
      result = bank.download_statement(account)
      next if result == :not_downloaded

      bank.rename_statement(account)
      logger.info 'completed.'
    end
  rescue => err
    logger.error err
    bank.console
  ensure
    bank.logout
  end
end
