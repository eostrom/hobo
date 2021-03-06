require 'hobosupport'

if ActiveSupport::Dependencies.respond_to?(:autoload_paths)
  ActiveSupport::Dependencies.autoload_paths |= [ File.dirname(__FILE__)]
else
  ActiveSupport::Dependencies.load_paths |= [ File.dirname(__FILE__)]
end

module Hobo
  # Empty class to represent the boolean type.
  class Boolean; end
end

module HoboFields

  VERSION = "1.1.0.pre3"

  extend self

  PLAIN_TYPES = {
    :boolean       => Hobo::Boolean,
    :date          => Date,
    :datetime      => (defined?(ActiveSupport::TimeWithZone) ? ActiveSupport::TimeWithZone : Time),
    :time          => Time,
    :integer       => Integer,
    :decimal       => BigDecimal,
    :float         => Float,
    :string        => String
  }

  ALIAS_TYPES = {
    Fixnum => "integer",
    Bignum => "integer"
  }

  # Provide a lookup for these rather than loading them all preemptively
  
  STANDARD_TYPES = {
    :raw_html      => "RawHtmlString",
    :html          => "HtmlString",
    :raw_markdown  => "RawMarkdownString",
    :markdown      => "MarkdownString",
    :textile       => "TextileString",
    :password      => "PasswordString",
    :text          => "Text",
    :email_address => "EmailAddress",
    :serialized    => "SerializedObject"
  }

  @field_types   = PLAIN_TYPES.with_indifferent_access
  
  @never_wrap_types = Set.new([NilClass, Hobo::Boolean, TrueClass, FalseClass])

  attr_reader :field_types

  def to_class(type)
    if type.is_one_of?(Symbol, String)
      type = type.to_sym
      field_types[type] || standard_class(type)
    else
      type # assume it's already a class
    end
  end


  def to_name(type)
    field_types.key(type) || ALIAS_TYPES[type]
  end


  if Object.instance_method(:initialize).arity!=0
    # version for Ruby 1.9.
    def can_wrap?(type, val)
      col_type = type::COLUMN_TYPE
      return false if val.blank? && (col_type == :integer || col_type == :float || col_type == :decimal)
      klass = Object.instance_method(:class).bind(val).call # Make sure we get the *real* class
      init_method = type.instance_method(:initialize)
      [-1,1].include?(init_method.arity) &&
        init_method.owner != Object.instance_method(:initialize).owner &&
        !@never_wrap_types.any? { |c| klass <= c }
    end
  else
    # Ruby 1.8.  1.8.6 doesn't include Method#owner.   1.8.7 could use
    # the 1.9 function, but this one is faster.
    def can_wrap?(type, val)
      col_type = type::COLUMN_TYPE
      return false if val.blank? && (col_type == :integer || col_type == :float || col_type == :decimal)
      klass = Object.instance_method(:class).bind(val).call # Make sure we get the *real* class
      init_method = type.instance_method(:initialize)
      [-1,1].include?(init_method.arity) && !@never_wrap_types.any? { |c| klass <= c }
    end
  end


  def never_wrap(type)
    @never_wrap_types << type
  end


  def register_type(name, klass)
    field_types[name] = klass
  end


  def plain_type?(type_name)
    type_name.in?(PLAIN_TYPES)
  end


  def standard_class(name)
    class_name = STANDARD_TYPES[name]
    "HoboFields::#{class_name}".constantize if class_name
  end

  def enable
    require "hobo_fields/enum_string"
    require "hobo_fields/fields_declaration"

    # Add the fields do declaration to ActiveRecord::Base
    ActiveRecord::Base.send(:include, HoboFields::FieldsDeclaration)

    # automatically load other rich types from app/rich_types/*.rb
    # don't assume we're in a Rails app
    if defined?(::Rails)
      plugins = Rails.configuration.plugin_loader.new(HoboFields.rails_initializer).plugins
      ([::Rails.root] + plugins.map(&:directory)).each do |dir|
        if ActiveSupport::Dependencies.respond_to?(:autoload_paths)
          ActiveSupport::Dependencies.autoload_paths << File.join(dir, 'app', 'rich_types')
        else
          ActiveSupport::Dependencies.load_paths << File.join(dir, 'app', 'rich_types')
        end
        Dir[File.join(dir, 'app', 'rich_types', '*.rb')].each do |f|
          # TODO: should we complain if field_types doesn't get a new value? Might be useful to warn people if they're missing a register_type
          require_dependency f
        end
      end

    end

    # Monkey patch ActiveRecord so that the attribute read & write methods
    # automatically wrap richly-typed fields.
    ActiveRecord::AttributeMethods::ClassMethods.class_eval do

      # Define an attribute reader method.  Cope with nil column.
      def define_read_method(symbol, attr_name, column)
        cast_code = column.type_cast_code('v') if column
        access_code = cast_code ? "(v=@attributes['#{attr_name}']) && #{cast_code}" : "@attributes['#{attr_name}']"

        unless attr_name.to_s == self.primary_key.to_s
          access_code = access_code.insert(0, "missing_attribute('#{attr_name}', caller) " +
                                           "unless @attributes.has_key?('#{attr_name}'); ")
        end

        # This is the Hobo hook - add a type wrapper around the field
        # value if we have a special type defined
        src = if connected? && (type_wrapper = try.attr_type(symbol)) &&
                  type_wrapper.is_a?(Class) && type_wrapper.not_in?(HoboFields::PLAIN_TYPES.values)
                "val = begin; #{access_code}; end; wrapper_type = self.class.attr_type(:#{attr_name}); " +
                  "if HoboFields.can_wrap?(wrapper_type, val); wrapper_type.new(val); else; val; end"
              else
                access_code
              end

        evaluate_attribute_method(attr_name,
                                  "def #{symbol}; @attributes_cache['#{attr_name}'] ||= begin; #{src}; end; end")
      end

      def define_write_method(attr_name)
        src = if connected? && (type_wrapper = try.attr_type(attr_name)) &&
                  type_wrapper.is_a?(Class) && type_wrapper.not_in?(HoboFields::PLAIN_TYPES.values)
                "begin; wrapper_type = self.class.attr_type(:#{attr_name}); " +
                  "if !val.is_a?(wrapper_type) && HoboFields.can_wrap?(wrapper_type, val); wrapper_type.new(val); else; val; end; end"
              else
                "val"
              end
        evaluate_attribute_method(attr_name,
                                  "def #{attr_name}=(val); write_attribute('#{attr_name}', #{src});end", "#{attr_name}=")

      end

    end

  end

end
