#
# PerfectSched
#
# Copyright (C) 2012 FURUHASHI Sadayuki
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

module PerfectSched
  module Backend
    class RDBCompatBackend
      include BackendHelper

      class Token < Struct.new(:row_id, :scheduled_time, :cron, :delay, :timezone)
      end

      def initialize(client, config)
        super

        require 'sequel'
        url = config[:url]
        unless url
          raise ConfigError, "url option is required for the rdb_compat backend"
        end

        @table = config[:table]
        unless @table
          raise ConfigError, "table option is required for the rdb_compat backend"
        end

        #password = config[:password]
        #user = config[:user]
        @db = Sequel.connect(url, :max_connections=>1)
        @mutex = Mutex.new

        connect {
          # connection test
        }
      end

      MAX_SELECT_ROW = 4

      attr_reader :db

      def get_schedule_metadata(key, options={})
        connect {
          row = @db.fetch("SELECT id, timeout, next_time, cron, delay, data, timezone FROM `#{@table}` LIMIT 1").first
          unless row
            raise NotFoundError, "schedule key=#{key} does not exist"
          end
          attributes = create_attributes(row)
          return ScheduleMetadata.new(@client, key, attributes)
        }
      end

      def list(options, &block)
        connect {
          @db.fetch("SELECT id, timeout, next_time, cron, delay, data, timezone FROM `#{@table}` ORDER BY timeout ASC") {|row|
            attributes = create_attributes(row)
            sched = ScheduleWithMetadata.new(@client, row[:id], attributes)
            yield sched
          }
        }
      end

      def submit(key, type, cron, delay, timezone, data, next_time, next_run_time, options)
        data = data.dup
        data[:type] = type
        connect {
          begin
            n = @db["INSERT INTO `#{@table}` (id, timeout, next_time, cron, delay, data, timezone) VALUES (?, ?, ?, ?, ?, ?, ?);", key, next_run_time, next_time, cron, delay, data.to_json, timezone].insert
            return Schedule.new(@client, key)
          rescue Sequel::DatabaseError
            raise AlreadyExistsError, "schedule key=#{key} already exists"
          end
        }
      end

      def delete(key, options)
        connect {
          n = @db["DELETE FROM `#{@table}` WHERE id=?;", key].delete
          if n <= 0
            raise NotFoundError, "schedule key=#{key} does no exist"
          end
        }
      end

      def modify(key, options)
        ks = []
        vs = []
        [:cron, :delay, :timezone].each {|k|
          # TODO type and data are not supported
          if v = options[k]
            ks << k
            vs << v
          end
        }
        return nil if ks.empty?

        sql = "UPDATE `#{@table}` SET "
        sql << ks.map {|k| "#{k}=?" }.join(', ')
        sql << " WHERE id=?"

        args = [sql].concat(vs)
        args << key

        connect {
          n = @db[*args].update
          if n <= 0
            raise NotFoundError, "schedule key=#{key} does not exist"
          end
        }
      end

      def acquire(alive_time, max_acquire, options)
        now = (options[:now] || Time.now).to_i
        next_timeout = now + alive_time

        connect {
          while true
            rows = 0
            @db.fetch("SELECT id, timeout, next_time, cron, delay, data, timezone FROM `#{@table}` WHERE timeout <= ? ORDER BY timeout ASC LIMIT #{MAX_SELECT_ROW};", now) {|row|

              n = @db["UPDATE `#{@table}` SET timeout=? WHERE id=? AND timeout=?;", next_timeout, row[:id], row[:timeout]].update
              if n > 0
                scheduled_time = Time.at(row[:next_time]).utc
                attributes = create_attributes(row)
                task_token = Token.new(row[:id], row[:next_time], attributes[:cron], attributes[:delay], attributes[:timezone])
                task = Task.new(@client, row[:id], attributes, scheduled_time, task_token)
                return [task]
              end

              rows += 1
            }
            if rows < MAX_SELECT_ROW
              return nil
            end
          end
        }
      end

      def heartbeat(task_token, alive_time, options)
        now = (options[:now] || Time.now).to_i
        row_id = task_token.row_id
        scheduled_time = task_token.scheduled_time
        next_run_time = now + alive_time

        connect {
          n = @db["UPDATE `#{@table}` SET timeout=? WHERE id=? AND next_time=?;", next_run_time, row_id, scheduled_time].update
          if n < 0
            raise AlreadyFinishedError, "task time=#{Time.at(scheduled_time).utc} is already finished"
          end
        }
      end

      def finish(task_token, options)
        row_id = task_token.row_id
        scheduled_time = task_token.scheduled_time
        next_time = PerfectSched.next_time(task_token.cron, scheduled_time, task_token.timezone)
        next_run_time = next_time + task_token.delay

        connect {
          n = @db["UPDATE `#{@table}` SET timeout=?, next_time=? WHERE id=? AND next_time=?;", next_run_time, next_time, row_id, scheduled_time].update
          if n < 0
            raise AlreadyFinishedError, "task time=#{Time.at(scheduled_time).utc} is already finished"
          end
        }
      end

      protected
      def connect(&block)
        @mutex.synchronize do
          retry_count = 0
          begin
            block.call
          rescue
            # workaround for "Mysql2::Error: Deadlock found when trying to get lock; try restarting transaction" error
            if $!.to_s.include?('try restarting transaction')
              err = ([$!] + $!.backtrace.map {|bt| "  #{bt}" }).join("\n")
              retry_count += 1
              if retry_count < MAX_RETRY
                STDERR.puts err + "\n  retrying."
                sleep 0.5
                retry
              else
                STDERR.puts err + "\n  abort."
              end
            end
            raise
          ensure
            @db.disconnect
          end
        end
      end

      def create_attributes(row)
        timezone = row[:timezone] || 'UTC'
        delay = row[:delay] || 0
        cron = row[:cron]
        next_time = Time.at(row[:next_time]).utc
        next_run_time = Time.at(row[:timeout]).utc

        begin
          data = JSON.parse(row[:data] || '{}')
        rescue
          data = {}
        end

        type = data.delete('type') || ''

        attributes = {
          :timezone => timezone,
          :delay => delay,
          :cron => cron,
          :data => data,
          :next_time => next_time,
          :next_run_time => next_run_time,
          :type => type,
          :message => nil,  # not supported
          :node => nil,  # not supported
        }
      end

    end
  end
end
