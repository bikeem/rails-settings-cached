module RailsSettings
  module Extend
    extend ActiveSupport::Concern

    included do
      scope :with_settings, lambda {
        st = RailsSettings::Settings.quoted_table_name
        joins(sanitize_sql_array(["JOIN #{st} ON (#{st}.thing_id = #{quoted_table_name}.#{quoted_primary_key} AND #{st}.thing_type = ?)", base_class.name]))
          .select("DISTINCT #{quoted_table_name}.*")
      }

      scope :with_settings_for, lambda { |var|
        st = RailsSettings::Settings.quoted_table_name
        joins(sanitize_sql_array(["JOIN #{st} ON (#{st}.thing_id = #{quoted_table_name}.#{quoted_primary_key} AND #{st}.thing_type = ?) AND #{st}.var = ?", base_class.name, var]))
      }

      scope :without_settings, lambda {
        st = RailsSettings::Settings.quoted_table_name
        joins(sanitize_sql_array(["LEFT JOIN #{st} ON (#{st}.thing_id = #{quoted_table_name}.#{quoted_primary_key} AND #{st}.thing_type = ?)", base_class.name]))
          .where("#{st}.id IS NULL")
      }

      scope :without_settings_for, lambda { |var|
        st = RailsSettings::Settings.quoted_table_name
        where("#{st}.id IS NULL")
          .joins(sanitize_sql_array(["LEFT JOIN #{st} ON (#{st}.thing_id = #{quoted_table_name}.#{quoted_primary_key} AND #{st}.thing_type = ?) AND #{st}.var = ?", base_class.name, var]))
      }
    end

    # Memoised per record instance so that a stub placed on `record.settings` in a test is the
    # same handle the code under test uses.
    #
    # The memo is validated against its owner rather than trusted: `dup` copies instance variables,
    # so a bare `||=` would hand the copy a handle still bound to the ORIGINAL record and send its
    # writes to the original's rows. `equal?`, not `==` -- AR compares records by id, and a dup of
    # a saved record has a nil id, so `==` would still alias. The scope is re-read too, so a
    # settings_scope derived from an attribute cannot go stale.
    def settings
      scope = respond_to?(:settings_scope) ? settings_scope : nil
      unless @rails_settings_scope_owner.equal?(self) && @rails_settings_scope_key == scope
        @rails_settings_scope_owner = self
        @rails_settings_scope_key = scope
        @rails_settings_scope = ScopedSettings.for_thing(self, scope)
      end
      @rails_settings_scope
    end
  end
end
