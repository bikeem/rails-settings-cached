$:.push File.expand_path("../lib", __FILE__)

require 'rspec'
require 'rails/all'
require 'sqlite3'
require 'fileutils'

require 'simplecov'
SimpleCov.start

# Rails >= 5 default. Must be set before the gem's Settings class runs `belongs_to`,
# because the presence validation is decided at definition time (spec D4).
ActiveRecord::Base.belongs_to_required_by_default = true

require 'rails-settings-cached'

if RailsSettings::Settings.respond_to? :raise_in_transactional_callbacks=
  RailsSettings::Settings.raise_in_transactional_callbacks = true
end

class TestApplication < Rails::Application
end

module Rails
  def self.root
    Pathname.new(File.expand_path("../", __FILE__))
  end

  def self.cache
    @cache ||= ActiveSupport::Cache::MemoryStore.new
  end

  def self.env
    'test'
  end
end


# Like count_queries but ignores BEGIN/COMMIT/SAVEPOINT bookkeeping, which sqlite defers until the
# first real statement -- so an otherwise-correct "this costs N queries" assertion can pick up a
# stray BEGIN depending on what ran before it.
def count_setting_queries(&block)
  count = 0
  counter = ->(_name, _started, _finished, _id, payload) do
    count += 1 unless %w[CACHE SCHEMA TRANSACTION].include?(payload[:name].to_s)
  end
  ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)
  count
end

def count_queries &block
  count = 0

  counter_f = ->(name, started, finished, unique_id, payload) {
    unless payload[:name].in? %w[ CACHE SCHEMA ]
      count += 1
    end
  }

  ActiveSupport::Notifications.subscribed(counter_f, "sql.active_record", &block)

  count
end

# run cache + executor initializers; they receive the application like a real boot would
RailsSettings::Railtie.initializers.each { |initializer| initializer.run(Rails.application) }

# A file-backed database: in-memory sqlite is per-connection, so a second thread would not
# see the schema (needed by the concurrency spec). Recreated on every run.
# Per-process path so concurrent rspec runs (e.g. a matrix run, or two terminals) cannot
# clobber each other's schema; removed again when the process exits.
DB_PATH = File.expand_path("../tmp/test-#{Process.pid}.sqlite3", __FILE__)
FileUtils.mkdir_p(File.dirname(DB_PATH))
FileUtils.rm_f(DB_PATH)
at_exit { FileUtils.rm_f(Dir.glob("#{DB_PATH}*")) } # also the -wal/-shm sidecars
ActiveRecord::Base.establish_connection adapter: 'sqlite3', database: DB_PATH, pool: 5

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define(version: 1) do
  create_table :settings do |t|
    t.string :var, null: false
    t.text :value
    t.integer :thing_id
    t.string :thing_type, limit: 30
    t.datetime :created_at
    t.datetime :updated_at
  end

  create_table :users do |t|
    t.string :login
    t.string :password
    t.string :type
    t.datetime :created_at
    t.datetime :updated_at
  end

  create_table :partners do |t|
    t.string :code
  end
end

RSpec.configure do |config|
  # Scope state is per thread and survives an example; without this a later example asserting
  # MissingScope would silently depend on run order.
  config.before(:each) { RailsSettings::ScopedSettings.clear_current! }

  config.before(:all) do
    class Setting < RailsSettings::Base
    end

    class CustomSetting < RailsSettings::Base
      table_name = 'custom_settings'
    end

    class User < ActiveRecord::Base
      include RailsSettings::Extend
    end

    # STI child of User: its settings rows must be addressed under the base class.
    class AdminUser < User
    end

    # A model whose settings_scope deliberately differs from its class name, so the precedence
    # between the two inside scoped_key can be observed at all.
    class Account < ActiveRecord::Base
      self.table_name = 'partners'
      include RailsSettings::Extend

      def settings_scope
        'acct'
      end
    end

    # Mirrors MEX's Partner: Extend + a settings_scope that prefixes every key.
    class Partner < ActiveRecord::Base
      include RailsSettings::Extend

      def settings_scope
        'partner'
      end
    end

    ActiveRecord::Base.connection.execute('delete from settings')
    Rails.cache.clear
  end

  config.after(:all) do
    Object.send(:remove_const, :Setting)
  end
end

Rails.application.instance_variable_set("@initialized", true)
