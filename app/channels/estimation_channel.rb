class EstimationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "estimation_session"
  end

  def unsubscribed
    # Cleanup when channel is unsubscribed
  end
end