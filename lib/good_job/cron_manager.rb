# frozen_string_literal: true

require "concurrent/hash"
require "concurrent/scheduled_task"
require "fugit"

module GoodJob # :nodoc:
  #
  # CronManagers enqueue jobs on a repeating schedule.
  #
  class CronManager
    # @!attribute [r] instances
    #   @!scope class
    #   List of all instantiated CronManagers in the current process.
    #   @return [Array<GoodJob::CronManager>, nil]
    cattr_reader :instances, default: Concurrent::Array.new, instance_reader: false

    # Task observer for cron task
    # @param time [Time]
    # @param output [Object]
    # @param thread_error [Exception]
    def self.task_observer(time, output, thread_error) # rubocop:disable Lint/UnusedMethodArgument
      return if thread_error.is_a? Concurrent::CancelledOperationError

      GoodJob._on_thread_error(thread_error) if thread_error
    end

    # Execution configuration to be scheduled
    # @return [Hash]
    attr_reader :cron_entries

    # @param cron_entries [Array<CronEntry>]
    # @param start_on_initialize [Boolean]
    def initialize(cron_entries = [], start_on_initialize: false, graceful_restart_period: nil, executor: Concurrent.global_io_executor)
      @executor = executor
      @running = false
      @cron_entries = cron_entries
      @tasks = Concurrent::Hash.new
      @graceful_restart_period = graceful_restart_period

      start if start_on_initialize
      self.class.instances << self
    end

    # Schedule tasks that will enqueue jobs based on their schedule
    def start
      ActiveSupport::Notifications.instrument("cron_manager_start.good_job", cron_entries: cron_entries) do
        @running = true
        cron_entries.each do |cron_entry|
          create_task(cron_entry)
          create_graceful_tasks(cron_entry) if @graceful_restart_period
        end
      end
    end

    # Stop/cancel any scheduled tasks
    # @param timeout [Numeric, nil] Unused but retained for compatibility
    def shutdown(timeout: nil) # rubocop:disable Lint/UnusedMethodArgument
      @running = false
      @tasks.each_value(&:cancel)
      @tasks.clear
    end

    # Stop and restart
    # @param timeout [Numeric, nil] Unused but retained for compatibility
    def restart(timeout: nil) # rubocop:disable Lint/UnusedMethodArgument
      shutdown
      start
    end

    # Tests whether the manager is running.
    # @return [Boolean, nil]
    def running?
      @running
    end

    # Tests whether the manager is shutdown.
    # @return [Boolean, nil]
    def shutdown?
      !running?
    end

    # Enqueues a scheduled task
    # @param cron_entry [CronEntry] the CronEntry object to schedule
    # @param previously_at [Date, Time, ActiveSupport::TimeWithZone, nil] the last, +in-memory+, scheduled time the cron task was intended to run
    def create_task(cron_entry, previously_at: nil)
      cron_at = cron_entry.next_at(previously_at: previously_at)
      delay = [(cron_at - Time.current).to_f, 0].max
      future = Concurrent::ScheduledTask.new(delay, args: [self, cron_entry, cron_at], executor: @executor) do |thr_scheduler, thr_cron_entry, thr_cron_at|
        # Re-schedule the next cron task before executing the current task
        thr_scheduler.create_task(thr_cron_entry, previously_at: thr_cron_at)

        Rails.application.executor.wrap do
          cron_entry.enqueue(thr_cron_at) if thr_cron_entry.enabled?
        end
      end

      @tasks[cron_entry.key] = future
      future.add_observer(self.class, :task_observer)
      future.execute
    end

    # Uses the graceful restart period to re-enqueue jobs that were scheduled to run during the period.
    # The existing uniqueness logic should ensure this does not create duplicate jobs.
    # @param cron_entry [CronEntry] the CronEntry object to schedule
    def create_graceful_tasks(cron_entry)
      return unless @graceful_restart_period

      time_period = @graceful_restart_period.ago..Time.current
      cron_entry.within(time_period).each do |cron_at|
        future = Concurrent::Future.new(args: [self, cron_entry, cron_at], executor: @executor) do |_thr_scheduler, thr_cron_entry, thr_cron_at|
          Rails.application.executor.wrap do
            cron_entry.enqueue(thr_cron_at) if thr_cron_entry.enabled?
          end
        end

        future.add_observer(self.class, :task_observer)
        future.execute
      end
    end
  end
end
