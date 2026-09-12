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

    def settings
      ScopedSettings.for_thing(self, respond_to?(:settings_scope) ? settings_scope : nil)
    end
  end
end
