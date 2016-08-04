require 'influxdb'
require 'timezone'

module Embulk
  module Output

    class Influxdb < OutputPlugin
      Plugin.register_output("influxdb", self)

      def self.transaction(config, schema, count, &control)
        # configuration code:
        task = {
          "host" => config.param("host", :string, default: nil),
          "hosts" => config.param("hosts", :array, default: nil),
          "port" => config.param("port", :integer, default: 8086),
          "username" => config.param("username", :string, default: "root"),
          "password" => config.param("password", :string, default: "root"),
          "database" => config.param("database", :string),
          "series" => config.param("series", :string, default: nil),
          "series_per_column" => config.param("series_per_column", :bool, default: false),
          "timestamp_column" => config.param("timestamp_column", :string, default: nil),
          "ignore_columns" => config.param("ignore_columns", :array, default: []),
          "default_timezone" => config.param("default_timezone", :string, default: "UTC"),
          "mode" => config.param("mode", :string, default: "insert"),
          "use_ssl" => config.param("use_ssl", :bool, default: false),
          "verify_ssl" => config.param("verify_ssl", :bool, default: true),
          "ssl_ca_cert" => config.param("ssl_ca_cert", :string, default: nil),
          "time_precision" => config.param("time_precision", :string, default: "s"),
          "initial_delay" => config.param("initial_delay", :float, default: 0.01),
          "max_delay" => config.param("max_delay", :float, default: 30),
          "open_timeout" => config.param("open_timeout", :integer, default: 5),
          "read_timeout" => config.param("read_timeout", :integer, default: 300),
          "async" => config.param("async", :bool, default: false),
          "udp" => config.param("udp", :bool, default: false),
          "retry" => config.param("retry", :integer, default: nil),
          "denormalize" => config.param("denormalize", :bool, default: true),
        }

        # resumable output:
        # resume(task, schema, count, &control)

        # non-resumable output:
        task_reports = yield(task)
        next_config_diff = {}
        return next_config_diff
      end

      #def self.resume(task, schema, count, &control)
      #  task_reports = yield(task)
      #
      #  next_config_diff = {}
      #  return next_config_diff
      #end

      def self.replaced_series
        @replaced_series ||= {}
      end

      def init
        # initialization code:
        task["hosts"] ||= Array(task["host"] || "localhost")
        @database = task["database"]
        @series = task["series"]
        @series_per_column = task["series_per_column"]
        unless @series
          raise "Need series or series_per_column parameter" unless @series_per_column
        end
        if task["timestamp_column"]
          @timestamp_column = schema.find { |col| col.name == task["timestamp_column"] }
        end
        @ignore_columns = task["ignore_columns"]
        @time_precision = task["time_precision"]
        @replace = task["mode"].downcase == "replace"
        @default_timezone = task["default_timezone"]

        @connection = InfluxDB::Client.new(@database,
          task.map { |k, v| [k.to_sym, v] }.to_h
        )
        create_database_if_not_exist
      end

      def close
      end

      def add(page)
        data = @series ? build_payload(page) : build_payload_per_column(page)

        Embulk.logger.info { "embulk-output-influxdb: Writing to #{@database}" }
        Embulk.logger.debug { "embulk-output-influxdb: #{data}" }

        @connection.write_points(data, @async, @time_precision)
      end

      def finish
      end

      def abort
      end

      def commit
        task_report = {}
        return task_report
      end

      private

      def build_payload(page)
        data = page.map do |record|
          series = resolve_placeholder(record, @series)
          delete_series_if_exist(series)
          payload = {
            name: series,
            data: Hash[
              target_columns.map { |col| [col.name, convert_timezone(record[col.index])] }
            ],
          }
          payload[:data][:time] = convert_timezone(record[@timestamp_column.index]).to_i if @timestamp_column
          payload
        end
      end

      def build_payload_per_column(page)
        page.flat_map do |record|
          target_columns.map do |col|
            series = col.name
            delete_series_if_exist(series)
            payload = {
              name: series,
              data: {value: record[col.index]},
            }
            payload[:data][:time] = convert_timezone(record[@timestamp_column.index]).to_i if @timestamp_column
            payload
          end
        end
      end

      def delete_series_if_exist(series)
        if @replace && self.class.replaced_series[series].nil? && find_series(series)
          Embulk.logger.info { "embulk-output-influxdb: Delete series #{series} from #{@database}" }
          self.class.replaced_series[series] = true
          @connection.delete_series(series)
        end
      end

      def find_series(series)
        @connection.query('LIST SERIES')["list_series_result"].find { |v|
          v["name"] == series
        }
      end

      def create_database_if_not_exist
        unless @connection.get_database_list.any? { |db| db["name"] == @database }
          @connection.create_database(@database)
        end
      end

      def resolve_placeholder(record, series)
        series.gsub(/\$\{(.*?)\}/) do |name|
          index = schema.index { |col| col.name == $1 }
          record[index]
        end
      end

      def target_columns
        schema.reject do |col|
          col.name == @timestamp_column.name || @ignore_columns.include?(col.name)
        end
      end

      def convert_timezone(value)
        return value unless value.is_a?(Time)

        timezone = Timezone::Zone.new(zone: @default_timezone)
        timezone.time(value)
      end
    end
  end
end
