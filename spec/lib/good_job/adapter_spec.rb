# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GoodJob::Adapter do
  let(:adapter) { described_class.new(execution_mode: :external) }
  let(:active_job) { instance_double(ActiveJob::Base) }
  let(:good_job) { instance_double(GoodJob::Job, queue_name: 'default', scheduled_at: nil, job_state: { queue_name: 'default' }) }

  before do
    GoodJob.configuration.instance_variable_set(:@_in_webserver, nil)
  end

  describe '#initialize' do
    it 'uses the global configuration value' do
      allow(GoodJob.configuration).to receive(:execution_mode).and_return(:external)
      adapter = described_class.new
      expect(adapter.execution_mode).to eq(:external)
    end

    it 'guards against improper execution modes' do
      expect do
        described_class.new(execution_mode: :blarg)
      end.to raise_error ArgumentError
    end
  end

  describe '#enqueue' do
    it 'sets default values' do
      active_job = ExampleJob.new
      adapter.enqueue(active_job)

      expect(GoodJob::Job.last).to have_attributes(
        queue_name: 'default',
        priority: 0,
        scheduled_at: be_within(1.second).of(Time.current)
      )
    end

    it 'calls GoodJob::Job.enqueue with parameters' do
      allow(GoodJob::Job).to receive(:enqueue).and_return(good_job)

      adapter.enqueue(active_job)

      expect(GoodJob::Job).to have_received(:enqueue).with(
        active_job,
        scheduled_at: nil
      )
    end

    context 'when inline' do
      let(:adapter) { described_class.new(execution_mode: :inline) }

      before do
        stub_const 'PERFORMED', []
        stub_const 'JobError', Class.new(StandardError)
        stub_const 'TestJob', (Class.new(ActiveJob::Base) do
          def perform(succeed: true)
            PERFORMED << Time.current

            raise JobError unless succeed
          end
        end)
      end

      it 'executes the job immediately' do
        adapter.enqueue(TestJob.new(succeed: true))
        expect(PERFORMED.size).to eq 1
      end

      it "raises unhandled exceptions" do
        expect do
          adapter.enqueue(TestJob.new(succeed: false))
        end.to raise_error(JobError)

        expect(PERFORMED.size).to eq 1
      end

      it 'does not execute future scheduled jobs' do
        adapter.enqueue_at(TestJob.new, 1.minute.from_now.to_f)
        expect(PERFORMED.size).to eq 0
        expect(GoodJob::Job.count).to eq 1
      end
    end

    context 'when async' do
      it 'triggers the capsule and the notifier' do
        allow(GoodJob::Job).to receive(:enqueue).and_return(good_job)
        allow(GoodJob::Notifier).to receive(:notify)

        capsule = instance_double(GoodJob::Capsule, start: nil, create_thread: nil, "lower_thread_priority=": nil)
        allow(GoodJob).to receive(:capsule).and_return(capsule)
        allow(capsule).to receive(:start)

        adapter = described_class.new(execution_mode: :async_all)
        adapter.enqueue(active_job)

        expect(capsule).to have_received(:start)
        expect(capsule).to have_received(:create_thread)
        expect(GoodJob::Notifier).to have_received(:notify).with({ queue_name: 'default' })
      end

      it 'lowers the thread priority of the capsule' do
        capsule = instance_double(GoodJob::Capsule, start: nil, create_thread: nil, "lower_thread_priority=": nil)
        allow(GoodJob).to receive(:capsule).and_return(capsule)
        allow(capsule).to receive(:start)

        described_class.new(execution_mode: :async_all)

        expect(capsule).to have_received(:lower_thread_priority=).with(true)
      end
    end
  end

  describe '#enqueue_at' do
    it 'calls GoodJob::Job.enqueue with parameters' do
      allow(GoodJob::Job).to receive(:enqueue).and_return(good_job)

      scheduled_at = 1.minute.from_now

      adapter.enqueue_at(active_job, scheduled_at.to_i)

      expect(GoodJob::Job).to have_received(:enqueue).with(
        active_job,
        scheduled_at: scheduled_at.change(usec: 0)
      )
    end

    it 'sets default values' do
      active_job = ExampleJob.new
      adapter.enqueue_at(active_job, nil)

      expect(GoodJob::Job.last).to have_attributes(
        queue_name: 'default',
        priority: 0,
        scheduled_at: be_within(1.second).of(Time.current)
      )
    end
  end

  describe '#enqueue_all' do
    before do
      allow(GoodJob::Notifier).to receive(:notify)
    end

    it 'enqueues multiple active jobs, returns the number of jobs enqueued, and sets provider_job_id' do
      active_jobs = [ExampleJob.new, ExampleJob.new]
      result = adapter.enqueue_all(active_jobs)
      expect(result).to eq 2

      provider_job_ids = active_jobs.map(&:provider_job_id)
      expect(provider_job_ids).to all be_present
    end

    it 'enqueues queue_name, scheduled_at, priority' do
      active_job = ExampleJob.new
      active_job.queue_name = 'elephant'
      active_job.priority = -55
      active_job.scheduled_at = 10.minutes.from_now

      adapter.enqueue_all([active_job])

      expect(GoodJob::Job.last).to have_attributes(
        queue_name: 'elephant',
        priority: -55,
        scheduled_at: be_within(1).of(10.minutes.from_now)
      )
      expect(GoodJob::Notifier).to have_received(:notify).with({
                                                                 queue_name: 'elephant',
                                                                 count: 1,
                                                                 scheduled_at: within(1).of(10.minutes.from_now),
                                                               })
    end

    it 'sets default values' do
      active_job = ExampleJob.new
      adapter.enqueue_all([active_job])

      expect(GoodJob::Job.last).to have_attributes(
        queue_name: 'default',
        priority: 0,
        scheduled_at: be_within(1.second).of(Time.current)
      )

      expect(GoodJob::Notifier).to have_received(:notify).with({
                                                                 queue_name: 'default',
                                                                 count: 1,
                                                                 scheduled_at: within(1).of(Time.current),
                                                               })
    end

    context 'when a job fails to enqueue' do
      it 'does not set a provider_job_id' do
        allow(GoodJob::Job).to receive(:insert_all).and_wrap_original do |original_method, *args|
          attributes, kwargs = *args
          original_method.call(attributes[0, 1], **kwargs) #  pretend only the first item is successfully inserted
        end

        active_jobs = [ExampleJob.new, ExampleJob.new]
        result = adapter.enqueue_all(active_jobs)
        expect(result).to eq 1

        expect(active_jobs.map(&:provider_job_id)).to eq [active_jobs.first.provider_job_id, nil]
        expect(GoodJob::Notifier).to have_received(:notify).once.with({ queue_name: 'default', count: 1, scheduled_at: within(1).of(Time.current) })
      end

      it 'sets successfully_enqueued, if Rails supports it' do
        allow(GoodJob::Job).to receive(:insert_all).and_wrap_original do |original_method, *args|
          attributes, kwargs = *args
          original_method.call(attributes[0, 1], **kwargs) #  pretend only the first item is successfully inserted
        end

        active_jobs = [ExampleJob.new, ExampleJob.new]
        result = adapter.enqueue_all(active_jobs)
        expect(result).to eq 1

        expect(active_jobs.map(&:successfully_enqueued?)).to eq [true, false] if ActiveJob::Base.method_defined?(:successfully_enqueued?)
      end
    end

    context 'when the adapter is inline' do
      let(:adapter) { described_class.new(execution_mode: :inline) }

      before do
        stub_const 'PERFORMED', []
        stub_const 'SuccessJob', (Class.new(ActiveJob::Base) do
          def perform
            raise "Not advisory locked" unless GoodJob::Job.find(provider_job_id).advisory_locked?

            PERFORMED << Time.current
          end
        end)

        stub_const 'ErrorJob', (Class.new(ActiveJob::Base) do
          def perform
            raise "Not advisory locked" unless GoodJob::Job.find(provider_job_id).advisory_locked?

            PERFORMED << Time.current
            raise TestJob::Error, "Error"
          end
        end)
        stub_const 'TestJob::Error', Class.new(StandardError)
      end

      it 'executes the jobs immediately' do
        active_jobs = [SuccessJob.new, SuccessJob.new]
        result = adapter.enqueue_all(active_jobs)
        expect(result).to eq 2
        expect(PERFORMED.size).to eq 2
      end

      it 'raises an exception when the job errors' do
        active_jobs = [ErrorJob.new, SuccessJob.new]
        expect do
          adapter.enqueue_all(active_jobs)
        end.to raise_error(TestJob::Error)

        expect(PERFORMED.size).to eq 1
      end

      it 'does not execute future scheduled jobs' do
        allow(GoodJob::Notifier).to receive(:notify)
        scheduled_at = 1.minute.from_now
        future_job = SuccessJob.new.tap { |job| job.scheduled_at = scheduled_at }

        adapter.enqueue_all([SuccessJob.new, future_job])
        expect(PERFORMED.size).to eq 1
        expect(GoodJob::Notifier).to have_received(:notify).once
        expect(GoodJob::Notifier).to have_received(:notify).with(queue_name: 'default', count: 1, scheduled_at: scheduled_at)
      end
    end
  end

  describe '#shutdown' do
    it 'is callable' do
      expect { adapter.shutdown }.not_to raise_error
    end
  end

  describe '#stopping?' do
    it 'is callable' do
      expect { adapter.stopping? }.not_to raise_error
    end
  end

  describe '#execute_async?' do
    context 'when execution mode async_all' do
      let(:adapter) { described_class.new(execution_mode: :async_all) }

      it 'returns true' do
        expect(adapter.execute_async?).to be true
      end
    end

    context 'when execution mode async' do
      let(:adapter) { described_class.new(execution_mode: :async) }

      context 'when Rails::Server is defined' do
        before do
          stub_const("Rails::Server", Class.new)
        end

        it 'returns true' do
          expect(adapter.execute_async?).to be true
          expect(adapter.execute_externally?).to be false
        end
      end

      context 'when Rails::Server is not defined' do
        before do
          hide_const("Rails::Server")
        end

        it 'returns false' do
          expect(adapter.execute_async?).to be false
          expect(adapter.execute_externally?).to be true
        end
      end
    end

    context 'when execution mode async_server' do
      let(:adapter) { described_class.new(execution_mode: :async_server) }

      before do
        capsule = instance_double(GoodJob::Capsule, start: nil, create_thread: nil)
        allow(GoodJob::Capsule).to receive(:new).and_return(capsule)
      end

      context 'when Rails::Server is defined' do
        before do
          stub_const("Rails::Server", Class.new)
        end

        it 'returns true' do
          expect(adapter.execute_async?).to be true
          expect(adapter.execute_externally?).to be false
        end
      end

      context 'when Rails::Server is not defined' do
        before do
          hide_const("Rails::Server")
        end

        it 'returns false' do
          expect(adapter.execute_async?).to be false
          expect(adapter.execute_externally?).to be true
        end
      end
    end
  end
end
