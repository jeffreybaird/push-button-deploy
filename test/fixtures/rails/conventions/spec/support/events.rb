# frozen_string_literal: true

module EventCapture
  def capture_events(name)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(name) { |*args| events << args.last }
    yield events
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def rolled_back_events(name, &block)
    capture_events(name) { rollback_change(&block) }
  end

  def rollback_change
    Note.transaction do
      yield
      raise ActiveRecord::Rollback
    end
  end
end
