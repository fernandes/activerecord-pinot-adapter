require "active_record/pinot/adapter"
require "active_record/connection_adapters/pinot_adapter/table_structure"

module ActiveRecord
  module ConnectionHandling # :nodoc:
    def pinot_adapter_class
      ConnectionAdapters::PinotAdapter
    end

    def pinot_connection(config)
      pinot_adapter_class.new(config)
    end
  end

  module ConnectionAdapters
    class PinotAdapter < AbstractAdapter
      TYPES = {
        "INT" => Type::Integer.new,
        "TIMESTAMP" => Type::DateTime.new,
        "FLOAT" => Type::Decimal.new,
        "LONG" => Type::Decimal.new
      }
      def initialize(config = {})
        @pinot_host = config.fetch(:host)
        @pinot_port = config.fetch(:port)
        @pinot_controller_port = config.fetch(:controller_port)
        # TODO: does it need connection pooling?
        @pinot_client = ::Pinot::Client.new(host: @pinot_host, port: @pinot_port, controller_port: @pinot_controller_port)

        super(config)
      end

      def default_prepared_statements
        false
      end

      def table_structure(table_name)
        schema = @pinot_client.schema(table_name)
        @table_structure = TableStructure.from_schema(schema)
        @table_structure.sort_by! { |x| x[:name] }
      end

      def new_column_from_field(table_name, field, definitions)
        default = nil

        type_metadata = fetch_type_metadata(field["type"])
        default_value = extract_value_from_default(default)
        default_function = extract_default_function(default_value, default)
        rowid = is_column_the_rowid?(field, definitions)

        Column.new(
          field["name"],
          default_value,
          type_metadata,
          field["notnull"].to_i == 0,
          default_function,
          collation: field["collation"]
        )
      end
      alias_method :column_definitions, :table_structure

      def extract_value_from_default(default)
        case default
        when /^null$/i
          nil
        # Quoted types
        when /^'([^|]*)'$/m
          $1.gsub("''", "'")
        # Quoted types
        when /^"([^|]*)"$/m
          $1.gsub('""', '"')
        # Numeric types
        when /\A-?\d+(\.\d*)?\z/
          $&
        # Binary columns
        when /x'(.*)'/
          [$1].pack("H*")
        else
          # Anything else is blank or some function
          # and we can't know the value of that, so return nil.
          nil
        end
      end

      def extract_default_function(default_value, default)
        default if has_default_function?(default_value, default)
      end

      def has_default_function?(default_value, default)
        !default_value && %r{\w+\(.*\)|CURRENT_TIME|CURRENT_DATE|CURRENT_TIMESTAMP|\|\|}.match?(default)
      end

      INTEGER_REGEX = /integer/i
      def is_column_the_rowid?(field, column_definitions)
        return false unless INTEGER_REGEX.match?(field["type"]) && field["pk"] == 1
        # is the primary key a single column?
        column_definitions.one? { |c|
          col_pk = c["pk"] || 0
          col_pk > 0
        }
      end

      def internal_exec_query(sql, name = "SQL", binds = [], prepare: false, async: false) # :nodoc:
        # rows = [
        #   [Time.now, 1, 2.0],
        #   [Time.now, 2, 2.0],
        #   [Time.now, 2, 2.0]
        # ]
        response = @pinot_client.execute(sql)
        rows = response.rows
        columns = response.columns
        columns.transform_values! { |value| TYPES.fetch(value, value) }
        ActiveRecord::Result.new(
          response.columns.keys,
          rows.to_a,
          columns
        )
      end

      def data_source_sql(name = nil, type: nil)
      end

      def primary_keys(table_name)
        []
      end
    end

    ActiveSupport.run_load_hooks(:active_record_pinotadapter, PinotAdapter)
  end
end
