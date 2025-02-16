# frozen_string_literal: true

require 'rails_helper'

describe GoodJob do
  let(:configuration) { GoodJob::Configuration.new({ queues: 'mice:1', poll_interval: -1 }) }

  describe '.shutdown' do
    it 'shuts down all capsules' do
      capsule = GoodJob::Capsule.new(configuration: configuration)
      capsule.start
      expect { described_class.shutdown }.to change(capsule, :shutdown?).from(false).to(true)
    end
  end

  describe '.shutdown?' do
    it 'returns whether any capsules are running' do
      expect do
        capsule = GoodJob::Capsule.new(configuration: configuration)
        capsule.start
      end.to change(described_class, :shutdown?).from(true).to(false)

      expect do
        described_class.shutdown
      end.to change(described_class, :shutdown?).from(false).to(true)
    end
  end

  describe '.restart' do
    it 'does nothing when there are no capsule instances' do
      GoodJob::Capsule.instances.clear
      expect { described_class.restart }.not_to change(described_class, :shutdown?).from(true)
    end

    it 'restarts all capsule instances' do
      capsule = GoodJob::Capsule.new(configuration: configuration)
      expect { described_class.restart }.to change(capsule, :shutdown?).from(true).to(false)
      capsule.shutdown

      described_class.shutdown
    end

    context 'when in webserver but not in async mode' do
      before do
        allow(described_class.configuration).to receive_messages(execution_mode: :external, in_webserver?: true)
      end

      it 'does not start capsules' do
        GoodJob::Capsule.new(configuration: configuration)
        expect { described_class.restart }.not_to change(described_class, :shutdown?).from(true)
      end
    end
  end

  describe '.cleanup_preserved_jobs' do
    let!(:recent_job) { GoodJob::Job.create!(active_job_id: SecureRandom.uuid, finished_at: 12.hours.ago) }
    let!(:old_unfinished_job) { GoodJob::Job.create!(active_job_id: SecureRandom.uuid, scheduled_at: 15.days.ago, finished_at: nil) }
    let!(:old_finished_job) { GoodJob::Job.create!(active_job_id: SecureRandom.uuid, finished_at: 15.days.ago) }
    let!(:old_finished_job_execution) { GoodJob::Execution.create!(active_job_id: old_finished_job.active_job_id, finished_at: 16.days.ago) }
    let!(:old_discarded_job) { GoodJob::Job.create!(active_job_id: SecureRandom.uuid, finished_at: 15.days.ago, error: "Error") }
    let!(:old_batch) { GoodJob::BatchRecord.create!(jobs_finished_at: 14.days.ago, finished_at: 15.days.ago) }

    it 'deletes finished jobs' do
      destroyed_records_count = described_class.cleanup_preserved_jobs(in_batches_of: 1)

      expect(destroyed_records_count).to eq 4

      expect { recent_job.reload }.not_to raise_error
      expect { old_unfinished_job.reload }.not_to raise_error
      expect { old_finished_job.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_finished_job_execution.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_discarded_job.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_batch.reload }.to raise_error ActiveRecord::RecordNotFound
    end

    it 'takes arguments' do
      destroyed_records_count = described_class.cleanup_preserved_jobs(older_than: 10.seconds)

      expect(destroyed_records_count).to eq 5

      expect { recent_job.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_unfinished_job.reload }.not_to raise_error
      expect { old_finished_job.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_finished_job_execution.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_discarded_job.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_batch.reload }.to raise_error ActiveRecord::RecordNotFound
    end

    it 'is instrumented' do
      payloads = []
      callback = proc { |*args| payloads << args }

      ActiveSupport::Notifications.subscribed(callback, "cleanup_preserved_jobs.good_job") do
        described_class.cleanup_preserved_jobs
      end

      expect(payloads.size).to eq 1
    end

    it "respects the cleanup_discarded_jobs? configuration" do
      allow(described_class.configuration).to receive(:env).and_return ENV.to_hash.merge({ 'GOOD_JOB_CLEANUP_DISCARDED_JOBS' => 'false' })
      destroyed_records_count = described_class.cleanup_preserved_jobs

      expect(destroyed_records_count).to eq 3

      expect { recent_job.reload }.not_to raise_error
      expect { old_unfinished_job.reload }.not_to raise_error
      expect { old_finished_job.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_finished_job_execution.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_discarded_job.reload }.not_to raise_error
      expect { old_batch.reload }.to raise_error ActiveRecord::RecordNotFound
    end

    it "can override cleanup_discarded_jobs? configuration" do
      allow(described_class.configuration).to receive(:env).and_return ENV.to_hash.merge({ 'GOOD_JOB_CLEANUP_DISCARDED_JOBS' => 'false' })
      destroyed_records_count = described_class.cleanup_preserved_jobs(include_discarded: true)

      expect(destroyed_records_count).to eq 4

      expect { recent_job.reload }.not_to raise_error
      expect { old_unfinished_job.reload }.not_to raise_error
      expect { old_finished_job.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_finished_job_execution.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_discarded_job.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { old_batch.reload }.to raise_error ActiveRecord::RecordNotFound
    end

    it "does not delete batches until their callbacks have finished" do
      old_batch.update!(finished_at: nil)
      described_class.cleanup_preserved_jobs
      expect { old_batch.reload }.not_to raise_error

      old_batch.update!(finished_at: 15.days.ago)
      described_class.cleanup_preserved_jobs
      expect { old_batch.reload }.to raise_error ActiveRecord::RecordNotFound
    end
  end

  describe '.perform_inline' do
    before do
      stub_const 'PERFORMED', []
      stub_const 'JobError', Class.new(StandardError)
      stub_const 'TestJob', (Class.new(ActiveJob::Base) do
        self.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)

        def perform(succeed: true)
          PERFORMED << Time.current
          raise JobError unless succeed
        end
      end)
    end

    it 'executes performable jobs' do
      TestJob.perform_later
      TestJob.perform_later
      TestJob.set(wait: 1.minute).perform_later

      described_class.perform_inline
      expect(PERFORMED.size).to eq 2
    end

    it 'raises unhandled exceptions' do
      TestJob.perform_later(succeed: false)

      expect do
        described_class.perform_inline
      end.to raise_error JobError
    end

    it 'executes future scheduled jobs' do
      TestJob.set(wait: 5.minutes).perform_later

      expect(PERFORMED.size).to eq 0
      Timecop.travel(6.minutes.from_now) do
        described_class.perform_inline
      end
      expect(PERFORMED.size).to eq 1
    end

    it 'can accept a limit' do
      TestJob.perform_later
      TestJob.perform_later

      described_class.perform_inline(limit: 1)

      expect(PERFORMED.size).to eq 1
    end
  end

  describe '#v4_ready?' do
    it "is true" do
      allow(described_class.deprecator).to receive(:warn)
      expect(described_class.v4_ready?).to eq true
      expect(described_class.deprecator).to have_received(:warn)
    end
  end

  describe '.pause, .unpause, and .paused?' do
    it 'can pause and unpause jobs' do
      expect(described_class.paused?(queue: 'default')).to be false
      expect(described_class.paused).to eq({ queues: [], job_classes: [], labels: [] })

      described_class.pause(queue: 'default')
      described_class.pause(job_class: 'MyJob')
      expect(described_class.paused?(queue: 'default')).to be true
      expect(described_class.paused).to eq({ queues: ['default'], job_classes: ['MyJob'], labels: [] })

      described_class.unpause(queue: 'default')
      expect(described_class.paused?(queue: 'default')).to be false
      expect(described_class.paused).to eq({ queues: [], job_classes: ['MyJob'], labels: [] })

      described_class.unpause(job_class: 'MyJob')
      expect(described_class.paused).to eq({ queues: [], job_classes: [], labels: [] })
    end
  end

  describe '.cli?' do
    it 'returns true when in a CLI environment' do
      allow(GoodJob::CLI).to receive(:within_exe?).and_return(false)
      expect(described_class.cli?).to be false

      allow(GoodJob::CLI).to receive(:within_exe?).and_return(true)
      expect(described_class.cli?).to be true
    end
  end
end
