# Be sure to restart your server when you modify this file

# Specifies gem version of Rails to use when vendor/rails is not present
RAILS_GEM_VERSION = '2.3.9' unless defined? RAILS_GEM_VERSION

# Bootstrap the Rails environment, frameworks, and default configuration
require File.join(File.dirname(__FILE__), 'boot')

# This is because the aws-s3 gem is using the XML:: namespace instead of LIBXML::
require 'xml/libxml'

Rails::Initializer.run do |config|
  # Settings in config/environments/* take precedence over those specified here.
  # Application configuration should go into files in config/initializers
  # -- all .rb files in that directory are automatically loaded.
  # See Rails::Configuration for more options.

  # Skip frameworks you're not going to use. To use Rails without a database
  # you must remove the Active Record framework.
  # config.frameworks -= [ :active_record, :active_resource, :action_mailer ]

  # dont specify gems here, use the gemfile with bundler, see: http://gembundler.com/

  # Only load the plugins named here, in the order given. By default, all plugins 
  # in vendor/plugins are loaded in alphabetical order.
  # :all can be used as a placeholder for all plugins not explicitly named
  # config.plugins = [ :exception_notification, :ssl_requirement, :all ]

  # Add additional load paths for your own custom dirs
  # config.autoload_paths += %W( #{RAILS_ROOT}/extras )

  # Force all environments to use the same logger level
  # (by default production uses :info, the others :debug)
  # config.log_level = :debug

  # Make Time.zone default to the specified zone, and make Active Record store time values
  # in the database in UTC, and return them converted to the specified local zone.
  # Run "rake -D time" for a list of tasks for finding time zone names. Comment line to use default local time.
  config.time_zone = 'UTC'

  memcache_servers = (YAML.load_file(RAILS_ROOT + "/config/memcache.yml")[RAILS_ENV] || []) rescue []
  if memcache_servers.empty?
    config.cache_store = :nil_store
  else
    config.cache_store = :mem_cache_store, *memcache_servers
  end

  # Use the database for sessions instead of the cookie-based default,
  # which shouldn't be used to store highly confidential information
  # (create the session table with "rake db:sessions:create")
  config.action_controller.session_store = :active_record_store
  
  # Use SQL instead of Active Record's schema dumper when creating the test database.
  # This is necessary if your schema can't be completely dumped by the schema dumper,
  # like if you have constraints or database-specific column types
  # config.active_record.schema_format = :sql

  # Activate observers that should always be running
  # config.active_record.observers = :cacher, :garbage_collector
  
  config.autoload_paths += %W( #{RAILS_ROOT}/app/middleware )
  
  config.middleware.use("RequestContextGenerator")
end

# Extend any base classes, even gem classes
Dir.glob("#{RAILS_ROOT}/lib/ext/**/*.rb").each { |file| require file }

Canvas::Security.encryption_key


# Require parts of the lib that are interesting
%w(
  gradebook_csv_parser 
  workflow  
  file_splitter   
  gradebook_importer 
  auto_handle
  zip_extractor
).each { |f| require f }

require 'kaltura/kaltura_client_v3'

ActionController::Dispatcher.middleware.use FlashSessionCookieMiddleware, '_normandy_session'

# tell Rails to use the native XML parser instead of REXML
ActiveSupport::XmlMini.backend = 'LibXML'

class NotImplemented < StandardError; end

HostUrl.configure_email(if File.exist?(RAILS_ROOT + "/config/outgoing_mail.yml")
    YAML.load_file(RAILS_ROOT + "/config/outgoing_mail.yml")[RAILS_ENV]
  else
    {:domain => "unknowndomain.example.com"}
  end)
